package unit.dev;

import dev.GateArms;
import devkit.Command;
import devkit.Lease;

using StringTools;
using Lambda;

/** What the slice gate's pool asks fit what its rows were measured to use (`exec-ledger`, gate phase). */
class GateRowFitTest extends utest.Test {

	/**
	 * A wide kill run asks for no more threads than the cap its readings in the ledger fit; a narrow one asks for its tracks.
	 */
	@:pin('guard')
	public function testTheArmsAskStopsAtWhatAKillRunWasMeasuredToUse(): Void {
		utest.Assert.isTrue(GateArms.armsAsk(19) <= 3, 'a wide kill run asks for ${GateArms.armsAsk(19)} threads');
		utest.Assert.equals(1, GateArms.armsAsk(1));
	}

	/**
	 * The arms plan runs before any row, in the gate's own process: under a pool of its own each command of it takes a one-thread
	 * lease queued ahead of the run's others, and under a lease the caller holds, or none, it runs as it is.
	 */
	@:pin('control')
	@:killer('M-GATE-PLAN-RUNS-UNLEASED')
	public function testEachCommandOfThePlanTakesAOneThreadLeaseUnderAPool(): Void {
		final command: Command = Command.of(['hxq', 'graph']);
		final own: Array<String> = GateArms.planLease(Own('/p/scripts/wf-run', 10), '/w/SLICE')(command).argv;
		utest.Assert.equals('1', own[own.indexOf('--threads') + 1], 'one thread: $own');
		utest.Assert.isTrue(own.exists(arg -> arg.startsWith('--priority=')), 'ahead of the run\'s other leases: $own');
		utest.Assert.isTrue(own.contains('slice-gate SLICE arms plan'), 'labelled in the pool: $own');
		utest.Assert.same(['hxq', 'graph'], GateArms.planLease(Held(4), '/w/SLICE')(command).argv);
		utest.Assert.same(['hxq', 'graph'], GateArms.planLease(Unpooled, '/w/SLICE')(command).argv);
		utest.Assert.equals(1, GateArms.planThreads(Own('/p/scripts/wf-run', 10)));
		utest.Assert.isNull(GateArms.planThreads(Held(4)));
		utest.Assert.isNull(GateArms.planThreads(Unpooled));
	}

}
