package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.format.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/**
 * Under `fit` a lone metadata is measured against the declaration's head, up to where its body or
 * initializer may break: a body that does not fit breaks first, and the metadata leaves the line only
 * when the head itself does not fit.
 */
class MetadataFitHeadTest extends Test {

	private static final CONFIG: String = '{"wrapping":{"maxLineLength":140},"indentation":{"character":"tab","tabWidth":4},'
		+ '"whitespace":{"typeHintColonPolicy":"after"},"lineEnds":{"metadataFunction":"fit","metadataVar":"fit"},'
		+ '"sameLine":{"functionBody":"fitLine"}}';

	/** An operator metadata stays on a head that fits; the body that does not fit takes the next line. */
	@:pin('control')
	@:killer('M-META-FIT-OPERATOR-COMPLEX')
	public function testAFittingHeadKeepsAnOperatorMetadata(): Void {
		Assert.equals(
			'class T {\n\t@:op(A + B) public static inline function add(a: Color, b: Color): Color\n'
			+ '\t\treturn fromARGBSave(a.a + b.a, a.r + b.r, a.g + b.g, a.b + b.b);\n}\n',
			fit(
				'class T {\n\t@:op(A + B) public static inline function add(a: Color, b: Color): Color '
				+ 'return fromARGBSave(a.a + b.a, a.r + b.r, a.g + b.g, a.b + b.b);\n}\n'
			)
		);
	}

	/** A var's metadata stays on a head that fits; the initializer that does not fit wraps. */
	@:pin('control')
	@:killer('M-META-FIT-HEAD-ENDS-AT-INITIALIZER')
	public function testAFittingVarHeadKeepsTheMetadata(): Void {
		Assert.equals(
			'class T {\n\t@:x public var aaaaaaaaaaaaaaaa: Array<String> = someFunctionCall(argumentNumberOne, argumentNumberTwo, '
			+ 'argumentNumberThree,\n\t\targumentFour);\n}\n',
			fit(
				'class T {\n\t@:x public var aaaaaaaaaaaaaaaa: Array<String> = someFunctionCall(argumentNumberOne, argumentNumberTwo, '
				+ 'argumentNumberThree, argumentFour);\n}\n'
			)
		);
	}

	/** An operator metadata on a head that does not fit takes a line of its own, written whole. */
	@:pin('control')
	@:killer('M-META-FIT-LONE-BREAKS-INSIDE')
	public function testAnOperatorMetadataOnAHeadThatDoesNotFitStaysAbove(): Void {
		final head: String = 'public static inline function addTheTwoColorsTogether(first: ColorWithAVeryLongTypeName, '
			+ 'second: ColorWithAVeryLongTypeName): Color';
		Assert.equals(
			'class T {\n\t@:op(A + B)\n\t$head\n\t\treturn first;\n}\n', fit('class T {\n\t@:op(A + B) $head return first;\n}\n')
		);
	}

	/** A prefix operator over a name is a simple argument too. */
	@:pin('control')
	@:killer('M-META-FIT-PREFIX-COMPLEX')
	public function testAPrefixOperatorArgumentIsSimple(): Void {
		Assert.equals(
			'class T {\n\t@:op(-A) public function neg(): T {}\n}\n', fit('class T {\n\t@:op(-A)\n\tpublic function neg(): T {}\n}\n')
		);
	}

	/** An operator over a call is complex: its metadata keeps a line of its own. */
	@:pin('control')
	@:killer('M-META-FIT-OPERANDS-UNREAD')
	public function testAnOperatorOverACallIsComplex(): Void {
		Assert.equals(
			'class T {\n\t@:a(f().x + 1)\n\tpublic function g(): T {}\n}\n',
			fit('class T {\n\t@:a(f().x + 1) public function g(): T {}\n}\n')
		);
	}

	/** A var typed without type parameters ends its head at `=` too: the call that does not fit after the metadata wraps. */
	@:pin('control')
	@:killer('M-META-FIT-HEAD-PLAIN-UNTAGGED')
	public function testAPlainTypedVarHeadKeepsTheMetadata(): Void {
		final call: String = 'someFunctionCall(argumentNumberOne, argumentNumberTwo, argumentNumberThree,';
		Assert.equals(
			'class T {\n\t@:x public var aaaaaaaaaaaaaaaa: Int = $call\n\t\targumentFourrrrrrrrrrrr);\n}\n',
			fit('class T {\n\t@:x public var aaaaaaaaaaaaaaaa: Int = $call argumentFourrrrrrrrrrrr);\n}\n')
		);
	}

	/** An untyped var ends its head at `=` as well. */
	@:pin('control')
	@:killer('M-META-FIT-HEAD-PLAIN-UNTAGGED')
	public function testAnUntypedVarHeadKeepsTheMetadata(): Void {
		final call: String = 'someFunctionCall(argumentNumberOne, argumentNumberTwo, argumentNumberThree,';
		Assert.equals(
			'class T {\n\t@:x public var aaaaaaaaaaaaaaaa = $call\n\t\targumentFourrrrrrrrrrrrrrrrr);\n}\n',
			fit('class T {\n\t@:x public var aaaaaaaaaaaaaaaa = $call argumentFourrrrrrrrrrrrrrrrr);\n}\n')
		);
	}

	/** A binary initializer that does not fit after the metadata breaks at its operator under a head that fits. */
	@:pin('control')
	@:killer('M-META-FIT-HEAD-PLAIN-UNTAGGED')
	public function testABinaryInitializerBreaksUnderAGluedHead(): Void {
		final lhs: String = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
		final rhs: String = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
		Assert.equals(
			'class T {\n\t@:x public static final someLongConstantName: Int = $lhs\n\t\t+ $rhs;\n}\n',
			fit('class T {\n\t@:x public static final someLongConstantName: Int = $lhs + $rhs;\n}\n')
		);
	}

	/**
	 * A call of a path over simple arguments is simple: it joins an expression, a block and a `return` bodied function.
	 */
	@:pin('control')
	@:killer('M-META-FIT-CALL-COMPLEX')
	public function testACallMetadataJoinsTheDeclarationLine(): Void {
		final src: String = 'class T {\n\t@:op(a()) public inline function d(): Void dispatchWithFlag(false);\n\n'
			+ '\t@:op(a()) public inline function e(): Void {\n\t\tdispatchWithFlag(false);\n\t}\n\n'
			+ '\t@:op(a.b(c, 1)) public inline function r(): Int return 1;\n}\n';
		Assert.equals(src, fit(src));
	}

	private static function fit(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(CONFIG));
	}

}
