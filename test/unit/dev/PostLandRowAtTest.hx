package unit.dev;

import dev.PostLand;
import devkit.ExecLedger;

/**
 * A post-land phase's ledger row carries the time its run started, so `dev exec-ledger --since` windows it like a land row.
 */
@:nullSafety(Strict)
final class PostLandRowAtTest extends Test {

	@:pin('control')
	@:killer('M-POSTLAND-PHASE-ROW-AT')
	public function testAPhaseRowCarriesTheTimeItStarted(): Void {
		TempDir.with(dir -> {
			final before: Float = Date.now().getTime();
			Assert.isTrue(PostLand.timed(dir.path, 'lint', _ -> Passed).match(Passed));
			final after: Float = Date.now().getTime();
			final rows: Array<LedgerRow> = ExecLedger.under(dir.path).rows();
			Assert.equals(1, rows.length);
			final at: Null<Float> = rows[0].at;
			Assert.notNull(at);
			if (at != null) Assert.isTrue(at >= Math.floor(before) - 1 && at <= after + 1);
		});
	}

}
