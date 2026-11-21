package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import dev.CuratorReport;
import dev.ModelTable;
import dev.TokenTranscript;
import devkit.Args.UsageError;
import sys.io.File;

using Lambda;

/**
 * `CuratorReport` (`dev curator-report`) and the `ModelTable` it bands by, over fixture ledger rows, a fixture workflow table
 * and a fixture transcript — never the real logs. Prices: sonnet output 10 and opus output 20 dollars per million tokens.
 */
@:nullSafety(Strict)
final class CuratorReportTest extends Test {

	private static final PROJECT: String = '/fixture/project';
	private static final BASE: Float = 1767225600000;
	private static final HOUR: Float = 3600000;
	private static final TABLE: String = [
		'name: slice-pipeline',
		'model_table:',
		'  stages:',
		'    plan:',
		'      - { upto: 10, model: sonnet, effort: high }',
		'    # a comment between stages',
		'    execute:',
		'      - { upto: 6, model: sonnet, effort: high }',
		'      - { upto: 10, model: opus, effort: high }  # the top band',
		'    review:',
		'      - { upto: 3, model: sonnet, effort: high }',
		'      - { upto: 10, model: opus, effort: medium }',
		'driver:',
		'  model: haiku',
		'  effort: medium'
	].join('\n');

	@:pin('control')
	@:killer('M-MODELTABLE-BAND-FROM')
	public function testTheModelTableReadsEachStagesBandsUpToTheNextKey(): Void {
		final table: Array<TableRow> = ModelTable.read(TABLE);
		Assert.same(['plan', 'execute', 'review'], ModelTable.stages(table));
		Assert.same([
			{
				stage: 'execute',
				from: 1,
				upto: 6,
				model: 'sonnet',
				effort: 'high'
			},
			{
				stage: 'execute',
				from: 7,
				upto: 10,
				model: 'opus',
				effort: 'high'
			}
		], table.filter(row -> row.stage == 'execute'));
		Assert.equals('medium', ModelTable.cellOf(table, 'review', 4)?.effort);
		Assert.isNull(ModelTable.cellOf(table, 'driver', 1));
	}

	@:pin('control')
	@:killer('M-CURATOR-WRITE-ONE-HOUR')
	public function testAnAgentsCacheWriteIsPricedAtTheOneHourMultiple(): Void {
		final session: LedgerSession = CuratorReport.sessionOf(JValueParser.parse(
			'{"spend":{"by_agent":[{"agent":"a","stage":"execute","model":"claude-opus-5-5","input":0,"output":0,"cache_read":0,'
			+ '"cache_write":1000000}]}}'
		));
		Assert.floatEquals(8, session.usd);
	}

	@:pin('control')
	@:killer('M-CURATOR-LANDS-FROM')
	public function testAWindowOfLandsStartsWhereTheLandBeforeItEnded(): Void {
		Assert.floatEquals(BASE + HOUR, CuratorReport.landsFrom(window(), PROJECT, 2, BASE + 10 * HOUR));
	}

	@:pin('control')
	@:killer('M-CURATOR-LANDED-DONE')
	public function testAnEngineTaskMarkedDoneIsALandOfTheDispatchTree(): Void {
		Assert.equals(3, summary(window(), BASE + HOUR, 0).allLands);
	}

	@:pin('control')
	@:killer('M-CURATOR-PARENT-ROOTS')
	public function testTheParentIsProRatedByTheLandsOfTheWindowsDispatchTreeAlone(): Void {
		final result: CuratorSummary = summary(window(), BASE + HOUR, 0);
		Assert.equals(2, result.lands);
		Assert.floatEquals(7, result.landUsd);
		Assert.equals(1, result.nonLanding);
		Assert.floatEquals(0.5, result.nonLandingUsd);
		Assert.floatEquals(12, result.parentUsd);
		Assert.equals(3, result.allLands);
	}

	@:pin('control')
	@:killer('M-CURATOR-CELL-BAND')
	public function testACellHoldsTheLandsOfItsStagesBandAndArm(): Void {
		final rows: Array<LedgerSession> = CuratorReport.readLedger([
			pipeline('a', 0, 1, 2, 1, '"execute":{"model":"sonnet","effort":"high"}', [agent('a1', 'execute', 'sonnet', 100000)]),
			pipeline('b', 0, 1, 5, 3, '"execute":{"model":"sonnet","effort":"high"}', [agent('b1', 'execute', 'sonnet', 300000)]),
			pipeline('c', 0, 1, 8, 2, '"execute":{"model":"opus","effort":"high"}', [agent('c1', 'execute', 'opus', 200000)])
		].join('\n'));
		final cells: Array<BandCell> = CuratorReport.cellsOf(rows, ModelTable.read(TABLE), ['a' => 0, 'b' => 4, 'c' => null]);
		Assert.same(
			['execute d1-6 sonnet/high 2', 'execute d7-10 opus/high 1'],
			cells.map(cell -> '${cell.stage} d${cell.from}-${cell.upto} ${cell.arm} ${cell.n}')
		);
		final low: BandCell = cells[0];
		Assert.floatEquals(2, low.median);
		Assert.floatEquals(2, low.stageUsd ?? 0);
		Assert.floatEquals(2, low.rounds);
		Assert.floatEquals(0.5, low.oneRound);
		Assert.floatEquals(2, low.findings ?? 0);
		Assert.isNull(cells[1].findings);
	}

	@:pin('control')
	@:killer('M-CURATOR-PLAN-HANDOVER')
	public function testAPlanAgentWithNoExecuteAgentBesideItIsTheExecutor(): Void {
		final rows: Array<LedgerSession> = CuratorReport.readLedger(
			pipeline('a', 0, 1, 2, 1, '"plan":{"model":"sonnet","effort":"high"}', [agent('a1', 'plan', 'sonnet', 100000)])
		);
		Assert.same(
			['execute sonnet/high 1'],
			[
				for (cell in CuratorReport.cellsOf(rows, ModelTable.read(TABLE), []))
					if (cell.stage == 'execute') '${cell.stage} ${cell.arm} ${cell.n}'
			]
		);
	}

	@:pin('control')
	@:killer('M-CURATOR-IDLE-NO-START')
	public function testAFreeSlotInALongStretchWithNoStartIsIdleForWantOfOne(): Void {
		Assert.floatEquals(12, idle().find(cause -> cause.cause == CuratorReport.CAUSE_NO_START)?.slotHours ?? 0);
	}

	@:pin('control')
	@:killer('M-CURATOR-IDLE-EXCLUSIVE')
	public function testAFreeSlotBesideARunningExclusiveLineIsIdleForIt(): Void {
		Assert.same([12.0, 1.0, 2.0], idle().map(cause -> cause.slotHours));
	}

	@:pin('control')
	@:killer('M-CURATOR-PEAK-SLOTS')
	public function testWithNoSlotCountTheWindowRunsOnItsPeak(): Void {
		final result: CuratorSummary = summary(CuratorReport.readLedger(occupancy()), BASE, 0, BASE + 12 * HOUR, ['T-b']);
		Assert.equals(2, result.slots);
		Assert.floatEquals(24, result.slotHours);
	}

	@:pin('control')
	@:killer('M-CURATOR-FLAG-IDLE')
	public function testAnIdleCausePastAFifthOfTheIdleIsFlagged(): Void {
		Assert.same(['idle no-start>=3h 12.00 slot-h = 80% of idle'], CuratorReport.flagsOf([], idle()));
	}

	@:pin('control')
	@:killer('M-CURATOR-MOVE-BEFORE-COMMIT')
	public function testATableMoveComparesThePreviousArmBeforeTheCommitWithTheNewArmAfterIt(): Void {
		final moves: Array<TableMove> = CuratorReport.movesOf(history(), [change()]);
		Assert.same(
			['execute d1-2 sonnet/high 1 -> haiku/xhigh 1'],
			moves.map(
				move ->
					'${move.before.stage} d${move.before.from}-${move.before.upto} ${move.before.arm} ${move.before.n} -> ${move.after.arm}'
					+ ' ${move.after.n}'
			)
		);
	}

	@:pin('control')
	@:killer('M-CURATOR-COVERAGE')
	public function testCoverageListsEveryCellOfTheTableAndThePreviousArmsWithTheirCount(): Void {
		final table: Array<TableRow> = change().after;
		final coverage: Array<BandCell> = CuratorReport.coverageOf(history(), table, CuratorReport.movesOf(history(), [change()]));
		Assert.same([
			'execute d1-2 haiku/xhigh 1',
			'execute d3-6 sonnet/high 1',
			'review d1-10 opus/medium 0',
			'execute d1-2 sonnet/high 2'
		], coverage.map(cell -> '${cell.stage} d${cell.from}-${cell.upto} ${cell.arm} ${cell.n}'));
	}

	@:pin('control')
	@:killer('M-CURATOR-COVERAGE-WIDTH')
	public function testCoverageKeepsAPreviousArmsCellBesideATableCellOfTheSameStartAndArmButAnotherWidth(): Void {
		final table: Array<TableRow> = change().before;
		final coverage: Array<BandCell> = CuratorReport.coverageOf(history(), table, CuratorReport.movesOf(history(), [change()]));
		Assert.same(
			['execute d1-6 sonnet/high 3', 'execute d1-2 sonnet/high 2'],
			coverage.map(cell -> '${cell.stage} d${cell.from}-${cell.upto} ${cell.arm} ${cell.n}')
		);
	}

	@:pin('control')
	@:killer('M-CURATOR-ONE-WINDOW')
	public function testASinceAndALandsCountOnOneCommandLineAreRefused(): Void {
		Assert.equals('--since and --lands name a window each; give one', refusal(['--since', 'x', '--lands', '3']));
	}

	@:pin('control')
	@:killer('M-CURATOR-LANDS-COUNT')
	public function testALandsCountWithATrailingLetterIsRefused(): Void {
		Assert.equals('--lands takes a count, not 2x', refusal(['--lands', '2x']));
	}

	@:pin('control')
	@:killer('M-CURATOR-FLAG-USD')
	public function testAMoveOfTheMedianPastFifteenPercentIsFlagged(): Void {
		Assert.same(
			['m execute d1-2 old -> new (n 10 -> 10) $$/land 10.00 -> 12.00 (20%)'], CuratorReport.flagsOf([move(10, 10, 12, 1.5, 1.6)], [])
		);
	}

	@:pin('control')
	@:killer('M-CURATOR-FLAG-ROUNDS')
	public function testAMoveOfTheRoundsByThreeTenthsIsFlagged(): Void {
		Assert.same(
			['m execute d1-2 old -> new (n 10 -> 10) rounds 1.50 -> 1.80'], CuratorReport.flagsOf([move(10, 10, 10.5, 1.5, 1.8)], [])
		);
	}

	@:pin('control')
	@:killer('M-CURATOR-FLAG-MIN-N')
	public function testAMoveWithFewerThanTenSlicesOnASideIsNotFlagged(): Void {
		Assert.same([], CuratorReport.flagsOf([move(9, 10, 20, 1, 2)], []));
	}

	@:pin('control')
	@:killer('M-CURATOR-FIX-ITEMS')
	public function testAFixRoundCountsItsNumberedItems(): Void {
		Assert.equals(3, CuratorReport.fixItems('Review fix round: 1. a.hx (design): b 2. c.hx: d (see 1.5) 3. e'));
		Assert.equals(1, CuratorReport.fixItems('Review fix round: one unnumbered item'));
	}

	@:pin('control')
	@:killer('M-CURATOR-FIX-PLACEHOLDER')
	public function testADriversPlaceholderAndACopyOfARoundAreNoFindings(): Void {
		final round: String = 'Review fix round: 1. a 2. b';
		Assert.equals(2, CuratorReport.findingsIn([
			'note\n$round',
			round,
			'SendMessage: Review fix round: <the reviewer\'s fix list verbatim>. Your NEW session'
		]));
	}

	@:pin('control')
	@:killer('M-TRANSCRIPT-TOOL-RESULT-TEXT')
	public function testAFixRoundInAToolResultIsReadFromTheTranscript(): Void {
		final texts: Array<String> = TempDir.with(dir -> {
			final path: String = dir.file('agent-x.jsonl');
			File.saveContent(path, [
				'{"type":"user","message":{"role":"user","content":"Review fix round: 1. a 2. b"}}',
				'{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"Review fix round: '
				+ '1. c"}]}}',
				'{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Review fix round: 1. no"}]}}'
			].join('\n'));
			TokenTranscript.userTexts(path);
		});
		Assert.equals(3, CuratorReport.findingsIn(texts));
	}

	@:pin('control')
	@:killer('M-CURATOR-LIVE')
	public function testARunningSessionEndsAtTheWindowEnd(): Void {
		final live: Null<LedgerSession> = CuratorReport.liveOf(
			JValueParser.parse(
				'{"session_id":"s","parent_session_id":"disp","started_at":"2026-01-01T01:00:00.000Z",'
				+ '"stack":[{"workflow":"slice-pipeline"}],"context":{"task":"T"}}'
			),
			BASE + 5 * HOUR
		);
		Assert.equals('T', live?.task);
		Assert.floatEquals(BASE + 5 * HOUR, live?.ended ?? 0);
		Assert.isTrue(live?.running ?? false);
		Assert.isNull(CuratorReport.liveOf(JValueParser.parse('{"outcome":"completed"}'), 0));
	}

	@:pin('control')
	@:killer('M-CURATOR-JSON')
	public function testTheJsonReportCarriesEverySection(): Void {
		final document: JValue = JValueParser.parse(CuratorReport.json(summary(window(), BASE + HOUR, 0)));
		Assert.equals('2', JValueTools.text(JValueTools.field(document, 'lands')));
		for (key in ['idle', 'cells', 'moves', 'coverage', 'flags']) Assert.notNull(JValueTools.field(document, key), key);
	}

	/** Lands L0 (before the window), L1, L2, a non-landing N1, a landed engine task E1 of the same tree, X1 of another tree. */
	private static function window(): Array<LedgerSession> {
		final spend: String -> Float -> String = (conversation, usd) ->
			',"parent_spend":{"conversation":"$conversation","project":"p","usd":$usd}';
		return CuratorReport.readLedger([
			pipeline('l0', 0, 1, 2, 1, '', [agent('z', 'execute', 'sonnet', 100000)]),
			pipeline('l1', 2, 3, 2, 1, '', [agent('a', 'execute', 'sonnet', 100000), agent('b', 'review', 'opus', 50000)], spend('c1', 4)),
			pipeline('l2', 3, 5, 8, 2, '', [agent('c', 'execute', 'opus', 200000), agent('d', 'review', 'opus', 50000)], spend('c1', 2)),
			pipeline('n1', 4, 4.5, 2, 0, '', [agent('e', 'execute', 'sonnet', 50000)], '', false),
			'{"session_id":"e1","parent_session_id":"disp","root_session_id":"root","workflow":"engine-task","started_at":"${at(4)}",'
			+ '"ended_at":"${at(6)}","visits":{"mark_done":1}${spend('c1', 6)}}',
			'{"session_id":"x1","parent_session_id":"other","root_session_id":"other","workflow":"engine-task","started_at":"${at(4)}",'
			+ '"ended_at":"${at(6)}","visits":{"mark_done":1}${spend('c2', 100)}}'
		].join('\n'));
	}

	/** Two slots over twelve hours: A 0-4, B (exclusive) 8-10, C 9-10, D 10-12 — no-start 12, exclusive 1, other 2. */
	private static function idle(): Array<IdleCause> {
		return CuratorReport.idleOf(CuratorReport.readLedger(occupancy()), BASE, BASE + 12 * HOUR, 2, ['T-b']);
	}

	private static function occupancy(): String {
		return [
			pipeline('a', 0, 4, 2, 1, '', []),
			pipeline('b', 8, 10, 2, 1, '', []),
			pipeline('c', 9, 10, 2, 1, '', []),
			pipeline('d', 10, 12, 2, 1, '', [])
		].join('\n');
	}

	/** The execute d1-6 band split at hour 5: d1-2 moves from sonnet/high to haiku/xhigh, d3-6 stays; review d1-10 is new to no row. */
	private static function change(): TableChange {
		return {
			commit: 'm',
			at: BASE + 5 * HOUR,
			before: ModelTable.read('model_table:\n  stages:\n    execute:\n      - { upto: 6, model: sonnet, effort: high }'),
			after: ModelTable.read(
				'model_table:\n  stages:\n    execute:\n      - { upto: 2, model: haiku, effort: xhigh }\n'
				+ '      - { upto: 6, model: sonnet, effort: high }\n    review:\n      - { upto: 10, model: opus, effort: medium }'
			)
		};
	}

	/** P1 d1 sonnet before the move, P2 d2 sonnet after it, P3 d2 haiku after it, P4 d4 sonnet. */
	private static function history(): Array<LedgerSession> {
		final sonnet: String = '"execute":{"model":"sonnet","effort":"high"}';
		return CuratorReport.readLedger([
			pipeline('p1', 1, 2, 1, 1, sonnet, [agent('a', 'execute', 'sonnet', 100000)]),
			pipeline('p2', 6, 7, 2, 1, sonnet, [agent('b', 'execute', 'sonnet', 100000)]),
			pipeline('p3', 7, 8, 2, 1, '"execute":{"model":"haiku","effort":"xhigh"}', [agent('c', 'execute', 'haiku', 100000)]),
			pipeline('p4', 7, 8, 4, 1, sonnet, [agent('d', 'execute', 'sonnet', 100000)])
		].join('\n'));
	}

	private static function move(n: Int, afterN: Int, afterMedian: Float, rounds: Float, afterRounds: Float): TableMove {
		return {
			commit: 'm',
			at: 0,
			before: cell('old', n, 10, rounds),
			after: cell('new', afterN, afterMedian, afterRounds)
		};
	}

	private static function cell(arm: String, n: Int, median: Float, rounds: Float): BandCell {
		return {
			stage: 'execute',
			from: 1,
			upto: 2,
			arm: arm,
			n: n,
			median: median,
			stageUsd: null,
			rounds: rounds,
			oneRound: 0,
			findings: null
		};
	}

	private static function summary(
		sessions: Array<LedgerSession>, from: Float, slots: Int, ?to: Float, ?exclusive: Array<String>
	): CuratorSummary {
		return CuratorReport.summarize({
			sessions: sessions,
			project: PROJECT,
			from: from,
			to: to ?? BASE + 10 * HOUR,
			table: ModelTable.read(TABLE),
			tableChanges: [],
			gitLands: 2,
			exclusive: exclusive ?? [],
			slots: slots,
			findings: _ -> null
		});
	}

	/** A landed (unless `landed` is false) `slice-pipeline` row of the fixture project under dispatcher `disp`. */
	private static function pipeline(
		id: String, from: Float, to: Float, difficulty: Int, rounds: Int, stages: String, agents: Array<String>, extra: String = '',
		landed: Bool = true
	): String {
		return '{"session_id":"$id","parent_session_id":"disp","root_session_id":"root","workflow":"slice-pipeline","project":"$PROJECT",'
			+ '"task":"T-$id","started_at":"${at(from)}","ended_at":"${at(to)}","difficulty":$difficulty,'
			+ '"visits":{"review":$rounds${landed ? ',"mark_landed":1' : ''}},"stages":{$stages},'
			+ '"spend":{"by_agent":[${agents.join(',')}]}$extra}';
	}

	private static function agent(id: String, stage: String, model: String, output: Int): String {
		return '{"agent":"$id","stage":"$stage","model":"claude-$model-5-5","input":0,"output":$output,"cache_read":0,"cache_write":0}';
	}

	private static function at(hours: Float): String {
		return new js.lib.Date(BASE + hours * HOUR).toISOString();
	}

	/** The message `CuratorReport.main` refuses `argv` with, over a fixture tree, queue and ledger; `null` when it runs. */
	private static function refusal(argv: Array<String>): Null<String> {
		return TempDir.with(dir -> {
			final queue: String = dir.file('queue.yaml');
			final ledger: String = dir.file('ledger.jsonl');
			File.saveContent(queue, '');
			File.saveContent(ledger, '');
			var message: Null<String> = null;
			try {
				CuratorReport.main(argv.concat([
					'--repo',
					dir.path,
					'--project',
					dir.path,
					'--queue',
					queue,
					'--ledger',
					ledger,
					'--state',
					dir.path
				]));
			} catch (exception: UsageError) {
				message = exception.message;
			}
			message;
		});
	}

}
