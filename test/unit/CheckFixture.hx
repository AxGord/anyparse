package unit;

import anyparse.check.Check;
import utest.Assert;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * Shared in-memory harness for the analysis-check test suites.
 *
 * A check test exercises `run` on an inline source and then, for a fixable check,
 * applies `fix`'s edits back onto that source and asserts the rewritten text. Both
 * halves are the same two moves in every suite — order the edits last-first so an
 * earlier span keeps its offsets, then splice them in — so they live here once
 * instead of once per test class.
 */
@:nullSafety(Strict)
final class CheckFixture {

	/**
	 * The two characters that close a `final e = macro …;` quotation — where the runtime half of a
	 * gate fixture begins. The LAST occurrence is the threshold: a `};` can legitimately appear
	 * INSIDE the quotation (an object literal, a nested lambda), never in the runtime half of the
	 * fixtures this serves, so `lastIndexOf` keeps the assertion tight where `indexOf` would let a
	 * quoted finding past an early inner `};`.
	 */
	private static inline final QUOTATION_END: String = '};';

	/**
	 * `source` with `edits` spliced in, applied last-first so an earlier edit's
	 * span is still valid when it is applied. The input array is not reordered.
	 */
	public static function applyEdits(source: String, edits: Array<{ span: Span, text: String }>): String {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	/**
	 * Assert that `violations` is exactly ONE finding and that it sits AFTER the macro quotation
	 * `source` opens with — the discriminating half of the reification-gate pair the switch-family
	 * checks carry. `source` is a fixture whose trigger shape appears TWICE, once quoted and once as
	 * real code; a check that still descends into the quotation reports both, so the count alone
	 * fails, and a check that reports the wrong one fails the position. `what` names the construct
	 * for the failure message.
	 */
	public static function assertOnlyAfterQuotation(violations: Array<Violation>, source: String, what: String): Void {
		Assert.equals(1, violations.length);
		final span: Null<Span> = violations[0].span;
		Assert.isTrue(
			span != null && span.from > source.lastIndexOf(QUOTATION_END), 'the finding must be the RUNTIME $what, not the quoted one'
		);
	}

	public static function fixedSource(check: Check, source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final violations: Array<Violation> = check.run([{ file: 'C.hx', source: source }], plugin);
		return applyEdits(source, check.fix(source, violations, plugin));
	}

}
