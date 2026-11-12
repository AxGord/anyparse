package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A short literal early on a line that overflows only through a LATER sibling keeps its flat shape: the overflowing
 * sibling breaks, not the literal whose own segment fits.
 */
@:nullSafety(Strict)
final class HxLaterSiblingOverflowTest extends Test {

	/** The Pony-shaped config of the comprehension fixture: cuddled open, NoWrap arrays, no objectLiteral rules. */
	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140,'
		+ '"comprehensionCuddledOpen":true,"mapWrap":{"defaultWrap":"onePerLine"},"anonType":{"defaultWrap":"onePerLine"},'
		+ '"arrayWrap":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"hasMultilineItems","value":1}],"type":"onePerLine"},'
		+ '{"conditions":[{"cond":"anyItemLength >= n","value":30}],"type":"onePerLine"}]}},'
		+ '"sameLine":{"comprehensionFor":"same"},"trailingCommas":{"arrayLiteralDefault":"yes"}}';

	private static final SOURCE: String = 'class M {\n\tfunction f() {\n'
		+ '\t\tvar y = [for (x in [for (y in ys) {a: y, b: 2}]) {alpha: x.aaaaaaaaaaaaaaaaaaaaaaa, beta: '
		+ "x.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, k: 'kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk'}];\n\t}\n}";
	private static final EXPECTED: String = 'class M {\n\tfunction f() {\n\t\tvar y = [\n\t\t\tfor (x in [for (y in ys) {a: y, b: 2}]) {\n'
		+ '\t\t\t\talpha: x.aaaaaaaaaaaaaaaaaaaaaaa,\n\t\t\t\tbeta: x.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n'
		+ "\t\t\t\tk: 'kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk'\n\t\t\t},\n\t\t];\n\t}\n}";

	public function new(): Void {
		super();
	}

	/** The iterable literal fits its own segment and stays flat; the body literal that overflows breaks. */
	@:pin('control')
	@:killer('M-REST-PROBE-CLOSE-RUN-OFF')
	public function testTheOverflowingLaterSiblingBreaksNotTheEarlyLiteral(): Void {
		Assert.equals(EXPECTED, HxWriteFixture.triviaWrite(SOURCE, CONFIG));
	}

	/** The first write is a fixed point. */
	@:pin('control')
	@:killer('M-REST-PROBE-CLOSE-RUN-OFF')
	public function testTheWriteIsAFixedPoint(): Void {
		Assert.equals(EXPECTED, HxWriteFixture.triviaWrite(EXPECTED, CONFIG));
	}

}
