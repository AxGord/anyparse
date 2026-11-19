package unit.dev;

import dev.Battery;
import dev.BatteryBranch;
import dev.BatteryPlan;
import dev.Binaries;
import devkit.Args;
import devkit.Command;
import devkit.Summary.Step;

/** `dev.BatteryBranch`: a battery branch runs under time(1) on macOS, and each of its rows carries the threads it held. */
@:nullSafety(Strict)
final class BatteryBranchTest extends Test {

	@:pin('control')
	@:killer('M-BATTERY-BRANCH-UNMETERED')
	public function testABranchRunsUnderTime(): Void {
		final plan: BatteryPlan = {
			repo: '/repo',
			work: '/work',
			cache: '/cache',
			head: 'abc',
			shards: 1,
			quick: true,
			snapshot: false,
			allowBlast: false,
			allow: [],
			run: 'r',
			ownLease: false
		};
		final command: Command = BatteryBranch.command(plan, 'dev.js', 'plan.json', ['suite', 'corpus'], '/work/branch-suite.json');
		final tail: Array<String> = ['node', 'dev.js', 'battery', '--rows', 'suite,corpus', '--plan', 'plan.json'];
		if (Sys.systemName() == 'Mac' && sys.FileSystem.exists('/usr/bin/time')) {
			Assert.equals('/usr/bin/time', command.argv[0]);
			Assert.same(tail, command.argv.slice(command.argv.length - tail.length));
		} else {
			Assert.same(tail, command.argv);
		}
	}

	@:pin('control')
	@:killer('M-BATTERY-ROW-THREADS-DROPPED')
	public function testEachRowOfTheBranchCarriesItsThreads(): Void {
		final steps: Array<Step> = [
			for (name in ['suite', 'corpus', 'fmt']) {
				name: name,
				outcome: Passed,
				ms: 1,
				note: '',
				excerpt: []
			}
		];
		BatteryBranch.carryThreads(steps, ['suite', 'corpus'], 3);
		Assert.same([3, 3, null], steps.map(step -> step.threads));
		BatteryBranch.carryThreads(steps, ['fmt'], null);
		Assert.isNull(steps[2].threads);
	}

	@:pin('control')
	@:killer('M-BATTERY-LEDGER-OPTION-IGNORED')
	public function testTheLedgerOptionNamesTheFile(): Void {
		Assert.equals('/logs/battery.ledger', BatteryBranch.ledgerOf(new Args(['--quick', '--ledger', '/logs/battery.ledger'])));
		Assert.isNull(BatteryBranch.ledgerOf(new Args(['--quick'])));
	}

	/** A lease the battery's caller holds is recorded once, on the span; a branch's own lease is its own. */
	@:pin('control')
	@:killer('M-BATTERYBRANCH-LEASE-PER-BRANCH')
	public function testASharedLeaseIsNotCarriedByEveryBranch(): Void {
		Assert.isNull(BatteryBranch.branchHeld(false, 8));
		Assert.equals(2, BatteryBranch.branchHeld(true, 2));
		Assert.isNull(BatteryBranch.branchHeld(true, null));
	}

	@:pin('control')
	@:killer('M-BATTERYBRANCH-SPAN-LEASE')
	public function testASharedLeaseIsRecordedOnTheSpan(): Void {
		Assert.equals(8, BatteryBranch.spanHeld(false, 8));
		Assert.isNull(BatteryBranch.spanHeld(true, 2));
		Assert.isNull(BatteryBranch.spanHeld(false, null));
	}

	/** Under its own lease the suite runs as many shards as the lease granted, whatever was planned. */
	@:pin('control')
	@:killer('M-BATTERYBRANCH-OWN-LEASE-SHARDS')
	public function testTheSuiteOfAnOwnLeaseTakesTheShardsItWasGranted(): Void {
		Assert.equals(6, BatteryBranch.suiteShards(true, true, 6, 2));
		Assert.equals(2, BatteryBranch.suiteShards(true, true, null, 2));
		Assert.equals(2, BatteryBranch.suiteShards(false, true, 6, 2));
	}

	/** A full battery keeps its one shard, the monolith run itself, so a lease-free land adds no second monolith run. */
	@:pin('control')
	@:killer('M-BATTERYBRANCH-FULL-SHARDS')
	public function testAFullSuiteUnderAnOwnLeaseRunsOnOneShard(): Void {
		Assert.equals(1, BatteryBranch.suiteShards(true, false, 6, 4));
		Assert.equals(4, BatteryBranch.suiteShards(false, false, 6, 4));
	}

	/** The quick suite's branch is the flexible one; a full run's holds one thread, as its one shard needs no more. */
	@:pin('control')
	@:killer('M-BATTERY-FULL-SUITE-HOLDS-ONE')
	public function testTheSuiteBranchHoldsOneThreadOnAFullRun(): Void {
		Assert.isNull(Battery.branchThreads(['suite', 'corpus'], true));
		Assert.equals(1, Battery.branchThreads(['suite', 'corpus'], false));
		Assert.equals(2, Battery.branchThreads(['oracle', 'lint'], false));
		Assert.equals(1, Battery.branchThreads(['fmt'], true));
	}

	/** A battery runs no kit process its pool lease does not hold: the kit row runs on the threads its branch leases. */
	@:pin('control')
	@:killer('M-BATTERY-KITS-THREADS-UNHELD')
	public function testTheKitProbesRunOnTheThreadsTheirBranchHolds(): Void {
		final probes: Array<String> = Battery.branches().filter(rows -> rows.contains('kit probes'))[0] ?? [];
		for (quick in [false, true])
			Assert.equals(Battery.branchThreads(probes, quick), BatteryBranch.kitThreads(Battery.branches(), quick));
		Assert.equals(1, BatteryBranch.kitThreads(Battery.branches(), false), 'the probes branch holds one thread');
		Assert.equals(2, BatteryBranch.kitThreads([['oracle', 'lint', 'kit probes']], false), 'kits in the oracle branch run on its two');
	}

	/** The build step carries what the build held only under the battery's own lease: under a held one the span carries it, once. */
	@:pin('control')
	@:killer('M-BATTERYBRANCH-LEASE-PER-BRANCH')
	public function testTheBuildOfASharedLeaseHoldsNoThreadsOfItsOwn(): Void {
		Assert.isNull(BatteryBranch.branchHeld(false, Binaries.heldBy(Held(12), 4)));
		Assert.equals(Binaries.WIDTH, BatteryBranch.branchHeld(true, Binaries.heldBy(Own('/p/scripts/wf-run', 12), 4)));
	}

}
