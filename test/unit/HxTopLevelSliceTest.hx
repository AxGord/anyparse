package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxTypedefDecl;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 top-level forms tests for the macro-generated Haxe parser.
 *
 * Validates three new `HxDecl` branches: `TypedefDecl`, `EnumDecl`,
 * and `InterfaceDecl`. All follow existing patterns — zero Lowering
 * changes.
 */
class HxTopLevelSliceTest extends HxTestHelpers {

	// -- Typedef tests --

	public function testSimpleTypedef():Void {
		final module:HxModule = HaxeModuleFastParser.parse('typedef Foo = Bar;');
		Assert.equals(1, module.decls.length);
		final td:HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Foo', (td.name : String));
		Assert.equals('Bar', (td.type.name : String));
	}

	public function testTypedefWhitespace():Void {
		final module:HxModule = HaxeModuleFastParser.parse('  typedef  Foo  =  Bar ;  ');
		Assert.equals(1, module.decls.length);
		final td:HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Foo', (td.name : String));
		Assert.equals('Bar', (td.type.name : String));
	}

	public function testTypedefInModule():Void {
		final module:HxModule = HaxeModuleFastParser.parse('typedef Foo = Bar; class Baz {}');
		Assert.equals(2, module.decls.length);
		final td:HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Foo', (td.name : String));
		final cls:HxClassDecl = expectClassDecl(module.decls[1]);
		Assert.equals('Baz', (cls.name : String));
	}

	public function testRejectsTypedefMissingEquals():Void {
		Assert.raises(() -> HaxeModuleFastParser.parse('typedef Foo Bar;'), ParseError);
	}

	public function testRejectsTypedefMissingSemicolon():Void {
		Assert.raises(() -> HaxeModuleFastParser.parse('typedef Foo = Bar class Baz {}'), ParseError);
	}

	// -- Enum tests --

	public function testEmptyEnum():Void {
		final module:HxModule = HaxeModuleFastParser.parse('enum Color {}');
		Assert.equals(1, module.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(0, ed.ctors.length);
	}

	public function testSingleCtor():Void {
		final module:HxModule = HaxeModuleFastParser.parse('enum Color { Red; }');
		Assert.equals(1, module.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(1, ed.ctors.length);
		Assert.equals('Red', (expectSimpleCtor(ed.ctors[0]) : String));
	}

	public function testMultipleCtors():Void {
		final module:HxModule = HaxeModuleFastParser.parse('enum Color { Red; Green; Blue; }');
		Assert.equals(1, module.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(3, ed.ctors.length);
		Assert.equals('Red', (expectSimpleCtor(ed.ctors[0]) : String));
		Assert.equals('Green', (expectSimpleCtor(ed.ctors[1]) : String));
		Assert.equals('Blue', (expectSimpleCtor(ed.ctors[2]) : String));
	}

	public function testEnumWhitespace():Void {
		final module:HxModule = HaxeModuleFastParser.parse('  enum  Color  {  Red ;  Green ;  }  ');
		Assert.equals(1, module.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(2, ed.ctors.length);
		Assert.equals('Red', (expectSimpleCtor(ed.ctors[0]) : String));
		Assert.equals('Green', (expectSimpleCtor(ed.ctors[1]) : String));
	}

	public function testEnumInModule():Void {
		final module:HxModule = HaxeModuleFastParser.parse('class Foo {} enum Color { Red; }');
		Assert.equals(2, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (cls.name : String));
		final ed:HxEnumDecl = expectEnumDecl(module.decls[1]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(1, ed.ctors.length);
	}

	public function testRejectsUnclosedEnum():Void {
		Assert.raises(() -> HaxeModuleFastParser.parse('enum Color { Red;'), ParseError);
	}

	// -- Interface tests --

	public function testEmptyInterface():Void {
		final module:HxModule = HaxeModuleFastParser.parse('interface IFoo {}');
		Assert.equals(1, module.decls.length);
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals('IFoo', (id.name : String));
		Assert.equals(0, id.members.length);
	}

	public function testInterfaceWithVar():Void {
		final module:HxModule = HaxeModuleFastParser.parse('interface IFoo { var x:Int; }');
		Assert.equals(1, module.decls.length);
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals(1, id.members.length);
		final vd:HxVarDecl = expectVarMember(id.members[0].member);
		Assert.equals('x', (vd.name : String));
		Assert.equals('Int', (vd.type.name : String));
	}

	public function testInterfaceWithFunction():Void {
		final module:HxModule = HaxeModuleFastParser.parse('interface IFoo { function f():Void {} }');
		Assert.equals(1, module.decls.length);
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals(1, id.members.length);
		final fd:HxFnDecl = expectFnMember(id.members[0].member);
		Assert.equals('f', (fd.name : String));
		Assert.equals('Void', (fd.returnType.name : String));
	}

	public function testInterfaceWithModifiers():Void {
		final module:HxModule = HaxeModuleFastParser.parse('interface IFoo { public function f():Void {} }');
		Assert.equals(1, module.decls.length);
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals(1, id.members.length);
		Assert.equals(1, id.members[0].modifiers.length);
		final fd:HxFnDecl = expectFnMember(id.members[0].member);
		Assert.equals('f', (fd.name : String));
	}

	public function testInterfaceInModule():Void {
		final module:HxModule = HaxeModuleFastParser.parse('class Foo {} interface IBar {}');
		Assert.equals(2, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (cls.name : String));
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[1]);
		Assert.equals('IBar', (id.name : String));
	}

	// -- Mixed module tests --

	public function testMixedModule():Void {
		final source:String = 'class Foo {} typedef Bar = Int; enum Color { Red; Green; } interface IBaz {}';
		final module:HxModule = HaxeModuleFastParser.parse(source);
		Assert.equals(4, module.decls.length);

		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (cls.name : String));

		final td:HxTypedefDecl = expectTypedefDecl(module.decls[1]);
		Assert.equals('Bar', (td.name : String));
		Assert.equals('Int', (td.type.name : String));

		final ed:HxEnumDecl = expectEnumDecl(module.decls[2]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(2, ed.ctors.length);

		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[3]);
		Assert.equals('IBaz', (id.name : String));
	}

	public function testWordBoundaryTypedefine():Void {
		Assert.raises(() -> HaxeModuleFastParser.parse('typedefine Foo = Bar;'), ParseError);
	}

	public function testWordBoundaryEnumerate():Void {
		Assert.raises(() -> HaxeModuleFastParser.parse('enumerate Color {}'), ParseError);
	}

	public function testWordBoundaryInterfacing():Void {
		Assert.raises(() -> HaxeModuleFastParser.parse('interfacing IFoo {}'), ParseError);
	}
}
