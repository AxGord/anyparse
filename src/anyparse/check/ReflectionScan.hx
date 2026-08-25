package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;

using Lambda;

/**
 * The one scan behind every "is this name reached by reflection" gate in the check layer, and the
 * containment test the interpolated half of its answer takes.
 *
 * Five checks refuse a rewrite when a member's name might be spelled by a runtime `Reflect` call —
 * `inline-constant` (which erases the field's reflective value), `static-constant` (which moves it
 * off the instance), `prefer-enum-abstract` (which stops the type existing as a runtime class) and
 * the two deletion checks `orphan-accessor` / `unused-public-member`. Each of them used to walk the
 * scope itself, and the walks did not agree: two collected interpolation FRAGMENTS, two answered
 * only for PLAIN literals, so `Reflect.field(o, '${p}NAME')` was invisible to one pair and visible
 * to the other. The domain of that scan is what makes the difference sound or silent, so it is
 * asked once, here.
 *
 * ONE scan, TWO questions. A MEMBER is reached by its bare name (`Reflect.field(o, 'NAME')`), a
 * TYPE only by its fully-qualified dot path (`Type.resolveClass('pkg.Align')`) — so the containment
 * tests fork where the scan does not: `runtimeNameFragment` for the member question,
 * `runtimeTypePath` / `runtimeTypePathFragment` for the type one. Asking the MEMBER test about a
 * type is what let `prefer-enum-abstract` convert a type a qualified `resolveClass` reached: it
 * compiles either way and answers null afterwards.
 */
@:nullSafety(Strict)
final class ReflectionScan {

	/**
	 * The shortest static fragment of an interpolated string that carries reflection INTENT. Below it
	 * a fragment is punctuation or a syllable — contained in half the names of any scope — and a gate
	 * reading it would decline every rewrite the scope offers. Calibrated as an accessor prefix's length, which is what the two checks that already had this
	 * test each reached for independently.
	 */
	private static inline final MIN_NAME_FRAGMENT_LENGTH: Int = 4;

	/**
	 * Every string across `files` a member name or a type PATH could be reached by at runtime — the
	 * reflection surface no structural scan sees.
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
	 *
	 * SCOPE — report UNION the resolution sources, never the report set alone. The report set is
	 * whatever the caller asked to lint, and a caller may ask for ONE file; a literal absent THERE is
	 * not evidence of absence in the project, so a gate answered from it authorises a rewrite on
	 * evidence it never had. Measured end to end: `hxq lint <one-file> --fix` converted a type a
	 * `Type.resolveClass('pkg.Align')` in a sibling file reaches — oracle green, `resolveClass` null
	 * afterwards. So the scan also takes `RefactorSupport.resolutionSourcesOf`, the seam
	 * `UnusedPublicMember.tokenCounts` already reads three lines from its own call of this function,
	 * for exactly this reason. Widening the FILE SET only ever ADDS strings, so it only ever adds
	 * REFUSALS — the safe direction under the nominate-never-disqualify rule, since a LOST refusal is
	 * a rewrite that compiles and fails at run time. Cost, measured: Pony (867 files, 3643 findings) moved 0 added / 0 removed, and a single-file
	 * lint stayed at ~1.0s. It also does not newly FORCE the library read in a project that declares no
	 * `resolutionLibs` and enables only default-on rules: 0.63s -> 0.66s there, against 0.14s with
	 * `APQ_NO_STD=1` — the std was already being demanded by the base arm, not by this change.
	 *
	 * RESIDUAL, and it is a CONFIG fact rather than a defect here: a project that declares no
	 * `resolutionRoots` has no resolution scope over its OWN sources, so a one-file lint there still
	 * answers from one file. Declaring them closes it and costs that lint ~1.0s -> ~4.5s.
	 */
	public static function reflectionSurface(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): ReflectionSurface {
		final out: ReflectionSurface = { whole: [], fragments: [] };
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (stringFold == null) return out;
		final fold: StringFoldSupport = stringFold;
		// Once per PATH, deduped through a linear scan — measured at no cost (Pony 867 files 12.4s -> 11.9s, anyparse 1487 files 1:55.9 -> 1:54.3), which is why it is not the `Map` the sibling dedupe in `Cli.resolutionThunk` argues for. The two halves overlap — `resolutionFiles` is report UNION library — and
		// `whole` keeps duplicates on purpose, since `inline-constant` COUNTS occurrences and
		// subtracts a constant's own value; a file scanned twice doubles that value and turns its
		// `count > self` test true on nothing at all.
		final scanned: Array<String> = [];
		inline function scan(entry: { file: String, source: String }): Void {
			if (!scanned.contains(entry.file)) {
				scanned.push(entry.file);
				final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
				if (tree != null) collect(tree, entry.source, fold, out);
			}
		}
		for (entry in files) scan(entry);
		final resolution: Null<Array<{ file: String, source: String }>> = RefactorSupport.resolutionSourcesOf(plugin);
		if (resolution != null) for (entry in resolution) scan(entry);
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
	 * Whether some PLAIN literal in `whole` spells the TYPE `name` the way a runtime lookup has to.
	 *
	 * A type is not reached by its simple name. `Type.resolveClass` / `Type.resolveEnum` take the
	 * FULLY-QUALIFIED dot path, so the literal that reaches `pkg.Align` at run time is `'pkg.Align'`,
	 * and a bare `'Align'` reaches it only from the root package. An equality test against the simple
	 * name is therefore the right answer for root-package types and for nothing else — which is why
	 * the TYPE question takes its own containment test rather than borrowing the member one's.
	 *
	 * The test reads the literal's LAST dot-segment, so it is a path test and never a substring one:
	 * `'pkg.MisAlign'` ends with `Align` yet names a different type, so only a `.` — or the literal's
	 * own start — counts as the separator that makes the tail the type's own name. The bare equality
	 * stays in front of it so the test is a superset of the one it replaced for ANY `name`, not only
	 * for the dot-free ones a type declaration can spell.
	 */
	public static function runtimeTypePath(whole: Array<String>, name: String): Bool {
		return whole.exists(literal -> literal == name || CheckScan.simpleModuleName(literal) == name);
	}

	/**
	 * Whether some static FRAGMENT of an interpolated string could spell the TYPE `name` at runtime.
	 *
	 * A fragment is only PART of the path the run computes, so the containment runs the same way
	 * round as in `runtimeNameFragment`. What differs is that the fragment can carry the path
	 * SEPARATOR with it — the static text of `'${pkg}.Align'` is `.Align`, which no simple name ever contains — so the
	 * fragment is read from its last `.` onward, and that segment then takes the same test and the
	 * same `MIN_NAME_FRAGMENT_LENGTH` floor. The floor is load-bearing here and not merely an
	 * over-refusal guard: a fragment of `'.'` alone segments to the empty string, which every name
	 * contains.
	 *
	 * A type name holds no `.`, so a dotted fragment can never pass `runtimeNameFragment`: this
	 * answers everything that one does for a type name, and the qualified spellings besides.
	 */
	public static function runtimeTypePathFragment(fragments: Array<String>, name: String): Bool {
		return fragments.exists(fragment -> {
			final segment: String = CheckScan.simpleModuleName(fragment);
			return segment.length >= MIN_NAME_FRAGMENT_LENGTH && name.indexOf(segment) >= 0;
		});
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
 * The reflection SURFACE of a scope: every string a member name — or a type's fully-qualified
 * path — could be reached by at runtime.
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
