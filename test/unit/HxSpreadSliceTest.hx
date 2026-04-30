package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;

/**
 * Spread / rest operator `...` parse + write tests.
 *
 * Two grammar additions land together:
 *
 *  - `HxParam.Rest(body:HxParamBody)` with `@:lead('...')` for the
 *    parameter-declaration form `function f(...r:Type)` (Haxe 4.2+
 *    rest / varargs).
 *  - `HxExpr.Spread(operand:HxExpr)` with `@:prefix('...')` for the
 *    call-site form `f(...args)` and similar argument-position spread.
 *
 * The two ctors share the `...` literal but live on different code
 * paths: param parsing dispatches on `@:lead` per Alt-enum branch
 * before any field is consumed, while expression parsing dispatches
 * on `@:prefix` from the atom parser. The infix `Interval(_, _)`
 * (`@:infix('...', 5)`) lives in the Pratt loop and only fires after
 * an atom is already parsed — so `0...10` (range) and `...x` (spread)
 * never compete on the same lookahead site.
 */
class HxSpreadSliceTest extends HxTestHelpers {

	// ---------- Rest parameter ----------

	public function testRestParamSingle():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(...r:Int):Void {} }');
		Assert.equals(1, decl.params.length);
		final body = expectRestParam(decl.params[0]);
		Assert.equals('r', (body.name : String));
		Assert.equals('Int', (expectNamedType(body.type).name : String));
		Assert.isNull(body.defaultValue);
	}

	public function testRestParamWithRequiredHead():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(a:Int, ...r:Int):Void {} }');
		Assert.equals(2, decl.params.length);
		Assert.equals('a', (expectRequiredParam(decl.params[0]).name : String));
		final tail = expectRestParam(decl.params[1]);
		Assert.equals('r', (tail.name : String));
		Assert.equals('Int', (expectNamedType(tail.type).name : String));
	}

	public function testRestParamMixedWithOptional():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(a:Int, ?b:Int, ...r:Int):Void {} }');
		Assert.equals(3, decl.params.length);
		Assert.equals('a', (expectRequiredParam(decl.params[0]).name : String));
		Assert.equals('b', (expectOptionalParam(decl.params[1]).name : String));
		Assert.equals('r', (expectRestParam(decl.params[2]).name : String));
	}

	public function testRestParamWithGenericType():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f(...r:Array<Int>):Void {} }');
		Assert.equals(1, decl.params.length);
		final body = expectRestParam(decl.params[0]);
		Assert.equals('r', (body.name : String));
		final ref = expectNamedType(body.type);
		Assert.equals('Array', (ref.name : String));
	}

	public function testRestParamWhitespaceTolerant():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class Foo { function f( ... r : Int ):Void {} }');
		Assert.equals(1, decl.params.length);
		Assert.equals('r', (expectRestParam(decl.params[0]).name : String));
	}

	// ---------- Spread expression ----------

	public function testSpreadInCallArg():Void {
		final decl:HxFnDecl = parseSingleFnDecl('class M { static function m() { f(...args); } }');
		final stmts = fnBodyStmts(decl);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ExprStmt(Call(_, args)):
				Assert.equals(1, args.length);
				switch args[0] {
					case Spread(IdentExpr(name)):
						Assert.equals('args', (name : String));
					case _:
						Assert.fail('expected Spread(IdentExpr), got ${args[0]}');
				}
			case _:
				Assert.fail('expected ExprStmt(Call(_, [Spread(_)])), got ${stmts[0]}');
		}
	}

	public function testSpreadOfPostfixChain():Void {
		// Operand is a postfix-extended atom (FieldAccess + Call). The
		// `@:prefix` recurses into `parseHxExprAtom`, which captures the
		// full postfix chain in one step.
		final decl:HxFnDecl = parseSingleFnDecl('class M { static function m() { f(...rest.append(999)); } }');
		final stmts = fnBodyStmts(decl);
		switch stmts[0] {
			case ExprStmt(Call(_, [Spread(Call(FieldAccess(IdentExpr(_), _), _))])):
				Assert.pass();
			case _:
				Assert.fail('expected Spread(Call(FieldAccess(...))), got ${stmts[0]}');
		}
	}

	public function testIntervalStillBindsAsInfix():Void {
		// Sanity: `0...10` must remain `Interval(IntLit(0), IntLit(10))`,
		// NOT `Spread` followed by `IntLit(10)`. Prefix `...` only fires
		// from the atom parser; the Pratt loop sees `...` as the
		// `Interval` infix when an atom (`0`) is already on the stack.
		final decl:HxFnDecl = parseSingleFnDecl('class M { static function m() { for (i in 0...10) {} } }');
		final stmts = fnBodyStmts(decl);
		switch stmts[0] {
			case ForStmt(stmt):
				switch stmt.iterable {
					case Interval(IntLit(_), IntLit(_)): Assert.pass();
					case _: Assert.fail('expected Interval iterable, got ${stmt.iterable}');
				}
			case _:
				Assert.fail('expected ForStmt, got ${stmts[0]}');
		}
	}

	// ---------- Round-trip ----------

	public function testRestAndSpreadRoundTrip():Void {
		roundTrip('class Foo { function f(...r:Int):Void {} }', 'rest-single');
		roundTrip('class Foo { function f(a:Int, ...r:Int):Void {} }', 'rest-after-required');
		roundTrip('class Foo { function f(a:Int, ?b:Int, ...r:Int):Void {} }', 'rest-after-mixed');
		roundTrip('class Foo { function f(...r:Array<Int>):Void {} }', 'rest-generic');
		roundTrip('class M { static function m() { f(...args); } }', 'spread-call');
		roundTrip('class M { static function m() { f(...rest.append(999)); } }', 'spread-call-chain');
		roundTrip('class M { static function m() { for (i in 0...10) trace(i); } }', 'interval-non-regression');
	}
}
