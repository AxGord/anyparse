package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/** A `#if` region of whole constructors in an enum body parses and round-trips. */
class HxEnumCtorConditionalTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	@:pin('control')
	@:killer('M-ENUM-CTOR-REGION-KW')
	public function testRegionBetweenCtors(): Void {
		assertFixed('enum E {\n\tA;\n\t#if foo\n\tB;\n\t#end\n\tC;\n}');
	}

	@:pin('control')
	@:killer('M-ENUM-CTOR-REGION-KW')
	public function testSameLineFixtureParsesAndIsIdempotent(): Void {
		final once: String = roundTrip('enum E { A; #if foo B; #end C; }');
		Assert.equals('enum E {\n\tA;\n\t#if foo B; #end\n\tC;\n}\n', once);
		Assert.equals(once, roundTrip(once));
	}

	@:pin('control')
	@:killer('M-ENUM-CTOR-REGION-KW')
	public function testDocCommentInsideRegion(): Void {
		assertFixed('enum E3 {\n\t#if foo\n\t/** d */\n\tA;\n\t#end\n\tB;\n}');
	}

	@:pin('control')
	@:killer('M-ENUM-CTOR-REGION-KW')
	public function testElseBranch(): Void {
		assertFixed('enum E {\n\t#if foo\n\tA;\n\t#else\n\tB(x:Int);\n\t#end\n}');
	}

	@:pin('control')
	@:killer('M-ENUM-CTOR-REGION-KW')
	public function testElseifBranch(): Void {
		assertFixed('enum E {\n\t#if foo\n\tA;\n\t#elseif bar\n\tB;\n\t#end\n}');
	}

	@:pin('control')
	@:killer('M-ENUM-CTOR-REGION-KW')
	public function testNestedRegion(): Void {
		assertFixed('enum E {\n\t#if foo\n\t#if bar\n\tA;\n\t#end\n\t#end\n\tB;\n}');
	}

	@:pin('guard')
	public function testEnumAbstractSharesMemberPath(): Void {
		assertFixed('enum abstract E(Int) {\n\t#if foo\n\tvar A = 1;\n\t#end\n\tvar B = 2;\n}');
	}

	private function assertFixed(source: String): Void {
		Assert.equals('$source\n', roundTrip(source));
	}

	private function roundTrip(source: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source));
	}

}
