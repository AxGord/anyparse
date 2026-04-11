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
 * Phase 3 Pratt-operator-expansion tests for the macro-generated
 * Haxe parser.
 *
 * Covers the nine new binary-infix operators added alongside the
 * baseline `+ - * /` set: `%` at prec 7, the six comparison
 * operators (`== != <= >= < >`) at prec 5, `&&` at prec 4, and `||`
 * at prec 3. Also guards the longest-match sort inside
 * `Lowering.lowerPrattLoop` that disambiguates `<=` vs `<` and
 * `>=` vs `>` at dispatch time.
 *
 * The baseline `+ - * /` set stays covered by `HxPrattSliceTest`;
 * that file doubles as the regression suite for the original Pratt
 * slice and the word-boundary fix on `@:lit`. This file is
 * additive — it does not re-test the baseline operators.
 *
 * Test groups:
 *  - per-operator smoke for every new ctor
 *  - longest-match disambiguation (`<=`, `>=`, `<`, `>`)
 *  - cross-level precedence between comparison, logical, additive,
 *    and multiplicative
 *  - left-associative chains at the new precedence levels
 *  - `%` binds at the multiplicative level (parity with `*` and `/`)
 *  - rejections for malformed input
 */
class HxPrattOpsTest extends Test {

	public function new() {
		super();
	}

	// -------- per-operator smoke --------

	public function testMod():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 10 % 3; }');
		switch decl.init {
			case Mod(IntLit(l), IntLit(r)):
				Assert.equals(10, (l : Int));
				Assert.equals(3, (r : Int));
			case null, _:
				Assert.fail('expected Mod(10, 3), got ${decl.init}');
		}
	}

	public function testEq():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 == 2; }');
		switch decl.init {
			case Eq(IntLit(l), IntLit(r)):
				Assert.equals(1, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected Eq(1, 2), got ${decl.init}');
		}
	}

	public function testNotEq():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 != 2; }');
		switch decl.init {
			case NotEq(IntLit(l), IntLit(r)):
				Assert.equals(1, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected NotEq(1, 2), got ${decl.init}');
		}
	}

	public function testLt():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 < 2; }');
		switch decl.init {
			case Lt(IntLit(l), IntLit(r)):
				Assert.equals(1, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected Lt(1, 2), got ${decl.init}');
		}
	}

	public function testLtEq():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 <= 2; }');
		switch decl.init {
			case LtEq(IntLit(l), IntLit(r)):
				Assert.equals(1, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected LtEq(1, 2), got ${decl.init}');
		}
	}

	public function testGt():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 2 > 1; }');
		switch decl.init {
			case Gt(IntLit(l), IntLit(r)):
				Assert.equals(2, (l : Int));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected Gt(2, 1), got ${decl.init}');
		}
	}

	public function testGtEq():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 2 >= 1; }');
		switch decl.init {
			case GtEq(IntLit(l), IntLit(r)):
				Assert.equals(2, (l : Int));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected GtEq(2, 1), got ${decl.init}');
		}
	}

	public function testAnd():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = true && false; }');
		switch decl.init {
			case And(BoolLit(l), BoolLit(r)):
				Assert.isTrue((l : Bool));
				Assert.isFalse((r : Bool));
			case null, _:
				Assert.fail('expected And(true, false), got ${decl.init}');
		}
	}

	public function testOr():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = true || false; }');
		switch decl.init {
			case Or(BoolLit(l), BoolLit(r)):
				Assert.isTrue((l : Bool));
				Assert.isFalse((r : Bool));
			case null, _:
				Assert.fail('expected Or(true, false), got ${decl.init}');
		}
	}

	// -------- longest-match disambiguation --------

	public function testLtEqNotLtFollowedByEq():Void {
		// Core regression guard for the longest-match sort in
		// `lowerPrattLoop`. Without the sort, `matchLit(ctx, "<")`
		// succeeds on `<=` first, consumes one char, and leaves `=`
		// stranded for the right operand parser. With the sort,
		// `<=` is attempted before `<` in the dispatch chain.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 <= 2; }');
		switch decl.init {
			case LtEq(IntLit(_), IntLit(_)): Assert.pass();
			case Lt(_, _):
				Assert.fail('longest-match regression: `<=` dispatched as `<`, got ${decl.init}');
			case null, _:
				Assert.fail('expected LtEq(1, 2), got ${decl.init}');
		}
	}

	public function testGtEqNotGtFollowedByEq():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 2 >= 1; }');
		switch decl.init {
			case GtEq(IntLit(_), IntLit(_)): Assert.pass();
			case Gt(_, _):
				Assert.fail('longest-match regression: `>=` dispatched as `>`, got ${decl.init}');
			case null, _:
				Assert.fail('expected GtEq(2, 1), got ${decl.init}');
		}
	}

	public function testShortLtStillWorks():Void {
		// Guard: the longest-match sort must not break the short
		// form. `1 < 2` has no trailing `=`, so the dispatch chain
		// skips `<=` and falls through to `<` cleanly.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 < 2; }');
		switch decl.init {
			case Lt(IntLit(_), IntLit(_)): Assert.pass();
			case null, _: Assert.fail('expected Lt, got ${decl.init}');
		}
	}

	public function testShortGtStillWorks():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 2 > 1; }');
		switch decl.init {
			case Gt(IntLit(_), IntLit(_)): Assert.pass();
			case null, _: Assert.fail('expected Gt, got ${decl.init}');
		}
	}

	// -------- cross-level precedence --------

	public function testAddTighterThanEq():Void {
		// 1 + 2 == 3 → Eq(Add(1, 2), 3). Additive (prec 6) binds
		// tighter than comparison (prec 5).
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 + 2 == 3; }');
		switch decl.init {
			case Eq(Add(IntLit(a), IntLit(b)), IntLit(c)):
				Assert.equals(1, (a : Int));
				Assert.equals(2, (b : Int));
				Assert.equals(3, (c : Int));
			case null, _:
				Assert.fail('expected Eq(Add(1, 2), 3), got ${decl.init}');
		}
	}

	public function testMulAddEqThreeLevels():Void {
		// 1 * 2 + 3 == 4 → Eq(Add(Mul(1, 2), 3), 4). Exercises three
		// precedence levels in a single expression.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 * 2 + 3 == 4; }');
		switch decl.init {
			case Eq(Add(Mul(IntLit(a), IntLit(b)), IntLit(c)), IntLit(d)):
				Assert.equals(1, (a : Int));
				Assert.equals(2, (b : Int));
				Assert.equals(3, (c : Int));
				Assert.equals(4, (d : Int));
			case null, _:
				Assert.fail('expected Eq(Add(Mul(1, 2), 3), 4), got ${decl.init}');
		}
	}

	public function testEqTighterThanAnd():Void {
		// a == b && c == d → And(Eq(a, b), Eq(c, d)). Comparison
		// (prec 5) binds tighter than logical-and (prec 4), so the
		// outer `&&` gets two equality sub-expressions.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = a == b && c == d; }');
		switch decl.init {
			case And(Eq(IdentExpr(a), IdentExpr(b)), Eq(IdentExpr(c), IdentExpr(d))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
				Assert.equals('d', (d : String));
			case null, _:
				Assert.fail('expected And(Eq(a, b), Eq(c, d)), got ${decl.init}');
		}
	}

	public function testAndTighterThanOr():Void {
		// a || b && c → Or(a, And(b, c)). Logical-and (prec 4) binds
		// tighter than logical-or (prec 3).
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = a || b && c; }');
		switch decl.init {
			case Or(IdentExpr(a), And(IdentExpr(b), IdentExpr(c))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected Or(a, And(b, c)), got ${decl.init}');
		}
	}

	// -------- left-associative chains --------

	public function testLeftAssocEq():Void {
		// 1 == 2 == 3 → Eq(Eq(1, 2), 3). Syntactically valid, semantically
		// weird, but guards left-assoc correctness at the new comparison
		// precedence level.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 == 2 == 3; }');
		switch decl.init {
			case Eq(Eq(IntLit(a), IntLit(b)), IntLit(c)):
				Assert.equals(1, (a : Int));
				Assert.equals(2, (b : Int));
				Assert.equals(3, (c : Int));
			case null, _:
				Assert.fail('expected Eq(Eq(1, 2), 3), got ${decl.init}');
		}
	}

	public function testLeftAssocOr():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = a || b || c; }');
		switch decl.init {
			case Or(Or(IdentExpr(a), IdentExpr(b)), IdentExpr(c)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected Or(Or(a, b), c), got ${decl.init}');
		}
	}

	public function testLeftAssocAnd():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = a && b && c; }');
		switch decl.init {
			case And(And(IdentExpr(a), IdentExpr(b)), IdentExpr(c)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected And(And(a, b), c), got ${decl.init}');
		}
	}

	// -------- `%` parity with `*` / `/` --------

	public function testModTighterThanAdd():Void {
		// 10 % 3 + 1 → Add(Mod(10, 3), 1). `%` sits at prec 7 along
		// with `*` and `/`, so it binds tighter than `+`.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 10 % 3 + 1; }');
		switch decl.init {
			case Add(Mod(IntLit(a), IntLit(b)), IntLit(c)):
				Assert.equals(10, (a : Int));
				Assert.equals(3, (b : Int));
				Assert.equals(1, (c : Int));
			case null, _:
				Assert.fail('expected Add(Mod(10, 3), 1), got ${decl.init}');
		}
	}

	public function testAddThenMod():Void {
		// 10 + 3 % 2 → Add(10, Mod(3, 2)). The same precedence rule
		// applied on the right side of the additive operator.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 10 + 3 % 2; }');
		switch decl.init {
			case Add(IntLit(a), Mod(IntLit(b), IntLit(c))):
				Assert.equals(10, (a : Int));
				Assert.equals(3, (b : Int));
				Assert.equals(2, (c : Int));
			case null, _:
				Assert.fail('expected Add(10, Mod(3, 2)), got ${decl.init}');
		}
	}

	// -------- rejections --------

	public function testRejectsTrailingLt():Void {
		// `1 <;` — `<` matches, right operand parser fails on `;`.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Bool = 1 <; }'), ParseError);
	}

	public function testRejectsLeadingLtEq():Void {
		// `<= 1;` — atom parser tries every branch, all fail on `<`
		// because the identifier regex rejects it and no literal
		// matches it as an atom.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Bool = <= 1; }'), ParseError);
	}

	// -------- helpers --------

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
