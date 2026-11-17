package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonFormat;
import anyparse.util.Compare;
import dev.BaseEngine;
import dev.BaseLint;
import dev.BaselineWriter;
import dev.GateLint;
import dev.GateTree;
import dev.SliceGate;
import devkit.Cmd.cmd;
import devkit.Lease.LeaseMode;
import devkit.Summary.Outcome;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;
using Lambda;

/** `dev.SliceGate`'s infra4 branch in a gate that takes its leases from the pool: what the branch process holds while it waits. */
@:nullSafety(Strict)
@:access(unit.dev.SliceGateTest)
final class Infra4LeasePhaseTest extends Test {

	/** A `bin/hxq` whose lint reports no finding and whose `lint-diff` reports nothing moved. */
	private static final FAKE_HXQ: String = 'case "$$1" in lint) echo "[]";; lint-diff) echo "0 added / 0 removed";; esac\n';

	/**
	 * A gate that holds no lease starts its infra4 branch without one: the branch waits for the base lint and checks the base
	 * out before it lints, so only its lints take threads of the pool, while the suite still takes its own.
	 */
	@:killer('M-GATE-INFRA4-BRANCH-LEASED')
	@:pin('control')
	public function testTheInfra4BranchOfAPooledGateHoldsNoLease(): Void {
		TempDir.with(cache -> {
			final was: Null<String> = Sys.getEnv(SliceGateTest.CACHE_VAR);
			var ran: {
				leases: String,
				branches: String,
				status: Int,
				table: String
			} = {
				leases: '',
				branches: '',
				status: -1,
				table: ''
			};
			CliFixture.always(() -> {
				if (was == null)
					js.Syntax.code('delete process.env[{0}]', SliceGateTest.CACHE_VAR)
				else
					Sys.putEnv(SliceGateTest.CACHE_VAR, was);
			}, () -> {
				Sys.putEnv(SliceGateTest.CACHE_VAR, cache.path);
				ran = SliceGateTest.gateRun(
					SliceGateTest.BASE_REGISTRY, [], SliceGateTest.GRAPH_HXQ, null, null, 'src/anyparse/check/Rule.hx', true
				);
			});
			Assert.equals(0, ran.status, ran.table);
			Assert.isTrue(ran.branches.split('\n').contains('infra4'), 'branches: ${ran.branches}');
			final leases: Array<String> = ran.leases.split('\n');
			Assert.isFalse(leases.exists(l -> l.contains('--label slice-gate tree infra4 --')), 'leases: ${ran.leases}');
			Assert.isTrue(leases.exists(l -> l.contains('--label slice-gate tree suite,corpus --')), 'leases: ${ran.leases}');
		});
	}

	/**
	 * The infra4 branch reads its lease mode as its gate does: in a workflow whose pool it reaches it asks the pool for its lints,
	 * and inside its gate's held lease it stays there; every other branch stays unpooled.
	 */
	@:pin('control')
	@:killer('M-GATE-INFRA4-BRANCH-LEASED')
	public function testTheInfra4BranchAsksThePoolOnlyWhenItsGateHeldNoLease(): Void {
		TempDir.with(dir -> {
			final wfRun: String = fakeWfRun(dir, SliceGateTest.FAKE_WF_RUN);
			final saved: Map<String, String> = [ for (v in ['WF_PLUGIN_ROOT', 'WF_THREADS']) v => Sys.getEnv(v) ?? '' ];
			final modes: Array<LeaseMode> = [];
			CliFixture.always(() -> for (v => value in saved) Sys.putEnv(v, value), () -> {
				Sys.putEnv('WF_PLUGIN_ROOT', Path.directory(Path.directory(wfRun)));
				Sys.putEnv('WF_THREADS', '');
				modes.push(SliceGate.leaseModeOf('infra4'));
				modes.push(SliceGate.leaseModeOf('lint'));
				Sys.putEnv('WF_THREADS', '3');
				modes.push(SliceGate.leaseModeOf('infra4'));
			});
			Assert.isTrue(modes[0].match(Own(_, 8)), 'infra4 under no lease: ${modes[0]}');
			Assert.isTrue(modes[1].match(Unpooled), 'the lint branch: ${modes[1]}');
			Assert.isTrue(modes[2].match(Held(3)), 'infra4 inside a held lease: ${modes[2]}');
		});
	}

	/**
	 * Under a mode of its own (`Own`) each lint of the infra4 row, the base tree's and every infra tree's in a gate and every
	 * infra tree's in `--baseline`, takes a pool lease of one thread labelled with its tree, queued one step ahead of the gate's
	 * own priority as the branch's lease was, so the row's serial steps hold none.
	 */
	@:pin('control')
	@:killer('M-GATE-INFRA4-LINT-UNLEASED', 'M-GATE-INFRA4-LINT-PRIORITY-DROPPED')
	public function testEachLintOfTheInfra4RowTakesALeaseOfOneThread(): Void {
		TempDir.with(dir -> {
			final wfRun: String = fakeWfRun(dir, SliceGateTest.LOGGING_WF_RUN);
			final tree: String = dir.file('tree');
			final logs: String = dir.file('logs');
			final infra: String = dir.file('infra');
			for (d in [Path.join([tree, 'src/anyparse/check']), Path.join([tree, 'bin']), logs, infra]) FileSystem.createDirectory(d);
			File.saveContent(Path.join([tree, 'keep']), tree);
			final git: Array<String> = ['-c', 'user.name=t', '-c', 'user.email=t@t'];
			cmd('git init -q -b main').at(tree).check();
			cmd('git add -A').at(tree).check();
			cmd('git $git commit -q -m base').at(tree).check();
			final base: String = cmd('git rev-parse HEAD').at(tree).check().out.trim();
			File.saveContent(Path.join([tree, 'src/anyparse/check/Rule.hx']), 'class Rule {}\n');
			for (hxml in ['bin/apq-js-common.hxml', 'bin/apq-js.hxml']) File.saveContent(Path.join([tree, hxml]), '');
			File.saveContent(Path.join([tree, 'bin/hxq']), FAKE_HXQ);
			cmd('git add -A').at(tree).check();
			cmd('git $git commit -q -m slice').at(tree).check();
			File.saveContent(dir.file('infra.json'), '[]');
			File.saveContent(
				Path.join([logs, GateTree.BASELINE_FILE]),
				BaselineWriter.write({
					base: base,
					lists: JObject([]),
					infra: [{ tree: infra, snapshot: dir.file('infra.json') }],
					frozen: []
				}, JsonFormat.instance.compactWriteOptions)
			);
			final gate: GateTree = new GateTree(optionsOf(tree, logs, false, []));
			File.saveContent(gate.log(BaseLint.FILE), '[]');
			File.saveContent(gate.log(BaseLint.STAMP), BaseLint.stampOf(gate.base, BaseEngine.toolchain()));
			final mode: LeaseMode = Own(wfRun, 8);
			final priorityWas: Null<String> = Sys.getEnv('WF_PRIORITY');
			var recorded: Outcome = NotRun('not run');
			var compared: Outcome = NotRun('not run');
			CliFixture.always(() -> {
				if (priorityWas == null)
					js.Syntax.code("delete process.env['WF_PRIORITY']")
				else
					Sys.putEnv('WF_PRIORITY', priorityWas);
			}, () -> {
				Sys.putEnv('WF_PRIORITY', '2');
				recorded = new GateLint(new GateTree(optionsOf(tree, dir.file('recording'), true, [infra])), true, mode).infraBaseline();
				compared = new GateLint(gate, true, mode).infraOutcome();
			});
			Assert.isTrue(recorded.match(Passed), '$recorded');
			Assert.isTrue(compared.match(Passed), '$compared');
			final leases: Array<String> = File.getContent(Path.join([Path.directory(wfRun), 'leases.log']))
				.split('\n')
				.filter(l -> l != '');
			final labels: Array<String> = leases.map(l -> l.substring(l.indexOf('--label ') + '--label '.length, l.indexOf(' -- ')));
			labels.sort(Compare.compareString);
			Assert.same([
				'slice-gate tree infra4 base tree',
				'slice-gate tree infra4 infra',
				'slice-gate tree infra4 infra'
			], labels);
			for (l in leases) {
				Assert.stringContains('--threads 1 ', l);
				Assert.stringContains('--priority=3 ', l, 'one step ahead of the gate\'s own priority: $l');
			}
		});
	}

	/** `script` as the `wf-run` of a workflow plugin root under `dir`, executable. */
	private static function fakeWfRun(dir: TempDir, script: String): String {
		final wfRun: String = dir.file('plugin/scripts/wf-run');
		FileSystem.createDirectory(Path.directory(wfRun));
		File.saveContent(wfRun, script);
		js.Syntax.code("require('fs').chmodSync({0}, 0o755)", wfRun);
		return wfRun;
	}

	/** The options of a gate over `tree` with its logs in `logs`, a `--baseline` run when `recording`, over the infra trees `infra`. */
	private static function optionsOf(tree: String, logs: String, recording: Bool, infra: Array<String>): GateOptions {
		FileSystem.createDirectory(logs);
		return {
			tree: tree,
			logs: logs,
			baseline: recording,
			frozen: [],
			infra: infra,
			arms: [],
			allow: [],
			allowArms: [],
			noArms: false,
			threads: null,
			run: 'r'
		};
	}

}
