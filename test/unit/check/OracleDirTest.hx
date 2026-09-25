package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.CompilerDisplayOracle;
import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.OracleCache;
import anyparse.check.OracleCoverage;
import anyparse.check.ReachDefinesProbe;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * A `compilerOracle` entry's `dir` is the working directory of EVERY spawn of that configuration,
 * not of the typecheck alone: the coverage probe, the reach define probe, the display server and the
 * verdict cache's fingerprint all read the hxml's relative `-cp`, which resolves against the
 * process cwd — so a spawn that dropped the directory answers about a different tree.
 *
 * The fixture's hxml sits in `sub/` and names `-cp src`, which exists only under `sub/`; from the
 * suite's own cwd that classpath does not hold `Main`, so every spawn that ignores `dir` fails.
 */
@:nullSafety(Strict)
final class OracleDirTest extends Test {

	#if (sys || nodejs)
	private static final MAIN: String = 'class Main {\n\n\tpublic static function main() {\n\t\ttrace(1);\n\t}\n\n}\n';
	private static final HXML: String = '-cp src\n-main Main\n';
	#end

	/** One typecheck, spawned on its own. */
	@:pin('control')
	@:killer('M-SPAWN-RUN-IGNORES-CWD')
	public function testASingleTypecheckRunsInTheDeclaredDir(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final config: OracleConfig = at(root, []);
		final verdict: OracleOutcome = CompilerOracle.typecheck(config.hxml, config.dir, config.defines);
		Assert.isTrue(verdict.match(Confirmed), 'the relative -cp resolves under dir: $verdict');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Several typechecks overlapping through the parallel driver, which spawns each in its own directory. */
	@:pin('control')
	@:killer('M-SPAWN-RUNALL-IGNORES-CWD')
	public function testOverlappedTypechecksRunInTheDeclaredDir(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final declared: Null<String> = Sys.getEnv('APQ_ORACLE_PARALLEL');
		Sys.putEnv('APQ_ORACLE_PARALLEL', '2');
		var verdict: OracleOutcome = Unavailable('not asked');
		var coverage: Array<OracleCoverage> = [];
		CliFixture.always(() -> Sys.putEnv('APQ_ORACLE_PARALLEL', declared ?? ''), () -> {
			verdict = CompilerOracle.typecheckAll([at(root, []), at(root, ['second'])]);
			coverage = OracleCoverage.probeAll([at(root, []), at(root, ['second'])]);
		});
		Assert.equals(2, coverage.length, 'both configurations were probed');
		Assert.isTrue(verdict.match(Confirmed), 'both configurations typecheck from dir: $verdict');
		Assert.isTrue(coverage[0].known && coverage[1].known, 'both coverage probes ran from dir');
		Assert.isTrue(coverage[0].covers('$root/sub/src/Main.hx'), 'and read the module under dir');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The single coverage probe and the reach define probe. */
	@:pin('control')
	@:killer('M-SPAWN-RUN-IGNORES-CWD')
	public function testTheProbesRunInTheDeclaredDir(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final config: OracleConfig = at(root, []);
		final coverage: OracleCoverage = OracleCoverage.probe(config.hxml, config.dir, config.defines);
		Assert.isTrue(coverage.known && coverage.covers('$root/sub/src/Main.hx'), 'the coverage probe ran from dir: ${coverage.reason}');
		Assert.notNull(ReachDefinesProbe.probeAll([config]), 'the reach define probe ran from dir');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The verdict cache's fingerprint walks the classpath under dir, so an edit there changes it. */
	@:pin('control')
	@:killer('M-ORACLE-CACHE-IGNORES-DIR')
	public function testTheFingerprintReadsTheClasspathUnderTheDeclaredDir(): Void {
		#if (sys || nodejs)
		final root: String = fixture();
		final config: OracleConfig = at(root, []);
		final before: Null<String> = OracleCache.fingerprint(config.hxml, config.dir, config.defines);
		File.saveContent('$root/sub/src/Main.hx', '$MAIN// edited\n');
		final after: Null<String> = OracleCache.fingerprint(config.hxml, config.dir, config.defines);
		Assert.notNull(before, 'the fingerprint is taken');
		Assert.notEquals(before, after, 'a module under dir/src is part of the compile input');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The display server compiles the configuration from dir, so it can type a module under it. */
	@:pin('control')
	@:killer('M-DISPLAY-IGNORES-DIR')
	public function testTheDisplayServerWarmsInTheDeclaredDir(): Void {
		#if nodejs
		final root: String = fixture();
		final config: OracleConfig = at(root, []);
		final display: Null<CompilerDisplayOracle> = CompilerDisplayOracle.start(config.hxml, config.dir, config.defines);
		final type: Null<String> = display?.typeAt('$root/sub/src/Main.hx', MAIN.indexOf('trace(1)') + 'trace('.length);
		display?.stop();
		Assert.equals('Int', type, 'the server compiled the build from dir, so it can type a module there');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-node target');
		#end
	}

	#if (sys || nodejs)
	private static function fixture(): String {
		return CliFixture.writeTree('oracledir', [
			{ name: 'sub/check.hxml', source: HXML },
			{ name: 'sub/src/Main.hx', source: MAIN }
		]);
	}

	/** The fixture's one configuration under `defines`, compiled from `sub/`. */
	private static function at(root: String, defines: Array<String>): OracleConfig {
		return {
			hxml: '$root/sub/check.hxml',
			dir: '$root/sub',
			defines: defines
		};
	}
	#end

}
