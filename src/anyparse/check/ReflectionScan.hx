package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;

using Lambda;

/**
 * The one scan behind every "is this name reached by reflection" gate in the check layer, and the
 * containment test the interpolated half of its answer takes.
 *
 * Four checks refuse a rewrite when a member's name might be spelled by a runtime `Reflect` call —
 * `inline-constant` (which erases the field's reflective value), `static-constant` (which moves it
 * off the instance), `prefer-enum-abstract` (which stops the type existing as a runtime class) and
 * the two deletion checks `orphan-accessor` / `unused-public-member`. Each of them used to walk the
 * scope itself, and the walks did not agree: two collected interpolation FRAGMENTS, two answered
 * only for PLAIN literals, so `Reflect.field(o, '${p}NAME')` was invisible to one pair and visible
 * to the other. The domain of that scan is what makes the difference sound or silent, so it is
 * asked once, here.
 */
@:nullSafety(Strict)
final class ReflectionScan {

	/**
	 * The shortest static fragment of an interpolated string that carries reflection INTENT. Below it
	 * a fragment is punctuation or a syllable — contained in half the names of any scope — and a gate
	 * reading it would decline every rewrite the scope offers. Calibrated as an accessor prefix's
	 * length, which is what the two checks that already had this test each reached for independently.
	 */
	private static inline final MIN_NAME_FRAGMENT_LENGTH: Int = 4;

	/**
	 * Every string across `files` a member name could be reached by at runtime — the reflection
	 * surface no structural scan sees.
	 *
	 * The split into two lists is the whole point. `StringFoldSupport.literalOf` answers null for an
	 * INTERPOLATED literal by contract, so a scan built on it alone reports `Reflect.field(o,
	 * '${p}NAME')` as no mention of `NAME` at all — and each rewrite gated here then breaks that call
	 * SILENTLY at runtime, with nothing at compile time to catch it.
	 *
	 * `whole` is each PLAIN literal's raw content with DUPLICATES KEPT — one reader counts
	 * occurrences rather than asking membership, so a self-named constant (`X = 'X'`) can subtract
	 * its OWN value. `fragments` is the deduped static text of every interpolated literal; a fragment
	 * is only ever PART of the computed name, so the test that reads it runs the other way round
	 * (`runtimeNameFragment`).
	 *
	 * Empty when the grammar exposes no string-fold support: that loses the gate, never the check.
	 */
	public static function reflectionSurface(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): ReflectionSurface {
		final out: ReflectionSurface = { whole: [], fragments: [] };
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (stringFold == null) return out;
		final fold: StringFoldSupport = stringFold;
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) collect(tree, entry.source, fold, out);
		}
		return out;
	}

	/**
	 * Whether some static FRAGMENT of an interpolated string in scope could spell `name` at runtime.
	 * Containment runs the opposite way from a whole literal's: a fragment is only part of the name
	 * the run computes, so that name can be `name` only when the fragment is CONTAINED IN it.
	 *
	 * `MIN_NAME_FRAGMENT_LENGTH` is what stops the gate declining everything, and its cost is stated
	 * there: a member whose whole name is shorter than the floor is out of this test's reach, and the
	 * surface's whole-literal half is what covers it.
	 */
	public static function runtimeNameFragment(fragments: Array<String>, name: String): Bool {
		return fragments.exists(fragment -> fragment.length >= MIN_NAME_FRAGMENT_LENGTH && name.indexOf(fragment) >= 0);
	}

	/**
	 * Collect into `out` the plain-literal content and the interpolation fragments that `node` and its
	 * descendants carry. A node the fold answers for is a PLAIN literal and contributes its content;
	 * one whose kind is a string-EXPRESSION host contributes each static `Literal` child instead.
	 */
	private static function collect(node: QueryNode, source: String, fold: StringFoldSupport, out: ReflectionSurface): Void {
		final literal: Null<StringLiteral> = fold.literalOf(node, source);
		if (literal != null)
			out.whole.push(literal.content);
		else if (CheckScan.STRING_EXPR_KINDS.contains(node.kind))
			for (child in node.children) {
				final fragment: Null<String> = child.name;
				if (child.kind == CheckScan.STRING_FRAGMENT_KIND && fragment != null && !out.fragments.contains(fragment))
					out.fragments.push(fragment);
			}
		for (child in node.children) collect(child, source, fold, out);
	}

}

/**
 * The reflection SURFACE of a scope: every string a member name could be reached by at runtime.
 *
 * `whole` holds each PLAIN string literal's raw content, DUPLICATES KEPT — one reader counts
 * occurrences rather than asking membership, so a self-named constant (`X = 'X'`) does not trip a
 * gate on its own value. `fragments` holds the deduped static text of every INTERPOLATED literal,
 * each only ever PART of a name the run computes.
 *
 * The two halves take DIFFERENT containment tests, which is why they stay apart: a whole literal is
 * compared against the name, a fragment is asked whether the name could contain IT.
 */
typedef ReflectionSurface = {
	final whole: Array<String>;
	final fragments: Array<String>;
};
