package anyparse.query;

import anyparse.check.ReflectionMemo;
import anyparse.query.ReachLiveness.ReachBuilds;

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

	/**
	 * Whether the project declared `resolutionRoots` AND they matched at least one `.hx` — the
	 * signal that the report files plus `resolutionProjectFiles` span the declared roots, including
	 * a whole-project lint where every root file sits in the report and `resolutionProjectFiles`
	 * therefore cannot tell it from a project with no working roots. Reads the scope's sources.
	 */
	function projectRootsMatched(): Bool;

	/**
	 * The memoised resolution-scoped `SymbolIndex` (built once, over report
	 * files UNION the library roots), or null when no scope is configured.
	 */
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

	/**
	 * EVERY project source — the report files UNION the declared `resolutionRoots` — when EVERY declared
	 * root matched, including a whole-project lint whose roots all sit in the report (where
	 * `resolutionProjectFiles` answers null); null when any root matched nothing, so the project may hold
	 * files this run never read. The seam for a proof that must see every place a project member is named.
	 * A file of the project that lies under no declared root is outside it by construction.
	 */
	function completeProjectFiles(): Null<Array<{ file: String, source: String }>>;

	/** The `MemberReach` memoised for the current pass, or null — dropped whenever the pass's index is. */
	function memberReach(): Null<MemberReach>;

	/** Memoise `reach` for the current pass. */
	function setMemberReach(reach: MemberReach): Void;

	/**
	 * The builds a `MemberReach` answer must hold under — each configured compiler oracle's define sets and the files it
	 * compiles — or null when the run declared none, did not declare its oracle list complete, declined them, or one
	 * could not be read: every conditional branch and every library file is then in play, and no subtype the index
	 * does not list is ruled out.
	 */
	function reachBuilds(): Null<ReachBuilds>;

	/**
	 * The memoised PROJECT-scoped `SymbolIndex` — built once over `resolutionProjectFiles`, or
	 * null when the project declared no `resolutionRoots` and the caller's own report scope IS
	 * the answer. The project-scope twin of `resolutionIndex`, and for the same reason: the two
	 * field-immutability checks both demand it, and without a memo each rebuilt the whole project
	 * index per `--fix` pass.
	 */
	function projectIndex(): Null<SymbolIndex>;

	/**
	 * The memoised `FieldWriteIndex` over the RESOLUTION scope — report UNION the library — with
	 * the library half tagged THIRD-PARTY so a name-keyed bail can be narrowed per owner
	 * (`FieldWriteIndex.admits`). Null when no scope reached the run.
	 *
	 * The write proof is the one question that WANTS the library in scope: a third-party subtype
	 * of a project type writes an inherited field from a file the project scope does not hold, and
	 * `MemberWriteScan.subtypeWriteReaches` can only see it here. Everything a check asks about
	 * its OWN candidate passes that candidate's file and is narrowed back to the project half.
	 */
	function fieldWriteIndex(): Null<FieldWriteIndex>;

	/**
	 * The run-scoped memo `check/ReflectionScan` keeps its scope-wide string surface in — the
	 * reflection twin of the three memoised indexes above, and memoised for the same reason: five
	 * registered checks demand that surface per run and each used to recompute the whole walk.
	 *
	 * The host owns only WHEN the memo dies (with the run, like every cache on the wrapper), never
	 * what it means — the check layer fills it and validates it against the sources it read. That
	 * split is what keeps it a RUN-scoped memo instead of a process cache: a surface collected in an
	 * earlier run must never answer this one's gates.
	 */
	function reflectionMemo(): ReflectionMemo;

}
