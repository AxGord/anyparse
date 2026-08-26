package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.SimplifyNegatedCompound;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `simplify-negated-compound` check over its two arms. A logical-not is flagged `Info` and
 * rewritten when — and only when — the result strictly reduces the unary-`!` count: a `&&` / `||`
 * compound is De Morganed (`!(!a || b)` → `a && !b` offered, `!(a || b)` → `!a && !b` not), and a
 * SINGLE comparison has its operator flipped (`!(n < 0)` → `n >= 0`, `!(a == b)` → `a != b`).
 *
 * The rewrite text comes from the same `BooleanLogicSupport` engine the guard family inverts with,
 * so an ordered comparison stays wrapped `!(a < b)` unless both operands resolve to a type `<` orders
 * TOTALLY (`Int` / `UInt`, never `String` — Haxe cannot prove a string non-null)
 * — which includes a method call's return type resolved through its receiver chain. On the
 * single-comparison arm that wrap IS the input, so the worth gate turns "unproven" into an outright
 * refusal; on the compound arm the same wrap survives inside a still-worthwhile partial result.
 *
 * Gates, shared by both arms: a comment in the span, a `#if` region, a macro-reification
 * subtree, and any operand outside the seam's whitelist (`|`, `&`, `is`, a call, another
 * `!`) all refuse; a chain that would strand a null-safety narrowing right-nests a
 * parenthesised group at the stranded operand instead of refusing.
 */
class SimplifyNegatedCompoundCheckTest extends Test {

	/** Resolution-scope model: the only totally-ordered tail every chain fixture ends in (`Str.indexOf` -> `Int`). */
	private static final MODEL_STR: String = 'class Str {\n\tpublic function indexOf(s:Str):Int return 0;\n}';

	/** `MODEL_STR` plus the one-field carrier the chain fixtures walk THROUGH to reach it. */
	private static final MODEL_STR_ITEM: String = '$MODEL_STR\nclass Item {\n\tpublic var text:Str;\n}';

	/** The generic carrier whose member is declared as its own type parameter — the substitution fixtures' subject. */
	private static final MODEL_BOX: String = 'class Box<T:Item> {\n\tpublic var payload:T;\n}';

	public function testNegatedDisjunctionWithNegatedTermFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('var b = !(!p || q);'));
		Assert.equals(1, vs.length);
		Assert.equals('simplify-negated-compound', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this negated compound simplifies by De Morgan', vs[0].message);
	}

	public function testPlainDisjunctionNotFlagged(): Void {
		// `!(p || q)` -> `!p && !q` trades one negation for two: the worth gate refuses it.
		Assert.equals(0, violations(wrap('var b = !(p || q);')).length);
	}

	public function testComparisonTieNotFlagged(): Void {
		// One `!` before (`!(…)`), one after (`!f(x)`) — a TIE is not a strict reduction.
		Assert.equals(0, violations(wrap('var b = !(x == y || f(x));')).length);
	}

	public function testUnprovenSingleOrderedComparisonNotFlagged(): Void {
		// The single-comparison arm READS this site now; the WORTH gate is what refuses it. `f` has
		// no declared type, so the order gate declines the flip and the only text the engine can emit
		// is `!(f < 0.5)` — the input verbatim, `notDelta` +1. Unproven -> refuse, with no partial
		// form to fall back on: one term leaves nothing else to shed a `!` from.
		Assert.equals(0, violations(wrap('var b = !(f < 0.5);')).length);
	}

	public function testSingleNegationNotFlagged(): Void {
		// `!(!p)` WOULD pay (`notDelta` -1) — it is the seam's operand whitelist, which excludes the
		// not-kind, that keeps this rule off `double-negation`'s shape and the two disjoint.
		Assert.equals(0, violations(wrap('var b = !(!p);')).length);
	}

	public function testNegatedOrderedComparisonFlaggedWhenIntProven(): Void {
		// `n:Int` proves both operands totally ordered, so the flip is licensed and costs no `!` while the
		// outer one is shed. The wording names the arm that accepted the site.
		final vs: Array<Violation> = violations(wrapTyped('var b = !(n < 0);', 'n:Int'));
		Assert.equals(1, vs.length);
		Assert.equals('simplify-negated-compound', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this negated comparison simplifies to the flipped operator', vs[0].message);
	}

	public function testFixFlipsSingleOrderedComparison(): Void {
		Assert.equals(wrapTyped('var b = n >= 0;', 'n:Int'), applyFix(wrapTyped('var b = !(n < 0);', 'n:Int')));
	}

	public function testNullableStringOrderedComparisonNotFlagged(): Void {
		// `String` is NOT a totally-ordered nominal. It carries no NaN — which is why it once
		// licensed the flip — but Haxe has no non-nullable string type, so `s:String` proves
		// nothing about null, and with a null operand `!(s < t)` is `true` where `s >= t` is
		// `false` (measured on `--interp`, `js` and `neko`, all four ordered operators). The flip
		// is declined, and on this arm a decline is an outright refusal: the wrap IS the input.
		final source: String = wrapTyped('var b = !(s < t);', 's:String, t:String');
		Assert.equals(0, violations(source).length);
		Assert.equals(source, applyFix(source));
	}

	public function testStringLiteralOrderedComparisonStillFlips(): Void {
		// The NOMINAL is refused; the LITERAL kinds are not. A string literal is non-null by
		// construction — exactly the proof a `String` declaration cannot give — so both operands
		// are totally ordered and the flip is sound. Pins that dropping the nominal did not also
		// drop the two string entries from `TOTAL_ORDER_LITERAL_KINDS`. It passes with the nominal
		// restored as well — a pin on the literal path, NOT a discriminator for the narrowing (the
		// literal kinds are consulted before the nominal resolver ever runs).
		Assert.equals(wrap('var b = "a" >= "b";'), applyFix(wrap('var b = !("a" < "b");')));
	}

	public function testNegatedEqualityFlaggedWithoutTypes(): Void {
		// No type proof needed: IEEE makes `NaN == x` false and `NaN != x` true, and a `null` operand
		// answers the same both ways, so the flipped
		// operator and the wrap agree for every operand — including an unresolved one.
		Assert.equals(1, violations(wrap('var b = !(a == b2);')).length);
	}

	public function testFixFlipsSingleEquality(): Void {
		Assert.equals(wrap('var b = a != b2;'), applyFix(wrap('var b = !(a == b2);')));
		Assert.equals(wrap('var b = a == b2;'), applyFix(wrap('var b = !(a != b2);')));
	}

	public function testFixParenthesisesFlippedComparisonInNotSlot(): Void {
		// The OUTER `!` wraps a `Not`, which the whitelist refuses, so the walk descends; the INNER
		// one is accepted and its replacement lands inside the outer negation's own parens. One pass
		// therefore leaves a `!( … )` that the NEXT pass hands to this same rule (`!(n >= 0)` ->
		// `n < 0`), which is why the fixpoint loop reports three passes on this shape.
		Assert.equals(wrapTyped('var b = !(n >= 0);', 'n:Int'), applyFix(wrapTyped('var b = !(!(n < 0));', 'n:Int')));
	}

	public function testSingleComparisonChainCallReturnTypeProvesFlip(): Void {
		// The single-term twin of `testChainCallReturnTypeProvesFlip`, and the shape the real tree
		// carries: resolving `it.text` to `Str` and `Str.indexOf` to `Int` is the whole licence.
		final model: String = MODEL_STR_ITEM;
		final source: String = wrapTyped('var b = !(it.text.indexOf(k) < 0);', 'it:Item, k:Str');
		Assert.equals(wrapTyped('var b = it.text.indexOf(k) >= 0;', 'it:Item, k:Str'), fixedWith(source, model));
	}

	public function testUnresolvedSingleChainCallNotFlagged(): Void {
		// The same shape with NO resolution scope: the return type is unknown, the flip is declined,
		// and on this arm a decline is a refusal — the site is left exactly as written. A refusal
		// pin, not a proof of the arm: it reads 0 before the widening too, for the other reason.
		final source: String = wrapTyped('var b = !(it.text.indexOf(k) < 0);', 'it:Item, k:Str');
		Assert.equals(0, violations(source).length);
		Assert.equals(source, applyFix(source));
	}

	public function testIsOperandNotFlagged(): Void {
		// A refusal pin, not a proof of the arm: `is` is outside the whitelist, and its wrap is the
		// canonical negation anyway, so the worth gate would refuse it too. Both readings say 0.
		Assert.equals(0, violations(wrap('var b = !(x is Int);')).length);
	}

	public function testCallOperandNotFlagged(): Void {
		// Same kind of pin: a call is opaque to the negation engine, so `!(g(x))` is all it can emit.
		Assert.equals(0, violations(wrap('var b = !(g(x));')).length);
	}

	public function testCommentInSingleComparisonSpanNotFlagged(): Void {
		// A refusal pin for the inherited comment gate — the arm is otherwise a licensed `Int` flip.
		Assert.equals(0, violations(wrapTyped('var b = !(n < 0 /* why */);', 'n:Int')).length);
	}

	public function testConditionalCompilationInSingleComparisonNotFlagged(): Void {
		// A refusal pin for the inherited `#if` gate. The arm has to be the EQUALITY one: an
		// ordered comparison whose operand is a `#if` region is refused by the WORTH gate first
		// (a `ConditionalExpr` operand is not order-provable, so the flip declines), which would
		// leave the `#if` gate untested. `==` needs no proof, so only the `#if` gate can say no.
		Assert.equals(0, violations(wrapTyped('var b = !(n == #if js 0 #else 1 #end);', 'n:Int')).length);
	}

	public function testFixParenthesisesFlippedComparisonInComparisonSlot(): Void {
		// The flipped result binds at the comparison tier, which in Haxe is ONE left-associative
		// rank: emitted bare into a comparison's right slot, `c == n >= 0` re-associates to
		// `(c == n) >= 0`. Both arms are pinned because the equality one needs no type proof and
		// so reaches any tree — `d == a != b2` reads `(d == a) != b2`, which compiles under
		// `Dynamic` and answers differently.
		Assert.equals(wrapTyped('var b = c == (n >= 0);', 'c:Bool, n:Int'), applyFix(wrapTyped('var b = c == !(n < 0);', 'c:Bool, n:Int')));
		Assert.equals(wrap('var b = d == (a != b2);'), applyFix(wrap('var b = d == !(a == b2);')));
	}

	public function testSingleComparisonFixIsIdempotent(): Void {
		final once: String = applyFix(wrapTyped('var b = !(n < 0);', 'n:Int'));
		Assert.equals(once, applyFix(once));
	}

	public function testBitwiseOperandNotFlagged(): Void {
		// `|` is a bitwise operator and is absent from the seam's operand whitelist, so
		// `negatedOperandOf` never returns it — and it is opaque to the negation engine besides,
		// so the worth gate would refuse it anyway. Two independent reasons; the fixture pins the
		// outcome, not one.
		Assert.equals(0, violations(wrap('var b = !(x | y);')).length);
	}

	public function testFixDropsOuterNegation(): Void {
		Assert.equals(wrap('var b = p && !q;'), applyFix(wrap('var b = !(!p || q);')));
	}

	public function testFixFlipsComparisonPair(): Void {
		Assert.equals(wrap('var b = x != y || z == w;'), applyFix(wrap('var b = !(x == y && z != w);')));
	}

	public function testFixKeepsUnprovenOrderedComparisonWrapped(): Void {
		// The order gate cannot type `f`, so its comparison stays wrapped — a PARTIAL
		// simplification, still one `!` fewer than the input.
		Assert.equals(wrap('var b = p && !(f < 0.5);'), applyFix(wrap('var b = !(!p || f < 0.5);')));
	}

	public function testFixFlipsOrderedComparisonWhenIntProven(): Void {
		Assert.equals(wrapTyped('var b = p && n >= 0;', 'p:Bool, n:Int'), applyFix(wrapTyped('var b = !(!p || n < 0);', 'p:Bool, n:Int')));
	}

	public function testFixKeepsStringOrderedComparisonWrappedInCompound(): Void {
		// The COMPOUND arm shares the one licence, so the `String` term stays wrapped and only the
		// partial simplification is offered — one `!` fewer, still worth it. While `String` was a
		// licensed nominal this read `p && s >= t`, an unsound rewrite; this is its regression pin,
		// and the `n:Int` twin directly above is what proves the licence itself still works.
		Assert.equals(
			wrapTyped('var b = p && !(s < t);', 'p:Bool, s:String, t:String'),
			applyFix(wrapTyped('var b = !(!p || s < t);', 'p:Bool, s:String, t:String'))
		);
	}

	public function testFixPreservesCallCountAndOrder(): Void {
		// De Morgan keeps each term in place and evaluates it at most once; the short-circuit
		// set is unchanged (`!(A || B)` skips B when A is true, `!A && !B` when `!A` is false).
		Assert.equals(wrap('var b = g() && !h();'), applyFix(wrap('var b = !(!g() || h());')));
	}

	public function testFixParenthesisesLooserResultInTighterSlot(): Void {
		// The result is an `||` chain sitting under `&&` — the seam re-adds the pair.
		Assert.equals(wrap('var b = p && (!q || r);'), applyFix(wrap('var b = p && !(q && !r);')));
	}

	public function testFixEmitsNoParensInFullExpressionSlot(): Void {
		Assert.equals(wrap('var b = p && q;'), applyFix(wrap('var b = !(!p || !q);')));
	}

	public function testFixReparenthesisesStrippedCompoundOperand(): Void {
		// The stripped `!(a || b)` term is an `||` chain joined by `&&`: parens are required.
		Assert.equals(wrap('var b = (a || c) && !q;'), applyFix(wrap('var b = !(!(a || c) || q);')));
	}

	public function testFixKeepsIsOperandUnparenthesised(): Void {
		// `x is Int && !q` parses (verified on Haxe 4.3.7); `is` binds tighter than `&&`.
		Assert.equals(wrap('var b = x is Int && !q;'), applyFix(wrap('var b = !(!(x is Int) || q);')));
	}

	public function testFixPreservesNullNarrowing(): Void {
		// The `&&` form narrows `x` for `f` exactly as the `||` chain's short circuit did.
		Assert.equals(wrap('var b = x != null && f(x);'), applyFix(wrap('var b = !(x == null || !f(x));')));
	}

	public function testStrandedNarrowingRegroupsAndFlagged(): Void {
		// Worth passes (the outer wrap and the inner `!p` both shed) and the stranded `b` narrowing
		// no longer refuses:
		// the negation right-nests the tail so `b`'s fact survives inside its group.
		final source: String = wrap('var v = !(a != null && b != null && !p(a.x, b.y));');
		Assert.equals(1, violations(source).length);
		Assert.equals(wrap('var v = a == null || (b == null || p(a.x, b.y));'), applyFix(source));
	}

	public function testFixRegroupsEqualityChain(): Void {
		// The guard-family leftover this regrouping exists for: a verbatim wrap over an
		// all-equality chain whose null check a later operand depends on.
		Assert.equals(
			wrap("var b = path == '' || (s == null || s.name == '..');"),
			applyFix(wrap("var b = !(path != '' && s != null && s.name != '..');"))
		);
	}

	public function testCommentInSpanNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var b = !(!p /* why */ || q);')).length);
	}

	public function testConditionalCompilationNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var b = !(!p || #if js q #else r #end);')).length);
	}

	public function testMacroReificationSkipped(): Void {
		Assert.equals(0, violations(wrap('var e = macro !(!p || q);')).length);
	}

	public function testOnlyOutermostOfNestFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('var b = !(!(!p || q) || r);'));
		Assert.equals(1, vs.length);
	}

	public function testFixIsIdempotent(): Void {
		final once: String = applyFix(wrap('var b = !(!p || q);'));
		Assert.equals(once, applyFix(once));
	}

	public function testChainCallReturnTypeProvesFlip(): Void {
		// `it.text.indexOf(k)` — a call whose receiver is a FIELD CHAIN. Resolving the chain to
		// `Str`, then `Str.indexOf` to `Int`, is what licenses the `< 0` -> `>= 0` flip.
		final model: String = MODEL_STR_ITEM;
		final source: String = wrapTyped('var b = !(!p || it.text.indexOf(k) < 0);', 'p:Bool, it:Item, k:Str');
		Assert.equals(wrapTyped('var b = p && it.text.indexOf(k) >= 0;', 'p:Bool, it:Item, k:Str'), fixedWith(source, model));
	}

	public function testUnresolvedChainCallKeepsWrap(): Void {
		// The same shape with NO resolution scope: the return type is unknown, so the wrap
		// stays. Unproven -> refuse is the direction every guard-family consumer relies on.
		Assert.equals(
			wrapTyped('var b = p && !(it.text.indexOf(k) < 0);', 'p:Bool, it:Item, k:Str'),
			applyFix(wrapTyped('var b = !(!p || it.text.indexOf(k) < 0);', 'p:Bool, it:Item, k:Str'))
		);
	}

	public function testForBindingElementTypeProvesFlip(): Void {
		// ARM 1 alone: the for-binding element type. `it` carries no `:Type` annotation, so
		// `declaredTypes` has no entry for it; its type comes from `items:Array<Item>` through
		// `RefShape.iterationElementTypeParams`. No type parameter is substituted anywhere along
		// the chain, so this fixture discriminates the for-binding arm and nothing else.
		final model: String = MODEL_STR_ITEM;
		final params: String = 'q:Bool, items:Array<Item>, k:Str';
		final source: String = wrapTyped('for (it in items) {\n\t\t\tvar b = !(!q || it.text.indexOf(k) < 0);\n\t\t}', params);
		final fixed: String = wrapTyped('for (it in items) {\n\t\t\tvar b = q && it.text.indexOf(k) >= 0;\n\t\t}', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	public function testTypeArgumentSubstitutionProvesFlip(): Void {
		// ARM 2 alone: type-argument substitution. `box` IS annotated, so the for-binding arm is
		// never consulted; what the shallow walk cannot do is turn `Box.payload : T` into `Item`
		// using the receiver's written argument. Without the substitution the chain stops at the
		// verbatim `T`, which names no type.
		final model: String = '$MODEL_STR_ITEM\n$MODEL_BOX';
		final params: String = 'q:Bool, box:Box<Item>, k:Str';
		final source: String = wrapTyped('var b = !(!q || box.payload.text.indexOf(k) < 0);', params);
		final fixed: String = wrapTyped('var b = q && box.payload.text.indexOf(k) >= 0;', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	public function testForBindingOverGenericElementProvesFlip(): Void {
		// BOTH arms in one chain — the shape this whole seam exists for. The binder's element
		// type is itself a generic application (`Array<Box<Item>>` yields `Box<Item>`), and that
		// application's argument is what resolves the member `payload`. Either arm alone leaves
		// this site wrapped.
		final model: String = '$MODEL_STR_ITEM\n$MODEL_BOX';
		final params: String = 'q:Bool, items:Array<Box<Item>>, k:Str';
		final source: String = wrapTyped('for (it in items) {\n\t\t\tvar b = !(!q || it.payload.text.indexOf(k) < 0);\n\t\t}', params);
		final fixed: String = wrapTyped('for (it in items) {\n\t\t\tvar b = q && it.payload.text.indexOf(k) >= 0;\n\t\t}', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	public function testKeyValueLoopKeyBinderKeepsWrap(): Void {
		// The KEY half of the key-value gate. `for (kk => vv in m)` projects as
		// `(ForStmt kk (KeyValueBinder vv) (IdentExpr m) …)` — the node's own name is the KEY.
		// Reading the ELEMENT parameter off `Map<Fl, Cnt>` would type `kk` as `Cnt` (an `Int`
		// field) and license the flip, but `kk` is really an `Fl` whose field is a `Float`, where
		// `!(a < b)` and `a >= b` differ under NaN. `iterationElementTypeParams` answers the
		// element question only, so the key binder must stay unresolved — this fixture is what
		// fails if that refusal is dropped along with the old header `=>` scan. It pins the MAP
		// half of the refusal only; the array-index half the arm doc also names is not
		// expressible as a fixture (a wrongly-typed `Int` index reads the same as a right one).
		final model: String = 'class Fl {\n\tpublic var v:Float;\n}\nclass Cnt {\n\tpublic var v:Int;\n}';
		final params: String = 'q:Bool, m:Map<Fl, Cnt>';
		final source: String = wrapTyped('for (kk => vv in m) {\n\t\t\tvar b = !(!q || kk.v < 0);\n\t\t}', params);
		final fixed: String = wrapTyped('for (kk => vv in m) {\n\t\t\tvar b = q && !(kk.v < 0);\n\t\t}', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	public function testKeyValueLoopValueBinderProvesFlip(): Void {
		// The VALUE half. `vv` IS what iterating a `Map<Fl, Cnt>` yields, so it reads the same
		// `iterationElementTypeParams` entry a single-binder `for (vv in m)` would — `Cnt`, whose
		// `v` is an `Int`, where the flip is sound. The arm refused this whole shape while the
		// binder existed only in the header text; the sibling fixture above pins that flipping the
		// refusal did NOT also license the key.
		final model: String = 'class Fl {\n\tpublic var v:Float;\n}\nclass Cnt {\n\tpublic var v:Int;\n}';
		final params: String = 'q:Bool, m:Map<Fl, Cnt>';
		final source: String = wrapTyped('for (kk => vv in m) {\n\t\t\tvar b = !(!q || vv.v < 0);\n\t\t}', params);
		final fixed: String = wrapTyped('for (kk => vv in m) {\n\t\t\tvar b = q && vv.v >= 0;\n\t\t}', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	public function testIntervalLoopBinderKeepsWrap(): Void {
		// An `Interval` iterable is not a nominal path at all, so `valueTypeSourceDeep` answers
		// null for it and the binder stays unresolved. Pins that the arm reads the iterable's
		// DECLARED type and never guesses `Int` from the loop's shape.
		final model: String = MODEL_STR;
		final params: String = 'q:Bool';
		final source: String = wrapTyped('for (i in 0...10) {\n\t\t\tvar b = !(!q || i < 0);\n\t\t}', params);
		final fixed: String = wrapTyped('for (i in 0...10) {\n\t\t\tvar b = q && !(i < 0);\n\t\t}', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	public function testInheritedGenericMemberKeepsWrap(): Void {
		// Substitution is DIRECT-MEMBERS-ONLY. `u` is declared on `Base<U>`, so its `U` names the
		// SUPERTYPE's parameter; mapping it through `extends Base<T>` to `Der`'s `T` and on to the
		// written `Item` is a link this index does not model. The verbatim `U` resolves to no type,
		// so the chain dies and the wrap stays.
		//
		// This one does NOT discriminate the direct-member gate: the parameter names differ, so the
		// index-lookup gate (`U` is not among `Der`'s parameters) rejects it first. The fixture that
		// does is `testSupertypeParamNameCollisionKeepsWrap` below.
		final model: String = '$MODEL_STR_ITEM\nclass Base<U> {\n\tpublic var u:U;\n}\nclass Der<T:Item> extends Base<T> {}';
		final params: String = 'q:Bool, d:Der<Item>, k:Str';
		final source: String = wrapTyped('var b = !(!q || d.u.text.indexOf(k) < 0);', params);
		final fixed: String = wrapTyped('var b = q && !(d.u.text.indexOf(k) < 0);', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	public function testSupertypeParamNameCollisionKeepsWrap(): Void {
		// The DIRECT-MEMBER gate, isolated — and the one shape where losing it produces a WRONG
		// concrete type rather than merely an unresolvable one. `Base<T>` and `Der<T>` both spell
		// their parameter `T`, but `Der` passes `Str` up, not its own `T`. So `d.u` is a `Str`,
		// which has no `text` member and no resolution: the wrap is the only sound answer.
		//
		// Without the gate the walk would find `u`'s source `T` through the supertype, match it
		// against `Der`'s OWN parameter list, and substitute `Der`'s argument `Item` — after which
		// `Item.text` resolves, `Str.indexOf` returns `Int`, and the comparison flips. Every later
		// gate passes; only the direct-member test rejects this.
		final model: String = '$MODEL_STR_ITEM\nclass Base<T> {\n\tpublic var u:T;\n}\nclass Der<T:Item> extends Base<Str> {}';
		final params: String = 'q:Bool, d:Der<Item>, k:Str';
		final source: String = wrapTyped('var b = !(!q || d.u.text.indexOf(k) < 0);', params);
		final fixed: String = wrapTyped('var b = q && !(d.u.text.indexOf(k) < 0);', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	public function testSelfReferentialLoopTerminates(): Void {
		// The recursion guard. The iterable is a CHILD of the loop node, so in `for (x in x)` the
		// iterable's `x` resolves straight back to the binder; without `seen` the arm would call
		// itself forever. Reaching the assertion at all is the real subject — the unresolved
		// answer that keeps the wrap is what termination looks like from outside.
		final model: String = MODEL_STR;
		final params: String = 'q:Bool, k:Str';
		final source: String = wrapTyped('for (x in x) {\n\t\t\tvar b = !(!q || x.text.indexOf(k) < 0);\n\t\t}', params);
		final fixed: String = wrapTyped('for (x in x) {\n\t\t\tvar b = q && !(x.text.indexOf(k) < 0);\n\t\t}', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('simplify-negated-compound'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('simplify-negated-compound'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/**
	 * The comprehension form of the same pair. `iterationBindingKinds` lists BOTH loop kinds and the
	 * grammar carries the binder slot on both, so a fixture on the statement form alone would pass
	 * over a model that surfaced only one of them.
	 */
	public function testKeyValueComprehensionValueBinderProvesFlip(): Void {
		final model: String = 'class Fl {\n\tpublic var v:Float;\n}\nclass Cnt {\n\tpublic var v:Int;\n}';
		final params: String = 'q:Bool, m:Map<Fl, Cnt>';
		final source: String = wrapTyped('var xs = [for (kk => vv in m) !(!q || vv.v < 0)];', params);
		final fixed: String = wrapTyped('var xs = [for (kk => vv in m) q && vv.v >= 0];', params);
		Assert.equals(fixed, fixedWith(source, model));
	}

	private function violations(src: String): Array<Violation> {
		return new SimplifyNegatedCompound().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Wrap a single statement body in a minimal, already-CANONICAL class + function so it parses and `fix` can splice into it. */
	private function wrap(body: String): String {
		return wrapTyped(body, '');
	}

	/** `wrap` with a typed parameter list, for the fixtures whose gate needs declared operand types. */
	private function wrapTyped(body: String, params: String): String {
		return canon('class C {\n\tfunction f($params):Void {\n\t\t$body\n\t}\n}');
	}

	/** `source` run through the writer alone — the canonical form `RefactorSupport.canonicalize` demands of a fix input. */
	private function canon(source: String): String {
		return switch RefactorSupport.canonicalize(source, [], true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	private function applyFix(source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: SimplifyNegatedCompound = new SimplifyNegatedCompound();
		final es: Array<{ span: Span, text: String }> = check.fix(source, check.run([{ file: 'C.hx', source: source }], plugin), plugin);
		return es.length == 0 ? source : canonicalized(source, es, plugin);
	}

	/**
	 * `source` fixed once with `model` in the resolution scope — the chain-receiver arm of the
	 * operand-type probe needs a declared scope in `run` AND an index in `fix`.
	 */
	private function fixedWith(source: String, model: String): String {
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: source }];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {report: report, library: new LibrarySources([{ file: 'Res.hx', source: model }]) }
		});
		final check: SimplifyNegatedCompound = new SimplifyNegatedCompound();
		final files: Array<{ file: String, source: String }> = report.concat([{ file: 'Res.hx', source: model }]);
		final vs: Array<Violation> = check.run(report, scoped);
		final es: Array<{ span: Span, text: String }> = check.fix(source, vs, scoped, SymbolIndex.build(files, scoped));
		return es.length == 0 ? source : canonicalized(source, es, scoped);
	}

	private function canonicalized(source: String, es: Array<{ span: Span, text: String }>, plugin: anyparse.query.GrammarPlugin): String {
		return switch RefactorSupport.canonicalize(source, es, false, plugin) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
