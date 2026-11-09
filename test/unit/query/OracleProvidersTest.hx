package unit.query;

import anyparse.check.FixVerifier;
import anyparse.check.LintConfig;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.Cli;
import anyparse.query.OracleProvider;
import anyparse.query.OracleProviders;
import anyparse.query.cli.command.LintFixVerify;
import unit.cli.CliFixture;

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

	@:pin('control')
	@:killer('M-ORACLE-ABSENT-FINGERPRINTS')
	public function testAGrammarWithoutACompilerRecordsAndPreparesNothing(): Void {
		final oracle: OracleProvider = OracleProviders.of(new JsonQueryPlugin());
		Assert.isNull(oracle.fingerprint(CONFIG.hxml, null, [], []));
		Assert.isNull(oracle.lookupVerdict(CONFIG.hxml, null, 'f', []));
		Assert.isFalse(oracle.storeVerdictIfUnchanged(CONFIG.hxml, null, 'f', Confirmed, [], [], null));
		Assert.same([], oracle.classPaths(CONFIG.hxml, null));
		Assert.isNull(oracle.classRoots(CONFIG.hxml, null));
		Assert.same([CONFIG], oracle.prepareBuilds([CONFIG]).oracles);
		Assert.same([CONFIG], oracle.attachRun([CONFIG], false, () -> [], new JsonQueryPlugin()));
	}

	@:pin('control')
	@:killer('M-ORACLE-FIRST-OF-ABSENT')
	public function testARunOfSeveralGrammarsAsksTheOneWithACompiler(): Void {
		Assert.isTrue(OracleProviders.firstOf([new JsonQueryPlugin(), new CachingGrammarPlugin(new HaxeQueryPlugin())]) is HaxeQueryPlugin);
	}

	@:pin('control')
	@:killer('M-ORACLE-NO-SERVER-NOT-COLD')
	public function testAWarmReportOnAGrammarWithoutACompilerFallsThroughToNoVerdict(): Void {
		final exit: Null<Int> = LintFixVerify.reportModeOracle(OracleProviders.of(new JsonQueryPlugin()), [CONFIG], ['A.json'], true);
		Assert.isNull(exit, 'no compiler answered, so the report neither stops nor rejects');
	}

	@:pin('control')
	@:killer('M-ORACLE-COMMAND-COMPILES-WITHOUT-PROVIDER')
	public function testTheOracleCommandOnAGrammarWithoutACompilerCompilesAndRecordsNothing(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('oracle-absent', [
			{ name: 'apq.json', source: '{"compilerOracle":"b.hxml"}' },
			{ name: 'b.hxml', source: '--interp\n--no-output\n' },
			{ name: 'a.json', source: '{}' }
		]);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['oracle', '--lang', 'json', '$dir/a.json']));
		Assert.equals(0, exit);
		Assert.isTrue(err.indexOf(OracleProviders.NO_ORACLE) >= 0, err);
		Assert.isTrue(err.indexOf('typechecks — verdict recorded') < 0, err);
		Assert.isTrue(err.indexOf('no fingerprint') < 0, err);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-ORACLE-ABSENT-READS-NOTHING')
	public function testAGrammarWithoutACompilerStillNamesTheBuildsTheProjectDeclares(): Void {
		final config: LintConfig = LintConfig.parse(
			'{"compilerOracle":[{"hxml":"b.hxml","defines":["X"],"dir":"d"},{"hxml":"c.hxml"},{"dir":"e"}]}', '/proj'
		);
		final absent: OracleProvider = OracleProviders.of(new JsonQueryPlugin());
		final oracles: Array<OracleConfig> = config.compilerOracles(absent);
		Assert.same(['/proj/b.hxml', '/proj/c.hxml'], oracles.map(oracle -> oracle.hxml));
		Assert.same([['X'], []], oracles.map(oracle -> oracle.defines));
		Assert.same(['/proj/d', null], oracles.map(oracle -> oracle.dir));
		Assert.same(
			['/proj/a.hxml'], LintConfig.parse('{"compilerOracle":"a.hxml"}', '/proj').compilerOracles(absent).map(oracle -> oracle.hxml)
		);
	}

	@:pin('control')
	@:killer('M-ORACLE-HAXE-IS-SOURCE-ALWAYS')
	@:killer('M-ORACLE-ABSENT-IS-SOURCE-ALWAYS')
	@:killer('M-ORACLE-HAXE-MODULE-UNDER-NULL')
	public function testTheProviderTellsASourceAndItsModuleInsteadOfTheCallerReadingTheHaxeOracle(): Void {
		final haxe: OracleProvider = OracleProviders.of(new HaxeQueryPlugin());
		Assert.isTrue(haxe.isSource('src/a/B.hx'));
		Assert.isFalse(haxe.isSource('src/a/B.json'));
		Assert.equals('a.B', haxe.moduleUnder(['/proj/src'], '/proj/src/a/B.hx'));
		Assert.isNull(haxe.moduleUnder(['/proj/src'], '/elsewhere/a/B.hx'));
		final absent: OracleProvider = OracleProviders.of(new JsonQueryPlugin());
		Assert.isFalse(absent.isSource('src/a/B.hx'));
		Assert.isNull(absent.moduleUnder(['/proj/src'], '/proj/src/a/B.hx'));
	}

	@:pin('control')
	@:killer('M-ORACLE-ABSENT-DROPS-LOST')
	public function testAGrammarWithoutACompilerStillReportsAMalformedDeclaration(): Void {
		final config: LintConfig = LintConfig.parse('{"compilerOracle":[{"dir":"e"},"x.hxml"]}', '/proj');
		Assert.same([], config.compilerOracles(OracleProviders.of(new JsonQueryPlugin())));
		Assert.same([
			'compilerOracle[0] declares no "hxml" — dropped',
			'compilerOracle[1] is not an object — dropped'
		], config.drops());
	}

}
