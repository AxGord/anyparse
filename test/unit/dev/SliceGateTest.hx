package unit.dev;

import dev.Probe;
import dev.SliceGate;
import devkit.Branches;
import devkit.Lease.LeaseMode;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

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

}
