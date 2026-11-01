package anyparse.check.oracle;

import anyparse.check.Check.NameOracle;
import anyparse.check.Check.NameSite;
import anyparse.check.oracle.CompilerDisplayOracle.TypeReplyPosition;
import anyparse.check.oracle.OracleCoverage.UsableCoverage;
import anyparse.check.oracle.OracleServerPool.PositionAsk;
import anyparse.core.PhaseTimings;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

/**
 * The compiler's answer to `NameOracle`: each configuration's warm server in the run's pool
 * (`OracleRunMemo.servers`, `OracleServerPool.positionsIn`) is asked where the name is declared in the
 * text before and after a rewrite, every site of the rewrite and every configuration in one round. Every
 * configuration that compiles the site — by its compiled set and the `#if` branches its defines keep live
 * (`OracleCoverage`), or whose compiled set is unknown — must name one declaration for both; a configuration naming
 * none, or with no server in the pool, is no answer, never a pass. RUN-scoped: built for one verified pass.
 */
@:nullSafety(Strict)
final class CompilerNameProof implements NameOracle {

	/** Which configurations judge and what each compiles; null until `answerFor`. */
	private var _judges: Null<() -> UsableCoverage> = null;

	/** The grammar the site's conditional regions are read with; null until `answerFor`. */
	private var _plugin: Null<GrammarPlugin> = null;

	public function new() {}

	/** Ask the configurations `judges` names from now on, reading conditional regions with `plugin`. */
	public function answerFor(judges: () -> UsableCoverage, plugin: GrammarPlugin): Void {
		_judges = judges;
		_plugin = plugin;
	}

	public function sameDeclarations(file: String, before: String, after: String, sites: Array<NameSite>): Array<Bool> {
		return PhaseTimings.measure('oracle name proof', sameDeclarationsTimed.bind(file, before, after, sites));
	}

	/** `sameDeclarations`, untimed: every configuration asked about every site it compiles, all in one round. */
	private function sameDeclarationsTimed(file: String, before: String, after: String, sites: Array<NameSite>): Array<Bool> {
		final judges: Null<() -> UsableCoverage> = _judges;
		final plugin: Null<GrammarPlugin> = _plugin;
		if (judges == null || plugin == null) return [for (_ in sites) false];
		final usable: UsableCoverage = judges();
		if (usable.stop != null) return [for (_ in sites) false];
		final asked: Array<Array<OracleConfig>> = [for (site in sites) compiling(usable, file, before, site.before, plugin)];
		final configs: Array<OracleConfig> = [];
		for (row in asked) for (config in row) if (!configs.contains(config)) configs.push(config);
		// the sites each configuration is asked about, by index into `sites`; its answers come in pairs, before then after
		final sitesOf: Array<Array<Int>> = [for (config in configs) [for (j => row in asked) if (row.contains(config)) j]];
		final answers: Array<Null<Array<Null<TypeReplyPosition>>>> = positionsOf(
			configs,
			[for (c in sitesOf) asksAbout([for (j in c) sites[j]], before, after)],
			file, usable
		);
		return [
			for (j => row in asked) agreed(
				row, config -> pairAt(answers[configs.indexOf(config)], sitesOf[configs.indexOf(config)].indexOf(j))
			)
		];
	}

	/** Whether the compiler named one place for both answers — `now` null, or anywhere else, is a different reading. PURE. */
	public static function samePosition(was: TypeReplyPosition, now: Null<TypeReplyPosition>): Bool {
		return now != null
			&& was.file == now.file
			&& was.line == now.line
			&& was.first == now.first
			&& was.last == now.last
			&& was.byLine == now.byLine;
	}

	/**
	 * The configurations whose reading of the site at `at` of `source` decides: each whose compiled set holds that byte of
	 * `file` in a branch its defines keep live, and each whose compiled set is unknown.
	 */
	private static function compiling(
		usable: UsableCoverage, file: String, source: String, at: Int, plugin: GrammarPlugin
	): Array<OracleConfig> {
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final site: Array<Span> = [new Span(at, at + 1)];
		return [
			for (i in 0...usable.configs.length)
				if (usable.coverages[i].uncovered(file, source, site, plugin.refShape(), regions) == null) usable.configs[i]
		].concat(usable.unknown);
	}

	/**
	 * Whether every one of `asked` named one declaration for both readings of a site, `answer` giving a configuration's
	 * pair, before then after — null when it holds none. No configuration asked is no agreement.
	 */
	private static function agreed(asked: Array<OracleConfig>, answer: OracleConfig -> Null<Array<Null<TypeReplyPosition>>>): Bool {
		for (config in asked) {
			final pair: Null<Array<Null<TypeReplyPosition>>> = answer(config);
			if (pair == null) return false;
			final was: Null<TypeReplyPosition> = pair[0];
			if (was == null || !samePosition(was, pair[1])) return false;
		}
		return asked.length > 0;
	}

	/** The run pools the servers of `configs` live in, each once; a configuration in none is in no pool. */
	private static function poolsOf(configs: Array<OracleConfig>): Array<OracleServerPool> {
		final out: Array<OracleServerPool> = [];
		for (config in configs) {
			final pool: Null<OracleServerPool> = config.runs?.servers;
			if (pool != null && !out.contains(pool)) out.push(pool);
		}
		return out;
	}

	/** The two readings of each of `sites`, in order: its name in `before`, then in `after`. PURE. */
	private static function asksAbout(sites: Array<NameSite>, before: String, after: String): Array<PositionAsk> {
		final out: Array<PositionAsk> = [];
		for (site in sites) {
			out.push({ content: before, at: site.before });
			out.push({ content: after, at: site.after });
		}
		return out;
	}

	/** The `m`-th pair of `answers` — a configuration's two readings of its `m`-th site — or null when it answered none. PURE. */
	private static function pairAt(answers: Null<Array<Null<TypeReplyPosition>>>, m: Int): Null<Array<Null<TypeReplyPosition>>> {
		return answers == null ? null : [answers[2 * m], answers[2 * m + 1]];
	}

	/**
	 * Each of `configs` asked its `asks` through the run pool its server lives in, every pool's configurations at once; null
	 * for a configuration in no pool or whose server the pool does not hold.
	 */
	private static function positionsOf(
		configs: Array<OracleConfig>, asks: Array<Array<PositionAsk>>, file: String, usable: UsableCoverage
	): Array<Null<Array<Null<TypeReplyPosition>>>> {
		final out: Array<Null<Array<Null<TypeReplyPosition>>>> = [for (_ in configs) null];
		for (pool in poolsOf(configs)) {
			// a run that verifies before its facts compiles freed the cores has not started its servers yet
			pool.start(usable.configs.concat(usable.unknown));
			final mine: Array<Int> = [for (c => config in configs) if (config.runs?.servers == pool) c];
			final replies: Array<Null<Array<Null<TypeReplyPosition>>>> = pool.positionsIn(
				[for (c in mine) configs[c]], file, [for (c in mine) asks[c]]
			);
			for (k => c in mine) out[c] = replies[k];
		}
		return out;
	}

}
