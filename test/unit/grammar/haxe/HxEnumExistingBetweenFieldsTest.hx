package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `emptyLines.enumEmptyLines.existingBetweenFields` answers to enum bodies only: a class, an interface, an abstract,
 * an `enum abstract` and a typedef keep the source blank lines between their fields under it.
 */
@:nullSafety(Strict)
class HxEnumExistingBetweenFieldsTest extends Test {

	private static inline final REMOVE: String = '{"emptyLines":{"enumEmptyLines":{"betweenFields":0,"existingBetweenFields":"remove"}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-ENUM-EXISTING-LEAKS')
	public function testAClassKeepsItsBlankLinesUnderEnumRemove(): Void {
		final src: String = 'class C {\n\tvar a:Int;\n\n\tvar b:Int;\n\n\tfunction f():Void {}\n}';
		Assert.equals(src, write(src, REMOVE));
	}

	@:pin('control')
	@:killer('M-ENUM-EXISTING-DROPPED')
	public function testAnEnumCollapsesItsBlankLinesUnderEnumRemove(): Void {
		Assert.equals('enum E {\n\tA;\n\tB;\n}', write('enum E {\n\tA;\n\n\tB;\n}', REMOVE));
	}

	@:pin('guard')
	public function testOtherKindsKeepTheirBlankLinesUnderEnumRemove(): Void {
		final iface: String = 'interface I {\n\tfunction a():Void;\n\n\tfunction b():Void;\n}';
		Assert.equals(iface, write(iface, REMOVE));
		final abs: String = 'abstract A(Int) {\n\tvar a:Int;\n\n\tvar b:Int;\n}';
		Assert.equals(abs, write(abs, REMOVE));
		final enumAbs: String = 'enum abstract EA(Int) {\n\tvar A = 1;\n\n\tvar B = 2;\n}';
		Assert.equals(enumAbs, write(enumAbs, REMOVE));
		final ext: String = 'extern class X {\n\tvar a:Int;\n\n\tvar b:Int;\n}';
		Assert.equals(ext, write(ext, REMOVE));
		final typedefSrc: String = 'typedef T = {\n\tvar a:Int;\n\n\tvar b:Int;\n}';
		Assert.equals(typedefSrc, write(typedefSrc, REMOVE));
	}

	@:pin('control')
	@:killer('M-CLASS-EXISTING-DROPPED')
	public function testClassRemoveStillStripsAClassAndLeavesEnums(): Void {
		final cfg: String = '{"emptyLines":{"classEmptyLines":{"existingBetweenFields":"remove"}}}';
		Assert.equals('class C {\n\tvar a:Int;\n\tvar b:Int;\n}', write('class C {\n\tvar a:Int;\n\n\tvar b:Int;\n}', cfg));
		final en: String = 'enum E {\n\tA;\n\n\tB;\n}';
		Assert.equals(en, write(en, cfg));
	}

	private function write(src: String, json: String): String {
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
		return out.rtrim();
	}

}
