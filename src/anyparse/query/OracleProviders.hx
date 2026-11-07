package anyparse.query;

import anyparse.check.Check.NameSite;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.query.OracleProvider.CompiledSet;
import anyparse.query.OracleProvider.DisplayTypeOracle;
import anyparse.query.OracleProvider.NameProof;
import anyparse.query.OracleProvider.OracleBaseline;
import anyparse.query.OracleProvider.OracleCoverageMemo;
import anyparse.query.OracleProvider.OracleExclusion;
import anyparse.query.OracleProvider.OracleOutcome;
import anyparse.query.OracleProvider.OracleReading;
import anyparse.query.OracleProvider.UsableCoverage;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

/**
 * The one answer to "which compiler oracle does a run's grammar supply": the plugin's own `OracleProvider`, looked up
 * through a `CachingGrammarPlugin` to the grammar it wraps, or an oracle that is never available for a grammar that
 * supplies none — so a verified phase on such a grammar declines every risky edit instead of compiling with a stranger.
 */
@:nullSafety(Strict)
final class OracleProviders {

	/** The `Unavailable` reason every answer of a grammar without a compiler oracle carries. */
	public static inline final NO_ORACLE: String = 'this grammar supplies no compiler oracle';

	/** `plugin`'s compiler oracle — never null; see the type's doc for a grammar that has none. */
	public static function of(plugin: GrammarPlugin): OracleProvider {
		final grammar: GrammarPlugin = plugin is CachingGrammarPlugin ? (cast plugin: CachingGrammarPlugin)._inner : plugin;
		return grammar is OracleProvider ? cast grammar : new AbsentOracle();
	}

}

/** A grammar's missing compiler oracle: compiles nothing, so every verdict is `Unavailable` and nothing is judged. */
@:nullSafety(Strict)
private final class AbsentOracle implements OracleProvider implements NameProof {

	public function new() {}

	public function invocations(): Int {
		return 0;
	}

	public function judging(oracles: Array<OracleConfig>): OracleBaseline {
		return { judging: [], excluded: [], verdict: Unavailable(OracleProviders.NO_ORACLE) };
	}

	public function typecheck(hxml: String, cwd: Null<String>, defines: Array<String>): OracleOutcome {
		return Unavailable(OracleProviders.NO_ORACLE);
	}

	public function typecheckAll(oracles: Array<OracleConfig>, verbose: Bool): OracleOutcome {
		return Unavailable(OracleProviders.NO_ORACLE);
	}

	public function typecheckEachReading(oracles: Array<OracleConfig>, stopAfterFailure: Bool): Array<OracleReading> {
		return [
			for (_ in oracles) { outcome: Unavailable(OracleProviders.NO_ORACLE), parsed: null }
		];
	}

	public function serverTypecheck(hxml: String, cwd: Null<String>, paths: Array<String>, defines: Array<String>): Null<OracleOutcome> {
		return null;
	}

	public function exclusionKey(exclusion: OracleExclusion): String {
		return '${exclusion.config.hxml}\n${exclusion.cause}';
	}

	public function usableOnce(memo: OracleCoverageMemo, oracles: Array<OracleConfig>, excluded: Array<OracleExclusion>): UsableCoverage {
		return {
			configs: [],
			coverages: [],
			unknown: [],
			excluded: [],
			stop: OracleProviders.NO_ORACLE
		};
	}

	public function probedOnce(memo: OracleCoverageMemo, oracles: Array<OracleConfig>): Array<CompiledSet> {
		return [];
	}

	public function nameProof(): NameProof {
		return this;
	}

	public function startDisplay(
		typeSyntax: TypeSyntaxReader, hxml: String, cwd: Null<String>, defines: Array<String>
	): Null<DisplayTypeOracle> {
		return null;
	}

	public function answerFor(judges: () -> UsableCoverage, plugin: GrammarPlugin): Void {}

	public function sameDeclarations(
		file: String, before: String, after: String, sites: Array<NameSite>, edits: Array<{ span: Span, text: String }>
	): Array<Bool> {
		return [for (_ in sites) false];
	}

}
