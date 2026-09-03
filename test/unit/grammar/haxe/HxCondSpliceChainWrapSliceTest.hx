package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A `#if … #end` token-splice operand inside an over-`maxLineLength` opAddSub
 * chain (`fillLine` wrap).
 *
 * ORIGINAL SUBJECT, and what replaced it. The region used to be
 * `HxCondSpliceRaw`'s verbatim multi-line `Text`, so the only layout the
 * writer could give it was the source's own: the test asked that the raw's
 * FIRST line pack onto the current fill line (rather than the whole operand
 * breaking off for its full flat width) and that the tail after `#end`
 * co-indent with the enclosing chain instead of compounding a second level.
 * Both still hold, but they are no longer decided by a verbatim byte run —
 * `HxCondSpliceOpExpr` carries `@:fmt(fillParts)`, so the region has a layout
 * policy of its own and the source's internal line breaks no longer reach the
 * output at all. What the two cases below pin is therefore the stronger
 * property: the canonical form is a fixed point AND the broken form reflows
 * to it, byte for byte.
 *
 * THE TAIL IS GLUED, AND OVER THE LIMIT, ON PURPOSE — this is
 * `CollapsePass`'s `unwrapAddOps` (fork parity: strip `+`/`-` line ends
 * inside a wrapped region), which collapses an inner add-chain that sits
 * inside a broken outer one. It fires here because the region no longer
 * carries a real hardline for `Renderer.embeddedLineWidths` to find. The
 * previous expectation had the tail wrapped, and that wrap was an artifact of
 * the source's own newline: the same construct written on one line already
 * glued the tail — over the limit — on the pre-slice writer. Measured over
 * 1665 real modules, the over-140 line count is 866 before and 866 after, so
 * nothing in the corpus moved; the cost is recorded here rather than hidden.
 */
@:nullSafety(Strict)
final class HxCondSpliceChainWrapSliceTest extends Test {

	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},'
		+ '"wrapping":{"maxLineLength":140,"opAddSubChain":{"defaultWrap":"noWrap",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]}}}';
	private static final CANONICAL: String = 'class C {\n\tpublic function render():String {\n'
		+ '\t\treturn "AlphaObject" + "nl" + "{" + head() + "  aa: " + aa + "nl" + "  bbbbb: " + bbbbb + "nl" + "  ccccccc: " + ccccccc + '
		+ '"nl"\n\t\t\t+ "  ddddddddd: " + ddddddddd + "nl"\n\t\t\t+ #if flag "  eeeeeeeeee: " + eeeeeeeeee + "nl" + "  ffffffffffffff: " '
		+ '+ ffffffffffffff + "nl" + #end\n\t\t\t"  gggggggggggg: " + wrapp(gggggggggggg) + "nl" + "  hhhhhhh: " + hhhhhhh + "nl" + "  '
		+ 'iiiiiiii: " + iiiiiiii + "nl" + "  jjjjjjjjjjjjjjjjjj: " + jjjjjjjjjjjjjjjjjj + "nl" + "}";\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * The canonical form is a writer fixed point: the `#if` operand run packs
	 * onto one line up to and including `#end`, and the tail after it lands at
	 * the enclosing chain's continuation indent — one level, not two.
	 */
	public function testCondSpliceOperandPacksFirstLineAndTailCoIndents(): Void {
		Assert.equals(CANONICAL, triviaWrite(CANONICAL));
	}

	/**
	 * The shape the author actually wrote — the operator run split across two
	 * lines mid-term (`… + ffffffffffffff` / `+ "nl" + #end`) and the tail
	 * continuation one indent level too deep — reflows to the canonical form.
	 * Before `@:fmt(fillParts)` this source WAS its own fixed point, which is
	 * the defect: two legal spellings of one tree produced two outputs.
	 */
	public function testCondSpliceChainReflowsBrokenForm(): Void {
		final broken: String = 'class C {\n\tpublic function render():String {\n\t\treturn "AlphaObject" + "nl" + "{" + head() '
			+ '+ "  aa: " + aa + "nl" + "  bbbbb: " + bbbbb + "nl" + "  ccccccc: " + ccccccc + "nl"\n'
			+ '\t\t\t+ "  ddddddddd: " + ddddddddd + "nl" + #if flag "  eeeeeeeeee: " + eeeeeeeeee + "nl" + "  ffffffffffffff: " + '
			+ 'ffffffffffffff\n\t\t\t+ "nl" + #end\n\t\t\t"  gggggggggggg: " + wrapp(gggggggggggg) + "nl" + "  hhhhhhh: " + hhhhhhh + "nl" '
			+ '+ "  iiiiiiii: " + iiiiiiii + "nl"\n\t\t\t+ "  jjjjjjjjjjjjjjjjjj: " + jjjjjjjjjjjjjjjjjj + "nl" + "}";\n\t}\n}';
		Assert.equals(CANONICAL, triviaWrite(broken));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
