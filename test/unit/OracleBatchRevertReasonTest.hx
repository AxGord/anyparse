package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * The four rollback CAUSES `Cli.verifyOracleBatch` distinguishes, each driven by canned oracle
 * verdicts. They are environment-shaped — a compiler that will not launch, an error text naming
 * no candidate, a batch that never settles — so no fixture can stage them against a real haxe;
 * the batch takes its oracle as a parameter for exactly this, as `TypeOracle` does elsewhere.
 *
 * Every scenario also asserts the DISK: a reverted candidate must hold its `before` text and an
 * applied one its `after`, because a verdict that reports the right reason while leaving the
 * wrong bytes behind is the failure that matters.
 */
@:access(anyparse.query.Cli)
class OracleBatchRevertReasonTest extends Test {

	#if (sys || nodejs)
	/** Canned verdicts, consumed one per typecheck; the last one repeats once the list runs out. */
	private static function canned(outcomes: Array<OracleOutcome>): (String, Null<String>) -> OracleOutcome {
		var at: Int = 0;
		return (_, _) -> {
			final i: Int = at < outcomes.length ? at : outcomes.length - 1;
			at++;
			return outcomes[i];
		};
	}

	/** `n` candidates named `f0.hx`…, each rewritten from `before <k>` to `after <k>`. */
	private static function batch(dir: String, n: Int): Array<{ file: String, before: String, after: String }> {
		return [
			for (k in 0...n) { file: '$dir/f$k.hx', before: 'before $k\n', after: 'after $k\n' }
		];
	}

	private static function makeDir(n: Int): String {
		return CliFixture.writeDir('orbatch', [for (k in 0...n) { name: 'f$k.hx', source: 'before $k\n' }]);
	}
	#end

	public function new() {
		super();
	}

	/** A rejection that NAMES a candidate reverts that one and keeps the rest once the batch settles. */
	public function testCompilerRejectedRevertsTheNamedFile(): Void {
		#if (sys || nodejs)
		final dir: String = makeDir(3);
		final candidates = batch(dir, 3);
		final result = Cli.verifyOracleBatch(candidates, 'check.hxml', dir, canned([
			Rejected('$dir/f1.hx:1: characters 1-2 : boom'),
			Confirmed
		]));
		Assert.equals('compiler rejected', result.reason);
		Assert.same(['$dir/f1.hx'], result.reverted);
		Assert.equals(2, result.applied.length);
		Assert.equals('before 1\n', File.getContent('$dir/f1.hx'));
		Assert.equals('after 0\n', File.getContent('$dir/f0.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A rejection naming NO candidate cannot be narrowed, so the whole batch rolls back. */
	public function testRejectionNamingNoCandidateRevertsAll(): Void {
		#if (sys || nodejs)
		final dir: String = makeDir(2);
		final result = Cli.verifyOracleBatch(
			batch(dir, 2), 'check.hxml', dir, canned([Rejected('some/other/File.hx:1: characters 1-2 : boom')])
		);
		Assert.equals('compiler rejected, no file named', result.reason);
		Assert.equals(2, result.reverted.length);
		Assert.equals(0, result.applied.length);
		Assert.equals('before 0\n', File.getContent('$dir/f0.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A compiler that never ran says nothing about the edits, so none of them may stand. */
	public function testUnavailableOracleRevertsAll(): Void {
		#if (sys || nodejs)
		final dir: String = makeDir(2);
		final result = Cli.verifyOracleBatch(batch(dir, 2), 'check.hxml', dir, canned([Unavailable('no haxe')]));
		Assert.equals('oracle unavailable', result.reason);
		Assert.equals(2, result.reverted.length);
		Assert.equals('before 1\n', File.getContent('$dir/f1.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One fresh culprit per pass outlasts the pass budget; the batch gives up and rolls everything back. */
	public function testNonConvergentBatchRevertsAll(): Void {
		#if (sys || nodejs)
		final dir: String = makeDir(8);
		final result = Cli.verifyOracleBatch(batch(dir, 8), 'check.hxml', dir, canned([
			for (k in 0...8) Rejected('$dir/f$k.hx:1: characters 1-2 : boom')
		]));
		Assert.equals('not converged in 6 passes', result.reason);
		Assert.equals(8, result.reverted.length);
		Assert.equals(0, result.applied.length);
		Assert.equals('before 7\n', File.getContent('$dir/f7.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
