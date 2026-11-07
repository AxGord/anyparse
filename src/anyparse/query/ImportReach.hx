package anyparse.query;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.query.OracleProvider.OracleCoverageMemo;
import anyparse.runtime.Span;

/**
 * The one answer to "can the builds that compile this module see what a fix newly brings in": the modules an edit set binds that
 * the source did not, asked of every declared `compilerOracle` build that reads it, through the grammar's `OracleProvider`.
 *
 * A build whose classpath is narrower than the lint scope (the replay program's `-cp test` alone) compiles the module but cannot
 * resolve a type under `src`. The compile that would say so is the net `--no-oracle` switches off, so this answers from each
 * build's compiled set, probed lazily and once per run. Run-scoped: the probes live in the instance, never in a static.
 */
@:nullSafety(Strict)
final class ImportReach {

	private final _memo: OracleCoverageMemo = {
		probes: [],
		usable: null
	};
	private final _oracles: Array<OracleConfig>;
	private final _provider: OracleProvider;

	public function new(provider: OracleProvider, oracles: Array<OracleConfig>) {
		_provider = provider;
		_oracles = oracles;
	}

	/**
	 * Why `edits` to `file` must not be written — a sentence ready to quote in a decline — or null when they add no
	 * import, every build that reads the file resolves each added module, or no build can say.
	 */
	public function unreached(
		file: String, source: String, edits: Array<{ span: Span, text: String }>, plugin: GrammarPlugin
	): Null<String> {
		if (_oracles.length == 0 || edits.length == 0) return null;
		final added: Array<String> = addedImports(source, edits, plugin);
		if (added.length == 0) return null;
		for (coverage in _provider.probedOnce(_memo, _oracles)) {
			final gap: Null<String> = coverage.unreached(file, added);
			if (gap != null) return gap;
		}
		return null;
	}

	/** The import paths `edits` bring into `source` that it did not import before, in the grammar's own reading of an import. */
	private static function addedImports(source: String, edits: Array<{ span: Span, text: String }>, plugin: GrammarPlugin): Array<String> {
		if (!(plugin is TypeInfoProvider)) return [];
		final info: TypeInfoProvider = cast plugin;
		final before: Array<String> = [for (path in info.importMap(source)) path];
		final spliced: String = CanonicalEdit.applyEdits(source, edits);
		return [for (path in info.importMap(spliced)) if (!before.contains(path)) path];
	}

}
