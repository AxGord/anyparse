package unit;

import anyparse.check.AvoidDynamic;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.OracleCoverage;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * The `RiskyFix` verifier's COVERAGE gate, end to end against the real compiler, in the
 * three directions that together make it a control rather than a slogan.
 *
 * 1. A file the oracle does not compile is DECLINED — nothing is written to it, and the
 *    run says so instead of calling the resulting exit-0 typecheck a verification.
 * 2. A file the oracle does compile is still verified and applied — the gate must not buy
 *    its honesty by refusing everything, which would trade a false confident answer for a
 *    useless one.
 * 3. A fix that genuinely breaks the build in a compiled file is still caught and REVERTED,
 *    and is reported as a revert, not as a decline.
 *
 * The fixture is one `-cp .` directory holding a `-main` module and an unreferenced sibling
 * carrying the identical `avoid-dynamic` shape, so the two files differ in exactly one
 * respect: whether the compiler reads them.
 */
@:nullSafety(Strict)
final class FixVerifierCoverageE2ETest extends Test {

	#if (sys || nodejs)
	/** The `-main` module, with a narrowable `Dynamic` local — inside the compiled set. */
	private static final MAIN: String = 'class Main {\n\n\tpublic function new() {}\n\n\tstatic function main() {\n'
		+ '\t\tfinal a:Main = new Main();\n\t\tvar x:Dynamic = a;\n\t\tvar y:Main = x;\n\t\ttrace(y);\n\t}\n\n}\n';

	/** The same narrowable shape in a module nothing references — outside the compiled set. */
	private static final OTHER: String = 'class Other {\n\n\tpublic function new() {}\n\n\tpublic function run():Void {\n'
		+ '\t\tfinal a:Other = new Other();\n\t\tvar x:Dynamic = a;\n\t\tvar y:Other = x;\n\t\ttrace(y);\n\t}\n\n}\n';

	/**
	 * A `-main` module whose narrowing BREAKS the build: `?b:Main` records nominal `Main` in
	 * `declaredTypes`, so the classifier proposes `x:Main` and `@:nullSafety(Strict)` refuses
	 * the `x = b` the original `Dynamic` tolerated.
	 */
	private static final BREAKS: String = '@:nullSafety(Strict)\nclass Main {\n\n\tpublic function new() {}\n\n'
		+ '\tstatic function main() {\n\t\trun(new Main());\n\t}\n\n\tstatic function run(a:Main, ?b:Main):Void {\n'
		+ '\t\tvar x:Dynamic = a;\n\t\tx = b;\n\t\tvar y:Main = x;\n\t\ttrace(y);\n\t}\n\n}\n';
	private static final HXML: String = '-cp .\n-main Main\n';
	#end

	/** Direction 1: outside the compiled set — declined, untouched, and named. */
	public function testUncoveredFileIsDeclinedAndLeftUntouched(): Void {
		#if (sys || nodejs)
		final dir: String = pairDir(MAIN);
		if (skipWithoutHaxe(dir)) return;
		final result: FixVerifyResult = verifyPair(dir, MAIN);
		Assert.equals(1, result.declined.length, 'the uncovered file yields exactly one decline');
		Assert.equals('$dir/Other.hx', result.declined[0].file);
		Assert.equals('avoid-dynamic', result.declined[0].rule, 'the decline names the rule that proposed the edit');
		Assert.equals(1, result.declined[0].edits, 'and how many edits went unapplied');
		Assert.equals(
			OTHER, File.getContent('$dir/Other.hx'), 'the uncovered file is byte-identical — no candidate was ever written to it'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Direction 2: inside the compiled set — still verified and applied, in the very same run. */
	public function testCoveredFileIsStillVerifiedAndApplied(): Void {
		#if (sys || nodejs)
		final dir: String = pairDir(MAIN);
		if (skipWithoutHaxe(dir)) return;
		final result: FixVerifyResult = verifyPair(dir, MAIN);
		Assert.same(['$dir/Main.hx'], result.applied, 'the compiled file is verified and applied');
		Assert.equals(1, result.appliedEdits);
		Assert.equals(0, result.reverted.length);
		// Both halves in ONE string: the narrowed declaration next to the untouched line below
		// it, so neither assertion can be satisfied by a run that did nothing.
		Assert.isTrue(
			File.getContent('$dir/Main.hx').indexOf('var x:Main = a;\n\t\tvar y:Main = x;') != -1,
			'the compiled file carries the narrowing'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Direction 3: a real build break inside the compiled set is still caught, and is a REVERT, not a decline. */
	public function testBuildBreakingFixInACoveredFileIsStillReverted(): Void {
		#if (sys || nodejs)
		final dir: String = pairDir(BREAKS);
		if (skipWithoutHaxe(dir)) return;
		final result: FixVerifyResult = verifyPair(dir, BREAKS);
		Assert.equals(0, result.applied.length, 'a narrowing that breaks the build is not applied');
		Assert.equals(1, result.reverted.length, 'it is REVERTED — the compiler read it and refused it');
		Assert.equals('$dir/Main.hx', result.reverted[0].file);
		Assert.isTrue(result.reverted[0].cause.match(OracleRejected), 'and the cause is the compiler, not a coverage gap');
		Assert.equals(BREAKS, File.getContent('$dir/Main.hx'), 'the compiled file is restored byte for byte');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * An oracle whose compiled set could not be established verifies NOTHING: the phase stops,
	 * carries the reason out, and leaves every file alone — the same outcome as a project with
	 * no `compilerOracle` key at all.
	 */
	public function testUnknownCoverageStopsThePhaseEntirely(): Void {
		#if (sys || nodejs)
		final dir: String = pairDir(MAIN);
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/Main.hx', source: MAIN },
			{ file: '$dir/Other.hx', source: OTHER }
		];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new AvoidDynamic()],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent, OracleCoverage.unknown('probe stub')
		);
		if (!result.baseline.match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		Assert.equals('probe stub', result.coverageUnknown, 'the reason travels out to the summary line');
		Assert.equals(0, result.applied.length);
		Assert.equals(0, result.declined.length, 'no per-file declines — one fact about the oracle, not one per candidate');
		Assert.equals(MAIN, File.getContent('$dir/Main.hx'), 'even the compiled file is left alone');
		Assert.equals(OTHER, File.getContent('$dir/Other.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * True when this host has no working `haxe` — the fixture typechecks by construction, so a
	 * rejection means no compiler. Carries the skip verdict AND the teardown, so each scenario
	 * opens with one line instead of the same four.
	 */
	private function skipWithoutHaxe(dir: String): Bool {
		if (CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) return false;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return true;
	}

	/** A fixture directory holding `main`, the unreferenced `Other.hx`, and the hxml. */
	private static function pairDir(main: String): String {
		return CliFixture.writeDir('fixvercov', [
			{ name: 'Main.hx', source: main },
			{ name: 'Other.hx', source: OTHER },
			{ name: 'check.hxml', source: HXML }
		]);
	}

	/** One `avoid-dynamic` verification pass over both files of `dir`, coverage probed for real. */
	private static function verifyPair(dir: String, main: String): FixVerifyResult {
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/Main.hx', source: main },
			{ file: '$dir/Other.hx', source: OTHER }
		];
		return FixVerifier.verify(files, [new AvoidDynamic()], new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent);
	}
	#end

}
