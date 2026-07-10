package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-cond-plaincall-open: a condition whose `&&`/`||` chain has a PLAIN-CALL
 * (non-arrow-lambda) overflow-absorbing operand leading-breaks the WHOLE
 * condition once the full header line exceeds `maxLineLength`, instead of
 * keeping the chain on the head line and wrapping the innermost call (which
 * dangles a trailing `.tail()) {`).
 *
 * The keep-flat glue probe (`IfNaturalFirstLineFitsOpenDelim`) measures only
 * the natural FIRST line, so it wrongly glues once the inner call leading-
 * breaks and that first line ends short at the call's open delim. A chain
 * with no arrow-lambda absorber (`->` absent) is therefore routed through
 * the `IfLineExceeds(lineWidth + 1)` probe — `col + (cond)` plus the
 * rest-of-stack lookahead whose BodyGroup arm counts a cuddled block body's
 * ` {` prefix and aborts at the body's own hardline. So a header exactly ONE
 * column past the limit opens (its `{` was the missing column — fork parity,
 * the fork measures the FULL physical line on a strict `>`), a header ON the
 * limit stays flat, and the else-if tail past the body hardline stays
 * invisible to the probe (see the else-if guard below).
 */
@:nullSafety(Strict)
final class HxCondPlainCallLeadingBreakSliceTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testPlainCallOverflowLeadingBreaksCondition(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfunction g() {\n\t\t\tif (\n\t\t\t\treceiverTimestampForItem != null\n\t\t\t\t&& receiverTimestampForItem.getTime() < DateHelper.delta(DateHelper.now(), DateHelper.minutes(10)).getTime()\n\t\t\t) {\n\t\t\t\thandleItem();\n\t\t\t}\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testShortElseIfChainStaysFlat(): Void {
		final src: String = 'class C {\n\tfunction f(source:String):Bool {\n\t\tvar depth = 0;\n\t\tvar quote = 0;\n\t\tvar i = 0;\n\t\twhile (i < source.length) {\n\t\t\tfinal ch = source.charCodeAt(i);\n\t\t\tif (quote != 0) {\n\t\t\t\tif (ch == 92)\n\t\t\t\t\ti++;\n\t\t\t} else if (ch == 40 || ch == 91 || ch == 123) {\n\t\t\t\tdepth++;\n\t\t\t} else if (ch == 41 || ch == 93 || ch == 125) {\n\t\t\t\tdepth--;\n\t\t\t}\n\t\t\ti++;\n\t\t}\n\t\treturn false;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testFittingPlainCallChainStaysFlat(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (itemValue != null && itemValue.getTime() < Clock.threshold()) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}


	public function testCuddledBraceOneColumnPastLimitOpensCondition(): Void {
		// Header line = 141 columns at tab=4 — the trailing ` {` supplies the
		// 141st column, so the condition must open (fork parity: the fork
		// measures the FULL physical line including the cuddled brace).
		final glued: String = 'class C {\n\tfunction f() {\n\t\tif (_aaaaBbbb1 && !_cccccc && _ddddEeeee1 == null && fffffGggggHhhhh12 == 0 && !iiiiJjjj.startsWith(abc) && kkkkLlll.type != MMMMM) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		final opened: String = 'class C {\n\tfunction f() {\n\t\tif (\n\t\t\t_aaaaBbbb1 && !_cccccc && _ddddEeeee1 == null && fffffGggggHhhhh12 == 0 && !iiiiJjjj.startsWith(abc) && kkkkLlll.type != MMMMM\n\t\t) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(opened, triviaWrite(glued));
		Assert.equals(opened, triviaWrite(opened));
	}


	public function testHeaderExactlyOnLimitStaysFlat(): Void {
		// Header line = exactly 140 columns — ON the limit is not past it
		// (fork opens on a strict `>`), the condition stays glued.
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (_aaaaBbbb1 && !_ccccc && _ddddEeeee1 == null && fffffGggggHhhhh12 == 0 && !iiiiJjjj.startsWith(abc) && kkkkLlll.type != MMMMM) {\n\t\t\thandleItem();\n\t\t}\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

}
