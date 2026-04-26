package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxModifier;
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
		final module:HxModule = HaxeModuleParser.parse('typedef Foo = Bar;');
		Assert.equals(1, module.decls.length);
		final td:HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Foo', (td.name : String));
		Assert.equals('Bar', (expectNamedType(td.type).name : String));
	}

	public function testTypedefWhitespace():Void {
		final module:HxModule = HaxeModuleParser.parse('  typedef  Foo  =  Bar ;  ');
		Assert.equals(1, module.decls.length);
		final td:HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Foo', (td.name : String));
		Assert.equals('Bar', (expectNamedType(td.type).name : String));
	}

	public function testTypedefInModule():Void {
		final module:HxModule = HaxeModuleParser.parse('typedef Foo = Bar; class Baz {}');
		Assert.equals(2, module.decls.length);
		final td:HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Foo', (td.name : String));
		final cls:HxClassDecl = expectClassDecl(module.decls[1]);
		Assert.equals('Baz', (cls.name : String));
	}

	public function testRejectsTypedefMissingEquals():Void {
		Assert.raises(() -> HaxeModuleParser.parse('typedef Foo Bar;'), ParseError);
	}

	public function testTypedefMissingSemicolonAccepted():Void {
		// Slice ω-typedef-trailOpt: trailing `;` on typedef is optional
		// (`@:trailOpt(';')` on `HxDecl.TypedefDecl`). Real Haxe accepts
		// `typedef Foo = Bar class Baz {}` because `class` ends the
		// preceding type ref and starts a new top-level decl.
		final module:HxModule = HaxeModuleParser.parse('typedef Foo = Bar class Baz {}');
		Assert.equals(2, module.decls.length);
		Assert.equals('Foo', (expectTypedefDecl(module.decls[0]).name : String));
		Assert.equals('Baz', (expectClassDecl(module.decls[1]).name : String));
	}

	// -- Enum tests --

	public function testEmptyEnum():Void {
		final module:HxModule = HaxeModuleParser.parse('enum Color {}');
		Assert.equals(1, module.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(0, ed.ctors.length);
	}

	public function testSingleCtor():Void {
		final module:HxModule = HaxeModuleParser.parse('enum Color { Red; }');
		Assert.equals(1, module.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(1, ed.ctors.length);
		Assert.equals('Red', (expectSimpleCtor(ed.ctors[0]) : String));
	}

	public function testMultipleCtors():Void {
		final module:HxModule = HaxeModuleParser.parse('enum Color { Red; Green; Blue; }');
		Assert.equals(1, module.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(3, ed.ctors.length);
		Assert.equals('Red', (expectSimpleCtor(ed.ctors[0]) : String));
		Assert.equals('Green', (expectSimpleCtor(ed.ctors[1]) : String));
		Assert.equals('Blue', (expectSimpleCtor(ed.ctors[2]) : String));
	}

	public function testEnumWhitespace():Void {
		final module:HxModule = HaxeModuleParser.parse('  enum  Color  {  Red ;  Green ;  }  ');
		Assert.equals(1, module.decls.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(2, ed.ctors.length);
		Assert.equals('Red', (expectSimpleCtor(ed.ctors[0]) : String));
		Assert.equals('Green', (expectSimpleCtor(ed.ctors[1]) : String));
	}

	public function testEnumInModule():Void {
		final module:HxModule = HaxeModuleParser.parse('class Foo {} enum Color { Red; }');
		Assert.equals(2, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (cls.name : String));
		final ed:HxEnumDecl = expectEnumDecl(module.decls[1]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(1, ed.ctors.length);
	}

	public function testRejectsUnclosedEnum():Void {
		Assert.raises(() -> HaxeModuleParser.parse('enum Color { Red;'), ParseError);
	}

	// -- Interface tests --

	public function testEmptyInterface():Void {
		final module:HxModule = HaxeModuleParser.parse('interface IFoo {}');
		Assert.equals(1, module.decls.length);
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals('IFoo', (id.name : String));
		Assert.equals(0, id.members.length);
	}

	public function testInterfaceWithVar():Void {
		final module:HxModule = HaxeModuleParser.parse('interface IFoo { var x:Int; }');
		Assert.equals(1, module.decls.length);
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals(1, id.members.length);
		final vd:HxVarDecl = expectVarMember(id.members[0].member);
		Assert.equals('x', (vd.name : String));
		Assert.equals('Int', (expectNamedType(vd.type).name : String));
	}

	public function testInterfaceWithFunction():Void {
		final module:HxModule = HaxeModuleParser.parse('interface IFoo { function f():Void {} }');
		Assert.equals(1, module.decls.length);
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals(1, id.members.length);
		final fd:HxFnDecl = expectFnMember(id.members[0].member);
		Assert.equals('f', (fd.name : String));
		Assert.equals('Void', (expectNamedType(fd.returnType).name : String));
	}

	public function testInterfaceWithModifiers():Void {
		final module:HxModule = HaxeModuleParser.parse('interface IFoo { public function f():Void {} }');
		Assert.equals(1, module.decls.length);
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals(1, id.members.length);
		Assert.equals(1, id.members[0].modifiers.length);
		final fd:HxFnDecl = expectFnMember(id.members[0].member);
		Assert.equals('f', (fd.name : String));
	}

	public function testInterfaceInModule():Void {
		final module:HxModule = HaxeModuleParser.parse('class Foo {} interface IBar {}');
		Assert.equals(2, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (cls.name : String));
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[1]);
		Assert.equals('IBar', (id.name : String));
	}

	// -- Mixed module tests --

	public function testMixedModule():Void {
		final source:String = 'class Foo {} typedef Bar = Int; enum Color { Red; Green; } interface IBaz {}';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(4, module.decls.length);

		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (cls.name : String));

		final td:HxTypedefDecl = expectTypedefDecl(module.decls[1]);
		Assert.equals('Bar', (td.name : String));
		Assert.equals('Int', (expectNamedType(td.type).name : String));

		final ed:HxEnumDecl = expectEnumDecl(module.decls[2]);
		Assert.equals('Color', (ed.name : String));
		Assert.equals(2, ed.ctors.length);

		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[3]);
		Assert.equals('IBaz', (id.name : String));
	}

	public function testWordBoundaryTypedefine():Void {
		Assert.raises(() -> HaxeModuleParser.parse('typedefine Foo = Bar;'), ParseError);
	}

	public function testWordBoundaryEnumerate():Void {
		Assert.raises(() -> HaxeModuleParser.parse('enumerate Color {}'), ParseError);
	}

	public function testWordBoundaryInterfacing():Void {
		Assert.raises(() -> HaxeModuleParser.parse('interfacing IFoo {}'), ParseError);
	}

	// -- Top-level modifier tests --

	public function testTopLevelPrivateClass():Void {
		final module:HxModule = HaxeModuleParser.parse('private class Foo {}');
		Assert.equals(1, module.decls.length);
		Assert.equals(1, module.decls[0].modifiers.length);
		Assert.equals(Private, module.decls[0].modifiers[0]);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (cls.name : String));
	}

	public function testTopLevelPrivateTypedef():Void {
		final module:HxModule = HaxeModuleParser.parse('private typedef Foo = Bar;');
		Assert.equals(1, module.decls.length);
		Assert.equals(1, module.decls[0].modifiers.length);
		Assert.equals(Private, module.decls[0].modifiers[0]);
		final td:HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		Assert.equals('Foo', (td.name : String));
	}

	public function testTopLevelPrivateEnum():Void {
		final module:HxModule = HaxeModuleParser.parse('private enum Color { Red; }');
		Assert.equals(1, module.decls.length);
		Assert.equals(1, module.decls[0].modifiers.length);
		Assert.equals(Private, module.decls[0].modifiers[0]);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals('Color', (ed.name : String));
	}

	public function testTopLevelPrivateInterface():Void {
		final module:HxModule = HaxeModuleParser.parse('private interface IFoo {}');
		Assert.equals(1, module.decls.length);
		Assert.equals(1, module.decls[0].modifiers.length);
		Assert.equals(Private, module.decls[0].modifiers[0]);
		final id:HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals('IFoo', (id.name : String));
	}

	public function testTopLevelExternFinalClass():Void {
		// Multiple modifiers — semantic validity (`extern final class`) is
		// the analysis pass's job, parser only checks syntax.
		final module:HxModule = HaxeModuleParser.parse('extern final class Foo {}');
		Assert.equals(2, module.decls[0].modifiers.length);
		Assert.equals(Extern, module.decls[0].modifiers[0]);
		Assert.equals(Final, module.decls[0].modifiers[1]);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (cls.name : String));
	}

	public function testTopLevelMixedModifiers():Void {
		final source:String = 'private class A {} class B {} private typedef C = Int;';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(3, module.decls.length);
		Assert.equals(1, module.decls[0].modifiers.length);
		Assert.equals(Private, module.decls[0].modifiers[0]);
		Assert.equals(0, module.decls[1].modifiers.length);
		Assert.equals(1, module.decls[2].modifiers.length);
		Assert.equals(Private, module.decls[2].modifiers[0]);
	}
}
