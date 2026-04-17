package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 assignment-slice tests for the macro-generated Haxe parser.
 *
 * Covers the right-associative Pratt operators at precedence 1. The
 * `Pratt.annotate` strategy accepts an optional third `@:infix` arg
 * (`'Left'` / `'Right'`, default `'Left'`), and `Lowering.lowerPrattLoop`
 * picks `nextMinPrec = prec` for right-associative branches instead of
 * `prec + 1` for left-associative, so same-prec chains fold right
 * instead of left.
 *
 * Three shipping waves share this file:
 *  - parens + right-assoc slice: `=`, `+=`, `-=`.
 *  - bitwise + shifts + arithmetic compound assigns slice: `*=`,
 *    `/=`, `%=`. Same right-assoc concept, same prec 1, no new
 *    macro work — only new ctors on `HxExpr`.
 *  - bitwise/shift compound assigns slice (β): `<<=`, `>>=`, `>>>=`,
 *    `|=`, `&=`, `^=`. Again same right-assoc concept, same prec 1,
 *    zero macro changes. Purpose of the slice is to validate that
 *    the D33 longest-match sort disambiguates the dense new conflict
 *    set (`>>>=`/`>>>`/`>>=`/`>>`/`>=`, `<<=`/`<<`/`<=`, `|=`/`||`,
 *    `&=`/`&&`) without any code change — every test below that
 *    looks like a "base op still works" regression guard is in fact
 *    the spot check for that sort.
 *
 * Grammar coverage in this file:
 *  - `a = 1`, `a += 1`, `a -= 1`, `a *= 1`, `a /= 1`, `a %= 1`,
 *    `a <<= 1`, `a >>= 1`, `a >>>= 1`, `a |= 1`, `a &= 1`, `a ^= 1`
 *    — per-op smoke for each of the twelve assignment ctors.
 *  - `a = b = 1` — right-fold: `Assign(a, Assign(b, 1))`.
 *  - `a += b -= 1` — mixed-op right-fold (first wave).
 *  - `a *= b /= 1` — mixed-op right-fold (second wave).
 *  - `a *= b += 1` — cross-wave right-fold, proves wave-1 and
 *    wave-2 compose inside a single chain.
 *  - `a |= b &= c` — bitwise right-fold (third wave).
 *  - `a <<= b >>= c` — shift right-fold (third wave).
 *  - `a += b *= c ^= 1` — triple-wave right-fold, proves waves 1+2+3
 *    compose inside a single chain.
 *  - `a = b + 1` — `+` binds tighter than `=`.
 *  - `a + 1 = 2` — lowest-precedence proof: `=` at prec 1 sits
 *    below `+` at prec 8, so the `+` subtree folds first and the
 *    whole `a + 1` ends up on the left of the `=`. The result has
 *    an `Add` as its `Assign` lvalue, which is semantically
 *    nonsensical but structurally correct — a later semantic pass
 *    would reject it. Note: this is a precedence check, not an
 *    associativity check — both left- and right-associative `=`
 *    produce the same shape here because the RHS (`2`) is a single
 *    atom with no same-prec chain. The real right-associativity
 *    proof is the `a = b = 1` test above.
 *  - `a = b == c` — `==` binds tighter than `=`.
 *  - `a |= b << 2` — `<<` at prec 7 binds tighter than `|=` at
 *    prec 1 (third-wave cross-precedence with a higher level).
 *  - `a >>= b + 1` — `+` at prec 8 binds tighter than `>>=` at
 *    prec 1 (third-wave cross-precedence against a different higher
 *    level).
 *  - `a << b`, `a >> b`, `a | b` — regression guards that shipping
 *    the 3-char `>>=`/`<<=` and 2-char `|=`/`&=` compound assigns
 *    did not accidentally shadow the shorter base operators under
 *    the D33 longest-match sort.
 *  - `a = (b = c)` — cross-concept smoke with the parens slice.
 *  - `a = ;` — missing right operand rejected.
 *  - `a >>>= ;` — missing right operand rejected for a 4-char op,
 *    proving the longest-match commit still reaches the RHS parse.
 */
class HxAssignSliceTest extends HxTestHelpers {

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
		// a = b + 1 → Assign(a, Add(b, 1)). `+` at prec 8 binds
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
		// a + 1 = 2 → Assign(Add(a, 1), 2). `+` at prec 8 binds
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
		Assert.raises(() -> HaxeParser.parse('class Foo { var x:Int = a = ; }'), ParseError);
	}

	public function testMulAssign():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a *= 1; }');
		switch decl.init {
			case MulAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected MulAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testDivAssign():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a /= 1; }');
		switch decl.init {
			case DivAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected DivAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testModAssign():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a %= 1; }');
		switch decl.init {
			case ModAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected ModAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testMulDivRightAssocChain():Void {
		// a *= b /= 1 → MulAssign(a, DivAssign(b, 1)). Second-wave
		// mixed-op right-fold. Same semantics as `testMixedRightAssocChain`,
		// different ctor pair, proves that `*=` and `/=` join the
		// existing assignment chain correctly.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a *= b /= 1; }');
		switch decl.init {
			case MulAssign(IdentExpr(a), DivAssign(IdentExpr(b), IntLit(one))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected MulAssign(a, DivAssign(b, 1)), got ${decl.init}');
		}
	}

	public function testCrossWaveCompoundChain():Void {
		// a *= b += 1 → MulAssign(a, AddAssign(b, 1)). Cross-wave
		// chain: the outer operator is from the second slice (`*=`)
		// and the inner is from the first slice (`+=`). Both sit at
		// prec 1 right-assoc, so the fold direction is the same and
		// the Pratt loop composes them without knowing they were
		// introduced in different sessions.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a *= b += 1; }');
		switch decl.init {
			case MulAssign(IdentExpr(a), AddAssign(IdentExpr(b), IntLit(one))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected MulAssign(a, AddAssign(b, 1)), got ${decl.init}');
		}
	}

	public function testShlAssign():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a <<= 1; }');
		switch decl.init {
			case ShlAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected ShlAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testShrAssign():Void {
		// `a >>= 1` — 3-char longest-match validates that `>>=`
		// (len 3) wins over `>>` (len 2) and `>=` (len 2). A
		// failing D33 sort would produce `Shr(a, Lt(...))` or
		// similar nonsense and this test would fail loudly.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a >>= 1; }');
		switch decl.init {
			case ShrAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected ShrAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testUShrAssign():Void {
		// `a >>>= 1` — 4-char longest-match validates that `>>>=`
		// (len 4) wins over `>>>` (len 3), `>>=` (len 3), `>>` (len
		// 2), `>=` (len 2), and `>` (len 1). Densest prefix-conflict
		// set in the grammar; the D33 sort is exercised maximally
		// by this one input.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a >>>= 1; }');
		switch decl.init {
			case UShrAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected UShrAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testBitOrAssign():Void {
		// `a |= 1` — validates that `|=` (len 2) wins over `|`
		// (len 1) AND is disambiguated from `||` (len 2, same
		// length but different text).
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a |= 1; }');
		switch decl.init {
			case BitOrAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected BitOrAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testBitAndAssign():Void {
		// `a &= 1` — validates that `&=` (len 2) wins over `&`
		// (len 1) AND is disambiguated from `&&` (len 2, same
		// length but different text).
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a &= 1; }');
		switch decl.init {
			case BitAndAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected BitAndAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testBitXorAssign():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ^= 1; }');
		switch decl.init {
			case BitXorAssign(IdentExpr(l), IntLit(r)):
				Assert.equals('a', (l : String));
				Assert.equals(1, (r : Int));
			case null, _:
				Assert.fail('expected BitXorAssign(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testShlBaseStillWorks():Void {
		// `a << b` — regression guard that adding the 3-char `<<=`
		// did not accidentally shadow the 2-char `<<` base op.
		// Outside an assignment context, the D33 sort still chooses
		// the longest matching prefix at the input position, and
		// `b` after `<< ` is not `=`, so `<<` wins.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a << b; }');
		switch decl.init {
			case Shl(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected Shl(a, b), got ${decl.init}');
		}
	}

	public function testShrBaseStillWorks():Void {
		// `a >> b` — same story as testShlBaseStillWorks, for the
		// right-shift family. Adding `>>=`/`>>>=` must not steal
		// input from `>>`.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a >> b; }');
		switch decl.init {
			case Shr(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected Shr(a, b), got ${decl.init}');
		}
	}

	public function testBitOrBaseStillWorks():Void {
		// `a | b` — regression guard for the bitwise `|` base op
		// after adding the 2-char `|=` compound assign.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a | b; }');
		switch decl.init {
			case BitOr(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l : String));
				Assert.equals('b', (r : String));
			case null, _:
				Assert.fail('expected BitOr(a, b), got ${decl.init}');
		}
	}

	public function testBitwiseAssignRightAssocChain():Void {
		// a |= b &= c → BitOrAssign(a, BitAndAssign(b, c)). Wave-3
		// homogeneous right-fold, proving the new bitwise compound
		// assigns join the existing prec 1 chain.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a |= b &= c; }');
		switch decl.init {
			case BitOrAssign(IdentExpr(a), BitAndAssign(IdentExpr(b), IdentExpr(c))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected BitOrAssign(a, BitAndAssign(b, c)), got ${decl.init}');
		}
	}

	public function testShiftAssignRightAssocChain():Void {
		// a <<= b >>= c → ShlAssign(a, ShrAssign(b, c)). Wave-3
		// right-fold on the shift-assign family. Exercises the
		// densest prefix-conflict set (3-char `>>=` inside a chain)
		// under a real fold.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a <<= b >>= c; }');
		switch decl.init {
			case ShlAssign(IdentExpr(a), ShrAssign(IdentExpr(b), IdentExpr(c))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected ShlAssign(a, ShrAssign(b, c)), got ${decl.init}');
		}
	}

	public function testTripleWaveCompoundChain():Void {
		// a += b *= c ^= 1 → AddAssign(a, MulAssign(b, BitXorAssign(c, 1))).
		// Three waves of compound assigns composing inside one
		// Pratt chain — first wave (`+=`), second wave (`*=`),
		// third wave (`^=`). All sit at prec 1 right-assoc, so
		// the fold direction is uniform and the loop does not
		// care which session introduced each ctor.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a += b *= c ^= 1; }');
		switch decl.init {
			case AddAssign(IdentExpr(a), MulAssign(IdentExpr(b), BitXorAssign(IdentExpr(c), IntLit(one)))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected AddAssign(a, MulAssign(b, BitXorAssign(c, 1))), got ${decl.init}');
		}
	}

	public function testBitOrAssignWithRhsShift():Void {
		// a |= b << 2 → BitOrAssign(a, Shl(b, 2)). `<<` at prec 7
		// binds tighter than `|=` at prec 1, so the inner recursion
		// folds `b << 2` before returning to the outer compound
		// assign. Cross-prec check against a higher level.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a |= b << 2; }');
		switch decl.init {
			case BitOrAssign(IdentExpr(a), Shl(IdentExpr(b), IntLit(two))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(2, (two : Int));
			case null, _:
				Assert.fail('expected BitOrAssign(a, Shl(b, 2)), got ${decl.init}');
		}
	}

	public function testShiftAssignWrapsAdditiveRhs():Void {
		// a >>= b + 1 → ShrAssign(a, Add(b, 1)). `+` at prec 8 binds
		// tighter than `>>=` at prec 1. Cross-prec check against a
		// different higher level than testBitOrAssignWithRhsShift.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a >>= b + 1; }');
		switch decl.init {
			case ShrAssign(IdentExpr(a), Add(IdentExpr(b), IntLit(one))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected ShrAssign(a, Add(b, 1)), got ${decl.init}');
		}
	}

	public function testRejectsShiftAssignWithoutRhs():Void {
		// `a >>>= ;` — the 4-char compound assign matches, skipWs
		// runs, and then the right-hand `parseHxExpr` fails on the
		// `;` terminator. Symmetric to `testRejectsAssignWithoutRhs`
		// for the longest compound-assign literal in the grammar.
		Assert.raises(() -> HaxeParser.parse('class Foo { var x:Int = a >>>= ; }'), ParseError);
	}

}
