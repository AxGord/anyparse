package anyparse.query;

/**
 * A run-scoped host that can supply a resolution-scoped `SymbolIndex` — the
 * report files UNION any configured library source roots, plus the implicitly
 * discovered Haxe std — for the cross-file type / inheritance resolution the
 * `redundant-this`, `prefer-index-access` and `map-keys-lookup` checks perform.
 * Implemented by `CachingGrammarPlugin`, the per-run plugin wrapper every check
 * receives, and consulted through `RefactorSupport.lazySymbolIndex`.
 *
 * Both `has*` predicates answer WITHOUT forcing the (potentially library-reading)
 * index build, so a check keeps its report-scope-only fallback and never touches
 * the library until it actually demands the resolution index. They differ in which
 * scope they admit: `hasAnyResolutionScope` counts the implicit std-only scope
 * every Haxe-equipped machine now gets, `hasDeclaredResolutionScope` only a
 * project-declared one. `resolutionIndex` returns the memoised resolution-scoped
 * index, or null when no scope reached the run at all.
 */
@:nullSafety(Strict)
interface SymbolIndexHost {

	/**
	 * Whether ANY resolution scope was injected — checked WITHOUT building the index, so the
	 * library stays unread until an index is demanded. Includes the IMPLICIT std-only scope, so
	 * on a machine with an installed Haxe std this is effectively always true for a `Cli` run:
	 * read it as "a wider index than the report exists", never as "the user opted in".
	 */
	function hasAnyResolutionScope(): Bool;

	/**
	 * Whether the project DECLARED the scope (`resolutionRoots` / `resolutionLibs`), as opposed
	 * to it existing only because a Haxe std was discovered. The signal for a consumer whose
	 * proof would be wrong — not merely wider — if the std joined it.
	 */
	function hasDeclaredResolutionScope(): Bool;

	/** The memoised resolution-scoped `SymbolIndex` (built once, over report files UNION the library roots), or null when no scope is configured. */
	function resolutionIndex(): Null<SymbolIndex>;

	/**
	 * The resolution scope's RAW sources — report files UNION the library roots — or null when no
	 * scope reached the run. Text, not trees: a source the parser SKIPPED still carries its bytes
	 * here, where the parsed `SymbolIndex` above drops it from both `allFiles` and `sourceOf`.
	 * The seam a raw-text whole-scope scan (`unused-public-member`'s token map) needs so a
	 * skip-parsing library file cannot read as holding no references at all.
	 */
	function resolutionFiles(): Null<Array<{ file: String, source: String }>>;

	/**
	 * The PROJECT sources — report files UNION the declared `resolutionRoots` — or null when the
	 * project declared no roots, in which case the report scope the caller already holds IS the
	 * answer. Narrower than `resolutionFiles` by exactly the third-party half (`resolutionLibs`,
	 * the std), for a proof about what can WRITE a project type's member: those roots are the
	 * project's own files, a haxelib is not, and a name-keyed write scan that admits one only ever
	 * stops reporting.
	 */
	function resolutionProjectFiles(): Null<Array<{ file: String, source: String }>>;

}
