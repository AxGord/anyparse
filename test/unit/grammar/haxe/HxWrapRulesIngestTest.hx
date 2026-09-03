package unit.grammar.haxe;

import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRule;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-peg-byname-array — unit tests for the `wrapping.<construct>.rules`
 * cascade ingestion lifted by the `@:peg` ByName Array<T> support.
 *
 * Scope: assert that `loadHxFormatJson` round-trips `rules: [...]` into
 * the runtime `WrapRules` cascade (mode + cond + value), correctly
 * drops rules with an unrecognised `cond` predicate, and degrades
 * gracefully when an entry is malformed.
 *
 * Between them the tests here name every mapped predicate at least
 * once, so a dropped `wrapCondFromString` arm is caught by this file alone. They do NOT cover every accepted SPELLING — each arm
 * takes both a symbolic form and one or more enum identifiers, and only a
 * few identifiers are exercised. `testLineLengthLessThanStillDropsRule`
 * pins the one fork-shipped predicate that is still unmapped, from the
 * other side.
 */
@:nullSafety(Strict)
class HxWrapRulesIngestTest extends Test {

	public function new(): Void {
		super();
	}

	public function testSingleRuleWithSingleConditionIngested(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"defaultWrap":"noWrap","rules":[{"type":"onePerLine","conditions":[{"cond":"itemCount >= '
			+ 'n","value":4}]}]}}}'
		);
		Assert.equals(WrapMode.NoWrap, opts.methodChainWrap.defaultMode);
		Assert.equals(1, opts.methodChainWrap.rules.length);
		final rule: WrapRule = opts.methodChainWrap.rules[0];
		Assert.equals(WrapMode.OnePerLine, rule.mode);
		Assert.equals(1, rule.conditions.length);
		Assert.equals(WrapConditionType.ItemCountLargerThan, rule.conditions[0].cond);
		Assert.equals(4, rule.conditions[0].value);
	}

	public function testMultipleConditionsAndAllPredicates(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"rules":[{"type":"noWrap","conditions":[{"cond":"itemCount <= n","value":3},{'
			+ '"cond":"exceedsMaxLineLength","value":0}]},{"type":"onePerLineAfterFirst","conditions":[{"cond":"anyItemLength >= '
			+ 'n","value":30},{"cond":"allItemLengths < n","value":50}]},{'
			+ '"type":"fillLine","conditions":[{"cond":"totalItemLength <= n","value":80},{"cond":"totalItemLength >= n","value":20}]}]}}}'
		);
		Assert.equals(3, opts.methodChainWrap.rules.length);
		final r0: WrapRule = opts.methodChainWrap.rules[0];
		Assert.equals(WrapMode.NoWrap, r0.mode);
		Assert.equals(2, r0.conditions.length);
		Assert.equals(WrapConditionType.ItemCountLessThan, r0.conditions[0].cond);
		Assert.equals(3, r0.conditions[0].value);
		Assert.equals(WrapConditionType.ExceedsMaxLineLength, r0.conditions[1].cond);
		final r1: WrapRule = opts.methodChainWrap.rules[1];
		Assert.equals(WrapMode.OnePerLineAfterFirst, r1.mode);
		Assert.equals(2, r1.conditions.length);
		Assert.equals(WrapConditionType.AnyItemLengthLargerThan, r1.conditions[0].cond);
		Assert.equals(30, r1.conditions[0].value);
		Assert.equals(WrapConditionType.AllItemLengthsLessThan, r1.conditions[1].cond);
		Assert.equals(50, r1.conditions[1].value);
		final r2: WrapRule = opts.methodChainWrap.rules[2];
		Assert.equals(WrapMode.FillLine, r2.mode);
		Assert.equals(2, r2.conditions.length);
		Assert.equals(WrapConditionType.TotalItemLengthLessThan, r2.conditions[0].cond);
		Assert.equals(80, r2.conditions[0].value);
		Assert.equals(WrapConditionType.TotalItemLengthLargerThan, r2.conditions[1].cond);
		Assert.equals(20, r2.conditions[1].value);
	}

	public function testLineLengthCondIngested(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"rules":[{"type":"onePerLineAfterFirst","conditions":[{"cond":"lineLength >= n","value":160}]},{'
			+ '"type":"noWrap","conditions":[{"cond":"itemCount <= n","value":3}]}]}}}'
		);
		Assert.equals(2, opts.methodChainWrap.rules.length);
		Assert.equals(WrapMode.OnePerLineAfterFirst, opts.methodChainWrap.rules[0].mode);
		Assert.equals(1, opts.methodChainWrap.rules[0].conditions.length);
		Assert.equals(WrapConditionType.LineLengthLargerThan, opts.methodChainWrap.rules[0].conditions[0].cond);
		Assert.equals(160, opts.methodChainWrap.rules[0].conditions[0].value);
	}

	/**
	 * The four predicates the fork SHIPS in its own default config that hxq
	 * had no mapping for — so `wrapRuleFromConfig` returned null and the
	 * whole rule vanished from the cascade, silently and indistinguishably
	 * from a typo. `allItemLengths <= n` is the fork's spelling of a
	 * condition hxq already evaluated under its own older `allItemLengths <
	 * n` (both still map, see the arm below); the other three are new
	 * `WrapConditionType` members. `HasMultiLineItems` is the fork's
	 * enum IDENTIFIER, which differs from hxq's `HasMultilineItems` by one
	 * capital and drops the rule just as quietly.
	 */
	public function testForkShippedCondSpellingsIngest(): Void {
		final conds: Array<String> = [
			'{"cond":"equalItemLengths","value":1}',
			'{"cond":"allItemLengths <= n","value":30}',
			'{"cond":"allItemLengths >= n","value":5}',
			'{"cond":"anyItemLength <= n","value":15}',
			'{"cond":"HasMultiLineItems","value":1}',
			'{"cond":"allItemLengths < n","value":30}'
		];
		final ruleList: String = [for (cond in conds) '{"type":"noWrap","conditions":[$cond]}'].join(',');
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"wrapping":{"arrayWrap":{"rules":[$ruleList]}}}');
		final rules: Array<WrapRule> = opts.arrayLiteralWrap.rules;
		Assert.equals(6, rules.length);
		Assert.equals(WrapConditionType.EqualItemLengths, rules[0].conditions[0].cond);
		Assert.equals(1, rules[0].conditions[0].value);
		Assert.equals(WrapConditionType.AllItemLengthsLessThan, rules[1].conditions[0].cond);
		Assert.equals(30, rules[1].conditions[0].value);
		Assert.equals(WrapConditionType.AllItemLengthsLargerThan, rules[2].conditions[0].cond);
		Assert.equals(WrapConditionType.AnyItemLengthLessThan, rules[3].conditions[0].cond);
		Assert.equals(15, rules[3].conditions[0].value);
		Assert.equals(WrapConditionType.HasMultilineItems, rules[4].conditions[0].cond);
		Assert.equals(WrapConditionType.AllItemLengthsLessThan, rules[5].conditions[0].cond);
	}

	/**
	 * `lineLength <= n` is the ONE fork-shipped predicate still unmapped
	 * after the four above: answering it needs the renderer's column probe
	 * inverted, and no config this project has met uses it. Pinned as a
	 * DROP so the day it is implemented this test fails and says where.
	 */
	public function testLineLengthLessThanStillDropsRule(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"arrayWrap":{"rules":[{"type":"noWrap","conditions":[{"cond":"lineLength <= n","value":80}]},'
			+ '{"type":"onePerLine","conditions":[{"cond":"itemCount >= n","value":4}]}]}}}'
		);
		Assert.equals(1, opts.arrayLiteralWrap.rules.length);
		Assert.equals(WrapMode.OnePerLine, opts.arrayLiteralWrap.rules[0].mode);
	}

	/**
	 * A condition with no `value` reads `1`, matching haxe-formatter's
	 * `@:default(1)` on the field. It used to read `0`, which for the three
	 * POLARITY predicates is not a missing threshold but the OPPOSITE rule:
	 * `equalItemLengths` with no value meant "match when the items differ".
	 */
	public function testOmittedCondValueDefaultsToOne(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"arrayWrap":{"rules":[{"type":"noWrap","conditions":[{"cond":"equalItemLengths"}]}]}}}'
		);
		Assert.equals(1, opts.arrayLiteralWrap.rules[0].conditions[0].value);
	}

	/**
	 * ω-complex-item-count: `complexItemCount >= n` ingests like every other predicate. Sits
	 * beside `testUnknownCondDropsRule` on purpose — before the mapping existed this exact JSON
	 * took THAT path and the rule was silently dropped, which is what a config-only D1 arm
	 * looks like when the engine has not learned the condition.
	 */
	public function testComplexItemCountCondIngested(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"arrayWrap":{"rules":[{"type":"onePerLine","conditions":[{"cond":"complexItemCount >= n","value":2}]}]}}}'
		);
		Assert.equals(1, opts.arrayLiteralWrap.rules.length);
		final rule: WrapRule = opts.arrayLiteralWrap.rules[0];
		Assert.equals(WrapMode.OnePerLine, rule.mode);
		Assert.equals(WrapConditionType.ComplexItemCountLargerThan, rule.conditions[0].cond);
		Assert.equals(2, rule.conditions[0].value);
	}

	/**
	 * `hasContainerItems` ingests as a bare predicate — the JSON carries a `value` of 1 for the
	 * positive polarity, like `hasMultilineItems` does. Its `callParameter` home is where the
	 * condition earns its keep, so it ingests through that cascade rather than `arrayWrap`.
	 */
	public function testHasContainerItemsCondIngested(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"callParameter":{"rules":[{"type":"onePerLine","conditions":[{"cond":"hasContainerItems","value":1}]}]}}}'
		);
		Assert.equals(1, opts.callParameterWrap.rules.length);
		final rule: WrapRule = opts.callParameterWrap.rules[0];
		Assert.equals(WrapMode.OnePerLine, rule.mode);
		Assert.equals(WrapConditionType.HasContainerItems, rule.conditions[0].cond);
		Assert.equals(1, rule.conditions[0].value);
	}

	/** `hasMultilineLambdaItems` ingests as a bare predicate, like its two neighbours. */
	public function testHasMultilineLambdaItemsCondIngested(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"callParameter":{"rules":[{"type":"onePerLine","conditions":[{"cond":"hasMultilineLambdaItems","value":1}]}]}}}'
		);
		Assert.equals(1, opts.callParameterWrap.rules.length);
		Assert.equals(WrapConditionType.HasMultilineLambdaItems, opts.callParameterWrap.rules[0].conditions[0].cond);
	}

	public function testUnknownCondDropsRule(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"rules":[{"type":"onePerLineAfterFirst","conditions":[{"cond":"thisCondIsBogus >= '
			+ 'n","value":42}]},{"type":"noWrap","conditions":[{"cond":"itemCount <= n","value":3}]}]}}}'
		);
		Assert.equals(1, opts.methodChainWrap.rules.length);
		Assert.equals(WrapMode.NoWrap, opts.methodChainWrap.rules[0].mode);
	}

	public function testUnknownTypeDropsRule(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"rules":[{"type":"customMode","conditions":[{"cond":"itemCount >= n","value":7}]},{'
			+ '"type":"onePerLine","conditions":[{"cond":"itemCount >= n","value":7}]}]}}}'
		);
		Assert.equals(1, opts.methodChainWrap.rules.length);
		Assert.equals(WrapMode.OnePerLine, opts.methodChainWrap.rules[0].mode);
	}

	public function testEmptyRulesArrayResetsCascade(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"defaultWrap":"onePerLine","rules":[]}}}'
		);
		Assert.equals(WrapMode.OnePerLine, opts.methodChainWrap.defaultMode);
		Assert.equals(0, opts.methodChainWrap.rules.length);
	}

	public function testAbsentRulesPreservesBaselineCascade(): Void {
		final base: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"wrapping":{"methodChain":{"defaultWrap":"noWrap"}}}');
		Assert.equals(base.methodChainWrap.rules.length, opts.methodChainWrap.rules.length);
		Assert.equals(WrapMode.NoWrap, opts.methodChainWrap.defaultMode);
	}

	public function testArrayWrapAndAnonTypeShareTheSameIngest(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"arrayWrap":{"rules":[{"type":"onePerLine","conditions":[]}]},'
			+ '"anonType":{"rules":[{"type":"fillLine","conditions":[]}]}}}'
		);
		Assert.equals(1, opts.arrayLiteralWrap.rules.length);
		Assert.equals(WrapMode.OnePerLine, opts.arrayLiteralWrap.rules[0].mode);
		Assert.equals(1, opts.anonTypeWrap.rules.length);
		Assert.equals(WrapMode.FillLine, opts.anonTypeWrap.rules[0].mode);
	}

	public function testEmptyConditionsArrayProducesAlwaysFiringRule(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"rules":[{"type":"onePerLine","conditions":[]}]}}}'
		);
		Assert.equals(1, opts.methodChainWrap.rules.length);
		Assert.equals(0, opts.methodChainWrap.rules[0].conditions.length);
		Assert.equals(WrapMode.OnePerLine, opts.methodChainWrap.rules[0].mode);
	}

}
