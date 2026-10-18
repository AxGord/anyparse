package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;

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
	 * The host's report + resolution-scope `SymbolIndex` (a configured library and the implicit std indexed too), or null
	 * when the plugin is not a resolution host or no scope reached it: a bare plugin (the unit tests pinning report-only
	 * behaviour), a machine with no discoverable std, a project declining it (`APQ_NO_STD`, `"resolutionStd": false`). The
	 * eager counterpart of `lazySymbolIndex`, for a check already holding a report index: `resolutionIndexOf(plugin) ?? index`.
	 */
	public static inline function resolutionIndexOf(plugin: GrammarPlugin): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		return host != null && host.hasAnyResolutionScope() ? host.resolutionIndex() : null;
	}

	/**
	 * The WIDEST index a name-keyed confinement or zero-occurrence proof may ask: the host's resolution-scoped index when
	 * the project DECLARED a scope, else the report-scoped `index` the caller passed, else null (the caller falls back to
	 * the one file it holds).
	 *
	 * Gated on `hasDeclaredResolutionScope`, not on `hasAnyResolutionScope` as `resolutionIndexOf` is: these proofs are
	 * name-keyed, so a simple-name coincidence with a std type that HAS subtypes decides them, and that must not happen by
	 * accident. The gate does not keep the std OUT of the index (`LintCommand.readResolutionLibrary` appends it to the
	 * declared scope); it refuses a scope that exists ONLY because a std was discovered. A field-write proof that must admit
	 * no third-party source asks the narrower `RefactorSupport.resolutionProjectSourcesOf`; a name-keyed reflection
	 * question asks `ReflectionScan.scopeFiles` (`CrossScopeSoundnessTest.placementDivergences` prices the difference). On a
	 * project declaring `resolutionLibs` and no `resolutionRoots` the index holds none of the project's other files, which
	 * no seam can tell, so the CLI warns (`ConfigDisagreement.warnMissingProjectRoots`).
	 */
	public static inline function widestScopeIndex(plugin: GrammarPlugin, ?index: SymbolIndex): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		final declared: Null<SymbolIndex> = host != null && host.hasDeclaredResolutionScope() ? host.resolutionIndex() : null;
		return declared ?? index;
	}

	/**
	 * A memoized `SymbolIndex` builder — built at most once, on first call — for a check that needs cross-file resolution
	 * only after its cheaper structural gates pass, so most runs never build it. A host carrying ANY resolution scope
	 * answers its memoised resolution index; otherwise (a bare plugin, no discoverable std) the report index over `files`,
	 * or `prebuilt` as-is when the caller already holds one. `prebuilt` is ignored under a resolution scope: the wider
	 * index must win, and it is a different index, so no duplicate build is skipped there.
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
	 * The memoised write index over the RESOLUTION scope (report UNION the library, the library half tagged third-party)
	 * when ANY scope reached the run — an implicit std-only one still supplies the library half this index is for — else
	 * `reportWrites(files)`.
	 */
	public static function resolutionWrites(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): FieldWriteIndex {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		final wide: Null<FieldWriteIndex> = host != null && host.hasAnyResolutionScope() ? host.fieldWriteIndex() : null;
		return wide ?? reportWrites(files, plugin);
	}

	/**
	 * The declarations of the module file `file` (text `source`) that no index of the run holds — what a name binding asks
	 * of a library or std module it meets through an import: read DECLARATIONS-ONLY and memoised per file on a host
	 * (`SymbolIndexHost.declarationsOf`), off the plugin's declarations parse otherwise, off a full single-file index for a
	 * plugin that has none. Null when the source does not parse.
	 */
	public static function declarationsOf(file: String, source: String, plugin: GrammarPlugin): Null<FileInfo> {
		final host: Null<SymbolIndexHost> = hostOf(plugin);
		if (host != null) return host.declarationsOf(file, source);
		if (!(plugin is ParsedRootProvider)) return over([{ file: file, source: source }], plugin).fileInfo(file);
		final provider: ParsedRootProvider = cast plugin;
		return SymbolIndexBuilder.declarationsFromRoot(file, source, provider.parseDeclarationsRoot(source), provider, plugin);
	}

	/** `plugin` as the run's index host, or null for a bare plugin. */
	private static inline function hostOf(plugin: GrammarPlugin): Null<SymbolIndexHost> {
		return plugin is SymbolIndexHost ? cast plugin : null;
	}

}
