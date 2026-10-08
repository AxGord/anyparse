package unit.cli;

import unit.check.ProcessProbe;
import utest.Assert;
import utest.Test;

/**
 * No `haxe --wait` server a `lint --fix` run starts outlives the run, however the run is ended: SIGTERM of `apq`, SIGKILL
 * of `apq`, or SIGKILL of the whole process group `apq` leads — what a timed-out or stopped agent's shell does. Two kinds
 * of server, two fixtures: the run's warm pool (`OracleServerPool`, a `--fix` run given every rule) and the display
 * server of the oracle-assisted pass (`CompilerDisplayOracle`, started only when the run has no compiler facts — the
 * fixture's macro fails the facts compile on `NO_FACTS=1`).
 *
 * Found leaking on a shared machine: twelve servers with ppid 1, ~2.7 GB each, up to two hours old. Before the tether
 * a group kill left the pool's servers (their own process groups survive it, and so did they) and a SIGTERM or SIGKILL
 * of `apq` left the display server, a direct child no handler was left to reap.
 *
 * Every compile of the fixture sleeps, so a run lives long enough for its servers to be seen and killed mid-run.
 */
@:nullSafety(Strict)
class ApqOracleServerLifetimeCliTest extends Test {

	/** Seconds a run is given to start its first server. */
	private static inline final START_S: Float = 90;

	/** Milliseconds the servers are given to end once the run was killed. */
	private static inline final GONE_MS: Int = 5000;

	#if nodejs
	private static final MAIN: String =
		'class Main {\n\tstatic function main() {\n\t\tvar a = [1, 2].map(x -> x + 1);\n\t\ttrace(a);\n\t}\n}\n';

	/** Every compile sleeps a second; the facts compile (it alone defines `keep-inline-positions`) fails on `NO_FACTS`. */
	private static final SLOW: String = 'class Slow {\n\tpublic static function run():Void {\n'
		+ '\t\tif (haxe.macro.Context.defined("keep-inline-positions") && Sys.getEnv("NO_FACTS") == "1")\n'
		+ '\t\t\thaxe.macro.Context.fatalError("no facts here", haxe.macro.Context.currentPos());\n' + '\t\tSys.sleep(1);\n\t}\n}\n';
	#end

	public function testThePoolDiesWithASigtermedRun(): Void {
		assertNoSurvivor(Pool, 'SIGTERM', false);
	}

	public function testThePoolDiesWithASigkilledRun(): Void {
		assertNoSurvivor(Pool, 'SIGKILL', false);
	}

	/** The leak that was found: the batch driver shares `apq`'s group and dies with it, the servers' groups do not. */
	public function testThePoolDiesWithASigkilledProcessGroup(): Void {
		assertNoSurvivor(Pool, 'SIGKILL', true);
	}

	/** The display server was a direct child of `apq`: a SIGTERM ends `apq` with no exit handler run. */
	public function testTheDisplayServerDiesWithASigtermedRun(): Void {
		assertNoSurvivor(Display, 'SIGTERM', false);
	}

	public function testTheDisplayServerDiesWithASigkilledRun(): Void {
		assertNoSurvivor(Display, 'SIGKILL', false);
	}

	/**
	 * Start `apq lint --fix` on a fresh fixture for `server`, wait for its first `haxe --wait`, send `signal` to `apq` —
	 * or to its whole process group when `group` — and assert every server the run had started ends.
	 */
	private static function assertNoSurvivor(server: ServerKind, signal: String, group: Bool): Void {
		#if nodejs
		final engine: Null<String> = CliFixture.engineOrSkip();
		if (engine == null) return;
		final dir: String = CliFixture.writeDir('serverlifetime', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'Slow.hx', source: SLOW },
			{ name: 'build.hxml', source: '-cp .\n-main Main\n--js out.js\n--macro Slow.run()\n' },
			{ name: 'apqlint.json', source: '{"compilerOracle": "build.hxml", "rules": {"explicit-local-type": {"enabled": true}}}' }
		]);
		final rules: Array<String> = server == Display ? ['--rule', 'explicit-local-type'] : [];
		final args: Array<String> = [sys.FileSystem.absolutePath(engine), 'lint', '--lang', 'haxe', '--fix'].concat(rules)
			.concat(['Main.hx']);
		final env: haxe.DynamicAccess<String> = js.Syntax.code('Object.assign({}, process.env)');
		if (server == Display) env['NO_FACTS'] = '1';
		final run: Dynamic = js.node.ChildProcess.spawn(js.Node.process.execPath, args, {
			cwd: dir,
			stdio: 'ignore',
			detached: true,
			env: env
		});
		final pid: Int = run.pid;
		final until: Float = Sys.time() + START_S;
		var servers: Array<Int> = [];
		while (servers.length == 0 && Sys.time() < until && ProcessProbe.alive(pid)) {
			Sys.sleep(0.1);
			servers = ProcessProbe.descendantsRunning(pid, 'haxe --wait');
		}
		Assert.isTrue(servers.length > 0, 'the run started a server before it ended');
		try js.Node.process.kill(group ? -pid : pid, signal) catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// the run already ended: the servers are asked about all the same
		}
		final left: Array<Int> = ProcessProbe.awaitGone(servers, GONE_MS);
		Assert.equals(0, left.length, 'a server outlived its run (${group ? 'group ' : ''}$signal): $left');
		ProcessProbe.killAll(left);
		ProcessProbe.killAll([pid]);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('not a node target');
		#end
	}

}

/** Which server the fixture's run is made to start. */
private enum abstract ServerKind(Int) {

	/** The run's warm pool: a `--fix` run given every rule, with compiler facts. */
	var Pool;

	/** The display server: the oracle-assisted pass of a run without compiler facts. */
	var Display;

}
