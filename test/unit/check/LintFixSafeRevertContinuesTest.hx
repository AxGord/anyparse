package unit.check;

#if (sys || nodejs)
import sys.io.File;

using StringTools;
#end

import anyparse.check.oracle.CompilerOracle;
import anyparse.query.Cli;
import unit.cli.CliFixture;

/**
 * A safe fix the compiler rejects costs ITS file, not the rest of the run.
 *
 * The safe-pass net narrows a failing wave to the files the compiler blames and confirms the rest green. The run then used
 * to return before the risky and oracle-assisted phases ran at all, although the tree they would judge was exactly the
 * one the narrowing had just proven green — so one bad safe edit silently cancelled every verified fix of the run (on
 * anyparse itself: 13 `redundant-import` and 7 `explicit-local-type` edits never landed behind one reverted safe file).
 *
 * The broken safe edit here is the project's own doing: an idiom declares `Point.setTo` the equivalent of writing `x`
 * and `y`, and `setTo` takes `String`s — the rule trusts the declaration (that is what a declaration is for), the compiler
 * does not. The risky edit (`prefer-inline` on `thin`) and the oracle-assisted one (`explicit-type`'s `:Int` on the same
 * method) live in another file the compiler never blames.
 */
@:nullSafety(Strict)
final class LintFixSafeRevertContinuesTest extends Test {

	#if (sys || nodejs)
	private static final POINT: String = 'package geom;\n\nclass Point {\n\n\tpublic var x:Float = 0;\n\tpublic var y:Float = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tpublic function setTo(xa:String, ya:String):Void {}\n\n}\n';
	private static final MAIN: String = 'import geom.Point;\n\nclass Main {\n\n\tprivate static function main():Void {\n'
		+ '\t\tfinal p:Point = new Point();\n\t\tp.x = 4;\n\t\tp.y = 3;\n\t\ttrace(p.x);\n\t\ttrace(new Other().run());\n\t}\n\n}\n';
	private static final THIRD: String = 'class Third {\n\n\tpublic static function either(a:Bool, b:Bool):Bool {\n'
		+ '\t\tif (a) return true;\n\t\tif (b) return true;\n\t\treturn false;\n\t}\n\n}\n';
	private static final OTHER: String = 'class Other {\n\n\tprivate var _n:Int = 3;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function run():Int {\n\t\treturn thin();\n\t}\n\n\tprivate function thin() {\n\t\treturn _n;\n\t}\n\n}\n';
	private static final CONFIG: String = '{"compilerOracle":"check.hxml","resolutionRoots":["."],"rules":{"prefer-api-idiom":'
		+ '{"idioms":[{"type":"geom.Point","fields":["x","y"],"method":"setTo"}]}}}';

	/** The oracle probe fixture - a module that typechecks on any host with a working `haxe`. */
	private static final TRIVIAL: String = 'class Main {\n\n\tprivate static function main():Void {}\n\n}\n';
	private static final HXML: String = '-cp .\n-main Main\n';
	#end

	/**
	 * `Main.hx` goes back to its bytes, `Other.hx` still takes the risky `inline` and the oracle-assisted return type, the
	 * notice names the reverted file, and the run still exits non-zero: a revert is a fixer defect the caller must see.
	 */
	@:pin('control')
	@:killer('M-SAFE-REVERT-ABORTS', 'M-SAFE-REVERT-EDITS-COUNTED', 'M-SAFE-REVERT-FILES-COUNTED', 'M-SAFE-REVERT-EXIT-OK',
		'M-SAFE-REVERT-UNSAID')
	public function testRiskyAndOracleAssistedFixesLandAfterAWholeWaveSafeRevert(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeTree('saferevertgo', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'Other.hx', source: OTHER },
			{ name: 'geom/Point.hx', source: POINT },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: CONFIG }
		]);
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run([
			'lint',
			'--rule',
			'prefer-api-idiom',
			'--rule',
			'prefer-inline',
			'--rule',
			'explicit-type',
			'--fix',
			'$dir/Main.hx',
			'$dir/Other.hx'
		]));
		Assert.equals(MAIN, File.getContent('$dir/Main.hx'), 'the safe edit the compiler rejected is reverted: $err');
		Assert.isTrue(err.indexOf('REVERTED all 1 file(s)') >= 0, 'the notice says what went back: $err');
		Assert.isTrue(err.indexOf('the risky and oracle-assisted phases go on') >= 0, 'and that the run goes on: $err');
		final other: String = File.getContent('$dir/Other.hx');
		Assert.isTrue(
			other.indexOf('private inline function thin():Int {') >= 0,
			'the risky inline and the oracle-assisted return type still land in the file the compiler never blamed: $other\n$err'
		);
		Assert.isTrue(err.indexOf('safe-pass REVERTED 1 file(s)') >= 0, 'the summary line carries the revert: $err');
		// two risky inlines and one return type; the reverted idiom call is neither an edit nor a changed file
		Assert.isTrue(err.indexOf('apq lint --fix: 3 edit(s) in 1 file(s) over') >= 0, 'the count leaves the reverted edit out: $err');
		Assert.equals(1, code, 'a revert still fails the run');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The narrowed arm: the wave also holds a GOOD safe edit (`Third.hx`'s guard chain), so the net reverts the blamed
	 * `Main.hx` alone, confirms the rest green and keeps it; the risky and oracle-assisted edits still land in `Other.hx`, and
	 * the summary counts the kept edit but not the reverted one.
	 */
	@:pin('control')
	@:killer('M-SAFE-REVERT-ABORTS', 'M-SAFE-REVERT-EDITS-COUNTED', 'M-SAFE-REVERT-FILES-COUNTED', 'M-SAFE-REVERT-EXIT-OK')
	public function testANarrowedRevertKeepsTheGoodSafeEditAndTheVerifiedOnes(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeTree('saferevertnarrow', [
			{
				name: 'Main.hx',
				source: MAIN.replace('trace(new Other().run());', 'trace(new Other().run());\n\t\ttrace(Third.either(true, false));')
			},
			{ name: 'Other.hx', source: OTHER },
			{ name: 'Third.hx', source: THIRD },
			{ name: 'geom/Point.hx', source: POINT },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: CONFIG }
		]);
		final main: String = File.getContent('$dir/Main.hx');
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run([
			'lint',
			'--rule',
			'prefer-api-idiom',
			'--rule',
			'simplify-boolean-return-chain',
			'--rule',
			'prefer-inline',
			'--rule',
			'explicit-type',
			'--fix',
			'$dir/Main.hx',
			'$dir/Other.hx',
			'$dir/Third.hx'
		]));
		Assert.equals(main, File.getContent('$dir/Main.hx'), 'the blamed file is reverted: $err');
		Assert.isTrue(err.indexOf('REVERTED 1 of 2 file(s), KEPT the other 1') >= 0, 'the narrowed notice: $err');
		Assert.isTrue(File.getContent('$dir/Third.hx').indexOf('return a || b;') >= 0, 'the good safe edit is kept: $err');
		Assert.isTrue(
			File.getContent('$dir/Other.hx').indexOf('private inline function thin():Int {') >= 0, 'the verified edits land: $err'
		);
		Assert.isTrue(err.indexOf('safe-pass REVERTED 1 file(s)') >= 0, err);
		// the kept guard chain, three risky inlines and one return type, in Third and Other
		Assert.isTrue(err.indexOf('apq lint --fix: 5 edit(s) in 2 file(s) over') >= 0, 'the count leaves the reverted edit out: $err');
		Assert.equals(1, code, 'a revert still fails the run');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** Whether a real `haxe` on PATH typechecks a trivial fixture - the test above proves nothing without one. */
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('saferevertprobe', [
			{ name: 'Main.hx', source: TRIVIAL },
			{ name: 'check.hxml', source: HXML }
		]);
		final outcome: OracleOutcome = CompilerOracle.typecheck('check.hxml', dir);
		CliFixture.removeDir(dir);
		return switch outcome {
			case Confirmed: true;
			case _: false;
		};
	}
	#end

}
