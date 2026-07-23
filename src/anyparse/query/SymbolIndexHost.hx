package anyparse.query;

/**
 * A run-scoped host that can supply a resolution-scoped `SymbolIndex` — the
 * report files UNION any configured library source roots — for the cross-file
 * type / inheritance resolution the `redundant-this`, `prefer-index-access` and
 * `map-keys-lookup` checks perform. Implemented by `CachingGrammarPlugin`, the
 * per-run plugin wrapper every check receives, and consulted through
 * `RefactorSupport.lazySymbolIndex`.
 *
 * `hasResolutionScope` reports whether a resolution scope was injected WITHOUT
 * forcing the (potentially library-reading) index build, so a check keeps its
 * report-scope-only fallback and never touches the library until it actually
 * demands the resolution index. `resolutionIndex` returns the memoised
 * resolution-scoped index, or null when no scope is configured.
 */
@:nullSafety(Strict)
interface SymbolIndexHost {

	/** Whether a resolution scope was injected — checked WITHOUT building the index, so the library stays unread until an index is demanded. */
	function hasResolutionScope(): Bool;

	/** The memoised resolution-scoped `SymbolIndex` (built once, over report files UNION the library roots), or null when no scope is configured. */
	function resolutionIndex(): Null<SymbolIndex>;

}
