package testkit;

import anyparse.check.Check;
import anyparse.check.ConfigNotes;
import anyparse.check.EffectiveRules;
import anyparse.check.LintConfig;
import anyparse.check.LintDocuments.DocumentMemo;
import anyparse.query.OracleProvider;

/**
 * Config reads for a test that asserts on the configuration, not on its diagnostics: each collects the notes and
 * says them through `ConfigNotes.warn`, as a caller with no ledger must, so none is dropped.
 */
@:nullSafety(Strict)
final class TestConfigs {

	/** `LintConfig.discover` of `path`. */
	public static function discover(path: String): LintConfig {
		return ConfigNotes.into(null, notes -> LintConfig.discover(path, notes));
	}

	/** `LintConfig.discoverChain` of `path`. */
	public static function discoverChain(path: String, ?documents: DocumentMemo): DiscoveredConfig {
		return ConfigNotes.into(null, notes -> LintConfig.discoverChain(path, documents, notes));
	}

	/** `EffectiveRules.resolve` of `files` under `checks`. */
	public static function rules(files: Array<String>, checks: Array<Check>): Array<RuleStateGroup> {
		return ConfigNotes.into(null, notes -> EffectiveRules.resolve(files, checks, notes));
	}

	/** `config.compilerOracles` over `compiler`. */
	public static function oracles(config: LintConfig, compiler: OracleProvider): Array<OracleConfig> {
		return ConfigNotes.into(null, notes -> config.compilerOracles(compiler, notes));
	}

}
