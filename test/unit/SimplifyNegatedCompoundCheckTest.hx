package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.SimplifyNegatedCompound;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The `simplify-negated-compound` check: a logical-not over a `&&` / `||` compound is
 * flagged `Info` and De Morganed — but ONLY when the rewrite strictly reduces the unary-`!`
 * count, so `!(!a || b)` → `a && !b` is offered and `!(a || b)` → `!a && !b` is not. The
 * rewrite text comes from the same `BooleanLogicSupport` engine the guard family inverts
 * with, so an ordered comparison stays wrapped `!(a < b)` unless both operands resolve to a
 * NaN-free type — which now includes a method call's return type resolved through its
 * receiver chain. Gates: a comment in the span, a `#if` region, a stranded null-safety
 * narrowing, a macro-reification subtree, and a non-logical (`|` / `&`) operand all refuse.
 */
class SimplifyNegatedCompoundCheckTest extends Test {

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

	public function testSingleTermNotFlagged(): Void {
		// Not a compound. `!(f < 0.5)` is the NaN wrap, refused by the worth gate (the wrap is all
		// the negation can emit); `!(!p)` is `double-negation`'s shape and WOULD pay, so it is the
		// compound-kind gate alone that keeps this rule off it.
		Assert.equals(0, violations(wrap('var b = !(f < 0.5);')).length);
		Assert.equals(0, violations(wrap('var b = !(!p);')).length);
	}

	public function testBitwiseOperandNotFlagged(): Void {
		// `|` is a bitwise operator, not the logical-or chain kind, so the compound gate never
		// reads it as a chain — and it is opaque to the negation engine besides, so the worth gate
		// would refuse it anyway. Two independent reasons; the fixture pins the outcome, not one.
		Assert.equals(0, violations(wrap('var b = !(x | y);')).length);
	}

	public function testFixDropsOuterNegation(): Void {
		Assert.equals(wrap('var b = p && !q;'), applyFix(wrap('var b = !(!p || q);')));
	}

	public function testFixFlipsComparisonPair(): Void {
		Assert.equals(wrap('var b = x != y || z == w;'), applyFix(wrap('var b = !(x == y && z != w);')));
	}

	public function testFixKeepsUnprovenOrderedComparisonWrapped(): Void {
		// The NaN gate cannot type `f`, so its comparison stays wrapped — a PARTIAL
		// simplification, still one `!` fewer than the input.
		Assert.equals(wrap('var b = p && !(f < 0.5);'), applyFix(wrap('var b = !(!p || f < 0.5);')));
	}

	public function testFixFlipsOrderedComparisonWhenIntProven(): Void {
		Assert.equals(wrapTyped('var b = p && n >= 0;', 'p:Bool, n:Int'), applyFix(wrapTyped('var b = !(!p || n < 0);', 'p:Bool, n:Int')));
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

	public function testStrandedNarrowingNotFlagged(): Void {
		// Worth passes (one `!` stripped), but negating the `&&` chain into `||` would strand
		// the `b` narrowing operand 2 depends on — the shared gate refuses first.
		Assert.equals(0, violations(wrap('var v = !(a != null && b != null && !p(a.x, b.y));')).length);
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
		final model: String = 'class Str {\n\tpublic function indexOf(s:Str):Int return 0;\n}\n' + 'class Item {\n\tpublic var text:Str;\n}';
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

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('simplify-negated-compound'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('simplify-negated-compound'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
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
