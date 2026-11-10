package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * Under `objectLiteralBraces.openingPolicy: "after"` with `arrowBodyOpenPad` off, only the object
 * literal whose `{` follows the `->` token drops its open pad. A literal written after any other
 * token of the arrow body (a ternary arm, an infix or chain right operand, a prefix or keyword
 * operand, a value-`if` branch, a metadata target) keeps both pads.
 */
@:nullSafety(Strict)
final class HxObjectLitArrowBodyNonLeadingPadTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140}, "whitespace": {"bracesConfig": {"objectLiteralBraces": {'
		+ '"openingPolicy": "after", "closingPolicy": "before"}}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-TERNARY-THEN')
	public function testTernaryThenArmKeepsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> e.ok ? { name: e.n, y: e.z } : null);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-TERNARY-ELSE')
	public function testTernaryElseArmKeepsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> e.ok ? null : { name: e.n, y: e.z });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-TERNARY-THEN')
	public function testTernaryBothArmsKeepOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> e.ok ? { name: e.n } : { name: 1 });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-CHAIN-LEAF')
	public function testNullCoalRightOperandKeepsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> e.a ?? { name: 1 });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-INFIX-RIGHT')
	public function testCompareRightOperandKeepsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> e.a == { name: 1 });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-PREFIX')
	public function testPrefixOperandKeepsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> !{ name: 1 }.ok);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-CLEAR-NONE')
	public function testValueIfBranchesKeepOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> if (e.ok) { name: 1 } else { name: 2 });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-KW-OPERAND')
	public function testCastOperandKeepsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> cast { name: 1 });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** The metadata target is a later field of its struct, so its literal follows the metadata, not `->`. */
	@:pin('control')
	@:killer('M-ARROW-LEAD-FIELD-AFTER-TOKEN')
	public function testMetadataTargetKeepsOpenPad(): Void {
		final out: String = triviaWrite('class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> @:m {name: 1 });\n\t}\n}');
		Assert.isTrue(out.indexOf('{ name: 1 }') != -1, 'expected `{ name: 1 }` in: <$out>');
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-CLEAR-NONE')
	public function testUnpaddedTernaryArmGainsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> e.ok ? {name: e.n, y: e.z } : null);\n\t}\n}';
		final expected: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> e.ok ? { name: e.n, y: e.z } : null);\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	/** A keyword-less ctor wrapping the literal passes the lead through: the `{` still follows `->`. */
	@:pin('control')
	@:killer('M-ARROW-LEAD-KW-ALWAYS')
	public function testLeadingLiteralStillDropsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> {name: e.n, y: e.z });\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	@:pin('control')
	@:killer('M-ARROW-LEAD-KW-ALWAYS')
	public function testLeadingLiteralOfAChainDropsOpenPad(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tfinal a = xs.map(e -> {name: 1 }.ok ? { name: 2 } : null);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, HxWriteFixture.listsKeepSource(CONFIG));
	}

}
