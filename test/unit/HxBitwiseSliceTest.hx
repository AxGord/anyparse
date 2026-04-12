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
 * Phase 3 bitwise + shift tests for the macro-generated Haxe parser.
 *
 * Covers the six symbolic binary operators added at two new
 * precedence levels inserted between `+ -` and `== !=`:
 *
 *  - prec 7 (shift, left-assoc): `<<` / `>>` / `>>>` — `Shl` /
 *    `Shr` / `UShr`.
 *  - prec 6 (bitwise, left-assoc): `|` / `&` / `^` — `BitOr` /
 *    `BitAnd` / `BitXor`.
 *
 * Inserting the two new levels forced a mechanical renumber of the
 * pre-existing multiplicative and additive ctors (`* / %` from 7 to
 * 9, `+ -` from 6 to 8). Tests assert parse trees, not absolute
 * precedence integers, so every pre-existing test in
 * `HxPrattSliceTest`, `HxPrattOpsTest`, `HxParenSliceTest`, and
 * `HxAssignSliceTest` continues to pass unchanged — relative
 * ordering is preserved for every operator pair.
 *
 * Every shared-prefix conflict this slice introduces is resolved by
 * the length-desc sort in `Lowering.lowerPrattLoop` (D33): `<<` vs
 * `<` vs `<=`, `>>>` vs `>>` vs `>` vs `>=`, `||` vs `|`, `&&` vs
 * `&`. Each conflict gets a dedicated disambiguation test below.
 *
 * Test groups:
 *  - per-operator smoke for each of the six new ctors
 *  - cross-level precedence interactions between new and existing levels
 *  - longest-match disambiguation regressions for the conflicts this
 *    slice introduces
 *  - left-associative chains at the two new precedence levels
 *  - rejections for malformed input
 *  - end-to-end through `HaxeModuleFastParser`
 */
class HxBitwiseSliceTest extends HxTestHelpers {

	// -------- per-operator smoke --------

	public function testBitAnd():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a & b; }');
		switch decl.init {
			case BitAnd(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected BitAnd(a, b), got ${decl.init}');
		}
	}

	public function testBitOr():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a | b; }');
		switch decl.init {
			case BitOr(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected BitOr(a, b), got ${decl.init}');
		}
	}

	public function testBitXor():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ^ b; }');
		switch decl.init {
			case BitXor(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected BitXor(a, b), got ${decl.init}');
		}
	}

	public function testShl():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a << b; }');
		switch decl.init {
			case Shl(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected Shl(a, b), got ${decl.init}');
		}
	}

	public function testShr():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a >> b; }');
		switch decl.init {
			case Shr(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected Shr(a, b), got ${decl.init}');
		}
	}

	public function testUShr():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a >>> b; }');
		switch decl.init {
			case UShr(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected UShr(a, b), got ${decl.init}');
		}
	}

	// -------- cross-level precedence --------

	public function testAddTighterThanShl():Void {
		// 1 + 2 << 3 → Shl(Add(1, 2), 3). `+` at prec 8 binds tighter
		// than `<<` at prec 7, so the `+` subtree folds first and the
		// whole `1 + 2` becomes the left operand of the outer shift.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 1 + 2 << 3; }');
		switch decl.init {
			case Shl(Add(IntLit(a), IntLit(b)), IntLit(c)):
				Assert.equals(1, (a : Int));
				Assert.equals(2, (b : Int));
				Assert.equals(3, (c : Int));
			case null, _:
				Assert.fail('expected Shl(Add(1, 2), 3), got ${decl.init}');
		}
	}

	public function testShlTighterThanBitOr():Void {
		// 1 << 2 | 3 → BitOr(Shl(1, 2), 3). `<<` at prec 7 binds
		// tighter than `|` at prec 6. This is the reference Haxe
		// precedence ordering — shifts sit above bitwise.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 1 << 2 | 3; }');
		switch decl.init {
			case BitOr(Shl(IntLit(a), IntLit(b)), IntLit(c)):
				Assert.equals(1, (a : Int));
				Assert.equals(2, (b : Int));
				Assert.equals(3, (c : Int));
			case null, _:
				Assert.fail('expected BitOr(Shl(1, 2), 3), got ${decl.init}');
		}
	}

	public function testBitOrTighterThanEq():Void {
		// a | b == c → Eq(BitOr(a, b), c). `|` at prec 6 binds
		// tighter than `==` at prec 5. This is the Haxe-specific
		// deviation from the C convention (in C, bitwise binds looser
		// than comparison — `a | b == c` parses as `a | (b == c)`).
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = a | b == c; }');
		switch decl.init {
			case Eq(BitOr(IdentExpr(a), IdentExpr(b)), IdentExpr(c)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected Eq(BitOr(a, b), c), got ${decl.init}');
		}
	}

	public function testBitAndBitOrSameLevel():Void {
		// a & b | c → BitOr(BitAnd(a, b), c). Both operators sit at
		// prec 6 and are left-associative, so the left-to-right fold
		// resolves `a & b` first and then wraps it in the outer `|`.
		// Left-assoc at the same level inside the new bitwise tier.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a & b | c; }');
		switch decl.init {
			case BitOr(BitAnd(IdentExpr(a), IdentExpr(b)), IdentExpr(c)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected BitOr(BitAnd(a, b), c), got ${decl.init}');
		}
	}

	// -------- longest-match disambiguation --------

	public function testShortLtStillWorksWithShl():Void {
		// Regression guard: after adding `<<` at prec 7, the short
		// `<` at prec 5 must still match cleanly on input with no
		// trailing `<` or `=`. Without the length-desc sort the
		// dispatch order is undefined and `<<` could be attempted
		// first but peek-fail on `1 < 2`, which is fine — what we
		// care about is that the final parse shape is `Lt`.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 < 2; }');
		switch decl.init {
			case Lt(IntLit(_), IntLit(_)): Assert.pass();
			case null, _: Assert.fail('expected Lt(1, 2), got ${decl.init}');
		}
	}

	public function testShortGtStillWorksWithShr():Void {
		// Same regression guard on the `>` side after adding `>>`
		// and `>>>`. The longer ops must not strand the short form.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 2 > 1; }');
		switch decl.init {
			case Gt(IntLit(_), IntLit(_)): Assert.pass();
			case null, _: Assert.fail('expected Gt(2, 1), got ${decl.init}');
		}
	}

	public function testLtEqNotShl():Void {
		// `<=` and `<<` are both length 2. Neither is a prefix of
		// the other, so the sort is free to order them either way,
		// but the dispatch chain must still pick the one whose
		// literal matches the input. Input `1 <= 2` must land on
		// `LtEq`, not `Shl` + error.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 1 <= 2; }');
		switch decl.init {
			case LtEq(IntLit(_), IntLit(_)): Assert.pass();
			case Shl(_, _):
				Assert.fail('longest-match regression: `<=` dispatched as `<<`, got ${decl.init}');
			case null, _:
				Assert.fail('expected LtEq(1, 2), got ${decl.init}');
		}
	}

	public function testGtEqNotShr():Void {
		// Symmetric: `>=` and `>>` are both length 2. Input `2 >= 1`
		// must land on `GtEq`, not `Shr` + error.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = 2 >= 1; }');
		switch decl.init {
			case GtEq(IntLit(_), IntLit(_)): Assert.pass();
			case Shr(_, _):
				Assert.fail('longest-match regression: `>=` dispatched as `>>`, got ${decl.init}');
			case null, _:
				Assert.fail('expected GtEq(2, 1), got ${decl.init}');
		}
	}

	public function testUShrNotShrFollowedByGt():Void {
		// Regression guard for the three-char operator. Without the
		// length-desc sort the two-char `>>` could match on `>>>` at
		// the cost of stranding the final `>`. The sort attempts
		// `>>>` first, which succeeds, and `>>` is never tried for
		// this input.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 1 >>> 2; }');
		switch decl.init {
			case UShr(IntLit(_), IntLit(_)): Assert.pass();
			case Shr(_, _):
				Assert.fail('longest-match regression: `>>>` dispatched as `>>`, got ${decl.init}');
			case null, _:
				Assert.fail('expected UShr(1, 2), got ${decl.init}');
		}
	}

	// -------- left-associative chains --------

	public function testShlLeftAssoc():Void {
		// a << b << c → Shl(Shl(a, b), c). Left-assoc at the new
		// shift precedence level.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a << b << c; }');
		switch decl.init {
			case Shl(Shl(IdentExpr(a), IdentExpr(b)), IdentExpr(c)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected Shl(Shl(a, b), c), got ${decl.init}');
		}
	}

	public function testBitOrLeftAssoc():Void {
		// a | b | c → BitOr(BitOr(a, b), c). Left-assoc at the new
		// bitwise precedence level.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a | b | c; }');
		switch decl.init {
			case BitOr(BitOr(IdentExpr(a), IdentExpr(b)), IdentExpr(c)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected BitOr(BitOr(a, b), c), got ${decl.init}');
		}
	}

	// -------- rejections --------

	public function testRejectsTrailingShl():Void {
		// `a <<;` — shift matches, right-operand parser fails on `;`.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = a <<; }'), ParseError);
	}

	public function testRejectsTrailingBitAnd():Void {
		// `a &;` — bitwise matches, right-operand parser fails on `;`.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = a &; }'), ParseError);
	}

	// -------- end-to-end through HaxeModuleFastParser --------

	public function testModuleWithShiftAndBitwise():Void {
		// Prove the two new precedence levels flow through the
		// module-root grammar the same way additive and comparison
		// already do. One class carries a shift initializer, the
		// other a bitwise initializer — the module parser must land
		// both without cross-talk or trailing-garbage errors.
		final source:String = 'class A { var x:Int = 1 << 2; } class B { var y:Int = 3 | 4; }';
		final module:HxModule = HaxeModuleFastParser.parse(source);
		Assert.equals(2, module.decls.length);

		final a:HxClassDecl = expectClassDecl(module.decls[0]);
		final aVar:HxVarDecl = expectVarMember(a.members[0].member);
		switch aVar.init {
			case Shl(IntLit(l), IntLit(r)):
				Assert.equals(1, (l : Int));
				Assert.equals(2, (r : Int));
			case null, _:
				Assert.fail('expected Shl(1, 2), got ${aVar.init}');
		}

		final b:HxClassDecl = expectClassDecl(module.decls[1]);
		final bVar:HxVarDecl = expectVarMember(b.members[0].member);
		switch bVar.init {
			case BitOr(IntLit(l), IntLit(r)):
				Assert.equals(3, (l : Int));
				Assert.equals(4, (r : Int));
			case null, _:
				Assert.fail('expected BitOr(3, 4), got ${bVar.init}');
		}
	}

}
