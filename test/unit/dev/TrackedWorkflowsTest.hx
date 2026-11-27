package unit.dev;

import anyparse.util.Compare;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The tracked `.claude/workflows` folder is portable: no file of it names a path of one machine, so a checkout anywhere
 * renders the same workflows through `{{project_root}}`; an exec command reads the checkout from the quoted
 * `$WF_PROJECT_ROOT` instead, since an unquoted interpolation breaks on a path holding a space. The per-machine toggle
 * `lib/recon-arm` is the one file the folder leaves ignored, and is not read here.
 */
@:nullSafety(Strict)
final class TrackedWorkflowsTest extends Test {

	private static final ROOT: String = '.claude/workflows';
	private static final MACHINE_PATHS: Array<String> = ['/Users/', '/home/', 'C:\\', '$$HOME/dev', 'mcp-workflow-engine/'];
	private static final NO_BACKGROUND_FLOWS: Array<String> = ['research-task', 'slice-pipeline', 'slice-worker'];

	public function testNoTrackedWorkflowFileNamesAPathOfOneMachine(): Void {
		final files: Array<String> = filesUnder(ROOT);
		utest.Assert.isTrue(files.length > 0, 'the workflows folder is read from the repository root');
		for (file in files) {
			final text: String = File.getContent(file);
			for (path in MACHINE_PATHS) utest.Assert.isFalse(text.contains(path), '$file names $path');
		}
	}

	public function testNoExecCommandInterpolatesTheProjectRootUnquoted(): Void {
		for (file in filesUnder(ROOT)) if (file.endsWith('.yaml')) {
			var inCommand: Bool = false;
			for (line in File.getContent(file).split('\n')) {
				if (line.startsWith('    ') && !line.startsWith('     ')) inCommand = line.startsWith('    command:');
				if (inCommand)
					utest.Assert.isFalse(
						line.contains('{{project_root}}'), '$file: a command interpolates {{project_root}}: ${line.trim()}'
					);
			}
		}
	}

	public function testABlockedSliceWaitsForTheUserAtAHumanStateThatFreesTheSlot(): Void {
		final pipeline: String = File.getContent('$ROOT/slice-pipeline.yaml');
		final ask: String = stateBlock(pipeline, 'blocked_ask');
		utest.Assert.isTrue(ask.contains('\n    human:'), 'blocked_ask is a human wait');
		utest.Assert.isFalse(ask.contains('ask: parent'), 'a human wait is not a NEEDS-PARENT hold');
		for (route in [
			'decided: decided',
			'close: mark_closed',
			'stop: mark_stopped',
			'split: mark_split'
		]) utest.Assert.isTrue(ask.contains('      $route'), 'blocked_ask routes $route');
		utest.Assert.isTrue(stateBlock(pipeline, 'blocked').contains('      ask_user: blocked_ask'), 'blocked reaches the wait');
		utest.Assert.isTrue(stateBlock(pipeline, 'decided').contains('{{context.human_answer}}'), 'decided reads the user call');
	}

	public function testTheDispatcherRelaysAHumanWaitAndResumesItsAnsweredLine(): Void {
		final dispatch: String = File.getContent('$ROOT/slice-dispatch.yaml');
		utest.Assert.isTrue(stateBlock(dispatch, 'dispatch').contains('`resume=<P>`'), 'dispatch resumes an answered row');
		final collect: String = stateBlock(dispatch, 'collect');
		utest.Assert.isTrue(collect.contains('`AWAITING task=<ID>'), 'collect relays the question');
		utest.Assert.isTrue(collect.contains('      refill: pick'), 'an answer refills the window');
	}

	public function testEveryHumanStateHasRoutesAndNoParentAsk(): Void {
		for (file in filesUnder(ROOT)) if (file.endsWith('.yaml')) {
			final text: String = File.getContent(file);
			for (line in text.split('\n')) if (
				line.startsWith('  ') && !line.startsWith('   ') && line.endsWith(':') && !line.startsWith('  #')
			) {
				final block: String = stateBlock(text, line.trim().substr(0, line.trim().length - 1));
				if (!block.contains('\n    human:')) continue;
				utest.Assert.isTrue(block.contains('\n    transitions:'), '$file: ${line.trim()} has routes');
				utest.Assert.isFalse(block.contains('\n    ask: parent'), '$file: ${line.trim()} also asks the parent');
			}
		}
	}

	public function testLessonRecordsCarryADestAndNoTaskFlowWritesStatusIntoMemory(): Void {
		for (file in ['slice-worker', 'slice-review']) {
			final text: String = File.getContent('$ROOT/$file.yaml');
			utest.Assert.isTrue(text.contains('"kind": "<class>", "dest": "<dest>"'), '$file: a lesson record has the dest key');
			utest.Assert.isTrue(text.contains('memory (none of the others fits)'), '$file: the dest words are listed');
		}
		utest.Assert.isTrue(
			File.getContent('$ROOT/research-task.yaml').contains('`- <dest> | <repo> | <exact text or edit>`'),
			'the research close carries dest rows'
		);
		utest.Assert.isTrue(
			File.getContent('$ROOT/slice-dispatch.yaml').contains('knowledge-placement'), 'the memory-note fork cites the skill'
		);
		for (file in ['task-night-cleanup', 'task-lint-cleanup', 'task-deferred-followups']) {
			final text: String = File.getContent('$ROOT/$file.yaml').replace('\n', ' ').replace('  ', ' ');
			for (status in ['Update project memory', 'update memory', 'memory topic file'])
				utest.Assert.isFalse(text.contains(status), '$file writes status into memory: $status');
			utest.Assert.isTrue(text.contains('knowledge-placement'), '$file places a lesson through the skill');
		}
	}

	/**
	 * A brief that names `run_in_background` teaches the leak it forbids: a shell its agent leaves live at a turn end sends the
	 * wake to the main conversation. The three flows that brief agents wait in the foreground, and each agent brief states
	 * the rule instead.
	 */
	public function testNoAgentBriefNamesRunInBackgroundAndEachStatesTheForegroundRule(): Void {
		for (flow in NO_BACKGROUND_FLOWS) {
			final text: String = File.getContent('$ROOT/$flow.yaml');
			utest.Assert.isFalse(text.contains('run_in_background'), '$flow names run_in_background');
		}
		final rule: String = 'you own no live background shell';
		utest.Assert.equals(
			2, File.getContent('$ROOT/research-task.yaml').toLowerCase().split(rule).length - 1, 'investigator and verifier carry the rule'
		);
		utest.Assert.equals(
			1, File.getContent('$ROOT/slice-pipeline.yaml').toLowerCase().split(rule).length - 1, 'the splitter carries the rule'
		);
	}

	/**
	 * A reviewed MERGE reaches `land` only through `look_route`, which sends a line whose `human_gate:` is due to the `owner_look`
	 * wait; no other state may route to `land` except the retries after a land attempt, so a new route here fails this test.
	 */
	public function testALineWithAHumanGateCannotReachTheLandWithoutPassingTheWait(): Void {
		final pipeline: String = File.getContent('$ROOT/slice-pipeline.yaml');
		final branch: String = stateBlock(pipeline, 'review_branch');
		utest.Assert.isTrue(branch.contains('"0": look_route'), 'a MERGE verdict goes to the gate check');
		utest.Assert.isFalse(branch.contains(': land'), 'review_branch never routes to land itself');
		final look: String = stateBlock(pipeline, 'look_route');
		utest.Assert.isTrue(look.contains('--gate "$$SLICE"'), 'look_route asks the queue whether the gate is due');
		utest.Assert.isTrue(look.contains('"10": owner_look'), 'exit 10 (gate due) enters the owner wait');
		utest.Assert.isTrue(look.contains('"0": land'), 'exit 0 (no gate due) lands');
		utest.Assert.isTrue(look.contains('default: look_failed'), 'an unreadable queue never lands');
		final owner: String = stateBlock(pipeline, 'owner_look');
		utest.Assert.isTrue(owner.contains('\n    human:'), 'owner_look is a human wait');
		utest.Assert.isTrue(owner.contains('passes: [go]'), 'only go passes the gate');
		for (route in ['go: land', 'fix: owner_fix', 'close: mark_closed'])
			utest.Assert.isTrue(owner.contains('      $route'), 'owner_look routes $route');
		utest.Assert.isTrue(
			stateBlock(pipeline, 'owner_fix').contains('      worker_done: worker_end'), 'an owner fix returns through review'
		);
		final routers: Array<String> = [];
		var state: String = '';
		for (line in pipeline.split('\n')) {
			if (line.startsWith('  ') && !line.startsWith('   ') && !line.startsWith('  #') && line.endsWith(':')) state = line.trim();
			final text: String = line.trim();
			if (!text.startsWith('#') && text.endsWith(': land') && !routers.contains(state)) routers.push(state);
		}
		routers.sort(Compare.compareString);
		utest.Assert.equals(
			'fmt_race_skip:,land_stray:,land_timeout:,look_route:,owner_look:,triage:', routers.join(','), 'the states that route to land'
		);
	}

	private static function filesUnder(dir: String): Array<String> {
		final out: Array<String> = [];
		if (!FileSystem.exists(dir)) return out;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$entry';
			if (FileSystem.isDirectory(path))
				for (nested in filesUnder(path)) out.push(nested);
			else if (path != '$ROOT/lib/recon-arm')
				out.push(path);
		}
		return out;
	}

	private static function stateBlock(text: String, name: String): String {
		final out: Array<String> = [];
		var inside: Bool = false;
		for (line in text.split('\n')) {
			final isStateKey: Bool = line.startsWith('  ') && !line.startsWith('   ') && !line.startsWith('  #') && line.endsWith(':');
			if (isStateKey) inside = line == '  $name:';
			if (inside) out.push(line);
		}
		return '\n' + out.join('\n');
	}

}
