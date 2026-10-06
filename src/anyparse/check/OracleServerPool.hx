package anyparse.check;

import anyparse.check.CompilerServer.ConnectResult;
import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.HaxeSpawn.SpawnJob;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.core.EnvFlag;
import anyparse.core.PhaseTimings;

using Lambda;

/**
 * One configuration's server in the pool: the port it listens on, and the text every path the run may write had when
 * the last compile through it started (`null` for a path that could not be read).
 */
typedef PoolServer = {
	var port: Int;
	var seen: Map<String, Null<String>>;
}

/**
 * The run's own `haxe --wait` servers, one per configuration, for the plain typechecks a `--fix` run repeats over trees
 * that differ by a file or two: the risky fix's covering compile, its bisect probes, the oracle-assisted batch.
 *
 * Started once the facts compiles are in (`LintCommand`), when the cores those took are free again: each server's first
 * compile runs in the background then, so the first typecheck through it is already warm. They live as the jobs of a
 * background process batch (`PendingRuns`), so the batch's driver ends them when the run ends (`stop`) and when `apq`
 * itself is gone. Never kept past the run: `CompilerServer` is the persistent kind, for report mode.
 *
 * ## A warm answer is believed only when it is GREEN
 *
 * A server can answer a stale null-safety diagnostic for a module it restored from its cache, and even a module it types
 * afresh is typed against cached ones (`CompilerServer`'s class doc), so a warm rejection is never a verdict: the caller
 * compiles every configuration that did not answer green cold, in the configurations' order (`CompilerOracle`). A warm
 * acceptance is believed because every path the run may write and whose text moved since the server's last compile is
 * `server/invalidate`d before the compile — by CONTENT, never by modification time, which the server compares in whole
 * seconds while a `--fix` run writes and verifies inside one.
 *
 * Declined with the report-mode warm path by `APQ_NO_ORACLE_SERVER`, and on a machine whose compile budget
 * (`HaxeSpawn.parallelism`) cannot hold one server per configuration at once.
 */
@:nullSafety(Strict)
final class OracleServerPool {

	/** Output a server or a compile through it may write before the driver ends it: a compile's errors, as `CompilerOracle`. */
	private static inline final BUFFER: Int = 256 * 1024 * 1024;

	/** How many `server/invalidate` rounds a server is given to come up before it is given up on. */
	private static inline final READY_ATTEMPTS: Int = 40;

	/** Random server ports: `[PORT_BASE, PORT_BASE + PORT_SPAN)`. */
	private static inline final PORT_BASE: Int = 20000;

	private static inline final PORT_SPAN: Int = 40000;

	private final _servers: Map<String, PoolServer> = [];

	/** Every path the run may write, read afresh at each compile (`OracleRunMemo`'s list). */
	private final _written: () -> Array<String>;

	/** The batch whose jobs ARE the servers, ended by `stop`. */
	private var _batch: Null<PendingRuns> = null;

	/** Each server's first compile, run in the background from `start`. */
	private var _warming: Null<PendingRuns> = null;

	public function new(written: () -> Array<String>) {
		_written = written;
	}

	/**
	 * Start one server per available configuration of `oracles` and its first compile in the background. A no-op once
	 * started, under `APQ_NO_ORACLE_SERVER`, or when the machine's compile budget cannot hold them all.
	 */
	public function start(oracles: Array<OracleConfig>): Void {
		PhaseTimings.time('oracle servers start', () -> startTimed(oracles));
	}

	/** `start`, untimed. */
	private function startTimed(oracles: Array<OracleConfig>): Void {
		#if nodejs
		if (_batch != null || EnvFlag.isSet('APQ_NO_ORACLE_SERVER')) return;
		final usable: Array<OracleConfig> = [];
		for (o in oracles) if (o.unavailable == null && !usable.exists(u -> keyOf(u) == keyOf(o))) usable.push(o);
		if (usable.length == 0 || HaxeSpawn.parallelism() < usable.length) return;
		final ports: Array<Int> = [];
		while (ports.length < usable.length) {
			final port: Int = PORT_BASE + Std.random(PORT_SPAN);
			if (!ports.contains(port)) ports.push(port);
		}
		_batch = HaxeSpawn.startAll([
			for (i in 0...usable.length) { args: ['--wait', '${ports[i]}'], cwd: usable[i].dir }
		], BUFFER, usable.length);
		final snapshot: Map<String, Null<String>> = texts();
		final warm: Array<SpawnJob> = [];
		for (i in 0...usable.length) if (ready(ports[i], usable[i])) {
			_servers[keyOf(usable[i])] = { port: ports[i], seen: snapshot };
			warm.push({ args: compileArgs(ports[i], usable[i]), cwd: usable[i].dir });
		}
		_warming = HaxeSpawn.startAll(warm, BUFFER, HaxeSpawn.parallelism());
		#end
	}

	/**
	 * Each of `oracles` typechecked through its server, in order — null for one that has none, whose server stopped
	 * answering, or whose compile could not be told from a refused connection. Every path the run may write whose text
	 * moved since the server's last compile is invalidated first. The compiles overlap; none stops another.
	 */
	public function compile(oracles: Array<OracleConfig>): Array<Null<HaxeRun>> {
		return PhaseTimings.measure('oracle warm compile', () -> compileTimed(oracles));
	}

	/** `compile`, untimed. */
	private function compileTimed(oracles: Array<OracleConfig>): Array<Null<HaxeRun>> {
		final out: Array<Null<HaxeRun>> = [for (_ in oracles) null];
		#if nodejs
		if (!_servers.keys().hasNext()) return out;
		_warming?.await();
		final now: Map<String, Null<String>> = texts();
		final asked: Array<Int> = [for (i in 0...oracles.length) if (_servers.exists(keyOf(oracles[i]))) i];
		final invalidations: Array<{ index: Int, job: SpawnJob }> = [];
		for (i in asked) {
			final oracle: OracleConfig = oracles[i];
			final server: Null<PoolServer> = _servers[keyOf(oracle)];
			if (server != null) for (path in moved(server.seen, now)) invalidations.push({
				index: i,
				job: {
					args: CompilerServer.connectArgs(
						server.port, oracle.hxml,
						['--display', CompilerServer.invalidateRequest(path)],
						oracle.defines
					),
					cwd: oracle.dir
				}
			});
		}
		final replies: Array<HaxeRun> = HaxeSpawn.runAll([for (v in invalidations) v.job], BUFFER, HaxeSpawn.parallelism());
		final unheard: Array<Int> = [];
		for (k in 0...invalidations.length) if (!CompilerServer.isServerReply(replies[k].out + replies[k].err)) {
			final i: Int = invalidations[k].index;
			if (!unheard.contains(i)) unheard.push(i);
		}
		// a server that did not take every invalidation may hold a text that is gone: it answers nothing from here on
		for (i in unheard) _servers.remove(keyOf(oracles[i]));
		final compiled: Array<Int> = [for (i in asked) if (!unheard.contains(i)) i];
		final runs: Array<HaxeRun> = HaxeSpawn.runAll([
			for (i in compiled) {
				final server: Null<PoolServer> = _servers[keyOf(oracles[i])];
				{ args: server == null ? [] : compileArgs(server.port, oracles[i]), cwd: oracles[i].dir };
			}
		], BUFFER, HaxeSpawn.parallelism());
		for (k in 0...compiled.length) {
			final i: Int = compiled[k];
			final server: Null<PoolServer> = _servers[keyOf(oracles[i])];
			if (server != null) server.seen = now;
			final run: HaxeRun = runs[k];
			if (refused(run))
				_servers.remove(keyOf(oracles[i]))
			else
				out[i] = run;
		}
		#end
		return out;
	}

	/** Whether any server of the pool answers compiles. */
	public function running(): Bool {
		return _servers.keys().hasNext();
	}

	/** End every server and any compile still warming one. */
	public function stop(): Void {
		_warming?.cancel();
		_batch?.cancel();
		_servers.clear();
	}

	/** The text of every path the run may write, read now; null for one that cannot be read (a deleted file). */
	private function texts(): Map<String, Null<String>> {
		final out: Map<String, Null<String>> = [];
		for (path in _written()) if (!out.exists(path)) out[path] = try sys.io.File.getContent(path) catch (exception: haxe.Exception) null;
		return out;
	}

	/** The paths whose text in `now` is not the one in `seen` — a path in only one of them included. */
	private static function moved(seen: Map<String, Null<String>>, now: Map<String, Null<String>>): Array<String> {
		final out: Array<String> = [for (path => text in now) if (!seen.exists(path) || seen[path] != text) path];
		for (path in seen.keys()) if (!now.exists(path)) out.push(path);
		return out;
	}

	/** Whether the server on `port` answers a display request yet, given a bounded number of tries. */
	private static function ready(port: Int, oracle: OracleConfig): Bool {
		#if nodejs
		for (_ in 0...READY_ATTEMPTS) {
			final reply: Null<ConnectResult> = CompilerServer.connect(
				port, oracle.hxml, oracle.dir,
				['--display', CompilerServer.invalidateRequest(oracle.hxml)],
				oracle.defines
			);
			if (reply == null) return false;
			if (CompilerServer.isServerReply(reply.output)) return true;
			js.node.ChildProcess.spawnSync('sleep', ['0.1']);
		}
		#end
		return false;
	}

	/** The client arguments of a typecheck of `oracle` through the server on `port`. */
	private static function compileArgs(port: Int, oracle: OracleConfig): Array<String> {
		return CompilerServer.connectArgs(port, oracle.hxml, ['--no-output'], oracle.defines);
	}

	/** Whether `run` never reached a server: the client's own refusal, which is no verdict. */
	private static function refused(run: HaxeRun): Bool {
		final text: String = run.out + run.err;
		return run.status == null || text.indexOf('Couldn\'t connect') != -1 || text.indexOf('Could not connect') != -1;
	}

	private static inline function keyOf(oracle: OracleConfig): String {
		return OracleDeclaration.oracleKey(oracle);
	}

}
