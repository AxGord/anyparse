package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * End-to-end probes for the v7 Tier-2 DX additions:
 *  - `apq sweep` — read-only view on `bin/.last-sweep.json` snapshot.
 *  - `apq cases <Ctor>` — case-pattern lookup precise to `case Foo(_):`.
 *  - `apq ast --children-limit N` — per-level horizontal width clamp.
 *  - `apq lit <camelCase>` — auto-widen to `--any-kind` on default 0-hit.
 *
 * Each test redirects `sys.io.File.saveContent` outputs into the OS
 * temp dir via `CliFixture` so a kill never litters the repo.
 */
@:nullSafety(Strict)
class ApqDxTier2CliTest extends Test {

	// -- apq sweep --

	public function testSweepReadsTotals(): Void {
		#if sys
		final snapshot: String = CliFixture.writeAs(
			'apq_sweep', 'json', '{"pass":42,"fail":7,"skipParse":3,"skipWrite":0,"skipConfig":1,"skipMalformed":1}'
		);
		Assert.equals(0, Cli.run(['sweep', '--file', snapshot]), 'reading a valid snapshot exits 0');
		FileSystem.deleteFile(snapshot);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepMissingFileExitsRuntime(): Void {
		#if sys
		Assert.equals(1, Cli.run(['sweep', '--file', '/tmp/definitely_does_not_exist.json']), 'missing file → EXIT_RUNTIME');
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepDeltaVsPrev(): Void {
		#if sys
		final cur: String = CliFixture.writeAs(
			'apq_sweep_cur', 'json', '{"pass":533,"fail":267,"skipParse":98,"skipWrite":0,"skipConfig":1,"skipMalformed":1}'
		);
		final prev: String = CliFixture.writeAs(
			'apq_sweep_prev', 'json', '{"pass":533,"fail":264,"skipParse":101,"skipWrite":0,"skipConfig":1,"skipMalformed":1}'
		);
		Assert.equals(0, Cli.run(['sweep', '--file', cur, '--prev', prev]), 'delta-vs-prev exits 0 on read success');
		FileSystem.deleteFile(cur);
		FileSystem.deleteFile(prev);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSweepAcceptsInjectedLangFlag(): Void {
		#if sys
		// hxq shim auto-injects `--lang haxe`; sweep must accept and
		// ignore it (snapshot reading has no language concern).
		final snapshot: String = CliFixture.writeAs(
			'apq_sweep', 'json', '{"pass":1,"fail":0,"skipParse":0,"skipWrite":0,"skipConfig":0,"skipMalformed":0}'
		);
		Assert.equals(0, Cli.run(['sweep', '--lang', 'haxe', '--file', snapshot]));
		FileSystem.deleteFile(snapshot);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- apq cases --

	public function testCasesFindsCallPattern(): Void {
		#if sys
		final src: String = 'class C { function f() { switch x { case VarMember(d): trace(d); case _: } } }';
		final f: String = CliFixture.write('apq_cases', src);
		Assert.equals(0, Cli.run(['cases', 'VarMember', f]), 'case VarMember(d): → exit 0 with hits');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCasesFindsBareIdentPattern(): Void {
		#if sys
		final src: String = 'class C { function f() { switch x { case FinalMember: 1; case _: 0; } } }';
		final f: String = CliFixture.write('apq_cases', src);
		Assert.equals(0, Cli.run(['cases', 'FinalMember', f]), 'case FinalMember: (bare ident) → exit 0');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCasesSkipsImports(): Void {
		#if sys
		// `import unit.VarMember` + `new VarMember()` must NOT match —
		// they are not case-patterns. `mentions` would over-match these;
		// `cases` deliberately doesn't.
		final src: String = 'class C { function f() { var x = new VarMember(); } }';
		final f: String = CliFixture.write('apq_cases', src);
		Assert.equals(0, Cli.run(['cases', 'VarMember', f]), 'no case-patterns → exit 0 (empty walker, not error)');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCasesMissingArgsExitsUsage(): Void {
		Assert.equals(2, Cli.run(['cases']), 'no args → EXIT_USAGE');
		Assert.equals(2, Cli.run(['cases', 'VarMember']), 'one arg → EXIT_USAGE (missing path)');
	}

	// -- apq ast --children-limit --

	public function testAstChildrenLimitClampsHorizontalWidth(): Void {
		#if sys
		// Module with 5 top-level decls → with --children-limit 2, only
		// 2 are rendered + a `(... 3 more)` sentinel.
		final src: String = 'class A {} class B {} class C {} class D {} class E {}';
		final f: String = CliFixture.write('apq_ast_climit', src);
		Assert.equals(
			0, Cli.run(['ast', f, '--depth', '1', '--children-limit', '2']), '--children-limit 2 should run cleanly on a 5-child root'
		);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAstChildrenLimitRejectsNegative(): Void {
		#if sys
		final f: String = CliFixture.write('apq_ast_climit', 'class C {}');
		Assert.equals(2, Cli.run(['ast', f, '--children-limit', '-1']), 'negative integer → EXIT_USAGE');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAstChildrenLimitRejectsNonInt(): Void {
		#if sys
		final f: String = CliFixture.write('apq_ast_climit', 'class C {}');
		Assert.equals(2, Cli.run(['ast', f, '--children-limit', 'foo']), 'non-int value → EXIT_USAGE');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// -- apq lit auto-widen --

	public function testLitAutoWidensOnDefault0Hit(): Void {
		#if sys
		// `HxSharpErrorSliceTest` is a CamelCase TypeName — default kind
		// (Literal,IdentExpr per smart-default) misses it as ImportDecl /
		// NewExpr. Auto-widen retries with --any-kind and shows hits.
		final src: String = 'import unit.HxSharpErrorSliceTest;\nclass R { function f() { new HxSharpErrorSliceTest(); } }';
		final f: String = CliFixture.write('apq_lit_widen', src);
		Assert.equals(0, Cli.run(['lit', 'HxSharpErrorSliceTest', f]), 'auto-widen exits 0 with hits, not 0-with-nudge');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLitExplicitKindDoesNotAutoWiden(): Void {
		#if sys
		// Explicit `--kind Literal` must NOT auto-widen — user picked
		// the filter deliberately. 0-hit nudge fires instead.
		final src: String = 'import unit.HxSharpErrorSliceTest;\n';
		final f: String = CliFixture.write('apq_lit_widen', src);
		Assert.equals(
			0, Cli.run(['lit', 'HxSharpErrorSliceTest', f, '--kind', 'Literal']),
			'explicit --kind disables auto-widen but still exits 0 cleanly'
		);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
