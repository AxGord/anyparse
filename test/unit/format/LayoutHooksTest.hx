package unit.format;

import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.Renderer;
import anyparse.format.IndentChar;
import anyparse.format.MemberGap;
import anyparse.format.WriteOptions;
import anyparse.format.wrap.ClauseWrap;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.grammar.haxe.HaxeFormat;

/**
 * The functions a `listLayout` / `gapRule` flag names: each is a plain function over finished Docs, so it is
 * checked here without a grammar.
 */
@:nullSafety(Strict)
final class LayoutHooksTest extends Test {

	private static final HEAD: Doc = Doc.Text('class A');
	private static final EXTENDS: Doc = Doc.Text('extends B');
	private static final IMPLEMENTS: Doc = Doc.Text('implements C');
	private static final NO_RULES: WrapRules = { rules: [], defaultMode: WrapMode.NoWrap };

	public function testAClauseListWithoutARuleStaysOnTheHeadLine(): Void {
		Assert.equals('class A extends B implements C', render(ClauseWrap.layout([EXTENDS, IMPLEMENTS], 1, NO_RULES, 120)));
	}

	public function testASingleClauseBreaksUnderTheHeadOnlyWhenItOverflows(): Void {
		Assert.equals('class A extends B', render(ClauseWrap.layout([EXTENDS], 1, NO_RULES, 120)));
		Assert.equals('class A\n\textends B', render(ClauseWrap.layout([EXTENDS], 1, NO_RULES, 12), 12));
	}

	public function testAMatchedRuleBreaksTheClausesAndChargesItsIndent(): Void {
		final rules: WrapRules = {
			rules: [
				{
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 2 }],
					mode: WrapMode.OnePerLine,
					additionalIndent: 1
				}
			],
			defaultMode: WrapMode.NoWrap
		};
		Assert.equals('class A\n\textends B\n\timplements C', render(ClauseWrap.layout([EXTENDS, IMPLEMENTS], 1, rules, 120)));
		Assert.equals('class A extends B', render(ClauseWrap.layout([EXTENDS], 1, rules, 120)));
	}

	public function testAFillLineRuleKeepsTheFirstClauseOnTheHeadLineAndFillsTheRest(): Void {
		final rules: WrapRules = { rules: [], defaultMode: WrapMode.FillLine, defaultAdditionalIndent: 1 };
		final items: Array<Doc> = [
			Doc.Text('extends Bbbbbbbb'),
			Doc.Text('implements Cccccc'),
			Doc.Text('implements Dddddd')
		];
		Assert.equals(
			'class A extends Bbbbbbbb\n\timplements Cccccc implements Dddddd', render(ClauseWrap.layout(items, 1, rules, 40), 40)
		);
	}

	public function testARuleOnAMeasureTheClauseListDoesNotTakeNeverHolds(): Void {
		final rules: WrapRules = {
			rules: [
				{ conditions: [{ cond: WrapConditionType.TotalItemLengthLargerThan, value: 1 }], mode: WrapMode.OnePerLine }
			],
			defaultMode: WrapMode.NoWrap
		};
		Assert.equals('class A extends B implements C', render(ClauseWrap.layout([EXTENDS, IMPLEMENTS], 1, rules, 120)));
	}

	public function testAGapOpensTheKnobsCountOnlyAroundAMultilineSide(): Void {
		final opt: WriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final flat: Doc = Doc.Text('var a:Int;');
		final tall: Doc = Doc.Concat([Doc.Text('function f() {'), D.hardline(), Doc.Text('}')]);
		Assert.equals(0, MemberGap.aroundMultiline(flat, flat, 2, opt));
		Assert.equals(0, MemberGap.aroundMultiline(flat, null, 2, opt));
		Assert.equals(2, MemberGap.aroundMultiline(tall, flat, 2, opt));
		Assert.equals(2, MemberGap.aroundMultiline(flat, tall, 2, opt));
		Assert.equals(0, MemberGap.aroundMultiline(tall, tall, 0, opt));
	}

	private static function render(list: Doc, width: Int = 120): String {
		return Renderer.render(Doc.Concat([HEAD, list]), width, IndentChar.Tab, 1);
	}

}
