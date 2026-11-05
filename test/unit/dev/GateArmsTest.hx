package unit.dev;

import dev.ArmRegistry;
import dev.GateArms;
import dev.GateTree;
import devkit.Cmd.cmd;
import devkit.Summary.Outcome;
import devkit.TempDir;
import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/** The arms row of a slice gate: which arms get the kill run, which only have to still apply, and whose a survivor is. */
@:nullSafety(Strict)
final class GateArmsTest extends Test {

	/**
	 * Stands in for `dev.js`. `--apply-only`: only M-OK's cut applies. Otherwise M-OWN survives only where the tree holds the slice,
	 * M-ROT, M-NEW and M-NEAR survive everywhere, `knobs/all-killed` kills them all, `knobs/exit-1` fails the process after its tally.
	 */
	private static final FAKE_DEV: String = "const fs=require('fs'),path=require('path');const a=process.argv.slice(2);"
		+ "const r=a.indexOf('--repo');const repo=r<0?process.cwd():a[r+1];const tree=path.dirname(path.dirname(process.argv[1]));"
		+ "const knob=n=>fs.existsSync(tree+'/knobs/'+n);fs.appendFileSync(tree+'/runs.log',(r<0?'at-slice ':'at-base ')+a.join(' ')+' "
		+ "HXQ_BIN='+process.env.HXQ_BIN+'\\n');if(a[0]==='worker-build')process.exit(fs.existsSync(tree+'/fail-base-build')?1:0);"
		+ "if(a.includes('--fast'))fs.appendFileSync(tree+'/progress.log',(process.env.APQ_ARMS_PROGRESS||'-')+'\\n');"
		+ "const names=a.slice(1).filter(x=>x.startsWith('M-'));if(a.includes('--apply-only')){const "
		+ "bad=names.filter(n=>n!=='M-OK');for(const n of bad)console.log('APPLY-FAIL  '+n+' why');console.log(names.length+' arms: "
		+ "'+(names.length-bad.length)+' apply, '+bad.length+' did not apply');process.exit(bad.length?1:0);}"
		+ "const slice=fs.readFileSync(repo+'/src/pkg/A.hx','utf8')==='slice';let k=0,s=0;const "
		+ "un=knob('unrendered')?fs.readFileSync(tree+'/knobs/unrendered','utf8'):'';for(const n of names){if(n===un)continue;const "
		+ "v=knob('all-killed')||n==='M-OK'||(n==='M-OWN'&&!slice)?'KILLED':'SURVIVED';v==='KILLED'?k++:s++;console.log(v+' '+n+' filter=x "
		+ "y');}console.log((k+s)+' tracks: '+k+' killed, '+s+' survived, 0 mismatch, 0 error');if(un)console.log('APPLY-FAIL  '+un+' "
		+ "why');process.exit(s||un||knob('exit-1')?1:0);";

	private static final REGISTRY: String = '{"arms": [{"name": "M-SAME", "type": "a.Untouched", "method": "f", "force": "1"},'
		+ '{"name": "M-LAYOUT", "type": "a.Reflowed", "method": "f", "force": "1"},{"name": "M-LAYOUT-SUB", "type": "a.Reflowed.Inner", '
		+ '"method": "f", "force": "1"},{"name": "M-EDITED", "type": "a.Edited", "method": "f", "force": "1"},{"name": "M-PINNED", "type": '
		+ '"a.Reflowed", "method": "g", "force": "1"},{"name": "M-ASKED", "type": "a.Untouched", "method": "g", "force": "1"}]}';

	/**
	 * Stands in for `hxq`, which the row runs from the tree: every call is logged, `changed` answers `knobs/changed`, the two graph
	 * calls answer `knobs/diff` and `knobs/focus`, or fail when `knobs/fail-diff` or `knobs/fail-focus` is there.
	 */
	private static final FAKE_HXQ: String = 'echo "$$*" >> hxq.log\n[ "$$1" = changed ] && { cat knobs/changed 2>/dev/null; exit 0; }\n'
		+ '[ "$$1" = graph ] || exit 0\nif [ "$$2" = --diff ]; then k=diff; else k=focus; fi\n'
		+ '[ -e knobs/fail-$$k ] && exit 1\ncat knobs/$$k 2>/dev/null || echo \'{"nodes": [], "edges": []}\'\n';

	/** The report of a slice that only reflowed the one file it touched. */
	private static final REFLOWED: String = 'M src/pkg/A.hx  layout\n';

	/** The arms of the base's registry, beside the `M-NEAR` every registry of `withTree` holds. */
	private static final BASE_ARMS: Array<String> = ['M-ROT', 'M-OWN', 'M-OK'];

	public function testAnArmOnAFileOfLayoutOnlyChangesOnlyHasToStillApply(): Void {
		final picked: ArmSelection = select(['a.Edited'], ['a.Reflowed'], ['M-PINNED'], ['M-ASKED']);
		Assert.same(['M-EDITED', 'M-PINNED', 'M-ASKED'], picked.fast);
		Assert.same(['M-LAYOUT', 'M-LAYOUT-SUB'], picked.applyOnly, 'a sub-type of the file counts, a pinned or asked arm does not');
	}

	public function testWithoutLayoutOnlyFilesEveryArmOnATouchedFileGetsTheKillRun(): Void {
		final picked: ArmSelection = select(['a.Edited', 'a.Reflowed'], [], [], []);
		Assert.same(['M-LAYOUT', 'M-LAYOUT-SUB', 'M-EDITED', 'M-PINNED'], picked.fast);
		Assert.same([], picked.applyOnly);
	}

	public function testAnArmNewSinceTheBaseGetsTheKillRunOnAnyFile(): Void {
		final base: String = '{"arms": [{"name": "M-SAME", "type": "a.Untouched", "method": "f", "force": "1"}]}';
		final picked: ArmSelection = GateArms.select(ArmRegistry.parse(REGISTRY), ArmRegistry.parse(base), [], ['a.Reflowed'], [], [], []);
		Assert.same(['M-LAYOUT', 'M-LAYOUT-SUB', 'M-EDITED', 'M-PINNED', 'M-ASKED'], picked.fast);
		Assert.same([], picked.applyOnly);
	}

	public function testTheFilesOfAChangedReportThatAreLayoutOnly(): Void {
		final report: String = [
			'changed against main: 5 file(s) — declarations 1, layout 3',
			'M tools/src/dev/A.hx  layout',
			'M tools/src/dev/B.hx  declarations  +4 -1',
			'    ~ FnMember:layout  +1 -1',
			'R100 tools/src/dev/C.hx  <- tools/src/dev/Old.hx  layout',
			'M docs/with space.hx  layout',
			''
		].join('\n');
		Assert.same(['tools/src/dev/A.hx', 'tools/src/dev/C.hx', 'docs/with space.hx'], GateArms.layoutOf(report));
		Assert.same([], GateArms.layoutOf(''));
	}

	/** A change to a member one call away makes an arm's pin stop discriminating with no file of the arm's or the pin's touched. */
	@:pin('control')
	@:killer('M-GATE-ARMS-NEIGHBOUR-BLIND')
	public function testAnArmOnACallNeighbourOfAChangedMemberGetsTheKillRun(): Void {
		final picked: ArmSelection = select([], ['a.Reflowed'], [], [], ['a.Untouched.g', 'a.Reflowed.g', 'a.Nowhere.f']);
		Assert.same(['M-PINNED', 'M-ASKED'], picked.fast, 'the neighbour is the arm\'s type and method together');
		Assert.same(['M-LAYOUT', 'M-LAYOUT-SUB'], picked.applyOnly);
	}

	/** A survivor that survives at the base too is named apart from the slice's own, an arm the base does not have is not asked. */
	@:pin('control')
	@:killer('M-GATE-ARMS-ROT-UNREAD')
	public function testASurvivorIsReadAgainAtTheBase(): Void {
		withTree(tree -> {
			final outcome: Outcome = outcomeOf(tree, []);
			Assert.isTrue(failedWith(outcome, 'rot on base: M-ROT; not killed: M-OWN, M-NEW — 4 tracks: 1 killed, 3 survived'), '$outcome');
			final runs: String = File.getContent(Path.join([tree, 'runs.log']));
			Assert.isTrue(runs.indexOf('at-base mutation-arm M-ROT M-OWN --fast') != -1, runs);
			Assert.isTrue(
				runs.indexOf('HXQ_BIN=/') != -1 && runs.indexOf('/base/bin/apq.js') != -1, 'the base run uses the base\'s engine:\n$runs'
			);
		});
	}

	@:pin('control')
	@:killer('M-GATE-ARMS-WAIVER-IGNORED')
	public function testAWaiverTakesOnlyTheArmsItNames(): Void {
		withTree(tree -> {
			Assert.isTrue(failedWith(outcomeOf(tree, ['M-ROT', 'M-NEW']), 'not killed: M-OWN — 4 tracks'), 'M-OWN is still the slice\'s');
			final gate: GateTree = gateOf(tree, ['M-ROT', 'M-OWN', 'M-NEW', 'M-OK']);
			Assert.isTrue(gate.summary.time('arms', GateArms.outcome.bind(gate)).match(Passed), 'every row that did not hold is waived');
			final row: String = gate.summary.table();
			Assert.isTrue(row.indexOf('waived: M-ROT, M-OWN, M-NEW') != -1, row);
			Assert.isTrue(row.indexOf('--allow-arm waives nothing: M-OK') != -1, row);
		});
	}

	public function testAWaiverNamingNoArmIsRefused(): Void {
		withTree(tree ->
			Assert.isTrue(failedWith(outcomeOf(tree, ['M-NOPE']), '--allow-arm M-NOPE names no arm'), 'a typo must not read as a waiver')
		);
	}

	/** The selection is held above; this is its wire, from the two graph calls through `outcome` to the kill run. */
	@:pin('control')
	@:killer('M-GATE-ARMS-NEIGHBOUR-UNWIRED')
	public function testAnArmOnACallNeighbourOfAChangedMemberReachesTheKillRun(): Void {
		withTree(tree -> {
			knob(tree, 'diff', graph([
				member('pkg.A.edited', 'changed'),
				member('pkg.A.added', 'added'),
				member('pkg.A.gone', 'removed'),
				node('type', 'pkg.A', 'changed')
			]));
			knob(tree, 'focus', graph([
				member('pkg.A.edited'),
				member('pkg.Other.near'),
				node('type', 'pkg.Far.near')
			]));
			knob(tree, 'all-killed');
			Assert.isTrue(outcomeOf(tree, []).match(Passed), 'every selected arm killed');
			final runs: String = File.getContent(Path.join([tree, 'runs.log']));
			Assert.isTrue(runs.indexOf('at-slice mutation-arm M-ROT M-OWN M-NEW M-OK M-NEAR --fast') != -1, runs);
			final calls: String = File.getContent(Path.join([tree, 'hxq.log']));
			Assert.isTrue(calls.indexOf('--focus pkg.A.edited src') != -1, 'only a member changed in place seeds:\n$calls');
		});
	}

	/** `graph --diff` compares by text, so a reflowed member reads as changed; it is no change a pin can see. */
	public function testAMemberOfALayoutOnlyFileSeedsNoNeighbour(): Void {
		withTree(tree -> {
			knob(tree, 'changed', REFLOWED);
			knob(tree, 'diff', graph([member('pkg.A.reflowed', 'changed'), member('pkg.A.Inner.reflowed', 'changed')]));
			Assert.isTrue(
				failedWith(outcomeOf(tree, []), '3 arms: 1 apply, 2 did not apply'), 'the arms of the reflowed file only have to apply'
			);
			final calls: String = File.getContent(Path.join([tree, 'hxq.log']));
			Assert.isTrue(calls.indexOf('--diff') != -1, calls);
			Assert.isTrue(calls.indexOf('--focus') == -1, 'no seed, no second graph call:\n$calls');
		});
	}

	public function testAGraphThatCannotBeReadDoesNotPassTheRow(): Void {
		withTree(tree -> {
			knob(tree, 'all-killed');
			final gate: GateTree = gateOf(tree, []);
			Assert.isTrue(
				gate.summary.time('arms', GateArms.outcome.bind(gate)).match(Passed), 'the same tree holds with the graph answering'
			);
			knob(tree, 'diff', graph([member('pkg.A.edited', 'changed')]));
			knob(tree, 'fail-focus');
			final focus: GateTree = gateOf(tree, []);
			Assert.isTrue(focus.summary.time('arms', GateArms.outcome.bind(focus)).match(NotRun(_)), 'the neighbours call failed');
			knob(tree, 'fail-diff');
			final diff: GateTree = gateOf(tree, []);
			Assert.isTrue(diff.summary.time('arms', GateArms.outcome.bind(diff)).match(NotRun(_)), 'the seeds call failed');
		});
	}

	/** Both runs of the row read one waiver: an arm the apply check waived is not reported as a waiver with nothing to waive. */
	public function testAWaiverReachesAnArmWhoseCutDidNotApply(): Void {
		withTree(tree -> {
			knob(tree, 'changed', REFLOWED);
			final gate: GateTree = gateOf(tree, ['M-ROT', 'M-OWN', 'M-NEW']);
			Assert.isTrue(gate.summary.time('arms', GateArms.outcome.bind(gate)).match(Passed), 'every failing row is waived');
			final row: String = gate.summary.table();
			Assert.isTrue(row.indexOf('waived: M-ROT, M-OWN, M-NEW') != -1, row);
			Assert.isTrue(row.indexOf('waives nothing') == -1, row);
			Assert.isTrue(
				failedWith(outcomeOf(tree, ['M-ROT']), '3 arms: 1 apply, 2 did not apply'), 'M-OWN did not apply and is not waived'
			);
		});
	}

	public function testARowWithoutAKillRunReadsItsWaivers(): Void {
		withTree(tree -> {
			knob(tree, 'changed', REFLOWED);
			final gate: GateTree = gateOf(tree, ['M-ROT', 'M-OWN', 'M-OK']);
			Assert.isTrue(gate.summary.time('arms', GateArms.outcome.bind(gate)).match(Passed), 'nothing asks for a kill run');
			final row: String = gate.summary.table();
			Assert.isTrue(row.indexOf('waived: M-ROT, M-OWN; --allow-arm waives nothing: M-OK') != -1, row);
			Assert.isTrue(File.getContent(Path.join([tree, 'runs.log'])).indexOf('--fast') == -1, 'the row ran no kill run');
		}, BASE_ARMS);
	}

	/** A clean tally is not the whole verdict: the run can still fail after it, and only a waived row excuses that. */
	@:pin('control')
	@:killer('M-GATE-ARMS-EXIT-IGNORED')
	public function testAKillRunThatFailsAfterACleanTallyFailsTheRow(): Void {
		withTree(tree -> {
			knob(tree, 'all-killed');
			Assert.isTrue(outcomeOf(tree, []).match(Passed), 'the same run holds when it exits clean');
			knob(tree, 'exit-1');
			final outcome: Outcome = outcomeOf(tree, []);
			Assert.isTrue(failedWith(outcome, 'no row explains the run (exit 1) — 4 tracks: 4 killed'), '$outcome');
		});
	}

	/**
	 * The kill run at the slice and the one at the base both hand the arms branch's progress file to the tracks, which rewrite it
	 * as each ends: a watched branch running many tracks is never cut for silence while it makes headway.
	 */
	@:pin('guard')
	public function testEveryKillRunHandsTheTracksTheBranchProgressFile(): Void {
		withTree(tree -> {
			Assert.isFalse(outcomeOf(tree, []).match(Passed), 'the survivors send the row to the base');
			final expected: String = Path.join(['$tree-logs', 'rows/arms.json.progress']);
			Assert.same([expected, expected], File.getContent(Path.join([tree, 'progress.log'])).trim().split('\n'));
		});
	}

	public function testABaseThatCannotBeReadCallsNoArmRotten(): Void {
		withTree(tree -> {
			File.saveContent(Path.join([tree, 'fail-base-build']), '');
			final outcome: Outcome = outcomeOf(tree, []);
			Assert.isTrue(failedWith(outcome, 'not killed: M-ROT, M-OWN, M-NEW; base not read: worker-build'), '$outcome');
		});
	}

	@:pin('control')
	@:killer('M-GATE-ARMS-UNRENDERED-PASSES')
	public function testAnArmThatDidNotRenderFailsTheRowBesideAWaivedSurvivor(): Void {
		withTree(tree -> {
			knob(tree, 'unrendered', 'M-NEW');
			final outcome: Outcome = outcomeOf(tree, ['M-ROT', 'M-OWN']);
			Assert.isTrue(
				failedWith(outcome, 'did not render: M-NEW'),
				'its row is outside the tally, so the waived survivors cannot account for it: $outcome'
			);
		});
	}

	public function testAWaivedArmThatDidNotRenderPassesWhenTheRestAreKilled(): Void {
		withTree(tree -> {
			knob(tree, 'all-killed');
			knob(tree, 'unrendered', 'M-NEW');
			Assert.isTrue(outcomeOf(tree, ['M-NEW']).match(Passed), 'the waiver reaches the row that is outside the tally');
			Assert.isTrue(failedWith(outcomeOf(tree, []), 'did not render: M-NEW'), 'unwaived, the same run fails the row');
		});
	}

	/** The row names the threads its kill run and its base run held, and a rot read on one thread says so beside the word rot. */
	@:pin('control')
	@:killer('M-GATE-ARMS-LEASE-UNNAMED')
	public function testTheRowNamesTheThreadsItsRunsHeld(): Void {
		withTree(tree -> {
			final tally: String = '4 tracks: 1 killed, 3 survived, 0 mismatch, 0 error';
			Assert.isTrue(
				failedWith(outcomeOf(tree, [], '1'), 'rot on base: M-ROT (both runs held 1 thread); not killed: M-OWN, M-NEW — $tally')
			);
			Assert.isTrue(failedWith(
				outcomeOf(tree, [], '4'),
				'rot on base: M-ROT; not killed: M-OWN, M-NEW — $tally — kill run held 4 threads, base run held 4 threads'
			));
			Assert.isTrue(failedWith(
				outcomeOf(tree, [], ''),
				'rot on base: M-ROT; not killed: M-OWN, M-NEW — $tally — kill run held no lease, base run held no lease'
			));
			knob(tree, 'all-killed');
			final gate: GateTree = gateOf(tree, []);
			withLease('1', () -> gate.summary.time('arms', () -> GateArms.outcome(gate)));
			Assert.stringContains('kill run held 1 thread', gate.summary.steps()[0].note);
		});
	}

	/** The excerpt, which the failed message's clip cannot cut, holds the threads line. */
	@:pin('control')
	@:killer('M-GATE-ARMS-THREADS-OUT-OF-EXCERPT')
	public function testTheExcerptOfAFailedRowHoldsTheThreadsLine(): Void {
		withTree(tree -> Assert.contains('kill run held 4 threads, base run held 4 threads', excerptOf(tree, '4')));
	}

	/** A base that was not read, or that no survivor exists at, names no base run: none ran. */
	@:pin('control')
	@:killer('M-GATE-ARMS-BASE-THREADS-UNGUARDED')
	public function testABaseRunThatDidNotRunHoldsNoThreads(): Void {
		withTree(tree -> {
			File.saveContent(Path.join([tree, 'fail-base-build']), '');
			final unread: Array<String> = excerptOf(tree, '4');
			Assert.contains('kill run held 4 threads', unread);
			Assert.same([], unread.filter(line -> line.contains('base run held')), unread.join('\n'));
		});
		withTree(tree -> {
			final unasked: Array<String> = excerptOf(tree, '4');
			Assert.contains('kill run held 4 threads', unasked);
			Assert.same([], unasked.filter(line -> line.contains('base run held')), unasked.join('\n'));
		}, ['M-NEW']);
	}

	private static function select(
		touched: Array<String>, layout: Array<String>, killers: Array<String>, extra: Array<String>, ?near: Array<String>
	): ArmSelection {
		final same: Array<ArmRecord> = ArmRegistry.parse(REGISTRY);
		return GateArms.select(same, same, touched, layout, killers, extra, near ?? []);
	}

	/** The row's outcome with the lease `held` (`WF_THREADS` text; empty is no lease) around both its runs. */
	private static function outcomeOf(tree: String, allowArms: Array<String>, held: String = '4'): Outcome {
		var outcome: Outcome = Passed;
		withLease(held, () -> outcome = GateArms.outcome(gateOf(tree, allowArms)));
		return outcome;
	}

	private static function withLease(held: String, body: () -> Void): Void {
		final saved: String = Sys.getEnv('WF_THREADS') ?? '';
		CliFixture.always(() -> Sys.putEnv('WF_THREADS', saved), () -> {
			Sys.putEnv('WF_THREADS', held);
			body();
		});
	}

	private static function failedWith(outcome: Outcome, start: String): Bool {
		return switch outcome {
			case Failed(why): why.startsWith(start);
			case _: false;
		};
	}

	private static function gateOf(tree: String, allowArms: Array<String>): GateTree {
		return new GateTree({
			tree: tree,
			logs: '$tree-logs',
			baseline: false,
			frozen: [],
			infra: [],
			arms: [],
			allow: [],
			allowArms: allowArms,
			noArms: false,
			threads: null,
			run: 'test'
		});
	}

	/**
	 * A slice commit over a base commit, with stand-ins for the tools the arms row runs: `dev.js` answers each arm's row by what
	 * the tree it was pointed at holds, so the row can tell a run at the base from a run at the slice.
	 */
	private static function withTree(body: String -> Void, ?sliceArms: Array<String>): Void {
		TempDir.with(dir -> {
			final tree: String = dir.file('tree');
			FileSystem.createDirectory(Path.join([tree, 'bin']));
			FileSystem.createDirectory(Path.join([tree, 'src/pkg']));
			FileSystem.createDirectory(Path.join([tree, ArmRegistry.DIRECTORY]));
			FileSystem.createDirectory('$tree-logs');
			File.saveContent(Path.join([tree, '.gitignore']), 'bin/\nknobs/\nruns.log\nprogress.log\nhxq.log\nfail-base-build\n');
			File.saveContent(Path.join([tree, 'bin/dev.js']), FAKE_DEV);
			File.saveContent(Path.join([tree, 'bin/test.js']), '');
			File.saveContent(Path.join([tree, 'bin/hxq']), FAKE_HXQ);
			File.saveContent(Path.join([tree, 'src/pkg/A.hx']), 'base');
			File.saveContent(Path.join([tree, ArmRegistry.DIRECTORY, 'pkg.json']), registry(BASE_ARMS));
			final git: Array<String> = ['-c', 'user.name=t', '-c', 'user.email=t@t'];
			cmd('git init -q -b main').at(tree).check();
			cmd('git add -A').at(tree).check();
			cmd('git $git commit -q -m base').at(tree).check();
			final base: String = cmd('git rev-parse HEAD').at(tree).check().out.trim();
			File.saveContent(Path.join([tree, 'src/pkg/A.hx']), 'slice');
			File.saveContent(
				Path.join([tree, ArmRegistry.DIRECTORY, 'pkg.json']), registry(sliceArms ?? ['M-ROT', 'M-OWN', 'M-NEW', 'M-OK'])
			);
			cmd('git add -A').at(tree).check();
			cmd('git $git commit -q -m slice').at(tree).check();
			File.saveContent(
				'$tree-logs/baseline.json', Json.stringify({
					base: base,
					tests: 0,
					assertions: 0,
					lists: {},
					lint: '',
					infra: [],
					frozen: []
				})
			);
			body(tree);
		});
	}

	private static function registry(names: Array<String>): String {
		final rows: Array<String> = [
			for (name in names) '{"name": "$name", "type": "pkg.A", "method": "f", "force": "1"}'
		];
		rows.push('{"name": "M-NEAR", "type": "pkg.Other", "method": "near", "force": "1"}');
		return '{"arms": [${rows.join(', ')}]}';
	}

	private static function knob(tree: String, name: String, text: String = ''): Void {
		FileSystem.createDirectory(Path.join([tree, 'knobs']));
		File.saveContent(Path.join([tree, 'knobs', name]), text);
	}

	private static function graph(nodes: Array<String>): String {
		return '{"nodes": [${nodes.join(', ')}], "edges": []}';
	}

	private static function member(name: String, ?change: String): String {
		return node('member', name, change);
	}

	/** The excerpt lines of the failed arms row of `tree` under the lease `held`. */
	private static function excerptOf(tree: String, held: String): Array<String> {
		final gate: GateTree = gateOf(tree, []);
		withLease(held, () -> gate.summary.time('arms', () -> GateArms.outcome(gate)));
		return gate.summary.steps()[0].excerpt;
	}

	private static function node(level: String, name: String, ?change: String): String {
		final shape: String = '"id": "$name", "level": "$level", "name": "$name", "label": "$name", "external": false, "focus": false';
		return change == null ? '{$shape}' : '{$shape, "change": "$change"}';
	}

}
