package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

/**
 * End-to-end probe for `apq probe` (inline-source AST/writer
 * inspection) and the underlying `ast --code` / `ast --stdin`
 * source paths.
 *
 * Asserts exit codes only — stdout is written via Sys.print, so the
 * tests verify the engine handles the source-from-arg paths without
 * crashing, mutual exclusivity is enforced, the `hxq` shim's
 * pre-inserted `--lang haxe` does NOT get consumed as the code arg,
 * and every forwarded `ast` flag (`--depth`, `--select`,
 * `--writer-output`, `--writer-output --diff`) drives through.
 */
@:nullSafety(Strict)
class ApqProbeCliTest extends Test {

	public function testHelpReturnsOk(): Void {
		Assert.equals(0, Cli.run(['probe', '--help']));
	}

	public function testInlineCodeParses(): Void {
		Assert.equals(0, Cli.run(['probe', 'class C {}']));
	}

	public function testInlineCodeWithDepth(): Void {
		Assert.equals(0, Cli.run(['probe', 'class C { function f() { return 1; } }', '--depth', '5']));
	}

	public function testInlineCodeWithSelect(): Void {
		Assert.equals(0, Cli.run(['probe', 'class C { var x:Int = 1; }', '--select', 'VarMember']));
	}

	public function testInlineCodeWithWriterOutput(): Void {
		Assert.equals(0, Cli.run(['probe', 'class C {}', '--writer-output']));
	}

	public function testInlineCodeWithWriterOutputDiff(): Void {
		Assert.equals(0, Cli.run([
			'probe',
			'class C { static function f() { return 1; } }',
			'--writer-output',
			'--diff'
		]));
	}

	public function testInlineCodeWithWriterOutputPlain(): Void {
		Assert.equals(0, Cli.run(['probe', 'class C {}', '--writer-output-plain']));
	}

	public function testParseErrorExitsRuntime(): Void {
		// Unparseable: closing brace missing. Must EXIT_RUNTIME (1),
		// not EXIT_USAGE (2) — the source IS provided, the engine
		// just couldn't accept it.
		Assert.equals(1, Cli.run(['probe', 'class C {']));
	}

	public function testMissingCodeArgExitsUsage(): Void {
		// Only flags, no positional code.
		Assert.equals(2, Cli.run(['probe', '--depth', '5']));
	}

	public function testNoArgsExitsOkOnHelp(): Void {
		// Pre-existing convention: no args prints usage and exits 0.
		// (printProbeUsage path; bare `apq probe` shouldn't crash.)
		Assert.equals(0, Cli.run(['probe']));
	}

	public function testTwoPositionalsExitsUsage(): Void {
		Assert.equals(2, Cli.run(['probe', 'class A {}', 'class B {}']));
	}

	public function testLangFlagBeforeCodeIsForwarded(): Void {
		// Exactly what the `hxq` shim emits: `apq probe --lang haxe <code>`.
		// The argv walker MUST forward `--lang haxe` to runAst without
		// consuming `<code>` as the value of `--lang`.
		Assert.equals(0, Cli.run(['probe', '--lang', 'haxe', 'class C {}']));
	}

	public function testFlagsAfterCode(): Void {
		Assert.equals(0, Cli.run(['probe', 'class C {}', '--depth', '3', '--json']));
	}

	public function testFlagsAroundCode(): Void {
		Assert.equals(0, Cli.run(['probe', '--lang', 'haxe', 'class C {}', '--depth', '3']));
	}

	public function testAstFileAndCodeMutexErrors(): Void {
		// Direct call to ast surface — both file and --code is invalid.
		Assert.equals(2, Cli.run(['ast', '--code', 'class A {}', 'someFile.hx']));
	}

	public function testAstMissingAllThreeSourcesErrors(): Void {
		Assert.equals(2, Cli.run(['ast']));
	}

	public function testAstCodeFlagDirect(): Void {
		// The underlying --code flag works as a direct ast option, not
		// only through the probe subcommand.
		Assert.equals(0, Cli.run(['ast', '--code', 'class C {}']));
	}

	/**
	 * `--spans` is in `AST_BOOL_FLAGS` so the probe walker treats it as
	 * a no-value flag and forwards it intact to `runAst`. Verifies the
	 * flag is recognized end-to-end (exit 0); content is checked
	 * elsewhere.
	 */
	public function testInlineCodeWithSpans(): Void {
		Assert.equals(0, Cli.run(['probe', 'class C { var x = a ? 1. : 2.; }', '--spans']));
	}

	public function testAstSpansFlagDirect(): Void {
		Assert.equals(0, Cli.run(['ast', '--code', 'class C {}', '--spans']));
	}

	public function testAstSpansComposesWithDepth(): Void {
		Assert.equals(0, Cli.run(['ast', '--code', 'class C { var x:Int = 1; }', '--spans', '--depth', '4']));
	}

}
