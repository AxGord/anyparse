package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RawSourceScan;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;

using Lambda;

/**
 * The one scan behind every "is this name reached by reflection" gate in the check layer, and the
 * containment test the interpolated half of its answer takes.
 *
 * Six checks refuse a rewrite when a member's name might be spelled by a runtime `Reflect` call —
 * `inline-constant` (which erases the field's reflective value), `static-constant` (which moves it
 * off the instance), `prefer-enum-abstract` (which stops the type existing as a runtime class) and
 * the three deletion checks `orphan-accessor` / `unused-public-member` / `unused-private`. Left to
 * walk the scope themselves, the walks did not agree: some collected interpolation FRAGMENTS, some
 * answered only for PLAIN literals, so `Reflect.field(o, '${p}NAME')` was invisible to one pair and
 * visible to the other. The domain of that scan is what makes the difference sound or silent, so it
 * is asked once, here.
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
	 * reading it would decline every rewrite the scope offers. Calibrated as an
	 * accessor prefix's length, which is what the two checks that already had this
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
	 * evidence it never had (a one-file `--fix` converting a type a `Type.resolveClass('pkg.Align')`
	 * in a sibling file reaches: oracle green, `resolveClass` null afterwards). So the scan takes its
	 * file set from `scopeFiles` below, the ONE definition every name-keyed reflection gate shares.
	 * Widening the FILE SET only ever ADDS strings, so it only ever adds REFUSALS — the safe direction
	 * under the nominate-never-disqualify rule, since a LOST refusal is a rewrite that compiles and
	 * fails at run time. The std is demanded by the base arm already, so this does not newly force
	 * the library read.
	 *
	 * RESIDUAL, and it is a CONFIG fact rather than a defect here: a project that declares no
	 * `resolutionRoots` has no resolution scope over its OWN sources, so a one-file lint there still
	 * answers from one file. Declaring them closes it, at the cost of reading the tree per lint.
	 */
	public static function reflectionSurface(files: Array<ScopeFile>, plugin: GrammarPlugin): ReflectionSurface {
		final out: ReflectionSurface = { whole: [], fragments: [], unreadable: [] };
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (stringFold == null) return out;
		final fold: StringFoldSupport = stringFold;
		// The file set is `scopeFiles`' to define, and the de-duplication with it: `whole` keeps
		// duplicates on purpose, since `inline-constant` COUNTS occurrences and subtracts a constant's
		// own value, so a file scanned twice doubles that value and turns its `count > self` test true
		// on nothing at all.
		//
		// A scope file the parser cannot read contributes no literal CONTENTS — there is no tree to take
		// them from — so its RAW SOURCE is kept instead, and `runtimeName` asks it the conservative
		// "may spell it" question per name. Dropping it instead lets an unreadable sibling's
		// `Reflect.field` license rewrites a readable one refuses — `inline-constant` erasing a constant
		// it reads, `prefer-inline` folding a method it names — which is the direction that compiles and
		// then fails at run time. The raw scan is per NAME and only over files that failed to parse, of
		// which a healthy tree has none.
		//
		// MEMOISED per run, and validated against the sources rather than expired — `ReflectionMemo`
		// carries the argument for proving staleness impossible instead of hooking every path that
		// rewrites a report file. A plugin hosting no memo recollects, byte-identically.
		final scope: Array<ScopeFile> = scopeFiles(files, plugin);
		final memo: Null<ReflectionMemo> = RefactorSupport.reflectionMemoOf(plugin);
		final memoised: Null<ReflectionSurface> = memo?.surfaceFor(scope);
		if (memoised != null) return memoised;
		for (entry in scope) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null)
				collect(tree, entry.source, fold, out)
			else
				out.unreadable.push(entry.source);
		}
		memo?.setSurface(scope, out);
		return out;
	}

	/**
	 * Every file a name-keyed reflection gate must consult: `files` UNION the resolution sources,
	 * deduped by path, and an unparseable one handed BACK rather than dropped.
	 *
	 * The ONE definition of that scope: a name-keyed question must admit the library and the std at
	 * every site, or the same name is refused at one gate and rewritten at another. The WIDE half
	 * wins. The narrow (project-only) seam's argument does not carry over — it reasons that a write
	 * to a project type's field must NAME that type, which no haxelib can; a reflective string names
	 * no type at all, so `Reflect.field(o, 'name')` in a library reaches a project member without
	 * ever spelling the project. And the two error directions are not symmetric: an extra name only
	 * DECLINES a rewrite, a missing one lets the rewrite through and breaks a call at run time.
	 *
	 * Handing back the unreadable files is what lets each reader decide about them ITSELF. Dropping
	 * them here would decide for both invisibly — the blindness of a walk over
	 * `SymbolIndex.allFiles()`, which a skip-parsed file is absent from.
	 */
	public static function scopeFiles(files: Array<ScopeFile>, plugin: GrammarPlugin): Array<ScopeFile> {
		// Once per PATH, deduped through a MAP — the same argument `Cli.resolutionThunk`'s sibling dedupe
		// makes. ASYMPTOTIC insurance rather than a measured win: a linear `seen.contains` is one compare
		// per (scope x scope) pair, and a declared `resolutionLibs` puts thousands of paths in the scope,
		// while this whole function is a sliver of a run either way (V8 compares paths drawn from one
		// array by pointer). The widening's cost sits in `Naming.reflectionNamesInOtherFiles`' pre-filter,
		// not in this union. `Bool` values are the flag a Haxe set has to carry.
		final out: Array<ScopeFile> = [];
		final seen: Map<String, Bool> = [];
		inline function take(entry: ScopeFile): Void {
			if (!seen.exists(entry.file)) {
				seen[entry.file] = true;
				out.push(entry);
			}
		}
		for (entry in files) take(entry);
		final resolution: Null<Array<ScopeFile>> = RefactorSupport.resolutionSourcesOf(plugin);
		if (resolution != null) for (entry in resolution) take(entry);
		return out;
	}

	/**
	 * Whether `name` is reached by reflection anywhere in the scope `surface` was taken over — the
	 * WHOLE member question, in the one place its three halves belong together.
	 *
	 * Two of the halves are the surface's own: a plain literal that spells the name, an
	 * interpolation fragment the run could compute it from. The third is what an UNREADABLE scope
	 * file can contribute, and it is not a literal at all — the parser gave no tree, so the file
	 * has no literal CONTENTS to offer and the surface skips it. Its raw text still spells whatever
	 * `Reflect.field` call it holds, so the conservative answer is a word-boundary mention, exactly
	 * as `RawSourceScan.skippedMayReference` answers it for an index that HAS the file.
	 *
	 * That third half is not a no-op: without it an unreadable sibling licenses rewrites a readable
	 * one refuses — `inline-constant` erasing a constant a `Reflect.field` reads, `prefer-inline`
	 * folding a method one names — which is the wrong direction for a file the run could not read.
	 *
	 * A word mention over-refuses: an ordinary call spells the name too. That is the same trade the
	 * skipped-file proofs beside it already make, and the alternative is a rewrite that compiles and
	 * fails at run time.
	 */
	public static function runtimeName(surface: ReflectionSurface, name: String): Bool {
		return surface.whole.contains(name) || runtimeNameFragment(surface.fragments, name)
			|| surface.unreadable.exists(source -> RawSourceScan.mentionsWord(source, name));
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
 * One file of the name-keyed reflection scope: its path and its raw source, parseable or not.
 *
 * A transparent alias for the `{ file, source }` pair the whole check layer passes around — declared
 * so the seam that OWNS that scope has a name for its element, and so the members reading it do not
 * each spell the structure out again. The alias is structural, so every `Check` implementor keeps
 * compiling against the anon spelling; lifting the name into `Check`, next to the `run` signature
 * that introduces the pair, is a sweep across the check layer rather than a change here.
 */
typedef ScopeFile = {
	var file: String;
	var source: String;
};

/**
 * The reflection SURFACE of a scope: every string a member name — or a type's fully-qualified
 * path — could be reached by at runtime.
 *
 * `whole` holds each PLAIN string literal's raw content, DUPLICATES KEPT — one reader counts
 * occurrences rather than asking membership, so a self-named constant (`X = 'X'`) does not trip a
 * gate on its own value. `fragments` holds the deduped static text of every INTERPOLATED literal,
 * each only ever PART of a name the run computes.
 *
 * The three halves take DIFFERENT containment tests, which is why they stay apart: a whole literal is compared
 * against the name, a fragment is asked whether the name could contain IT, and an unreadable source is asked
 * only whether it spells the name as a word. `runtimeName` is where the member question puts all three together.
 */
typedef ReflectionSurface = {
	final whole: Array<String>;
	final fragments: Array<String>;

	/**
	 * The RAW SOURCE of every scope file the parser could not read — no literal contents, because
	 * there is no tree to take them from, and the only honest answer about such a file is that its
	 * bytes may spell any name. `runtimeName` is where that answer is asked.
	 */
	final unreadable: Array<String>;
};
