package unit.devkit;

import dev.BaseLint;
import dev.BaseSuite;
import dev.SliceGate;
import devkit.Branches;
import devkit.Command;
import devkit.Lease.LeaseMode;

/** The heavy branch of a slice gate (the suite) asks the pool for threads by the budget, not by what the light branches leave. */
@:nullSafety(Strict)
final class BranchesHeavyShareTest extends Test {

	/** A gate whose every light row runs, on a pool of fourteen: its light branches lease more than the budget. */
	private static final BUSY: GateDemand = {
		recording: false,
		infra: 0,
		touchedHx: true,
		jvmMoved: true,
		kitsMoved: true,
		typerMoved: true,
		ruleInfra: 3
	};

	@:pin('control')
	@:killer('M-BRANCHES-HEAVY-SHARE-UNCAPPED')
	public function testTheSuiteAsksUpToTheFanOutKneeBesideBusyLightBranches(): Void {
		Assert.equals('2-4', suiteAsk(14), 'the suite takes up to the knee whatever the light branches lease');
	}

	@:pin('control')
	@:killer('M-BRANCHES-HEAVY-SHARE-UNSPLIT')
	public function testASmallPoolLeavesTheSuiteOneThread(): Void {
		Assert.equals('1', suiteAsk(3), 'two heavy branches on three threads each take one');
	}

	/** The `--threads` value the suite branch of a busy gate passes to the pool of `budget` threads. */
	private static function suiteAsk(budget: Int): String {
		final branches: Array<Array<String>> = SliceGate.GATE_BRANCHES.concat([[BaseSuite.ROW], [BaseLint.ROW]]);
		final pool: LeaseMode = Own('/p/scripts/wf-run', budget);
		final argv: Array<String> = Branches.leased(
			pool, branches, rows -> SliceGate.demandOf(BUSY, rows), rows -> Command.of(['node', rows[0]]), 'gate'
		)(['suite', 'corpus']).argv;
		return argv[argv.indexOf('--threads') + 1];
	}

}
