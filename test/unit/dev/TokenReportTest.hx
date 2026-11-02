package unit.dev;

import dev.TokenReport;
import dev.TokenTranscript;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * `TokenReport`: the price of a turn per model family, the turns that rebuild their whole cache and the idle gap before each,
 * and the sums per tool, model and slice (with the landed ones singled out).
 */
@:nullSafety(Strict)
final class TokenReportTest extends Test {

	private static inline final MILLION: Int = 1000000;

	public function testATurnIsPricedPerMillionTokensOfItsModelFamily(): Void {
		final opus: TurnReading = turn('claude-opus-5-5', 0, {
			input: MILLION,
			output: MILLION,
			cacheRead: MILLION,
			write5m: MILLION,
			write1h: MILLION
		});
		Assert.floatEquals(4 + 20 + 0.2 + 4 * 1.25 + 4 * 2, TokenReport.costOf(opus));
		final sonnet: TurnReading = turn('claude-sonnet-5-5', 0, {
			input: MILLION,
			output: 0,
			cacheRead: 0,
			write5m: 0,
			write1h: 0
		});
		Assert.floatEquals(2, TokenReport.costOf(sonnet));
		Assert.equals(
			0.0, TokenReport.costOf(turn('claude-future-9', 0, {
				input: MILLION,
				output: 0,
				cacheRead: 0,
				write5m: 0,
				write1h: 0
			}))
		);
	}

	public function testATurnThatRewritesItsContextIsToldFromAnAppendByItsCacheWrite(): Void {
		final agent: AgentReading = agentOf('s', 'S1', [
			turn('claude-opus-5-5', 0, {
				input: 10,
				output: 5,
				cacheRead: 0,
				write5m: 50000,
				write1h: 0
			}),
			turn('claude-opus-5-5', 10000, {
				input: 10,
				output: 5,
				cacheRead: 50000,
				write5m: 800,
				write1h: 0
			}),
			turn('claude-opus-5-5', 700000, {
				input: 10,
				output: 5,
				cacheRead: 0,
				write5m: 51000,
				write1h: 0
			})
		]);
		final found: Array<Rewrite> = TokenReport.rewritesOf(agent);
		Assert.equals(1, found.length);
		Assert.equals(51000, found[0].tokens);
		Assert.floatEquals(690, found[0].gapSeconds);
		Assert.isTrue(found[0].extraCost > 0);
	}

	public function testAFirstTurnAndASmallContextAreNeverRewrites(): Void {
		final agent: AgentReading = agentOf('s', 'S1', [
			turn('claude-opus-5-5', 0, {
				input: 10,
				output: 5,
				cacheRead: 0,
				write5m: 90000,
				write1h: 0
			}),
			turn('claude-opus-5-5', 1000, {
				input: 10,
				output: 5,
				cacheRead: 0,
				write5m: 900,
				write1h: 0
			})
		]);
		Assert.equals(0, TokenReport.rewritesOf(agent).length);
	}

	public function testGapsAreBucketedByTheCacheLifetimes(): Void {
		final report: Report = TokenReport.summarize([
			agentOf('a', 'S1', rewriting(200)),
			agentOf('b', 'S1', rewriting(1800)),
			agentOf('c', 'S2', rewriting(7200))
		], null);
		Assert.equals(3, report.rewrites.rewrites);
		Assert.equals(1, report.rewrites.within5m);
		Assert.equals(1, report.rewrites.to1h);
		Assert.equals(1, report.rewrites.over1h);
		Assert.floatEquals(1800, report.rewrites.gapMedianSeconds);
		Assert.floatEquals(7200, report.rewrites.gapMaxSeconds);
		Assert.equals(3 * 40000, report.rewrites.initialTokens);
		Assert.equals(3 * 40000, report.rewrites.rewriteTokens);
		Assert.equals(0, report.rewrites.appendTokens);
	}

	public function testCostIsSummedPerSliceAndPerLandedSlice(): Void {
		final report: Report = TokenReport.summarize([
			agentOf('a', 'S1', [
				turn('claude-opus-5-5', 0, {
					input: MILLION,
					output: 0,
					cacheRead: 0,
					write5m: 0,
					write1h: 0
				})
			]),
			agentOf('b', 'S1', [
				turn('claude-opus-5-5', 0, {
					input: MILLION,
					output: 0,
					cacheRead: 0,
					write5m: 0,
					write1h: 0
				})
			]),
			agentOf('c', 'S2', [
				turn('claude-sonnet-5-5', 0, {
					input: MILLION,
					output: 0,
					cacheRead: 0,
					write5m: 0,
					write1h: 0
				})
			]),
			agentOf('d', null, [
				turn('claude-sonnet-5-5', 0, {
					input: MILLION,
					output: 0,
					cacheRead: 0,
					write5m: 0,
					write1h: 0
				})
			])
		], ['S1']);
		Assert.equals(3, report.slices.length);
		Assert.equals('S1', report.slices[0].slice);
		Assert.equals(2, report.slices[0].agents);
		Assert.floatEquals(8, report.slices[0].cost);
		Assert.isTrue(report.slices[0].landed);
		Assert.isFalse(report.slices[1].landed);
		Assert.equals(1, report.landed?.slices);
		Assert.floatEquals(8, report.landed?.perSlice ?? -1);
		Assert.floatEquals(12, report.cost);
		Assert.isTrue(report.slices.exists(s -> s.slice == TokenReport.OTHER));
	}

	public function testNoLandedListLeavesTheLandedSummaryOut(): Void {
		Assert.isNull(TokenReport.summarize([agentOf('a', 'S1', [])], null).landed);
	}

	public function testToolsAreSummedAcrossAgentsAndSortedBySize(): Void {
		final first: AgentReading = agentOf('a', 'S1', []);
		first.tools['hxq show'] = stat(1, 400, 0, 0);
		final second: AgentReading = agentOf('b', 'S1', []);
		second.tools['hxq show'] = stat(2, 40000, 1, 0);
		second.tools['git diff'] = stat(1, 100000, 1, 1);
		final report: Report = TokenReport.summarize([first, second], null);
		Assert.equals('git diff', report.tools[0].key);
		Assert.equals(3, report.tools[1].calls);
		Assert.equals(10100, report.tools[1].outTok);
		Assert.equals(1, report.tools[1].over2k);
		Assert.equals(35100, report.toolOutTok);
	}

	public function testToolsAreSummedPerRoleWithTheLargestCallsKeptAndConvertedToTokens(): Void {
		final worker: AgentReading = agentOf('a', 'S1', []);
		worker.role = TokenTranscript.ROLE_WORKER;
		worker.tools['hxq show'] = stat(2, 40000, 1, 0, [{ outChars: 36000, call: 'hxq show a' }, { outChars: 4000, call: 'hxq show b' }]);
		final other: AgentReading = agentOf('b', 'S1', []);
		other.role = TokenTranscript.ROLE_WORKER;
		other.tools['hxq show'] = stat(2, 800, 0, 0, [{ outChars: 400, call: 'hxq show c' }, { outChars: 400, call: 'hxq show d' }]);
		final reviewer: AgentReading = agentOf('c', 'S1', []);
		reviewer.role = TokenTranscript.ROLE_REVIEWER;
		reviewer.tools['git diff'] = stat(1, 80000, 1, 1);
		final rows: Array<RoleToolRow> = TokenReport.summarize([worker, other, reviewer], null).roles;
		Assert.equals(2, rows.length);
		Assert.equals(TokenTranscript.ROLE_REVIEWER, rows[0].role);
		Assert.equals('git diff', rows[0].key);
		Assert.equals(20000, rows[0].outTok);
		Assert.equals(1, rows[0].over5k);
		Assert.equals(TokenTranscript.ROLE_WORKER, rows[1].role);
		Assert.equals(4, rows[1].calls);
		Assert.equals(10200, rows[1].outTok);
		Assert.equals(3, rows[1].biggest.length);
		Assert.equals('hxq show a', rows[1].biggest[0].call);
		Assert.equals(9000, rows[1].biggest[0].outTok);
		Assert.equals('hxq show b', rows[1].biggest[1].call);
	}

	public function testBypassesAreSummedAndSampled(): Void {
		final agent: AgentReading = agentOf('a', 'S1', []);
		agent.hxReads = ['cat src/A.hx', 'sed -n 1p src/B.hx'];
		agent.hxWrites = ['Edit /w/src/A.hx'];
		agent.writeChars = 4000;
		agent.indentChars = 400;
		final report: Report = TokenReport.summarize([agent], null);
		Assert.equals(2, report.bypass.shellHxReads);
		Assert.equals(1, report.bypass.hxWrites);
		Assert.equals(1000, report.bypass.writePayloadTok);
		Assert.equals(100, report.bypass.indentTok);
	}

	/** Two turns, the second rebuilding a 40000-token context after `gap` seconds, behind a first fill of 40000. */
	private static function rewriting(gap: Float): Array<TurnReading> {
		return [
			turn('claude-opus-5-5', 0, {
				input: 10,
				output: 5,
				cacheRead: 0,
				write5m: 40000,
				write1h: 0
			}),
			turn('claude-opus-5-5', gap * 1000, {
				input: 10,
				output: 5,
				cacheRead: 0,
				write5m: 40000,
				write1h: 0
			})
		];
	}

	private static function agentOf(id: String, slice: Null<String>, turns: Array<TurnReading>): AgentReading {
		return {
			id: id,
			role: TokenTranscript.ROLE_OTHER,
			slice: slice,
			tools: [],
			turns: turns,
			hxReads: [],
			hxWrites: [],
			scriptWrites: [],
			deniedReads: [],
			deniedWrites: [],
			writeChars: 0,
			indentChars: 0
		};
	}

	private static function stat(calls: Int, outChars: Int, over2k: Int, over5k: Int, ?biggest: Array<BigCall>): ToolStat {
		return {
			calls: calls,
			inChars: 0,
			outChars: outChars,
			over2k: over2k,
			over5k: over5k,
			biggest: biggest ?? []
		};
	}

	/** A turn starting `at` milliseconds in and ending at the same time. */
	private static function turn(model: String, at: Float, usage: Usage): TurnReading {
		return {
			model: model,
			start: at,
			end: at,
			input: usage.input,
			output: usage.output,
			cacheRead: usage.cacheRead,
			write5m: usage.write5m,
			write1h: usage.write1h
		};
	}

}

private typedef Usage = {
	var input: Int;
	var output: Int;
	var cacheRead: Int;
	var write5m: Int;
	var write1h: Int;
}
