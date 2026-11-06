package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * `<kind>EmptyLines.afterFieldsWithDocComments` for an enum, a typedef and an `enum abstract` body: the blank line
 * after a doc-commented member. `none` packs the member after a doc while the before-doc blank stays; an absent key
 * keeps each kind's layout from before the key existed.
 */
@:nullSafety(Strict)
class HxTypeAfterDocEmptyLinesTest extends Test {

	private static inline final NONE: String = '{"emptyLines":{'
		+ '"enumEmptyLines":{"afterFieldsWithDocComments":"none"},'
		+ '"typedefEmptyLines":{"afterFieldsWithDocComments":"none"},'
		+ '"enumAbstractEmptyLines":{"afterFieldsWithDocComments":"none"}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-AFTER-DOC-OWN-KNOB-UNREAD')
	public function testANoneEnumPacksTheCtorAfterADocMiddleCtor(): Void {
		Assert.equals('enum E {\n\tA;\n\n\t/** doc */\n\tB;\n\tC;\n}\n', write('enum E {\n\tA;\n\t/** doc */\n\tB;\n\n\tC;\n}\n', NONE));
		Assert.equals('enum P {\n\tA;\n\tB;\n}\n', write('enum P {\n\tA;\n\tB;\n}\n', NONE));
	}

	@:pin('control')
	@:killer('M-AFTER-DOC-OWN-KNOB-UNREAD')
	public function testAOneEnumTakesABlankAfterADocCtor(): Void {
		final json: String = '{"emptyLines":{"enumEmptyLines":{"afterFieldsWithDocComments":"one"}}}';
		Assert.equals('enum E {\n\t/** doc */\n\tB;\n\n\tC;\n}\n', write('enum E {\n\t/** doc */\n\tB;\n\tC;\n}\n', json));
	}

	@:pin('control')
	@:killer('M-TYPEDEF-AFTER-DOC-OFF')
	public function testANoneTypedefPacksTheFieldAfterADoc(): Void {
		Assert.equals(
			'typedef T = {\n\tvar a:Int;\n\n\t/** doc */\n\tvar b:Int;\n\tvar c:Int;\n}\n',
			write('typedef T = {\n\tvar a:Int;\n\t/** doc */\n\tvar b:Int;\n\n\tvar c:Int;\n}\n', NONE)
		);
	}

	@:pin('control')
	@:killer('M-AFTER-DOC-FLAG-IGNORED')
	public function testAnAnonOutsideATypedefIgnoresTheTypedefKey(): Void {
		final src: String = 'class V {\n\tvar v:{\n\t\t/** doc */\n\t\tvar b:Int;\n\n\t\tvar c:Int;\n\t};\n}\n';
		Assert.equals(src, write(src, NONE));
	}

	@:pin('control')
	@:killer('M-AFTER-DOC-ALT-UNREAD')
	public function testANoneEnumAbstractPacksTheMemberAfterADoc(): Void {
		Assert.equals(
			'enum abstract X(Int) {\n\tvar A = 1;\n\n\t/** doc */\n\tvar B = 2;\n\tvar C = 3;\n}\n',
			write('enum abstract X(Int) {\n\tvar A = 1;\n\t/** doc */\n\tvar B = 2;\n\n\tvar C = 3;\n}\n', NONE)
		);
	}

	@:pin('control')
	@:killer('M-AFTER-DOC-OWN-KNOB-UNREAD')
	public function testAnEnumAbstractWithoutItsKeyReadsTheGlobalKey(): Void {
		final json: String = '{"emptyLines":{"afterFieldsWithDocComments":"none"}}';
		Assert.equals(
			'enum abstract X(Int) {\n\t/** doc */\n\tvar B = 2;\n\tvar C = 3;\n}\n',
			write('enum abstract X(Int) {\n\t/** doc */\n\tvar B = 2;\n\n\tvar C = 3;\n}\n', json)
		);
	}

	@:pin('control')
	@:killer('M-AFTER-DOC-IGNORE-FALLBACK')
	public function testAbsentKeysKeepEachKindsLayout(): Void {
		Assert.equals('enum E {\n\t/** doc */\n\tB;\n\tC;\n}\n', write('enum E {\n\t/** doc */\n\tB;\n\tC;\n}\n', '{}'));
		Assert.equals(
			'typedef T = {\n\t/** doc */\n\tvar b:Int;\n\tvar c:Int;\n}\n',
			write('typedef T = {\n\t/** doc */\n\tvar b:Int;\n\tvar c:Int;\n}\n', '{}')
		);
		Assert.equals(
			'enum abstract X(Int) {\n\t/** doc */\n\tvar B = 2;\n\n\tvar C = 3;\n}\n',
			write('enum abstract X(Int) {\n\t/** doc */\n\tvar B = 2;\n\tvar C = 3;\n}\n', '{}')
		);
	}

	/** The per-kind keys name no class knob and no cut routes a class body to one: the class keeps the global key. */
	@:pin('guard') // noqa: guard-pin-arm-reach
	public function testAClassIsUntouched(): Void {
		final src: String = 'class C {\n\tvar x:Int;\n\n\t/** doc */\n\tvar y:Int;\n\n\tvar z:Int;\n}\n';
		Assert.equals(src, write(src, NONE));
	}

	private function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
