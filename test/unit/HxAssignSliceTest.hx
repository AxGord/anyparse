package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 assignment-slice tests for the macro-generated Haxe parser.
 *
 * Covers the first right-associative Pratt operators landed together
 * with the parens slice: `=`, `+=`, `-=`, all at precedence 1. The
 * `Pratt.annotate` strategy gained an optional third `@:infix` arg
 * (`'Left'` / `'Right'`, default `'Left'`), and `Lowering.lowerPrattLoop`
 * picks `nextMinPrec = prec` for right-associative branches instead of
 * `prec + 1` for left-associative, so same-prec chains fold right
 * instead of left.
 *
 * Grammar coverage in this slice:
 *  - `a = 1`, `a += 1`, `a -= 1` — per-op smoke for each new ctor.
 *  - `a = b = 1` — right-fold: `Assign(a, Assign(b, 1))`.
 *  - `a += b -= 1` — mixed-op right-fold.
 *  - `a = b + 1` — `+` binds tighter than `=`.
 *  - `a + 1 = 2` — lowest-precedence proof: `=` at prec 1 sits
 *    below `+` at prec 6, so the `+` subtree folds first and the
 *    whole `a + 1` ends up on the left of the `=`. The result has
 *    an `Add` as its `Assign` lvalue, which is semantically
 *    nonsensical but structurally correct — a later semantic pass
 *    would reject it. Note: this is a precedence check, not an
 *    associativity check — both left- and right-associative `=`
 *    produce the same shape here because the RHS (`2`) is a single
 *    atom with no same-prec chain. The real right-associativity
 *    proof is the `a = b = 1` test above.
 *  - `a = b == c` — `==` binds tighter than `=`.
 *  - `a = (b = c)` — cross-concept smoke with the parens slice.
 *  - `a = ;` — missing right operand rejected.
 */
class HxAssignSliceTest extends Test {

	public function new() {
		super();
	}

	public function testAssign():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a = 1; }');
		switch decl.init {
			case Assign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected Assign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testAddAssign():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a += 1; }');
		switch decl.init {
			case AddAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected AddAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testSubAssign():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a -= 1; }');
		switch decl.init {
			case SubAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected SubAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testRightAssocChain():Void {
		// a = b = 1 → Assign(a, Assign(b, 1)). The inner call is
		// `parseHxExpr(ctx, 1)` (prec, not prec + 1, because `=`
		// is right-associative), so the second `=` sits at the
		// same precedence as the outer and is absorbed by the
		// inner recursion — right-fold.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a = b = 1; }');
		switch decl.init {
			case Assign(IdentExpr(a), Assign(IdentExpr(b), IntLit(one))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected Assign(a, Assign(b, 1)), got ${decl.init}');
		}
	}

	public function testMixedRightAssocChain():Void {
		// a += b -= 1 → AddAssign(a, SubAssign(b, 1)). Same fold as
		// the homogeneous chain — the Pratt loop does not care that
		// the inner operator is a different ctor as long as it
		// resolves to the same right-associative precedence.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a += b -= 1; }');
		switch decl.init {
			case AddAssign(IdentExpr(a), SubAssign(IdentExpr(b), IntLit(one))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected AddAssign(a, SubAssign(b, 1)), got ${decl.init}');
		}
	}

	public function testAssignBindsLooserThanAdd():Void {
		// a = b + 1 → Assign(a, Add(b, 1)). `+` at prec 6 binds
		// tighter than `=` at prec 1, so the inner recursion folds
		// the whole `b + 1` before returning to the outer assign.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a = b + 1; }');
		switch decl.init {
			case Assign(IdentExpr(a), Add(IdentExpr(b), IntLit(one))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected Assign(a, Add(b, 1)), got ${decl.init}');
		}
	}

	public function testAssignWrapsAdditiveLvalue():Void {
		// a + 1 = 2 → Assign(Add(a, 1), 2). `+` at prec 6 binds
		// tighter than `=` at prec 1, so `a + 1` folds first inside
		// the inner loop; then the `=` at prec 1 is accepted by the
		// outer loop because its prec (1) is >= minPrec (0, the
		// default). The structural result has an `Add` as an lvalue,
		// which is semantically nonsensical — a later semantic pass
		// would reject it. The parser is structural-only; this test
		// locks in the lowest-precedence wrapping shape. Note that
		// associativity does not enter the picture here — the RHS
		// `2` is a single atom, so both left- and right-assoc `=`
		// would produce the same AST. Right-assoc is proved by
		// `testRightAssocChain` above (`a = b = 1`).
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a + 1 = 2; }');
		switch decl.init {
			case Assign(Add(IdentExpr(a), IntLit(one)), IntLit(two)):
				Assert.equals('a', (a : String));
				Assert.equals(1, (one : Int));
				Assert.equals(2, (two : Int));
			case null, _:
				Assert.fail('expected Assign(Add(a, 1), 2), got ${decl.init}');
		}
	}

	public function testAssignBindsLooserThanEq():Void {
		// a = b == c → Assign(a, Eq(b, c)). `==` at prec 5 binds
		// tighter than `=` at prec 1, so the comparison resolves
		// before the outer assign wraps it.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a = b == c; }');
		switch decl.init {
			case Assign(IdentExpr(a), Eq(IdentExpr(b), IdentExpr(c))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected Assign(a, Eq(b, c)), got ${decl.init}');
		}
	}

	public function testAssignInsideParens():Void {
		// a = (b = c) → Assign(a, ParenExpr(Assign(b, c))).
		// Cross-concept smoke proving that parens and right-assoc
		// compose. The parens force the inner assign to be an
		// atom from the outer loop's point of view, which the
		// outer assign then consumes as its right operand.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a = (b = c); }');
		switch decl.init {
			case Assign(IdentExpr(a), ParenExpr(Assign(IdentExpr(b), IdentExpr(c)))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected Assign(a, ParenExpr(Assign(b, c))), got ${decl.init}');
		}
	}

	public function testRejectsAssignWithoutRhs():Void {
		// `a = ;` — the assign operator matches, skipWs runs, and
		// then the right-hand `parseHxExpr` tries every atom branch
		// and fails on the `;` terminator.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = a = ; }'), ParseError);
	}

	private function parseSingleVarDecl(source:String):HxVarDecl {
		final ast:HxClassDecl = HaxeFastParser.parse(source);
		Assert.equals(1, ast.members.length);
		return expectVarMember(ast.members[0]);
	}

	private function expectVarMember(member:HxClassMember):HxVarDecl {
		return switch member {
			case VarMember(decl): decl;
			case _: throw 'expected VarMember, got $member';
		};
	}
}
