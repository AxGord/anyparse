package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonFormat;
import anyparse.grammar.json.JsonText;
import dev.BaseSuite;
import dev.BaselineWriter;
import dev.BranchWatch;
import dev.Probe;
import dev.SliceGate;
import devkit.Branches;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Lease.LeaseMode;
import devkit.Summary.Step;
import devkit.TempDir;
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

	/** A registry whose one arm belongs to a package other than the document's (`a.json`). */
	private static inline final MISPLACED_REGISTRY: String =
		'{"arms": [{"name": "M-BAD", "type": "b.Other", "method": "f", "force": "1"}]}';

	/** A `bin/hxq` that answers every graph call with an empty graph. */
	private static inline final GRAPH_HXQ: String = 'echo \'{"nodes": [], "edges": []}\'\n';

	/** The environment variable that names the corpus the suite's harness reads. */
	private static inline final FORK_VAR: String = 'ANYPARSE_HXFORMAT_FORK';

	/**
	 * A stand-in for the script the branches run: it logs the rows it was handed in `<logs>/branches.log` and leaves the
	 * report of a branch that passed every row.
	 */
	private static final FAKE_SELF: String = "const fs=require('fs');const a=process.argv.slice(2);const at=n=>a[a.indexOf(n)+1];"
		+ "const rows=at('--rows').split(','),logs=at('--logs');fs.appendFileSync(logs+'/branches.log',rows.join(',')+'\\n');"
		+ "fs.mkdirSync(logs+'/rows',{recursive:true});fs.writeFileSync(logs+'/rows/'+rows[0]+'.json',JSON.stringify({run:at('--run'),"
		+ "steps:rows.map(n=>({name:n,outcome:'passed',why:'',ms:0,note:'',excerpt:[]})),readings:[]}));";

	/** `FAKE_SELF` with its `corpus` row ending failed. */
	private static final FAILING_CORPUS_SELF: String = FAKE_SELF.replace("outcome:'passed'", "outcome:n==='corpus'?'failed':'passed'");

	/** A stand-in branch that starts its first row and then stops moving for good, as a wedged row does. */
	private static final STALLED_SELF: String = "const fs=require('fs');const a=process.argv.slice(2);const at=n=>a[a.indexOf(n)+1];"
		+ "const rows=at('--rows').split(','),logs=at('--logs');fs.mkdirSync(logs+'/rows',{recursive:true});"
		+ "fs.writeFileSync(logs+'/rows/'+rows[0]+'.json.progress',rows[0]);setInterval(()=>{},1000);";

	/**
	 * `FAKE_SELF` for every branch but the arms one, which stops moving
	 * as `STALLED_SELF` does: the arms phase follows a green fan-out only.
	 */
	private static final ARMS_STALLED_SELF: String = [
		"const rows0=process.argv[process.argv.indexOf('--rows')+1];if(rows0!=='arms'){",
		FAKE_SELF,
		'}else{',
		STALLED_SELF,
		'}'
	].join('');

	private static final FAILING_LINT_SELF: String = FAKE_SELF.replace("outcome:'passed'", "outcome:n==='lint'?'failed':'passed'");

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
	 * What every branch of a gate run but the heavy one holds is one thread for the short
	 * rows, the kits row's when the engine or a kit moved, two for the lint row when a
	 * `.hx` file moved, one for the jvm probe when it runs, and the base tree's lint plus one per infra tree when rule code
	 * moved.
	 */
	@:pin('control')
	@:killer('M-GATE-DEMAND-LISTS-NONE')
	public function testTheLightBranchesOfAGateHoldWhatItsRowsRun(): Void {
		for (touchedHx in [false, true]) for (jvmMoved in [false, true]) for (kitsMoved in [false, true]) for (ruleInfra in [null, 0, 3]) {
			final facts: GateDemand = {
				recording: false,
				infra: 0,
				touchedHx: touchedHx,
				jvmMoved: jvmMoved,
				kitsMoved: kitsMoved,
				ruleInfra: ruleInfra
			};
			final expected: Int = 1 + (kitsMoved ? Probe.GATE_THREADS : 0) + (touchedHx ? 2 : 0) + (jvmMoved ? 1 : 0) + (
				ruleInfra == null ? 0 : 1 + ruleInfra
			);
			Assert.equals(expected, Branches.light(SliceGate.GATE_BRANCHES, rows -> SliceGate.demandOf(facts, rows)), '$facts');
		}
		Assert.isNull(SliceGate.demandOf({
			recording: false,
			infra: 0,
			touchedHx: true,
			jvmMoved: true,
			kitsMoved: true,
			ruleInfra: 3
		}, ['suite']));
		Assert.isNull(
			SliceGate.demandOf({
				recording: false,
				infra: 0,
				touchedHx: false,
				jvmMoved: false,
				kitsMoved: false,
				ruleInfra: null
			}, ['base']),
			'the base branch is a heavy one beside the suite'
		);
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
		final tracks: Int = SliceGate.ARMS_THREADS + 13;
		final own: Array<String> = SliceGate.armsCommand(Own('/p/scripts/wf-run', 10), command, 'gate arms', tracks).argv;
		Assert.contains('1-${SliceGate.ARMS_THREADS}', own);
		Assert.isFalse(own.contains('10'), 'the pool budget is not what it asks for: $own');
		Assert.same(['node', 'arms'], SliceGate.armsCommand(Held(4), command, 'gate arms', tracks).argv);
		Assert.same(['node', 'arms'], SliceGate.armsCommand(Unpooled, command, 'gate arms', tracks).argv);
		Assert.equals(SliceGate.ARMS_THREADS, SliceGate.armsThreads(Held(SliceGate.ARMS_THREADS + 3), tracks));
		Assert.equals(SliceGate.ARMS_THREADS, SliceGate.armsThreads(Held(SliceGate.ARMS_THREADS), tracks));
		Assert.equals(1, SliceGate.armsThreads(Held(1), tracks));
		Assert.isNull(SliceGate.armsThreads(Own('/p/scripts/wf-run', 10), tracks));
		Assert.isNull(SliceGate.armsThreads(Unpooled, tracks));
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
		Assert.isTrue(SliceGate.fmtCombined(Skipped('none'), Failed('xconfig +1')).match(Failed('xconfig +1')));
		Assert.isTrue(SliceGate.fmtCombined(Skipped('none'), Skipped('no touched .hx')).match(Skipped('none')));
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
		Assert.isTrue(ran.branches.contains('arms'), 'branches: ${ran.branches}\n${ran.table}');
		Assert.isTrue(ran.leases.contains(' arms -- '), 'leases: ${ran.leases}');
	}

	/**
	 * A row of the first fan-out that ended red leaves the arms row not run, naming that row, and starts no arms branch and asks
	 * for no lease: the gate is red whatever the kill run says.
	 */
	@:pin('control')
	@:killer('M-GATE-ARMS-RUN-ON-RED-ROW')
	public function testARedRowOfTheFirstFanOutStartsNoArmsRun(): Void {
		final ran: GateRan = gateRun(GROWN_REGISTRY, [], GRAPH_HXQ, FAILING_CORPUS_SELF);
		Assert.equals(1, ran.status, ran.table);
		Assert.isTrue(ran.branches.contains('suite'), 'the first fan-out still ran: ${ran.branches}');
		Assert.isFalse(ran.branches.contains('arms'), 'branches: ${ran.branches}\n${ran.table}');
		Assert.isFalse(ran.leases.contains(' arms -- '), 'leases: ${ran.leases}');
		Assert.isTrue(~/(^|\n)arms +not run +[0-9.]+s +not run: corpus did not pass/.match(ran.table), ran.table);
	}

	/**
	 * A plan the gate settles itself (`--no-arms`, a mistyped `--arm`) keeps its own row beside a red fan-out, so a typo on a red
	 * gate is named instead of read as not run.
	 */
	@:pin('guard')
	public function testASettledArmsPlanKeepsItsRowBesideARedRow(): Void {
		final skipped: GateRan = gateRun(GROWN_REGISTRY, ['--no-arms'], GRAPH_HXQ, FAILING_CORPUS_SELF);
		Assert.equals(1, skipped.status, skipped.table);
		Assert.isTrue(~/(^|\n)arms +skipped +[0-9.]+s +--no-arms/.match(skipped.table), skipped.table);
		final typo: GateRan = gateRun(GROWN_REGISTRY, ['--arm', 'M-NOPE'], GRAPH_HXQ, FAILING_CORPUS_SELF);
		Assert.equals(1, typo.status, typo.table);
		Assert.isTrue(~/(^|\n)arms +FAILED/.match(typo.table), typo.table);
		Assert.stringContains('--arm M-NOPE names no arm', typo.table);
	}

	/** A selection that is empty settles the arms row in the gate's own process, so no lease is asked for it. */
	@:pin('control')
	@:killer('M-GATE-ARMS-LEASE-BEFORE-PLAN')
	public function testAnEmptyArmsSelectionTakesNoLease(): Void {
		final ran: GateRan = gateRun(BASE_REGISTRY);
		Assert.isTrue(ran.branches.contains('suite'), 'the other rows still run: ${ran.branches}');
		Assert.isFalse(ran.branches.contains('arms'), 'branches: ${ran.branches}\n${ran.table}');
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
		Assert.isFalse(ran.branches.contains('arms'), 'branches: ${ran.branches}\n${ran.table}');
		Assert.isFalse(ran.leases.contains(' arms -- '), 'leases: ${ran.leases}');
	}

	/** A registry that does not read (a misplaced arm) fails the gate at once, the row naming the document and the arm. */
	@:pin('control')
	@:killer('M-GATE-REGISTRY-REFUSAL-DROPPED')
	public function testAnUnreadableArmRegistryFailsTheGateBeforeAnyBranch(): Void {
		final ran: GateRan = gateRun(MISPLACED_REGISTRY);
		Assert.equals(1, ran.status, ran.table);
		Assert.equals('', ran.branches, ran.table);
		Assert.stringContains('a.json: arm M-BAD', ran.table);
		Assert.isTrue(~/(^|\n)arms +FAILED/.match(ran.table), ran.table);
		Assert.isFalse(~/(^|\n)build /.match(ran.table), 'the refusal comes before the build: ${ran.table}');
	}

	/** `--allow arms` does not waive a registry that does not read: the gate ran no other row, so it cannot pass. */
	@:pin('control')
	@:killer('M-GATE-REGISTRY-REFUSAL-WAIVABLE')
	public function testAnUnreadableArmRegistryIsNotWaivedByAllowArms(): Void {
		final ran: GateRan = gateRun(MISPLACED_REGISTRY, ['--allow', 'arms']);
		Assert.equals(1, ran.status, ran.table);
		Assert.stringContains('a.json: arm M-BAD', ran.table);
	}

	/** A document that does not parse is named in the row. */
	@:pin('guard')
	public function testABrokenArmDocumentIsNamedInTheRefusal(): Void {
		final ran: GateRan = gateRun('{"arms": [{"name": }]}');
		Assert.equals(1, ran.status, ran.table);
		Assert.stringContains('a.json: ', ran.table);
	}

	/** `--no-arms` leaves the registry unread: the other rows still run. */
	@:pin('control')
	@:killer('M-GATE-REGISTRY-REFUSAL-READS-NOARMS')
	public function testNoArmsLeavesAnUnreadableRegistryUnread(): Void {
		final ran: GateRan = gateRun(MISPLACED_REGISTRY, ['--no-arms']);
		Assert.isTrue(ran.branches.contains('suite'), ran.table);
	}

	/** A plan that cannot be made (the graph call fails) is left to the branch, which reports the row; the gate does not throw. */
	@:pin('control')
	@:killer('M-GATE-ARMS-PLAN-THROWS-IN-GATE')
	public function testAPlanThatThrowsIsLeftToTheBranch(): Void {
		final ran: GateRan = gateRun(GROWN_REGISTRY, [], 'exit 1\n');
		Assert.isTrue(ran.branches.contains('arms'), 'branches: ${ran.branches}\n${ran.table}');
	}

	/**
	 * Every branch is watched for silence: one that starts a row and then stops moving is cut at its row's limit, and the gate
	 * names the row it stood in. The limit is the longest of the rows the branch runs, and a row left unnamed has the default.
	 */
	@:pin('guard')
	public function testABranchThatStopsMovingIsCutAndNamesItsRow(): Void {
		final armsOnly: GateRan = gateRun(GROWN_REGISTRY, [], GRAPH_HXQ, ARMS_STALLED_SELF, 1000);
		final all: GateRan = gateRun(GROWN_REGISTRY, [], GRAPH_HXQ, STALLED_SELF, 1000);
		for (first in ['suite', 'lists', 'lint', 'jvm', 'infra4', 'kits', 'arms']) {
			final log: String = (first == 'arms' ? armsOnly : all).rowLogs[first] ?? '';
			Assert.stringContains('made no progress for 1 s', log, first);
			Assert.stringContains('last started: $first', log, first);
		}
		final minute: Int = 60 * 1000;
		Assert.equals(40 * minute, BranchWatch.idleOf(['suite', 'corpus']));
		Assert.equals(20 * minute, BranchWatch.idleOf(['corpus']));
		Assert.equals(10 * minute, BranchWatch.idleOf(['lists', 'fmt', 'scrub', 'artifacts']));
		Assert.equals(45 * minute, BranchWatch.idleOf(['arms']));
		Assert.equals(5 * minute, BranchWatch.idleOf(['lists']));
		Assert.equals(20 * minute, BranchWatch.idleOf(['no-such-row']));
	}

	/**
	 * The real branch names each row in its progress file as the row starts and leaves its report after every row: while the
	 * second row runs, the first row's result is already on disk and the progress file names the second, so a branch cut in
	 * the second row loses nothing of the first.
	 */
	@:pin('guard')
	public function testARealBranchMovesItsProgressFileAndReportsAfterEveryRow(): Void {
		TempDir.with(dir -> {
			final tree: String = scratchTree(dir, BASE_REGISTRY, GRAPH_HXQ);
			final logs: String = dir.file('logs');
			FileSystem.createDirectory(Path.join([logs, 'rows']));
			final report: String = Path.join([logs, 'rows/artifacts.json']);
			final progress: String = '$report.progress';
			final marker: String = dir.file('marker');
			final probe: Array<String> = [
				"const fs = require('fs');",
				'fs.writeFileSync(${JsonText.quote(marker)}, fs.existsSync(${JsonText.quote(report)}) + "|"',
				'	+ fs.readFileSync(${JsonText.quote(progress)}, "utf8"));'
			];
			File.saveContent(Path.join([tree, 'bin/apq.js']), 'built');
			File.saveContent(Path.join([tree, 'bin/test.js']), probe.join('\n'));
			Assert.equals(0, SliceGate.main([tree, '--rows', 'artifacts,lists', '--logs', logs, '--run', 'r']));
			Assert.equals('true|lists', File.getContent(marker), 'while the second row ran');
			Assert.equals('lists', File.getContent(progress));
			final left: Null<BranchReport> = Branches.reportOf(report, 'r');
			Assert.same(['artifacts', 'lists'], left == null ? [] : [for (step in left.steps) step.name]);
		});
	}

	/**
	 * A `--baseline` run in which a row failed records nothing and retires the baseline an earlier run left, with the base
	 * suite reading kept beside it: the gate then has none to compare with, instead of the older one.
	 */
	@:pin('control')
	@:killer('M-GATE-BASELINE-RECORDED-AFTER-FAILURE')
	@:killer('M-GATE-BASELINE-NOT-RETIRED')
	public function testABaselineThatFailedARowIsNotRecordedAndRetiresTheOlderOne(): Void {
		final ran: GateRan = gateRun(BASE_REGISTRY, ['--baseline'], GRAPH_HXQ, FAILING_LINT_SELF);
		Assert.equals(1, ran.status);
		Assert.isFalse(ran.logsHad.contains('baseline.json'), 'logs: ${ran.logsHad}');
		Assert.isFalse(ran.logsHad.contains('sweep-base.json'), 'logs: ${ran.logsHad}');
		Assert.isFalse(ran.logsHad.contains(BaseSuite.FILE), 'logs: ${ran.logsHad}');
	}

	/**
	 * A `--baseline` run in which every row passed records its readings, and runs neither the suite nor the corpus: a gate
	 * reads those from the base when it needs them.
	 */
	@:pin('guard')
	public function testABaselineThatPassedEveryRowIsRecorded(): Void {
		final ran: GateRan = gateRun(BASE_REGISTRY, ['--baseline']);
		Assert.equals(0, ran.status);
		Assert.stringContains('"lists"', ran.baselineText);
		Assert.isFalse(ran.baselineText.contains('"tests"'), ran.baselineText);
		Assert.isFalse(ran.baselineText.contains('"sweep"'), ran.baselineText);
		Assert.isFalse(ran.branches.contains('suite'), ran.branches);
		Assert.isFalse(ran.branches.contains('corpus'), ran.branches);
	}

	/**
	 * The corpus row will not compare a snapshot the suite did not write: a fork that names no directory (the harness skips it
	 * quietly) and a tree with no snapshot are refused with their cause, and a base suite that cannot be read is named, not
	 * compared with.
	 */
	@:pin('control')
	@:killer('M-GATE-CORPUS-FORK-NOT-CHECKED')
	@:killer('M-GATE-CORPUS-SNAPSHOT-NOT-CHECKED')
	@:killer('M-GATE-CORPUS-BASE-UNREAD')
	public function testTheCorpusRowRefusesASnapshotTheSuiteDidNotWrite(): Void {
		Assert.stringContains('no directory', corpusWhy({ fork: false, snapshot: true }));
		Assert.stringContains('the suite left no corpus snapshot', corpusWhy({ fork: true, snapshot: false }));
		Assert.stringContains('no corpus snapshot of the base', corpusWhy({ fork: true, snapshot: true }));
	}

	/** The suite row removes the snapshot an earlier run left, so the corpus row can only read the one the suite wrote. */
	@:pin('control')
	@:killer('M-GATE-STALE-SNAPSHOT-KEPT')
	public function testTheSuiteRowRemovesTheSnapshotAnEarlierRunLeft(): Void {
		TempDir.with(dir -> {
			final tree: String = scratchTree(dir, BASE_REGISTRY, GRAPH_HXQ);
			FileSystem.createDirectory('$tree-logs/rows');
			final stale: String = Path.join([tree, 'bin/.last-sweep.json']);
			File.saveContent(stale, '{}');
			Assert.equals(0, SliceGate.main([tree, '--rows', 'suite', '--logs', '$tree-logs', '--run', 'r']));
			Assert.isFalse(FileSystem.exists(stale));
			Assert.equals('{}', File.getContent(Path.join([tree, 'bin/.prev-sweep.json'])), 'it is rotated, as the corpus class would');
		});
	}

	/**
	 * The arms lease asks for no more threads than the kill run has tracks, since a run holds no more slots than that: one track
	 * asks for exactly one thread and so waits no whole-share window, a few tracks ask for a range up to their count, and a
	 * selection past the top asks for the top. A held lease is bounded by the same ask.
	 */
	@:pin('control')
	@:killer('M-GATE-ARMS-ASK-UNBOUNDED')
	public function testTheArmsLeaseAsksNoMoreThreadsThanTheKillRunHasTracks(): Void {
		final command: Command = Command.of(['node', 'arms']);
		final own: LeaseMode = Own('/p/scripts/wf-run', 10);
		final one: Array<String> = SliceGate.armsCommand(own, command, 'gate arms', 1).argv;
		Assert.equals('1', one[one.indexOf('--threads') + 1], 'one track asks for one thread: $one');
		Assert.isFalse(one.exists(arg -> arg.startsWith('--wait-full')), 'a fixed ask waits for no whole share: $one');
		final three: Array<String> = SliceGate.armsCommand(own, command, 'gate arms', 3).argv;
		Assert.equals('1-3', three[three.indexOf('--threads') + 1]);
		Assert.isTrue(three.exists(arg -> arg.startsWith('--wait-full')), 'a range waits for its whole share first: $three');
		final many: Array<String> = SliceGate.armsCommand(own, command, 'gate arms', 19).argv;
		Assert.equals('1-${SliceGate.ARMS_THREADS}', many[many.indexOf('--threads') + 1]);
		Assert.equals(1, SliceGate.armsThreads(Held(4), 1));
		Assert.equals(3, SliceGate.armsThreads(Held(4), 3));
		Assert.equals(2, SliceGate.armsThreads(Held(2), 3));
		Assert.equals(1, SliceGate.armsThreads(Held(4), 0), 'no track still asks for the one thread the branch runs on');
	}

	/**
	 * The arms lease is asked for the kill run the plan selected, not for the top of the range: a selection of one arm asks for
	 * exactly one thread and waits for no whole share.
	 */
	@:pin('control')
	@:killer('M-GATE-ARMS-ASK-IGNORES-PLAN')
	public function testTheArmsLeaseIsAskedForTheTracksThePlanSelected(): Void {
		final ran: GateRan = gateRun(GROWN_REGISTRY);
		final asked: Array<String> = ran.leases.split('\n').filter(line -> line.contains(' arms -- '));
		Assert.equals(1, asked.length, 'leases: ${ran.leases}');
		final line: String = asked.join('\n');
		Assert.isTrue(line.contains('--threads 1 '), line);
		Assert.isFalse(line.contains('--wait-full'), line);
	}

	/**
	 * A whole-suite gate whose base suite is unread starts the base branch with the others, at the gate's start and on a lease of
	 * its own, not as a step of the suite branch behind its suite; the branch is no line of the gate's table.
	 */
	@:pin('guard')
	public function testAWholeGateStartsTheBaseBranchBesideItsSuite(): Void {
		final ran: GateRan = gateRun(BASE_REGISTRY, [], GRAPH_HXQ, null, null, 'haxelib.json');
		Assert.equals(0, ran.status, ran.table);
		Assert.isTrue(ran.branches.split('\n').contains('base'), 'branches: ${ran.branches}');
		Assert.isTrue(ran.branches.split('\n').contains('suite,corpus'), 'branches: ${ran.branches}');
		Assert.isTrue(ran.leases.contains(' base -- '), 'leases: ${ran.leases}');
		Assert.isFalse(~/(^|\n)base /.match(ran.table), ran.table);
		final impact: GateRan = gateRun(BASE_REGISTRY);
		Assert.isFalse(impact.branches.split('\n').contains('base'), 'an impact gate reads no base suite: ${impact.branches}');
	}

	/**
	 * A scratch tree whose base commit holds the arm registry `BASE_REGISTRY` and whose slice commit holds `registry`, with the
	 * stand-ins the gate's tools need; it answers the baseline record the gate reads.
	 */
	private static function scratchTree(dir: TempDir, registry: String, hxq: String, touched: String = 'notes.txt'): String {
		final tree: String = dir.file('tree');
		final registryFile: String = Path.join([tree, 'test/testkit/arms/a.json']);
		FileSystem.createDirectory(Path.join([tree, 'tools']));
		FileSystem.createDirectory(Path.join([tree, 'bin']));
		FileSystem.createDirectory(Path.join([tree, 'test/testkit/arms']));
		File.saveContent(Path.join([tree, 'tools/dev.hxml']), '');
		File.saveContent(Path.join([tree, 'bin/test.js']), '');
		File.saveContent(Path.join([tree, 'bin/apq-js-common.hxml']), '');
		File.saveContent(Path.join([tree, 'bin/apq-js.hxml']), '');
		FileSystem.createDirectory(Path.join([tree, 'src']));
		// the tree's own path makes its base commit unique: the baseline cache is keyed by the base,
		// and two trees made in one second would share one entry
		File.saveContent(Path.join([tree, 'src/keep']), tree);
		File.saveContent(Path.join([tree, 'bin/hxq']), hxq);

		File.saveContent(registryFile, BASE_REGISTRY);
		final git: Array<String> = ['-c', 'user.name=t', '-c', 'user.email=t@t'];
		cmd('git init -q -b main').at(tree).check();
		cmd('git add -A').at(tree).check();
		cmd('git $git commit -q -m base').at(tree).check();
		final base: String = cmd('git rev-parse HEAD').at(tree).check().out.trim();
		File.saveContent(registryFile, registry);
		File.saveContent(Path.join([tree, touched]), 'slice');
		cmd('git add -A').at(tree).check();
		cmd('git $git commit -q -m slice').at(tree).check();
		FileSystem.createDirectory('$tree-logs');
		File.saveContent(
			'$tree-logs/baseline.json', BaselineWriter.write({
				base: base,

				lists: JObject([]),
				lint: '',
				infra: [],
				frozen: []
			}, JsonFormat.instance.compactWriteOptions)
		);
		File.saveContent('$tree-logs/sweep-base.json', '{}');
		File.saveContent('$tree-logs/${BaseSuite.FILE}', 'a reading of an earlier base');

		return tree;
	}

	/** A whole `check()` over a scratch tree whose slice leaves `registry`, the compiler, the branches' script and the pool faked. */
	private static function gateRun(
		registry: String, ?extra: Array<String>, hxq: String = GRAPH_HXQ, ?self: String, ?idleMs: Int, touched: String = 'notes.txt'
	): GateRan {
		var ran: GateRan = {
			branches: '',
			leases: '',
			status: -1,
			rowLogs: [],
			logsHad: [],
			baselineText: '',

			table: ''
		};
		TempDir.with(dir -> {
			final tree: String = scratchTree(dir, registry, hxq, touched);

			final root: String = dir.file('plugin');
			final fakeBin: String = dir.file('fakebin');
			for (d in [Path.join([root, 'scripts']), fakeBin]) FileSystem.createDirectory(d);
			File.saveContent(Path.join([fakeBin, 'haxe']), '#!/bin/sh\nexit 0\n');
			File.saveContent(Path.join([root, 'scripts/wf-run']), LOGGING_WF_RUN);
			File.saveContent(dir.file('self.js'), self ?? FAKE_SELF);
			for (script in [Path.join([fakeBin, 'haxe']), Path.join([root, 'scripts/wf-run'])])
				js.Syntax.code("require('fs').chmodSync({0}, 0o755)", script);
			var status: Int = -1;
			final saved: Map<String, String> = [
				for (v in [
					'WF_PLUGIN_ROOT',
					'WF_THREADS',
					'PATH',
					SliceGate.SELF_VAR,
					BranchWatch.IDLE_VAR,
					FORK_VAR
				]) v => Sys.getEnv(v) ?? ''
			];
			CliFixture.always(() -> for (v => value in saved) Sys.putEnv(v, value), () -> {
				Sys.putEnv('WF_PLUGIN_ROOT', root);
				Sys.putEnv('WF_THREADS', '');
				Sys.putEnv(FORK_VAR, '');
				Sys.putEnv('PATH', '$fakeBin:${saved['PATH']}');
				Sys.putEnv(SliceGate.SELF_VAR, dir.file('self.js'));
				Sys.putEnv(BranchWatch.IDLE_VAR, idleMs == null ? '' : '$idleMs');
				status = SliceGate.main([tree, '--logs', '$tree-logs'].concat(extra ?? []));

			});
			final read: String -> String = file -> FileSystem.exists(file) ? File.getContent(file) : '';
			final rowsDir: String = '$tree-logs/rows';
			final rowLogs: Map<String, String> = FileSystem.exists(rowsDir) ? [
				for (f in FileSystem.readDirectory(rowsDir)) if (f.endsWith('.json.log'))
					f.substr(0, f.length - '.json.log'.length) => read(Path.join([rowsDir, f]))
			] : [];
			ran = {
				branches: read('$tree-logs/branches.log'),
				leases: read(Path.join([root, 'scripts/leases.log'])),
				status: status,
				rowLogs: rowLogs,
				logsHad: FileSystem.exists('$tree-logs') ? FileSystem.readDirectory('$tree-logs') : [],
				baselineText: read('$tree-logs/baseline.json'),
				table: read('$tree-logs/${SliceGate.TABLE_FILE}')
			};
		});
		return ran;
	}

	/**
	 * The why of the corpus row of a scratch tree run alone: `fork` whether the corpus directory the environment names exists
	 * and `snapshot` whether the tree holds a snapshot. The tree's base holds no test build, so a base suite read fails fast.
	 */
	private static function corpusWhy(facts: CorpusFacts): String {
		var why: String = '';
		TempDir.with(dir -> {
			final tree: String = scratchTree(dir, BASE_REGISTRY, GRAPH_HXQ);
			final logs: String = '$tree-logs';
			FileSystem.createDirectory(Path.join([logs, 'rows']));
			File.saveContent(Path.join([tree, 'bin/apq.js']), 'built');
			if (facts.snapshot) File.saveContent(Path.join([tree, 'bin/.last-sweep.json']), '{}');
			final fork: String = dir.file('fork');
			if (facts.fork) FileSystem.createDirectory(fork);
			final saved: String = Sys.getEnv(FORK_VAR) ?? '';
			CliFixture.always(() -> Sys.putEnv(FORK_VAR, saved), () -> {
				Sys.putEnv(FORK_VAR, fork);
				Assert.equals(0, SliceGate.main([tree, '--rows', 'corpus', '--logs', logs, '--run', 'r']));
			});
			why = switch Branches.reportOf(Path.join([logs, 'rows/corpus.json']), 'r')?.steps[0]?.outcome {
				case Failed(reason), NotRun(reason): reason;
				case _: '';
			};
		});
		return why;
	}

}

/** What a `check()` over a scratch tree left: the rows each branch process was handed, and the leases asked of the pool. */
private typedef GateRan = {
	var branches: String;
	var leases: String;
	var status: Int;

	/** Each branch's log, by the first row it ran: what its process printed and why it was cut. */
	var rowLogs: Map<String, String>;

	/** The names the gate's logs directory holds afterwards, and the text of its `baseline.json` (empty when it has none). */
	var logsHad: Array<String>;

	var baselineText: String;


	/** The table the gate printed, for the message of a failed assertion. */
	var table: String;
}

/** What the corpus row of a scratch tree meets (`SliceGateTest.corpusWhy`). */
private typedef CorpusFacts = {
	var fork: Bool;
	var snapshot: Bool;
}
