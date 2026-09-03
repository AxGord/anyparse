package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * ω-group-rest-probe on a STRUCT-FIELD Star, and the dual-dispatch fork it used to
 * have (T169, closed by the gate in `WriterLowering.emitSepStarList`).
 *
 * `@:fmt(groupRestProbe)` makes a list's outer Group charge the same-line tail
 * after its close delimiter to the fit probe, so `typedef Foo<A, B> = Rhs;` wraps
 * its type parameters when the ASSIGNMENT is what pushes the line past the limit.
 * 21 grammar sites carry the flag. 18 are struct-field Stars: every declare-site
 * `<T, …>` list in the language (class / interface / enum / enum-ctor / abstract /
 * typedef / function / anon-function head, plus the two `…Head` twins) and
 * `HxNewExpr.params` / `HxTypeRef.params` / `HxArrowFnType.args`, then
 * `HxFnDecl.params`, `HxCondNameFnDecl.params`, `HxNewExpr.args` and
 * `HxObjectLit.fields`. Three more are enum-ctor payloads: `HxType.Anon`,
 * `HxExpr.ArrayExpr` and `HxExpr.Call`. Only the last four of the 18 carry
 * `@:trivia`. This census is the canonical one — the `WriterLowering` comment
 * quotes its 14-of-18 figure from here.
 *
 * They reach the engine through THREE dispatches, all now gated:
 *
 *  - `WriterLowering.emitSepStarList`, the non-trivia struct-Star dispatch. It is
 *    the ONLY path for a Star without `@:trivia` — 14 of the 18, in BOTH writers —
 *    and it is the plain writer's path for the other four. It passes
 *    `groupRestProbe && !opt._suppressPatternRestProbe`, and until T169 it passed a
 *    macro-time constant instead: a case pattern sets that flag over its whole
 *    subtree precisely so nothing below it charges the trailing guard to its own
 *    fit, and this dispatch was not listening.
 *  - `TriviaSepLowering`'s no-trivia branch, taken by a `@:trivia` struct Star or an
 *    enum-Alt Star in the trivia writer. Same expression.
 *  - `WriterLowering.lowerPostfixSepListCall`, the `HxExpr.Call` gate, shared by
 *    both writers. It passes
 *    `!opt._suppressCallRestProbe && !opt._suppressPatternRestProbe`.
 *
 * The backlog note at the fixed site called the gap plain-only and therefore
 * unreachable by any fixture, since `writeRoundTrip` / `fmt` / every canonical gate
 * drive the trivia writer. That was wrong, and the third test below is the
 * counter-example: 14 of the 18 carriers have no `@:trivia`, so the TRIVIA writer
 * reached the ungated dispatch as well and `fmt` saw the gap.
 *
 * (`lowerEnumStarPlain`, the plain path of the three enum-ctor carriers, passes no
 * `groupRestProbe` option at all, so the flag is a silent no-op there — a separate
 * gap, not covered here.)
 *
 * Mutation arms named per assertion in the method docs below:
 *
 *  - M2 — drop `suppressPatternRestProbe` from `HxCasePattern.expr`, the flag's only
 *    grammar set-site.
 *  - M4 — `groupRestProbe: $v{false}` at the non-trivia dispatch. Its only killer in
 *    this class is `testTypeParamsRestProbeTheAssignmentTail`; both pattern tests
 *    survive it, because turning the probe off entirely also leaves a pattern flat.
 *  - M6 — strip `&& !opt._suppressPatternRestProbe` from `TriviaSepLowering`.
 *  - M7 — revert this slice's gate, restoring the macro-time constant.
 */
@:nullSafety(Strict)
final class HxGroupRestProbeStructStarTest extends Test {

	/** Type parameters wrap one-per-line as soon as the whole line exceeds 60. */
	private static final TYPE_PARAM_CONFIG: String = '{"wrapping": {"maxLineLength": 60, "typeParameter": {"defaultWrap": '
		+ '"ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLine"}]}}}';

	/**
	 * The same type-parameter cascade with every construct that could ABSORB the
	 * overflow pinned to `noWrap`, so the type-parameter list is the only thing on
	 * the line that can break and the assertion cannot be satisfied by a guard
	 * wrap instead.
	 */
	private static final PATTERN_TYPE_PARAM_CONFIG: String = '{"wrapping": {"maxLineLength": 60, "typeParameter": '
		+ '{"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": '
		+ '"onePerLine"}]}, "casePattern": {"defaultWrap": "noWrap", "rules": []}, "conditionWrapping": {"defaultWrap": '
		+ '"noWrap", "rules": []}, "opBoolChain": {"defaultWrap": "noWrap", "rules": []}}}';

	/**
	 * `HxObjectLit.fields` is a `@:trivia` Star, so it is the shape where the two
	 * struct-Star dispatches genuinely FORK: the trivia writer gates the probe,
	 * the plain writer does not. Everything that could absorb the overflow
	 * INSTEAD of the literal is pinned to `noWrap` with an empty cascade, and the
	 * fixture's guard is a single identifier — nothing in it can break — so the
	 * object literal is the only movable thing on the line.
	 */
	private static final OBJECT_PATTERN_CONFIG: String = '{"wrapping": {"maxLineLength": 60, "objectLiteral": '
		+ '{"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": '
		+ '"onePerLine"}]}, "callParameter": {"defaultWrap": "noWrap", "rules": []}, "casePattern": {"defaultWrap": '
		+ '"noWrap", "rules": []}, "conditionWrapping": {"defaultWrap": "noWrap", "rules": []}, "opBoolChain": '
		+ '{"defaultWrap": "noWrap", "rules": []}}}';

	public function new(): Void {
		super();
	}

	/**
	 * The mechanism itself, and the suite's first coverage of the PLAIN writer's
	 * wrap output. `typedef Foo<AlphaParameter, BetaParameter>` is 42 columns and
	 * fits; only the ` = R…;` tail takes the line to 61. Both writers wrap the
	 * type parameters, byte-identically — the rest probe is what sees that tail.
	 *
	 * M4's only killer in this class: with `groupRestProbe: $v{false}` the
	 * 42-column list fits under the limit on its own, `defaultWrap: "ignore"`
	 * leaves it flat, and both `Assert.equals(wrapped, …)` fail. The two pattern
	 * tests below survive M4, so nothing else here covers it.
	 */
	public function testTypeParamsRestProbeTheAssignmentTail(): Void {
		final src: String = 'typedef Foo<AlphaParameter, BetaParameter> = RRRRRRRRRRRRRRR;';
		final wrapped: String = 'typedef Foo<\n\tAlphaParameter,\n\tBetaParameter\n> = RRRRRRRRRRRRRRR;';
		Assert.equals(wrapped, HxWriteFixture.triviaWrite(src, TYPE_PARAM_CONFIG));
		Assert.equals(wrapped, HxWriteFixture.plainWrite(src, TYPE_PARAM_CONFIG));
	}

	/**
	 * One column shorter — exactly 60 — and nothing breaks, in either writer. The
	 * strict limit+1 boundary, and the control that keeps the test above from
	 * passing on a writer that simply wraps every type-parameter list.
	 *
	 * Both assertions are identity, so no arm that turns the rest probe OFF can
	 * flip this one: its killer is the opposite mutation, an off-by-one that
	 * loosens the fit predicate (`>` to `>=` in the exceeds check). The pair is
	 * what discriminates — the method above expects the WRAPPED text, so an
	 * always-wrapping writer fails there and an always-flat one fails here.
	 */
	public function testTypeParamsExactlyOnTheLimitStayFlat(): Void {
		final src: String = 'typedef Foo<AlphaParameter, BetaParameter> = RRRRRRRRRRRRRR;';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, TYPE_PARAM_CONFIG));
		Assert.equals(src, HxWriteFixture.plainWrite(src, TYPE_PARAM_CONFIG));
	}

	/**
	 * T169's TRIVIA arm — the counter-example to "the plain writer is the only way
	 * in", and the reason the gate could not stay deferred. `HxTypeRef.params` has
	 * no `@:trivia`, so even the trivia writer routes it through
	 * `emitSepStarList`; before the gate, the type-parameter list inside a case
	 * pattern was charged the trailing `) if (isReady && isSet):` and broke, in
	 * BOTH writers. A pattern is a matching shape, not a value — it never owns the
	 * line's overflow — so the whole `case` line now stays flat and long.
	 *
	 * Killed by reverting the gate (arm M7, `groupRestProbe: $v{groupRestProbe}`
	 * back at the plain site: both assertions) and by arm M2 (drop
	 * `suppressPatternRestProbe` from `HxCasePattern.expr`, which is what the gate
	 * reads). NOT killed by M4 (`groupRestProbe: $v{false}`) — turning the probe
	 * off entirely also leaves the line flat, which is why M4's killer is
	 * `testTypeParamsRestProbeTheAssignmentTail` instead.
	 */
	public function testCasePatternTypeParamsDeclineTheRestProbe(): Void {
		final src: String = 'class C {\n\tstatic function f(): Void {\n\t\tswitch v {\n\t\t\tcase (x : Map<AlphaParam, '
			+ 'BetaParam>) if (isReady && isSet):\n\t\t\t\tg();\n\t\t}\n\t}\n}';
		final trivia: String = HxWriteFixture.triviaWrite(src, PATTERN_TYPE_PARAM_CONFIG);
		final plain: String = HxWriteFixture.plainWrite(src, PATTERN_TYPE_PARAM_CONFIG);
		// Positive form on purpose: `indexOf('Map<\n') < 0` would also hold of an
		// empty or truncated output, and of the untransformed input.
		Assert.isTrue(trivia.indexOf('Map<AlphaParam, BetaParam>') >= 0, 'the pattern declines the rest probe, got:\n<$trivia>');
		Assert.isTrue(plain.indexOf('Map<AlphaParam, BetaParam>') >= 0, 'the pattern declines the rest probe, got:\n<$plain>');
	}

	/**
	 * The shape where the two struct-Star dispatches used to FORK.
	 * `HxObjectLit.fields` carries `@:trivia`, so the trivia writer takes the
	 * `TriviaSepLowering` dispatch and the plain writer takes `emitSepStarList` —
	 * the same AST, the same config, the same limit, and until the gate landed,
	 * two different answers. Both now decline the probe below a pattern.
	 *
	 * The literal closes at column 48 and the line reaches 63 only because of the
	 * trailing `) if (isReady):`, so the rest probe is the only thing that can
	 * move it; the guard is one identifier and every sibling cascade is pinned, so
	 * neither assertion can be satisfied by something else breaking.
	 *
	 * Two dispatches, two independent killers, which is the whole point of
	 * asserting them side by side: the trivia assertion dies under M6 (strip
	 * `&& !opt._suppressPatternRestProbe` from `TriviaSepLowering`) and under M2
	 * (drop the flag at its grammar set-site); the plain assertion dies under M7
	 * (revert the gate) and under M2. Neither dies under M4, which turns the probe
	 * off on both paths and so satisfies both.
	 */
	public function testObjectLiteralPatternDeclinesTheRestProbeInBothWriters(): Void {
		final src: String = 'class C {\n\tstatic function g():Void {\n\t\tswitch field.kind {\n\t\t\tcase FVar(t, {expr: '
			+ 'E(tp), meta: mm}) if (isReady):\n\t\t\t\tg();\n\t\t}\n\t}\n}';
		final trivia: String = HxWriteFixture.triviaWrite(src, OBJECT_PATTERN_CONFIG);
		final plain: String = HxWriteFixture.plainWrite(src, OBJECT_PATTERN_CONFIG);
		Assert.isTrue(trivia.indexOf('{expr: E(tp), meta: mm}') >= 0, 'the trivia writer gates it, got:\n<$trivia>');
		Assert.isTrue(plain.indexOf('{expr: E(tp), meta: mm}') >= 0, 'the plain writer gates it too, got:\n<$plain>');
	}

}
