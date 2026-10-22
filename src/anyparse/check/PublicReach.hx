package anyparse.check;

import anyparse.query.MemberKinds;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * The whole-project REACH evidence a fix needs before it may act on the claim "nothing outside
 * this region names that member" - built for `unused-public-member`'s deletions and shared with
 * `naming`'s privatize arm, so the two ask ONE set of questions instead of keeping two copies.
 *
 * Three families of question, each answered conservatively (an unprovable answer always lands on
 * the side that leaves the member alone):
 *
 * - The REFERENCE test (`tokenCounts` + `occursOnlyWithin`): a raw identifier-token count over
 *   report UNION resolution scope, built once per run, compared with the count inside the regions
 *   that are allowed to name the member; then the authoritative raw-text confirm on an index, which
 *   also reads the `\x24name` interpolation escape the plain tokenizer swallows. Raw text, so a
 *   comment, a string literal, a `#if` branch, a library or an unrelated same-named member all count
 *   as an occurrence - and so does a structure field of a typedef the class could unify with, which
 *   is why no separate structural-unification gate exists.
 * - The TYPE gates (`typeOutOfReach`, `chainOutOfReach`): `@:keep` / `@:build` / `extern` on the
 *   type, an RTTI-carrying hierarchy, an ancestor's `@:autoBuild`, and a supertype that fails to
 *   resolve.
 * - The MEMBER run (`readRun`): the modifier / metadata run in front of one member, read as
 *   `OrphanAccessor` reads it.
 */
@:nullSafety(Strict)
final class PublicReach {

	/** The modifier sibling an explicit `public` projects as. */
	private static inline final PUBLIC_MODIFIER: String = 'Public';

	/** The modifier sibling `override` projects as. */
	private static inline final OVERRIDE_MODIFIER: String = 'Override';

	/** The modifier sibling `static` projects as - the one modifier no framework contract claims. */
	private static inline final STATIC_MODIFIER: String = 'Static';

	/**
	 * Whether `declared`'s own annotations put its members out of any source scan's reach: `@:keep`
	 * (reached by machinery no scan models), `@:build` (a macro may generate the reference) or an
	 * `extern` declaration (its members describe a foreign object).
	 */
	public static inline function typeOutOfReach(declared: TypeDeclInfo): Bool {
		return declared.hasKeep || declared.hasBuild || declared.isExtern;
	}

	/**
	 * The identifier-token occurrence counts over report UNION resolution scope - a run's
	 * cost-bounded pre-filter.
	 *
	 * Two invariants the count comparison in `occursOnlyWithin` rests on, both established here by
	 * construction:
	 *
	 * 1. The map is a SUPERSET of every REPORT file, `files` included. `wide` may legitimately lack
	 *    one, and a map missing a declaration's OWN tokens can make the comparison hold by coincidence
	 *    against unrelated library occurrences the confirm cannot see - a false finding, and a wrong
	 *    edit. The report set is therefore unioned in, keyed by PATH so nothing is counted twice.
	 * 2. Nothing in the resolution scope is silently missing. Counting tokens is a RAW-TEXT operation
	 *    that needs no parse, so the scope's own sources are read when the host exposes them - a
	 *    library file the parser skipped still contributes. Reading them off the INDEX instead would
	 *    drop such a file from both `allFiles` and `sourceOf`, and a reference inside it would read as
	 *    absent. The index path is the fallback for a plugin hosting no scope, where `wide` IS the
	 *    report index and the union below covers it whole anyway.
	 */
	public static function tokenCounts(
		files: Array<{ file: String, source: String }>, wide: SymbolIndex, plugin: GrammarPlugin
	): Map<String, Int> {
		final sources: Map<String, String> = [];
		final resolution: Null<Array<{ file: String, source: String }>> = RefactorSupport.resolutionSourcesOf(plugin);
		if (resolution == null)
			for (fi in wide.allFiles()) sources[fi.file] = indexedSource(wide, fi.file);
		else
			for (entry in resolution) sources[entry.file] = entry.source;
		for (entry in files) sources[entry.file] = entry.source;
		final out: Map<String, Int> = [];
		for (src in sources) countTokens(src, 0, src.length, out);
		return out;
	}

	/**
	 * Accumulate into `out` the occurrence count of every identifier token in `source[from, to)`,
	 * word-boundary by construction. Raw text, so tokens inside comments, string literals and `#if`
	 * branches all count - the conservative direction (an extra occurrence only ever keeps a member).
	 * A token STRADDLING `to` is counted truncated, which likewise can only under-count the region and
	 * so keep the member.
	 */
	public static function countTokens(source: String, from: Int, to: Int, out: Map<String, Int>): Void {
		final stop: Int = to <= source.length ? to : source.length;
		var i: Int = from;
		while (i < stop) {
			if (!SourceText.isIdentStartChar(source.fastCodeAt(i))) {
				i++;
				continue;
			}
			var end: Int = i + 1;
			while (end < stop && SourceText.isIdentChar(source.fastCodeAt(end))) end++;
			final token: String = source.substring(i, end);
			out[token] = (out[token] ?? 0) + 1;
			i = end;
		}
	}

	/**
	 * Whether every occurrence of `name` in scope lies inside `regions`. The cheap global token map
	 * decides it first (the count inside the regions equals the count everywhere), then `confirm`'s
	 * raw-text scan agrees - it additionally reads the `\x24name` / `$name` interpolation ESCAPE
	 * (`RefactorSupport.DOLLAR_ESCAPES`), which the plain tokenizer swallows into one long token. The
	 * confirm is a per-candidate scan of every file `confirm` indexes, so it never runs for a name the
	 * map already saw somewhere else.
	 */
	public static function occursOnlyWithin(
		name: String, tokens: Map<String, Int>, regions: Array<ReachRegion>, confirm: SymbolIndex
	): Bool {
		final own: Map<String, Int> = [];
		final excluded: Map<String, Array<Span>> = [];
		for (r in regions) {
			countTokens(r.source, r.span.from, r.span.to, own);
			final spans: Array<Span> = excluded[r.file] ?? [];
			spans.push(r.span);
			excluded[r.file] = spans;
		}
		return tokens[name] == own[name] && !confirm.text.nameOccursOutsideAll(name, excluded);
	}

	/**
	 * Whether `declared`'s HIERARCHY puts its members out of reach: it transitively carries RTTI (the
	 * hierarchy is reflected on field NAMES at runtime), a supertype reference resolves to no indexed
	 * declaration (the chain cannot be read at all), or - when `autoBuildCounts` - an ANCESTOR carries
	 * `@:autoBuild` (that macro generates into descendants, so it is read walking the chain UPWARD).
	 *
	 * `autoBuildCounts` is the caller's because the hazard depends on the edit: generated code may CALL
	 * a member, so a deletion must respect it, but it lands INSIDE the descendant, where a member made
	 * private stays visible.
	 */
	public static function chainOutOfReach(scope: SymbolIndex, host: FileInfo, declared: TypeDeclInfo, autoBuildCounts: Bool): Bool {
		if (scope.traits.transitivelyCarriesRtti(declared.name)) return true;
		final chain: Chain = { unresolved: false, generated: false };
		walkChain(scope, host, declared, chain, []);
		return chain.unresolved || (autoBuildCounts && chain.generated);
	}

	/**
	 * What one member's modifier / metadata `run` says: whether it carries `public`, `override`,
	 * `static`, ANY `@:meta` (`MemberKinds.META_KINDS` - metadata makes a member implicitly reachable,
	 * so the whole class is treated alike rather than a `@:keep` whitelist that would leak by
	 * category), and the `public` keyword's own node, the span a visibility edit replaces.
	 */
	public static function readRun(run: Array<QueryNode>): MemberRun {
		var visibility: Null<QueryNode> = null;
		var isOverride: Bool = false;
		var isStatic: Bool = false;
		var annotated: Bool = false;
		for (mod in run) {
			if (mod.kind == PUBLIC_MODIFIER) visibility = mod;
			if (mod.kind == STATIC_MODIFIER) isStatic = true;
			if (MemberKinds.META_KINDS.contains(mod.kind)) annotated = true;
			if (mod.kind == OVERRIDE_MODIFIER) isOverride = true;
		}
		return {
			isPublic: visibility != null,
			publicModifier: visibility,
			isOverride: isOverride,
			isStatic: isStatic,
			annotated: annotated
		};
	}

	/**
	 * Accumulate into `chain` whether any ANCESTOR of `type` carries `@:autoBuild` and whether any
	 * supertype reference resolved to no indexed declaration.
	 */
	private static function walkChain(scope: SymbolIndex, host: FileInfo, type: TypeDeclInfo, chain: Chain, seen: Array<String>): Void {
		final visited: String = '${host.file}#${type.name}';
		if (seen.contains(visited)) return;
		seen.push(visited);
		for (raw in type.supertypesRaw) {
			final supers: Array<{ file: FileInfo, type: TypeDeclInfo }> = scope.resolveTypeRefsFrom(raw, host.file, type.span.from);
			if (supers.length == 0) {
				chain.unresolved = true;
				continue;
			}
			for (s in supers) {
				if (s.type.hasAutoBuild) chain.generated = true;
				walkChain(scope, s.file, s.type, chain, seen);
			}
		}
	}

	/** `scope`'s source for `file`. The index writes it in lockstep with the `FileInfo`, so an absent one is a broken index. */
	private static function indexedSource(scope: SymbolIndex, file: String): String {
		final src: Null<String> = scope.sourceOf(file);
		if (src == null) throw new Exception('SymbolIndex lists \'$file\' but holds no source for it');
		return src;
	}

}

/** One region of one file allowed to name a member - its own declaration, its type, a subtype. */
typedef ReachRegion = {
	final file: String;
	final source: String;
	final span: Span;
};

/** What a member's modifier / metadata run says, as `PublicReach.readRun` reads it. */
typedef MemberRun = {
	final isPublic: Bool;

	/** The `public` keyword's node, or null when the run carries none. */
	final publicModifier: Null<QueryNode>;
	final isOverride: Bool;
	final isStatic: Bool;
	final annotated: Bool;
};

/** The accumulated verdict of one inheritance-chain walk. */
private typedef Chain = {

	/** Whether a supertype reference resolved to no indexed declaration, leaving the chain unreadable. */
	var unresolved: Bool;

	/** Whether an ancestor carries `@:autoBuild` - it generates members into the class the walk started from. */
	var generated: Bool;

};
