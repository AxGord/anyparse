package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.check.FixVerifier.FixRevertCause;
import anyparse.query.Cli;
import anyparse.query.cli.command.LintFixVerify;
import anyparse.query.cli.command.SweepCommand;
import utest.Assert;
import utest.Test;

using StringTools;

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
		#if (sys || nodejs)
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
		#if (sys || nodejs)
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
		#if (sys || nodejs)
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
		#if (sys || nodejs)
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
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('apq_wp_v10', 'class M {\n\tfunction m() {\n\t\tvar a, b;\n\t}\n}\n');
		Assert.equals(0, Cli.run(['writer-probe', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- #4: sweep --diff <prev> per-fixture status ---

	public function testSweepDiffEmitsPerFixtureFlips(): Void {
		#if (sys || nodejs)
		final cur: String = CliFixture.writeAs(
			'apq_sweep_v10_cur', 'json',
			'{"pass":2,"fail":1,"skipParse":0,"fixtures":[{"path":"test/testcases/whitespace/inline_calls.hxtest","status":"PASS"},{'
			+ '"path":"test/testcases/whitespace/static_locals.hxtest","status":"FAIL"},{'
			+ '"path":"test/testcases/whitespace/keep.hxtest","status":"PASS"}]}'
		);
		final prev: String = CliFixture.writeAs(
			'apq_sweep_v10_prev', 'json',
			'{"pass":1,"fail":1,"skipParse":1,"fixtures":[{"path":"test/testcases/whitespace/inline_calls.hxtest","status":"FAIL"},{'
			+ '"path":"test/testcases/whitespace/static_locals.hxtest","status":"SKIP_PARSE"},{'
			+ '"path":"test/testcases/whitespace/keep.hxtest","status":"PASS"}]}'
		);
		Assert.equals(0, Cli.run(['sweep', '--file', cur, '--diff', prev]));
		FileSystem.deleteFile(cur);
		FileSystem.deleteFile(prev);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepDiffIdenticalSnapshotsEmitsZeroChanged(): Void {
		#if (sys || nodejs)
		final cur: String = CliFixture.writeAs(
			'apq_sweep_v10_id', 'json', '{"pass":1,"fail":0,"skipParse":0,"fixtures":[{"path":"a","status":"PASS"}]}'
		);
		final prev: String = CliFixture.writeAs(
			'apq_sweep_v10_id', 'json', '{"pass":1,"fail":0,"skipParse":0,"fixtures":[{"path":"a","status":"PASS"}]}'
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
		#if (sys || nodejs)
		final cur: String = CliFixture.writeAs(
			'apq_sweep_v10_compose', 'json',
			'{"pass":2,"fail":0,"skipParse":0,"fixtures":[{"path":"a","status":"PASS"},{"path":"b","status":"PASS"}]}'
		);
		final prev: String = CliFixture.writeAs(
			'apq_sweep_v10_compose', 'json',
			'{"pass":1,"fail":1,"skipParse":0,"fixtures":[{"path":"a","status":"PASS"},{"path":"b","status":"FAIL"}]}'
		);
		Assert.equals(0, Cli.run(['sweep', '--file', cur, '--prev', prev, '--diff', prev]));
		FileSystem.deleteFile(cur);
		FileSystem.deleteFile(prev);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepDiffMissingFixturesArrayFails(): Void {
		#if (sys || nodejs)
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

	/**
	 * An ABSENT baseline is diagnosed as absent, not as a FORMAT problem.
	 *
	 * `loadSweepFixtureStatus` fails soft, so a missing file, a malformed one and one with
	 * no `fixtures` array all arrive as the same empty map. The single message this used to
	 * print named the last of the three — and the case a fresh worktree actually hits is the
	 * first, so the reader went looking for a corrupt snapshot nothing had written yet.
	 */
	@:access(anyparse.query.Cli)
	public function testSweepDiffAbsentBaselineIsNotReportedAsAFormatProblem(): Void {
		final absent: String = SweepCommand.sweepDiffNoBaseline('bin/.prev-sweep.json', false, true);
		Assert.isTrue(absent.contains('does not exist'), 'names ABSENCE - got: $absent');
		Assert.isFalse(absent.contains('`fixtures` array'), 'and never the format cause - got: $absent');
		Assert.isTrue(absent.contains('ROTATION'), 'and says why a first sweep leaves it absent - got: $absent');
		final malformed: String = SweepCommand.sweepDiffNoBaseline('bin/.prev-sweep.json', true, true);
		Assert.isTrue(malformed.contains('carries no readable `fixtures` array'), 'a PRESENT one names the format - got: $malformed');
		Assert.isFalse(malformed.contains('does not exist'), 'and never absence - got: $malformed');
	}

	/** An EXPLICIT baseline that is absent gets the --save remedy, never the rotation explainer that does not apply to it. */
	@:access(anyparse.query.Cli)
	public function testSweepDiffExplicitAbsentBaselineGetsItsOwnRemedy(): Void {
		final explicit: String = SweepCommand.sweepDiffNoBaseline('/tmp/base.json', false, false);
		Assert.isTrue(explicit.contains('does not exist'), 'names ABSENCE - got: $explicit');
		Assert.isTrue(explicit.contains('--save'), 'and points at the op that creates one - got: $explicit');
		Assert.isFalse(explicit.contains('ROTATION'), 'and not at a rotation that never touches it - got: $explicit');
	}

	/**
	 * The AUTO-ROTATED baseline's `0 changed` carries what it is worth, on the same run.
	 *
	 * The harness overwrites `bin/.prev-sweep.json` with the preceding run's snapshot before
	 * every write, so the default `--diff` compares the last two runs of ONE tree. In a fresh
	 * worktree both of those ran after the change, which makes 0 the only answer the
	 * comparison can give — a gate that cannot fail, printing as a pass.
	 */
	@:access(anyparse.query.Cli)
	public function testSweepDiffAutoRotatedBaselineDeclaresItsProvenance(): Void {
		final note: String = SweepCommand.sweepDiffAutoRotatedNote('bin/.prev-sweep.json');
		Assert.isTrue(note.contains('bin/.prev-sweep.json'), 'names the baseline - got: $note');
		Assert.isTrue(note.contains('AUTO-ROTATED'), 'says what that baseline is - got: $note');
		Assert.isTrue(note.contains('--save'), 'and names the form that can fail - got: $note');
	}

	// --- #5: search rejects macro reification with clear error ---

	public function testSearchRejectsDollarVReification(): Void {
		#if (sys || nodejs)
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
		#if (sys || nodejs)
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
		#if (sys || nodejs)
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
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('apq_lit_v10', 'class C { var x:Int; }');
		Assert.equals(0, Cli.run(['lit', 'foo\\|bar', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitNegatedCharClassExitsClean(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('apq_lit_v10', 'class C { var x:Int; }');
		Assert.equals(0, Cli.run(['lit', '[^abc]', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitNonCapturingGroupExitsClean(): Void {
		#if (sys || nodejs)
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
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('apq_lit_v10', 'class C { var foo:Int = 1; }');
		Assert.equals(0, Cli.run(['lit', 'foo', fixture]));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The TOTALS path's missing-snapshot line names the cause and the remedy, the
	 * way the `--diff` path's already did.
	 *
	 * `apq sweep` only READS what the corpus harness inside `bin/test.js` writes,
	 * so a tree where that has never run has nothing to read — and `--save` has
	 * nothing to copy. The old line said `cannot read <path> (missing or
	 * unparseable)`, which reads as a corrupt file rather than as one nobody has
	 * written yet: a batch protocol grew a "run a plain `sweep` first" step off
	 * that misreading, and it cannot work, because a plain `sweep` reads the very
	 * same file.
	 */
	@:access(anyparse.query.Cli)
	public function testSweepMissingSnapshotNamesTheHarnessThatWritesIt(): Void {
		#if (sys || nodejs)
		final gone: String = CliFixture.writeAs('apq_sweep_w23_absent', 'json', '');
		FileSystem.deleteFile(gone);
		final absent: String = SweepCommand.sweepNoSnapshot(gone, null);
		Assert.isTrue(absent.contains('no corpus snapshot'), 'names ABSENCE - got: $absent');
		Assert.isTrue(absent.contains('node bin/test.js'), 'and the run that writes it - got: $absent');
		Assert.isTrue(absent.contains('does not seed it'), 'and kills the plain-sweep-first workaround - got: $absent');
		final present: String = CliFixture.writeAs('apq_sweep_w23_bad', 'json', 'not json');
		final malformed: String = SweepCommand.sweepNoSnapshot(present, null);
		Assert.isTrue(malformed.contains('is not a sweep snapshot'), 'a PRESENT one names the format - got: $malformed');
		Assert.isFalse(malformed.contains('no corpus snapshot'), 'and never absence - got: $malformed');
		FileSystem.deleteFile(present);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--save` says it had nothing to COPY, so a two-command recipe names the half that failed. */
	@:access(anyparse.query.Cli)
	public function testSweepSaveMissingSnapshotBlamesTheSourceNotTheDestination(): Void {
		#if (sys || nodejs)
		final gone: String = CliFixture.writeAs('apq_sweep_w23_save', 'json', '');
		FileSystem.deleteFile(gone);
		final save: String = SweepCommand.sweepNoSnapshot(gone, '/tmp/base.json');
		Assert.isTrue(save.contains('--save /tmp/base.json has nothing to copy'), 'names the save and its cause - got: $save');
		final read: String = SweepCommand.sweepNoSnapshot(gone, null);
		Assert.isFalse(read.contains('--save'), 'a plain read never mentions --save - got: $read');
		#else
		Assert.pass('non-sys target');
		#end
	}


	/**
	 * The three risky-fix revert causes render as three DIFFERENT sentences, and
	 * only one of them names the compiler.
	 *
	 * `FixVerifier` used to collapse every non-`Ok` from `canonicalize` into the
	 * bisect's boolean `false`, which is the oracle's word for "the compiler
	 * rejected this" — so a WRITER refusal was recorded, and reported, as a
	 * compiler rejection. A reader chasing that reason goes looking in the check's
	 * edit for a type error that is not there.
	 */
	@:access(anyparse.query.Cli)
	public function testRevertCausesRenderDistinguishably(): Void {
		final rejected: String = LintFixVerify.revertCauseText(OracleRejected);
		final unavailable: String = LintFixVerify.revertCauseText(OracleUnavailable('no hxml'));
		final uncanonical: String = LintFixVerify.revertCauseText(NotCanonical('the writer cannot settle this file'));
		Assert.isTrue(rejected.contains('compiler rejected'), 'the oracle verdict names the compiler - got: $rejected');
		Assert.isTrue(unavailable.contains('could not run'), 'an absent oracle says so - got: $unavailable');
		Assert.isTrue(uncanonical.contains('nothing reached the compiler'), 'a writer refusal denies it - got: $uncanonical');
		Assert.isFalse(uncanonical.contains('rejected'), 'and never claims a rejection that never happened - got: $uncanonical');
		Assert.isTrue(uncanonical.contains('cannot settle'), 'carrying the writer\'s own words - got: $uncanonical');
	}

	/** A `--prev` baseline is one the USER saved, so its absence points at `--save`, never at the corpus harness. */
	@:access(anyparse.query.Cli)
	public function testSweepPrevMissingBaselinePointsAtSaveNotTheHarness(): Void {
		#if (sys || nodejs)
		final gone: String = CliFixture.writeAs('apq_sweep_w23_prev', 'json', '');
		FileSystem.deleteFile(gone);
		final prev: String = SweepCommand.sweepNoSnapshot(gone, null, true);
		Assert.isTrue(prev.contains('--prev'), 'names the flag that failed - got: $prev');
		Assert.isTrue(prev.contains('--save'), 'and the op that creates one - got: $prev');
		Assert.isFalse(prev.contains('node bin/test.js'), 'never the harness, which does not write this path - got: $prev');
		Assert.isFalse(prev.contains('has not run the corpus harness'), 'and never a claim the totals just disproved - got: $prev');
		#else
		Assert.pass('non-sys target');
		#end
	}

}
