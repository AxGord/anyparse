package dev;

import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JValueWriter;
import anyparse.grammar.json.JsonFormat;
import anyparse.util.Compare;
import dev.ModelTable.TableRow;
import dev.SliceStats.Landing;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Table;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using anyparse.util.Groups;
using Lambda;
using StringTools;

/** One agent's share of a ledger session: the stage it ran (null before the ledger named stages) and its cost at `TokenReport.PRICES`. */
typedef AgentSpend = { var id: String; var stage: Null<String>; var usd: Float; }

/**
 * One session of the workflow engine as the curator report reads it, times in ms since the epoch: a finished one from its
 * ledger row, a `running` one from its state file, ended at the window's end. `arms` maps a stage to the `model/effort` it ran on;
 * `parentUsd` is the share of the parent conversation's spend the ledger booked on this row.
 */
typedef LedgerSession = {

	var id: String;
	var parent: String;
	var root: String;
	var workflow: String;
	var project: String;
	var task: String;
	var started: Float;
	var ended: Float;
	var running: Bool;
	var landed: Bool;
	var difficulty: Null<Int>;
	var rounds: Int;
	var arms: Map<String, String>;

	/** The row carries a spend record (the ledger kept none before it priced agents). */
	var measured: Bool;
	var usd: Float;
	var agents: Array<AgentSpend>;
	var conversation: Null<String>;
	var conversationDir: Null<String>;
	var parentUsd: Float;

}

/**
 * The landed slices of one stage, difficulty band and arm: how many, the median slice $, the mean $ of the stage (null when no
 * row named its stages), the mean review rounds, the share that passed review at once, the mean review findings (null when unknown).
 */
typedef BandCell = {
	var stage: String;
	var from: Int;
	var upto: Int;
	var arm: String;
	var n: Int;
	var median: Float;
	var stageUsd: Null<Float>;
	var rounds: Float;
	var oneRound: Float;
	var findings: Null<Float>;
}

/** A band a model-table commit moved to another arm: its slices on the previous arm before the commit and on the new one after. */
typedef TableMove = {
	var commit: String;
	var at: Float;
	var before: BandCell;
	var after: BandCell;
}

/** The slot-hours left idle for one cause. */
typedef IdleCause = { var cause: String; var slotHours: Float; }

/** A commit of the workflow file that changed its model table: the table before and after it. */
typedef TableChange = {
	var commit: String;
	var at: Float;
	var before: Array<TableRow>;
	var after: Array<TableRow>;
}

/** What a report is computed from; `findings` answers the review findings of a landed session, null when unknown. */
typedef CuratorInput = {

	var sessions: Array<LedgerSession>;
	var project: String;
	var from: Float;
	var to: Float;
	var table: Array<TableRow>;
	var tableChanges: Array<TableChange>;
	var gitLands: Int;
	var exclusive: Array<String>;

	/** The slot count, or 0 for the most sessions the window's dispatchers ran at once. */
	var slots: Int;
	var findings: LedgerSession -> Null<Int>;

}

/** The curator's counting over one window: the lands and their money, the band cells, idle slots, table moves, coverage, flags. */
typedef CuratorSummary = {
	var from: Float;
	var to: Float;
	var lands: Int;
	var gitLands: Int;
	var landUsd: Float;
	var nonLanding: Int;
	var nonLandingUsd: Float;
	var parentUsd: Float;
	var allLands: Int;
	var slots: Int;
	var slotHours: Float;
	var idle: Array<IdleCause>;
	var cells: Array<BandCell>;
	var moves: Array<TableMove>;
	var coverage: Array<BandCell>;
	var flags: Array<String>;
}

/**
 * `dev curator-report` — the one answer to "what did the lands since the last curator run cost, per stage, band and arm, and
 * where did the slots idle": the engine's ledger (and the state files of the sessions still running) read over a window of lands,
 * every agent priced at `TokenReport.PRICES`, the bands of the `slice-pipeline` model table, the table's commits in git, the
 * review findings from the workers' transcripts. It counts and flags mechanically; judging a flag is a person's or an agent's job.
 */
@:nullSafety(Strict)
final class CuratorReport {

	public static inline final USAGE: String = 'usage: dev curator-report [--since <rev> | --lands <n>] [--until <rev>] [--slots <n>] [--json] '
		+ '[--ledger <file>] [--state <dir>] [--queue <file>] [--project <dir>] [--repo <tree>]';

	/** The lands of a window when neither `--since` nor `--lands` names one: the curator's cadence. */
	public static inline final DEFAULT_LANDS: Int = 20;

	/** A table move is flagged only when both of its sides hold at least this many slices. */
	public static inline final FLAG_MIN_N: Int = 10;

	/** A flagged move of the median $/land: more than this share of the previous arm's. */
	public static inline final FLAG_USD_SHARE: Float = 0.15;

	/** A flagged move of the mean review rounds: at least this many. */
	public static inline final FLAG_ROUNDS: Float = 0.3;

	/** A flagged idle cause: more than this share of all idle slot-hours. */
	public static inline final FLAG_IDLE_SHARE: Float = 0.2;

	/** A coverage cell with fewer slices than this is listed as thin. */
	public static inline final THIN_N: Int = 6;

	/**
	 * A free slot inside a stretch this long with no session started is
	 * idle for want of a start (a dispatcher down, or nothing to admit).
	 */
	public static inline final NO_START_HOURS: Float = 3;

	public static final CAUSE_NO_START: String = 'no-start>=3h';
	public static final CAUSE_EXCLUSIVE: String = 'exclusive';
	public static final CAUSE_OTHER: String = 'other';

	private static inline final MS_PER_SECOND: Float = 1000;
	private static inline final MS_PER_MINUTE: Float = 60000;
	private static inline final MS_PER_HOUR: Float = 3600000;
	private static inline final MS_PER_DAY: Float = 86400000;
	private static inline final PERCENT: Float = 100;
	private static final STAGE: String = 'stage';
	private static final MODEL: String = 'model';
	private static final PIPELINE: String = 'slice-pipeline';
	private static final EXECUTE: String = 'execute';
	private static final PLAN: String = 'plan';
	private static final EFFORT: String = 'effort';
	private static final REVIEW: String = 'review';
	private static final WORKFLOW_FILE: String = '.claude/workflows/slice-pipeline.yaml';
	private static final QUEUE_FILE: String = '.claude/batch/queue.yaml';
	private static final LEDGER_FILE: String = 'ledger.jsonl';
	private static final FIX_ROUND: String = 'Review fix round';
	private static final PLACEHOLDER: EReg = ~/^Review fix round: *</;
	private static final STATE_FILE: EReg = ~/^[0-9a-f]{8}\.json$/;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final since: Null<String> = args.option('--since');
		final landsArg: Null<String> = args.option('--lands');
		final until: Null<String> = args.option('--until');
		final slotsArg: Null<String> = args.option('--slots');
		final asJson: Bool = args.flag('--json');
		final tree: String = Repo.resolve(args.option('--repo'));
		final project: String = args.option('--project') ?? mainTree(tree);
		final state: String = args.option('--state') ?? stateDir();
		final ledger: String = args.option('--ledger') ?? Path.join([state, LEDGER_FILE]);
		final queue: String = fileText(args.option('--queue') ?? Path.join([project, QUEUE_FILE]));
		final projects: String = Path.directory(TokenAudit.projectOf(tree));
		args.done();
		if (since != null && landsArg != null) throw new UsageError('--since and --lands name a window each; give one');
		if (!FileSystem.exists(ledger)) throw new UsageError('no ledger $ledger');
		final lands: Int = count(landsArg, '--lands') ?? DEFAULT_LANDS;
		final slots: Int = count(slotsArg, '--slots') ?? 0;
		final finished: Array<LedgerSession> = readLedger(File.getContent(ledger));
		final to: Float = until == null ? Date.now().getTime() : boundary(finished, project, until);
		final from: Float = since == null ? landsFrom(finished, project, lands, to) : boundary(finished, project, since);
		final summary: CuratorSummary = summarize(
			gather(projects, project, finished.concat(readLive(state, finished, to)), from, to, until, queue, slots)
		);
		Sys.println(
			asJson ? json(summary) : render(summary, since == null ? 'last $lands lands to ${until ?? 'now'}' : '$since..${until ?? 'now'}')
		);
		return 0;
	}

	/** Every session of the ledger `text` (one JSON row per line); a line that is not JSON is skipped. */
	public static function readLedger(text: String): Array<LedgerSession> {
		final out: Array<LedgerSession> = [];
		for (line in text.split('\n')) if (line.trim() != '') {
			final row: Null<JValue> = try JValueParser.parse(line) catch (_: Exception) null;
			if (row != null) out.push(sessionOf(row));
		}
		return out;
	}

	/**
	 * The session of one ledger row. A row with no execute agent was executed by its plan agent (the plan stage hands its worker
	 * on to execute), so that agent is booked as execute.
	 */
	public static function sessionOf(row: JValue): LedgerSession {
		final records: Array<JValue> = JValueTools.items(JValueTools.at(row, 'spend.by_agent'));
		final handedOver: Bool = !records.exists(agent -> JValueTools.stringAt(agent, STAGE) == EXECUTE);
		final agents: Array<AgentSpend> = records.map(agent -> agentOf(agent, handedOver));
		final arms: Map<String, String> = armsOf(row, handedOver);
		final difficulty: Null<Float> = number(JValueTools.field(row, 'difficulty'));
		final parentSpend: Null<JValue> = JValueTools.field(row, 'parent_spend');
		return {
			id: JValueTools.stringAt(row, 'session_id') ?? '',
			parent: JValueTools.stringAt(row, 'parent_session_id') ?? '',
			root: JValueTools.stringAt(row, 'root_session_id') ?? '',
			workflow: JValueTools.stringAt(row, 'workflow') ?? '',
			project: JValueTools.stringAt(row, 'project') ?? '',
			task: JValueTools.stringAt(row, 'task') ?? '',
			started: js.lib.Date.parse(JValueTools.stringAt(row, 'started_at') ?? ''),
			ended: js.lib.Date.parse(JValueTools.stringAt(row, 'ended_at') ?? ''),
			running: false,
			landed: JValueTools.at(row, 'visits.mark_landed') != null || JValueTools.at(row, 'visits.mark_done') != null,
			difficulty: difficulty == null ? null : Std.int(difficulty),
			rounds: Std.int(number(JValueTools.at(row, 'visits.review')) ?? 0),
			arms: arms,
			measured: JValueTools.field(row, 'spend') != null,
			usd: agents.length > 0 ? agents.fold((agent, sum) -> sum + agent.usd, 0.0) : number(JValueTools.at(row, 'spend.usd')) ?? 0,
			agents: agents,
			conversation: JValueTools.stringAt(parentSpend, 'conversation'),
			conversationDir: JValueTools.stringAt(parentSpend, 'project'),
			parentUsd: number(JValueTools.field(parentSpend, 'usd')) ?? 0
		};
	}

	/**
	 * What one `spend.by_agent` record cost at `TokenReport.PRICES`. The ledger keeps one cache-write count; the agents write the
	 * one-hour cache, so it is priced at that multiple, which is what their transcripts' split prices it at.
	 */
	public static function agentUsd(agent: JValue): Float {
		return TokenReport.costOf({
			model: JValueTools.stringAt(agent, MODEL) ?? '',
			start: 0,
			end: 0,
			input: Std.int(number(JValueTools.field(agent, 'input')) ?? 0),
			output: Std.int(number(JValueTools.field(agent, 'output')) ?? 0),
			cacheRead: Std.int(number(JValueTools.field(agent, 'cache_read')) ?? 0),
			write5m: 0,
			write1h: Std.int(number(JValueTools.field(agent, 'cache_write')) ?? 0)
		});
	}

	/** The session of one engine state file still running (no `outcome`), ended at `to`; null for a finished one. */
	public static function liveOf(state: JValue, to: Float): Null<LedgerSession> {
		return JValueTools.field(state, 'outcome') != null ? null : {
			id: JValueTools.stringAt(state, 'session_id') ?? '',
			parent: JValueTools.stringAt(state, 'parent_session_id') ?? '',
			root: JValueTools.stringAt(state, 'root_session_id') ?? '',
			workflow: JValueTools.text(JValueTools.at(state, 'stack.0.workflow')) ?? '',
			project: JValueTools.text(JValueTools.at(state, 'context.project_root')) ?? '',
			task: JValueTools.text(JValueTools.at(state, 'context.task')) ?? '',
			started: js.lib.Date.parse(JValueTools.stringAt(state, 'started_at') ?? ''),
			ended: to,
			running: true,
			landed: false,
			difficulty: null,
			rounds: 0,
			arms: [],
			measured: false,
			usd: 0,
			agents: [],
			conversation: null,
			conversationDir: null,
			parentUsd: 0
		};
	}

	/**
	 * The start of a window of the last `lands` lands of `project` that ended by `to`: the end of the land before them, so a window
	 * starts where the previous one ended; with no land before them, just before the first of them began.
	 */
	public static function landsFrom(sessions: Array<LedgerSession>, project: String, lands: Int, to: Float): Float {
		final landed: Array<LedgerSession> = sessions.filter(s -> isPipeline(s, project) && s.landed && s.ended <= to);
		landed.sort((a, b) -> Reflect.compare(a.ended, b.ended));
		if (landed.length > lands) return landed[landed.length - lands - 1].ended;
		return landed.length == 0 ? to : landed.fold((s, first) -> Math.min(s.started, first), to) - 1;
	}

	/**
	 * The report over `input`'s window: the `project`'s `slice-pipeline` sessions that ended inside (`from`, `to`], the
	 * parent's spend of their conversations pro-rated by the lands of their dispatch trees, the cells of the window's lands,
	 * the slot-minutes their dispatchers left idle, each model-table move with the slices of the whole ledger on both sides,
	 * the coverage of the table's cells over the whole ledger, and the flags.
	 */
	public static function summarize(input: CuratorInput): CuratorSummary {
		final inWindow: LedgerSession -> Bool = s -> !s.running && s.ended > input.from && s.ended <= input.to;
		final rows: Array<LedgerSession> = input.sessions.filter(s -> isPipeline(s, input.project) && inWindow(s));
		final landed: Array<LedgerSession> = rows.filter(s -> s.landed);
		final rest: Array<LedgerSession> = rows.filter(s -> !s.landed);
		final roots: Array<String> = distinct(rows.map(s -> s.root));
		final conversations: Array<String> = distinct([ for (s in rows) s.conversation ?? continue ]);
		final window: Array<LedgerSession> = input.sessions.filter(inWindow);
		final history: Array<LedgerSession> = input.sessions.filter(s ->
			isPipeline(s, input.project) && !s.running && s.landed && s.measured && s.ended <= input.to
		);
		final moves: Array<TableMove> = movesOf(history, input.tableChanges);
		final dispatchers: Array<String> = distinct(rows.map(s -> s.parent));
		final occupants: Array<LedgerSession> = input.sessions.filter(s ->
			dispatchers.contains(s.parent) && s.started < input.to && s.ended > input.from
		);
		final slots: Int = input.slots > 0 ? input.slots : peakOf(occupants, input.from, input.to);
		final idle: Array<IdleCause> = idleOf(occupants, input.from, input.to, slots, input.exclusive);
		return {
			from: input.from,
			to: input.to,
			lands: landed.length,
			gitLands: input.gitLands,
			landUsd: total(landed),
			nonLanding: rest.length,
			nonLandingUsd: total(rest),
			parentUsd: window.fold(
				(s, sum) -> s.conversation != null && conversations.contains(s.conversation) ? sum + s.parentUsd : sum, 0.0
			),
			allLands: window.filter(s -> s.landed && roots.contains(s.root)).length,
			slots: slots,
			slotHours: slots * (input.to - input.from) / MS_PER_HOUR,
			idle: idle,
			cells: cellsOf(landed, input.table, [ for (s in landed) s.id => input.findings(s) ]),
			moves: moves,
			coverage: coverageOf(history, input.table, moves),
			flags: flagsOf(moves, idle)
		};
	}

	/** The cells of `rows`, by stage in the table's order, then by band and arm; a row whose difficulty no band holds is left out. */
	public static function cellsOf(rows: Array<LedgerSession>, table: Array<TableRow>, findings: Map<String, Null<Int>>): Array<BandCell> {
		final out: Array<BandCell> = [];
		for (stage in ModelTable.stages(table)) {
			final cells: Array<BandCell> = [];
			for (band in table) if (band.stage == stage) {
				final inBand: Array<LedgerSession> = rows.filter(row ->
					row.difficulty != null && band.from <= row.difficulty && row.difficulty <= band.upto
				);
				final arms: Array<String> = distinct([ for (row in inBand) armOf(row, stage) ?? continue ]);
				arms.sort(Compare.compareString);
				for (arm in arms) cells.push(cellOf(stage, band, arm, inBand.filter(row -> armOf(row, stage) == arm), findings));
			}
			for (cell in cells) out.push(cell);
		}
		return out;
	}

	/** The cell of `rows` on `stage`'s band and `arm`; `findings` holds what is known of each row's review findings. */
	public static function cellOf(
		stage: String, band: TableRow, arm: String, rows: Array<LedgerSession>, findings: Map<String, Null<Int>>
	): BandCell {
		final staged: Array<LedgerSession> = rows.filter(row -> row.agents.exists(agent -> agent.stage != null));
		final known: Array<Int> = [ for (row in rows) findings[row.id] ?? continue ];
		final n: Int = rows.length;
		return {
			stage: stage,
			from: band.from,
			upto: band.upto,
			arm: arm,
			n: n,
			median: SliceStats.median(rows.map(row -> row.usd)),
			stageUsd: staged.length == 0
				? null
				: staged.fold(
					(row, sum) -> sum + row.agents.fold((agent, own) -> agent.stage == stage ? own + agent.usd : own, 0.0), 0.0
				) / staged.length,
			rounds: n == 0 ? 0 : rows.fold((row, sum) -> sum + row.rounds, 0) / n,
			oneRound: n == 0 ? 0 : rows.filter(row -> row.rounds <= 1).length / n,
			findings: known.length == 0 ? null : known.fold((items, sum) -> sum + items, 0) / known.length
		};
	}

	/**
	 * The arm `row` ran `stage` on, or null when it did not run it: an agent of the row ran the stage, or — a row from before
	 * the ledger named stages — the stage is execute or review, which every landed slice ran.
	 */
	public static function armOf(row: LedgerSession, stage: String): Null<String> {
		final ran: Bool = row.agents.exists(agent -> agent.stage == stage)
			|| (!row.agents.exists(agent -> agent.stage != null) && (stage == EXECUTE || stage == REVIEW));
		return ran ? row.arms[stage] : null;
	}

	/**
	 * Each band of each table commit whose arm the commit changed: the landed slices of the band on the arm the old table gave
	 * their difficulty, begun before the commit, against the slices on the new arm begun after it.
	 */
	public static function movesOf(history: Array<LedgerSession>, changes: Array<TableChange>): Array<TableMove> {
		return [ for (change in changes) for (row in change.after) {
			final now: String = '${row.model}/${row.effort}';
			final previous: Array<String> = distinct(
				[ for (difficulty in row.from ... row.upto + 1) armAt(change.before, row.stage, difficulty) ?? continue ]
			);
			if (previous.length != 0 && (previous.length != 1 || previous[0] != now)) {
				final inBand: Array<LedgerSession> = history.filter(s ->
					s.difficulty != null && row.from <= s.difficulty && s.difficulty <= row.upto
				);
				final before: Array<LedgerSession> = inBand.filter(
					s -> s.started < change.at && armOf(s, row.stage) == armAt(change.before, row.stage, s.difficulty ?? 0)
				);
				final after: Array<LedgerSession> = inBand.filter(s -> s.started >= change.at && armOf(s, row.stage) == now);
				{
					commit: change.commit,
					at: change.at,
					before: cellOf(row.stage, row, previous.join('|'), before, []),
					after: cellOf(row.stage, row, now, after, [])
				};
			}
		} ];
	}

	/** Every cell of `table`, and the previous arm of each move, with the landed slices of `history` on it. */
	public static function coverageOf(history: Array<LedgerSession>, table: Array<TableRow>, moves: Array<TableMove>): Array<BandCell> {
		final out: Array<BandCell> = [];
		final add: (String, Int, Int, String) -> Void = (stage, from, upto, arm) -> {
			if (out.exists(cell -> cell.stage == stage && cell.from == from && cell.upto == upto && cell.arm == arm)) return;
			final band: TableRow = {
				stage: stage,
				from: from,
				upto: upto,
				model: '',
				effort: ''
			};
			out.push(cellOf(
				stage, band, arm,
				history.filter(s -> s.difficulty != null && from <= s.difficulty && s.difficulty <= upto && armOf(s, stage) == arm), []
			));
		};
		for (row in table) add(row.stage, row.from, row.upto, '${row.model}/${row.effort}');
		for (move in moves) for (arm in move.before.arm.split('|')) add(move.before.stage, move.before.from, move.before.upto, arm);
		return out;
	}

	/**
	 * The idle slot-minutes of (`from`, `to`] by cause, `occupants` filling `slots` minute by minute: a free slot inside a stretch
	 * of `NO_START_HOURS` with no occupant started is `no-start`, one beside a running exclusive line is `exclusive`, any other is
	 * `other`.
	 */
	public static function idleOf(
		occupants: Array<LedgerSession>, from: Float, to: Float, slots: Int, exclusive: Array<String>
	): Array<IdleCause> {
		final starts: Array<Float> = occupants.map(s -> s.started);
		starts.sort(Reflect.compare);
		final minutes: Map<String, Float> = [CAUSE_NO_START => 0, CAUSE_EXCLUSIVE => 0, CAUSE_OTHER => 0];
		var next: Int = 0;
		var at: Float = from;
		while (at < to) {
			while (next < starts.length && starts[next] <= at) next++;
			final running: Array<LedgerSession> = occupants.filter(s -> s.started <= at && s.ended > at);
			final free: Int = slots - running.length;
			if (free > 0) {
				final before: Float = next > 0 ? starts[next - 1] : from;
				final after: Float = next < starts.length ? starts[next] : to;
				final cause: String = if (after - before >= NO_START_HOURS * MS_PER_HOUR)
					CAUSE_NO_START
				else if (running.exists(s -> exclusive.contains(s.task)))
					CAUSE_EXCLUSIVE
				else
					CAUSE_OTHER;
				minutes[cause] = (minutes[cause] ?? 0) + free;
			}
			at += MS_PER_MINUTE;
		}
		return [
			for (cause in [CAUSE_NO_START, CAUSE_EXCLUSIVE, CAUSE_OTHER])
				{ cause: cause, slotHours: (minutes[cause] ?? 0) * MS_PER_MINUTE / MS_PER_HOUR }
		];
	}

	/** The most `occupants` running at one minute of (`from`, `to`]: the slots a window ran on when no count is given. */
	public static function peakOf(occupants: Array<LedgerSession>, from: Float, to: Float): Int {
		var peak: Int = 0;
		var at: Float = from;
		while (at < to) {
			final running: Int = occupants.filter(s -> s.started <= at && s.ended > at).length;
			if (running > peak) peak = running;
			at += MS_PER_MINUTE;
		}
		return peak;
	}

	/**
	 * The mechanical flags: a table move whose two sides hold `FLAG_MIN_N` slices each and whose median $/land moved by more than
	 * `FLAG_USD_SHARE` or whose mean rounds moved by `FLAG_ROUNDS` or more; an idle cause past `FLAG_IDLE_SHARE` of all idle.
	 */
	public static function flagsOf(moves: Array<TableMove>, idle: Array<IdleCause>): Array<String> {
		final flags: Array<String> = [];
		for (move in moves) if (move.before.n >= FLAG_MIN_N && move.after.n >= FLAG_MIN_N) {
			final name: String = '${moveName(move)} (n ${move.before.n} -> ${move.after.n})';
			final previous: Float = move.before.median;
			final share: Float = previous == 0 ? 0 : move.after.median / previous - 1;
			if (Math.abs(share) > FLAG_USD_SHARE)
				flags.push('$name $$/land ${fixed(previous)} -> ${fixed(move.after.median)} (${percent(share)})');
			if (Math.round(Math.abs(move.after.rounds - move.before.rounds) * PERCENT) >= Math.round(FLAG_ROUNDS * PERCENT))
				flags.push('$name rounds ${fixed(move.before.rounds)} -> ${fixed(move.after.rounds)}');
		}
		final all: Float = idle.fold((cause, sum) -> sum + cause.slotHours, 0.0);
		for (cause in idle) if (all > 0 && cause.slotHours / all > FLAG_IDLE_SHARE)
			flags.push('idle ${cause.cause} ${fixed(cause.slotHours)} slot-h = ${percent(cause.slotHours / all)} of idle');
		return flags;
	}

	/** The review findings of one fix-round message: its numbered items `1. `, `2. `, … in order, at least one. */
	public static function fixItems(message: String): Int {
		var items: Int = 0;
		var at: Int = 0;
		while (true) {
			final marker: EReg = new EReg('(?:^|[\\s(:])${items + 1}\\. (?=[^\\d\\s])', '');
			if (!marker.matchSub(message, at)) break;
			items++;
			at = marker.matchedPos().pos + 1;
		}
		return items > 0 ? items : 1;
	}

	/**
	 * The review findings in `messages`, the user messages of a slice's agents: the items of each distinct fix-round message. A
	 * driver's prompt quotes the round with a `<placeholder>` where the list goes; that is the template, not a round.
	 */
	public static function findingsIn(messages: Array<String>): Int {
		final rounds: Array<String> = distinct(
			[ for (message in messages) if (message.indexOf(FIX_ROUND) >= 0) message.substr(message.indexOf(FIX_ROUND)) ]
		).filter(round -> !PLACEHOLDER.match(round));
		return rounds.fold((round, sum) -> sum + fixItems(round), 0);
	}

	/** The report as the text the parent reads in one screen. */
	public static function render(summary: CuratorSummary, label: String): String {
		final lines: Array<String> = [];
		final lands: Int = summary.lands;
		final share: Float = summary.allLands == 0 ? 0 : summary.parentUsd * lands / summary.allLands;
		final allIn: Float = summary.landUsd + summary.nonLandingUsd + share;
		lines.push(
			'curator-report $label: ${iso(summary.from)} -> ${iso(summary.to)}, ${fixed((summary.to - summary.from) / MS_PER_HOUR)} h, '
			+ '$lands lands (git ${summary.gitLands}${summary.gitLands == lands ? '' : ', MISMATCH'})'
		);
		lines.push(
			'$$ lands ${fixed(summary.landUsd)} = ${fixed(perLand(summary.landUsd, lands))}/land; non-landing ${summary.nonLanding} = '
			+ '${fixed(summary.nonLandingUsd)}; parent ${fixed(summary.parentUsd)} x $lands/${summary.allLands} = ${fixed(share)}; '
			+ 'all-in ${fixed(allIn)} = ${fixed(perLand(allIn, lands))}/land'
		);
		lines.push(
			Table.render([STAGE, 'band', 'arm', 'n', 'med $$', 'stage $$', 'rounds', '1-round', 'findings'], summary.cells.map(cell -> [
				cell.stage,
				band(cell),
				cell.arm,
				'${cell.n}',
				fixed(cell.median),
				optional(cell.stageUsd),
				fixed(cell.rounds),
				percent(cell.oneRound),
				optional(cell.findings)
			]))
		);
		final idle: Float = summary.idle.fold((cause, sum) -> sum + cause.slotHours, 0.0);
		lines.push(
			summary.slots <= 0
				? 'idle: no session of the dispatchers ran in the window'
				: 'idle ${fixed(idle)} of ${fixed(summary.slotHours)} slot-h (${summary.slots} slots): '
					+ summary.idle.map(
						cause -> '${cause.cause} ${fixed(cause.slotHours)}${idle > 0 ? ' (${percent(cause.slotHours / idle)})' : ''}'
					)
						.join(', ')
		);
		lines.push(
			summary.moves.length == 0
				? 'model-table moves in the window: none'
				: Table.render(
					[
						'model-table move',
						'before n',
						'med $$',
						'rounds',
						'after n',
						'med $$',
						'rounds'
					],
					summary.moves.map(move -> [
						moveName(move),
						'${move.before.n}',
						fixed(move.before.median),
						fixed(move.before.rounds),
						'${move.after.n}',
						fixed(move.after.median),
						fixed(move.after.rounds)
					])
				)
		);
		lines.push('coverage (landed slices of the whole ledger to the window end):');
		for (stage in distinct(summary.coverage.map(cell -> cell.stage)))
			lines.push(
				'  $stage: ' + [ for (cell in summary.coverage) if (cell.stage == stage) '${band(cell)} ${cell.arm} ${cell.n}' ].join(', ')
			);
		final thin: Array<String> = [
			for (cell in summary.coverage) if (cell.n < THIN_N) '${cell.stage} ${band(cell)} ${cell.arm} ${cell.n}'
		];
		lines.push('thin (n < $THIN_N): ${thin.length == 0 ? 'none' : thin.join(', ')}');
		lines.push('FLAGS: ${summary.flags.length == 0 ? 'none' : ''}');
		for (flag in summary.flags) lines.push('  $flag');
		return lines.join('\n');
	}

	/** The report as one JSON document. */
	public static function json(summary: CuratorSummary): String {
		return JValueWriter.write(JObject([
			entry('from', JString(iso(summary.from))),
			entry('to', JString(iso(summary.to))),
			entry('lands', JNumber(summary.lands)),
			entry('gitLands', JNumber(summary.gitLands)),
			entry('landUsd', JNumber(summary.landUsd)),
			entry('nonLanding', JNumber(summary.nonLanding)),
			entry('nonLandingUsd', JNumber(summary.nonLandingUsd)),
			entry('parentUsd', JNumber(summary.parentUsd)),
			entry('allLands', JNumber(summary.allLands)),
			entry('slots', JNumber(summary.slots)),
			entry('slotHours', JNumber(summary.slotHours)),
			entry('idle', JArray(summary.idle.map(cause -> JObject([
				entry('cause', JString(cause.cause)),
				entry('slotHours', JNumber(cause.slotHours))
			])))),
			entry('cells', JArray(summary.cells.map(cellJson))),
			entry('moves', JArray(summary.moves.map(move -> JObject([
				entry('commit', JString(move.commit)),
				entry('at', JString(iso(move.at))),
				entry('before', cellJson(move.before)),
				entry('after', cellJson(move.after))
			])))),
			entry('coverage', JArray(summary.coverage.map(cellJson))),
			entry('flags', JArray(summary.flags.map(flag -> JString(flag))))
		]), JsonFormat.instance.expandedWriteOptions);
	}

	private static inline function entry(key: String, value: JValue): JEntry {
		return JValueTools.entry(key, value);
	}

	private static inline function isPipeline(session: LedgerSession, project: String): Bool {
		return session.workflow == PIPELINE && session.project == project;
	}

	private static inline function band(cell: BandCell): String {
		return 'd${cell.from}-${cell.upto}';
	}

	private static inline function perLand(usd: Float, lands: Int): Float {
		return lands == 0 ? 0 : usd / lands;
	}

	private static inline function fixed(value: Float): String {
		return js.Syntax.code('{0}.toFixed(2)', value);
	}

	/**
	 * The input of a report over (`from`, `to`]: the model table at `until` (the project's own file when null) and its commits, the
	 * git lands, all read from the `project` checkout whose main history the lands are on; the queue's exclusive lines; the
	 * transcripts under `projects`, the Claude Code projects directory.
	 */
	private static function gather(
		projects: String, project: String, sessions: Array<LedgerSession>, from: Float, to: Float, until: Null<String>, queue: String,
		slots: Int
	): CuratorInput {
		return {
			sessions: sessions,
			project: project,
			from: from,
			to: to,
			table: ModelTable.read(until == null ? fileText(Path.join([project, WORKFLOW_FILE])) : shown(project, '$until:$WORKFLOW_FILE')),
			tableChanges: tableChanges(project, from, to, until ?? 'HEAD'),
			gitLands: gitLands(project, from, to, until ?? 'HEAD'),
			exclusive: [ for (line in QueueFile.read(queue)) if (line.exclusive) line.id ],
			slots: slots,
			findings: session -> findingsOf(session, sessions, projects)
		};
	}

	private static function cellJson(cell: BandCell): JValue {
		final stageUsd: Null<Float> = cell.stageUsd;
		final findings: Null<Float> = cell.findings;
		return JObject([
			entry(STAGE, JString(cell.stage)),
			entry('from', JNumber(cell.from)),
			entry('upto', JNumber(cell.upto)),
			entry('arm', JString(cell.arm)),
			entry('n', JNumber(cell.n)),
			entry('median', JNumber(cell.median)),
			entry('stageUsd', stageUsd == null ? JNull : JNumber(stageUsd)),
			entry('rounds', JNumber(cell.rounds)),
			entry('oneRound', JNumber(cell.oneRound)),
			entry('findings', findings == null ? JNull : JNumber(findings))
		]);
	}

	/**
	 * The review findings of a landed `session`: 0 when it passed review at once, else the fix rounds in the transcripts of
	 * its agents (a fix list reaches whichever agent the round went to; a copy another agent holds counts once), null when none is on disk.
	 */
	private static function findingsOf(session: LedgerSession, sessions: Array<LedgerSession>, projects: String): Null<Int> {
		if (session.rounds <= 1) return 0;
		final places: Array<String> = distinct([
			for (s in [session].concat(sessions))
				if (s.conversation != null && s.conversationDir != null)
					Path.join([projects, s.conversationDir, s.conversation, 'subagents'])
		]);
		final messages: Array<String> = [];
		var read: Bool = false;
		for (agent in distinct(session.agents.map(a -> a.id))) {
			final path: Null<String> = places.map(dir -> Path.join([dir, 'agent-$agent.jsonl'])).find(FileSystem.exists);
			if (path == null) continue;
			read = true;
			for (text in TokenTranscript.userTexts(path)) messages.push(text);
		}
		return read ? findingsIn(messages) : null;
	}

	/**
	 * The end of the land of `rev` in the `project` checkout: when the
	 * ledger marked its slice landed after its commit, else its commit time.
	 */
	private static function boundary(sessions: Array<LedgerSession>, project: String, rev: String): Float {
		final committed: Float = TokenAudit.commitMillis(project, rev);
		final landings: Array<Landing> = SliceStats.landings(project, '$rev^!', null);
		final id: Null<String> = landings.length == 0 ? null : landings[0].id;
		var marked: Null<Float> = null;
		for (s in sessions)
			if (isPipeline(s, project) && s.landed && s.task == id && s.ended >= committed && (marked == null || s.ended < marked))
				marked = s.ended;
		return marked ?? committed;
	}

	/** The slice landings of `rev`'s first-parent history committed inside (`from`, `to`]. */
	private static function gitLands(tree: String, from: Float, to: Float, rev: String): Int {
		return SliceStats.landings(tree, rev, iso(from - MS_PER_DAY))
			.filter(landing -> landing.landed * MS_PER_SECOND > from && landing.landed * MS_PER_SECOND <= to)
			.length;
	}

	/** The commits of the workflow file on `rev`'s history inside (`from`, `to`] that changed its model table, oldest first. */
	private static function tableChanges(tree: String, from: Float, to: Float, rev: String): Array<TableChange> {
		final window: String = '--since=${iso(from - MS_PER_DAY)}';
		final format: String = '--format=%H %ct';
		final out: Array<TableChange> = [];
		for (line in cmd('git -C $tree log $format $window $rev -- $WORKFLOW_FILE').check().lines()) {
			final fields: Array<String> = line.trim().split(' ');
			if (fields.length < 2) continue;
			final seconds: Float = Std.parseFloat(fields[1]);
			final at: Float = seconds * MS_PER_SECOND;
			if (Math.isNaN(seconds) || at <= from || at > to) continue;
			final before: Array<TableRow> = ModelTable.read(shown(tree, '${fields[0]}^:$WORKFLOW_FILE'));
			final after: Array<TableRow> = ModelTable.read(shown(tree, '${fields[0]}:$WORKFLOW_FILE'));
			if (before.length > 0 && after.length > 0) out.unshift({
				commit: fields[0],
				at: at,
				before: before,
				after: after
			});
		}
		return out;
	}

	/** The file `spec` (`<rev>:<path>`) of `tree`, empty when the revision has no such file. */
	private static function shown(tree: String, spec: String): String {
		final run: Result = cmd('git -C $tree show $spec').run();
		return run.ok ? run.out : '';
	}

	/** Every running session of the engine state directory `dir` the ledger has no row of yet, ended at `to`. */
	private static function readLive(dir: String, finished: Array<LedgerSession>, to: Float): Array<LedgerSession> {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) return [];
		final known: Map<String, Bool> = [ for (s in finished) s.id => true ];
		final out: Array<LedgerSession> = [];
		for (name in FileSystem.readDirectory(dir)) if (STATE_FILE.match(name)) {
			final state: Null<JValue> = try JValueParser.parse(File.getContent(Path.join([dir, name]))) catch (_: Exception) null;
			final live: Null<LedgerSession> = state == null ? null : liveOf(state, to);
			if (live != null && !known.exists(live.id) && live.started < to) out.push(live);
		}
		return out;
	}

	/** The `model/effort` of each stage `row` names; a `handedOver` row's plan arm is its execute arm too. */
	private static function armsOf(row: JValue, handedOver: Bool): Map<String, String> {
		final arms: Map<String, String> = [];
		switch JValueTools.field(row, 'stages') {
			case JObject(entries):
				for (stage in entries) {
					final arm: Null<String> = armIn(stage.value, MODEL, EFFORT);
					if (arm != null) arms[stage.key] = arm;
				}
			case _:
				final execute: Null<String> = armIn(row, MODEL, EFFORT);
				final review: Null<String> = armIn(row, 'review_model', 'review_effort');
				if (execute != null) arms[EXECUTE] = execute;
				if (review != null) arms[REVIEW] = review;
		}
		final planned: Null<String> = arms[PLAN];
		if (handedOver && planned != null && !arms.exists(EXECUTE)) arms[EXECUTE] = planned;
		return arms;
	}

	/** `<model>/<effort>` of the two fields of `value`, null when either is missing. */
	private static function armIn(value: JValue, modelKey: String, effortKey: String): Null<String> {
		final model: Null<String> = JValueTools.stringAt(value, modelKey);
		final effort: Null<String> = JValueTools.stringAt(value, effortKey);
		return model == null || effort == null ? null : '$model/$effort';
	}

	/** One `spend.by_agent` record; a `handedOver` row's plan agent executed it, so it is booked as execute. */
	private static function agentOf(agent: JValue, handedOver: Bool): AgentSpend {
		final stage: Null<String> = JValueTools.stringAt(agent, STAGE);
		return {
			id: JValueTools.stringAt(agent, 'agent') ?? '',
			stage: handedOver && stage == PLAN ? EXECUTE : stage,
			usd: agentUsd(agent)
		};
	}

	private static function armAt(table: Array<TableRow>, stage: String, difficulty: Int): Null<String> {
		final row: Null<TableRow> = ModelTable.cellOf(table, stage, difficulty);
		return row == null ? null : '${row.model}/${row.effort}';
	}

	private static function number(value: Null<JValue>): Null<Float> {
		return switch value {
			case JNumber(v): v;
			case _: null;
		}
	}

	private static function total(rows: Array<LedgerSession>): Float {
		return rows.fold((row, sum) -> sum + row.usd, 0.0);
	}

	private static function distinct<T>(values: Array<T>): Array<T> {
		final out: Array<T> = [];
		out.pushAllUnique(values);
		return out;
	}

	private static function count(value: Null<String>, flag: String): Null<Int> {
		if (value == null) return null;
		final parsed: Null<Int> = Std.parseInt(value);
		if (parsed == null || parsed < 0 || '$parsed' != value) throw new UsageError('$flag takes a count, not $value');
		return parsed;
	}

	private static function moveName(move: TableMove): String {
		return '${move.commit.substr(0, 9)} ${move.before.stage} ${band(move.before)} ${move.before.arm} -> ${move.after.arm}';
	}

	private static function optional(value: Null<Float>): String {
		return value == null ? '-' : fixed(value);
	}

	private static function percent(share: Float): String {
		return js.Syntax.code('{0}.toFixed(0)', share * PERCENT) + '%';
	}

	private static function iso(ms: Float): String {
		return new js.lib.Date(ms).toISOString();
	}

	private static function fileText(path: String): String {
		return FileSystem.exists(path) ? File.getContent(path) : '';
	}

	private static function mainTree(tree: String): String {
		return Path.directory(cmd('git -C $tree rev-parse --path-format=absolute --git-common-dir').check().out.trim());
	}

	private static function stateDir(): String {
		return Sys.getEnv('WF_STATE_DIR') ?? Path.join([Sys.getEnv('HOME') ?? '', '.claude', 'workflow-state']);
	}

}
