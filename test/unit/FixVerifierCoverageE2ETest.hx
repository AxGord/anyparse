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
 * directions that together make it a control rather than a slogan.
 *
 * 1. A file the oracle does not compile is DECLINED — nothing is written to it, and the
 *    run says so instead of calling the resulting exit-0 typecheck a verification.
 * 2. A file the oracle does compile is still verified and applied — the gate must not buy
 *    its honesty by refusing everything, which would trade a false confident answer for a
 *    useless one.
 * 3. A fix that genuinely breaks the build in a compiled file is still caught and REVERTED,
 *    and is reported as a revert, not as a decline.
 * 4. Coverage that could not be established at all verifies NOTHING, and 5. every rule's
 *    findings and landed edits are tallied — the two directions the per-file lists cannot
 *    answer. 6. And one level below the file: two files the oracle BOTH compiles, whose
 *    `avoid-dynamic` shapes differ only in which `#if` branch holds them — the branch a
 *    file's `Parsed` line says nothing about.
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

	/** Both region modules are referenced, so `-main` pulls them into the compiled set. */
	private static final REGION_MAIN: String =
		'class Main {\n\n\tstatic function main() {\n\t\tnew Live().run();\n\t\tnew Dead().run();\n\t}\n\n}\n';

	/** The narrowable shape in the branch `-D regionon` KEEPS. */
	private static final LIVE: String = 'class Live {\n\n\tpublic function new() {}\n\n\tpublic function run():Void {\n'
		+ '\t\t#if regionon\n\t\tfinal a:Live = new Live();\n\t\tvar x:Dynamic = a;\n\t\tvar y:Live = x;\n\t\ttrace(y);\n'
		+ '\t\t#else\n\t\ttrace(0);\n\t\t#end\n\t}\n\n}\n';

	/** The SAME shape in the branch it drops — one variable, and the file is compiled either way. */
	private static final DEAD: String = 'class Dead {\n\n\tpublic function new() {}\n\n\tpublic function run():Void {\n'
		+ '\t\t#if regionon\n\t\ttrace(0);\n\t\t#else\n\t\tfinal a:Dead = new Dead();\n\t\tvar x:Dynamic = a;\n'
		+ '\t\tvar y:Dead = x;\n\t\ttrace(y);\n\t\t#end\n\t}\n\n}\n';
	private static final REGION_HXML: String = '-cp .\n-main Main\n-D regionon\n';
	/**
	 * `OTHER`'s shape under an indentation the writer will not settle on — the same findings, but
	 * `canonicalize` refuses the source before any candidate exists.
	 */
	private static final DRIFTED: String = 'class Other {\n    public function new() {}\n    public function run():Void {\n'
		+ '        final a:Other = new Other();\n        var x:Dynamic = a;\n        var y:Other = x;\n        trace(y);\n' + '    }\n}\n';
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
		// The `Reverted` arm of the tally arithmetic, which no other test fills: a candidate the
		// compiler read and refused reached disk with ZERO edits surviving, however many it had.
		// Beside it the uncovered file's `Declined` row, so neither can satisfy the other.
		Assert.same([
			{
				rule: 'avoid-dynamic',
				file: '$dir/Main.hx',
				findings: 1,
				edits: 0
			},
			{
				rule: 'avoid-dynamic',
				file: '$dir/Other.hx',
				findings: 1,
				edits: 0
			}
		], result.tallies);
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

	/**
	 * Direction 5, and the reason the other four could not answer it: what each RULE achieved.
	 *
	 * `applied` / `reverted` / `declined` answer per FILE and per EVENT, which is the wrong shape
	 * for the caller's per-rule fix ledger — so a `RiskyFix` rule contributed EDITS to a
	 * `lint --fix` summary and never a FINDING to the block that says what got no edit, and the two
	 * numbers a reader compares were measured over two different rule sets. `tallies` is that shape,
	 * and both directions of the same run have to appear in it: the covered file with its edit
	 * landed, the uncovered one with its findings and nothing landed.
	 *
	 * Asserted as the whole array in one `same`, so neither row can be satisfied by the other.
	 */
	public function testEachRulesFindingsAndLandedEditsAreTallied(): Void {
		#if (sys || nodejs)
		final dir: String = pairDir(MAIN);
		if (skipWithoutHaxe(dir)) return;
		final result: FixVerifyResult = verifyPair(dir, MAIN);
		Assert.same([
			{
				rule: 'avoid-dynamic',
				file: '$dir/Main.hx',
				findings: 1,
				edits: 1
			},
			{
				rule: 'avoid-dynamic',
				file: '$dir/Other.hx',
				findings: 1,
				edits: 0
			}
		], result.tallies);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A source the WRITER will not settle on is not this check's decline, and gets no tally at all.
	 *
	 * `verifyEntry` reaches `canonicalize` before anything else, and with `reformat = false` that
	 * REFUSES a source which is not already the writer's fixed point: nothing is spliced, nothing is
	 * typechecked, and nothing whatever is learned about the check. On a tree nobody has run `fmt`
	 * over, that is the common answer rather than the exceptional one.
	 *
	 * A tally row for it would be `edits: 0`, which the caller's ledger reads as a DECLINE — and
	 * since no `declined` / `reverted` entry exists to quote, the run then printed `its fix was
	 * called for these findings and returned no edit` against a check it never asked. So the verdict
	 * carries its own constructor now and this row is the one that is never pushed.
	 *
	 * Asserted against the covered file's row in the same array, so a run that tallied NOTHING would
	 * fail it too.
	 */
	public function testADriftedSourceIsNotTalliedAtAll(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('fixverdrift', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'Other.hx', source: DRIFTED },
			{ name: 'check.hxml', source: HXML }
		]);
		if (skipWithoutHaxe(dir)) return;
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/Main.hx', source: MAIN },
			{ file: '$dir/Other.hx', source: DRIFTED }
		];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new AvoidDynamic()],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		Assert.same([
			{
				rule: 'avoid-dynamic',
				file: '$dir/Main.hx',
				findings: 1,
				edits: 1
			}
		], result.tallies, 'the drifted file contributes no row, the canonical one still does');
		Assert.equals(0, result.declined.length, 'and it is not a decline either — no candidate was ever produced');
		Assert.equals(DRIFTED, File.getContent('$dir/Other.hx'), 'the drifted file is byte-identical');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Direction 6: two files the oracle BOTH compiles, whose
	 * `avoid-dynamic` shapes differ only in which `#if` branch they sit in.
	 *
	 * A branch the arm's defines exclude is skipped at lex time, so a candidate written there
	 * cannot fail the typecheck whatever it did — the same vacuity as an uncompiled file, one
	 * level down, and `covers` answers TRUE for both files. Asserted as a PAIR in one run so
	 * neither half can be satisfied alone: a gate that refused everything would lose the applied
	 * narrowing, and one that refused nothing would lose the decline.
	 */
	public function testAnExcludedBranchIsDeclinedWhileItsLiveSiblingApplies(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('fixverregion', [
			{ name: 'Main.hx', source: REGION_MAIN },
			{ name: 'Live.hx', source: LIVE },
			{ name: 'Dead.hx', source: DEAD },
			{ name: 'check.hxml', source: REGION_HXML }
		]);
		if (skipWithoutHaxe(dir)) return;
		final files: Array<{ file: String, source: String }> = [
			{ file: '$dir/Live.hx', source: LIVE },
			{ file: '$dir/Dead.hx', source: DEAD }
		];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new AvoidDynamic()],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		Assert.same(['$dir/Live.hx'], result.applied, 'the live branch is verified and applied');
		Assert.equals(1, result.declined.length, 'the excluded branch yields exactly one decline');
		Assert.equals('$dir/Dead.hx', result.declined[0].file);
		Assert.isTrue(
			result.declined[0].reason.indexOf('`#else` of `#if regionon`') != -1,
			'and the reason NAMES the branch rather than blaming the file: got ${result.declined[0].reason}'
		);
		Assert.equals(DEAD, File.getContent('$dir/Dead.hx'), 'nothing was written into the excluded branch');
		Assert.isTrue(
			File.getContent('$dir/Live.hx').indexOf('var x:Live = a;\n\t\tvar y:Live = x;') != -1,
			'and the live branch carries the narrowing'
		);
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
