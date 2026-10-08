package unit.check;

import anyparse.check.CompilerOracle;
import anyparse.check.CompilerOracle.OracleBaseline;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.OracleCoverage;
import anyparse.check.OracleRunMemo;
import anyparse.check.OracleServerPool;
import anyparse.check.TypedFactsProbe;
import anyparse.query.LintFixSafePass.SafePassOutcome;
import anyparse.query.cli.command.LintFixDriver;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `OracleRunMemo`: inside one run, a compile of a tree the run already compiled is answered from the memo — and only a
 * compile of the same CONTENT, only one whose input held still, and never with the streams a rejection may not quote.
 *
 * Every fixture counts COMPILES, not spawns: its hxml runs an init macro (`Counter.hit`) that appends a line to
 * `compiles.log` in the configuration's directory, so the compiler itself says how often it ran, whichever class
 * spawned it.
 */
@:nullSafety(Strict)
final class OracleRunMemoTest extends Test {

	#if (sys || nodejs)
	private static final GOOD: String = 'class Main {\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n}\n';
	private static final OTHER: String = 'class Main {\n\tstatic function main() {\n\t\ttrace(2);\n\t}\n}\n';
	private static final BAD: String = 'class Main {\n\tstatic function main() {\n\t\tnope();\n\t}\n}\n';
	private static final MUTATOR: String = 'class Mutator {\n\tpublic static function once():Void {\n'
		+ '\t\tif (sys.FileSystem.exists(\'mutated.flag\')) return;\n\t\tsys.io.File.saveContent(\'mutated.flag\', \'\');\n'
		+ '\t\tsys.io.File.saveContent(\'Main.hx\', \'class Main { static function main() { nope(); } }\\n\');\n\t}\n}\n';
	private static final BUILD: String = '-cp .\n-main Main\n--js out.js\n' + CompileCounter.MACRO;
	#end

	/** The coverage probe of the tree a baseline just compiled with `-v` IS that compile, so it costs none of its own. */
	@:pin('control')
	@:killer('M-RUNMEMO-PROBE-RECOMPILES')
	public function testTheCoverageProbeReusesTheBaselineCompile(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the baseline confirms');
		final coverage: OracleCoverage = OracleCoverage.probeAll(oracles)[0];
		Assert.isTrue(coverage.covers('$dir/Main.hx'), 'the reused run still names what the compile read');
		Assert.equals(1, CompileCounter.count(dir), 'one compile answered both the baseline and the probe');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The safe-write net's after-write typecheck compiles with `-v`: the risky phase's coverage probe asks about exactly
	 * that tree next, and is answered by the net's own compile.
	 */
	@:pin('control')
	@:killer('M-SAFE-NET-PLAIN')
	@:access(anyparse.query.cli.command.LintFixDriver)
	public function testTheSafeWriteNetCompilesTheTreeTheCoverageProbeAsksAbout(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		final main: String = '$dir/Main.hx';
		final pre: OracleBaseline = CompilerOracle.judging(oracles);
		sys.io.File.saveContent(main, OTHER);
		final net: SafePassOutcome = LintFixDriver.reconcileSafePass(
			[{ file: main, source: OTHER }], [main], [main => GOOD], [], pre, oracles, []
		);
		Assert.isFalse(net.reverted, 'a green write is kept');
		Assert.isTrue(OracleCoverage.probeAll(oracles)[0].covers(main), 'the probe names what the compile read');
		Assert.equals(2, CompileCounter.count(dir), 'the probe of the written tree cost no compile of its own');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A run's warm server answers a tree the run rewrote inside the very second it last compiled: the pool hands it every
	 * path whose TEXT moved, while the server's own check compares modification times, which here do not move at all.
	 */
	@:pin('control')
	@:killer('M-POOL-NO-INVALIDATE')
	public function testAWarmServerReadsATreeRewrittenWithinTheSecond(): Void {
		#if nodejs
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		pool?.start(oracles);
		Assert.isTrue(pool?.running() ?? false, 'the server did not start');
		Assert.equals(0, pool?.compile(oracles)[0]?.status, 'the warm server compiles the first text');
		final main: String = '$dir/Main.hx';
		final stamp: Date = js.node.Fs.statSync(main).mtime;
		sys.io.File.saveContent(main, BAD);
		js.node.Fs.utimesSync(main, stamp, stamp);
		Assert.isTrue(CompilerOracle.typecheckAll(oracles).match(Rejected(_)), 'the warm server answered the text that is gone');
		pool?.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	/**
	 * A run's warm server dies with the batch driver that started it, however the driver went: a SIGKILL of the process
	 * group `apq` and the driver share leaves the driver no handler to run, and the server's own group is not theirs.
	 */
	@:pin('control')
	@:killer('M-POOL-SERVER-UNTETHERED')
	@:access(anyparse.check.OracleServerPool)
	@:access(anyparse.check.PendingRuns)
	public function testAWarmServerDiesWithItsDriver(): Void {
		#if nodejs
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		pool?.start(oracles);
		final ports: Array<Int> = pool == null ? [] : [for (server in pool._servers) server.port];
		Assert.equals(1, ports.length, 'one server started');
		final servers: Array<Int> = [
			for (port in ports) for (pid in ProcessProbe.pidsRunning('haxe --wait $port')) pid
		];
		final driver: Null<Int> = pool?._batch?._pid;
		Assert.isTrue(servers.length > 0, 'the server runs');
		Assert.notNull(driver, 'the servers have a driver');
		if (driver != null) Assert.equals(0, ProcessProbe.outlivingKilledDriver(driver, servers).length, 'the server outlived its driver');
		pool?.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	/**
	 * A warm rejection is never the verdict: the configuration is compiled again cold. Staged by keeping from the server
	 * that the text moved back, so it answers the rejected text it still holds.
	 */
	@:pin('control')
	@:killer('M-POOL-TRUSTS-WARM-RED')
	@:access(anyparse.check.OracleServerPool)
	public function testAWarmRejectionIsCompiledAgainCold(): Void {
		#if nodejs
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		pool?.start(oracles);
		pool?.compile(oracles);
		final main: String = '$dir/Main.hx';
		final stamp: Date = js.node.Fs.statSync(main).mtime;
		sys.io.File.saveContent(main, BAD);
		js.node.Fs.utimesSync(main, stamp, stamp);
		Assert.isTrue(CompilerOracle.typecheckAll(oracles).match(Rejected(_)), 'the rejected text is rejected');
		sys.io.File.saveContent(main, GOOD);
		js.node.Fs.utimesSync(main, stamp, stamp);
		if (pool != null) for (server in pool._servers) server.seen = pool.texts();
		Assert.isTrue(CompilerOracle.typecheckAll(oracles).match(Confirmed), 'a stale warm rejection was taken as the verdict');
		pool?.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	/**
	 * A verdict is reused for the content it was taken on and for nothing else: the broken tree is compiled (the `-v`
	 * compile and its plain retry), and the tree restored to the first content is answered without a compile.
	 */
	@:pin('control')
	@:killer('M-RUNMEMO-KEY-IGNORES-CONTENT')
	public function testAVerdictIsReusedForTheSameContentOnly(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the first content confirms');
		sys.io.File.saveContent('$dir/Main.hx', BAD);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Rejected(_)), 'the edited content is compiled and refused');
		Assert.equals(3, CompileCounter.count(dir), 'the edit cost the -v compile and its plain retry');
		sys.io.File.saveContent('$dir/Main.hx', GOOD);
		Assert.isTrue(CompilerOracle.typecheckAll(oracles).match(Confirmed), 'the first content is still green');
		Assert.equals(3, CompileCounter.count(dir), 'and it is answered from the memo');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A baseline that fails is quoted as the PLAIN compile quotes it: the `-v` lines never reach a rejection. */
	@:pin('control')
	@:killer('M-RUNMEMO-QUOTES-THE-VERBOSE-STREAMS')
	public function testARejectedBaselineQuotesThePlainCompile(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(BAD, BUILD);
		if (dir == null) return;
		final plain: String = errorsOf(CompilerOracle.typecheck('build.hxml', dir));
		final remembered: String = errorsOf(CompilerOracle.judging(remembering(dir)).verdict);
		Assert.isTrue(plain.indexOf('nope') >= 0, 'the plain compile names the error: $plain');
		Assert.equals(plain, remembered);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A compile whose input changed while it ran is not filed: here an init macro rewrites `Main.hx` before typing, so
	 * that compile judged content its starting fingerprint never named, and must not replace the confirm filed for it.
	 */
	@:pin('control')
	@:killer('M-RUNMEMO-FILES-A-MOVED-INPUT')
	public function testACompileWhoseInputMovedIsNotFiled(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, '$BUILD--macro Mutator.once()\n');
		if (dir == null) return;
		sys.io.File.saveContent('$dir/Mutator.hx', MUTATOR);
		// the flag keeps the macro quiet for the first compile, which proves what the configuration reads
		sys.io.File.saveContent('$dir/mutated.flag', '');
		final oracles: Array<OracleConfig> = remembering(dir);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the first content confirms');
		sys.FileSystem.deleteFile('$dir/mutated.flag');
		sys.io.File.saveContent('$dir/Main.hx', OTHER);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Rejected(_)), 'the compile read what the macro wrote');
		sys.io.File.saveContent('$dir/Main.hx', OTHER);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the restored content is compiled, not answered');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The facts compile brings the baseline of the same tree along, so the baseline asked next costs no compile. */
	@:pin('control')
	@:killer('M-RUNMEMO-NO-BASELINE-AHEAD')
	public function testTheFactsCompileBringsTheBaselineAlong(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		Assert.equals(1, TypedFactsProbe.probeAll(oracles)?.configurations.length, 'the facts compile answered');
		Assert.equals(2, CompileCounter.count(dir), 'the facts compile and the baseline beside it');
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the baseline confirms');
		Assert.equals(2, CompileCounter.count(dir), 'and it is answered from the memo');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A compile that reads a file outside every directory its fingerprint walks — here one an init macro adds to the
	 * classpath — can change with no fingerprint changing, so the configuration is never answered from the memo.
	 */
	@:pin('control')
	@:killer('M-RUNMEMO-TRUSTS-UNSEEN-SOURCES')
	public function testASourceTheFingerprintCannotSeeIsAlwaysCompiled(): Void {
		#if (sys || nodejs)
		// outside the project: a directory under the compile root is walked like any other
		final extra: String = CliFixture.writeDir('runmemoextra', [
			{ name: 'Extra.hx', source: 'class Extra {\n\tpublic static function go():Void {}\n}\n' }
		]);
		final dir: Null<String> = scratch(
			'class Main {\n\tstatic function main() {\n\t\tExtra.go();\n\t}\n}\n', '$BUILD--macro addClassPath(\'$extra\')\n'
		);
		if (dir == null) {
			CliFixture.removeDir(extra);
			return;
		}
		final oracles: Array<OracleConfig> = remembering(dir);
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'the build confirms');
		Assert.isTrue(CompilerOracle.judging(oracles).verdict.match(Confirmed), 'and again');
		Assert.equals(2, CompileCounter.count(dir), 'both baselines compiled: `extra` is invisible to the fingerprint');
		CliFixture.removeDir(dir);
		CliFixture.removeDir(extra);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Configurations no lint run prepared carry no memo, and every question is a compile, as it always was. */
	@:pin('guard')
	public function testAConfigurationOutsideARunIsAlwaysCompiled(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = [{ hxml: 'build.hxml', dir: dir, defines: [] }];
		CompilerOracle.judging(oracles);
		CompilerOracle.judging(oracles);
		Assert.equals(2, CompileCounter.count(dir));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function errorsOf(outcome: OracleOutcome): String {
		return switch outcome {
			case Rejected(errors): errors;
			case _: '';
		};
	}

	#if (sys || nodejs)
	/** A scratch project of `main` and `build`, or null (the test passed) when no compiler is available. */
	private static function scratch(main: String, build: String): Null<String> {
		final dir: String = CliFixture.writeDir('runmemo', [
			{ name: 'Main.hx', source: main },
			{ name: 'Counter.hx', source: CompileCounter.SOURCE },
			{ name: 'build.hxml', source: build }
		]);
		final probe: String = CliFixture.writeDir('runmemoprobe', [
			{ name: 'Main.hx', source: GOOD },
			{ name: 'Counter.hx', source: CompileCounter.SOURCE },
			{ name: 'build.hxml', source: BUILD }
		]);
		final works: Bool = CompilerOracle.typecheck('build.hxml', probe).match(Confirmed);
		CliFixture.removeDir(probe);
		if (works) return dir;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return null;
	}

	/** The one configuration of `dir`, as a lint run prepares it: carrying a fresh memo. */
	private static function remembering(dir: String): Array<OracleConfig> {
		return OracleRunMemo.attach([{ hxml: 'build.hxml', dir: dir, defines: [] }], new OracleRunMemo(false, () -> ['$dir/Main.hx']));
	}
	#end

}
