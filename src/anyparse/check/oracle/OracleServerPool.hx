package anyparse.check.oracle;

import anyparse.check.oracle.CompilerDisplayOracle;
import anyparse.check.oracle.CompilerServer.ConnectResult;
import anyparse.check.oracle.HaxeSpawn.SpawnJob;
import anyparse.core.EnvFlag;
import anyparse.core.PhaseTimings;

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
 * that differ by a file or two: the risky fix's covering compile, its bisect probes, the oracle-assisted batch. The one
 * answer to "which warm compiler server typechecks for this run".
 *
 * Started once the facts compiles are in (`LintCommand`), when the cores those took are free again: each server's first
 * compile runs in the background then, so the first typecheck through it is already warm. Each lives as the one job of
 * its own background process batch (`PendingRuns`), so its driver ends it when the run ends (`stop`), when the pool
 * gives it up (`end`) and when `apq` itself is gone — and each is TETHERED to that driver (`SpawnJob.tethered`), so a
 * kill that takes the driver down with `apq` (a SIGKILL of their whole process group: a timed-out or stopped agent's
 * shell) takes the servers too, where it used to leave each one holding a whole compiled project with no owner. Never
 * kept past the run: `CompilerServer` is the persistent kind, for report mode.
 *
 * ## A warm answer is believed only when it is GREEN
 *
 * A server can answer a stale null-safety diagnostic for a module it restored from its cache, and even a module it types
 * afresh is typed against cached ones (`CompilerServer`'s class doc), so a warm rejection is never a verdict: the caller
 * compiles every configuration that did not answer green cold, in the configurations' order (`CompilerOracle`). A warm
 * acceptance is believed because every path the run may write and whose text moved since the server's last compile is
 * `server/invalidate`d before the compile — by CONTENT, never by modification time, which the server compares in whole
 * seconds while a `--fix` run writes and verifies inside one. A server whose tree moved by more paths than invalidating
 * them is worth is replaced by a fresh one instead (`renew`), which holds nothing to invalidate.
 *
 * Declined with the report-mode warm path by `APQ_NO_ORACLE_SERVER`. A server holds its compiled project while it waits,
 * so the machine's memory (`HaxeSpawn.resident`) bounds how many start, the first configurations first; the compile
 * budget (`HaxeSpawn.parallelism`) bounds only how many of them compile at once.
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

	/**
	 * How many moved paths a server is invalidated for before it is replaced by a fresh one instead (`renew`): the server
	 * answers invalidations one at a time, each a walk of everything it holds, so past this many a fresh server's first
	 * compile costs less than bringing the old one up to date.
	 */
	private static inline final RESTART_AT: Int = 32;

	private final _servers: Map<String, PoolServer> = [];

	/** Each server's own batch, its one job the server, by configuration: ended by `stop`, or alone by `end`. */
	private final _batches: Map<String, PendingRuns> = [];

	/** Every path the run may write, read afresh at each compile (`OracleRunMemo`'s list). */
	private final _written: () -> Array<String>;

	/** Whether `start` started the servers: the pool starts once per run. */
	private var _started: Bool = false;

	/** Each server's first compile, run in the background from `start`. */
	private var _warming: Null<PendingRuns> = null;

	public function new(written: () -> Array<String>) {
		_written = written;
	}

	/**
	 * Start one server per available configuration of `oracles` and its first compile in the background. A no-op once
	 * started or under `APQ_NO_ORACLE_SERVER`; only as many as the machine's memory holds, the first ones first.
	 */
	public function start(oracles: Array<OracleConfig>): Void {
		PhaseTimings.time('oracle servers start', startTimed.bind(oracles));
	}

	/**
	 * Each of `oracles` typechecked through its server, in order — null for one that has none, whose server stopped
	 * answering, or whose compile could not be told from a refused connection. Every path the run may write whose text
	 * moved since the server's last compile is invalidated first. The compiles overlap; none stops another.
	 */
	public function compile(oracles: Array<OracleConfig>): Array<Null<HaxeRun>> {
		return PhaseTimings.measure('oracle warm compile', compileTimed.bind(oracles));
	}

	/**
	 * Where `oracle`'s server says the declaration of the name at offset `at` of `content` is written, `content` being read
	 * as the text of `file` in place of its bytes on disk (`CompilerDisplayOracle.positionOver`); null when the pool holds
	 * no server for it, a server did not take an invalidation, or the compiler names none. As before a compile, every path
	 * the run may write whose text moved is dropped first, and then `file` itself, whose cached module the server would
	 * answer from instead of `content`; `file` then counts as moved, so the next compile re-reads it.
	 */
	public function positionIn(oracle: OracleConfig, file: String, content: String, at: Int): Null<TypeReplyPosition> {
		#if nodejs
		if (!_servers.exists(keyOf(oracle))) return null;
		_warming?.await();
		final now: Map<String, Null<String>> = texts();
		renew(oracle, now);
		final server: Null<PoolServer> = _servers[keyOf(oracle)];
		if (server == null) return null;
		final replies: Array<HaxeRun> = HaxeSpawn.runAll([
			for (path in moved(server.seen, now).concat([file])) invalidation(server, oracle, path)
		], BUFFER, HaxeSpawn.parallelism());
		if (!replies.foreach(reply -> CompilerServer.isServerReply(reply.out + reply.err))) {
			end(oracle);
			return null;
		}
		server.seen = [for (path => text in now) if (path != file) path => text];
		return CompilerDisplayOracle.positionOver(server.port, oracle.hxml, oracle.dir, oracle.defines, file, content, at);
		#else
		return null;
		#end
	}

	/** Whether any server of the pool answers compiles. */
	public function running(): Bool {
		return _servers.keys().hasNext();
	}

	/** End every server and any compile still warming one. */
	public function stop(): Void {
		_warming?.cancel();
		for (batch in _batches) batch.cancel();
		_batches.clear();
		_servers.clear();
	}

	/** `start`, untimed. */
	private function startTimed(oracles: Array<OracleConfig>): Void {
		#if nodejs
		if (_started || EnvFlag.isSet('APQ_NO_ORACLE_SERVER')) return;
		final available: Array<OracleConfig> = [];
		for (o in oracles) if (o.unavailable == null && !available.exists(u -> keyOf(u) == keyOf(o))) available.push(o);
		final usable: Array<OracleConfig> = available.slice(0, HaxeSpawn.resident());
		if (usable.length == 0) return;
		_started = true;
		final ports: Array<Int> = [];
		for (o in usable) {
			final port: Int = freePort(ports);
			ports.push(port);
			_batches[keyOf(o)] = serve(port, o);
		}
		final snapshot: Map<String, Null<String>> = texts();
		final warm: Array<SpawnJob> = [];
		for (i => o in usable) if (ready(ports[i], o)) {
			_servers[keyOf(o)] = { port: ports[i], seen: snapshot };
			warm.push({ args: compileArgs(ports[i], o), cwd: o.dir });
		} else {
			end(o);
		}
		_warming = HaxeSpawn.startAll(warm, BUFFER, HaxeSpawn.parallelism());
		#end
	}

	/** `compile`, untimed. */
	private function compileTimed(oracles: Array<OracleConfig>): Array<Null<HaxeRun>> {
		final out: Array<Null<HaxeRun>> = [for (_ in oracles) null];
		#if nodejs
		if (!_servers.keys().hasNext()) return out;
		_warming?.await();
		final now: Map<String, Null<String>> = texts();
		for (oracle in oracles) renew(oracle, now);
		final asked: Array<Int> = [for (i in 0...oracles.length) if (_servers.exists(keyOf(oracles[i]))) i];
		final unheard: Array<Int> = invalidate(oracles, asked, now);
		// a server that did not take every invalidation may hold a text that is gone: it answers nothing from here on
		for (i in unheard) end(oracles[i]);
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
				end(oracles[i])
			else
				out[i] = run;
		}
		#end
		return out;
	}

	/** The text of every path the run may write, read now; null for one that cannot be read (a deleted file). */
	private function texts(): Map<String, Null<String>> {
		final out: Map<String, Null<String>> = [];
		for (path in _written()) if (!out.exists(path)) out[path] = try sys.io.File.getContent(path) catch (exception: haxe.Exception) null;
		return out;
	}

	/**
	 * Replace `oracle`'s server by a fresh one when more paths moved since its last compile than `RESTART_AT`. A fresh
	 * server holds no module yet, so it has nothing to invalidate: its first compile reads the tree as it is `now`.
	 */
	private function renew(oracle: OracleConfig, now: Map<String, Null<String>>): Void {
		final server: Null<PoolServer> = _servers[keyOf(oracle)];
		if (server == null || moved(server.seen, now).length <= RESTART_AT) return;
		PhaseTimings.time('oracle server restart', () -> {
			end(oracle);
			final port: Int = freePort([]);
			_batches[keyOf(oracle)] = serve(port, oracle);
			if (ready(port, oracle))
				_servers[keyOf(oracle)] = { port: port, seen: now }
			else
				end(oracle);
		});
	}

	/** End `oracle`'s server: it answers nothing from here on, and the compiled project it holds is freed. */
	private function end(oracle: OracleConfig): Void {
		_batches[keyOf(oracle)]?.cancel();
		_batches.remove(keyOf(oracle));
		_servers.remove(keyOf(oracle));
	}

	/** A random port neither in `taken` nor one a server of the pool listens on. */
	private function freePort(taken: Array<Int>): Int {
		final used: Array<Int> = taken.concat([for (server in _servers) server.port]);
		var port: Int = PORT_BASE + Std.random(PORT_SPAN);
		while (used.contains(port)) port = PORT_BASE + Std.random(PORT_SPAN);
		return port;
	}

	/**
	 * Every path whose text in `now` moved since the last compile through the server of each `oracles[i]`, `i` in `asked`,
	 * invalidated on that server; the indices whose server did not take every one of them.
	 */
	private function invalidate(oracles: Array<OracleConfig>, asked: Array<Int>, now: Map<String, Null<String>>): Array<Int> {
		final invalidations: Array<{ index: Int, job: SpawnJob }> = [];
		for (i in asked) {
			final oracle: OracleConfig = oracles[i];
			final server: Null<PoolServer> = _servers[keyOf(oracle)];
			if (server != null) for (path in moved(server.seen, now))
				invalidations.push({ index: i, job: invalidation(server, oracle, path) });
		}
		final replies: Array<HaxeRun> = HaxeSpawn.runAll([for (v in invalidations) v.job], BUFFER, HaxeSpawn.parallelism());
		final unheard: Array<Int> = [];
		for (k => asking in invalidations) if (
			!CompilerServer.isServerReply(replies[k].out + replies[k].err) && !unheard.contains(asking.index)
		)
			unheard.push(asking.index);
		return unheard;
	}

	private static inline function keyOf(oracle: OracleConfig): String {
		return OracleDeclaration.oracleKey(oracle);
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

	/** The `server/invalidate` request dropping `path` from `server`, the server of `oracle`. */
	private static function invalidation(server: PoolServer, oracle: OracleConfig, path: String): SpawnJob {
		return {
			args: CompilerServer.connectArgs(
				server.port, oracle.hxml,
				['--display', CompilerServer.invalidateRequest(path)],
				oracle.defines
			),
			cwd: oracle.dir
		};
	}

	/** Whether `run` never reached a server: the client's own refusal, which is no verdict. */
	private static function refused(run: HaxeRun): Bool {
		final text: String = run.out + run.err;
		return run.status == null || text.indexOf('Couldn\'t connect') != -1 || text.indexOf('Could not connect') != -1;
	}

	/** `oracle`'s server on `port`, started as the one job of its own batch, so it can be ended alone (`end`). */
	private static function serve(port: Int, oracle: OracleConfig): PendingRuns {
		return HaxeSpawn.startAll([{ args: ['--wait', '$port'], cwd: oracle.dir, tethered: true }], BUFFER, 1);
	}

}
