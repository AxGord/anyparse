package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-callparam-nested-array-hug: under `callParameter.defaultWrap:
 * fillLineWithLeadingBreak`, a MULTI-arg call whose SOLE multi-line arg is a
 * `new X([…], …)` / `f([…])` — i.e. built AROUND an array literal that is the
 * arg's FIRST break — HUGS that arg onto the open-paren line (`f(new X([`),
 * breaks the array one-per-line, and keeps the sibling scalar args inline (the
 * leading ones before the arg, the trailing ones on the array-close line). The
 * generalisation of the sole-arg / arg-STARTS-with-`[` collection glue to a
 * bracket nested inside the arg's head, at ANY arg position.
 *
 * Negatives held: a nested call whose OWN args wrap with NO array, two array-
 * bearing args, and an opAdd chain whose array is reached past a soft break —
 * all still leading-break the outer call (no hug). A function-signature param
 * `x: Null<{…}>` is untouched (the recogniser is array-`[`-only, not `{`).
 */
@:nullSafety(Strict)
final class HxCallParamNestedArrayHugSliceTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testNestedArrayFirstArgScalarLastHugs(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tcontainer.addItem(new Row([\n\t\t\tnew Label("alphaLongText", fmtFunctionOne(), null, 30),\n\t\t\tnew Label("bravoLongText", fmtFunctionTwo(), null, 30)\n\t\t], someWidthValue, null), false);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testNestedArrayLastArgScalarFirstHugs(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tcontainer.addItem(false, new Row([\n\t\t\tnew Label("alphaLongText", fmtFunctionOne(), null, 30),\n\t\t\tnew Label("bravoLongText", fmtFunctionTwo(), null, 30)\n\t\t], someWidthValue, null));\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testNestedArraySoleInnerArgHugs(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tcontainer.addItem(new Row([\n\t\t\tnew Label("alpha", fmtOneFunctionCall(), null, 30),\n\t\t\tnew Label("bravo", fmtTwoFunctionCall(), null, 30)\n\t\t]), false);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testNestedArrayTailOverflowStillHugs(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tcontainer.addItem(new Row([\n\t\t\tnew Label("alphaLongText", fmtFunctionOne(), null, 30),\n\t\t\tnew Label("bravoLongText", fmtFunctionTwo(), null, 30)\n\t\t], someVeryLongWidthValueExpressionGoesHereToOverflow, anotherLongTrailingArgumentValueHere), false);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testDirectArrayArgStillHugs(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tcontainer.addItem([\n\t\t\tnew Label("alpha", fmtOneFunctionCall(), null, 30),\n\t\t\tnew Label("bravo", fmtTwoFunctionCall(), null, 30)\n\t\t], false);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testNestedCallNoArrayLeadingBreaks(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tcontainer.addItem(\n\t\t\tnew Row(longArgumentAlphaValue, longArgumentBravoValue, longArgumentCharlieValue, longArgumentDeltaValue, longEchoValue),\n\t\t\tfalse\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testTwoArrayBearingArgsLeadingBreak(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tcontainer.addItem(\n\t\t\tnew Row([new Label("alpha", fmtOneFunctionValue(), null, 30)], widthOne),\n\t\t\tnew Row([new Label("bravo", fmtTwoFunctionValue(), null, 30)], widthTwo)\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testChainOwnedArrayPastSoftBreakLeadingBreaks(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\treturn assert(\n\t\t\talphaCount == 0,\n\t\t\t\'Should not create items for the given additions, but created $${alphaCount}: \' + [for (m in moves) \'$${m.oldPath}\'].join(\', \')\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
