package unit.dev;

import dev.Probe;
import dev.SliceGate;
import devkit.Branches;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Lease.LeaseMode;
import devkit.Summary.Step;
import devkit.TempDir;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;
using Lambda;

/** `dev.SliceGate`: where a gate's and a branch's threads come from, and what its branches hold between them. */
@:nullSafety(Strict)
final class SliceGateTest extends Test {

	/** A `wf-run` that answers its status with a budget of eight and runs any other command as it is. */
	private static inline final FAKE_WF_RUN: String = '#!/bin/sh\nif [ "$$1" = "--status" ]; then\n'
		+ 'echo "pool /p: budget 8, held 0, load 0.0 (external 0.0, threshold 2)"; exit 0\nfi\nexec "$$@"\n';

	/** A `wf-run` that logs every lease it is asked for in `leases.log` beside itself and runs the command after `--`. */
	private static inline final LOGGING_WF_RUN: String = '#!/bin/sh\nif [ "$$1" = "--status" ]; then\n'
		+ 'echo "pool /p: budget 8, held 0, load 0.0 (external 0.0, threshold 2)"; exit 0\nfi\n'
		+ 'echo "$$*" >> "$$(dirname "$$0")/leases.log"\nwhile [ "$$1" != "--" ]; do shift; done\nshift\nexec "$$@"\n';

	/** The arms registry of the scratch tree below: one arm, on a type no slice touches. */
	private static inline final BASE_REGISTRY: String =
		'{"arms": [{"name": "M-SAME", "type": "a.Untouched", "method": "f", "force": "1"}]}';

	/** `BASE_REGISTRY` with a second arm, which a slice that adds it has to run the kill run for. */
	private static inline final GROWN_REGISTRY: String = '{"arms": [{"name": "M-SAME", "type": "a.Untouched", "method": "f", "force": "1"},'
		+ '{"name": "M-NEW", "type": "a.Other", "method": "f", "force": "1"}]}';

	/** A `bin/hxq` that answers every graph call with an empty graph. */
	private static inline final GRAPH_HXQ: String = 'echo \'{"nodes": []}\'\n';

	/**
	 * A stand-in for the script the branches run: it logs the rows it was handed in `<logs>/branches.log` and leaves the
	 * report of a branch that passed every row.
	 */
	private static final FAKE_SELF: String = "const fs=require('fs');const a=process.argv.slice(2);const at=n=>a[a.indexOf(n)+1];"
		+ "const rows=at('--rows').split(','),logs=at('--logs');fs.appendFileSync(logs+'/branches.log',rows.join(',')+'\\n');"
		+ "fs.mkdirSync(logs+'/rows',{recursive:true});fs.writeFileSync(logs+'/rows/'+rows[0]+'.json',JSON.stringify({run:at('--run'),"
		+ "steps:rows.map(n=>({name:n,outcome:'passed',why:'',ms:0,note:'',excerpt:[]})),readings:[]}));";

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

	/**
	 * `check()` runs the arms phase: a slice that adds an arm gets the arms branch, on a lease of its own beside the leases of
	 * the other rows.
	 */
	@:pin('control')
	@:killer('M-GATE-CHECK-DROPS-ARMS-PHASE')
	public function testCheckRunsTheArmsPhase(): Void {
		final ran: GateRan = gateRun(GROWN_REGISTRY);
		Assert.isTrue(ran.branches.contains('arms'), 'branches: ${ran.branches}');
		Assert.isTrue(ran.leases.contains(' arms -- '), 'leases: ${ran.leases}');
	}

	/** A selection that is empty settles the arms row in the gate's own process, so no lease is asked for it. */
	@:pin('control')
	@:killer('M-GATE-ARMS-LEASE-BEFORE-PLAN')
	public function testAnEmptyArmsSelectionTakesNoLease(): Void {
		final ran: GateRan = gateRun(BASE_REGISTRY);
		Assert.isTrue(ran.branches.contains('suite'), 'the other rows still run: ${ran.branches}');
		Assert.isFalse(ran.branches.contains('arms'), 'branches: ${ran.branches}');
		Assert.isFalse(ran.leases.contains(' arms -- '), 'leases: ${ran.leases}');
	}

	/** `--allow artifacts` lets the whole row through, saying the file it would have failed on was allowed. */
	@:pin('control')
	@:killer('M-GATE-ALLOW-IGNORED')
	public function testAllowingTheArtifactsRowLetsAnOffendingFileThrough(): Void {
		TempDir.with(dir -> {
			final tree: String = scratchTree(dir, BASE_REGISTRY, GRAPH_HXQ);
			File.saveContent(Path.join([tree, 'bin/apq.js']), 'built');
			for (allowed in [false, true]) {
				final logs: String = dir.file(allowed ? 'logs-allowed' : 'logs-plain');
				FileSystem.createDirectory(Path.join([logs, 'rows']));
				final args: Array<String> = [tree, '--rows', 'artifacts', '--logs', logs, '--run', 'r'].concat(
					allowed ? ['--allow', 'artifacts'] : []
				);
				Assert.equals(0, SliceGate.main(args));
				final step: Null<Step> = Branches.reportOf(Path.join([logs, 'rows/artifacts.json']), 'r')?.steps[0];
				Assert.notNull(step);
				if (step == null) continue;
				Assert.isTrue(allowed == step.outcome.match(Passed), '$allowed: ${step.outcome}');
				if (allowed) Assert.isTrue(step.note.contains('allowed: 1 artifact(s)'), step.note);
			}
		});
	}

	/** A settled plan that failed (a mistyped `--arm`) fails the gate and starts no arms branch. */
	@:pin('control')
	@:killer('M-GATE-SETTLED-ARMS-ROW-DROPPED')
	public function testASettledArmsFailureFailsTheGateWithoutABranch(): Void {
		final ran: GateRan = gateRun(BASE_REGISTRY, ['--arm', 'M-NOPE']);
		Assert.equals(1, ran.status);
		Assert.isFalse(ran.branches.contains('arms'), 'branches: ${ran.branches}');
		Assert.isFalse(ran.leases.contains(' arms -- '), 'leases: ${ran.leases}');
	}

	/** A plan that cannot be made (the graph call fails) is left to the branch, which reports the row; the gate does not throw. */
	@:pin('control')
	@:killer('M-GATE-ARMS-PLAN-THROWS-IN-GATE')
	public function testAPlanThatThrowsIsLeftToTheBranch(): Void {
		final ran: GateRan = gateRun(GROWN_REGISTRY, [], 'exit 1\n');
		Assert.isTrue(ran.branches.contains('arms'), 'branches: ${ran.branches}');
	}

	/**
	 * A scratch tree whose base commit holds the arm registry `BASE_REGISTRY` and whose slice commit holds `registry`, with the
	 * stand-ins the gate's tools need; it answers the baseline record the gate reads.
	 */
	private static function scratchTree(dir: TempDir, registry: String, hxq: String): String {
		final tree: String = dir.file('tree');
		final registryFile: String = Path.join([tree, 'test/testkit/arms/pkg.json']);
		FileSystem.createDirectory(Path.join([tree, 'tools']));
		FileSystem.createDirectory(Path.join([tree, 'bin']));
		FileSystem.createDirectory(Path.join([tree, 'test/testkit/arms']));
		File.saveContent(Path.join([tree, 'tools/dev.hxml']), '');
		File.saveContent(Path.join([tree, 'bin/test.js']), '');
		File.saveContent(Path.join([tree, 'bin/apq-js-common.hxml']), '');
		FileSystem.createDirectory(Path.join([tree, 'src']));
		File.saveContent(Path.join([tree, 'src/keep']), '');
		File.saveContent(Path.join([tree, 'bin/hxq']), hxq);

		File.saveContent(registryFile, BASE_REGISTRY);
		final git: Array<String> = ['-c', 'user.name=t', '-c', 'user.email=t@t'];
		cmd('git init -q -b main').at(tree).check();
		cmd('git add -A').at(tree).check();
		cmd('git $git commit -q -m base').at(tree).check();
		final base: String = cmd('git rev-parse HEAD').at(tree).check().out.trim();
		File.saveContent(registryFile, registry);
		File.saveContent(Path.join([tree, 'notes.txt']), 'slice');
		cmd('git add -A').at(tree).check();
		cmd('git $git commit -q -m slice').at(tree).check();
		FileSystem.createDirectory('$tree-logs');
		File.saveContent('$tree-logs/baseline.json', Json.stringify({ base: base, frozen: [], infra: [] }));

		return tree;
	}

	/** A whole `check()` over a scratch tree whose slice leaves `registry`, the compiler, the branches' script and the pool faked. */
	private static function gateRun(registry: String, ?extra: Array<String>, hxq: String = GRAPH_HXQ): GateRan {
		var ran: GateRan = { branches: '', leases: '', status: -1 };
		TempDir.with(dir -> {
			final tree: String = scratchTree(dir, registry, hxq);
			final root: String = dir.file('plugin');
			final fakeBin: String = dir.file('fakebin');
			for (d in [Path.join([root, 'scripts']), fakeBin]) FileSystem.createDirectory(d);
			File.saveContent(Path.join([fakeBin, 'haxe']), '#!/bin/sh\nexit 0\n');
			File.saveContent(Path.join([root, 'scripts/wf-run']), LOGGING_WF_RUN);
			File.saveContent(dir.file('self.js'), FAKE_SELF);
			for (script in [Path.join([fakeBin, 'haxe']), Path.join([root, 'scripts/wf-run'])])
				js.Syntax.code("require('fs').chmodSync({0}, 0o755)", script);
			var status: Int = -1;
			final saved: Map<String, String> = [
				for (v in ['WF_PLUGIN_ROOT', 'WF_THREADS', 'PATH', SliceGate.SELF_VAR]) v => Sys.getEnv(v) ?? ''
			];
			CliFixture.always(() -> for (v => value in saved) Sys.putEnv(v, value), () -> {
				Sys.putEnv('WF_PLUGIN_ROOT', root);
				Sys.putEnv('WF_THREADS', '');
				Sys.putEnv('PATH', '$fakeBin:${saved['PATH']}');
				Sys.putEnv(SliceGate.SELF_VAR, dir.file('self.js'));
				status = SliceGate.main([tree, '--logs', '$tree-logs'].concat(extra ?? []));
			});
			final read: String -> String = file -> FileSystem.exists(file) ? File.getContent(file) : '';
			ran = { branches: read('$tree-logs/branches.log'), leases: read(Path.join([root, 'scripts/leases.log'])), status: status };
		});
		return ran;
	}

}

/** What a `check()` over a scratch tree left: the rows each branch process was handed, and the leases asked of the pool. */
private typedef GateRan = {
	var branches: String;
	var leases: String;
	var status: Int;
}
