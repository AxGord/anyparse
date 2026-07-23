package anyparse.query;

import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin.CheckOverrides;
import anyparse.query.SpanTypeInfoProvider;

/**
 * A run-scoped `GrammarPlugin` decorator that memoizes `parseFile` /
 * `parseFileTypeRefs` by source content.
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
 * The cache holds mutable state, so it must stay run-scoped — create a fresh
 * wrapper per lint run / fix run and never share it across threads. Every other
 * method delegates straight through; a parse that throws is not cached (a
 * skip-parse file re-parses per check, a negligible minority).
 */
@:nullSafety(Strict)
final class CachingGrammarPlugin implements GrammarPlugin implements TypeInfoProvider implements SpanTypeInfoProvider
		implements SymbolIndexHost {

	private final _inner: GrammarPlugin;
	private final _parseCache: Map<String, QueryNode> = [];
	private final _typeRefCache: Map<String, QueryNode> = [];

	// One combined span-parse cache replacing five per-map caches: the five
	// TypeInfoProvider accessors below are exact slices of this bundle, so a file's
	// type-info costs a single span-parse instead of one per accessor.
	private final _spanInfoCache: Map<String, SpanTypeInfo> = [];

	private final _importMapCache: Map<String, Map<String, String>> = [];

	// Run-scoped, same lifecycle as the other caches on this class — a fresh
	// RefsCache per wrapper instance, shared with every RefShape this plugin hands
	// out so `Refs.find` resolves against ONE memoized index per tree instead of
	// re-walking per query.
	private final _refsCache: RefsCache = new RefsCache();

	// Resolution scope (SymbolIndexHost): a thunk yielding the report files UNION the
	// configured library sources, and the memoised index built from it. Both stay unset
	// for a run with no resolution scope, so the checks fall back to their report-only
	// index. The library sources are read (inside the thunk) and the index built only on
	// the first resolutionIndex() demand, so a run needing no cross-file resolution never
	// touches the library.
	private var _resolutionFiles: Null<() -> Array<{ file: String, source: String }>> = null;
	private var _resolutionIndex: Null<SymbolIndex> = null;
	private var _resolutionIndexBuilt: Bool = false;

	public function new(inner: GrammarPlugin) {
		_inner = inner;
	}

	/**
	 * Inject the resolution file-set thunk: the report files UNION the configured library
	 * sources. Read from disk (inside the thunk) and indexed only on the first
	 * `resolutionIndex()` demand, keeping a resolution-free run off the library.
	 */
	public function setResolutionFiles(files: () -> Array<{ file: String, source: String }>): Void {
		_resolutionFiles = files;
	}

	/** `SymbolIndexHost`: whether a resolution scope was injected, tested without forcing the (library-reading) index build. */
	public function hasResolutionScope(): Bool {
		return _resolutionFiles != null;
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
		final thunk: Null<() -> Array<{ file: String, source: String }>> = _resolutionFiles;
		if (thunk == null) return null;
		_resolutionIndexBuilt = true;
		_resolutionIndex = SymbolIndex.build(thunk(), this);
		return _resolutionIndex;
	}

	public function parseFile(source: String): QueryNode {
		final cached: Null<QueryNode> = _parseCache[source];
		if (cached != null) return cached;
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
		final batched: Null<SpanTypeInfoProvider> = (_inner is SpanTypeInfoProvider) ? cast _inner : null;
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
		final inner: Null<TypeInfoProvider> = (_inner is TypeInfoProvider) ? cast _inner : null;
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
		final inner: Null<TypeInfoProvider> = (_inner is TypeInfoProvider) ? cast _inner : null;
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
