package unit.check.oracle;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.facts.TypedFactsProbe;
import anyparse.check.oracle.CompilerOracle;
import anyparse.check.oracle.OracleCoverage;
import anyparse.check.oracle.OracleRunMemo;
import anyparse.check.oracle.OracleServerPool;
import anyparse.proc.ProcessSpawn;
import anyparse.query.LintFixSafePass;
import anyparse.query.OracleProvider.OracleBaseline;
import anyparse.query.OracleProvider.OracleOutcome;
import anyparse.query.cli.command.LintFixDriver;
import anyparse.query.cli.command.LintFixSafeTrail;

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

	private static final USES_OTHER: String = 'class Main {\n\tstatic function main() {\n\t\ttrace(Other.v);\n\t}\n}\n';
	private static final OTHER_GOOD: String = 'class Other {\n\tpublic static final v: Int = 1;\n}\n';
	private static final OTHER_BAD: String = 'class Other {\n\tpublic static final v: Int = nope();\n}\n';

	#if (sys || nodejs)
	private static final GOOD: String = 'class Main {\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n}\n';
	private static final OTHER: String = 'class Main {\n\tstatic function main() {\n\t\ttrace(2);\n\t}\n}\n';
	private static final BAD: String = 'class Main {\n\tstatic function main() {\n\t\tnope();\n\t}\n}\n';
	private static final MUTATOR: String = 'class Mutator {\n\tpublic static function once():Void {\n'
		+ '\t\tif (sys.FileSystem.exists(\'mutated.flag\')) return;\n\t\tsys.io.File.saveContent(\'mutated.flag\', \'\');\n'
		+ '\t\tsys.io.File.saveContent(\'Main.hx\', \'class Main { static function main() { nope(); } }\\n\');\n\t}\n}\n';
	private static final BUILD: String = '-cp .\n-main Main\n--js out.js\n${CompileCounter.MACRO}';
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
			[{ file: main, source: OTHER }],
			[main],
			[main => GOOD], [], pre, new HaxeQueryPlugin(), oracles, [], new LintFixSafeTrail((_, _, _) -> null, LintFixSafePass.PROBE_CAP)
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
	@:access(anyparse.check.oracle.OracleServerPool)
	@:access(anyparse.proc.PendingRuns)
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
		final driver: Null<Int> = pool == null ? null : [for (batch in pool._batches) batch._pid][0];
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
	 * A run whose compile budget is smaller than its configurations still gets a warm server for each of them: a server
	 * waits between compiles, so the machine's memory bounds how many start, not the compiles that may run at once.
	 */
	@:pin('control')
	@:killer('M-POOL-SERVERS-NEED-PARALLELISM')
	@:access(anyparse.check.oracle.OracleServerPool)
	public function testEveryConfigurationGetsAServerBeyondTheCompileBudget(): Void {
		#if nodejs
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		sys.io.File.saveContent('$dir/other.hxml', BUILD);
		final oracles: Array<OracleConfig> = OracleRunMemo.attach([
			{ hxml: 'build.hxml', dir: dir, defines: [] },
			{ hxml: 'other.hxml', dir: dir, defines: [] }
		], new OracleRunMemo(false, () -> ['$dir/Main.hx']));
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		final declared: Null<String> = Sys.getEnv('APQ_ORACLE_PARALLEL');
		CliFixture.always(() -> Sys.putEnv('APQ_ORACLE_PARALLEL', declared ?? ''), () -> {
			Sys.putEnv('APQ_ORACLE_PARALLEL', '1');
			pool?.start(oracles);
		});
		final servers: Int = pool == null ? 0 : [for (_ in pool._servers) 1].length;
		Assert.equals(
			Std.int(Math.min(2, ProcessSpawn.resident())), servers, 'a compile budget of one started no server for two configurations'
		);
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
	@:access(anyparse.check.oracle.OracleServerPool)
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
	 * A server whose tree moved by more paths than invalidating them is worth is replaced by a fresh one, which compiles the
	 * tree as it is now — staged with a rewrite inside the second the first server compiled, which no modification time
	 * tells — and the server it replaced is ended.
	 */
	@:pin('control')
	@:killer('M-POOL-NEVER-RESTARTS')
	@:access(anyparse.check.oracle.OracleServerPool)
	@:access(unit.check.ProcessProbe)
	public function testADriftedServerIsReplacedByAFreshOne(): Void {
		#if nodejs
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final main: String = '$dir/Main.hx';
		final save: (String, String) -> Void = sys.io.File.saveContent;
		final pads: Array<String> = [for (k in 0...OracleServerPool.RESTART_AT + 1) '$dir/pad$k.hx'];
		for (pad in pads) save(pad, 'a');
		final oracles: Array<OracleConfig> = OracleRunMemo.attach(
			[{ hxml: 'build.hxml', dir: dir, defines: [] }], new OracleRunMemo(false, () -> [main].concat(pads))
		);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		pool?.start(oracles);
		Assert.equals(0, pool?.compile(oracles)[0]?.status, 'the first server compiles the first text');
		final first: Array<Int> = pool == null ? [] : [for (server in pool._servers) server.port];
		final replaced: Array<Int> = [
			for (port in first) for (pid in ProcessProbe.pidsRunning('haxe --wait $port')) pid
		];
		for (pad in pads) save(pad, 'b');
		final stamp: Date = js.node.Fs.statSync(main).mtime;
		save(main, BAD);
		js.node.Fs.utimesSync(main, stamp, stamp);
		final status: Null<Int> = pool?.compile(oracles)[0]?.status;
		Assert.isTrue(status != null && status != 0, 'the drifted configuration did not answer the text it holds now');
		final second: Array<Int> = pool == null ? [] : [for (server in pool._servers) server.port];
		Assert.equals(1, second.length, 'the drifted configuration keeps a server');
		Assert.equals(
			0, second.filter(port -> first.contains(port)).length, 'the drifted server was invalidated path by path, not replaced'
		);
		Assert.equals(0, ProcessProbe.awaitGone(replaced, ProcessProbe.GONE_MS).length, 'the replaced server still runs');
		pool?.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	/**
	 * A server the pool gives up on is ended alone: each server is the one job of its own batch, so the server of the other
	 * configuration keeps running and still answers its compiles.
	 */
	@:pin('control')
	@:killer('M-POOL-END-CANCELS-ALL')
	@:access(anyparse.check.oracle.OracleServerPool)
	@:access(unit.check.ProcessProbe)
	public function testEndingOneServerLeavesTheOthersRunning(): Void {
		#if nodejs
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		sys.io.File.saveContent('$dir/other.hxml', BUILD);
		final oracles: Array<OracleConfig> = OracleRunMemo.attach([
			{ hxml: 'build.hxml', dir: dir, defines: [] },
			{ hxml: 'other.hxml', dir: dir, defines: [] }
		], new OracleRunMemo(false, () -> ['$dir/Main.hx']));
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		pool?.start(oracles);
		if (pool == null || ProcessSpawn.resident() < 2) {
			pool?.stop();
			CliFixture.removeDir(dir);
			Assert.pass('the machine holds one server only');
			return;
		}
		final ended: Null<Int> = pool._servers[OracleServerPool.keyOf(oracles[0])]?.port;
		final kept: Null<Int> = pool._servers[OracleServerPool.keyOf(oracles[1])]?.port;
		Assert.notNull(ended, 'the first configuration has a server');
		Assert.notNull(kept, 'the second configuration has a server');
		final endedPids: Array<Int> = ended == null ? [] : ProcessProbe.pidsRunning('haxe --wait $ended');
		final keptPids: Array<Int> = kept == null ? [] : ProcessProbe.pidsRunning('haxe --wait $kept');
		Assert.isTrue(endedPids.length > 0 && keptPids.length > 0, 'both servers run');
		pool.end(oracles[0]);
		Assert.equals(0, ProcessProbe.awaitGone(endedPids, ProcessProbe.GONE_MS).length, 'the ended server still runs');
		Assert.equals(keptPids.length, keptPids.filter(ProcessProbe.alive).length, 'ending one server ended the other too');
		Assert.equals(0, pool.compile([oracles[1]])[0]?.status, 'the kept server no longer answers its compiles');
		pool.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	/**
	 * A position request through a server whose tree drifted past what invalidating it is worth is answered by a fresh
	 * server, as a compile is: the drifted one is ended.
	 */
	@:pin('control')
	@:killer('M-POOL-POSITION-NEVER-RENEWS')
	@:access(anyparse.check.oracle.OracleServerPool)
	@:access(unit.check.ProcessProbe)
	public function testAPositionRequestReplacesADriftedServer(): Void {
		#if nodejs
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final main: String = '$dir/Main.hx';
		final save: (String, String) -> Void = sys.io.File.saveContent;
		final pads: Array<String> = [for (k in 0...OracleServerPool.RESTART_AT + 1) '$dir/pad$k.hx'];
		for (pad in pads) save(pad, 'a');
		final oracles: Array<OracleConfig> = OracleRunMemo.attach(
			[{ hxml: 'build.hxml', dir: dir, defines: [] }], new OracleRunMemo(false, () -> [main].concat(pads))
		);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		pool?.start(oracles);
		Assert.equals(0, pool?.compile(oracles)[0]?.status, 'the first server compiles the first text');
		final first: Array<Int> = pool == null ? [] : [for (server in pool._servers) server.port];
		final replaced: Array<Int> = [
			for (port in first) for (pid in ProcessProbe.pidsRunning('haxe --wait $port')) pid
		];
		for (pad in pads) save(pad, 'b');
		pool?.positionIn(oracles[0], main, GOOD, GOOD.indexOf('trace'));
		final second: Array<Int> = pool == null ? [] : [for (server in pool._servers) server.port];
		Assert.equals(1, second.length, 'the drifted configuration keeps a server');
		Assert.equals(
			0, second.filter(port -> first.contains(port)).length, 'the drifted server was invalidated path by path, not replaced'
		);
		Assert.equals(0, ProcessProbe.awaitGone(replaced, ProcessProbe.GONE_MS).length, 'the replaced server still runs');
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

	/**
	 * The module a position request dropped from the server's record is read again by the next compile, which invalidates it
	 * on the server it has: the compile after a position round does not replace the server.
	 */
	@:pin('control')
	@:killer('M-POOL-REREAD-COUNTS-AS-APPEARED')
	@:access(anyparse.check.oracle.OracleServerPool)
	@:access(unit.check.ProcessProbe)
	public function testACompileAfterAPositionRoundKeepsTheServer(): Void {
		#if nodejs
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final main: String = '$dir/Main.hx';
		final oracles: Array<OracleConfig> = OracleRunMemo.attach(
			[{ hxml: 'build.hxml', dir: dir, defines: [] }], new OracleRunMemo(false, () -> [main])
		);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		pool?.start(oracles);
		Assert.equals(0, pool?.compile(oracles)[0]?.status, 'the first compile is green');
		final first: Array<Int> = pool == null ? [] : [for (server in pool._servers) server.port];
		final running: Array<Int> = [
			for (port in first) for (pid in ProcessProbe.pidsRunning('haxe --wait $port')) pid
		];
		Assert.equals(1, first.length, 'a server came up');
		pool?.positionIn(oracles[0], main, GOOD, GOOD.indexOf('trace'));
		Assert.equals(0, pool?.compile(oracles)[0]?.status, 'the compile after the position round is green');
		final second: Array<Int> = pool == null ? [] : [for (server in pool._servers) server.port];
		Assert.same(first, second, 'the module the position round dropped is invalidated, not a reason to replace the server');
		Assert.isTrue(
			running.length > 0 && running.filter(ProcessProbe.alive).length == running.length, 'the first server is still running'
		);
		pool?.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	/**
	 * A configuration whose warm compile was red only in a file the run cannot write is compiled cold from then on: a server
	 * that holds a stale view of the rest of the project repeats the same red, so every later check would pay warm and then cold.
	 */
	@:pin('control')
	@:killer('M-POOL-KEEPS-WARM-AFTER-RED-OUTSIDE')
	public function testARedOutsideTheWriteSetEndsTheWarmCompiles(): Void {
		#if nodejs
		final dir: Null<String> = scratch(USES_OTHER, BUILD);
		if (dir == null) return;
		final other: String = '$dir/Other.hx';
		rewrite(other, OTHER_GOOD, null);
		final stamp: Float = js.node.Fs.statSync(other).mtime.getTime();
		final oracles: Array<OracleConfig> = remembering(dir);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		pool?.start(oracles);
		Assert.equals(0, pool?.compile(oracles)[0]?.status, 'the first warm compile is green');
		rewrite(other, OTHER_BAD, Date.fromTime(stamp + 10000));
		final red: Null<Int> = pool?.compile(oracles)[0]?.status;
		Assert.isTrue(red != null && red != 0, 'the warm compile reads the file outside the write set and is red');
		rewrite(other, OTHER_GOOD, Date.fromTime(stamp + 20000));
		Assert.isNull(pool?.compile(oracles)[0], 'a configuration red only outside the write set is not asked warm again');
		Assert.isTrue(CompilerOracle.typecheckAll(oracles).match(Confirmed), 'the cold compile answers the mended tree');
		pool?.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	/** A warm compile red in a file the run writes does not end the warm compiles: the mended text is typechecked warm again. */
	@:pin('control')
	@:killer('M-POOL-SKIPS-WARM-AFTER-ANY-RED')
	public function testARedInsideTheWriteSetKeepsTheWarmCompiles(): Void {
		#if nodejs
		final dir: Null<String> = scratch(GOOD, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		pool?.start(oracles);
		Assert.equals(0, pool?.compile(oracles)[0]?.status, 'the first warm compile is green');
		final main: String = '$dir/Main.hx';
		final stamp: Date = js.node.Fs.statSync(main).mtime;
		rewrite(main, BAD, stamp);
		final red: Null<Int> = pool?.compile(oracles)[0]?.status;
		Assert.isTrue(red != null && red != 0, 'the warm compile of the rejected text is red');
		rewrite(main, GOOD, stamp);
		Assert.equals(0, pool?.compile(oracles)[0]?.status, 'the mended text is typechecked warm again');
		pool?.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	/**
	 * A skipped configuration is not replaced by a fresh server for the drift of the tree it no longer compiles: its text
	 * moving past `RESTART_AT` paths leaves the server it has.
	 */
	@:pin('control')
	@:killer('M-POOL-RENEWS-SKIPPED')
	@:access(anyparse.check.oracle.OracleServerPool)
	public function testASkippedConfigurationIsNotRenewed(): Void {
		#if nodejs
		final dir: Null<String> = scratch(USES_OTHER, BUILD);
		if (dir == null) return;
		final main: String = '$dir/Main.hx';
		final pads: Array<String> = [for (k in 0...OracleServerPool.RESTART_AT + 1) '$dir/pad$k.hx'];
		for (pad in pads) rewrite(pad, 'a', null);
		final oracles: Array<OracleConfig> = OracleRunMemo.attach(
			[{ hxml: 'build.hxml', dir: dir, defines: [] }], new OracleRunMemo(false, () -> [main].concat(pads))
		);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		if (pool != null) skipAfterRedOutside(dir, oracles, pool);
		final before: Array<Int> = pool == null ? [] : [for (server in pool._servers) server.port];
		for (pad in pads) rewrite(pad, 'b', null);
		Assert.isNull(pool?.compile(oracles)[0], 'a skipped configuration is not compiled warm');
		Assert.same(before, pool == null ? [] : [for (server in pool._servers) server.port], 'the skipped server was replaced');
		Assert.equals(1, before.length, 'the skipped configuration keeps a server');
		pool?.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	/** A skipped configuration still answers position queries: skipping its warm compiles does not end its server. */
	@:pin('control')
	@:killer('M-POOL-SKIP-ENDS-SERVER')
	public function testASkippedConfigurationStillAnswersPositions(): Void {
		#if nodejs
		final dir: Null<String> = scratch(USES_OTHER, BUILD);
		if (dir == null) return;
		final oracles: Array<OracleConfig> = remembering(dir);
		final pool: Null<OracleServerPool> = OracleRunMemo.of(oracles)?.servers;
		if (pool != null) skipAfterRedOutside(dir, oracles, pool);
		Assert.isNull(pool?.compile(oracles)[0], 'the configuration is skipped');
		Assert.notNull(
			pool?.positionIn(oracles[0], '$dir/Main.hx', USES_OTHER, USES_OTHER.indexOf('Other')),
			'the skipped configuration answered no position'
		);
		pool?.stop();
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

	private static function errorsOf(outcome: OracleOutcome): String {
		return switch outcome {
			case Rejected(errors): errors;
			case _: '';
		};
	}

	/** `path` rewritten with `text` and, when `mtime` is given, stamped with it: the server compares modification times. */
	private static function rewrite(path: String, text: String, mtime: Null<Date>): Void {
		sys.io.File.saveContent(path, text);
		if (mtime != null) js.node.Fs.utimesSync(path, mtime, mtime);
	}

	/**
	 * Brings `pool` up over `dir`, compiles green, breaks the file outside the write set so the warm compile is red there, and
	 * mends it: the configuration is skipped from then on.
	 */
	private static function skipAfterRedOutside(dir: String, oracles: Array<OracleConfig>, pool: OracleServerPool): Void {
		final other: String = '$dir/Other.hx';
		rewrite(other, OTHER_GOOD, null);
		final stamp: Float = js.node.Fs.statSync(other).mtime.getTime();
		pool.start(oracles);
		Assert.equals(0, pool.compile(oracles)[0]?.status, 'the first warm compile is green');
		rewrite(other, OTHER_BAD, Date.fromTime(stamp + 10000));
		final red: Null<Int> = pool.compile(oracles)[0]?.status;
		Assert.isTrue(red != null && red != 0, 'the warm compile reads the file outside the write set and is red');
		rewrite(other, OTHER_GOOD, Date.fromTime(stamp + 20000));
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
