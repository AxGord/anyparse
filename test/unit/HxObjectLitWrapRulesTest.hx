package unit;

import utest.Assert;
import utest.Test;
import anyparse.core.Doc;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapList;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Slice ω-wraprules-objlit — per-construct wrap-rules cascade engine
 * driving the multi-line layout decision for `HxObjectLit.fields`.
 * Mirrors haxe-formatter's `WrapConfig.objectLiteral` cascade
 * (AxGord fork's `default-hxformat.json`):
 *   noWrap if itemCount <= 3 ∧ ¬exceeds
 *   else onePerLine if anyItem ≥ 30 / total ≥ 60 / itemCount ≥ 4 / exceeds
 * Default mode: `noWrap`.
 *
 * Test layout:
 *  - `WrapList.decide` direct unit tests confirm the cascade walks
 *    rules in order, AND-combines conditions, and returns
 *    `defaultMode` on miss. Format-neutral — no parser needed.
 *  - End-to-end tests run a Haxe object literal through the parser +
 *    writer and assert the resulting source matches the expected
 *    layout shape for the chosen mode. Default rules are inherited
 *    from `HaxeFormat.defaultObjectLiteralWrap`.
 *  - One regression test re-uses `HxObjectLitBracesOptionsTest`'s 2-
 *    field example (`{a: 1, b: 2}`) to confirm the wrap engine doesn't
 *    interfere with the orthogonal `objectLiteralBracesOpen` /
 *    `objectLiteralBracesClose` interior-spacing knobs — a 2-field
 *    object literal stays in `NoWrap` mode under default rules.
 */
@:nullSafety(Strict)
final class HxObjectLitWrapRulesTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultsExposed():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WrapMode.NoWrap, defaults.objectLiteralWrap.defaultMode);
		Assert.isTrue(defaults.objectLiteralWrap.rules.length >= 4, 'expected at least four rules in default cascade');
	}

	public function testDecideNoWrapForThreeShortItems():Void {
		final rules:WrapRules = HaxeFormat.defaultObjectLiteralWrap();
		Assert.equals(WrapMode.NoWrap, WrapList.decide(rules, 3, 5, 15, false));
	}

	public function testDecideOnePerLineForFourItems():Void {
		final rules:WrapRules = HaxeFormat.defaultObjectLiteralWrap();
		Assert.equals(WrapMode.OnePerLine, WrapList.decide(rules, 4, 5, 20, false));
	}

	public function testDecideNoWrapWinsOverLongAnyItemForFewItems():Void {
		// The leading `noWrap if itemCount<=3 ∧ ¬exceeds` rule wins
		// for low-count lists even when individual items are long. The
		// `AnyItemLengthLargerThan` rule only triggers once the count
		// rule's gate releases (count > 3 or exceeds=true).
		final rules:WrapRules = HaxeFormat.defaultObjectLiteralWrap();
		Assert.equals(WrapMode.NoWrap, WrapList.decide(rules, 2, 35, 50, false));
	}

	public function testDecideOnePerLineForLongAnyItemWhenExceeds():Void {
		// Same low-count list with `exceeds=true` — the cascade's
		// leading `itemCount<=3 ∧ ¬exceeds` rule fails on the second
		// condition; rule 2 (`anyItem >= 30`) takes over and selects
		// `OnePerLine`. Drives the `Group(IfBreak)` shape on the writer
		// side: when the source line overflows, the Group breaks and
		// the cascade's `exceeds=true` arm fires.
		final rules:WrapRules = HaxeFormat.defaultObjectLiteralWrap();
		Assert.equals(WrapMode.OnePerLine, WrapList.decide(rules, 2, 35, 50, true));
	}

	public function testDecideOnePerLineForLargeTotalWhenExceeds():Void {
		// Same gating logic — `total >= 60` triggers only after the
		// leading `noWrap` rule fails on `exceeds=true`. Real-world
		// drivers of this branch are 3-field literals whose flat shape
		// pushes the enclosing line past `lineWidth` even though the
		// per-item count is below 4.
		final rules:WrapRules = HaxeFormat.defaultObjectLiteralWrap();
		Assert.equals(WrapMode.OnePerLine, WrapList.decide(rules, 3, 25, 65, true));
	}

	public function testDecideOnePerLineWhenExceedsLine():Void {
		final rules:WrapRules = HaxeFormat.defaultObjectLiteralWrap();
		Assert.equals(WrapMode.OnePerLine, WrapList.decide(rules, 1, 5, 5, true));
	}

	public function testDecideRespectsCustomDefaultMode():Void {
		final rules:WrapRules = {
			rules: [],
			defaultMode: WrapMode.FillLine,
		};
		Assert.equals(WrapMode.FillLine, WrapList.decide(rules, 99, 99, 999, true));
	}

	public function testDecideFirstMatchWins():Void {
		final rules:WrapRules = {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 4}],
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{cond: WrapConditionType.ItemCountLargerThan, value: 4}],
				},
			],
			defaultMode: WrapMode.NoWrap,
		};
		Assert.equals(WrapMode.FillLine, WrapList.decide(rules, 5, 5, 25, false));
	}

	public function testFlatLengthCountsTextAndFlatLine():Void {
		final doc:Doc = Concat([Text('abc'), Line(' '), Text('xyz')]);
		Assert.equals(7, WrapList.flatLength(doc));
	}

	public function testFlatLengthRefusesHardline():Void {
		final doc:Doc = Concat([Text('abc'), Line('\n'), Text('xyz')]);
		Assert.equals(-1, WrapList.flatLength(doc));
	}

	public function testTwoFieldObjectStaysFlat():Void {
		final out:String = writeWith('class Foo { static var x = {a: 1, b: 2}; }');
		Assert.isTrue(out.indexOf('{a: 1, b: 2}') != -1, 'expected flat `{a: 1, b: 2}` in: <$out>');
	}

	public function testFourFieldObjectWrapsOnePerLine():Void {
		final src:String = 'class Foo { static var x = {one: 1, two: 2, three: 3, four: 4}; }';
		final out:String = writeWith(src);
		Assert.isTrue(out.indexOf('{\n') != -1, 'expected wrap after `{` in: <$out>');
		Assert.isTrue(out.indexOf('one: 1,\n') != -1, 'expected `one: 1,` on its own line in: <$out>');
		Assert.isTrue(out.indexOf('four: 4\n') != -1, 'expected `four: 4` not followed by trailing comma in: <$out>');
	}

	public function testThreeFieldObjectStaysFlatByCount():Void {
		final src:String = 'class Foo { static var x = {a: 1, b: 2, c: 3}; }';
		final out:String = writeWith(src);
		Assert.isTrue(out.indexOf('{a: 1, b: 2, c: 3}') != -1, 'expected flat `{a: 1, b: 2, c: 3}` in: <$out>');
	}

	public function testThreeFieldOverflowingLineWraps():Void {
		// Three short-name fields whose VALUES push the line past
		// `lineWidth=160` (default). The cascade's
		// `Group(IfBreak(OnePerLine, NoWrap))` shape lets the renderer
		// measure the NoWrap layout; on overflow the Group breaks and
		// the IfBreak picks `OnePerLine` per the cascade's
		// `exceeds=true` arm (rule 2: `anyItem >= 30`).
		final src:String = 'class Foo { static var x = {alpha: "first really really really really really long value here", beta: "second really really really really really long value here", gamma: "third really really really really really long value here"}; }';
		final out:String = writeWith(src);
		Assert.isTrue(out.indexOf('{\n') != -1, 'expected wrap when line overflows in: <$out>');
	}

	public function testCustomNoWrapDefaultDisablesEngine():Void {
		final src:String = 'class Foo { static var x = {one: 1, two: 2, three: 3, four: 4, five: 5}; }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.objectLiteralWrap = {rules: [], defaultMode: WrapMode.NoWrap};
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('{one: 1, two: 2, three: 3, four: 4, five: 5}') != -1, 'expected forced flat layout under empty rule set: <$out>');
	}

	public function testEmptyObjectLitStaysFlat():Void {
		final out:String = writeWith('class Foo { static var x = {}; }');
		Assert.isTrue(out.indexOf('{}') != -1, 'expected empty `{}` flat in: <$out>');
	}

	private inline function writeWith(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}
}
