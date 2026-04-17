package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxModule;
import anyparse.runtime.ParseError;

/**
 * Phase 3 multi-declaration tests for the macro-generated Haxe module
 * parser.
 *
 * Complements `HaxeFirstSliceTest` (which targets `HaxeParser` rooted
 * on `HxClassDecl`) by exercising `HaxeModuleParser` rooted on
 * `HxModule` — the EOF-terminated Star<HxDecl> list that represents a
 * complete `.hx` file's top level.
 *
 * The module grammar supports only `class` declarations in this slice;
 * typedefs, enums, abstracts, imports, and conditional compilation are
 * deferred to later milestones. Empty modules (zero decls) are valid and
 * mirror the existing zero-member class case from the skeleton session.
 */
class HaxeModuleSliceTest extends HxTestHelpers {

	public function new() {
		super();
	}

	public function testEmptyModule():Void {
		final module:HxModule = HaxeModuleParser.parse('');
		Assert.equals(0, module.decls.length);
	}

	public function testEmptyModuleWithWhitespace():Void {
		final module:HxModule = HaxeModuleParser.parse('   \n\t  \n');
		Assert.equals(0, module.decls.length);
	}

	public function testSingleClassModule():Void {
		final module:HxModule = HaxeModuleParser.parse('class Foo {}');
		Assert.equals(1, module.decls.length);
		final classDecl:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (classDecl.name : String));
		Assert.equals(0, classDecl.members.length);
	}

	public function testTwoClassModule():Void {
		final module:HxModule = HaxeModuleParser.parse('class Foo {} class Bar {}');
		Assert.equals(2, module.decls.length);
		Assert.equals('Foo', (expectClassDecl(module.decls[0]).name : String));
		Assert.equals('Bar', (expectClassDecl(module.decls[1]).name : String));
	}

	public function testThreeClassModule():Void {
		final module:HxModule = HaxeModuleParser.parse('class A {} class B {} class C {}');
		Assert.equals(3, module.decls.length);
		Assert.equals('A', (expectClassDecl(module.decls[0]).name : String));
		Assert.equals('B', (expectClassDecl(module.decls[1]).name : String));
		Assert.equals('C', (expectClassDecl(module.decls[2]).name : String));
	}

	public function testTwoClassesWithNoSpace():Void {
		final module:HxModule = HaxeModuleParser.parse('class Foo {}class Bar {}');
		Assert.equals(2, module.decls.length);
		Assert.equals('Foo', (expectClassDecl(module.decls[0]).name : String));
		Assert.equals('Bar', (expectClassDecl(module.decls[1]).name : String));
	}

	public function testModuleWithMembers():Void {
		final source:String = 'class Foo { var x:Int; } class Bar { function tick():Void {} }';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(2, module.decls.length);

		final foo:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (foo.name : String));
		Assert.equals(1, foo.members.length);
		final fooMember:HxClassMember = foo.members[0].member;
		switch fooMember {
			case VarMember(decl):
				Assert.equals('x', (decl.name : String));
				Assert.equals('Int', (decl.type.name : String));
			case _:
				Assert.fail('expected VarMember, got $fooMember');
		}

		final bar:HxClassDecl = expectClassDecl(module.decls[1]);
		Assert.equals('Bar', (bar.name : String));
		Assert.equals(1, bar.members.length);
		final barMember:HxClassMember = bar.members[0].member;
		switch barMember {
			case FnMember(decl):
				Assert.equals('tick', (decl.name : String));
				Assert.equals('Void', (decl.returnType.name : String));
			case _:
				Assert.fail('expected FnMember, got $barMember');
		}
	}

	public function testIrregularWhitespaceBetweenClasses():Void {
		final source:String = '\n\nclass Foo {}\n\n\tclass Bar {}\n';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(2, module.decls.length);
		Assert.equals('Foo', (expectClassDecl(module.decls[0]).name : String));
		Assert.equals('Bar', (expectClassDecl(module.decls[1]).name : String));
	}

	public function testRejectsTrailingGarbage():Void {
		// After parsing `class Foo {}`, the EOF-terminated loop tries to
		// parse another HxDecl starting at `bogus` — that call expects the
		// `class` keyword and fails with ParseError.
		Assert.raises(() -> HaxeModuleParser.parse('class Foo {} bogus'), ParseError);
	}

	public function testRejectsIncompleteClass():Void {
		// Incomplete last decl — the inner class parser fails on the
		// missing `{}` and the error propagates out of the module loop.
		Assert.raises(() -> HaxeModuleParser.parse('class Foo {} class Bar'), ParseError);
	}

}
