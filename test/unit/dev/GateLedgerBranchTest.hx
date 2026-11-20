package unit.dev;

import dev.GateReuse;
import devkit.ExecLedger;
import devkit.Summary.Step;

/** A gate's rows are filed under the real branches of `SliceGate.GATE_BRANCHES`, not under the last earlier row with a lease. */
@:nullSafety(Strict)
final class GateLedgerBranchTest extends Test {

	@:pin('control')
	@:killer('M-EXECLEDGER-GATE-BRANCHES')
	public function testAGateRowsFollowTheirRealBranches(): Void {
		final first: Array<String> = ['suite', 'lists', 'lint', 'jvm', 'infra4'];
		final names: Array<String> = ['suite', 'lists', 'corpus', 'fmt', 'lint', 'jvm', 'infra4', 'scrub', 'artifacts'];
		final steps: Array<Step> = names.map(name -> step(name, first.contains(name)));
		final rows: Array<LedgerRow> = ExecLedger.decodeAll(GateReuse.timingsOf(steps, 7));
		final branches: Map<String, String> = [ for (row in rows) row.row => row.branch ?? row.row ];
		Assert.equals('suite', branches['corpus']);
		Assert.equals('lists', branches['fmt']);
		Assert.equals('lists', branches['scrub']);
		Assert.equals('lists', branches['artifacts']);
		Assert.equals('infra4', branches['infra4']);
	}

	private static function step(name: String, leading: Bool): Step {
		final out: Step = {
			name: name,
			outcome: Passed,
			ms: 1000,
			note: '',
			excerpt: [],
			threads: 1
		};
		if (leading) {
			out.wait = 10;
			out.cpu = 5;
		}
		return out;
	}

}
