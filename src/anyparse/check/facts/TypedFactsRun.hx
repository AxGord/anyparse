package anyparse.check.facts;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.facts.TypedFactsProbe.FactsProbe;
import anyparse.query.CompilerFacts;
import anyparse.query.OracleProvider.StartedProbe;

/** The facts compiles of one run behind the handle a run holds them by: `TypedFactsProbe` does the work. */
@:nullSafety(Strict)
final class TypedFactsRun implements StartedProbe<CompilerFacts> {

	private final _probe: FactsProbe;

	public function new(oracles: Array<OracleConfig>) {
		_probe = TypedFactsProbe.start(oracles);
	}

	public function finish(): Null<CompilerFacts> {
		return TypedFactsProbe.finish(_probe);
	}

	public function abandon(): Void {
		TypedFactsProbe.abandon(_probe);
	}

}
