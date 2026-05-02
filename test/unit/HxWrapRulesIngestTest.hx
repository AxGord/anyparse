package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRule;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-peg-byname-array — unit tests for the `wrapping.<construct>.rules`
 * cascade ingestion lifted by the `@:peg` ByName Array<T> support.
 *
 * Scope: assert that `loadHxFormatJson` round-trips `rules: [...]` into
 * the runtime `WrapRules` cascade (mode + cond + value), correctly
 * drops rules whose `cond` predicate isn't modelled yet
 * (`lineLength >= n`), and degrades gracefully when an entry is
 * malformed.
 *
 * `testMultipleConditionsAndAllPredicates` exercises all seven
 * `wrapCondFromString` branches (`itemCount <= n` / `itemCount >= n` /
 * `anyItemLength >= n` / `allItemLengths < n` / `totalItemLength <= n` /
 * `totalItemLength >= n` / `exceedsMaxLineLength`) so a regression in
 * any single arm is caught by this file alone.
 */
@:nullSafety(Strict)
class HxWrapRulesIngestTest extends Test {

	public function new():Void {
		super();
	}

	public function testSingleRuleWithSingleConditionIngested():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"defaultWrap":"noWrap","rules":['
				+ '{"type":"onePerLine","conditions":[{"cond":"itemCount >= n","value":4}]}'
				+ ']}}}'
		);
		Assert.equals(WrapMode.NoWrap, opts.methodChainWrap.defaultMode);
		Assert.equals(1, opts.methodChainWrap.rules.length);
		final rule:WrapRule = opts.methodChainWrap.rules[0];
		Assert.equals(WrapMode.OnePerLine, rule.mode);
		Assert.equals(1, rule.conditions.length);
		Assert.equals(WrapConditionType.ItemCountLargerThan, rule.conditions[0].cond);
		Assert.equals(4, rule.conditions[0].value);
	}

	public function testMultipleConditionsAndAllPredicates():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"rules":['
				+ '{"type":"noWrap","conditions":['
				+ '{"cond":"itemCount <= n","value":3},'
				+ '{"cond":"exceedsMaxLineLength","value":0}'
				+ ']},'
				+ '{"type":"onePerLineAfterFirst","conditions":['
				+ '{"cond":"anyItemLength >= n","value":30},'
				+ '{"cond":"allItemLengths < n","value":50}'
				+ ']},'
				+ '{"type":"fillLine","conditions":['
				+ '{"cond":"totalItemLength <= n","value":80},'
				+ '{"cond":"totalItemLength >= n","value":20}'
				+ ']}'
				+ ']}}}'
		);
		Assert.equals(3, opts.methodChainWrap.rules.length);
		final r0:WrapRule = opts.methodChainWrap.rules[0];
		Assert.equals(WrapMode.NoWrap, r0.mode);
		Assert.equals(2, r0.conditions.length);
		Assert.equals(WrapConditionType.ItemCountLessThan, r0.conditions[0].cond);
		Assert.equals(3, r0.conditions[0].value);
		Assert.equals(WrapConditionType.ExceedsMaxLineLength, r0.conditions[1].cond);
		final r1:WrapRule = opts.methodChainWrap.rules[1];
		Assert.equals(WrapMode.OnePerLineAfterFirst, r1.mode);
		Assert.equals(2, r1.conditions.length);
		Assert.equals(WrapConditionType.AnyItemLengthLargerThan, r1.conditions[0].cond);
		Assert.equals(30, r1.conditions[0].value);
		Assert.equals(WrapConditionType.AllItemLengthsLessThan, r1.conditions[1].cond);
		Assert.equals(50, r1.conditions[1].value);
		final r2:WrapRule = opts.methodChainWrap.rules[2];
		Assert.equals(WrapMode.FillLine, r2.mode);
		Assert.equals(2, r2.conditions.length);
		Assert.equals(WrapConditionType.TotalItemLengthLessThan, r2.conditions[0].cond);
		Assert.equals(80, r2.conditions[0].value);
		Assert.equals(WrapConditionType.TotalItemLengthLargerThan, r2.conditions[1].cond);
		Assert.equals(20, r2.conditions[1].value);
	}

	public function testUnmodelledLineLengthCondDropsRule():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"rules":['
				+ '{"type":"onePerLineAfterFirst","conditions":['
				+ '{"cond":"lineLength >= n","value":160}'
				+ ']},'
				+ '{"type":"noWrap","conditions":['
				+ '{"cond":"itemCount <= n","value":3}'
				+ ']}'
				+ ']}}}'
		);
		Assert.equals(1, opts.methodChainWrap.rules.length);
		Assert.equals(WrapMode.NoWrap, opts.methodChainWrap.rules[0].mode);
	}

	public function testUnknownTypeDropsRule():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"rules":['
				+ '{"type":"customMode","conditions":[{"cond":"itemCount >= n","value":7}]},'
				+ '{"type":"onePerLine","conditions":[{"cond":"itemCount >= n","value":7}]}'
				+ ']}}}'
		);
		Assert.equals(1, opts.methodChainWrap.rules.length);
		Assert.equals(WrapMode.OnePerLine, opts.methodChainWrap.rules[0].mode);
	}

	public function testEmptyRulesArrayResetsCascade():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"defaultWrap":"onePerLine","rules":[]}}}'
		);
		Assert.equals(WrapMode.OnePerLine, opts.methodChainWrap.defaultMode);
		Assert.equals(0, opts.methodChainWrap.rules.length);
	}

	public function testAbsentRulesPreservesBaselineCascade():Void {
		final base:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"defaultWrap":"noWrap"}}}'
		);
		Assert.equals(base.methodChainWrap.rules.length, opts.methodChainWrap.rules.length);
		Assert.equals(WrapMode.NoWrap, opts.methodChainWrap.defaultMode);
	}

	public function testArrayWrapAndAnonTypeShareTheSameIngest():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{'
				+ '"arrayWrap":{"rules":[{"type":"onePerLine","conditions":[]}]},'
				+ '"anonType":{"rules":[{"type":"fillLine","conditions":[]}]}'
				+ '}}'
		);
		Assert.equals(1, opts.arrayLiteralWrap.rules.length);
		Assert.equals(WrapMode.OnePerLine, opts.arrayLiteralWrap.rules[0].mode);
		Assert.equals(1, opts.anonTypeWrap.rules.length);
		Assert.equals(WrapMode.FillLine, opts.anonTypeWrap.rules[0].mode);
	}

	public function testEmptyConditionsArrayProducesAlwaysFiringRule():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping":{"methodChain":{"rules":['
				+ '{"type":"onePerLine","conditions":[]}'
				+ ']}}}'
		);
		Assert.equals(1, opts.methodChainWrap.rules.length);
		Assert.equals(0, opts.methodChainWrap.rules[0].conditions.length);
		Assert.equals(WrapMode.OnePerLine, opts.methodChainWrap.rules[0].mode);
	}

}
