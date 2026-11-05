package unit.dev;

import dev.ScrubRow;
import devkit.Result;
import utest.Assert;
import utest.Test;

/** The `scrub` row of the slice gate: what it says of the tree scan and the range scan of `scrub-guard`. */
@:nullSafety(Strict)
final class ScrubRowTest extends Test {

	private static inline final UNCONFIGURED: String = 'scrub-guard: no token list, nothing checked\n';

	@:pin('control')
	@:killer('M-SCRUB-ROW-UNCONFIGURED-FIRST')
	public function testAFailingRangeIsFailedEvenWhenTheTreeScanHadNoList(): Void {
		Assert.isTrue(ScrubRow.verdict(run(0, UNCONFIGURED), run(1, '')).match(Failed(_)));
		Assert.isTrue(ScrubRow.verdict(run(1, ''), run(0, '')).match(Failed(_)));
	}

	public function testACleanPairIsNotRunWithoutAListAndPassedWithOne(): Void {
		Assert.isTrue(ScrubRow.verdict(run(0, UNCONFIGURED), run(0, '')).match(NotRun(_)));
		Assert.isTrue(ScrubRow.verdict(run(0, 'scrub-guard: 0 match(es)\n'), run(0, '')).match(Passed));
	}

	private static function run(status: Int, err: String): Result {
		return new Result('scrub-guard', {
			status: status,
			out: '',
			err: err,
			failure: '',
			overflowed: false
		});
	}

}
