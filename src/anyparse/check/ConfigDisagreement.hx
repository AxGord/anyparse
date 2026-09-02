package anyparse.check;

import anyparse.query.NamingPolicy.FrameworkContract;

/**
 * A project-level setting a lint RUN resolves ONCE, from its first file, over a scope that may span
 * several `apqlint.json` roots — and the one sentence that says so when those roots disagree.
 *
 * Two such settings exist and both stay resolved that way. The framework roster, because the rules
 * sharing it do not all have a per-file seam to resolve at (`unused-public-member` builds one
 * whole-scope context before it sees a file) and a roster differing between two of them would spare a
 * member from one rule and delete it with its sibling. The `compilerOracle`, because an oracle names
 * ONE build. Neither choice is the defect; the SILENCE was — a file under the second root was linted
 * by the first root's answer and no byte of output said so, which is the same shape as a `frameworks`
 * entry this package drops without a diagnostic.
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
		warn('the framework roster', rosterMessage(resolve, paths));
	}

	/**
	 * Warn once when the scope's roots name different `compilerOracle` builds.
	 *
	 * Called from `Cli.runLint` and gated there on `--no-oracle`: a run that takes no oracle verdict
	 * has nothing a disagreement could corrupt.
	 */
	public static function warnOracle(resolve: Null<(String) -> LintConfig>, paths: Array<String>): Void {
		warn('the compiler oracle', oracleMessage(resolve, paths));
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
	 * Emit `message`'s sentence, at most once per process per setting.
	 *
	 * Through `LintConfig`'s own ledger rather than a second one, so a run that has already warned
	 * about a setting stays quiet however many rules ask the question again.
	 */
	@:access(anyparse.check.LintConfig)
	private static function warn(setting: String, line: Null<String>): Void {
		if (line != null) LintConfig.warnOnce('scope-disagreement:$setting', line);
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
