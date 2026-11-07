package unit.query;

import anyparse.check.FixVerifier;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.OracleProvider;
import anyparse.query.OracleProviders;

/**
 * `OracleProviders.of`, the seam a verified `--fix` phase reaches the compiler through: the grammar's own capability,
 * found through the run's caching wrapper, and for a grammar that supplies none an oracle that judges nothing.
 */
class OracleProvidersTest extends Test {

	/** A configuration no compiler is asked about: every answer below comes from the grammar's capability alone. */
	private static final CONFIG: OracleConfig = { hxml: 'never-compiled.hxml', dir: null, defines: [] };

	@:pin('control')
	@:killer('M-ORACLE-PROVIDER-NOT-THROUGH-CACHE')
	public function testTheHaxeGrammarSuppliesItsCompilerThroughTheRunCache(): Void {
		Assert.isTrue(OracleProviders.of(new HaxeQueryPlugin()) is HaxeQueryPlugin, 'the bare plugin is its own oracle');
		Assert.isTrue(
			OracleProviders.of(new CachingGrammarPlugin(new HaxeQueryPlugin())) is HaxeQueryPlugin,
			'the run wraps the plugin, and the wrapper hands back the grammar\'s oracle'
		);
	}

	@:pin('control')
	@:killer('M-ORACLE-ABSENT-JUDGES')
	public function testAGrammarWithoutACompilerJudgesNothing(): Void {
		final oracle: OracleProvider = OracleProviders.of(new CachingGrammarPlugin(new JsonQueryPlugin()));
		final measured: OracleBaseline = oracle.judging([CONFIG]);
		Assert.equals(0, measured.judging.length);
		Assert.isTrue(measured.verdict.equals(Unavailable(OracleProviders.NO_ORACLE)), 'got ${measured.verdict}');
		Assert.isTrue(oracle.typecheckAll([CONFIG], false).equals(Unavailable(OracleProviders.NO_ORACLE)));
		Assert.isTrue(oracle.typecheck(CONFIG.hxml, null, []).equals(Unavailable(OracleProviders.NO_ORACLE)));
		final readings: Array<OracleReading> = oracle.typecheckEachReading([CONFIG, CONFIG], false);
		Assert.equals(2, readings.length);
		for (reading in readings) {
			Assert.same(Unavailable(OracleProviders.NO_ORACLE), reading.outcome);
			Assert.isNull(reading.parsed);
		}
		Assert.isNull(oracle.serverTypecheck(CONFIG.hxml, null, [], []));
		Assert.equals(OracleProviders.NO_ORACLE, oracle.usableOnce({ probes: [], usable: null }, [CONFIG], []).stop);
		Assert.same([false], oracle.nameProof().sameDeclarations('A.json', '{}', '{}', [{ before: 0, after: 0 }], []));
		Assert.isNull(oracle.startDisplay(_ -> null, CONFIG.hxml, null, []));
		Assert.equals(0, oracle.invocations());
	}

	@:pin('control')
	@:killer('M-FIXVERIFIER-BASELINE-NOT-ASKED')
	public function testTheRiskyPhaseTakesItsBaselineFromTheGrammarsOracle(): Void {
		final result: FixVerifyResult = FixVerifier.verify([], [], new JsonQueryPlugin(), [CONFIG], (_, _) -> {});
		Assert.isTrue(result.baseline.equals(Unavailable(OracleProviders.NO_ORACLE)), 'got ${result.baseline}');
	}

}
