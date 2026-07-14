package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.EncapsulateField;
import anyparse.query.RefactorSupport.EditResult;

/**
 * `EncapsulateField.encapsulate` — turn a stored var field into an
 * `@:isVar` property with get / set accessors. Each test drives the PURE
 * op on an in-memory source (with `reformat` so the raw string need not be
 * canonical); `Ok` results are re-parsed, refusals assert `Err`.
 */
class EncapsulateFieldSliceTest extends Test {

	/** A plain field becomes a get/set property with accessors. */
	public function testBasicEncapsulate(): Void {
		final src: String = 'package pkg;\n\nclass Model {\n\tpublic var count:Int = 0;\n\tpublic function new() {}\n}';
		final text: String = okEncap(src, 'Model', 'count');
		Assert.isTrue(StringTools.contains(text, '@:isVar public var count(get, set):Int'), 'field becomes a property');
		Assert.isTrue(StringTools.contains(text, 'function get_count():Int'), 'getter added');
		Assert.isTrue(StringTools.contains(text, 'function set_count(value:Int):Int'), 'setter added');
		Assert.isTrue(StringTools.contains(text, 'return count = value'), 'setter assigns the field');
	}

	/** A field literally named `value` gets a non-colliding setter parameter. */
	public function testParamNoCollision(): Void {
		final src: String = 'package pkg;\n\nclass Model {\n\tpublic var value:Int = 0;\n\tpublic function new() {}\n}';
		final text: String = okEncap(src, 'Model', 'value');
		Assert.isTrue(StringTools.contains(text, 'function set_value(newValue:Int):Int'), 'param renamed to avoid shadowing');
		Assert.isTrue(StringTools.contains(text, 'return value = newValue'), 'setter assigns field from the renamed param');
		Assert.isFalse(StringTools.contains(text, 'return value = value'), 'no self-assign');
	}

	/** A `final` field is refused (no setter). */
	public function testFinalRefused(): Void {
		final src: String = 'package pkg;\n\nclass Model {\n\tpublic final id:Int = 1;\n\tpublic function new() {}\n}';
		assertErr(EncapsulateField.encapsulate(src, 'Model', 'id', true, plugin()));
	}

	/** A `static` field is refused. */
	public function testStaticRefused(): Void {
		final src: String = 'package pkg;\n\nclass Model {\n\tpublic static var shared:Int = 0;\n\tpublic function new() {}\n}';
		assertErr(EncapsulateField.encapsulate(src, 'Model', 'shared', true, plugin()));
	}

	/** A field with no explicit type is refused. */
	public function testNoTypeRefused(): Void {
		final src: String = 'package pkg;\n\nclass Model {\n\tpublic var loose = 0;\n\tpublic function new() {}\n}';
		assertErr(EncapsulateField.encapsulate(src, 'Model', 'loose', true, plugin()));
	}

	/** An existing accessor blocks encapsulation. */
	public function testAccessorExistsRefused(): Void {
		final src: String = 'package pkg;\n\nclass Model {\n\tpublic var count:Int = 0;\n\tpublic function new() {}\n\tfunction get_count():Int return count;\n}';
		assertErr(EncapsulateField.encapsulate(src, 'Model', 'count', true, plugin()));
	}

	/** A field already declared as a property is refused. */
	public function testAlreadyPropertyRefused(): Void {
		final src: String = 'package pkg;\n\nclass Model {\n\t@:isVar public var count(get, set):Int = 0;\n\tpublic function new() {}\n\tfunction get_count():Int return count;\n\tfunction set_count(v:Int):Int return count = v;\n}';
		assertErr(EncapsulateField.encapsulate(src, 'Model', 'count', true, plugin()));
	}

	/** A method name (not a field) is refused. */
	public function testMethodNotFieldRefused(): Void {
		final src: String = 'package pkg;\n\nclass Model {\n\tpublic function new() {}\n\tpublic function run():Void {}\n}';
		assertErr(EncapsulateField.encapsulate(src, 'Model', 'run', true, plugin()));
	}

	/** A missing field is refused. */
	public function testNoSuchFieldRefused(): Void {
		final src: String = 'package pkg;\n\nclass Model {\n\tpublic var count:Int = 0;\n\tpublic function new() {}\n}';
		assertErr(EncapsulateField.encapsulate(src, 'Model', 'nope', true, plugin()));
	}

	private function okEncap(src: String, typeName: String, fieldName: String): String {
		switch EncapsulateField.encapsulate(src, typeName, fieldName, true, plugin()) {
			case Ok(text):
				var parsed: Bool = true;
				try
					plugin().parseFile(text)
				catch (_: haxe.Exception)
					parsed = false;
				Assert.isTrue(parsed, 'result should re-parse');
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	private function assertErr(result: EditResult): Void {
		switch result {
			case Ok(_):
				Assert.fail('expected Err, got Ok');
			case Err(_):
				Assert.pass();
		}
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}
