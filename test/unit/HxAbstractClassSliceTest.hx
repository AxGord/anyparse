package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxMemberModifier;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModifier;

/**
 * Slice 29 — `abstract class` top-level form + member-level
 * `abstract` / `overload` modifiers.
 *
 * Three additive grammar changes:
 *  - `HxDecl.AbstractClassDecl(decl:HxClassDecl)` with `@:kw('abstract')`,
 *    placed BEFORE `AbstractDecl(HxAbstractDecl)` so the longer-prefix
 *    shape is tried first and rolls back to the type-form on a missing
 *    `class` keyword (mirror of `EnumAbstractDecl` → `EnumDecl`).
 *  - `HxMemberModifier.Abstract` / `Overload` — `abstract function …`
 *    and `overload function …` inside a class.
 *  - `HxModifier.Overload` — top-level `overload static function …`
 *    (no `Abstract` at the top-level because the keyword is ambiguous
 *    with the type-form, the same reason `Final` lives at dispatch
 *    instead of in the modifier Star).
 *
 * Corpus drivers: `lineends/abstract_class.hxtest` and
 * `lineends/issue_626_overload_modifier.hxtest`.
 */
class HxAbstractClassSliceTest extends HxTestHelpers {

	// -- HxDecl.AbstractClassDecl --

	public function testAbstractClassEmpty(): Void {
		final mod: HxModule = HaxeModuleParser.parse('abstract class Foo {}');
		Assert.equals(1, mod.decls.length);
		Assert.isTrue(mod.decls[0].decl.match(AbstractClassDecl(_)));
	}

	public function testAbstractClassWithMembers(): Void {
		final mod: HxModule = HaxeModuleParser.parse('abstract class Foo {\n\tabstract function foo();\n\tpublic function bar() {}\n}');
		Assert.equals(1, mod.decls.length);
		final cls: HxClassDecl = switch mod.decls[0].decl {
			case AbstractClassDecl(decl): decl;
			case _: throw 'expected AbstractClassDecl';
		};
		Assert.equals(2, cls.members.length);
	}

	// -- Regression: plain `abstract Foo(Int)` still routes to AbstractDecl --

	public function testAbstractTypeDeclStillParses(): Void {
		final mod: HxModule = HaxeModuleParser.parse('abstract Foo(Int) {}');
		Assert.equals(1, mod.decls.length);
		Assert.isTrue(mod.decls[0].decl.match(AbstractDecl(_)));
	}

	public function testAbstractTypeDeclWithFromTo(): Void {
		final mod: HxModule = HaxeModuleParser.parse('abstract Foo(Int) from Int to Int { public function f() {} }');
		Assert.isTrue(mod.decls[0].decl.match(AbstractDecl(_)));
	}

	// -- HxMemberModifier.Abstract --

	public function testMemberAbstractFunction(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tabstract function foo();\n}');
		Assert.equals(1, cls.members.length);
		final mods: Array<HxMemberModifier> = cls.members[0].modifiers;
		Assert.isTrue(mods.length == 1 && mods[0].match(Abstract));
	}

	public function testMemberPublicAbstractFunction(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tpublic abstract function foo();\n}');
		final mods: Array<HxMemberModifier> = cls.members[0].modifiers;
		Assert.equals(2, mods.length);
		Assert.isTrue(mods[0].match(Public));
		Assert.isTrue(mods[1].match(Abstract));
	}

	// -- HxMemberModifier.Overload --

	public function testMemberOverloadFunction(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\toverload function foo() {}\n}');
		final mods: Array<HxMemberModifier> = cls.members[0].modifiers;
		Assert.isTrue(mods.length == 1 && mods[0].match(Overload));
	}

	public function testMemberMultiLineModifiers(): Void {
		final cls: HxClassDecl = HaxeParser.parse('class C {\n\tstatic\n\toverload extern inline function foo() {}\n}');
		final mods: Array<HxMemberModifier> = cls.members[0].modifiers;
		Assert.equals(4, mods.length);
	}

	// -- HxModifier.Overload (top-level) --

	public function testTopLevelOverloadStaticFn(): Void {
		final mod: HxModule = HaxeModuleParser.parse('overload static function foo(i:Int) {}');
		Assert.equals(1, mod.decls.length);
		final mods: Array<HxModifier> = mod.decls[0].modifiers;
		Assert.equals(2, mods.length);
		Assert.isTrue(mods[0].match(Overload));
		Assert.isTrue(mods[1].match(Static));
	}

	// -- Round-trip / corpus drivers --

	public function testCorpusAbstractClassRoundTrip(): Void {
		roundTripModule(
			'abstract class Foo {\n\tabstract function foo();\n\tpublic abstract function foo2();\n\tpublic function foo3();\n}\n',
			'abstract_class'
		);
	}

	public function testCorpusIssue626RoundTrip(): Void {
		roundTripModule(
			'abstract class Foo {\n\tstatic\n\toverload extern inline function foo() {}\n\n\toverload\n\tstatic extern inline function foo(i:Int) {}\n}\n\n\toverload\n\tstatic inline function foo(i:Int) {}\n',
			'issue_626_overload_modifier'
		);
	}

	private function roundTripModule(source: String, ?label: String): Void {
		final written1: String = anyparse.grammar.haxe.HxModuleWriter.write(HaxeModuleParser.parse(source));
		final written2: String = anyparse.grammar.haxe.HxModuleWriter.write(HaxeModuleParser.parse(written1));
		Assert.equals(written1, written2, 'idempotency failed for ${label ?? source}');
	}

}
