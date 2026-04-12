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
 * Phase 3 prefix-slice (γ) tests for the macro-generated Haxe parser.
 *
 * Covers unary-prefix operators `-`, `!`, `~` added on top of the 31
 * binary-infix baseline. The new `Prefix` strategy is annotate-only
 * (`prefix.op` namespace), and `Lowering.lowerEnumBranch` gained a
 * classifier case that runs before the existing Cases 1/2/4/3 — it
 * consumes the prefix literal, recurses into the enclosing atom
 * function, and constructs the ctor around the returned operand. The
 * recursion target is `parseHxExprAtom` for Pratt-enabled enums like
 * `HxExpr`, which is exactly the property these tests lock in.
 *
 * Grammar coverage in this file:
 *  - `-x`, `!x`, `~x` — per-op smoke with identifier operand.
 *  - `-5`, `-3.14`, `!true` — prefix composes with numeric and boolean
 *    atom leaves. FloatLit and IntLit both fail their regex on `-`,
 *    roll back, and let the prefix branch consume the literal before
 *    recursing.
 *  - `-x + 1`, `!x && y`, `~x | 1` — prefix applies before infix
 *    climb. These are the load-bearing Sub-2 correctness tests: the
 *    prefix recursion targets the ATOM function (`parseHxExprAtom`),
 *    not the loop (`parseHxExpr`), so the outer Pratt loop picks up
 *    the binary operator around the prefix result. Trees shape as
 *    `Add(Neg(x), 1)`, not `Neg(Add(x, 1))`.
 *  - `--x`, `!!x` — nested same-op prefix. Proves the atom recursion
 *    terminates and folds correctly.
 *  - `-!x` — mixed prefix. Each prefix branch tries its literal in
 *    source order; inner recursion into the atom function lets the
 *    next-in-source-order prefix consume its own literal.
 *  - `-(x + 1)` — prefix composes with `ParenExpr`. The parens reset
 *    precedence inside, so `x + 1` folds first, then the outer prefix
 *    wraps the paren atom.
 *  - `var x:Int = -5;` end-to-end through `HaxeModuleFastParser`.
 *  - Rejection: `var x:Int = - ;` — `-` consumes but the operand
 *    recursion trips on `;` and raises a ParseError.
 *
 */
class HxPrefixSliceTest extends HxTestHelpers {

	public function testNegIdent():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = -a; }');
		switch decl.init {
			case Neg(IdentExpr(v)): Assert.equals('a', (v : String));
			case null, _:
				Assert.fail('expected Neg(IdentExpr(a)), got ${decl.init}');
		}
	}

	public function testNotIdent():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = !a; }');
		switch decl.init {
			case Not(IdentExpr(v)): Assert.equals('a', (v : String));
			case null, _:
				Assert.fail('expected Not(IdentExpr(a)), got ${decl.init}');
		}
	}

	public function testBitNotIdent():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = ~a; }');
		switch decl.init {
			case BitNot(IdentExpr(v)): Assert.equals('a', (v : String));
			case null, _:
				Assert.fail('expected BitNot(IdentExpr(a)), got ${decl.init}');
		}
	}

	public function testNegInt():Void {
		// `-5` — IntLit fails on the leading `-` (regex `[0-9]+`
		// demands a digit at pos 0), rolls back, and the prefix
		// branch consumes the `-` before recursing into the atom
		// function for `5`.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = -5; }');
		switch decl.init {
			case Neg(IntLit(v)): Assert.equals(5, (v : Int));
			case null, _:
				Assert.fail('expected Neg(IntLit(5)), got ${decl.init}');
		}
	}

	public function testNegFloat():Void {
		// `-3.14` — FloatLit's regex `[0-9]+\.[0-9]+...` fails on
		// the leading `-` for the same reason as IntLit, and the
		// prefix branch consumes the `-` then recurses into the
		// atom function, where FloatLit matches `3.14` cleanly.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Float = -3.14; }');
		switch decl.init {
			case Neg(FloatLit(v)): Assert.floatEquals(3.14, (v : Float));
			case null, _:
				Assert.fail('expected Neg(FloatLit(3.14)), got ${decl.init}');
		}
	}

	public function testNotBool():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = !true; }');
		switch decl.init {
			case Not(BoolLit(v)): Assert.isTrue(v);
			case null, _:
				Assert.fail('expected Not(BoolLit(true)), got ${decl.init}');
		}
	}

	public function testNegBindsTighterThanAdd():Void {
		// `-x + 1` → Add(Neg(x), 1). The Pratt loop starts at
		// minPrec 0, calls parseHxExprAtom which returns `Neg(x)`
		// (Neg's body recursed back into parseHxExprAtom for `x`,
		// consuming only the single atom). The loop then sees `+`
		// at prec 8, recurses at minPrec 9 for the right operand,
		// and builds `Add(Neg(x), IntLit(1))`. A body that recursed
		// into parseHxExpr (the loop) instead of parseHxExprAtom
		// would have consumed `x + 1` as the operand and produced
		// the wrong `Neg(Add(x, 1))`.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = -a + 1; }');
		switch decl.init {
			case Add(Neg(IdentExpr(a)), IntLit(one)):
				Assert.equals('a', (a : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected Add(Neg(a), 1), got ${decl.init}');
		}
	}

	public function testNotBindsTighterThanAnd():Void {
		// `!a && b` → And(Not(a), b). Same Sub-2 correctness
		// property as testNegBindsTighterThanAdd, verified against
		// a lower-prec binary operator (`&&` at prec 4).
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = !a && b; }');
		switch decl.init {
			case And(Not(IdentExpr(a)), IdentExpr(b)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _:
				Assert.fail('expected And(Not(a), b), got ${decl.init}');
		}
	}

	public function testBitNotBindsTighterThanBitOr():Void {
		// `~a | 1` → BitOr(BitNot(a), 1). Same property against the
		// bitwise-or operator (`|` at prec 6), which shares a
		// prefix with the `|=` compound-assign landed in slice β.
		// The D33 longest-match sort still resolves `|` vs `|=`
		// correctly because the following character is `1`, not `=`.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = ~a | 1; }');
		switch decl.init {
			case BitOr(BitNot(IdentExpr(a)), IntLit(one)):
				Assert.equals('a', (a : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected BitOr(BitNot(a), 1), got ${decl.init}');
		}
	}

	public function testDoubleNeg():Void {
		// `--a` → Neg(Neg(a)). The outer Neg consumes `-` then
		// recurses into parseHxExprAtom, which tries every atom
		// branch in source order and eventually reaches the Neg
		// branch again: that inner call consumes the second `-`
		// and recurses once more for `a`. Atom recursion
		// terminates when the regex/literal branches finally
		// match without rolling back.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = --a; }');
		switch decl.init {
			case Neg(Neg(IdentExpr(a))): Assert.equals('a', (a : String));
			case null, _:
				Assert.fail('expected Neg(Neg(a)), got ${decl.init}');
		}
	}

	public function testDoubleNot():Void {
		// `!!a` → Not(Not(a)). Symmetric to testDoubleNeg for the
		// logical-not operator.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = !!a; }');
		switch decl.init {
			case Not(Not(IdentExpr(a))): Assert.equals('a', (a : String));
			case null, _:
				Assert.fail('expected Not(Not(a)), got ${decl.init}');
		}
	}

	public function testMixedPrefix():Void {
		// `-!a` → Neg(Not(a)). Outer Neg consumes `-`, inner atom
		// call tries branches in source order and reaches Not,
		// which consumes `!` and recurses again for the identifier.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = -!a; }');
		switch decl.init {
			case Neg(Not(IdentExpr(a))): Assert.equals('a', (a : String));
			case null, _:
				Assert.fail('expected Neg(Not(a)), got ${decl.init}');
		}
	}

	public function testNegParens():Void {
		// `-(a + 1)` → Neg(ParenExpr(Add(a, 1))). The outer Neg
		// consumes `-`, skipWs, then the atom recursion picks
		// ParenExpr (via the `@:wrap('(', ')')` Case 3 body), which
		// resets precedence inside to parse the whole `a + 1`
		// expression. The result is then wrapped back into ParenExpr
		// and handed to the outer Neg ctor.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = -(a + 1); }');
		switch decl.init {
			case Neg(ParenExpr(Add(IdentExpr(a), IntLit(one)))):
				Assert.equals('a', (a : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected Neg(ParenExpr(Add(a, 1))), got ${decl.init}');
		}
	}

	public function testNegIntInModule():Void {
		// End-to-end through `HaxeModuleFastParser` — confirms the
		// new prefix branches ship through the module root pipeline,
		// not just the isolated `HaxeFastParser`. Both parsers share
		// the same `HxExpr` rule because both grammars reference it
		// via `HxVarDecl.init`, so any macro-pipeline bug in the
		// prefix classifier would break both identically.
		final module:HxModule = HaxeModuleFastParser.parse('class Foo { var x:Int = -5; }');
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, cls.members.length);
		final decl:HxVarDecl = expectVarMember(cls.members[0].member);
		switch decl.init {
			case Neg(IntLit(v)): Assert.equals(5, (v : Int));
			case null, _:
				Assert.fail('expected Neg(IntLit(5)), got ${decl.init}');
		}
	}

	public function testRejectsLoneMinus():Void {
		// `var x:Int = - ;` — the prefix branch consumes `-` and
		// skipWs, then recurses into parseHxExprAtom for the
		// operand. Every atom branch trips on `;` (no literal, no
		// regex match), the atom function runs out of branches, and
		// the failExpr raises a ParseError that propagates out
		// through the prefix branch's try-wrapper in `tryBranch`.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = - ; }'), ParseError);
	}

}
