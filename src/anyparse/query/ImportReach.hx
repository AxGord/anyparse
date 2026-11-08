package anyparse.query;

import anyparse.check.Check;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.query.OracleProvider.OracleCoverageMemo;
import anyparse.runtime.Span;

using Lambda;

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

	/** Whether a declared build has been compiled for a reach question yet: the probe is lazy, so a run that never asks has not. */
	public inline function probed(): Bool {
		return _memo.probes.length > 0;
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

	/**
	 * `found` without each finding whose remedy module (`Violation.remedy`) some declared build that reads its file cannot resolve:
	 * a rule whose only advice is a helper out of the build's reach does not report there. A module the file already imports is
	 * resolved by definition, and a run holding no such finding probes no build.
	 */
	public function reportable(
		found: Array<Violation>, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): Array<Violation> {
		if (_oracles.length == 0 || !found.exists(v -> v.remedy != null)) return found;
		final sources: Map<String, String> = [for (entry in files) entry.file => entry.source];
		return [for (v in found) if (remedyResolves(v, sources[v.file] ?? '', plugin)) v];
	}

	/** Whether every build that reads `v`'s file resolves its remedy module, or the file imports it itself, or the finding names none. */
	private function remedyResolves(v: Violation, source: String, plugin: GrammarPlugin): Bool {
		final module: Null<String> = v.remedy;
		return module == null
			|| importedPaths(source, plugin).contains(module)
			|| _provider.probedOnce(_memo, _oracles).foreach(coverage -> coverage.unreached(v.file, [module]) == null);
	}

	/** The import paths `edits` bring into `source` that it did not import before, in the grammar's own reading of an import. */
	private static function addedImports(source: String, edits: Array<{ span: Span, text: String }>, plugin: GrammarPlugin): Array<String> {
		final before: Array<String> = importedPaths(source, plugin);
		return importedPaths(CanonicalEdit.applyEdits(source, edits), plugin).filter(path -> !before.contains(path));
	}

	/** The import paths `source` binds, in the grammar's own reading of an import; none for a grammar that reads none. */
	private static function importedPaths(source: String, plugin: GrammarPlugin): Array<String> {
		if (!(plugin is TypeInfoProvider)) return [];
		final info: TypeInfoProvider = cast plugin;
		return [for (path in info.importMap(source)) path];
	}

}
