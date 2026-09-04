package unit.format;

import anyparse.format.DirectiveCondition;
import anyparse.format.OperatorSpacing;
import unit.grammar.haxe.HxWriteFixture;
import utest.Assert;
import utest.Test;

/**
 * `whitespace.conditionalCompilationBinop` - operator spacing inside a `#if` / `#elseif`
 * CONDITION, which the grammar carries as one verbatim text terminal rather than as an
 * expression tree, so `whitespace.binopPolicy` (which acts on operator NODES) has never
 * reached it and the authored spelling survived byte for byte.
 *
 * The user asked for it (2026-09-03): `#if (js||flash)` should read `#if (js || flash)`.
 * The knob is a BOOL, not a policy of its own: the direction comes from the config's
 * `binopPolicy`, so the condition's `&&` / `||` cannot drift from the code's.
 *
 * ⚠️ THE REGRESSION THIS CLASS EXISTS FOR: the `#if` condition field carries its own
 * `@:fmt(sharpCondParensInside(…))`, whose handler emits the condition text ITSELF and so never
 * runs the terminal's `@:writeNormalize`. The first implementation therefore respaced `#elseif`
 * and left `#if` alone - and BOTH of Pony's two tight sites are `#if`, so the feature would have
 * moved nothing on the tree it was written for. `testTheIfHeadIsNormalisedToo` is the pin; a
 * fix that only reaches `#elseif` fails it.
 */
@:nullSafety(Strict)
class DirectiveConditionSpacingTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final KEEP: String = '$BASE}';
	private static final AROUND: String = '$BASE, "whitespace": {"binopPolicy": "around", "conditionalCompilationBinop": true}}';
	private static final NONE: String = '$BASE, "whitespace": {"binopPolicy": "none", "conditionalCompilationBinop": true}}';

	public function testTheIfHeadIsNormalisedToo(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('#if (js||flash)\n\t\tp();\n\t\t#end'), AROUND);
		Assert.isTrue(out.indexOf('#if (js || flash)') != -1, 'the `#if` head must be respaced too in: <$out>');
	}

	public function testTheElseifHeadIsNormalised(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('#if (neko)\n\t\tp();\n\t\t#elseif (js&&sys)\n\t\tq();\n\t\t#end'), AROUND);
		Assert.isTrue(out.indexOf('#elseif (js && sys)') != -1, 'the `#elseif` head must be respaced in: <$out>');
	}

	public function testKeepIsTheDefaultAndMovesNothing(): Void {
		final src: String = wrap('#if (js||flash)\n\t\tp();\n\t\t#end');
		Assert.equals(src, HxWriteFixture.triviaWrite(src, KEEP));
	}

	public function testAlreadySpacedIsLeftAlone(): Void {
		final src: String = wrap('#if (js || flash)\n\t\tp();\n\t\t#end');
		Assert.equals(src, HxWriteFixture.triviaWrite(src, AROUND));
	}

	public function testNoneTightensInstead(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('#if (js || flash)\n\t\tp();\n\t\t#end'), NONE);
		Assert.isTrue(out.indexOf('#if (js||flash)') != -1, 'the `none` direction must tighten in: <$out>');
	}

	// -------- the transform's own refusals, unit-level --------

	public function testAnOperatorInsideAStringLiteralIsNeverTouched(): Void {
		Assert.equals('(a == \'||x\')', DirectiveCondition.spaceOperators('(a == \'||x\')', OperatorSpacing.Around));
		Assert.equals('(a == "x&&y")', DirectiveCondition.spaceOperators('(a == "x&&y")', OperatorSpacing.Around));
	}

	public function testAUnaryBangIsNotAnOperatorHere(): Void {
		Assert.equals('(!js)', DirectiveCondition.spaceOperators('(!js)', OperatorSpacing.Around));
		Assert.equals('(!js || flash)', DirectiveCondition.spaceOperators('(!js||flash)', OperatorSpacing.Around));
	}

	public function testAMultiLineConditionKeepsItsLayout(): Void {
		final text: String = '(js\n\t|| flash)';
		Assert.equals(text, DirectiveCondition.spaceOperators(text, OperatorSpacing.None));
	}

	public function testKeepReturnsTheTextUnchanged(): Void {
		Assert.equals('(js||flash)', DirectiveCondition.spaceOperators('(js||flash)', OperatorSpacing.Keep));
	}

	public function testNestedParensAreCopiedThrough(): Void {
		Assert.equals(
			'(neko || (cpp && !cppia) || flash)', DirectiveCondition.spaceOperators('(neko||(cpp&&!cppia)||flash)', OperatorSpacing.Around)
		);
	}

	public function testTheRewriteIsIdempotent(): Void {
		final once: String = DirectiveCondition.spaceOperators('(js||flash&&neko)', OperatorSpacing.Around);
		Assert.equals(once, DirectiveCondition.spaceOperators(once, OperatorSpacing.Around));
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

}
