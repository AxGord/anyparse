package anyparse.check.oracle;

import anyparse.check.Check.NameOracle;
import anyparse.check.oracle.CompilerDisplayOracle.TypeReplyPosition;
import anyparse.check.oracle.OracleCoverage.UsableCoverage;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

/**
 * The compiler's answer to `NameOracle`: each configuration's warm server in the run's pool (`OracleRunMemo.servers`,
 * `OracleServerPool.positionIn`) is asked where the name is declared in the text before and after a rewrite. Every
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

	public function sameDeclaration(file: String, before: String, beforeAt: Int, after: String, afterAt: Int): Bool {
		final judges: Null<() -> UsableCoverage> = _judges;
		final plugin: Null<GrammarPlugin> = _plugin;
		if (judges == null || plugin == null) return false;
		final usable: UsableCoverage = judges();
		if (usable.stop != null) return false;
		final asked: Array<OracleConfig> = compiling(usable, file, before, beforeAt, plugin);
		for (config in asked) {
			final pool: Null<OracleServerPool> = config.runs?.servers;
			if (pool == null) return false;
			// a run that verifies before its facts compiles freed the cores has not started its servers yet
			pool.start(usable.configs.concat(usable.unknown));
			final was: Null<TypeReplyPosition> = pool.positionIn(config, file, before, beforeAt);
			if (was == null || !samePosition(was, pool.positionIn(config, file, after, afterAt))) return false;
		}
		return asked.length > 0;
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

}
