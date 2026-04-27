package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;

/**
 * Tests for slice ω-fn-return-body — adds `HxExpr.ReturnExpr(value:HxExpr)`
 * with `@:kw('return')` so a `return`-led expression is now a first-class
 * `HxExpr` atom. The slice's user-visible payoff is `function f() return X;`
 * shorthand bodies, which now parse through the existing
 * `HxFnBody.ExprBody` branch (landed in ω-fn-expr-body) — `ExprBody`'s
 * fall-through dispatch runs the full `HxExpr` parser, which now sees
 * `return X` as a kw-led atom (sibling to `UntypedExpr` /
 * `CastExpr`). No `HxFnBody` change was required.
 *
 * Statement-level `return X;` is unaffected: the surrounding
 * `HxStatement` Alt has `ReturnStmt @:kw('return') @:trail(';')` declared
 * before the catch-all `ExprStmt`, so source-order dispatch still routes
 * statement-position input through `ReturnStmt(value:HxExpr)`. A regression
 * test pins this — `class M { function f() { return 1; } }` must keep
 * its `ReturnStmt` shape, NOT promote to `ExprStmt(ReturnExpr(...))`.
 *
 * Pratt absorption: `return` binds at HxExpr-atom level (kw-led with
 * single `HxExpr` operand), so the operand recurses through `parseHxExpr`
 * — `return x + 1` parses as `ReturnExpr(Add(x, 1))`, matching real Haxe
 * semantics where the whole RHS expression is the returned value.
 *
 * Out of scope:
 *  - `function f():Void return;` — void return body. Requires either
 *    `?value:HxExpr` (creates statement-level dispatch ambiguity vs
 *    `VoidReturnStmt`) or a separate `HxFnBody.VoidReturnBody @:kw('return')
 *    @:lit(';')` ctor. Deferred.
 */
class HxFnReturnBodySliceTest extends HxTestHelpers {

	// ======== Class-member position ========

	public function testClassMemberReturnBodyTyped():Void {
		final ast:HxModule = HaxeModuleParser.parse('class Main {\n\tstatic function f():Int return 1;\n}');
		assertReturnExprBody(parseSingleFnFromOnlyClass(ast).body);
	}

	public function testClassMemberReturnBodyNoType():Void {
		final ast:HxModule = HaxeModuleParser.parse('class C {\n\tfunction f() return 1;\n}');
		assertReturnExprBody(parseSingleFnFromOnlyClass(ast).body);
	}

	public function testClassMemberReturnBodyComplex():Void {
		// Pratt absorption: `return x + 1` → ReturnExpr(Add(x, 1)).
		final ast:HxModule = HaxeModuleParser.parse('class C {\n\tstatic function f(x:Int):Int return x + 1;\n}');
		final inner:HxExpr = unwrapReturnExpr(parseSingleFnFromOnlyClass(ast).body);
		switch inner {
			case Add(_, _): Assert.pass();
			case _: Assert.fail('expected return value Add(_, _), got $inner');
		}
	}

	// ======== Top-level position ========

	public function testToplevelFnReturnBody():Void {
		final ast:HxModule = HaxeModuleParser.parse('function f():Int return 42;');
		Assert.equals(1, ast.decls.length);
		switch ast.decls[0].decl {
			case FnDecl(decl): assertReturnExprBody(decl.body);
			case _: Assert.fail('expected FnDecl, got ${ast.decls[0].decl}');
		}
	}

	// ======== Statement-level non-regression ========

	public function testStatementLevelReturnUnchanged():Void {
		// `return 1;` inside a block must still parse as ReturnStmt, NOT
		// as ExprStmt(ReturnExpr(...)). HxStatement source order has
		// ReturnStmt @:kw('return') BEFORE the ExprStmt fall-through.
		final ast:HxModule = HaxeModuleParser.parse('class C {\n\tfunction f() {\n\t\treturn 1;\n\t}\n}');
		final fn:HxFnDecl = parseSingleFnFromOnlyClass(ast);
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ReturnStmt(_): Assert.pass();
			case _: Assert.fail('expected ReturnStmt, got ${stmts[0]}');
		}
	}

	// ======== Round-trip ========

	public function testRoundTripReturnBodyClass():Void {
		roundTrip('class Main {\n\tstatic function f():Int return 1;\n}');
	}

	public function testRoundTripReturnBodyNoType():Void {
		roundTrip('class C {\n\tfunction f() return 1;\n}');
	}

	public function testRoundTripReturnBodyComplex():Void {
		roundTrip('class C {\n\tstatic function f(x:Int):Int return x + 1;\n}');
	}

	public function testRoundTripReturnBodyToplevel():Void {
		roundTrip('function f():Int return 42;');
	}

	public function testRoundTripStatementReturnUnchanged():Void {
		roundTrip('class C {\n\tfunction f() {\n\t\treturn 1;\n\t}\n}');
	}

	// ======== Helpers ========

	private function parseSingleFnFromOnlyClass(ast:HxModule):HxFnDecl {
		Assert.equals(1, ast.decls.length);
		final cls:HxClassDecl = expectClassDecl(ast.decls[0]);
		Assert.equals(1, cls.members.length);
		return expectFnMember(cls.members[0].member);
	}

	private function assertReturnExprBody(body:HxFnBody):Void {
		switch body {
			case ExprBody(ReturnExpr(_)): Assert.pass();
			case _: Assert.fail('expected ExprBody(ReturnExpr(...)), got $body');
		}
	}

	private function unwrapReturnExpr(body:HxFnBody):HxExpr {
		return switch body {
			case ExprBody(ReturnExpr(value)): value;
			case _: throw 'expected ExprBody(ReturnExpr(...)), got $body';
		};
	}
}
