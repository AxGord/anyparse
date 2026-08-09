package anyparse.query;

import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin.LayoutMetrics;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin.CheckOverrides;
import anyparse.query.SpanTypeInfoProvider;
import haxe.Exception;

/**
 * A `GrammarPlugin` decorator that memoizes `parseFile` / `parseFileTypeRefs` by source
 * content, run-scoped, over a PROCESS-scoped second tier for the resolution library.
 *
 * The analysis checks each parse every file independently — `Linter.run` calls
 * every check's `run`, and each `run` calls `plugin.parseFile`, so without this
 * the same file is parsed once per check (N checks over M files is N×M parses).
 * During `--fix` the `SymbolIndex` build and every fix pass re-parse on top of
 * that. The checks only READ the trees (they collect violations and spans, never
 * mutate the AST), so a single parse can be shared across all of them safely;
 * keying on source content means an unchanged file is reused across fix passes
 * while a rewritten one re-parses on its new content.
 *
 * The instance caches hold mutable state, so they stay run-scoped — create a fresh
 * wrapper per lint run / fix run and never share it across threads. Every other
 * method delegates straight through; a parse that throws is not cached (a
 * skip-parse file re-parses per check, a negligible minority).
 *
 * Behind them sits ONE process-scoped tier, for the resolution LIBRARY only
 * (`shareLibrary`): a fresh wrapper per `Cli.run` otherwise means re-parsing the
 * 200+ auto-discovered Haxe std files, plus every declared `resolutionRoots` /
 * `resolutionLibs` source, on every run in the process. Only the library half of a `ResolutionSources` ever enters it, which is what bounds it — a `--fix` loop's per-pass rewritten report sources never do, and the nominal `LibrarySources` type makes feeding it the report half a compile error rather than a convention. Same single-thread rule as the
 * instance caches; same content key, so a library file changed on disk misses.
 */
@:nullSafety(Strict)
final class CachingGrammarPlugin implements GrammarPlugin implements TypeInfoProvider implements SpanTypeInfoProvider
		implements SymbolIndexHost {

	/** Library sources actually parsed into the shared tier — a served entry leaves this untouched (the caching-invariant tests read it). */
	public static var libraryParses(default, null): Int = 0;

	/**
	 * Shared-tier SERVES from `parseFile` — incremented inside the serve branch itself, so it
	 * measures the lookup that saves the work rather than `shareLibrary`'s promotion
	 * bookkeeping. That distinction is the whole point: an earlier version counted hits in
	 * `shareLibrary`'s own `exists` short-circuit, so BOTH serve lookups could be deleted with
	 * the suite still green while the run got 4.5x slower.
	 */
	public static var libraryHits(default, null): Int = 0;

	/** The `spanTypeInfo` half of `libraryHits`, counted in its own serve branch for the same reason. */
	public static var librarySpanHits(default, null): Int = 0;

	/**
	 * `_inner.parseFile` invocations — the work the tiers exist to avoid. Two runs over the same
	 * scope pay the same cost for everything EXCEPT the library the first one promoted (the
	 * report sources, and the retries of any library file that does not parse, recur
	 * identically), so run 2's delta must equal run 1's delta minus run 1's `libraryParses`.
	 * That subtraction is what "zero inner parses of library sources" means arithmetically, and
	 * it is the identity `ResolutionLibraryCacheTest` pins.
	 */
	public static var innerParses(default, null): Int = 0;

	/** `_inner.spanTypeInfo` (or the five-accessor fallback) invocations — the span-parse twin of `innerParses`. */
	public static var innerSpanParses(default, null): Int = 0;

	// PROCESS-scoped second tier behind `_parseCache` / `_spanInfoCache`, written by
	// `shareLibrary` and by nothing else, so only RESOLUTION-LIBRARY sources ever enter it.
	// A blanket static tier would be wrong: a `--fix` loop rewrites a report file every pass,
	// so every intermediate source would be retained for the life of the process. Library
	// sources have no such churn — they are read-only for the whole run — and keying on
	// (language, source CONTENT) means an entry can only ever be served for byte-identical
	// input, so a library directory deleted and recreated with different content under the
	// SAME path misses and re-parses. The file SET is never cached (each run re-expands its
	// own scan roots), so two runs configuring different scopes cannot see each other's
	// library. Single-threaded by the same rule as the instance caches below. The language is the
	// OUTER key rather than part of a composite one: two grammars parse the same bytes into
	// different trees, but folding the language into the key would mean building a fresh string
	// per lookup and re-hashing the whole source on every `parseFile` call.
	private static final SHARED_PARSE_TIERS: Map<String, Map<String, QueryNode>> = [];
	private static final SHARED_SPAN_TIERS: Map<String, Map<String, SpanTypeInfo>> = [];

	private final _inner: GrammarPlugin;

	// This wrapper's language slices of the two process-scoped tiers above, resolved once in the
	// constructor so a lookup is one map read against the caller's own source string.
	private final _sharedParseCache: Map<String, QueryNode>;
	private final _sharedSpanCache: Map<String, SpanTypeInfo>;
	private final _parseCache: Map<String, QueryNode> = [];
	private final _typeRefCache: Map<String, QueryNode> = [];
	private final _branchAwareCache: Map<String, QueryNode> = [];

	// One combined span-parse cache replacing five per-map caches: the five
	// TypeInfoProvider accessors below are exact slices of this bundle, so a file's
	// type-info costs a single span-parse instead of one per accessor.
	private final _spanInfoCache: Map<String, SpanTypeInfo> = [];
	private final _importMapCache: Map<String, Map<String, String>> = [];

	// Layout metrics per config JSON — one entry per distinct `hxformat.json` in a run.
	private final _layoutMetricsCache: Map<String, Null<LayoutMetrics>> = [];

	// Run-scoped, same lifecycle as the other caches on this class — a fresh
	// RefsCache per wrapper instance, shared with every RefShape this plugin hands
	// out so `Refs.find` resolves against ONE memoized index per tree instead of
	// re-walking per query.
	private final _refsCache: RefsCache = new RefsCache();

	// Resolution scope (SymbolIndexHost): a thunk yielding the report files and the
	// configured library sources APART, and the memoised index built from their union. Both
	// stay unset for a run with no resolution scope, so the checks fall back to their
	// report-only index. The library sources are read (inside the thunk) and the index built
	// only on the first resolutionIndex() demand, so a run needing no cross-file resolution
	// never touches the library. The two halves stay separate because only the library one
	// may enter the process-scoped tier above.
	private var _resolutionScope: Null<ResolutionScope> = null;
	private var _resolutionIndex: Null<SymbolIndex> = null;
	private var _resolutionIndexBuilt: Bool = false;

	// The library array instance `shareLibrary` has already walked. The thunk memoises its
	// library, so every `resolutionFiles()` call after the first in a run hands back the SAME
	// array — one per `--fix` pass — and re-walking it would re-hash every library source for
	// nothing. Reference identity, not content: a different array is a different library.
	private var _promotedLibrary: Null<Array<{ file: String, source: String }>> = null;

	public function new(inner: GrammarPlugin) {
		_inner = inner;
		_sharedParseCache = tier(SHARED_PARSE_TIERS, inner.langName());
		_sharedSpanCache = tier(SHARED_SPAN_TIERS, inner.langName());
	}

	/**
	 * Inject the resolution scope: its `declared` provenance plus the thunk yielding the report
	 * files and the configured library sources, kept apart. Read from disk (inside the thunk)
	 * and indexed only on the first `resolutionFiles()` / `resolutionIndex()` demand, keeping a
	 * resolution-free run off the library.
	 */
	public inline function setResolutionScope(scope: ResolutionScope): Void {
		_resolutionScope = scope;
	}

	/**
	 * `SymbolIndexHost`: whether ANY resolution scope was injected — a declared one or the
	 * implicit std-only one — tested without forcing the (library-reading) index build. On a
	 * machine with an installed Haxe std this is effectively always true for a `Cli` run, which
	 * is why the name says ANY: a consumer that needs "the user opted into a wider scope" must
	 * ask `hasDeclaredResolutionScope` instead.
	 */
	public function hasAnyResolutionScope(): Bool {
		return _resolutionScope != null;
	}

	/**
	 * `SymbolIndexHost`: whether the project DECLARED the resolution scope via `resolutionRoots`
	 * / `resolutionLibs`, as opposed to it existing only because a Haxe std was discovered on
	 * the machine. The narrower signal, for a proof that must not admit std sources.
	 */
	public function hasDeclaredResolutionScope(): Bool {
		final scope: Null<ResolutionScope> = _resolutionScope;
		return scope != null && scope.declared;
	}

	/**
	 * The resolution file set — report files UNION library sources — with every library parse
	 * PROMOTED into the process-scoped tier on the way out, so the next run over the same
	 * library serves those trees instead of re-parsing them. Null when no scope was injected.
	 * The one door onto the scope: both the self-built index below and the `--fix` loop's
	 * per-pass index go through it, so neither can skip the promotion.
	 *
	 * Called once per `--fix` pass, and the thunk memoises its library, so the promotion walk is
	 * itself memoised on the library ARRAY INSTANCE (`shareLibrary`) — re-hashing every library
	 * source once per pass would otherwise be the tier's own overhead.
	 */
	public function resolutionFiles(): Null<Array<{ file: String, source: String }>> {
		final scope: Null<ResolutionScope> = _resolutionScope;
		if (scope == null) return null;
		final sources: ResolutionSources = scope.sources();
		shareLibrary(sources.library);
		return sources.report.concat(sources.library.entries());
	}

	/**
	 * Adopt an externally-built resolution-scoped index as the memoised one. The `--fix`
	 * loop builds a fresh index per pass over the CURRENT report sources UNION the library
	 * (its naming / edit index) and shares it here, so the cross-file checks resolve against
	 * this pass's sources — the per-pass rebuild the loop relies on, extended to the checks —
	 * instead of a frozen first-demand snapshot. Re-settable: each pass overwrites.
	 */
	public function setResolutionIndex(index: SymbolIndex): Void {
		_resolutionIndex = index;
		_resolutionIndexBuilt = true;
	}

	/**
	 * `SymbolIndexHost`: the resolution-scoped index — an externally adopted one
	 * (`setResolutionIndex`, the `--fix` loop's per-pass index) when present, else built once
	 * over the thunk's file set (report UNION library) and memoised for the report path, else
	 * null when no scope was injected. The self-build runs through `this`, so library parses
	 * land in this wrapper's parse cache.
	 */
	public function resolutionIndex(): Null<SymbolIndex> {
		if (_resolutionIndexBuilt) return _resolutionIndex;
		final files: Null<Array<{ file: String, source: String }>> = resolutionFiles();
		if (files == null) return null;
		_resolutionIndexBuilt = true;
		_resolutionIndex = SymbolIndex.build(files, this);
		return _resolutionIndex;
	}

	public function parseFile(source: String): QueryNode {
		final cached: Null<QueryNode> = _parseCache[source];
		if (cached != null) return cached;
		final shared: Null<QueryNode> = _sharedParseCache[source];
		if (shared != null) {
			libraryHits++;
			return shared;
		}
		innerParses++;
		final tree: QueryNode = _inner.parseFile(source);
		_parseCache[source] = tree;
		return tree;
	}

	public function parseFileTypeRefs(source: String): QueryNode {
		final cached: Null<QueryNode> = _typeRefCache[source];
		if (cached != null) return cached;
		final tree: QueryNode = _inner.parseFileTypeRefs(source);
		_typeRefCache[source] = tree;
		return tree;
	}

	/**
	 * `GrammarPlugin`: the branch-aware projection, memoized by source next to `_typeRefCache`
	 * and DELEGATED to `_inner` — the decorator owns the cache, the wrapped grammar owns the
	 * projection, exactly as for `parseFileTypeRefs`.
	 *
	 * Memoization here is CORRECTNESS-adjacent, not a nicety: `RefsCache` keys its per-file
	 * `Refs.findMulti` index by TREE IDENTITY, so handing each opted-in check a freshly built
	 * tree would re-index the whole file once per check. One tree per source keeps that at one
	 * index, exactly as the plain `parseFile` tree does.
	 *
	 * The seam takes an already-parsed tree, so there is no second parse to avoid and nothing to
	 * reimplement here: callers pair it with this wrapper's memoized `parseFile`. A source that
	 * does not parse throws out of THAT call and never reaches this cache.
	 */
	public function projectBranchAware(tree: QueryNode, source: String): QueryNode {
		final cached: Null<QueryNode> = _branchAwareCache[source];
		if (cached != null) return cached;
		final projected: QueryNode = _inner.projectBranchAware(tree, source);
		_branchAwareCache[source] = projected;
		return projected;
	}

	public function langName(): String return _inner.langName();

	public function parsePattern(source: String): Pattern return _inner.parsePattern(source);

	/**
	 * `GrammarPlugin`: attaches this wrapper's run-scoped `RefsCache` to a fresh
	 * copy of the inner shape, so `Refs.find` resolves through the memoized
	 * index instead of walking the tree per query. Safe: `_inner.refShape()`
	 * returns a fresh struct literal per call, so mutating the copy leaks
	 * nowhere.
	 */
	public function refShape(): RefShape {
		final shape: RefShape = _inner.refShape();
		shape.refsCache = _refsCache;
		return shape;
	}

	public function metaShape(): MetaShape return _inner.metaShape();

	public function selectKindEquivalence(): KindEquivalence return _inner.selectKindEquivalence();

	public function typeRefShape(): TypeRefShape return _inner.typeRefShape();

	public function writeRoundTrip(source: String, ?optsJson: String): Null<String> return _inner.writeRoundTrip(source, optsJson);

	/**
	 * Memoised by `optsJson` — a width-aware check asks per FILE, and a lint run
	 * over one project resolves the same `hxformat.json` for every file in it, so
	 * without the memo the config JSON would be re-parsed into full write options
	 * once per candidate.
	 */
	public function layoutMetrics(?optsJson: String): Null<LayoutMetrics> {
		// A BLANK payload keys as NO CONFIG — the reading every hop agrees on
		// (`FormatConfigDiscovery.normalize`), since a 0-byte `hxformat.json` states no
		// settings. Normalising here rather than only inside the grammar keeps the two
		// spellings on ONE entry. The prefix keeps a JSON payload off the no-config key.
		final stated: Null<String> = FormatConfigDiscovery.normalize(optsJson);
		final key: String = stated == null ? 'none' : 'json:$stated';
		if (_layoutMetricsCache.exists(key)) return _layoutMetricsCache[key];
		final metrics: Null<LayoutMetrics> = _inner.layoutMetrics(stated);
		_layoutMetricsCache[key] = metrics;
		return metrics;
	}

	public function writeRoundTripPlain(source: String, ?optsJson: String): Null<String>
		return _inner.writeRoundTripPlain(source, optsJson);

	public function reconParse(source: String): Bool return _inner.reconParse(source);

	public function namingSupport(): Null<NamingSupport> return _inner.namingSupport();

	public function stringFoldSupport(): Null<StringFoldSupport> return _inner.stringFoldSupport();

	public function maxComplexity(path: String): Null<Int> return _inner.maxComplexity(path);

	public function controlFlowSupport(): Null<ControlFlowSupport> return _inner.controlFlowSupport();

	public function booleanLogicSupport(): Null<BooleanLogicSupport> return _inner.booleanLogicSupport();

	public function knownExtensionMethods(modulePath: String): Null<Array<String>> return _inner.knownExtensionMethods(modulePath);

	public function checkOverrides(path: String): Null<CheckOverrides> return _inner.checkOverrides(path);

	/**
	 * `SpanTypeInfoProvider`: the five span-indexed maps, memoized by source. When the
	 * wrapped plugin batches (`SpanTypeInfoProvider`) the bundle is one span-parse;
	 * otherwise it falls back to the wrapped plugin's five individual accessors, so a
	 * non-batching inner is byte-identical to the old per-map caches. The five
	 * `TypeInfoProvider` accessors below read their slice from here.
	 */
	public function spanTypeInfo(source: String): SpanTypeInfo {
		final cached: Null<SpanTypeInfo> = _spanInfoCache[source];
		if (cached != null) return cached;
		final shared: Null<SpanTypeInfo> = _sharedSpanCache[source];
		if (shared != null) {
			librarySpanHits++;
			return shared;
		}
		innerSpanParses++;
		final batched: Null<SpanTypeInfoProvider> = _inner is SpanTypeInfoProvider ? cast _inner : null;
		final result: SpanTypeInfo = batched != null ? batched.spanTypeInfo(source) : fallbackSpanInfo(source);
		_spanInfoCache[source] = result;
		return result;
	}

	public function declaredTypes(source: String): Map<Int, String> return spanTypeInfo(source).declaredTypes;

	public function returnTypes(source: String): Map<Int, String> return spanTypeInfo(source).returnTypes;

	/** `TypeInfoProvider`: forward + memoize the property read-accessor map. */
	public function propertyAccessors(source: String): Map<Int, Bool> return spanTypeInfo(source).propertyAccessors;

	/** `TypeInfoProvider`: forward + memoize the property write-accessor map. */
	public function propertyWriteAccessors(source: String): Map<Int, Bool> return spanTypeInfo(source).propertyWriteAccessors;

	/** `TypeInfoProvider`: forward + memoize the declaration type-source map per source. */
	public function declaredTypeSources(source: String): Map<Int, String> return spanTypeInfo(source).declaredTypeSources;

	/** `TypeInfoProvider`: forward + memoize the typed-cast target-type-source map per source. */
	public function castTargetSources(source: String): Map<Int, String> return spanTypeInfo(source).castTargetSources;

	/** `TypeInfoProvider`: forward + memoize the import simple-name → FQN map per source. */
	public function importMap(source: String): Map<String, String> {
		final cached: Null<Map<String, String>> = _importMapCache[source];
		if (cached != null) return cached;
		final inner: Null<TypeInfoProvider> = _inner is TypeInfoProvider ? cast _inner : null;
		final result: Map<String, String> = inner != null ? inner.importMap(source) : [];
		_importMapCache[source] = result;
		return result;
	}

	/**
	 * The span-info bundle assembled from the wrapped plugin's five individual
	 * `TypeInfoProvider` accessors — the path for an inner that supplies per-map type
	 * info but not the batched `SpanTypeInfoProvider` capability. Exactly reproduces
	 * the pre-batching behaviour (each map is `inner.X(source)` or empty).
	 */
	private function fallbackSpanInfo(source: String): SpanTypeInfo {
		final inner: Null<TypeInfoProvider> = _inner is TypeInfoProvider ? cast _inner : null;
		return {
			declaredTypes: inner != null ? inner.declaredTypes(source) : [],
			returnTypes: inner != null ? inner.returnTypes(source) : [],
			propertyAccessors: inner != null ? inner.propertyAccessors(source) : [],
			propertyWriteAccessors: inner != null ? inner.propertyWriteAccessors(source) : [],
			declaredTypeSources: inner != null ? inner.declaredTypeSources(source) : [],
			castTargetSources: inner != null ? inner.castTargetSources(source) : []
		};
	}

	/**
	 * PROMOTE every library source's parse and span-info into the process-scoped tier, so the
	 * next `Cli.run` over the same library serves them instead of re-parsing 200+ std files
	 * from scratch. Idempotent and content-addressed: an entry already present is a HIT and
	 * costs nothing, and only a byte-identical source can serve it.
	 *
	 * A source that does not parse is left out entirely (`SymbolIndexBuilder.extract` re-tries
	 * it and records the file as skipped) — the same treatment the instance parse cache gives a
	 * throwing parse, over a negligible minority of library files.
	 */
	private function shareLibrary(library: LibrarySources): Void {
		final entries: Array<{ file: String, source: String }> = library.entries();
		if (_promotedLibrary == entries) return;
		_promotedLibrary = entries;
		for (entry in entries) {
			// Routed through `parseFile` — NOT short-circuited on `_sharedParseCache.exists` —
			// so an already-promoted entry goes through the SERVE branch, the one thing this
			// tier exists for. Short-circuiting here is what made the serve path deletable with
			// a green suite: the counters then measured this loop, never the lookup.
			final tree: Null<QueryNode> = try parseFile(entry.source) catch (exception: Exception) null;
			if (tree == null || _sharedParseCache.exists(entry.source)) continue;
			_sharedParseCache[entry.source] = tree;
			_sharedSpanCache[entry.source] = spanTypeInfo(entry.source);
			libraryParses++;
		}
	}

	/** The `lang` slice of a process-scoped `tiers` map, created empty on first use. */
	private static function tier<T>(tiers: Map<String, Map<String, T>>, lang: String): Map<String, T> {
		final existing: Null<Map<String, T>> = tiers[lang];
		if (existing != null) return existing;
		final created: Map<String, T> = [];
		tiers[lang] = created;
		return created;
	}

}

/**
 * The two halves of a resolution scope, kept APART on purpose. `report` is the files the run
 * lints and may rewrite — read live, so a `--fix` pass sees the current sources. `library` is
 * the configured resolution roots / libs / std, read-only for the whole run.
 *
 * The split is what bounds `CachingGrammarPlugin`'s process-scoped parse tier: only `library`
 * is promoted into it, so a `--fix` loop's per-pass intermediate sources — a fresh string per
 * pass per edited file — can never accumulate there.
 */
typedef ResolutionSources = {
	final report: Array<{ file: String, source: String }>;
	final library: LibrarySources;
};

/**
 * The library half of a `ResolutionSources`, as a NOMINAL type.
 *
 * Structurally it is the same `Array<{file, source}>` as the report half, so nothing but naming
 * convention stopped a caller from handing the REPORT array to `shareLibrary` — and "only
 * library sources are ever promoted" is the entire growth bound on the process-scoped parse
 * tier. A `--fix` loop rewrites a report file every pass, so one such misfeed would retain every
 * intermediate source for the life of the process, silently and unboundedly. Wrapping it makes
 * that a compile error rather than an argument in a comment.
 *
 * Deliberately conversion-free in both directions: no `@:from` / `@:to`, so constructing one is
 * a visible `new LibrarySources(...)` at the single site that reads the library off disk, and
 * unwrapping is a visible `entries()`.
 */
abstract LibrarySources(Array<{ file: String, source: String }>) {

	public inline function new(entries: Array<{ file: String, source: String }>) {
		this = entries;
	}

	/** The wrapped entries — the one way out, so every read of the library is visibly that. */
	public inline function entries(): Array<{ file: String, source: String }> {
		return this;
	}

}

/**
 * An injected resolution scope: `sources` yields its two halves on demand, `declared` records
 * WHY it exists.
 *
 * `declared` is true when the project asked for the scope through `resolutionRoots` /
 * `resolutionLibs`, and false when it exists only because a Haxe std was discovered on the
 * machine. On any Haxe-equipped box the implicit case is the common one, so "a scope is
 * present" no longer means "the user opted into a wider scope" — the two questions had to
 * become two signals (`hasAnyResolutionScope` / `hasDeclaredResolutionScope`). Consumers that
 * want the WIDEST index available treat both alike; a proof whose scan must not admit std
 * sources (`unused-private`'s zero-occurrence scan) asks for the declared one.
 */
typedef ResolutionScope = {
	final declared: Bool;
	final sources: () -> ResolutionSources;
};
