package unit.check;

#if (sys || nodejs)
import sys.io.File;

using StringTools;
#end

import anyparse.check.CompilerOracle;
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * The FOLLOW-UP convergence round of `apq lint --fix`, and why it needs a compiler oracle to
 * exist at all.
 *
 * `prefer-inline` is a `RiskyFix`. WITHOUT an oracle it is `OracleRelaxable` and runs inside the
 * safe fixed-point loop, where every cascade it starts converges - which is what
 * `LintFixFixedPointCliTest.testPreferInlineFullScopeAcrossPasses` covers, and why that test
 * never caught this. WITH an oracle the same rule leaves the safe set for `verifyRiskyFixes`,
 * which writes AFTER the loop has already converged: marking `thin` inline moves it under
 * `member-order`'s within-rank sub-order (inline leads its rank), and nothing re-entered the loop
 * to re-sort it. The run printed a success line while leaving a `member-order` finding IT had
 * just created, and a byte-identical second invocation of the same command then fixed it.
 *
 * Measured on the Pony corpus (867 files, oracle configured): the second invocation fixed 5 more
 * issues in 3 more files; with the follow-up round the first invocation reaches that same tree
 * byte for byte, and a second invocation fixes 0.
 */
@:nullSafety(Strict)
final class LintFixFollowUpRoundTest extends Test {

	#if (sys || nodejs)
	/**
	 * `thin` is a `prefer-inline` candidate (a bare field read) and is NOT the first private
	 * instance method, so inlining it moves it - `wrap` is a two-statement body and no candidate.
	 * Everything else is already in canonical order, so `member-order` is silent until the risky
	 * fix lands. Byte-canonical under default writer opts, or the `--fix` canonical gate skips it.
	 */
	private static final CASCADE: String = 'class Main {\n\n\tprivate var _n:Int = 3;\n\n\tpublic function new() {}\n\n'
		+ '\tprivate function wrap(n:Int):Int {\n\t\tif (n > 0) return n + 1;\n\t\treturn n - 1;\n\t}\n\n'
		+ '\tprivate function thin():Int {\n\t\treturn _n;\n\t}\n\n\tprivate static function main():Void {\n'
		+ '\t\tfinal c:Main = new Main();\n\t\ttrace(c.wrap(1));\n\t\ttrace(c.thin());\n\t}\n\n}\n';

	/** The oracle probe fixture - a module that typechecks on any host with a working `haxe`. */
	private static final TRIVIAL: String = 'class Main {\n\n\tprivate static function main():Void {}\n\n}\n';

	private static final HXML: String = '-cp .\n-main Main\n';
	#end

	public function testRiskyFixExposureConvergesInOneInvocation(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixfollowup', [
			{ name: 'Main.hx', source: CASCADE },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: '{"compilerOracle":"check.hxml"}' }
		]);
		final path: String = '$dir/Main.hx';
		Assert.equals(0, Cli.run(['lint', '--rule', 'prefer-inline', '--rule', 'member-order', '--fix', path]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		// ONE substring spanning both halves: asserting them separately lets the ordering half pass
		// vacuously when the risky fix never lands (`indexOf` answers -1, which is less than
		// everything), and utest's `Assert` does not throw, so the earlier presence check cannot
		// stop it.
		Assert.isTrue(
			out.indexOf('private inline function thin():Int {\n\t\treturn _n;\n\t}\n\n\tprivate function wrap') != -1,
			'the risky inline landed AND the member-order finding it exposed was fixed in the same invocation: $out'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The follow-up round reads `entry.source`, so every phase that WRITES must keep it in step.
	 * `verifyRiskyFixes` did (`FixVerifier.verifyEntry` assigns it); `applyOracleAssistedFixes` did
	 * not — it wrote the batch to disk and left memory holding the PRE-annotation bytes. Nothing read
	 * them afterwards, so the drift was invisible until this round existed; then a file taking both a
	 * risky `inline` and an oracle-assisted `:Int` was re-linted from the stale copy and written back
	 * over the verified edit, and the return type was silently gone. `--fix` still counted it.
	 *
	 * Same fixture as the test above minus `thin`'s return type, so `explicit-type`'s oracle-assisted
	 * pass supplies it and all three phases land on ONE file.
	 */
	public function testOracleAssistedEditSurvivesTheFollowUpRound(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixfollowupoa', [
			{ name: 'Main.hx', source: CASCADE.replace('function thin():Int {', 'function thin() {') },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: '{"compilerOracle":"check.hxml"}' }
		]);
		final path: String = '$dir/Main.hx';
		Assert.equals(0, Cli.run([
			'lint',
			'--rule',
			'prefer-inline',
			'--rule',
			'member-order',
			'--rule',
			'explicit-type',
			'--fix',
			path
		]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		Assert.isTrue(
			out.indexOf('private inline function thin():Int {\n\t\treturn _n;\n\t}\n\n\tprivate function wrap') != -1,
			'the risky inline, the oracle-assisted return type and the reorder they exposed all survive: $out'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** Whether a real `haxe` on PATH typechecks a trivial fixture - the test above proves nothing without one. */
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('followupprobe', [
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
