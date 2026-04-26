package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxThinParenLambda;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Tests for the canonical Haxe arrow-lambda syntax: `->` body
 * separator and infix operator. Companion to `HxArrowArraySliceTest`
 * which covers the legacy `=>` form (kept active for map literals
 * and pre-existing test data).
 *
 * Two new `HxExpr` branches:
 *
 *  - `ThinArrow` — `@:infix('->', 0, 'Right')`. Handles single-ident
 *    arrow lambdas (`x -> x + 1`).
 *  - `ThinParenLambdaExpr` — bare-Ref Case 3 wrapping
 *    `HxThinParenLambda` typedef. Covers zero-, single-, multi-, and
 *    typed-param lambdas with `->` body.
 *
 * Source order in `HxExpr`:
 *  - `ThinParenLambdaExpr` BEFORE `ParenLambdaExpr` BEFORE `ParenExpr`
 *    so `tryBranch` tries the canonical `->` form first and falls
 *    through to the `=>` form, then to `ParenExpr`.
 *  - `ThinArrow` BEFORE `Arrow` in the operator list (D33 longest-
 *    match isn't load-bearing here — the literals don't share a
 *    prefix — but the canonical form still wins on declaration order).
 */
class HxThinArrowSliceTest extends HxTestHelpers {

	// ======== ThinArrow — single-ident lambda ========

	/** `x -> x + 1` -> ThinArrow(IdentExpr("x"), Add(IdentExpr("x"), IntLit(1))). */
	public function testSingleIdentThinArrow():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = x -> x + 1; }');
		switch decl.init {
			case ThinArrow(IdentExpr(l), Add(IdentExpr(r1), IntLit(r2))):
				Assert.equals('x', (l : String));
				Assert.equals('x', (r1 : String));
				Assert.equals(1, (r2 : Int));
			case null, _: Assert.fail('expected ThinArrow(IdentExpr, Add), got ${decl.init}');
		}
	}

	/** `x -> y -> x + y` -> right-associative nesting. */
	public function testThinArrowRightAssoc():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = x -> y -> x + y; }');
		switch decl.init {
			case ThinArrow(IdentExpr(x), ThinArrow(IdentExpr(y), Add(_, _))):
				Assert.equals('x', (x : String));
				Assert.equals('y', (y : String));
			case null, _: Assert.fail('expected ThinArrow(x, ThinArrow(y, Add)), got ${decl.init}');
		}
	}

	/** `a = b -> c` -> Assign(a, ThinArrow(b, c)). */
	public function testAssignVsThinArrow():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = a = b -> c; }');
		switch decl.init {
			case Assign(IdentExpr(a), ThinArrow(IdentExpr(b), IdentExpr(c))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _: Assert.fail('expected Assign(a, ThinArrow(b, c)), got ${decl.init}');
		}
	}

	/** Subtraction must not accidentally match `->` — `a - b` stays Sub. */
	public function testSubVsThinArrow():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = a - b; }');
		switch decl.init {
			case Sub(IdentExpr(a), IdentExpr(b)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _: Assert.fail('expected Sub(a, b), got ${decl.init}');
		}
	}

	/** `a -> -b` — thin arrow with prefix `-` on the right. */
	public function testThinArrowWithPrefixNeg():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = a -> -b; }');
		switch decl.init {
			case ThinArrow(IdentExpr(a), Neg(IdentExpr(b))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _: Assert.fail('expected ThinArrow(a, Neg(b)), got ${decl.init}');
		}
	}

	/** Whitespace tolerance around `->`. */
	public function testThinArrowWhitespace():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = x  ->  x; }');
		switch decl.init {
			case ThinArrow(IdentExpr(l), IdentExpr(r)):
				Assert.equals('x', (l : String));
				Assert.equals('x', (r : String));
			case null, _: Assert.fail('expected ThinArrow(x, x)');
		}
	}

	/** ThinArrow in return statement. */
	public function testThinArrowInReturn():Void {
		final ast:HxClassDecl = HaxeParser.parse('class C { function f():Int { return x -> x; } }');
		final fn:HxFnDecl = expectFnMember(ast.members[0].member);
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ReturnStmt(ThinArrow(IdentExpr(l), IdentExpr(r))):
				Assert.equals('x', (l : String));
				Assert.equals('x', (r : String));
			case null, _: Assert.fail('expected ReturnStmt(ThinArrow)');
		}
	}

	// ======== ThinParenLambdaExpr ========

	/** `() -> 42` -> zero-param thin lambda. */
	public function testZeroParamThinLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = () -> 42; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(0, lambda.params.length);
				switch lambda.body {
					case IntLit(v): Assert.equals(42, (v : Int));
					case null, _: Assert.fail('expected IntLit body');
				}
			case null, _: Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `(x) -> x + 1` -> single-param paren thin lambda. */
	public function testSingleParenThinLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x) -> x + 1; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
				Assert.isNull(lambda.params[0].type);
			case null, _: Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `(x, y) -> x + y` -> multi-param thin lambda. */
	public function testMultiParamThinLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x, y) -> x + y; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(2, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
				Assert.equals('y', (lambda.params[1].name : String));
				switch lambda.body {
					case Add(IdentExpr(l), IdentExpr(r)):
						Assert.equals('x', (l : String));
						Assert.equals('y', (r : String));
					case null, _: Assert.fail('expected Add body');
				}
			case null, _: Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `(x:Int) -> x` -> typed-param thin lambda. */
	public function testTypedParamThinLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x:Int) -> x; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
				Assert.notNull(lambda.params[0].type);
			case null, _: Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `(x:Int, y:String) -> x` -> multi typed params. */
	public function testMultiTypedParamThinLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x:Int, y:String) -> x; }');
		switch decl.init {
			case ThinParenLambdaExpr(lambda):
				Assert.equals(2, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
				Assert.notNull(lambda.params[0].type);
				Assert.equals('y', (lambda.params[1].name : String));
				Assert.notNull(lambda.params[1].type);
			case null, _: Assert.fail('expected ThinParenLambdaExpr, got ${decl.init}');
		}
	}

	/** `return (x) -> x;` -> thin lambda in return. */
	public function testParenThinLambdaInReturn():Void {
		final ast:HxClassDecl = HaxeParser.parse('class C { function f():Int { return (x) -> x; } }');
		final fn:HxFnDecl = expectFnMember(ast.members[0].member);
		final stmts:Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ReturnStmt(ThinParenLambdaExpr(lambda)):
				Assert.equals(1, lambda.params.length);
			case null, _: Assert.fail('expected ReturnStmt(ThinParenLambdaExpr)');
		}
	}

	/** `(x + 1)` still parses as ParenExpr — neither thin nor fat lambda. */
	public function testParenExprNotThinLambda():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x + 1); }');
		switch decl.init {
			case ParenExpr(Add(_, _)): Assert.pass();
			case null, _: Assert.fail('expected ParenExpr(Add), got ${decl.init}');
		}
	}

	// ======== Coexistence with the `=>` form ========

	/** `x => x` still resolves to `Arrow`, not `ThinArrow`. */
	public function testFatArrowStillWorks():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = x => x; }');
		switch decl.init {
			case Arrow(IdentExpr(l), IdentExpr(r)):
				Assert.equals('x', (l : String));
				Assert.equals('x', (r : String));
			case null, _: Assert.fail('expected Arrow(x, x), got ${decl.init}');
		}
	}

	/** `(x) => x` still resolves to `ParenLambdaExpr`, not `ThinParenLambdaExpr`. */
	public function testFatParenLambdaStillWorks():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Int = (x) => x; }');
		switch decl.init {
			case ParenLambdaExpr(lambda):
				Assert.equals(1, lambda.params.length);
				Assert.equals('x', (lambda.params[0].name : String));
			case null, _: Assert.fail('expected ParenLambdaExpr, got ${decl.init}');
		}
	}

}
