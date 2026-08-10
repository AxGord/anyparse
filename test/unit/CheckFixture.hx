package unit;

import anyparse.check.Check;
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
	 * `source` after `check`'s own autofix: run it over the single synthetic file
	 * `C.hx`, hand the findings straight back to `fix`, and apply the edits. The
	 * splice is raw — unlike the `lint --fix` path it neither drops contained edits
	 * nor canonicalizes, so the result is the edits' literal effect on `source`.
	 */
	public static function fixedSource(check: Check, source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final violations: Array<Violation> = check.run([{ file: 'C.hx', source: source }], plugin);
		return applyEdits(source, check.fix(source, violations, plugin));
	}

}
