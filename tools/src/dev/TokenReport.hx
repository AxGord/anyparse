package dev;

import dev.TokenTranscript.AgentReading;
import dev.TokenTranscript.ToolStat;
import dev.TokenTranscript.TurnReading;

using Lambda;

/**
 * The one answer to "where do the agents' tokens and money go": sums the readings of many transcripts (`TokenTranscript`)
 * into per-tool and per-role sizes, per-model usage priced from `PRICES`, the cost per slice (and per landed slice), the cache rewrites
 * with the idle gap before each, and the bypasses of hxq. Pure over its input, so a before/after pair of reports diffs.
 */
@:nullSafety(Strict)
final class TokenReport {

	/** The cache-write price as a multiple of the input price: an assumption, not a table value. */
	public static inline final WRITE_5M_MULTIPLE: Float = 1.25;

	public static inline final WRITE_1H_MULTIPLE: Float = 2;

	/** A turn whose cache write is at least this share of its whole context rebuilt the context (a cache miss). */
	public static inline final REWRITE_SHARE: Float = 0.8;

	/** Contexts smaller than this many tokens are too cheap to count as a rewrite. */
	public static inline final REWRITE_MIN_CONTEXT: Int = 10000;

	/** The 5-minute and the 1-hour cache lifetimes, in seconds. */
	public static inline final TTL_SHORT: Float = 300;

	public static inline final TTL_LONG: Float = 3600;

	/** The row of the agents whose prompt names no slice. */
	public static inline final OTHER: String = '(other)';

	/** The price of one million tokens of a model family: fresh input, output, and a cache read. */
	public static final PRICES: Array<Price> = [
		{
			family: 'opus',
			input: 4,
			output: 20,
			read: 0.2
		},
		{
			family: 'sonnet',
			input: 2,
			output: 10,
			read: 0.2
		},
		{
			family: 'haiku',
			input: 0.1,
			output: 0.5,
			read: 0.01
		}
	];

	/** How many of the costliest rewrites a report lists, and how many bypass samples. */
	private static inline final WORST_REWRITES: Int = 20;

	private static inline final SAMPLES: Int = 10;
	private static inline final PERCENT: Float = 100;
	private static inline final PER_MTOK: Float = 1000000;
	private static inline final MS_PER_SECOND: Float = 1000;
	private static inline final COST_SCALE: Float = 10000;

	/** The report over `agents`; `landed` names the slices that landed, or null when that is not asked. */
	public static function summarize(agents: Array<AgentReading>, landed: Null<Array<String>>): AuditReport {
		final tools: Array<ToolRow> = toolRows(agents);
		final models: Array<ModelRow> = modelRows(agents);
		final slices: Array<SliceCost> = sliceCosts(agents, landed);
		return {
			agents: agents.length,
			turns: agents.fold((a, sum) -> sum + a.turns.length, 0),
			toolInTok: tools.fold((t, sum) -> sum + t.inTok, 0),
			toolOutTok: tools.fold((t, sum) -> sum + t.outTok, 0),
			cost: round(models.fold((m, sum) -> sum + m.cost, 0.0)),
			tools: tools,
			roles: roleRows(agents),
			models: models,
			slices: slices,
			landed: landed == null ? null : landedSummary(slices),
			rewrites: rewriteSummary(agents),
			bypass: bypassSummary(agents),
			assumptions: [
				'sizes are characters / ${TokenTranscript.CHARS_PER_TOKEN}',
				'cache write priced at ${WRITE_5M_MULTIPLE}x (5m) / ${WRITE_1H_MULTIPLE}x (1h) of the input price',
				'a rewrite is a turn after the first whose cache write is >= ${Math.round(REWRITE_SHARE * PERCENT)}'
					+ '% of its context and whose context is >= $REWRITE_MIN_CONTEXT tokens',
				'a gap is the time from the end of the previous turn to the start of the rewriting turn'
			]
		};
	}

	/** The price list entry for `model` (matched by family name), or null for a model the table does not know. */
	public static function priceOf(model: String): Null<Price> {
		return PRICES.find(p -> model.indexOf(p.family) >= 0);
	}

	/** What `turn` cost in dollars; zero for an unpriced model. */
	public static function costOf(turn: TurnReading): Float {
		final price: Null<Price> = priceOf(turn.model);
		return price == null
			? 0
			: (
				turn.input * price.input
					+ turn.output * price.output
					+ turn.cacheRead * price.read
					+ turn.write5m * price.input * WRITE_5M_MULTIPLE
					+ turn.write1h * price.input * WRITE_1H_MULTIPLE
			) / PER_MTOK;
	}

	/** The cache rewrites of one agent, in turn order: its first turn only fills the cache, so it is never one. */
	public static function rewritesOf(agent: AgentReading): Array<Rewrite> {
		final found: Array<Rewrite> = [];
		for (i in 1...agent.turns.length) {
			final turn: TurnReading = agent.turns[i];
			final written: Int = turn.write5m + turn.write1h;
			final context: Int = turn.input + turn.cacheRead + written;
			if (context < REWRITE_MIN_CONTEXT || written < REWRITE_SHARE * context) continue;
			final price: Null<Price> = priceOf(turn.model);
			found.push({
				agent: agent.id,
				slice: agent.slice,
				model: turn.model,
				tokens: written,
				context: context,
				gapSeconds: (turn.start - agent.turns[i - 1].end) / MS_PER_SECOND,
				extraCost: price == null ? 0 : round(costOfWrite(turn, price) - written * price.read / PER_MTOK)
			});
		}
		return found;
	}

	private static inline function costOfWrite(turn: TurnReading, price: Price): Float {
		return (turn.write5m * WRITE_5M_MULTIPLE + turn.write1h * WRITE_1H_MULTIPLE) * price.input / PER_MTOK;
	}

	private static function toolRows(agents: Array<AgentReading>): Array<ToolRow> {
		final sums: Map<String, ToolStat> = [];
		for (agent in agents) for (key => stat in agent.tools) {
			final sum: ToolStat = sums[key] ?? TokenTranscript.emptyStat();
			TokenTranscript.addStat(sum, stat);
			sums[key] = sum;
		}
		final rows: Array<ToolRow> = [
			for (key => sum in sums)
				{
					key: key,
					calls: sum.calls,
					outTok: tokens(sum.outChars),
					avgOutTok: sum.calls == 0 ? 0 : Math.round(tokens(sum.outChars) / sum.calls),
					inTok: tokens(sum.inChars),
					over2k: sum.over2k,
					over5k: sum.over5k
				}
		];
		rows.sort((a, b) -> b.inTok + b.outTok - a.inTok - a.outTok);
		return rows;
	}

	/** The calls of each tool kind per agent role, the role and tool with the most output first. */
	private static function roleRows(agents: Array<AgentReading>): Array<RoleToolRow> {
		final sums: Map<String, ToolStat> = [];

		for (agent in agents) for (key => stat in agent.tools) {
			final id: String = '${agent.role}\n$key';
			final sum: ToolStat = sums[id] ?? TokenTranscript.emptyStat();
			TokenTranscript.addStat(sum, stat);
			for (big in stat.biggest) TokenTranscript.keepBiggest(sum.biggest, big);
			sums[id] = sum;
		}
		final rows: Array<RoleToolRow> = [
			for (id => sum in sums)
				{
					role: id.substr(0, id.indexOf('\n')),
					key: id.substr(id.indexOf('\n') + 1),
					calls: sum.calls,
					outTok: tokens(sum.outChars),
					over5k: sum.over5k,
					biggest: sum.biggest.map(big -> {outTok: tokens(big.outChars), call: big.call })
				}
		];
		rows.sort((a, b) -> b.outTok - a.outTok);
		return rows;
	}

	private static function tokens(chars: Int): Int {
		return Math.round(chars / TokenTranscript.CHARS_PER_TOKEN);
	}

	private static function modelRows(agents: Array<AgentReading>): Array<ModelRow> {
		final rows: Map<String, ModelRow> = [];
		for (agent in agents) for (turn in agent.turns) {
			final row: ModelRow = rows[turn.model] ?? {
				model: turn.model,
				turns: 0,
				input: 0,
				output: 0,
				cacheRead: 0,
				cacheWrite: 0,
				cost: 0
			};
			row.turns++;
			row.input += turn.input;
			row.output += turn.output;
			row.cacheRead += turn.cacheRead;
			row.cacheWrite += turn.write5m + turn.write1h;
			row.cost += costOf(turn);
			rows[turn.model] = row;
		}
		return costliestFirst([for (row in rows) row]);
	}

	private static function sliceCosts(agents: Array<AgentReading>, landed: Null<Array<String>>): Array<SliceCost> {
		final rows: Map<String, SliceCost> = [];
		for (agent in agents) {
			final key: String = agent.slice ?? OTHER;
			final row: SliceCost = rows[key] ?? {
				slice: key,
				agents: 0,
				turns: 0,
				output: 0,
				cost: 0,
				landed: landed != null && landed.contains(key)
			};
			row.agents++;
			row.turns += agent.turns.length;
			for (turn in agent.turns) {
				row.output += turn.output;
				row.cost += costOf(turn);
			}
			rows[key] = row;
		}
		return costliestFirst([for (row in rows) row]);
	}

	private static function landedSummary(slices: Array<SliceCost>): LandedSummary {
		final done: Array<SliceCost> = slices.filter(s -> s.landed);
		final cost: Float = done.fold((s, sum) -> sum + s.cost, 0.0);
		return { slices: done.length, cost: round(cost), perSlice: done.length == 0 ? 0 : round(cost / done.length) };
	}

	private static function rewriteSummary(agents: Array<AgentReading>): RewriteSummary {
		final all: Array<Rewrite> = [];
		var initial: Int = 0;
		var appended: Int = 0;
		var turns: Int = 0;
		for (agent in agents) {
			final found: Array<Rewrite> = rewritesOf(agent);
			for (r in found) all.push(r);
			var rewritten: Int = 0;
			for (r in found) rewritten += r.tokens;
			for (i => turn in agent.turns) {
				final written: Int = turn.write5m + turn.write1h;
				if (i == 0)
					initial += written
				else
					appended += written;
			}
			appended -= rewritten;
			turns += agent.turns.length;
		}
		final gaps: Array<Float> = all.map(r -> r.gapSeconds);
		gaps.sort(Reflect.compare);
		final worst: Array<Rewrite> = all.copy();
		worst.sort((a, b) -> Reflect.compare(b.extraCost, a.extraCost));
		return {
			turns: turns,
			rewrites: all.length,
			rewriteTokens: all.fold((r, sum) -> sum + r.tokens, 0),
			appendTokens: appended,
			initialTokens: initial,
			extraCost: round(all.fold((r, sum) -> sum + r.extraCost, 0.0)),
			gapMedianSeconds: gaps.length == 0 ? 0 : gaps[gaps.length >> 1],
			gapMaxSeconds: gaps.length == 0 ? 0 : gaps[gaps.length - 1],
			within5m: all.count(r -> r.gapSeconds <= TTL_SHORT),
			to1h: all.count(r -> r.gapSeconds > TTL_SHORT && r.gapSeconds <= TTL_LONG),
			over1h: all.count(r -> r.gapSeconds > TTL_LONG),
			worst: worst.slice(0, WORST_REWRITES)
		};
	}

	private static function bypassSummary(agents: Array<AgentReading>): BypassSummary {
		final reads: Array<String> = gather(agents, a -> a.hxReads);
		final writes: Array<String> = gather(agents, a -> a.hxWrites);
		final scripts: Array<String> = gather(agents, a -> a.scriptWrites);
		var payload: Int = 0;
		var indent: Int = 0;
		for (agent in agents) {
			payload += agent.writeChars;
			indent += agent.indentChars;
		}
		return {
			shellHxReads: reads.length,
			hxWrites: writes.length,
			scriptWrites: scripts.length,
			deniedReads: gather(agents, a -> a.deniedReads).length,
			deniedWrites: gather(agents, a -> a.deniedWrites).length,
			writePayloadTok: tokens(payload),
			indentTok: tokens(indent),
			readSamples: reads.slice(0, SAMPLES),
			writeSamples: writes.slice(0, SAMPLES),
			scriptSamples: scripts.slice(0, SAMPLES)
		};
	}

	/** The entries `pick` takes from every agent, in agent order. */
	private static function gather(agents: Array<AgentReading>, pick: AgentReading -> Array<String>): Array<String> {
		return [for (agent in agents) for (entry in pick(agent)) entry];
	}

	/** `value` rounded to a ten-thousandth of a dollar. */
	private static function round(value: Float): Float {
		return Math.round(value * COST_SCALE) / COST_SCALE;
	}

	/** `rows` ordered by their cost, the costliest first, each cost rounded for the report. */
	private static function costliestFirst<T:{ var cost: Float; }>(rows: Array<T>): Array<T> {
		rows.sort((a, b) -> Reflect.compare(b.cost, a.cost));
		for (row in rows) row.cost = round(row.cost);
		return rows;
	}

}

/** A model family and its dollars per million tokens. */
typedef Price = {
	var family: String;
	var input: Float;
	var output: Float;
	var read: Float;
}
