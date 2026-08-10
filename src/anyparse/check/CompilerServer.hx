package anyparse.check;

import anyparse.check.CompilerOracle.OracleOutcome;
import haxe.crypto.Md5;
import haxe.io.Path;

using StringTools;

/**
 * One `haxe --connect` round trip: the client's exit status (null when the spawn
 * produced none) and its combined stdout + stderr. The typed narrowing of the raw
 * spawn result, so no `Dynamic` crosses back out of the process boundary.
 */
typedef ConnectResult = {
	var status: Null<Int>;
	var output: String;
}

/**
 * What `apq` remembers about the warm server it started for one project: the port it
 * listens on, the pid of the `haxe --wait` process (the liveness probe), and the
 * wall-clock SECOND at which the last typecheck through it began — the watermark the
 * staleness rule is written against.
 */
typedef ServerState = {
	var port: Int;
	var pid: Int;
	var compiledAt: Int;
}

/**
 * A PERSISTENT Haxe compilation server shared by every `apq` process working on one
 * project — the warm path of the report-mode compiler oracle. `CompilerOracle` spawns a
 * fresh `haxe <hxml> --no-output` per lint run (14.6s on this project, measured); the
 * same typecheck through a server that already holds the compiled modules is 0.4s
 * when nothing changed underneath it, and the cost of recompiling what did otherwise.
 * The server is spawned DETACHED and deliberately outlives the process that started it —
 * that is the whole point, since a server warmed and killed inside one run would only
 * add cost. It is recorded in a state file under the OS temp dir keyed by the
 * (hxml, cwd) pair, and `stopShared` is its explicit teardown.
 *
 * Opt-in per project through the `apqlint.json` `compilerOracleServer` key, and
 * declinable process-wide with `APQ_NO_ORACLE_SERVER` — a daemon that outlives the run
 * is a bigger commitment than the typecheck the `compilerOracle` key asks for, so it is
 * never implied by that key alone.
 *
 * ## Every failure falls back, never guesses
 *
 * `typecheck` returns null for EVERY condition it cannot answer under — nothing
 * recorded, a dead pid, no free port, a server that never came up, an unreachable port,
 * a client that produced no status. The caller then runs the cold `CompilerOracle`, so
 * the warm path can only ever be faster, never a different verdict.
 *
 * ## Why the port is proved before it is believed (measured)
 *
 * An UNRELATED process listening on the port accepts `--connect`, and the compiler
 * client then exits 0 having compiled nothing — verified against an `nc` listener on a
 * project that does NOT typecheck. Trusting that exit status would silently disable the
 * whole gate. So before any verdict is believed the port must answer a
 * `server/invalidate` display request with a JSON-RPC reply (`isServerReply`), which
 * only a real compilation server produces.
 *
 * ## Why linted files are invalidated first (measured)
 *
 * The compilation server decides a module is stale by comparing modification times at
 * ONE-SECOND granularity, so a write landing in the same second as the compile that read
 * the file is invisible — and stays invisible for as long as the file is not written
 * again in a later second. This is not a one-second window: it FREEZES that module at
 * its previous content indefinitely. Measured on Haxe 4.3.7 with a write-then-connect
 * loop: 9 of 10 iterations gave a wrong verdict, including a broken build reported as
 * clean. Every linted path whose modification second is at or after the last compile is
 * therefore `server/invalidate`d first, which the same measurement shows fixes the
 * verdict with no wait at all. Past `MAX_INVALIDATIONS` files one fresh full compile
 * costs less than the round trips, so the recorded server is reaped and rebuilt instead.
 *
 * A file OUTSIDE the linted set, written in the same second as the last compile, stays a
 * residual: a report run never reads it, so nothing can know it changed. It costs one
 * run's oracle line and self-corrects as soon as that file is touched again in a later
 * second or the server is restarted.
 *
 * ## Never post-write verification
 *
 * The `--fix` risky-fix path (`FixVerifier`) writes files and then asks whether the
 * project still compiles — the exact question the granularity above cannot answer
 * honestly, since the write and the verify fall in the same second by construction. It
 * stays on the cold `CompilerOracle`, a new process reading current bytes every time.
 * The same reason `CompilerDisplayOracle` restricts its own server to read-only queries.
 *
 * ## A warm REJECTION is not believed on its own
 *
 * A compilation server can re-emit a stale null-safety diagnostic for a module it restored
 * from cache instead of recompiling. Measured on this project: ONE site (`StdResolver`
 * bridging a `sys` extern whose declared non-null `String` reads as nullable off the cache)
 * made every fully-cached recompile spuriously red while the cold compile was green. The
 * caller therefore re-runs a warm rejection COLD before reporting it
 * (`Cli.reportOracleVerdict`), so this class can only ever change what a verdict COSTS.
 *
 * ## Target
 *
 * Everything here is `#if nodejs` (the target `apq` ships on): `spawn` for the detached
 * server, `spawnSync` for each `--connect`. On any other target the warm path is simply
 * unavailable (null) and the cold oracle answers, so the class type-checks everywhere
 * while only the nodejs path runs.
 */
@:nullSafety(Strict)
final class CompilerServer {

	/** Total warm typechecks this process — the counter tests read to prove the no-key gate. */
	public static var invocations(default, null): Int = 0;

	/** Ephemeral-port search: try this many random high ports before giving up on a free one. */
	private static inline final MAX_PORT_ATTEMPTS: Int = 8;

	/** Random server port range: `[PORT_BASE, PORT_BASE + PORT_SPAN)`. */
	private static inline final PORT_BASE: Int = 20000;

	private static inline final PORT_SPAN: Int = 40000;

	/** Warm poll budget: `--connect` attempts (each ~0.3s apart) to let a freshly spawned server boot and finish its first full compile. */
	private static inline final MAX_WARM_ATTEMPTS: Int = 40;

	/**
	 * Stale-file budget: past this many possibly-stale linted files a fresh full compile
	 * costs less than a `server/invalidate` round trip each, so the recorded server is
	 * reaped and a new one started instead. Measured on this project: one round trip
	 * 0.10-0.12s against a 15.1s cold compile, so the break-even is around 128 files.
	 */
	private static inline final MAX_INVALIDATIONS: Int = 128;

	/** Milliseconds per second — the compilation server compares modification times in whole seconds. */
	private static inline final MS_PER_SECOND: Float = 1000;

	/**
	 * Typecheck `hxml` (compiled from `cwd`) through the project's shared warm server, or
	 * null when the warm path could not be used — the caller then falls back to
	 * `CompilerOracle.typecheck`, whose verdict a null here promises to be equivalent to.
	 * `paths` are the files the caller is linting: every one of them modified since the
	 * last compile through this server is invalidated first (see the class doc).
	 */
	public static function typecheck(hxml: String, cwd: Null<String>, paths: Array<String>): Null<OracleOutcome> {
		#if nodejs
		final ready: Null<ServerState> = reuse(hxml, cwd, paths) ?? startServer(hxml, cwd);
		if (ready == null) return null;
		invocations++;
		final startedAt: Int = nowSeconds();
		final res: Null<ConnectResult> = connect(ready.port, hxml, cwd, ['--no-output']);
		if (res == null || isConnectRefusal(res)) return null;
		// The watermark only moves for a compile that RAN to a status: a client killed
		// mid-compile leaves the server holding whatever it had read, which the next run
		// must still treat as possibly stale.
		final outcome: OracleOutcome = switch res.status {
			case null: return null;
			case 0: Confirmed;
			case _: Rejected(res.output.trim());
		};
		writeState(hxml, cwd, { port: ready.port, pid: ready.pid, compiledAt: startedAt });
		return outcome;
		#else
		return null;
		#end
	}

	/**
	 * Kill the server recorded for `hxml`/`cwd` and forget it — the explicit teardown for
	 * a caller that must not leave a daemon behind (a test fixture, a machine being
	 * cleaned up). A no-op when nothing is recorded.
	 */
	public static function stopShared(hxml: String, cwd: Null<String>): Void {
		#if nodejs
		final state: Null<ServerState> = readState(hxml, cwd);
		if (state != null && isOurServer(state.pid, state.port)) killPid(state.pid);
		final path: String = stateFile(hxml, cwd);
		if (sys.FileSystem.exists(path)) deleteState(path);
		#end
	}

	/**
	 * Where the shared server for `hxml` (compiled from `cwd`) is recorded — one file per
	 * project under the OS temp dir, keyed by a digest of the pair so two checkouts, or
	 * two build files in one checkout, never share a server. Public because it is also how
	 * a human finds the pid of a daemon to stop.
	 */
	public static function stateFile(hxml: String, cwd: Null<String>): String {
		#if nodejs
		final key: String = '${absolute(hxml)}|${cwd ?? ''}';
		return Path.join([js.node.Os.tmpdir(), 'apq-oracle-${Md5.encode(key)}.json']);
		#else
		return '';
		#end
	}

	/**
	 * Whether `raw` is a display-protocol reply — the marker that a real Haxe compilation
	 * server, rather than an unrelated listener that merely accepted the connection, is on
	 * the port. PURE: no process, unit-testable.
	 */
	public static function isServerReply(raw: String): Bool {
		// The REQUEST also carries `"jsonrpc"`, so that marker alone is satisfied by any
		// listener that echoes its input — the very shape this guard exists to reject. A
		// reply is what carries a `result` or an `error`.
		return raw.indexOf('"jsonrpc"') != -1 && (raw.indexOf('"result"') != -1 || raw.indexOf('"error"') != -1);
	}

	/**
	 * One `haxe --connect <port> <hxml> <extra…>` round trip run from `cwd`, narrowed to a
	 * `ConnectResult`, or null when the client could not be launched at all (no `haxe` on
	 * PATH). The shared process primitive of every warm-server consumer.
	 */
	public static function connect(port: Int, hxml: String, cwd: Null<String>, extra: Array<String>): Null<ConnectResult> {
		#if nodejs
		try {
			final args: Array<String> = ['--connect', '$port', hxml].concat(extra);
			final opts: Dynamic = { encoding: 'utf8' };
			if (cwd != null) Reflect.setField(opts, 'cwd', cwd);
			final res: Dynamic = js.node.ChildProcess.spawnSync('haxe', args, opts);
			if (res.error != null) return null;
			final status: Null<Int> = res.status;
			return { status: status, output: text(res.stdout) + text(res.stderr) };
		} catch (exception: haxe.Exception) {
			return null;
		}
		#else
		return null;
		#end
	}

	/**
	 * Poll `--connect` until the server answers (its first real connect drives the initial
	 * full compile and blocks until it finishes) or the boot budget is spent. A client that
	 * cannot be launched at all fails immediately rather than burning the whole budget on a
	 * machine that simply has no compiler.
	 */
	public static function warm(port: Int, hxml: String, cwd: Null<String>): Bool {
		#if nodejs
		var attempt: Int = 0;
		while (attempt < MAX_WARM_ATTEMPTS) {
			attempt++;
			final res: Null<ConnectResult> = connect(port, hxml, cwd, ['--no-output']);
			if (res == null) return false;
			if (!isConnectRefusal(res)) return true;
			sleep();
		}
		return false;
		#else
		return false;
		#end
	}

	/**
	 * Spawn `haxe --wait <port>` with its streams discarded, `detached` when the server
	 * must outlive this process. Null when the spawn itself threw.
	 */
	public static function spawnServer(port: Int, detached: Bool): Dynamic {
		#if nodejs
		try {
			final opts: Dynamic = { detached: detached, stdio: 'ignore' };
			return js.node.ChildProcess.spawn('haxe', ['--wait', '$port'], opts);
		} catch (exception: haxe.Exception) {
			return null;
		}
		#else
		return null;
		#end
	}

	/** Reap a spawned server handle. Idempotent and exception-safe. */
	public static function killChild(child: Dynamic): Void {
		#if nodejs
		// child.kill() does not throw for an already-dead process (it returns false) — no guard needed.
		child?.kill();
		#end
	}

	#if nodejs
	/**
	 * The recorded server when it is still alive AND still answers as a Haxe compilation
	 * server, with every possibly-stale linted file invalidated first. Null when there is
	 * no usable server: nothing recorded, the process is gone, the port answers as
	 * something else, or so many files changed that a fresh server is cheaper — that last
	 * case reaps the recorded one so the caller starts over.
	 */
	private static function reuse(hxml: String, cwd: Null<String>, paths: Array<String>): Null<ServerState> {
		final state: Null<ServerState> = readState(hxml, cwd);
		if (state == null || !isOurServer(state.pid, state.port)) return null;
		final stale: Array<String> = staleFiles(paths, state.compiledAt);
		if (stale.length > MAX_INVALIDATIONS) {
			killPid(state.pid);
			return null;
		}
		// With nothing to invalidate the hxml stands in as the probe: `server/invalidate` on
		// a path that is not a module is a no-op which still proves a Haxe server answers.
		final probes: Array<String> = stale.length > 0 ? stale : [hxml];
		// A server that is alive but no longer answers as one is reaped rather than left
		// behind: `startServer` would otherwise spawn its replacement and overwrite the only
		// record of it, orphaning a process holding a whole compiled project.
		for (p in probes) if (!invalidate(state.port, hxml, cwd, p)) {
			killPid(state.pid);
			return null;
		}
		return state;
	}

	/**
	 * Spawn a DETACHED server on a free random port, drive its first full compile, record
	 * it and return the handle — or null when no port worked. The process deliberately
	 * outlives this one, so it is unref'd rather than reaped; the record is written as soon
	 * as the server exists, so a run that dies later still leaves it discoverable.
	 */
	private static function startServer(hxml: String, cwd: Null<String>): Null<ServerState> {
		var attempt: Int = 0;
		while (attempt < MAX_PORT_ATTEMPTS) {
			attempt++;
			final startedAt: Int = nowSeconds();
			final port: Int = PORT_BASE + Std.random(PORT_SPAN);
			final child: Dynamic = spawnServer(port, true);
			if (child == null) continue;
			final spawnedPid: Null<Int> = child.pid;
			if (spawnedPid != null && warm(port, hxml, cwd) && invalidate(port, hxml, cwd, hxml)) {
				final pid: Int = spawnedPid;
				final state: ServerState = { port: port, pid: pid, compiledAt: startedAt };
				writeState(hxml, cwd, state);
				// A record that did not land would orphan the daemon the moment this process
				// exits — nothing else knows its pid — so an unwritable temp dir reaps it here.
				if (sys.FileSystem.exists(stateFile(hxml, cwd))) {
					child.unref();
					return state;
				}
			}
			killChild(child);
		}
		return null;
	}

	/**
	 * Ask the server to drop its cached module for `file`, and confirm the answer came from
	 * a compilation server at all. False when the port answered as something else — the
	 * check that keeps a stray listener from passing for a warm server.
	 */
	private static function invalidate(port: Int, hxml: String, cwd: Null<String>, file: String): Bool {
		final request: String = '{"jsonrpc":"2.0","id":1,"method":"server/invalidate","params":{"file":"${jsonPath(file)}"}}';
		final res: Null<ConnectResult> = connect(port, hxml, cwd, ['--display', request]);
		return res != null && isServerReply(res.output);
	}

	/**
	 * `file` as the REALPATH the compiler registers a module under, with the two characters a
	 * JSON string cannot carry raw escaped. The symlink resolution is load-bearing: the server
	 * matches `server/invalidate` against the resolved path, answers a well-formed reply either
	 * way, and simply does nothing when the path does not resolve to a module it holds — so an
	 * unresolved form disables the staleness guard with no diagnostic at all. Verified: under a
	 * symlinked root (macOS `$TMPDIR` = `/var/folders/…` → `/private/var/folders/…`) the
	 * unresolved form left a broken build reported as clean, the resolved form rejected it.
	 */
	private static function jsonPath(file: String): String {
		return realPath(file).replace('\\', '\\\\').replace('"', '\\"');
	}

	/**
	 * The `paths` whose modification SECOND is at or after `compiledAt` — the ones the
	 * server's one-second granularity may still be holding at their previous content. A
	 * path that cannot be stat'ed counts as just-written, the conservative direction.
	 */
	private static function staleFiles(paths: Array<String>, compiledAt: Int): Array<String> {
		return [for (p in paths) if (modifiedSecond(p) >= compiledAt) p];
	}

	/** `path`'s modification time in whole seconds, or now when it cannot be stat'ed. */
	private static function modifiedSecond(path: String): Int {
		return try Std.int(sys.FileSystem.stat(path).mtime.getTime() / MS_PER_SECOND) catch (exception: haxe.Exception) nowSeconds();
	}

	/** Wall clock in whole seconds — the unit the compilation server's staleness comparison works in. */
	private static function nowSeconds(): Int {
		return Std.int(Date.now().getTime() / MS_PER_SECOND);
	}

	/**
	 * The recorded server for `hxml`/`cwd`, or null when nothing is recorded or the record is
	 * unreadable / incomplete. Every field is checked, `compiledAt` included: a record missing
	 * it reads back as `undefined`, every `mtime >= undefined` comparison is false, and the
	 * staleness guard would silently pass over every file instead of failing loudly.
	 */
	private static function readState(hxml: String, cwd: Null<String>): Null<ServerState> {
		final path: String = stateFile(hxml, cwd);
		if (!sys.FileSystem.exists(path)) return null;
		final state: Null<ServerState> = try haxe.Json.parse(sys.io.File.getContent(path)) catch (exception: haxe.Exception) null;
		return state != null && state.port > 0 && state.pid > 0 && state.compiledAt > 0 ? state : null;
	}

	/** Record `state` as the shared server for `hxml`/`cwd`. */
	private static function writeState(hxml: String, cwd: Null<String>, state: ServerState): Void {
		try sys.io.File.saveContent(stateFile(hxml, cwd), haxe.Json.stringify(state)) catch (_exception: haxe.Exception) {
			// A temp dir we cannot write to only costs the next run a fresh server, never a verdict.
		}
	}

	/** Forget the record at `path`. */
	private static function deleteState(path: String): Void {
		try sys.FileSystem.deleteFile(path) catch (_exception: haxe.Exception) {
			// A record we cannot delete is re-validated, and replaced, on the next run anyway.
		}
	}

	/**
	 * Whether `pid` is still running AND is still the `haxe --wait <port>` that was recorded.
	 * A bare liveness probe is not enough: a record outliving its server (a reboot, a long-lived
	 * temp dir) points at a RECYCLED pid, and this class kills what it believes it owns.
	 */
	private static function isOurServer(pid: Int, port: Int): Bool {
		final res: Dynamic = js.node.ChildProcess.spawnSync('ps', ['-p', '$pid', '-o', 'command='], { encoding: 'utf8' });
		return text(res.stdout).indexOf('--wait $port') != -1;
	}

	/** Terminate a recorded server. Spawned rather than signalled in-process so an already-exited pid is a silent no-op instead of a throw. */
	private static function killPid(pid: Int): Void {
		js.node.ChildProcess.spawnSync('kill', ['$pid']);
	}

	/**
	 * Whether the client never reached a listener on the port — the fatal a dead or
	 * not-yet-listening server produces. Both spellings the compiler has shipped are
	 * matched, since the message is the only signal the client gives.
	 */
	private static function isConnectRefusal(res: ConnectResult): Bool {
		return res.output.indexOf('Couldn\'t connect') != -1 || res.output.indexOf('Could not connect') != -1;
	}

	/** Poll pause between `--connect` attempts while a freshly spawned server boots. */
	private static function sleep(): Void {
		// spawnSync reports a missing/failed `sleep` through its result, never a throw — a tighter poll is harmless.
		js.node.ChildProcess.spawnSync('sleep', ['0.3']);
	}

	/** Coerce a possibly-null spawn stream field (Buffer|String under utf8) to a String. */
	private static function text(value: Dynamic): String {
		return value == null ? '' : Std.string(value);
	}

	/** `file` resolved against the process cwd (node-normalised, NOT symlink-followed), or `file` on failure. */
	private static function absolute(file: String): String {
		return try sys.FileSystem.absolutePath(file) catch (exception: haxe.Exception) file;
	}

	/** `file` with its symlink chain resolved — the form the compiler records a module under; the plain absolute form when it cannot be resolved. */
	private static function realPath(file: String): String {
		// The result is bridged through an explicit `Null<String>` because `FileSystem.fullPath`'s
		// declared non-null `String` reads as nullable off a compilation-server cache. Both known
		// sites of that mismatch (here and `StdResolver.resolveSymlink`) are `fullPath` in a
		// try-expression; left unbridged, a warm recompile reports a null-safety error the cold
		// compile does not.
		final full: Null<String> = try sys.FileSystem.fullPath(file) catch (exception: haxe.Exception) null;
		return full ?? absolute(file);
	}
	#end

}
