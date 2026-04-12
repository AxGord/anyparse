package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 expression-atom tests for the macro-generated Haxe parser.
 *
 * Validates the smallest useful expression slice — four literal
 * atoms (`IntLit`, `BoolLit`, `NullLit`, `IdentExpr`) wired as the
 * optional `= expr` initializer on a class `var` declaration.
 *
 * The grammar's HxVarDecl gained a third field
 * (`@:optional @:lead('=') var init:Null<HxExpr>`), so the generator
 * now emits a `matchLit(ctx, "=")` peek followed by a conditional
 * `parseHxExpr(ctx)` call. Absence of the `=` leaves `decl.init`
 * as `null`, and the pre-existing var tests (from
 * `HaxeFirstSliceTest`) stay green because they all omit the init.
 *
 * Operators, calls, field access, float literals, and string
 * literals are explicitly out of scope for this slice.
 */
class HxExprSliceTest extends HxTestHelpers {

	public function testVarWithoutInit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int; }');
		Assert.equals('x', (decl.name : String));
		Assert.equals('Int', (decl.type.name : String));
		Assert.isNull(decl.init);
	}

	public function testVarWithIntInit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 42; }');
		Assert.equals('x', (decl.name : String));
		Assert.equals('Int', (decl.type.name : String));
		assertIntLit(decl.init, 42);
	}

	public function testVarWithBoolTrueInit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = true; }');
		assertBoolLit(decl.init, true);
	}

	public function testVarWithBoolFalseInit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = false; }');
		assertBoolLit(decl.init, false);
	}

	public function testVarWithNullInit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Ty = null; }');
		assertNullLit(decl.init);
	}

	public function testVarWithIdentInit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Ty = other; }');
		assertIdentExpr(decl.init, 'other');
	}

	public function testVarWithSpacedEquals():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 42 ; }');
		assertIntLit(decl.init, 42);
	}

	public function testVarWithoutSpaceAroundEquals():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int=42; }');
		assertIntLit(decl.init, 42);
	}

	public function testRejectsEmptyInit():Void {
		// `var x:Int = ;` — the `=` is consumed, the sub-rule
		// parseHxExpr(ctx) then sees `;` and every branch fails.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = ; }'), ParseError);
	}

	public function testRejectsMissingSemicolonAfterInit():Void {
		// `var x:Int = 42` — the VarMember's trailing `;` is missing;
		// `HxClassMember` fails and the outer loop fails.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = 42 }'), ParseError);
	}

	public function testMixedInitInClass():Void {
		final source:String = 'class Foo { var a:Int; var b:Bool = true; var c:Ty = null; var d:Int = 7; }';
		final ast:HxClassDecl = HaxeFastParser.parse(source);
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(4, ast.members.length);

		final a:HxVarDecl = expectVarMember(ast.members[0].member);
		Assert.equals('a', (a.name : String));
		Assert.isNull(a.init);

		final b:HxVarDecl = expectVarMember(ast.members[1].member);
		Assert.equals('b', (b.name : String));
		assertBoolLit(b.init, true);

		final c:HxVarDecl = expectVarMember(ast.members[2].member);
		Assert.equals('c', (c.name : String));
		assertNullLit(c.init);

		final d:HxVarDecl = expectVarMember(ast.members[3].member);
		Assert.equals('d', (d.name : String));
		assertIntLit(d.init, 7);
	}

	public function testInitAcrossModuleRoot():Void {
		final source:String = 'class A { var x:Int = 1; } class B { var y:Bool = false; }';
		final module:HxModule = HaxeModuleFastParser.parse(source);
		Assert.equals(2, module.decls.length);

		final a:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('A', (a.name : String));
		Assert.equals(1, a.members.length);
		final aVar:HxVarDecl = expectVarMember(a.members[0].member);
		Assert.equals('x', (aVar.name : String));
		assertIntLit(aVar.init, 1);

		final b:HxClassDecl = expectClassDecl(module.decls[1]);
		Assert.equals('B', (b.name : String));
		Assert.equals(1, b.members.length);
		final bVar:HxVarDecl = expectVarMember(b.members[0].member);
		Assert.equals('y', (bVar.name : String));
		assertBoolLit(bVar.init, false);
	}

	private function assertIntLit(expr:Null<HxExpr>, expected:Int):Void {
		switch expr {
			case IntLit(v): Assert.equals(expected, (v : Int));
			case null, _: Assert.fail('expected IntLit($expected), got $expr');
		}
	}

	private function assertBoolLit(expr:Null<HxExpr>, expected:Bool):Void {
		switch expr {
			case BoolLit(v): Assert.equals(expected, v);
			case null, _: Assert.fail('expected BoolLit($expected), got $expr');
		}
	}

	private function assertNullLit(expr:Null<HxExpr>):Void {
		switch expr {
			case NullLit: Assert.pass();
			case null, _: Assert.fail('expected NullLit, got $expr');
		}
	}

	private function assertIdentExpr(expr:Null<HxExpr>, expected:String):Void {
		switch expr {
			case IdentExpr(v): Assert.equals(expected, (v : String));
			case null, _: Assert.fail('expected IdentExpr($expected), got $expr');
		}
	}
}
