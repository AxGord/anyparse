package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.SimplifyBooleanTernary;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `simplify-boolean-ternary` check: a ternary with a boolean-literal branch
 * is reduced to a boolean expression, with any negation pushed inward by De
 * Morgan. The four mixed forms and the two pure-literal forms are asserted on the
 * exact rewrite text; a real-valued ternary and a same-literal ternary are left
 * alone.
 */
class SimplifyBooleanTernaryCheckTest extends Test {

	public function testCondXFalseToAnd(): Void {
		Assert.equals('p && x > 0', simplifyOf('return p ? x > 0 : false;'));
	}

	public function testCondTrueXToOr(): Void {
		Assert.equals('p || x > 0', simplifyOf('return p ? true : x > 0;'));
	}

	public function testCondXTrueToNotOr(): Void {
		Assert.equals('!p || x > 0', simplifyOf('return p ? x > 0 : true;'));
	}

	public function testCondFalseXToNotAnd(): Void {
		Assert.equals('!p && x > 0', simplifyOf('return p ? false : x > 0;'));
	}

	public function testDeMorganOrCondition(): Void {
		// cond ? false : x  with a `||` of comparisons -> negation pushed all the way in.
		Assert.equals('a != 0 && b != 0 && x > 0', simplifyOf('return a == 0 || b == 0 ? false : x > 0;'));
	}

	public function testDeMorganAndCondition(): Void {
		// !(a && b) -> !a || !b ; wrapped because `||` binds looser than the joining `&&`.
		Assert.equals('(!a || !b) && x > 0', simplifyOf('return a && b ? false : x > 0;'));
	}

	public function testPureTrueFalseToCond(): Void {
		Assert.equals('a == b', simplifyOf('return a == b ? true : false;'));
	}

	public function testPureFalseTrueToNotCond(): Void {
		Assert.equals('a != b', simplifyOf('return a == b ? false : true;'));
	}

	public function testCompoundCondParenthesised(): Void {
		// cond ? x : false -> cond && x ; a `||` cond is wrapped to keep precedence.
		Assert.equals('(a > 0 || b > 0) && x > 0', simplifyOf('return a > 0 || b > 0 ? x > 0 : false;'));
	}

	public function testNotConditionStripped(): Void {
		// cond ? false : x with cond = !p -> !!p && x -> p && x.
		Assert.equals('p && x > 0', simplifyOf('return !p ? false : x > 0;'));
	}

	public function testRealValuedTernaryNotFlagged(): Void {
		Assert.equals(0, violations('return c ? 1 : 2;').length);
	}

	public function testSameLiteralNotFlagged(): Void {
		// cond ? true : true would drop cond's evaluation — left alone.
		Assert.equals(0, violations('return c ? true : true;').length);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('return p ? x > 0 : false;');
		Assert.equals(1, vs.length);
		Assert.equals('simplify-boolean-ternary', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new SimplifyBooleanTernary().run([{ file: 'Bad.hx', source: 'class Bad { function f() { ' }], new HaxeQueryPlugin()).length
		);
	}

	/**
	 * `claimedSpans` answers exactly what `run` reports, span for span.
	 *
	 * The shared claim IS the fix for the order-dependence with `prefer-if-expression-chain`, and
	 * its whole value is that the two answers cannot diverge: a deferral built on a second walk
	 * carrying its own copy of this check's gate would drift the moment one of them moved — the
	 * defect S46's review found after correcting one side of a two-sided derivation. Both go
	 * through `walkClaims`, so there is one gate and one traversal.
	 *
	 * CANNOT COMPILE at base: no `claimedSpans` exists there.
	 */
	public function testClaimedSpansAnswerTheReportedSpans(): Void {
		final source: String = hosted('Bool', '{ return c ? false : p; }');
		final claimed: Null<Map<String, Bool>> = claimsOf(source);
		if (claimed == null) return;
		final reported: Array<Violation> = new SimplifyBooleanTernary().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
		Assert.equals(1, reported.length, 'the fixture reports exactly one claim: $reported');
		final span: Null<Span> = reported[0].span;
		if (span == null) {
			Assert.fail('the finding carries no span');
			return;
		}
		Assert.isTrue(claimed.exists('${span.from}:${span.to}'), 'the claim set holds the reported span');
		Assert.equals(1, [for (k in claimed.keys()) k].length, 'and holds nothing else');
	}

	/**
	 * CONTROL: a ternary this check does NOT claim is absent from the set too.
	 *
	 * Without it the pin above passes for a `claimedSpans` that answers EVERY ternary — which is
	 * exactly the mutation that would silence `prefer-if-expression-chain` wholesale.
	 */
	public function testClaimedSpansHoldNothingForARealValuedTernary(): Void {
		final source: String = hosted('Int', '{ return c ? a : b; }');
		final claimed: Null<Map<String, Bool>> = claimsOf(source);
		if (claimed == null) return;
		Assert.equals(0, new SimplifyBooleanTernary().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
		Assert.equals(0, [for (k in claimed.keys()) k].length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('simplify-boolean-ternary'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('simplify-boolean-ternary'));
	}

	/** A null-narrowing-guarded condition is left alone — flattening would break the narrowing. */
	public function testNullNarrowingGuardNotSimplified(): Void {
		Assert.equals('', simplifyOf('return c != null && c.foo() != null ? true : x > 0;'));
	}

	/** A bare null-check (no access of the same ident) is still simplified. */
	public function testBareNullCheckStillSimplified(): Void {
		Assert.equals('c != null || x > 0', simplifyOf('return c != null ? true : x > 0;'));
	}

	/** Index-access reuse guards the ternary form too. */
	public function testIndexAccessGuardNotSimplified(): Void {
		Assert.equals('', simplifyOf('return c != null && c[0] > 0 ? true : x > 0;'));
	}

	/** A `null` branch makes the ternary `Null<Bool>`, not a boolean expression — left alone. */
	public function testTrueNullNotSimplified(): Void {
		Assert.equals('', simplifyOf('return p ? true : null;'));
		Assert.equals(0, violations('return p ? true : null;').length);
	}

	/** Same for a `false` / `null` ternary — the `null` branch is not provably Bool. */
	public function testFalseNullNotSimplified(): Void {
		Assert.equals('', simplifyOf('return p ? false : null;'));
	}

	/** A bare-identifier branch may be a `Null<Bool>` local — not provably Bool, so left alone. */
	public function testBareIdentBranchNotSimplified(): Void {
		Assert.equals('', simplifyOf('return p ? true : c;'));
		Assert.equals(0, violations('return p ? true : c;').length);
	}

	/**
	 * THE FLAGSHIP REGRESSION: a `String`-typed ordered comparison keeps its `!( … )` wrap.
	 * Before this rule threaded a type resolver it flipped ordered comparisons UNCONDITIONALLY,
	 * so `(s < t) ? false : a && b` became `s >= t && a && b` — and with `s = null` the original
	 * yields `true` while the rewrite yields `false` (measured on `--interp` and `js`, Haxe
	 * 4.3.7). Haxe has no non-nullable string type, so a `String` declaration proves nothing
	 * about null and the flip is never licensed.
	 */
	public function testStringOrderedComparisonKeepsWrap(): Void {
		Assert.equals('!(s < t) && x > 0', simplifyOf('return s < t ? false : x > 0;'));
	}

	/** Same licence in the `cond ? x : true` arm — the other form that negates the condition. */
	public function testStringOrderedComparisonKeepsWrapInOrArm(): Void {
		Assert.equals('!(s < t) || x > 0', simplifyOf('return s < t ? x > 0 : true;'));
	}

	/** And in the pure-literal `cond ? false : true` arm, whose whole output IS the negation. */
	public function testStringOrderedComparisonKeepsWrapInPureArm(): Void {
		Assert.equals('!(s < t)', simplifyOf('return s < t ? false : true;'));
	}

	/**
	 * A `Float` operand is refused for the other reason the flip can break: `!(y < 0.5)` is
	 * `true` for a NaN `y` where `y >= 0.5` is `false`. The unconditional mode got this wrong
	 * too — the `String` repro is just the one a reviewer reproduced first.
	 */
	public function testFloatOrderedComparisonKeepsWrap(): Void {
		Assert.equals('!(y < 0.5) && x > 0', simplifyOf('return y < 0.5 ? false : x > 0;'));
	}

	/**
	 * PIN (not a discrimination test): an `Int` operand is totally ordered by `<`, so the flip
	 * is licensed and the output is byte-identical to what the unconditional mode emitted. This
	 * passes with the change reverted — that is the point: it pins the promise that proven-Int
	 * shapes did not move.
	 */
	public function testIntOrderedComparisonStillFlips(): Void {
		Assert.equals('x >= 0 && x > 0', simplifyOf('return x < 0 ? false : x > 0;'));
	}

	/** A non-ordered `==` flips regardless of the operand type — NaN and null agree with the wrap. */
	public function testStringEqualityStillFlips(): Void {
		Assert.equals('s != t && x > 0', simplifyOf('return s == t ? false : x > 0;'));
	}

	/**
	 * A declined flip never suppresses the finding: unlike the guard family, this rule is not
	 * inverting a condition for readability — it is eliminating a ternary, and a `!( … )`
	 * operand is already its normal output for any opaque condition. So the site is still
	 * FLAGGED, just reduced with the wrap.
	 *
	 * PIN, not a discrimination test: flagging never consulted the type probe (`run` passes
	 * none, and no `return null` path in the seam reads the negation), so this passes with the
	 * change reverted too. What it pins is the deliberate decision NOT to add a decline gate
	 * here — and, with it, the run/fix invariant that lets `run` skip the resolver.
	 */
	public function testStringOrderedComparisonStillFlagged(): Void {
		Assert.equals(1, violations('return s < t ? false : x > 0;').length);
	}

	/**
	 * THE SLICE: a ternary that is the RETURNED value of a function declaring `:Bool`
	 * reduces even with a non-provably-Bool branch — the declared return type is the proof.
	 * `boolFnSimplifyOf` wraps in `static function f(...): Bool`, the other helpers in
	 * `: Dynamic`, so the two populations stay separated.
	 */
	public function testCallBranchInBoolReturnSimplified(): Void {
		Assert.equals('!p && g()', boolFnSimplifyOf('return p ? false : g();'));
		Assert.equals('p || g()', boolFnSimplifyOf('return p ? true : g();'));
		Assert.equals('p && g()', boolFnSimplifyOf('return p ? g() : false;'));
		Assert.equals('!p || g()', boolFnSimplifyOf('return p ? g() : true;'));
	}

	/** The same ternary in a `:Dynamic` function keeps the old refusal. */
	public function testCallBranchInDynamicReturnNotSimplified(): Void {
		Assert.equals('', simplifyOf('return p ? false : g();'));
	}

	/** `Null<Bool>` proves nothing — refused. */
	public function testCallBranchInNullBoolReturnNotSimplified(): Void {
		Assert.equals('', nullBoolFnSimplifyOf('return p ? false : g();'));
	}

	/** An EXPRESSION body (`function f(): Bool return …`) is the function's returned value too. */
	public function testCallBranchInBoolExpressionBodySimplified(): Void {
		Assert.equals('!p && g()', boolFnExprBodySimplifyOf('p ? false : g()'));
	}

	/** Only the DIRECT returned value: a ternary nested inside the returned expression is not licensed. */
	public function testNestedTernaryInBoolReturnNotSimplified(): Void {
		Assert.equals('', boolFnSimplifyOf('return h(p ? false : g());'));
	}

	/** A `null` branch stays refused even in a `:Bool` function — `!p && null` is degenerate. */
	public function testNullBranchInBoolReturnNotSimplified(): Void {
		Assert.equals('', boolFnSimplifyOf('return p ? false : null;'));
	}

	/** A statement-like branch stays refused even in a `:Bool` function. */
	public function testStatementLikeBranchInBoolReturnNotSimplified(): Void {
		Assert.equals('', boolFnSimplifyOf('return p ? false : try g() catch (e:Dynamic) false;'));
		Assert.equals('', boolFnSimplifyOf('return p ? false : switch (x) { case 1: true; case _: false; };'));
	}

	/** A branch that is itself a mid-reduction ternary is refused: reducing the outer would strand it. */
	public function testPendingBooleanTernaryBranchNotSimplified(): Void {
		Assert.equals('', boolFnSimplifyOf('return p ? true : (c ? false : g());'));
	}

	/** `claimedSpans` over `source`, or null after failing the test when the fixture does not parse. */
	private function claimsOf(source: String): Null<Map<String, Bool>> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree != null) return SimplifyBooleanTernary.claimedSpans(source, tree, plugin);
		Assert.fail('the fixture does not parse');
		return null;
	}

	private function violations(body: String): Array<Violation> {
		return new SimplifyBooleanTernary().run([{ file: 'C.hx', source: hosted('Dynamic', body) }], new HaxeQueryPlugin());
	}

	/** The rewrite text the fix emits for the first ternary in `body` (empty if none). */
	private function simplifyOf(body: String): String {
		return firstEdit(hosted('Dynamic', body));
	}

	/** The rewrite text for the first ternary in `body`, wrapped in a `: Bool` function. */
	private function boolFnSimplifyOf(body: String): String {
		return firstEdit(hosted('Bool', body));
	}

	/** As `boolFnSimplifyOf`, but the function declares `: Null<Bool>` — the proof a nullable type does not give. */
	private function nullBoolFnSimplifyOf(body: String): String {
		return firstEdit(hosted('Null<Bool>', body));
	}

	/** As `boolFnSimplifyOf`, but the body is an EXPRESSION body rather than a `return` statement. */
	private function boolFnExprBodySimplifyOf(body: String): String {
		return firstEdit('class C { static function f(a: Int, b: Int, c: Bool, p: Bool, x: Int): Bool return ${body}; }');
	}

	/** `body` inside one host function declaring `: ${ret}` — the return type IS the variable these tests turn. */
	private function hosted(ret: String, body: String): String {
		return 'class C { static function f(a: Int, b: Int, c: Bool, p: Bool, x: Int, s: String, t: String, y: Float): ${ret} ${body} }';
	}

	/** The first rewrite `fix` emits for `src`, or an empty string when there is none. */
	private function firstEdit(src: String): String {
		final check: SimplifyBooleanTernary = new SimplifyBooleanTernary();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length > 0 ? edits[0].text : '';
	}

}
