package anyparse.query;

import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.FunctionTypeProvider;
import anyparse.query.GrammarPlugin.CheckOverrides;
import anyparse.query.GrammarPlugin.LayoutMetrics;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.SpanTypeInfoProvider;
import anyparse.query.StringFold.StringFoldSupport;

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
 * Behind them sits ONE process-scoped tier, for the resolution LIBRARY only (`SharedParseTier`): a fresh wrapper per `Cli.run` otherwise means re-parsing the
 * 200+ auto-discovered Haxe std files, plus every declared `resolutionRoots` /
 * `resolutionLibs` source, on every run in the process. Only the library half of a `ResolutionSources` ever enters it, which is what bounds it — a `--fix` loop's per-pass rewritten report sources never do, and the nominal `LibrarySources` type makes feeding it the report half a compile error rather than a convention. Same single-thread rule as the
 * instance caches; same content key, so a library file changed on disk misses.
 *
 * Under all of them is the run-scoped PARSED-ROOT cache, the one thing the projection
 * caches above could not share: `parseFile`, `parseFileTypeRefs`, `spanTypeInfo` and
 * `importMap` each memoise a DIFFERENT projection, so each used to begin by parsing the
 * source again. When the wrapped grammar offers `ParsedRootProvider` the four go through
 * ONE memoised root instead, and a source is parsed once per run however many
 * projections that run demands (`rootParses` counts them). Instance state like every
 * cache here, run-scoped for the same reason, and never shared across threads.
 */
@:nullSafety(Strict)
final class CachingGrammarPlugin implements GrammarPlugin implements TypeInfoProvider implements SpanTypeInfoProvider
		implements SymbolIndexHost implements FunctionTypeProvider {

	/** Roots parsed by this wrapper — one per distinct source once the projections share it. */
	public var rootParses(default, null): Int = 0;

	// The parsed ROOT per source — the one thing the projection caches below could not
	// share, so each of them re-parsed. Values may be null (a source that does not parse
	// memoises its failure too), so reads go through `exists`, not a null test.
	private final _rootCache: Map<String, Null<Any>> = [];

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

	/**
	 * The complexity threshold per DIRECTORY. `maxComplexity` walks up from a file to a
	 * `checkstyle.json`, reads it off disk and re-derives the threshold, and `Complexity.run` asks
	 * it once per file: 851 disk walks, 851 JSON parses and 851 re-derivations for ONE config.
	 *
	 * Keyed by directory because `ConfigFinder.findUp` starts at a file's own directory, so two
	 * files sharing one resolve to the same config by construction; two spellings of one directory
	 * are two entries and one extra miss, never a wrong answer. `null` is a real answer (no config,
	 * or one that does not configure `CyclomaticComplexity`), so reads go through `exists`.
	 */
	private final _maxComplexityCache: Map<String, Null<Int>> = [];

	// Run-scoped, same lifecycle as the other caches on this class — a fresh
	// RefsCache per wrapper instance, shared with every RefShape this plugin hands
	// out so `Refs.find` resolves against ONE memoized index per tree instead of
	// re-walking per query.
	private final _refsCache: RefsCache = new RefsCache();
	private final _inner: GrammarPlugin;

	// The wrapped grammar's OPTIONAL root-sharing capability, resolved once — the same
	// `_inner is X ? cast _inner : null` seam as `SpanTypeInfoProvider`, one level lower.
	// Null for a grammar without it, and every entry point below then falls back to its
	// source-taking `_inner` call, byte-identically.
	private final _rootProvider: Null<ParsedRootProvider>;

	// The wrapped grammar's OPTIONAL function-type reader, resolved once by the same seam as
	// `_rootProvider`. The wrapper implements `FunctionTypeProvider` UNCONDITIONALLY and answers
	// null here for a grammar that has none, which is the same verdict a consumer would reach by
	// finding the capability absent — and it keeps the wrapper from hiding a capability the inner
	// grammar does have, which is exactly what an unforwarded one does.
	private final _functionTypes: Null<FunctionTypeProvider>;

	// The PROCESS-scoped tier behind the run-scoped caches below: this wrapper's language slice
	// of it, resolved once in the constructor. Only RESOLUTION-LIBRARY sources ever enter it —
	// `SharedParseTier` documents why that bound is what makes a process-scoped tier safe here.
	private final _shared: SharedParseTier;

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

	public function new(inner: GrammarPlugin) {
		_inner = inner;
		_rootProvider = inner is ParsedRootProvider ? cast inner : null;
		_functionTypes = inner is FunctionTypeProvider ? cast inner : null;
		_shared = new SharedParseTier(inner.langName());
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
	 * itself memoised on the library ARRAY INSTANCE (`SharedParseTier.promote`) — re-hashing every library
	 * source once per pass would otherwise be the tier's own overhead.
	 */
	public function resolutionFiles(): Null<Array<{ file: String, source: String }>> {
		final scope: Null<ResolutionScope> = _resolutionScope;
		if (scope == null) return null;
		final sources: ResolutionSources = scope.sources();
		_shared.promote(sources.library, this);
		// Drop the LIBRARY roots the moment the process-scoped tier owns their projections.
		// Library sources are demanded as `{parseFile, spanInfo}` and only that, and those two
		// calls are ADJACENT — the generated one-entry root memo already collapsed them before
		// this cache existed — so holding their roots buys ZERO parses (346 of 1048 sources on
		// this tree). Measured on a TM lint, three interleaved rounds against BOTH the base and
		// the un-narrowed variant: keeping them costs +322 MB peak RSS for -7.4%, dropping them
		// costs +168 MB for -7.2%. The speed difference is 0.04s, inside the noise; the memory
		// difference is half the bill. A later demand the shared tier does not cover simply
		// re-parses, which is correct, just slower.
		for (entry in sources.library.entries()) _rootCache.remove(entry.source);
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
		final shared: Null<QueryNode> = _shared.servedParse(source);
		if (shared != null) return shared;
		SharedParseTier.noteInnerParse();
		final provider: Null<ParsedRootProvider> = _rootProvider;
		final tree: QueryNode = provider != null
			? provider.treeFromRoot(rootOf(provider, source), source, false)
			: _inner.parseFile(source);
		_parseCache[source] = tree;
		return tree;
	}

	public function parseFileTypeRefs(source: String): QueryNode {
		final cached: Null<QueryNode> = _typeRefCache[source];
		if (cached != null) return cached;
		final provider: Null<ParsedRootProvider> = _rootProvider;
		final tree: QueryNode = provider != null
			? provider.treeFromRoot(rootOf(provider, source), source, true)
			: _inner.parseFileTypeRefs(source);
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

	/**
	 * The wrapped grammar's complexity threshold for `path`, memoised per DIRECTORY.
	 *
	 * The one method here that memoises a DISK walk rather than a parse. `Complexity.run` asks it
	 * once per file and the Haxe grammar answers by walking up to a `checkstyle.json`, reading it
	 * and re-deriving the threshold — the identical walk-and-parse `HaxeNamingSupport.policyFor`
	 * does, at the call site the FULL ruleset reaches, which is why memoising only `policyFor`
	 * bought nothing measurable on a full run.
	 *
	 * Run-scoped like every cache on this class: a fresh wrapper per lint / fix run, never shared
	 * across threads, never a `static` (`docs/design-principles.md` § 2).
	 */
	public function maxComplexity(path: String): Null<Int> {
		final dir: String = haxe.io.Path.directory(path);
		if (_maxComplexityCache.exists(dir)) return _maxComplexityCache[dir];
		final max: Null<Int> = _inner.maxComplexity(path);
		_maxComplexityCache[dir] = max;
		return max;
	}

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
		final shared: Null<SpanTypeInfo> = _shared.servedSpanInfo(source);
		if (shared != null) return shared;
		SharedParseTier.noteInnerSpanParse();
		final provider: Null<ParsedRootProvider> = _rootProvider;
		final batched: Null<SpanTypeInfoProvider> = _inner is SpanTypeInfoProvider ? cast _inner : null;
		final result: SpanTypeInfo = if (provider != null)
			provider.spanTypeInfoFromRoot(rootOf(provider, source), source);
		else if (batched != null)
			batched.spanTypeInfo(source);
		else
			fallbackSpanInfo(source);
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

	/** `FunctionTypeProvider`, forwarded verbatim — the answer is a pure function of the text, so there is nothing to cache. */
	public function functionTypeArity(typeSource: String): Null<Int> return _functionTypes?.functionTypeArity(typeSource);

	/** `TypeInfoProvider`: forward + memoize the typed-cast target-type-source map per source. */
	public function castTargetSources(source: String): Map<Int, String> return spanTypeInfo(source).castTargetSources;

	/** `TypeInfoProvider`: forward + memoize the import simple-name → FQN map per source. */
	public function importMap(source: String): Map<String, String> {
		final cached: Null<Map<String, String>> = _importMapCache[source];
		if (cached != null) return cached;
		final provider: Null<ParsedRootProvider> = _rootProvider;
		final inner: Null<TypeInfoProvider> = _inner is TypeInfoProvider ? cast _inner : null;
		final result: Map<String, String> = if (provider != null)
			provider.importMapFromRoot(rootOf(provider, source), source);
		else if (inner != null)
			inner.importMap(source);
		else
			[];
		_importMapCache[source] = result;
		return result;
	}

	/**
	 * The parsed root of `source`, memoised for the whole run — the ONE parse the four
	 * projections above share. `exists` is the read rather than a null test because a
	 * source that does not parse memoises a NULL root, so a skip-parse file is not
	 * re-parsed once per projection either. Called only where `provider` is in hand, so
	 * the capability check stays at the call site instead of being re-tested here.
	 */
	private function rootOf(provider: ParsedRootProvider, source: String): Null<Any> {
		if (_rootCache.exists(source)) return _rootCache[source];
		final root: Null<Any> = provider.parseRoot(source);
		_rootCache[source] = root;
		rootParses++;
		return root;
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
 * convention stopped a caller from handing the REPORT array to `SharedParseTier.promote` — and "only
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
