package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.MakeFinal;
import anyparse.query.RefactorSupport.EditResult;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `MakeFinal.makeFinal` — turn a never-reassigned `var` field into
 * `final`, so the `move-member` instance path (final-fields contract) can
 * take it. Each test drives the PURE op with an in-memory scope; a
 * qualifying field is rewritten (`Ok`), a reassigned / never-assigned /
 * doubly-assigned one is refused (`Err`).
 */
class MakeFinalSliceTest extends Test {

	/** A class with one declaration-initialised public field — the plain finalizable shape. */
	private static final DECL_INIT_FIELD: String = 'package pkg;\n\nclass Cfg {\n\tpublic var x:Int = 5;\n\tpublic function new() {}\n}';

	/** A class carrying BOTH members of the builtin structural `Iterator` set, `hasNext` as a field. */
	private static final ITERATOR_SHAPE: String = 'package pkg;\n\nclass It {\n\tpublic var hasNext:Void->Bool;\n'
		+ '\tpublic function new(h:Void->Bool) { hasNext = h; }\n\tpublic function next():Int return 1;\n}';

	/** A field assigned only at its declaration becomes final. */
	public function testDeclInitToFinal(): Void {
		final src: String =
			'package pkg;\n\nclass Cfg {\n\tpublic var x:Int = 5;\n\tpublic function new() {}\n\tpublic function read():Int return x;\n}';
		final text: String = okFinal('pkg/Cfg.hx', 'Cfg', 'x', [{ file: 'pkg/Cfg.hx', source: src }]);
		Assert.isTrue(text.contains('public final x:Int = 5'), 'var became final');
	}

	/** A field assigned only in the constructor becomes final. */
	public function testCtorInitToFinal(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var name:String;\n\tpublic function new(n:String) { name = n; }\n}';
		final text: String = okFinal('pkg/Cfg.hx', 'Cfg', 'name', [{ file: 'pkg/Cfg.hx', source: src }]);
		Assert.isTrue(text.contains('public final name:String;'), 'ctor-assigned var became final');
	}

	/** A field reassigned in a method is refused. */
	public function testReassignedRefused(): Void {
		final src: String =
			'package pkg;\n\nclass Cfg {\n\tpublic var n:Int = 0;\n\tpublic function new() {}\n\tpublic function bump():Void n = n + 1;\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'n', [{ file: 'pkg/Cfg.hx', source: src }], plugin()));
	}

	/** A compound-assign counts as a reassignment. */
	public function testCompoundAssignRefused(): Void {
		final src: String =
			'package pkg;\n\nclass Cfg {\n\tpublic var n:Int = 0;\n\tpublic function new() {}\n\tpublic function bump():Void n += 1;\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'n', [{ file: 'pkg/Cfg.hx', source: src }], plugin()));
	}

	/** A cross-file `obj.field = …` write is refused. */
	public function testCrossFileWriteRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var v:Int = 0;\n\tpublic function new() {}\n}';
		final user: String = 'package pkg;\n\nclass User {\n\tpublic function new() {}\n\tpublic function set(c:Cfg):Void c.v = 9;\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'v', [
			{ file: 'pkg/Cfg.hx', source: src },
			{ file: 'pkg/User.hx', source: user }
		], plugin()));
	}

	/** A field never assigned (no init, no ctor write) is refused. */
	public function testNeverAssignedRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var loose:Int;\n\tpublic function new() {}\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'loose', [{ file: 'pkg/Cfg.hx', source: src }], plugin()));
	}

	/** A field assigned both at its declaration and in the constructor is refused. */
	public function testDoubleInitRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var x:Int = 1;\n\tpublic function new() { x = 2; }\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'x', [{ file: 'pkg/Cfg.hx', source: src }], plugin()));
	}

	/** A field that is already final is not a plain var and is refused. */
	public function testAlreadyFinalRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic final x:Int = 1;\n\tpublic function new() {}\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'x', [{ file: 'pkg/Cfg.hx', source: src }], plugin()));
	}

	/** A missing field is refused. */
	public function testNoSuchFieldRefused(): Void {
		final src: String = 'package pkg;\n\nclass Cfg {\n\tpublic var x:Int = 1;\n\tpublic function new() {}\n}';
		assertErr(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'nope', [{ file: 'pkg/Cfg.hx', source: src }], plugin()));
	}

	/**
	 * The `Iterator` shape: a class declaring `hasNext` and `next` unifies with the language's
	 * builtin structural iterator, whose members are non-final, so `final` there is `Cannot
	 * unify final and non-final fields` — refused.
	 */
	public function testStructuralIteratorMemberRefused(): Void {
		assertErrContaining(
			MakeFinal.makeFinal('pkg/It.hx', 'It', 'hasNext', [{ file: 'pkg/It.hx', source: ITERATOR_SHAPE }], plugin()), 'structural type'
		);
	}

	/**
	 * The positive control for the builtin arm: `hasNext` alone is not the `Iterator` shape —
	 * the set needs `next` too — so the same field in a class lacking it stays finalizable. A
	 * gate keyed on the NAME rather than on the member set would refuse this one as well.
	 */
	public function testHalfIteratorShapeStillFinal(): Void {
		final src: String =
			'package pkg;\n\nclass Half {\n\tpublic var hasNext:Void->Bool;\n\tpublic function new(h:Void->Bool) { hasNext = h; }\n}';
		final text: String = okFinal('pkg/Half.hx', 'Half', 'hasNext', [{ file: 'pkg/Half.hx', source: src }]);
		Assert.isTrue(text.contains('public final hasNext:Void->Bool;'), 'var became final');
	}

	/** The OPTIONAL shorthand anon-structure field form `?x:T` declares a mutable member too. */
	public function testOptionalShorthandStructuralMemberRefused(): Void {
		assertErrContaining(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'x', [
			{ file: 'pkg/Cfg.hx', source: DECL_INIT_FIELD },
			{ file: 'pkg/S.hx', source: 'package pkg;\n\ntypedef S = { ?x:Int }' }
		], plugin()), 'structural type');
	}

	/** An anonymous-structure typedef in scope declaring the same member as a mutable field pins it. */
	public function testStructuralTypedefMemberRefused(): Void {
		assertErrContaining(MakeFinal.makeFinal('pkg/Cfg.hx', 'Cfg', 'x', [
			{ file: 'pkg/Cfg.hx', source: DECL_INIT_FIELD },
			{ file: 'pkg/S.hx', source: 'package pkg;\n\ntypedef S = { var x:Int; }' }
		], plugin()), 'structural type');
	}

	/** A structure the class does NOT satisfy (it lacks `y`) leaves the field finalizable. */
	public function testUnsatisfiedStructuralTypedefStillFinal(): Void {
		final text: String = okFinal('pkg/Cfg.hx', 'Cfg', 'x', [
			{ file: 'pkg/Cfg.hx', source: DECL_INIT_FIELD },
			{ file: 'pkg/S.hx', source: 'package pkg;\n\ntypedef S = { var x:Int; var y:Int; }' }
		]);
		Assert.isTrue(text.contains('public final x:Int = 5'), 'var became final');
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

	/**
	 * `assertErr` plus the reason: every gate in `makeFinal` answers `Err`, so a bare `assertErr`
	 * passes when an EARLIER gate refuses and says nothing about the one under test.
	 */
	private function assertErrContaining(result: EditResult, fragment: String): Void {
		switch result {
			case Ok(_):
				Assert.fail('expected Err, got Ok');
			case Err(message):
				Assert.isTrue(message.contains(fragment), 'Err "$message" should mention "$fragment"');
		}
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}
