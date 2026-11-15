package unit.dev;

import dev.BatteryBranch;
import dev.BatteryPlan;
import devkit.Args;
import devkit.Command;
import devkit.Summary.Step;
import utest.Assert;
import utest.Test;

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

}
