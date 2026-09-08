package anyparse.check;

import anyparse.query.NamingPolicy.FrameworkContract;

/**
 * The sentences a lint RUN owes its reader about the SET of `apqlint.json` documents its scope spans —
 * when two of those roots disagree about a setting resolved once for the whole run, and when a root
 * names no sources of the project's own.
 *
 * Two such SETTINGS exist and both stay resolved that way. The framework roster, because the rules
 * sharing it do not all have a per-file seam to resolve at (`unused-public-member` builds one
 * whole-scope context before it sees a file) and a roster differing between two of them would spare a
 * member from one rule and delete it with its sibling. The `compilerOracle`, because an oracle names
 * ONE build. Neither choice is the defect; the SILENCE was — a file under the second root was linted
 * by the first root's answer and no byte of output said so, which is the same shape as a `frameworks`
 * entry this package drops without a diagnostic.
 *
 * The last two sentences are not about a disagreement at all but about an ABSENCE, and they belong here
 * for the same reason the first two do: `resolutionRoots` decides what the resolution scope holds of the
 * project's OWN sources, and what a scope holds is a property of the document SET. A project that
 * declares `resolutionLibs` and leaves the roots out gets a scope that IS declared and is made
 * entirely of installed libraries — the one shape where every cross-scope proof S177, S179 and S180
 * widened quietly answers from the report scope again.
 *
 * Beside `LintConfig` rather than inside it: that class answers for ONE document (or one folded
 * chain), and every question here is about the SET of documents a scope reaches, which is not a
 * property any single config has.
 */
@:nullSafety(Strict)
final class ConfigDisagreement {

	/**
	 * Warn once when the scope's roots disagree about the FRAMEWORK ROSTER.
	 *
	 * Called from `Cli.runLint` beside its oracle twin, NOT from `LintConfig.frameworksFor`: that runs
	 * once per framework-aware rule and re-runs this whole per-file scan each time (the argument is
	 * evaluated whatever the once-per-process ledger later decides), and for the `RiskyFix` half of
	 * those rules `FixVerifier` installs no resolver at all — so each scan was an uncached
	 * `LintConfig.discover` walk per file. The CLI is where the memoised resolver lives, and where the
	 * run knows whether any `FrameworkAware` rule is active to read the roster at all.
	 */
	public static function warnRoster(resolve: Null<(String) -> LintConfig>, paths: Array<String>): Void {
		warn('scope-disagreement', 'the framework roster', rosterMessage(resolve, paths));
	}

	/**
	 * Warn once when the scope's roots name different `compilerOracle` builds.
	 *
	 * Called from `Cli.runLint` and gated there on `--no-oracle`: a run that takes no oracle verdict
	 * has nothing a disagreement could corrupt.
	 */
	public static function warnOracle(resolve: Null<(String) -> LintConfig>, paths: Array<String>): Void {
		warn('scope-disagreement', 'the compiler oracle', oracleMessage(resolve, paths));
	}

	/**
	 * Warn once when the scope declares resolution LIBRARIES and names no project source roots.
	 *
	 * Not a disagreement between two roots but a GAP in one, and the only notice here about what the
	 * scope does NOT hold. It belongs beside the other two because it answers the same kind of
	 * question — what the SET of documents a run resolves against contains, which no single config
	 * can say. `resolutionRoots` is the key that puts the project's own sources into the scope, and it fills BOTH
	 * halves — `ResolutionSources.projectRoots` directly, and the library half through
	 * `LintCommand.resolutionThunk`'s concat. Leave it out and both starve at once:
	 * `RefactorSupport.resolutionProjectSourcesOf` answers null on the empty `projectRoots`, and the index
	 * `RefactorSupport.widestScopeIndex` hands back is the report files plus an installed library, while
	 * `hasDeclaredResolutionScope` keeps saying yes. So five checks decide a rewrite without a single file
	 * of the project they are rewriting, and none of them can tell.
	 * `test/unit/check/CrossScopeSoundnessTest.LIBS_ONLY_REGRESSIONS` measures what that costs: ten
	 * writes and four findings the roots-declared arm refuses.
	 *
	 * A sentence rather than a repair because there is nothing to repair with — source roots nobody
	 * declared cannot be invented, and guessing them (the config's own directory, the oracle hxml's
	 * classpath) would silently widen what every such project resolves against.
	 */
	public static function warnMissingProjectRoots(resolve: Null<(String) -> LintConfig>, paths: Array<String>): Void {
		warn('scope-gap', 'the project source roots', missingProjectRootsMessage(resolve, paths));
	}

	/**
	 * Warn once when a DECLARED `resolutionRoots` entry matches no `.hx` at all.
	 *
	 * The blind spot of `warnMissingProjectRoots`, which reads the CONFIG and therefore sees a key
	 * that IS there. A root spelled wrong — a typo, a directory since moved, a path written against
	 * the wrong base — expands to nothing, `projectRoots` comes back empty, and the run is
	 * byte-identical to one that never declared the key: measured on a scratch project,
	 * `"resolutionRoots": ["sources"]` beside a real `src/` let `lint <one file> --rule naming --fix`
	 * rename a private field and orphan an `@:access` grantee in a second file, with no diagnostic of
	 * any kind.
	 *
	 * Called from `LintCommand.readResolutionRoots` — the only place that learns it, and on FIRST
	 * DEMAND, so a run whose checks never build the index still pays nothing for the question. The
	 * twin of the `could not resolve haxelib "…"` note that sits beside it.
	 */
	public static function warnUnreachableProjectRoots(roots: Array<String>): Void {
		warn('scope-gap', 'unreachable project source roots', unreachableProjectRootsMessage(roots));
	}

	/**
	 * The roster sentence for `paths`, or null when their roots agree.
	 *
	 * Named rather than inlined into `warnRoster` so a test reads the SAME wiring the run does: a
	 * fixture that spelled the signature itself would pass whatever `warnRoster` actually compared.
	 */
	private static function rosterMessage(resolve: Null<(String) -> LintConfig>, paths: Array<String>): Null<String> {
		return message(resolve, paths, 'the framework roster', c -> rosterSignature(c.frameworks()));
	}

	/**
	 * The oracle sentence for `paths`, or null when their roots agree.
	 *
	 * `?? ''` because an OMITTED optional constructor argument is `undefined` on js, not null: a
	 * directory with no config at all yields `LintConfig([])`, whose accessors then render as
	 * `undefined` where a parsed document with the key absent renders as `null`. Every consumer asks
	 * `!= null`, which is loose and cannot tell them apart — a raw interpolation can, and the first
	 * mixed scope this ran over was reported as a disagreement about nothing.
	 */
	private static function oracleMessage(resolve: Null<(String) -> LintConfig>, paths: Array<String>): Null<String> {
		return message(resolve, paths, 'the compiler oracle', c -> (c.compilerOracle() ?? '') + '|' + (c.compilerOracleDir() ?? ''));
	}

	/**
	 * The gap sentence for `paths`, or null when the scope holds project roots — or holds no declared
	 * resolution at all, which is a different situation with its own answer already.
	 *
	 * One root declaring `resolutionRoots` is enough to return null, because the run resolves the
	 * UNION of every discovered document's keys: the proofs then have project sources to widen into,
	 * whichever config named them. What the sentence quotes back is the REPORT count, since that is the number the reader can act on — a
	 * one-file run and a whole-project run get the same scope and are exposed completely differently.
	 *
	 * The question it answers is about the CONFIG, not about the filesystem, and that is a real limit: a
	 * root DECLARED but spelled wrong — a typo, a directory since moved — expands to no `.hx` at all, which
	 * leaves the proofs exactly as inert while this stays silent. The expansion is lazy and happens in
	 * `LintCommand.readResolutionRoots`, which is the only place that learns it and therefore the only place
	 * the second sentence could live; asking here would force the tree walk this scope defers on purpose.
	 */
	private static function missingProjectRootsMessage(resolve: Null<(String) -> LintConfig>, paths: Array<String>): Null<String> {
		var exposed: Int = 0;
		for (path in paths) {
			final config: LintConfig = LintConfig.resolveWith(resolve, path);
			if (config.resolutionRoots().length == 0 && config.resolutionLibs().length > 0) exposed++;
		}
		return exposed == 0
			? null
			: 'apq: $exposed of ${paths.length} file(s) this run reports sit under an apqlint.json declaring resolutionLibs and no '
				+ 'resolutionRoots — their resolution scope is this run\'s own files plus an installed library, with no other source of '
				+ 'the project in it, so the checks that prove a cross-file rewrite safe answer from the report scope alone: one can '
				+ 'report a live member as dead, rename a member another file reaches, or drop a parameter a cross-file caller still '
				+ 'passes, and --fix writes it. Declare "resolutionRoots" naming the project\'s own source dirs (e.g. ["src"])\n';
	}

	/** The unreachable-roots sentence for `roots`, or null when every declared root matched something. */
	private static function unreachableProjectRootsMessage(roots: Array<String>): Null<String> {
		final named: String = roots.join(', ');
		return roots.length == 0
			? null
			: 'apq lint: resolutionRoots: $named match no .hx — the project\'s own sources are then absent from the'
				+ ' resolution scope exactly as if the key were never declared, and the checks that prove a cross-file rewrite safe answer '
				+ 'from the report scope alone. A relative entry resolves against the declaring apqlint.json\'s directory\n';
	}

	/**
	 * Emit `message`'s sentence, at most once per process per setting.
	 *
	 * Through `LintConfig`'s own ledger rather than a second one, so a run that has already warned
	 * about a setting stays quiet however many rules ask the question again.
	 */
	@:access(anyparse.check.LintConfig)
	private static function warn(kind: String, label: String, line: Null<String>): Void {
		if (line != null) LintConfig.warnOnce('$kind:$label', line);
	}

	/**
	 * The sentence `warn` prints, or null when there is nothing to say.
	 *
	 * Split from the write because the write is a bare `Sys.stderr` with no seam a test can read, and
	 * because the DECISION — which root wins, how many files sit under another — is the half worth
	 * pinning. Null for a scope that is empty, single-file, single-rooted, or multi-rooted and in
	 * agreement, which is every scope in this project and in Pony.
	 */
	private static function message(
		resolve: Null<(String) -> LintConfig>, paths: Array<String>, setting: String, signature: (LintConfig) -> String
	): Null<String> {
		if (paths.length < 2) return null;
		final applied: String = signature(LintConfig.resolveWith(resolve, paths[0]));
		final others: Array<String> = [];
		var disagreeing: Int = 0;
		for (path in paths) {
			final own: String = signature(LintConfig.resolveWith(resolve, path));
			if (own == applied) continue;
			disagreeing++;
			if (!others.contains(own)) others.push(own);
		}
		return disagreeing == 0
			? null
			: 'apq: this scope spans apqlint.json roots that disagree about $setting — the one'
				+ ' discovered for ${paths[0]} applies to all ${paths.length} file(s), of which $disagreeing file(s) sit under'
				+ ' a root declaring one of ${others.length} other value(s)\n';
	}

	/**
	 * One roster as a comparable string — how two configs' rosters are told apart.
	 *
	 * SORTED, because the consumer is not order-sensitive: `HaxeNamingSupport.nominated` reads the
	 * roster with `filter` / `exists`, so two roots stating the same contracts in a different order
	 * agree and must not be reported as disagreeing.
	 */
	private static function rosterSignature(roster: Array<FrameworkContract>): String {
		final rendered: Array<String> = [
			for (contract in roster) '${contract.root}(${sorted(contract.names)})(${sorted(contract.prefixes)})'
		];
		rendered.sort(Reflect.compare);
		return rendered.join(' ');
	}

	/**
	 * `fragments` joined in a canonical order — a COPY, because `LintConfig.frameworks()` hands back
	 * its own cached array and an in-place sort would reorder a config every later reader shares.
	 */
	private static function sorted(fragments: Array<String>): String {
		final ordered: Array<String> = fragments.copy();
		ordered.sort(Reflect.compare);
		return ordered.join(',');
	}

}
