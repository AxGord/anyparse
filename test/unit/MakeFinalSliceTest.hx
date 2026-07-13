package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.MakeFinal;
import anyparse.query.RefactorSupport.EditResult;

/**
 * `MakeFinal.makeFinal` — turn a never-reassigned `var` field into
 * `final`, so the `move-member` instance path (final-fields contract) can
 * take it. Each test drives the PURE op with an in-memory scope; a
 * qualifying field is rewritten (`Ok`), a reassigned / never-assigned /
 * doubly-assigned one is refused (`Err`).
 */
class MakeFinalSliceTest extends Test {

	/** A field assigned only at its declaration becomes final. */
	public function testDeclInitToFinal(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var x:Int = 5;\n\tpublic function new() {}\n'
			+ '\tpublic function read():Int return x;\n}';
		final text: String = okFinal('pkg/Cfg.hx', 'Cfg', 'x', [{ file: 'pkg/Cfg.hx', source: src },]);
		Assert.isTrue(StringTools.contains(text, 'public final x:Int = 5'), 'var became final');
	}

	/** A field assigned only in the constructor becomes final. */
	public function testCtorInitToFinal(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var name:String;\n' + '\tpublic function new(n:String) { name = n; }\n}';
		final text: String = okFinal('pkg/Cfg.hx', 'Cfg', 'name', [{ file: 'pkg/Cfg.hx', source: src },]);
		Assert.isTrue(StringTools.contains(text, 'public final name:String;'), 'ctor-assigned var became final');
	}

	/** A field reassigned in a method is refused. */
	public function testReassignedRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var n:Int = 0;\n\tpublic function new() {}\n'
			+ '\tpublic function bump():Void n = n + 1;\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'n', [{ file: 'pkg/Cfg.hx', source: src },], plugin()));
	}

	/** A compound-assign counts as a reassignment. */
	public function testCompoundAssignRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var n:Int = 0;\n\tpublic function new() {}\n'
			+ '\tpublic function bump():Void n += 1;\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'n', [{ file: 'pkg/Cfg.hx', source: src },], plugin()));
	}

	/** A cross-file `obj.field = …` write is refused. */
	public function testCrossFileWriteRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var v:Int = 0;\n\tpublic function new() {}\n}';
		final user: String = 'package pkg;\n\nclass User {\n\tpublic function new() {}\n' + '\tpublic function set(c:Cfg):Void c.v = 9;\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'v', [
			{ file: 'pkg/Cfg.hx', source: src },
			{ file: 'pkg/User.hx', source: user },
		], plugin()));
	}

	/** A field never assigned (no init, no ctor write) is refused. */
	public function testNeverAssignedRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var loose:Int;\n\tpublic function new() {}\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'loose', [{ file: 'pkg/Cfg.hx', source: src },], plugin()));
	}

	/** A field assigned both at its declaration and in the constructor is refused. */
	public function testDoubleInitRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var x:Int = 1;\n' + '\tpublic function new() { x = 2; }\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'x', [{ file: 'pkg/Cfg.hx', source: src },], plugin()));
	}

	/** A field that is already final is not a plain var and is refused. */
	public function testAlreadyFinalRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic final x:Int = 1;\n\tpublic function new() {}\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'x', [{ file: 'pkg/Cfg.hx', source: src },], plugin()));
	}

	/** A missing field is refused. */
	public function testNoSuchFieldRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var x:Int = 1;\n\tpublic function new() {}\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'nope', [{ file: 'pkg/Cfg.hx', source: src },], plugin()));
	}

	private function okFinal(
		srcFile: String, typeName: String, field: String, scopeFiles: Array<{ file: String, source: String }>
	): String {
		switch MakeFinal.makeFinal(srcFile, typeName, field, scopeFiles, plugin()) {
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
