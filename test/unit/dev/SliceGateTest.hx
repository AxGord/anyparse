package unit.dev;

import dev.Probe;
import dev.SliceGate;
import devkit.Branches;
import devkit.Command;
import devkit.Lease.LeaseMode;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/** `dev.SliceGate`: where a gate's and a branch's threads come from, and what its branches hold between them. */
@:nullSafety(Strict)
final class SliceGateTest extends Test {

	/** A `wf-run` that answers its status with a budget of eight and runs any other command as it is. */
	private static inline final FAKE_WF_RUN: String = '#!/bin/sh\nif [ "$$1" = "--status" ]; then\n'
		+ 'echo "pool /p: budget 8, held 0, load 0.0 (external 0.0, threshold 2)"; exit 0\nfi\nexec "$$@"\n';

	/**
	 * A `--rows` branch runs inside the lease its gate took for it and never asks the pool itself, even inside a workflow
	 * whose pool it could reach: a branch queued for threads its gate already holds waits behind its own gate.
	 */
	@:pin('control')
	@:killer('M-GATE-BRANCH-OWN-LEASE')
	public function testABranchStaysUnpooledInsideAWorkflow(): Void {
		TempDir.with(dir -> {
			final root: String = dir.file('plugin');
			FileSystem.createDirectory(Path.join([root, 'scripts']));
			final wfRun: String = Path.join([root, 'scripts/wf-run']);
			sys.io.File.saveContent(wfRun, FAKE_WF_RUN);
			js.Syntax.code("require('fs').chmodSync({0}, 0o755)", wfRun);
			final saved: Map<String, String> = [for (v in ['WF_PLUGIN_ROOT', 'WF_THREADS']) v => Sys.getEnv(v) ?? ''];
			var branch: LeaseMode = Unpooled;
			var gate: LeaseMode = Unpooled;
			CliFixture.always(() -> for (v => value in saved) Sys.putEnv(v, value), () -> {
				Sys.putEnv('WF_PLUGIN_ROOT', root);
				Sys.putEnv('WF_THREADS', '');
				branch = SliceGate.leaseModeOf('suite,corpus,arms');
				gate = SliceGate.leaseModeOf(null);
			});
			Assert.isTrue(branch.match(Unpooled), 'the branch: $branch');
			Assert.isTrue(gate.match(Own(_, 8)), 'the gate: $gate');
		});
	}

	/**
	 * What every branch of a gate run but the heavy one holds is one thread for the short rows, the kits row's, two for the lint row when a
	 * `.hx` file moved, one for the jvm probe when it runs, and the base tree's lint plus one per infra tree when rule code
	 * moved.
	 */
	@:pin('control')
	@:killer('M-GATE-DEMAND-LISTS-NONE')
	public function testTheLightBranchesOfAGateHoldWhatItsRowsRun(): Void {
		for (touchedHx in [false, true]) for (jvmMoved in [false, true]) for (ruleInfra in [null, 0, 3]) {
			final facts: GateDemand = {
				recording: false,
				infra: 0,
				touchedHx: touchedHx,
				jvmMoved: jvmMoved,
				ruleInfra: ruleInfra
			};
			final expected: Int = 1
				+ Probe.GATE_THREADS
				+ (touchedHx ? 2 : 0)
				+ (jvmMoved ? 1 : 0)
				+ (ruleInfra == null ? 0 : 1 + ruleInfra);
			Assert.equals(expected, Branches.light(SliceGate.GATE_BRANCHES, rows -> SliceGate.demandOf(facts, rows)), '$facts');
		}
		Assert.isNull(SliceGate.demandOf({
			recording: false,
			infra: 0,
			touchedHx: true,
			jvmMoved: true,
			ruleInfra: 3
		}, ['suite']));
	}

	/**
	 * The arms row is a phase of its own after the other branches, and takes a lease of one thread up to `ARMS_THREADS`
	 * that goes back to the pool as it ends: a gate that held its whole lease for the arms starved every other build.
	 * Under a held lease it takes what that lease has, up to the same bound; without a pool, nothing.
	 */
	@:pin('guard')
	public function testTheArmsRowIsAPhaseOnALeaseOfItsOwn(): Void {
		Assert.isFalse(SliceGate.GATE_BRANCHES.exists(rows -> rows.contains('arms')), 'no branch of the main fan-out runs the arms');
		Assert.same([['arms']], SliceGate.ARMS_BRANCHES);
		final command: Command = Command.of(['node', 'arms']);
		final own: Array<String> = SliceGate.armsCommand(Own('/p/scripts/wf-run', 10), command, 'gate arms').argv;
		Assert.contains('1-${SliceGate.ARMS_THREADS}', own);
		Assert.isFalse(own.contains('10'), 'the pool budget is not what it asks for: $own');
		Assert.same(['node', 'arms'], SliceGate.armsCommand(Held(4), command, 'gate arms').argv);
		Assert.same(['node', 'arms'], SliceGate.armsCommand(Unpooled, command, 'gate arms').argv);
		Assert.equals(SliceGate.ARMS_THREADS, SliceGate.armsThreads(Held(4)));
		Assert.equals(1, SliceGate.armsThreads(Held(1)));
		Assert.isNull(SliceGate.armsThreads(Own('/p/scripts/wf-run', 10)));
		Assert.isNull(SliceGate.armsThreads(Unpooled));
	}

	/** A branch is the process that reads a waiver, so a waiver its gate did not hand over would never apply. */
	@:pin('control')
	@:killer('M-GATE-BRANCH-DROPS-WAIVER')
	public function testABranchIsHandedTheGatesArmWaivers(): Void {
		final args: Array<String> = SliceGate.branchArgs({
			tree: '/t',
			logs: '/l',
			baseline: false,
			frozen: [],
			infra: [],
			arms: [],
			allow: [],
			allowArms: ['M-A', 'M-B'],
			noArms: false,
			threads: null,
			run: 'r'
		}, ['arms'], null);
		Assert.isTrue(args.contains('--allow-arm=M-A') && args.contains('--allow-arm=M-B'), args.join(' '));
	}

	/**
	 * The fmt row is the project half and the cross-config half: a skipped cross half adds nothing, a failing one fails an otherwise
	 * green row, and a row failing both says both.
	 */
	@:pin('control')
	@:killer('M-GATE-FMT-CROSS-HALF-IGNORED')
	public function testTheFmtRowFailsOnEitherHalfAndNamesBoth(): Void {
		Assert.isTrue(SliceGate.fmtCombined(Passed, Skipped('no touched .hx')).match(Passed));
		Assert.isTrue(SliceGate.fmtCombined(Passed, Passed).match(Passed));
		Assert.isTrue(SliceGate.fmtCombined(Passed, Failed('xconfig +1')).match(Failed('xconfig +1')));
		Assert.isTrue(SliceGate.fmtCombined(Failed('3 would be rewritten'), Passed).match(Failed('3 would be rewritten')));
		Assert.isTrue(SliceGate.fmtCombined(Failed('a'), Failed('b')).match(Failed('a; b')));
	}

}
