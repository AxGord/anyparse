package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * An overwide method chain whose head is breakable (array literal, call, comprehension) breaks at its seams when the head
 * fits flat with the first link, instead of letting the head's own wrap take the line and gluing the tail to its closing bracket.
 */
@:nullSafety(Strict)
final class HxChainBreakableHeadSeamsTest extends Test {

	/** Tab indent, 140 columns; array and call cascades whose overflow answer wraps the brackets. */
	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,'
		+ '"methodChainCuddledLinks":true,"comprehensionCuddledOpen":true,"arrayWrap":{"defaultWrap":"ignore","rules":['
		+ '{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},'
		+ '{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},'
		+ '"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":['
		+ '{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},'
		+ '{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]}}}';

	private static final LITERAL_SRC: String = 'class A {\n\tfunction f() {\n\t\tfinal v = [alphaaaaaaaaaaaaaaaaaaaaaaaaa, '
		+ 'betaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa].concat(gammaaaaaaaaaaaaaaaaaaaaa).concat(deltaaaaaaaaaaaaaaaaaaaaaaaaa).concat(y);\n\t}\n}';
	private static final LITERAL_EXP: String = 'class A {\n\tfunction f() {\n\t\tfinal v = [alphaaaaaaaaaaaaaaaaaaaaaaaaa, '
		+ 'betaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa]\n\t\t\t.concat(gammaaaaaaaaaaaaaaaaaaaaa)\n'
		+ '\t\t\t.concat(deltaaaaaaaaaaaaaaaaaaaaaaaaa)\n\t\t\t.concat(y);\n\t}\n}';
	private static final CALL_SRC: String = 'class A {\n\tfunction f() {\n\t\tfinal w = makeList(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '
		+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb).length.toString().concat(cccccccccccccccccccccccccccccccccc).concat(ddddddddddd);\n\t}\n}';
	private static final CALL_EXP: String = 'class A {\n\tfunction f() {\n\t\tfinal w = makeList(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, '
		+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)\n\t\t\t.length.toString()\n'
		+ '\t\t\t.concat(cccccccccccccccccccccccccccccccccc)\n\t\t\t.concat(ddddddddddd);\n\t}\n}';
	private static final COMPREHENSION_SRC: String = 'class A {\n\tfunction f() {\n'
		+ '\t\tfinal u = [for (i in 0...countttttttttttttttttttttttttttttttt) i * '
		+ '2].length.toString().concat(cccccccccccccccccccccccccccccccccc).concat(ddddddddddd);\n\t}\n}';
	private static final COMPREHENSION_EXP: String = 'class A {\n\tfunction f() {\n\t\tfinal u = [for (i in 0...countttttttttttttttttttttttttttttttt) '
		+ 'i * 2]\n\t\t\t.length.toString()\n\t\t\t.concat(cccccccccccccccccccccccccccccccccc)\n\t\t\t.concat(ddddddddddd);\n\t}\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-CHAIN-BREAKABLE-HEAD-GLUED')
	public function testArrayLiteralHeadStaysFlatAndSeamsBreak(): Void {
		Assert.equals(LITERAL_EXP, write(LITERAL_SRC));
	}

	@:pin('control')
	@:killer('M-CHAIN-BREAKABLE-HEAD-GLUED')
	public function testCallHeadStaysFlatAndSeamsBreak(): Void {
		Assert.equals(CALL_EXP, write(CALL_SRC));
	}

	@:pin('control')
	@:killer('M-CHAIN-BREAKABLE-HEAD-GLUED')
	public function testComprehensionHeadStaysFlatAndSeamsBreak(): Void {
		Assert.equals(COMPREHENSION_EXP, write(COMPREHENSION_SRC));
	}

	private inline function write(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
