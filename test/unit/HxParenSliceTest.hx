package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 parens-slice tests for the macro-generated Haxe parser.
 *
 * Covers the new `ParenExpr` atom branch. Parens are added to the
 * `HxExpr` grammar as `@:wrap('(', ')') ParenExpr(inner:HxExpr)`,
 * which flows through the existing `Lowering.lowerEnumBranch` Case 3
 * single-`Ref` wrapping path — no Lowering-level change was needed.
 * These tests validate both that the path exists and that the
 * resulting AST groups correctly under the Pratt precedence machinery.
 *
 * Grammar coverage in this slice:
 *  - `(1)` — smoke.
 *  - `(1 + 2)` — parens around a Pratt expression.
 *  - `1 * (2 + 3)` — precedence override: the group is atomic so the
 *    outer `*` binds the whole paren as its right operand.
 *  - `((1))` — nesting.
 *  - `( 1 + 2 )` — whitespace tolerance inside the group.
 *  - `(1 +;` — unmatched-paren rejection.
 */
class HxParenSliceTest extends HxTestHelpers {

	public function testBareIntInParens():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = (1); }');
		switch decl.init {
			case ParenExpr(IntLit(v)):
				Assert.equals(1, (v : Int));
			case null, _:
				Assert.fail('expected ParenExpr(IntLit(1)), got ${decl.init}');
		}
	}

	public function testSumInParens():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = (1 + 2); }');
		switch decl.init {
			case ParenExpr(Add(IntLit(l), IntLit(r))):
				Assert.equals(1, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected ParenExpr(Add(1, 2)), got ${decl.init}');
		}
	}

	public function testParensOverridePrecedence():Void {
		// 1 * (2 + 3) → Mul(1, ParenExpr(Add(2, 3))). Without parens
		// the same tokens parse as Add(Mul(1, 2), 3) because `*` has
		// higher precedence than `+`. The paren group is an atom from
		// the outer loop's point of view, so `*` binds the whole group.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 1 * (2 + 3); }');
		switch decl.init {
			case Mul(IntLit(a), ParenExpr(Add(IntLit(b), IntLit(c)))):
				Assert.equals(1, (a : Int));
				Assert.equals(2, (b : Int));
				Assert.equals(3, (c : Int));
			case null, _:
				Assert.fail('expected Mul(1, ParenExpr(Add(2, 3))), got ${decl.init}');
		}
	}

	public function testNestedParens():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = ((1)); }');
		switch decl.init {
			case ParenExpr(ParenExpr(IntLit(v))):
				Assert.equals(1, (v : Int));
			case null, _:
				Assert.fail('expected ParenExpr(ParenExpr(IntLit(1))), got ${decl.init}');
		}
	}

	public function testWhitespaceInsideParens():Void {
		// `(  1  +  2  )` — the Lowering Case 3 body emits skipWs
		// before the inner call and before the closing `)`. The
		// outer whitespace policy (`@:ws` on `HxClassDecl`) carries
		// into the sub-rule via the same `skipWs` calls Lowering
		// inlines between operator literals.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = (  1  +  2  ); }');
		switch decl.init {
			case ParenExpr(Add(IntLit(l), IntLit(r))):
				Assert.equals(1, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected ParenExpr(Add(1, 2)), got ${decl.init}');
		}
	}

	public function testRejectsUnmatchedParen():Void {
		// `(1 +;` — open paren, int, operator without right operand,
		// no matching close. `parseHxExprAtom` on the right side of
		// `+` fails to find any atom and throws, which propagates
		// out of the enum-branch try/catch and fails the whole parse.
		Assert.raises(() -> HaxeParser.parse('class Foo { var x:Int = (1 +; }'), ParseError);
	}

}
