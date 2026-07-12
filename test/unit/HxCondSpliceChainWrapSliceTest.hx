package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * A `#if … #end` token-splice operand inside an over-`maxLineLength` opAddSub
 * chain (`fillLine` wrap). The splice `raw` is a verbatim multi-line `Text`,
 * so the writer must:
 *
 *  - pack the splice operand's FIRST line onto the current fill line when it
 *    fits (the trailing lines break via the raw's own embedded newline)
 *    instead of breaking the whole operand onto its own line for its full flat
 *    width; and
 *  - co-indent the continuation tail (the operand chain after `#end`) with the
 *    ENCLOSING chain rather than compounding a second indent level.
 *
 * Fork-parity: haxe-formatter re-flows both. Fails on the un-fixed writer.
 */
@:nullSafety(Strict)
final class HxCondSpliceChainWrapSliceTest extends Test {

	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]}}}';

	public function new(): Void {
		super();
	}

	/**
	 * The canonical form is a writer fixed-point: the splice operand's first
	 * line stays packed on the chain line and the post-`#end` tail co-indents
	 * with the enclosing chain. The un-fixed writer breaks before the `#if`
	 * operand and over-indents the tail continuation by one level.
	 */
	public function testCondSpliceOperandPacksFirstLineAndTailCoIndents(): Void {
		final src: String = 'class C {\n\tpublic function render():String {\n\t\treturn "AlphaObject" + "nl" + "{" + head() + "  aa: " + aa + "nl" + "  bbbbb: " + bbbbb + "nl" + "  ccccccc: " + ccccccc + "nl"\n\t\t\t+ "  ddddddddd: " + ddddddddd + "nl" + #if flag "  eeeeeeeeee: " + eeeeeeeeee + "nl" + "  ffffffffffffff: " + ffffffffffffff\n\t\t\t+ "nl" + #end\n\t\t\t"  gggggggggggg: " + wrapp(gggggggggggg) + "nl" + "  hhhhhhh: " + hhhhhhh + "nl" + "  iiiiiiii: " + iiiiiiii + "nl"\n\t\t\t+ "  jjjjjjjjjjjjjjjjjj: " + jjjjjjjjjjjjjjjjjj + "nl" + "}";\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * The broken shape (splice operand on its own line, tail continuation one
	 * indent level too deep) re-flows to the canonical form.
	 */
	public function testCondSpliceChainReflowsBrokenForm(): Void {
		final canonical: String = 'class C {\n\tpublic function render():String {\n\t\treturn "AlphaObject" + "nl" + "{" + head() + "  aa: " + aa + "nl" + "  bbbbb: " + bbbbb + "nl" + "  ccccccc: " + ccccccc + "nl"\n\t\t\t+ "  ddddddddd: " + ddddddddd + "nl" + #if flag "  eeeeeeeeee: " + eeeeeeeeee + "nl" + "  ffffffffffffff: " + ffffffffffffff\n\t\t\t+ "nl" + #end\n\t\t\t"  gggggggggggg: " + wrapp(gggggggggggg) + "nl" + "  hhhhhhh: " + hhhhhhh + "nl" + "  iiiiiiii: " + iiiiiiii + "nl"\n\t\t\t+ "  jjjjjjjjjjjjjjjjjj: " + jjjjjjjjjjjjjjjjjj + "nl" + "}";\n\t}\n}';
		final broken: String = 'class C {\n\tpublic function render():String {\n\t\treturn "AlphaObject" + "nl" + "{" + head() + "  aa: " + aa + "nl" + "  bbbbb: " + bbbbb + "nl" + "  ccccccc: " + ccccccc + "nl"\n\t\t\t+ "  ddddddddd: " + ddddddddd + "nl"\n\t\t\t+ #if flag "  eeeeeeeeee: " + eeeeeeeeee + "nl" + "  ffffffffffffff: " + ffffffffffffff\n\t\t\t+ "nl" + #end\n\t\t\t"  gggggggggggg: " + wrapp(gggggggggggg) + "nl" + "  hhhhhhh: " + hhhhhhh + "nl" + "  iiiiiiii: " + iiiiiiii + "nl"\n\t\t\t\t+ "  jjjjjjjjjjjjjjjjjj: " + jjjjjjjjjjjjjjjjjj + "nl" + "}";\n\t}\n}';
		Assert.equals(canonical, triviaWrite(broken));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
