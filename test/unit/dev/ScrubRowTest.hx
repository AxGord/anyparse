package unit.dev;

import dev.PrivateDeclaration;
import dev.ScrubRow;
import devkit.Result;
import devkit.Summary.Outcome;

/** The `scrub` row of the slice gate: what it says of the tree scan and the range scan of `scrub-guard`. */
@:nullSafety(Strict)
final class ScrubRowTest extends Test {

	private static final UNCONFIGURED: String = 'scrub-guard: no token list, nothing checked\n';

	private var _declared: String = '';

	public function setup(): Void {
		_declared = Sys.getEnv(PrivateDeclaration.VAR) ?? '';
		Sys.putEnv(PrivateDeclaration.VAR, '');
	}

	public function teardown(): Void {
		Sys.putEnv(PrivateDeclaration.VAR, _declared);
	}

	@:pin('control')
	@:killer('M-SCRUB-ROW-UNCONFIGURED-FIRST')
	public function testAFailingRangeIsFailedEvenWhenTheTreeScanHadNoList(): Void {
		Assert.isTrue(ScrubRow.verdict(run(0, UNCONFIGURED), run(1, '')).match(Failed(_)));
		Assert.isTrue(ScrubRow.verdict(run(1, ''), run(0, '')).match(Failed(_)));
	}

	public function testAFailingRangeIsFailedEvenWhenNothingPrivateIsDeclared(): Void {
		Sys.putEnv(PrivateDeclaration.VAR, 'none');
		Assert.isTrue(ScrubRow.verdict(run(0, UNCONFIGURED), run(1, '')).match(Failed(_)));
	}

	public function testACleanPairIsSkippedWithoutAListWhenNothingPrivateIsDeclared(): Void {
		Sys.putEnv(PrivateDeclaration.VAR, 'none');
		Assert.same(Outcome.Skipped(PrivateDeclaration.NOTE), ScrubRow.verdict(run(0, UNCONFIGURED), run(0, '')));
		Assert.isTrue(ScrubRow.verdict(run(0, 'scrub-guard: 0 match(es)\n'), run(0, '')).match(Passed));
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
