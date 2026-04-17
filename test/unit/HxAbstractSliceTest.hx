package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 abstract declaration tests for the macro-generated Haxe parser.
 *
 * Validates the `AbstractDecl` branch in `HxDecl`, `HxAbstractDecl`
 * typedef, and `HxAbstractClause` enum (from/to clauses). Zero Lowering
 * changes — first consumer of positional try-parse on a bare Star field.
 */
class HxAbstractSliceTest extends HxTestHelpers {

	// -- Basic abstract --

	public function testEmptyAbstract():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo(Int) {}');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals('Foo', (ad.name : String));
		Assert.equals('Int', (ad.underlyingType.name : String));
		Assert.equals(0, ad.clauses.length);
		Assert.equals(0, ad.members.length);
	}

	public function testAbstractWhitespace():Void {
		final module:HxModule = HaxeModuleParser.parse('  abstract  Foo  (  Int  )  {  }  ');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals('Foo', (ad.name : String));
		Assert.equals('Int', (ad.underlyingType.name : String));
		Assert.equals(0, ad.clauses.length);
		Assert.equals(0, ad.members.length);
	}

	// -- from/to clauses --

	public function testSingleFrom():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo(Int) from Int {}');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals('Foo', (ad.name : String));
		Assert.equals('Int', (ad.underlyingType.name : String));
		Assert.equals(1, ad.clauses.length);
		switch ad.clauses[0] {
			case FromClause(type): Assert.equals('Int', (type.name : String));
			case _: Assert.fail('expected FromClause');
		}
	}

	public function testSingleTo():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo(Int) to String {}');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(1, ad.clauses.length);
		switch ad.clauses[0] {
			case ToClause(type): Assert.equals('String', (type.name : String));
			case _: Assert.fail('expected ToClause');
		}
	}

	public function testFromAndTo():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo(Int) from Int to String {}');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(2, ad.clauses.length);
		switch ad.clauses[0] {
			case FromClause(type): Assert.equals('Int', (type.name : String));
			case _: Assert.fail('expected FromClause');
		}
		switch ad.clauses[1] {
			case ToClause(type): Assert.equals('String', (type.name : String));
			case _: Assert.fail('expected ToClause');
		}
	}

	public function testMultipleFromTo():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo(Int) from Int from Float to String to Bool {}');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(4, ad.clauses.length);
		switch ad.clauses[0] {
			case FromClause(type): Assert.equals('Int', (type.name : String));
			case _: Assert.fail('expected FromClause at 0');
		}
		switch ad.clauses[1] {
			case FromClause(type): Assert.equals('Float', (type.name : String));
			case _: Assert.fail('expected FromClause at 1');
		}
		switch ad.clauses[2] {
			case ToClause(type): Assert.equals('String', (type.name : String));
			case _: Assert.fail('expected ToClause at 2');
		}
		switch ad.clauses[3] {
			case ToClause(type): Assert.equals('Bool', (type.name : String));
			case _: Assert.fail('expected ToClause at 3');
		}
	}

	public function testClausesWhitespace():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo ( Int )  from  Int  to  String  { }');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(2, ad.clauses.length);
		Assert.equals('Int', (ad.underlyingType.name : String));
	}

	// -- Members --

	public function testAbstractWithVar():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo(Int) { var x:Int; }');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(0, ad.clauses.length);
		Assert.equals(1, ad.members.length);
		final vd:HxVarDecl = expectVarMember(ad.members[0].member);
		Assert.equals('x', (vd.name : String));
		Assert.equals('Int', (vd.type.name : String));
	}

	public function testAbstractWithFunction():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo(Int) { function f():Void {} }');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(1, ad.members.length);
		final fd:HxFnDecl = expectFnMember(ad.members[0].member);
		Assert.equals('f', (fd.name : String));
		Assert.equals('Void', (fd.returnType.name : String));
	}

	public function testAbstractWithModifiers():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo(Int) { public static inline function f():Void {} }');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(1, ad.members.length);
		Assert.equals(3, ad.members[0].modifiers.length);
		final fd:HxFnDecl = expectFnMember(ad.members[0].member);
		Assert.equals('f', (fd.name : String));
	}

	public function testAbstractWithClausesAndMembers():Void {
		final module:HxModule = HaxeModuleParser.parse('abstract Foo(Int) from Int to String { var x:Int; function f():Void {} }');
		Assert.equals(1, module.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(2, ad.clauses.length);
		Assert.equals(2, ad.members.length);
	}

	// -- Module integration --

	public function testAbstractInModule():Void {
		final module:HxModule = HaxeModuleParser.parse('class Bar {} abstract Foo(Int) {}');
		Assert.equals(2, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Bar', (cls.name : String));
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[1]);
		Assert.equals('Foo', (ad.name : String));
	}

	public function testMixedModuleWithAbstract():Void {
		final source:String = 'class Foo {} abstract Bar(Int) from Int {} enum Color { Red; }';
		final module:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(3, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (cls.name : String));
		final ad:HxAbstractDecl = expectAbstractDecl(module.decls[1]);
		Assert.equals('Bar', (ad.name : String));
		Assert.equals(1, ad.clauses.length);
		final ed:HxEnumDecl = expectEnumDecl(module.decls[2]);
		Assert.equals('Color', (ed.name : String));
	}

	// -- Word boundary --

	public function testWordBoundaryAbstractly():Void {
		Assert.raises(() -> HaxeModuleParser.parse('abstractly Foo(Int) {}'), ParseError);
	}

	// -- Rejections --

	public function testRejectsMissingOpenParen():Void {
		Assert.raises(() -> HaxeModuleParser.parse('abstract Foo Int) {}'), ParseError);
	}

	public function testRejectsMissingCloseParen():Void {
		Assert.raises(() -> HaxeModuleParser.parse('abstract Foo(Int {}'), ParseError);
	}

	public function testRejectsMissingBody():Void {
		Assert.raises(() -> HaxeModuleParser.parse('abstract Foo(Int)'), ParseError);
	}
}
