package unit.dev;

import anyparse.ds.Set;
import haxe.io.Path;
import sys.FileSystem;
import unit.dev.WorkflowRoutes.WorkflowState;

using StringTools;

/**
 * The routes of the tracked `.claude/workflows/*.yaml` held as data (read by `WorkflowRoutes`).
 *
 * The engine applies an exec state's `context_set` only when the step exits 0, so a key it writes does not exist on a route
 * the state leaves by another case, `default`, `on_error` or `on_timeout`. `testNoFailureRouteReadsAKeyItsStateSetsOnSuccess`
 * walks every state reachable from such an exit and reports the first whose text mentions `context.<key>` before another
 * state writes the key; a route that comes back to the state itself ends there. It cannot see a key set by an agent's own
 * `transition set:` or `context_set` call, a key preloaded at `start`, a read through `{{stdout}}`, a key an earlier
 * successful visit left, or whether a path is taken at all (every transition of an ask state counts).
 *
 * The two scenario tests follow the chain a session takes, applying `context_set` on exit 0 only, so a route that depends
 * on a key set on a non-zero exit goes wrong there as it did in a session.
 */
@:nullSafety(Strict)
final class TrackedWorkflowRoutesTest extends Test {

	private static inline final HAND_LANDED: String = 'the parent landed it by hand out of triage: the table of the land that did not end 0 is '
		+ 'empty, and the reader prints it or falls back';
	private static inline final LOCK_MODE_KEPT: String =
		'the command of review_lock is `true`: its error route exists only because the engine requires one, and keeps the mode already set';
	private static inline final FLAGS_ACCUMULATE: String = 'an accumulator: a failed round reads the flags an earlier round or the parent left; '
		+ 'worker_end sets them from a finished worker only';
	private static inline final DESIGN_MARKER_ONLY: String = 'reads the verdict only for a `design=yes` marker, which the recorded verdict '
		+ 'never carries: a stale value from an earlier round answers the same';
	private static inline final LAST_REPORT: String =
		'prints the last successful sync report; the failure prompts carry the live output of the failing step as {{stdout}}';
	private static inline final CAME_FROM_TEXT: String =
		'names where the worker came from in a prompt; stale or empty after a failed step, part of the sync_from defect below';
	private static inline final RESUME_ROUTES_BY_STALE_KEY: String =
		'DEFECT, own queue line: sync_resume routes the resumed worker by sync_from, which a failed or conflicting step never sets';
	private static final ROOT: String = '.claude/workflows';
	private static final PIPELINE: String = '$ROOT/slice-pipeline.yaml';
	private static final COMMIT_MODE: String = '--commit';
	private static final SWEEP_NEXT_REVIEW: Int = 10;
	private static final MAX_PATH: Int = 40;
	private static final ENDS: Array<String> = ['review', 'recon_route', 'land'];

	/**
	 * `<file>:<state>/<key>/<reader>`: a state on a failure route of `<state>` that reads `<key>`, which `<state>` sets only on
	 * exit 0, and why that read is harmless (or a defect awaiting its own line). An entry no route reads any more fails.
	 */
	private static final TOLERATED: Map<String, String> = [
		'slice-campaign.yaml:land/land_table/bookkeeping' => HAND_LANDED,
		'slice-pipeline.yaml:land/land_table/bookkeeping' => HAND_LANDED,
		'slice-pipeline.yaml:land/land_table/cleanup' => HAND_LANDED,
		'slice-pipeline.yaml:land/land_table/mark_landed' => HAND_LANDED,
		'slice-pipeline.yaml:review_lock/lock_mode/sweep_lock' => LOCK_MODE_KEPT,
		'slice-pipeline.yaml:review_lock/lock_mode/sweep_next' => LOCK_MODE_KEPT,
		'slice-pipeline.yaml:review_end/verdict/review_route' => DESIGN_MARKER_ONLY,
		'slice-pipeline.yaml:worker_end/gate_flags/decided' => FLAGS_ACCUMULATE,
		'slice-pipeline.yaml:worker_end/gate_flags/fixes' => FLAGS_ACCUMULATE,
		'slice-pipeline.yaml:worker_end/gate_flags/gate_fix' => FLAGS_ACCUMULATE,
		'slice-pipeline.yaml:worker_end/gate_flags/land' => FLAGS_ACCUMULATE,
		'slice-pipeline.yaml:worker_end/gate_flags/regate' => FLAGS_ACCUMULATE,
		'slice-pipeline.yaml:worker_end/gate_flags/round_not_started' => FLAGS_ACCUMULATE,
		'slice-worker.yaml:sync_start/sync_report/fix' => LAST_REPORT,
		'slice-worker.yaml:sync_start/sync_report/implement' => LAST_REPORT,
		'slice-worker.yaml:sync_start_run/sync_report/fix' => LAST_REPORT,
		'slice-worker.yaml:sync_start_run/sync_report/implement' => LAST_REPORT,
		'slice-worker.yaml:sync_gate/sync_report/fix' => LAST_REPORT,
		'slice-worker.yaml:sync_gate/sync_report/implement' => LAST_REPORT,
		'slice-worker.yaml:sync_gate_run/sync_report/fix' => LAST_REPORT,
		'slice-worker.yaml:sync_gate_run/sync_report/implement' => LAST_REPORT,
		'slice-worker.yaml:sync_start/sync_from/sync_conflict' => CAME_FROM_TEXT,
		'slice-worker.yaml:sync_start/sync_from/sync_failed' => CAME_FROM_TEXT,
		'slice-worker.yaml:sync_start/sync_from/sync_resume' => RESUME_ROUTES_BY_STALE_KEY,
		'slice-worker.yaml:sync_start_run/sync_from/sync_conflict' => CAME_FROM_TEXT,
		'slice-worker.yaml:sync_start_run/sync_from/sync_failed' => CAME_FROM_TEXT,
		'slice-worker.yaml:sync_start_run/sync_from/sync_resume' => RESUME_ROUTES_BY_STALE_KEY,
		'slice-worker.yaml:sync_gate/sync_from/sync_conflict' => CAME_FROM_TEXT,
		'slice-worker.yaml:sync_gate/sync_from/sync_failed' => CAME_FROM_TEXT,
		'slice-worker.yaml:sync_gate/sync_from/sync_resume' => RESUME_ROUTES_BY_STALE_KEY,
		'slice-worker.yaml:sync_gate_run/sync_from/sync_conflict' => CAME_FROM_TEXT,
		'slice-worker.yaml:sync_gate_run/sync_from/sync_failed' => CAME_FROM_TEXT,
		'slice-worker.yaml:sync_gate_run/sync_from/sync_resume' => RESUME_ROUTES_BY_STALE_KEY
	];

	public function testNoFailureRouteReadsAKeyItsStateSetsOnSuccess(): Void {
		var checked: Int = 0;
		final used: Set<String> = new Set<String>();
		for (file in workflowFiles()) {
			final states: Map<String, WorkflowState> = WorkflowRoutes.statesOf(file);
			for (name => state in states) for (key in state.contextSet.keys()) for (target in WorkflowRoutes.failureTargets(state)) {
				checked++;
				for (reader in WorkflowRoutes.readersOn(states, name, target, key)) {
					final entry: String = '${Path.withoutDirectory(file)}:$name/$key/$reader';
					if (TOLERATED.exists(entry))
						used.add(entry);
					else
						utest.Assert.fail('$file: $name sets `$key` only on exit 0, but its route via $target reads it in $reader: $entry');
				}
			}
		}
		for (entry in TOLERATED.keys()) utest.Assert.isTrue(used.has(entry), 'TOLERATED entry no route reads any more: $entry');
		utest.Assert.isTrue(checked > 0, 'some state of the folder sets a context key and has a failure route');
	}

	public function testARoundThatEndsWithoutAFmtRaceGoesToReview(): Void {
		utest.Assert.same([
			'worker_end',
			'fmt_race_skip',
			'review_lock',
			'sweep_probe',
			'sweep_next',
			'review'
		], follow(WorkflowRoutes.statesOf(PIPELINE), 'worker_end', ['fmt_race_skip' => 10]));
	}

	public function testTheSweepLockNoteReachesTheParentOnEveryRefusalExit(): Void {
		final states: Map<String, WorkflowState> = WorkflowRoutes.statesOf(PIPELINE);
		final lock: Null<WorkflowState> = states['sweep_lock'];
		final ask: Null<WorkflowState> = states['sweep_ask'];
		final wait: Null<WorkflowState> = states['sweep_wait'];
		if (lock == null || ask == null || wait == null) {
			utest.Assert.fail('sweep_lock, sweep_wait and sweep_ask exist');
			return;
		}
		utest.Assert.equals('sweep_wait', WorkflowRoutes.nextOf(lock, 11));
		utest.Assert.equals('sweep_ask', wait.fields['on_exhausted']);
		utest.Assert.equals('sweep_ask', WorkflowRoutes.nextOf(lock, 12));
		utest.Assert.equals('sweep_ask', WorkflowRoutes.nextOf(lock, 13));
		utest.Assert.isTrue(ask.text.contains('{{stdout}}'), 'the ask prints the output of the step that sent it');
		utest.Assert.isFalse(WorkflowRoutes.reads(ask, 'lock_note'), 'no context key stands between the lock and the ask');
		final stray: Null<WorkflowState> = states['land_stray'];
		utest.Assert.isTrue(stray != null && stray.text.contains('{{stdout}}'), 'the stray-files ask prints the land output');
	}

	/** The verdict is read by `review_end` from the review session's record; no reviewer message carries a route to land. */
	public function testOnlyARecordedVerdictLeavesTheReviewForLandFixesOrReject(): Void {
		final states: Map<String, WorkflowState> = WorkflowRoutes.statesOf(PIPELINE);
		final end: Null<WorkflowState> = states['review_end'];
		final branch: Null<WorkflowState> = states['review_branch'];
		if (end == null || branch == null) {
			utest.Assert.fail('review_end and review_branch exist');
			return;
		}
		utest.Assert.equals('review_branch', WorkflowRoutes.nextOf(end, 0));
		utest.Assert.equals('review_running', WorkflowRoutes.nextOf(end, 3));
		utest.Assert.equals('review_dead', WorkflowRoutes.nextOf(end, 4));
		utest.Assert.equals('review_dead', WorkflowRoutes.nextOf(end, 99));
		utest.Assert.equals('land', WorkflowRoutes.nextOf(branch, 0));
		utest.Assert.equals('fixes', WorkflowRoutes.nextOf(branch, 1));
		utest.Assert.equals('reject', WorkflowRoutes.nextOf(branch, 2));
		utest.Assert.equals('review_dead', WorkflowRoutes.nextOf(branch, 4));
		final dead: Null<WorkflowState> = states['review_dead'];
		utest.Assert.isTrue(
			dead != null && dead.text.contains('set: {reviewer_agent: ""}'),
			'a dead review is redone by a fresh reviewer: respawn clears the warm-round marker review_route reads'
		);
		for (name in ['review', 'review_spawn', 'review_warm']) {
			final state: Null<WorkflowState> = states[name];
			if (state == null) {
				utest.Assert.fail('$name exists');
				continue;
			}
			for (verdictRoute in ['land', 'fixes', 'reject'])
				utest.Assert.isFalse(
					WorkflowRoutes.targetsOf(state).contains(verdictRoute), '$name must not route to $verdictRoute itself'
				);
		}
	}

	public function testAFreshLineGoesToReconRoute(): Void {
		utest.Assert.same(
			['prepare', 'sweep_probe', 'sweep_next', 'recon_route'], follow(WorkflowRoutes.statesOf(PIPELINE), 'prepare', [])
		);
	}

	/** The states a chain visits from `start`, each leaving by its scripted exit (0 when unscripted) until one of `ENDS`. */
	private static function follow(states: Map<String, WorkflowState>, start: String, exits: Map<String, Int>): Array<String> {
		final context: Map<String, String> = [];
		final path: Array<String> = [start];
		var at: String = start;
		while (!ENDS.contains(at) && path.length < MAX_PATH) {
			final state: Null<WorkflowState> = states[at];
			if (state == null) break;
			// `sweep_next` ends 10 exactly when its MODE is the commit mode: the command's own contract.
			final code: Int = at == 'sweep_next' ? (context['lock_mode'] == COMMIT_MODE ? SWEEP_NEXT_REVIEW : 0) : exits[at] ?? 0;
			if (code == 0) for (key => value in state.contextSet) context[key] = value;
			final next: Null<String> = WorkflowRoutes.nextOf(state, code);
			if (next == null) break;
			path.push(next);
			at = next;
		}
		return path;
	}

	private static function workflowFiles(): Array<String> {
		final out: Array<String> = [];
		if (FileSystem.exists(ROOT)) for (entry in FileSystem.readDirectory(ROOT)) if (entry.endsWith('.yaml')) out.push('$ROOT/$entry');
		return out;
	}

}
