package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypeRef;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Tests for the `is` operator — Haxe's runtime type-check operator.
 *
 * Adds `Is(left:HxExpr, right:HxType)` with `@:infix('is', 5)` to
 * `HxExpr`. Two new shapes exercised across this slice:
 *
 *  - **Word-like infix dispatch.** `is` ends with a word character so
 *    Lowering's Pratt loop emits `matchKw` instead of `matchLit` for
 *    its dispatch branch. Without word-boundary enforcement, an
 *    identifier like `island` would eagerly consume the `is` prefix
 *    as the operator. Tested by `testIdentNotConsumedAsIs`.
 *
 *  - **Asymmetric infix RHS.** Unlike every other Pratt branch in
 *    `HxExpr` (LHS and RHS both `HxExpr`), `Is`'s RHS is a `HxType`.
 *    Lowering detects the cross-type Ref and routes to `parseHxType`
 *    instead of recursing into `parseHxExpr` at elevated minPrec.
 *    The writer mirrors the asymmetry through `writeFnFor(rightRef)`.
 *
 * Left-associative chaining (`x is Int is String` → `Is(Is(x, Int), String)`)
 * falls out of the standard Pratt iteration: the outer loop handles
 * the second `is` after building the first, with no recursion needed.
 */
class HxIsSliceTest extends HxTestHelpers {

	/** `x is Bool` — basic asymmetric infix shape. */
	public function testSimpleIs():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Bool = x is Bool; }');
		switch decl.init {
			case Is(IdentExpr(l), Named(ref)):
				Assert.equals('x', (l : String));
				Assert.equals('Bool', (ref.name : String));
			case null, _: Assert.fail('expected Is(IdentExpr, Named), got ${decl.init}');
		}
	}

	/** `x is Int is String` — left-assoc chain via outer Pratt iteration. */
	public function testIsChainLeftAssoc():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Bool = x is Int is String; }');
		switch decl.init {
			case Is(Is(IdentExpr(x), Named(t1)), Named(t2)):
				Assert.equals('x', (x : String));
				Assert.equals('Int', (t1.name : String));
				Assert.equals('String', (t2.name : String));
			case null, _: Assert.fail('expected Is(Is(_, _), _), got ${decl.init}');
		}
	}

	/** `is("")` — `is` as a function-call identifier, not the operator. */
	public function testIdentNotConsumedAsIs():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Bool = is(""); }');
		switch decl.init {
			case Call(IdentExpr(name), args):
				Assert.equals('is', (name : String));
				Assert.equals(1, args.length);
			case null, _: Assert.fail('expected Call(IdentExpr("is"), _), got ${decl.init}');
		}
	}

	/** `island` must not match the `is` operator prefix — full identifier. */
	public function testIdentWithIsPrefix():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Bool = island; }');
		switch decl.init {
			case IdentExpr(name): Assert.equals('island', (name : String));
			case null, _: Assert.fail('expected IdentExpr("island"), got ${decl.init}');
		}
	}

	/** Whitespace tolerance around `is`. */
	public function testIsWhitespace():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class C { var f:Bool = x  is  Int; }');
		switch decl.init {
			case Is(IdentExpr(x), Named(t)):
				Assert.equals('x', (x : String));
				Assert.equals('Int', (t.name : String));
			case null, _: Assert.fail('expected Is(IdentExpr, Named)');
		}
	}

	/** Round-trip simple form. */
	public function testRoundTripSimple():Void {
		roundTrip('class C { var f:Bool = x is Bool; }');
	}

	/** Round-trip chained form. */
	public function testRoundTripChain():Void {
		roundTrip('class C { var f:Bool = x is Int is String; }');
	}

	/** Round-trip `is` as identifier — must not become operator on reparse. */
	public function testRoundTripIsAsIdent():Void {
		roundTrip('class C { var f:Bool = is(""); }');
	}

}
