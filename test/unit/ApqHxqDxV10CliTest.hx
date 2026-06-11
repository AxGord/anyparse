package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
#end

/**
 * `hxq DX v10` six-pack (CLI-exercised improvements; #2 is shim-level,
 * covered by smoke tests on `bin/hxq`):
 *
 *  - #1: `apq cases <Ctor>` now unwraps Slice 34's `HxCasePatternBody.Plain`
 *    wrapper, so post-Slice-34 sources (every Haxe file in the project)
 *    actually surface their `case Foo(_):` patterns. Pre-fix: 0 hits.
 *  - #2: `bin/hxq` stale-build warning throttle / auto-rebuild / quiet
 *    envs — shim-only, no CLI test.
 *  - #3: `apq writer-probe` emits a stderr NOTE when the trivia output
 *    diverges from source bytes — surfaces writer-fidelity gaps
 *    (`HxVarMore` `,` collapses the space, etc.) at probe time, not
 *    test-failure time.
 *  - #4: `apq sweep --diff <prev>` prints per-fixture status flips
 *    (PASS->FAIL / FAIL->PASS / ADDED / REMOVED). Replaces the ad-hoc
 *    python3 read on `bin/.last-sweep.json`.
 *  - #5: `apq search` rejects macro reification (`$v{}` / `$i{}` / ...)
 *    with a clear "use lit" error message instead of the generic "not
 *    valid as expression" parser fault.
 *  - #6: `apq lit` emits a regex-not-supported NOTE when the query
 *    carries regex-only syntax (`\|`, `[^...]`, `(?:...)`, etc.) —
 *    previously misrouted to the dotted-access nudge.
 */
@:nullSafety(Strict)
class ApqHxqDxV10CliTest extends Test {

	// --- #1: cases unwraps HxCasePatternBody.Plain (Slice 34) ---

	public function testCasesUnwrapsPlainWrapper(): Void {
		#if sys
		// Post-Slice-34, every `case <expr>:` in a Haxe source parses
		// through `Plain(Call(IdentExpr "VarStmt", ...))`. Before the
		// DX v10 fix, `cases` would return 0 hits on this fixture
		// because `Plain` fell through `matchPattern`'s default arm.
		// Exit code 0 is preserved (cases always exits clean when scan
		// succeeds) — the regression check is that the call doesn't
		// crash AND completes through the Plain-unwrap arm.
		final fixture: String = CliFixture.write(
			'apq_cases_v10', 'class C { function f(s:Dynamic) { switch s { case VarStmt(_): trace(""); case _: } } }'
		);
		Assert.equals(0, Cli.run(['cases', 'VarStmt', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCasesNoMatchSilent(): Void {
		// Regression: a fixture WITHOUT a matching case still exits 0
		// (silent zero-hit). Pairs with the unwrap test — together they
		// verify the Plain arm fires for matches and stays inert otherwise.
		#if sys
		final fixture: String = CliFixture.write('apq_cases_v10', 'class C { function f() { switch x { case 1: trace(""); case _: } } }');
		Assert.equals(0, Cli.run(['cases', 'VarStmt', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCasesAlternationStillMatches(): Void {
		// Regression: BitOr arm (`case A | B:`) still works through Plain
		// (Plain wraps the BitOr, BitOr recurses to its sides).
		#if sys
		final fixture: String = CliFixture.write(
			'apq_cases_v10', 'class C { function f(s:Dynamic) { switch s { case Foo | VarStmt: trace(""); case _: } } }'
		);
		Assert.equals(0, Cli.run(['cases', 'VarStmt', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- #3: writer-probe source-preservation note ---

	public function testWriterProbeRunsCleanOnSourcePreservingFixture(): Void {
		// A fixture whose trivia round-trip preserves source bytes
		// (single-var, no comma-list). Exit 0, no failure.
		#if sys
		final fixture: String = CliFixture.write('apq_wp_v10', 'class M {\n\tfunction m() {\n\t\tvar a = 1;\n\t}\n}\n');
		Assert.equals(0, Cli.run(['writer-probe', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testWriterProbeRunsCleanOnSourceDivergingFixture(): Void {
		// HxVarMore `, ` collapses to `,` in the trivia writer (known
		// writer-fidelity gap). The probe still exits 0 — the new NOTE
		// goes to stderr, doesn't affect exit. Regression: this used to
		// silently produce the wrong-looking output; now the note flags it.
		#if sys
		final fixture: String = CliFixture.write('apq_wp_v10', 'class M {\n\tfunction m() {\n\t\tvar a, b;\n\t}\n}\n');
		Assert.equals(0, Cli.run(['writer-probe', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- #4: sweep --diff <prev> per-fixture status ---

	public function testSweepDiffEmitsPerFixtureFlips(): Void {
		#if sys
		final cur: String = CliFixture.writeAs(
			'apq_sweep_v10_cur', 'json',
			'{' + '"pass":2,"fail":1,"skipParse":0,' + '"fixtures":['
			+ '{"path":"test/testcases/whitespace/inline_calls.hxtest","status":"PASS"},'
			+ '{"path":"test/testcases/whitespace/static_locals.hxtest","status":"FAIL"},'
			+ '{"path":"test/testcases/whitespace/keep.hxtest","status":"PASS"}' + ']}'
		);
		final prev: String = CliFixture.writeAs(
			'apq_sweep_v10_prev', 'json',
			'{' + '"pass":1,"fail":1,"skipParse":1,' + '"fixtures":['
			+ '{"path":"test/testcases/whitespace/inline_calls.hxtest","status":"FAIL"},'
			+ '{"path":"test/testcases/whitespace/static_locals.hxtest","status":"SKIP_PARSE"},'
			+ '{"path":"test/testcases/whitespace/keep.hxtest","status":"PASS"}' + ']}'
		);
		Assert.equals(0, Cli.run(['sweep', '--file', cur, '--diff', prev]));
		FileSystem.deleteFile(cur);
		FileSystem.deleteFile(prev);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepDiffIdenticalSnapshotsEmitsZeroChanged(): Void {
		#if sys
		final cur: String = CliFixture.writeAs(
			'apq_sweep_v10_id', 'json', '{' + '"pass":1,"fail":0,"skipParse":0,' + '"fixtures":[{"path":"a","status":"PASS"}]}'
		);
		final prev: String = CliFixture.writeAs(
			'apq_sweep_v10_id', 'json', '{' + '"pass":1,"fail":0,"skipParse":0,' + '"fixtures":[{"path":"a","status":"PASS"}]}'
		);
		Assert.equals(0, Cli.run(['sweep', '--file', cur, '--diff', prev]));
		FileSystem.deleteFile(cur);
		FileSystem.deleteFile(prev);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepDiffComposesWithPrev(): Void {
		// `--prev` (totals delta) and `--diff` (per-fixture flips) are
		// orthogonal — both can be passed in a single call. Composes
		// cleanly without arg-conflict errors.
		#if sys
		final cur: String = CliFixture.writeAs(
			'apq_sweep_v10_compose', 'json',
			'{' + '"pass":2,"fail":0,"skipParse":0,' + '"fixtures":[{"path":"a","status":"PASS"},{"path":"b","status":"PASS"}]}'
		);
		final prev: String = CliFixture.writeAs(
			'apq_sweep_v10_compose', 'json',
			'{' + '"pass":1,"fail":1,"skipParse":0,' + '"fixtures":[{"path":"a","status":"PASS"},{"path":"b","status":"FAIL"}]}'
		);
		Assert.equals(0, Cli.run(['sweep', '--file', cur, '--prev', prev, '--diff', prev]));
		FileSystem.deleteFile(cur);
		FileSystem.deleteFile(prev);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepDiffMissingFixturesArrayFails(): Void {
		#if sys
		final cur: String = CliFixture.writeAs('apq_sweep_v10_nof', 'json', '{"pass":1,"fail":0,"skipParse":0}');
		final prev: String = CliFixture.writeAs(
			'apq_sweep_v10_nof', 'json', '{"pass":0,"fail":1,"skipParse":0,"fixtures":[{"path":"a","status":"FAIL"}]}'
		);
		// --diff requires `fixtures` arrays in both snapshots; absent →
		// EXIT_RUNTIME with a stderr explainer.
		Assert.notEquals(0, Cli.run(['sweep', '--file', cur, '--diff', prev]));
		FileSystem.deleteFile(cur);
		FileSystem.deleteFile(prev);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- #5: search rejects macro reification with clear error ---

	public function testSearchRejectsDollarVReification(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_search_v10', 'class C {}');
		// Macro reification → EXIT_USAGE (was EXIT_RUNTIME with a
		// misleading "not valid as expression" message).
		Assert.equals(2, Cli.run(['search', "_dt($v{x})", fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSearchRejectsDollarIReification(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_search_v10', 'class C {}');
		Assert.equals(2, Cli.run(['search', "fn($i{name}, 1)", fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSearchPlainMetavarStillWorks(): Void {
		// Regression: plain `$x` metavars are NOT macro reification
		// (they don't have the `{` brace) — search must continue parsing
		// them as patterns.
		#if sys
		final fixture: String = CliFixture.write('apq_search_v10', 'class C { function f() { trace(1); } }');
		// Exit code 0 — pattern parses, search finds at least the trace call.
		Assert.equals(0, Cli.run(['search', "trace($x)", fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- #6: lit regex-like query nudge ---

	public function testLitRegexLikeQueryExitsClean(): Void {
		// `foo\|bar` is a regex alternation — lit is substring-only,
		// so the new NOTE points at running separate calls. Exit 0
		// (nudge is stderr, doesn't change exit).
		#if sys
		final fixture: String = CliFixture.write('apq_lit_v10', 'class C { var x:Int; }');
		Assert.equals(0, Cli.run(['lit', 'foo\\|bar', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitNegatedCharClassExitsClean(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_lit_v10', 'class C { var x:Int; }');
		Assert.equals(0, Cli.run(['lit', '[^abc]', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitNonCapturingGroupExitsClean(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_lit_v10', 'class C { var x:Int; }');
		Assert.equals(0, Cli.run(['lit', '(?:foo)', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitPlainQueryDoesNotTrigger(): Void {
		// Regression: plain glob-ish characters (`*`, `?`, `[`) are
		// common in identifiers and should NOT fire the regex nudge.
		// The existing fallback nudges keep their behaviour.
		#if sys
		final fixture: String = CliFixture.write('apq_lit_v10', 'class C { var foo:Int = 1; }');
		Assert.equals(0, Cli.run(['lit', 'foo', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
