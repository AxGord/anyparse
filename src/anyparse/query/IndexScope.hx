package anyparse.query;

/**
 * Which `SymbolIndex` (and `FieldWriteIndex`) a question asks, and the ONE place outside the run host
 * (`CachingGrammarPlugin`, the `SymbolIndexHost`) that builds one. Every rule, op and query asks here
 * by NAME instead of calling `SymbolIndex.build` itself:
 *
 * - `report(files, plugin)` — exactly the files the caller was handed (the lint report, a `FileGated`
 *   subset): the scope of a confinement or a "nothing in the report reaches it" proof.
 * - `resolution(files, plugin)` — the host's resolution scope (report UNION the library roots UNION the
 *   std) when one reached the run, else `report`: what a name or a supertype MEANS.
 * - `widest(files, plugin)` — the resolution scope only when the project DECLARED it, else `report`
 *   (`widestScopeIndex` says why a std-only scope must not decide a name-keyed proof).
 * - `over(files, plugin, ?thirdPartyFiles)` — an explicitly different file set: an op's `--scope`, a
 *   scratch tree, a per-file rebuild, a set the caller assembled itself.
 *
 * On a host every answer is memoised per run (`SymbolIndexHost.indexOver`), so the many rules asking
 * the same question over the same files share ONE build; on a bare plugin (a direct `check.run` in a
 * unit test) each call builds afresh, which answers the same index.
 */
@:nullSafety(Strict)
final class IndexScope {

	/**
	 * The report + resolution-scope `SymbolIndex` the plugin host carries — a subtype declared in a
	 * configured resolution library, or in the implicitly-scoped Haxe std, is indexed there too — or
	 * null when the plugin is not a resolution host or no scope reached it at all (the caller falls
	 * back to the report index). The eager counterpart of `lazySymbolIndex`, for a check that already
	 * holds a report index and only needs to know whether a WIDER one exists:
	 * `resolutionIndexOf(plugin) ?? index`.
	 *
	 * The null return is now the RARE case rather than the default. A `Cli` run reaches it only when
	 * the project declares no resolution key AND no Haxe std is discoverable — a machine without Haxe,
	 * or one that declined the std via `APQ_NO_STD` / `"resolutionStd": false`. It is still the plain
	 * answer for a direct `check.run` with a bare plugin, which is what the unit tests that pin the
	 * report-only behaviour use.
	 */
	public static inline function resolutionIndexOf(plugin: GrammarPlugin): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		return host != null && host.hasAnyResolutionScope() ? host.resolutionIndex() : null;
	}

	/**
	 * The WIDEST index a structural confinement or zero-occurrence proof may ask: the host's
	 * resolution-scoped index (report UNION the DECLARED library roots) when `plugin` is a
	 * `SymbolIndexHost` carrying a declared scope, else the report-scoped `index` the caller passed,
	 * else null (no index reached the call at all — the caller falls back to the single file it holds).
	 *
	 * Deliberately gated on `hasDeclaredResolutionScope`, NOT on `hasAnyResolutionScope` the way
	 * `resolutionIndexOf` beside it is. The proofs this index feeds are name-keyed rather than
	 * type-resolved, so a SIMPLE-NAME coincidence with a std type decides them: an owner whose simple name
	 * collides with a std type that HAS subtypes reads as unconfined on that coincidence alone. The
	 * direction is safe — an unconfined member is kept, its rename refused, its parameter left alone — so
	 * the hazard costs usefulness rather than correctness, which is exactly why it must not happen by
	 * ACCIDENT. A DECLARED library is a different matter: the project chose it, and a file the run does not
	 * lint can legitimately be where the reference lives.
	 *
	 * Read the gate for what it does and not for what its name suggests, because the obvious reading is
	 * wrong: it does NOT keep the std out of the returned index. `LintCommand.readResolutionLibrary`
	 * appends the std to the SAME scope as the declared roots and libs, so a project that declares anything
	 * gets the std in here too. What the gate refuses is a scope that exists ONLY because a std was
	 * discovered — a project that declared nothing keeps the report index. The narrower
	 * `resolutionProjectSourcesOf` below is the seam for a proof that must not admit third-party sources at
	 * all — a FIELD-WRITE proof, and only that; a name-keyed REFLECTION question does NOT belong there, and
	 * both such sites go through `check/ReflectionScan.scopeFiles`, which unions `resolutionSourcesOf`
	 * (`CrossScopeSoundnessTest.placementDivergences` prices the difference: the narrow seam licenses an
	 * edit the wide one refuses).
	 *
	 * What BOTH seams answer on a project declaring `resolutionLibs` and no `resolutionRoots` is nothing
	 * of the project: `projectRoots` is empty, so the narrow seam returns null, and this one returns
	 * report ∪ haxelibs ∪ std — a declared scope with not one of the project's own other files in it.
	 * Neither seam can tell, so the CLI says it instead (`ConfigDisagreement.warnMissingProjectRoots`), and
	 * `CrossScopeSoundnessTest.LIBS_ONLY_REGRESSIONS` prices what it costs.
	 *
	 * FOUR call sites, and they fail DIFFERENTLY on the narrow report index, which is why each asks
	 * for this one. `UnusedPrivate.run` feeds `violationFor`, which otherwise reports a live member
	 * dead, and `UnusedPrivate.fix` feeds `referencedElsewhere`, the zero-occurrence proof that lifts a
	 * `#if`-carrying file's whole-file veto. The other two WRITE: `UnusedParameter.run` raises the
	 * finding to `Warning`, and `Warning` is what removes a parameter whose cross-file callers the
	 * proof never saw; `Naming.fix` takes ONE index and feeds it to TWO proofs — `RenameRefusal.of`,
	 * which otherwise lets a single-file rename orphan a cross-file reference to the old
	 * name, and `reflectionNamesInOtherFiles`, which otherwise never visits the file whose
	 * `Reflect.field(x, 'name')` the rename is about to break. That sharing is why the arm cutting the
	 * confinement half has to cut the ARGUMENT rather than the local.
	 */
	public static inline function widestScopeIndex(plugin: GrammarPlugin, ?index: SymbolIndex): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		final declared: Null<SymbolIndex> = host != null && host.hasDeclaredResolutionScope() ? host.resolutionIndex() : null;
		return declared ?? index;
	}

	/**
	 * The memoised write index over the RESOLUTION scope (report UNION the library, the library
	 * half tagged third-party), or null when the plugin hosts no scope at all. Gated on the ANY
	 * predicate, not the declared one: the library half is exactly what this index is for, and an
	 * implicit std-only scope still supplies one.
	 */
	public static inline function fieldWriteIndexOf(plugin: GrammarPlugin): Null<FieldWriteIndex> {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		return host != null && host.hasAnyResolutionScope() ? host.fieldWriteIndex() : null;
	}

	/**
	 * A memoized `SymbolIndex` builder — built at most once, on first call, over `files`. Shared by
	 * checks whose path-receiver type gate needs cross-file resolution only after cheaper structural
	 * gates pass, so most runs never trigger the build. When `plugin` is a `SymbolIndexHost` carrying
	 * ANY resolution scope — a declared one (report files UNION the configured library roots) or the
	 * implicit std-only one — that host's memoised resolution index is preferred, so the check resolves
	 * against libraries and std too.
	 *
	 * The report-only fallback below it is therefore no longer the ordinary path: on a Haxe-equipped
	 * machine a `Cli` run always takes the host branch, and the fallback answers only for a direct
	 * `check.run` with a bare plugin (every unit test that pins report-scope behaviour) or a machine
	 * with no discoverable std. `prebuilt`, when supplied, is an already-built report-scope index that
	 * fallback returns as-is instead of building a second one — `prefer-final-field` passes the eager
	 * index it already holds. It is ignored when a resolution scope is present, since the wider index
	 * must win; that is not a lost optimisation, because the host's index is a DIFFERENT (wider) index
	 * than `prebuilt`, so there is no duplicate build to avoid on that path.
	 */
	public static function lazySymbolIndex(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?prebuilt: SymbolIndex
	): () -> Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		if (host != null && host.hasAnyResolutionScope()) {
			final resolver: SymbolIndexHost = host;
			return () -> resolver.resolutionIndex();
		}
		if (prebuilt != null) {
			final ready: SymbolIndex = prebuilt;
			return () -> ready;
		}
		var index: Null<SymbolIndex> = null;
		var built: Bool = false;
		return () -> {
			if (!built) {
				built = true;
				index = report(files, plugin);
			}
			return index;
		};
	}

	/**
	 * The REPORT-scope index: exactly the `files` the caller was handed — a lint run's report, a
	 * `FileGated` check's subset, the pass's sources a `--fix` hands its fixes. The scope a confinement
	 * or a "no report file reaches it" proof is stated over, and the one a rule that must NOT see the
	 * library asks (`redundant-map-exists` reads its skipped set as "nothing is hidden"). Memoised per run
	 * on a host, so every rule asking it over the same files shares one build.
	 */
	public static function report(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): SymbolIndex {
		return over(files, plugin);
	}

	/**
	 * The index over an EXPLICITLY chosen file set, with `thirdPartyFiles` tagged third-party: an op's
	 * `--scope`, a scratch tree, a per-file rebuild, a set the caller assembled (a graph's held files, a
	 * compiled build's project UNION library). The same memo as `report` on a host — the name only says the
	 * set is not the report — and a fresh build on a bare plugin.
	 */
	public static function over(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?thirdPartyFiles: Array<String>
	): SymbolIndex {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		return host != null ? host.indexOver(files, thirdPartyFiles) : SymbolIndex.build(files, plugin, thirdPartyFiles);
	}

	/**
	 * The RESOLUTION index — the host's report UNION library UNION std scope when ANY scope reached the
	 * run (`resolutionIndexOf`), else the report index over `files`. What a name, a supertype or a
	 * declared type MEANS: a question the library can only ever answer more precisely.
	 */
	public static function resolution(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): SymbolIndex {
		return resolutionIndexOf(plugin) ?? report(files, plugin);
	}

	/**
	 * The WIDEST index a name-keyed confinement or zero-occurrence proof may ask — the resolution scope
	 * only when the project DECLARED one (`widestScopeIndex`), else the report index over `files`.
	 */
	public static function widest(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): SymbolIndex {
		return widestScopeIndex(plugin) ?? report(files, plugin);
	}

	/**
	 * The REPORT-scope write index over exactly `files`, resolving receivers through `report(files)`.
	 * Memoised per run on a host (`SymbolIndexHost.writeIndexOver`), a fresh build on a bare plugin.
	 */
	public static function reportWrites(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): FieldWriteIndex {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		return host != null ? host.writeIndexOver(files) : FieldWriteIndex.build(files, plugin, report(files, plugin));
	}

	/**
	 * The RESOLUTION-scope write index (`fieldWriteIndexOf`: report UNION library, the library half
	 * tagged third-party) when any scope reached the run, else `reportWrites(files)`.
	 */
	public static function resolutionWrites(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): FieldWriteIndex {
		return fieldWriteIndexOf(plugin) ?? reportWrites(files, plugin);
	}

	/** `plugin` as the run's index host, or null for a bare plugin. */
	private static inline function hostOf(plugin: GrammarPlugin): Null<SymbolIndexHost> {
		return plugin is SymbolIndexHost ? cast plugin : null;
	}

}
