package anyparse.check;

#if nodejs
import js.node.ChildProcess.ChildProcessSpawnSyncResult;
#end

/**
 * One `haxe` child process — the single seam every compiler-oracle spawn in this
 * package goes through.
 *
 * ## Why it exists
 *
 * There were THREE near-copies of this block: `CompilerOracle.typecheck` (the
 * project-wide typecheck), `OracleCoverage.probeOutput` (the `-v` compiled-set probe)
 * and `OracleCache.probeOutput` (the `-v --interp Std` toolchain probe). One question —
 * "run `haxe` with these arguments in this directory and tell me what happened" — with
 * three independently drifted answers:
 *
 *  - the output BUFFER: 256 MiB in one, node's 1 MiB default in the other two, though
 *    the 1 MiB default is what the coverage probe's own doc records as blown through by
 *    815 KB on one project and 2.1 MB on another;
 *  - STDERR: read by one, deliberately dropped by another, silently dropped by the
 *    third;
 *  - the cwd on a native `sys` target: refused by one (the compiler prints RELATIVE
 *    paths, so answering from a directory it never ran in would build a set of wrong
 *    keys), silently ignored by the other two;
 *  - the drain ORDER on that target: two read the pipes BEFORE `exitCode()`, one
 *    waited on exit first — which deadlocks on any output larger than a pipe buffer,
 *    and `-v` is exactly that.
 *
 * A caller's POLICY — what an overflow means, whether a non-zero status is a verdict or
 * a refusal — stays with the caller. What is shared here is the mechanism: the spawn,
 * the buffer, both streams, and the four ways it can fail to produce an answer.
 *
 * ## The three answers this returns, and why they are not two
 *
 * `failure` is non-empty ONLY when the process produced no verdict at all — it never
 * ran, or it out-wrote its buffer. `overflowed` then separates those two, because they
 * send a reader to opposite places (output volume against a missing binary) and because
 * an overflow leaves PARTIAL output that one caller reads as a rejection's error text.
 * `status` is null for a process that produced no exit code. Everything else is an
 * honest run whatever it exited with.
 *
 * ## Target
 *
 * `js.node.ChildProcess.spawnSync` under nodejs (the target `apq` ships on),
 * `sys.io.Process` on a native sys target, and a compile-time failure on a target with
 * no process API — so every caller type-checks everywhere while only the nodejs path is
 * exercised in practice. `sys.io.Process` has no working directory, so the native
 * branch runs in the PROCESS cwd; `honoursCwd` states that, and a caller for which it
 * matters checks it rather than discovering the mismatch as wrong output.
 */
@:nullSafety(Strict)
final class HaxeSpawn {

	/** The failure sentence of a job `runAll` never started because an earlier one failed under `stopAfterFailure`. */
	public static inline final NOT_STARTED: String = 'not started — an earlier job failed';

	/** Bytes a job's JSON-escaped streams may add over its own output cap in the parallel driver's reply. */
	private static inline final OVERHEAD: Int = 1024 * 1024;

	/** The most compiles `parallelism` lets run at once, whatever the machine. */
	private static inline final MAX_PARALLEL: Int = 16;

	/**
	 * The memory one compile of a large project is budgeted, in bytes: a measured peak of a little over a gigabyte,
	 * plus headroom for everything else the machine runs.
	 */
	private static inline final COMPILE_MEMORY: Float = 2.0 * 1024 * 1024 * 1024;

	/**
	 * The node program `runAll` drives its jobs with: reads the jobs as JSON on stdin, keeps at most `argv[1]` of them
	 * running, kills one that out-writes `argv[2]` bytes or outlives its own `timeout` (ms, when positive), and prints
	 * every run as JSON in job order once all closed. A job runs `haxe <args>`, or its `shell` command line when it names
	 * one. With `argv[3]` = `1` a job that fails (any status but 0) kills every LATER job still running and starts none
	 * after it, so the first failure in job order is always one that ran to its end. Off Windows every job leads a
	 * process group of its own and a kill reaches the whole group — a shell's children (a build tool it started) die
	 * with it instead of writing on after their job was answered. A SIGINT, SIGTERM or SIGHUP to the driver kills every
	 * live job group before it exits: the groups are detached, so a Ctrl-C at the terminal no longer reaches them
	 * by itself. The driver also watches its parent: once `apq` is gone (its ppid changes — a SIGKILL leaves no
	 * handler to run) it does the same. A job naming a `groupFile` gets its process group leader written there
	 * (pid, then start time), so a run that takes over an abandoned generation can end the job the dead run left.
	 * With `argv[4]` naming a file the runs go there instead of stdout — written whole under a temporary name, then
	 * renamed, so the file exists only once it is complete — and with `argv[5]` naming one the jobs are read from it
	 * instead of stdin and deleted once read: the two ends a driver running in the BACKGROUND (`PendingRuns`) is talked
	 * to through. Such a driver ended by a signal, or outliving `apq`, removes the directory holding its answer file.
	 */
	private static inline final PARALLEL_DRIVER: String = "const cp = require('child_process');"
		+ "const jobs = JSON.parse(require('fs').readFileSync(process.argv[5] ? process.argv[5] : 0, 'utf8'));"
		+ "if (process.argv[5]) try { require('fs').unlinkSync(process.argv[5]); } catch (err) {}"
		+ "function drop() { if (process.argv[4]) try { require('fs').rmSync(require('path').dirname(process.argv[4]),"
		+ " { recursive: true, force: true }); } catch (err) {} }"
		+ "function emit(s) { const f = process.argv[4]; if (!f) { process.stdout.write(s); return; }"
		+ " require('fs').writeFileSync(f + '.part', s); require('fs').renameSync(f + '.part', f); }"
		+ "const limit = parseInt(process.argv[1]); const max = parseInt(process.argv[2]); const stop = process.argv[3] === '1';"
		+ "const group = process.platform !== 'win32';"
		+ "const out = new Array(jobs.length); const kids = new Array(jobs.length); let next = 0, running = 0, done = 0;"
		+ "function kill(c) { try { if (group) process.kill(-c.pid, 'SIGKILL'); else c.kill(); }"
		+ " catch (err) { try { c.kill('SIGKILL'); } catch (ignored) {} } }"
		+ "function killAll() { for (const c of kids) if (c) kill(c); }"
		+ "for (const s of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(s, () => { killAll(); drop(); process.exit(1); });"
		+ "const parent = process.ppid;"
		+ "setInterval(() => { if (process.ppid !== parent) { killAll(); drop(); process.exit(1); } }, 500).unref();"
		+ "function recordGroup(j, c) { if (j.groupFile == null || c.pid == null) return; let st = '';"
		+ " try { if (group) st = cp.execFileSync('ps', ['-o', 'lstart=', '-p', String(c.pid)], { encoding: 'utf8' }).trim(); } catch (err) {}"
		+ " try { require('fs').writeFileSync(j.groupFile, c.pid + '\\n' + st); } catch (err) {} }"
		+ "function cancelAfter(i) { for (let k = i + 1; k < jobs.length; k++) { if (out[k]) continue;"
		+ " if (kids[k]) { kids[k].cancelled = true; kill(kids[k]); }"
		+ " else if (k >= next) { out[k] = { status: null, out: '', err: '', failure: '" + NOT_STARTED + "', overflowed: false,"
		+ " cancelled: true, unstarted: true }; done++; } } next = jobs.length; }"
		+ "function finish(i, rec) { if (out[i]) return; out[i] = rec; if (kids[i] && kids[i].timer) clearTimeout(kids[i].timer);"
		+ " kids[i] = null; running--; done++;" + " if (stop && rec.status !== 0 && !rec.cancelled) cancelAfter(i);"
		+ " if (done === jobs.length) emit(JSON.stringify(out)); else start(); }"
		+ "function start() { while (running < limit && next < jobs.length) { const i = next++; if (out[i]) continue; running++;"
		+ " const j = jobs[i]; const o = [], e = []; let size = 0, over = false; const what = j.shell == null ? 'haxe' : 'the command';"
		+ " const opts = { cwd: j.cwd == null ? undefined : j.cwd, stdio: ['ignore', 'pipe', 'pipe'], detached: group };"
		+ " const c = j.shell == null ? cp.spawn('haxe', j.args, opts) : cp.spawn(j.shell, Object.assign({ shell: true }, opts));"
		+ " kids[i] = c; recordGroup(j, c);"
		+ " if (j.timeout > 0) c.timer = setTimeout(() => { c.timedOut = true; kill(c); }, j.timeout);"
		+ " c.stdout.on('data', d => { size += d.length; if (size > max) { over = true; kill(c); } else o.push(d); });"
		+ " c.stderr.on('data', d => e.push(d));"
		+ " c.on('error', err => finish(i, { status: null, out: '', err: '', failure: 'could not launch ' + what + ' (' + err.message + ')',"
		+ " overflowed: false }));" + " c.on('close', code => finish(i, { status: over || c.cancelled || c.timedOut ? null : code,"
		+ " out: Buffer.concat(o).toString('utf8'), err: Buffer.concat(e).toString('utf8'),"
		+ " failure: c.cancelled ? 'cancelled — an earlier job failed' : c.timedOut ? what + ' timed out after ' + j.timeout + ' ms'"
		+ " : over ? what + ' out-wrote its ' + max + ' byte output buffer' : '', overflowed: over, cancelled: c.cancelled === true })); } }"
		+ "if (jobs.length === 0) emit('[]'); else start();";

	/**
	 * Whether this target's spawn honours the `cwd` argument. False on the native `sys`
	 * branch, where `sys.io.Process` has no working directory — a caller whose answer
	 * depends on WHERE the compiler ran must refuse rather than resolve the reply against
	 * a root the compiler never saw.
	 */
	public static inline function honoursCwd(): Bool {
		return #if nodejs true #else false #end;
	}

	/**
	 * Run `haxe args` in `cwd` (the process cwd when null, and always when `honoursCwd`
	 * is false), capturing both streams under a `maxBuffer` byte cap. Never throws: every
	 * way this can fail to produce a verdict comes back as a `failure` sentence.
	 *
	 * `maxBuffer` is a required argument rather than a default, because the three callers
	 * disagree about what an overflow MEANS and a shared default would let one of them
	 * inherit a limit it never chose — which is the drift this class was extracted to end.
	 */
	public static function run(args: Array<String>, cwd: Null<String>, maxBuffer: Int): HaxeRun {
		#if nodejs
		final options: Dynamic = { encoding: 'utf8', maxBuffer: maxBuffer };
		if (cwd != null) Reflect.setField(options, 'cwd', cwd);
		final res: ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', args, options);
		final out: String = streamText(res.stdout);
		final err: String = streamText(res.stderr);
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		if (launchError == null) return {
			status: (res.status: Null<Int>),
			out: out,
			err: err,
			failure: '',
			overflowed: false
		};
		// ENOBUFS is the compiler having run FINE and out-written `maxBuffer`; every other
		// spawn error means `haxe` never ran at all. Both leave the caller without a status,
		// but only the first leaves it with output worth reading.
		final code: Null<Dynamic> = Reflect.field(launchError, 'code');
		final overflowed: Bool = code != null && '$code' == 'ENOBUFS';
		return {
			status: null,
			out: out,
			err: err,
			failure: overflowed
				? 'haxe out-wrote its $maxBuffer byte output buffer'
				: 'could not launch haxe (${Reflect.field(launchError, 'message')})',
			overflowed: overflowed
		};
		#elseif sys
		return processRun('haxe', args, 'haxe');
		#else
		return {
			status: null,
			out: '',
			err: '',
			failure: 'a haxe child process requires a sys or nodejs target',
			overflowed: false
		};
		#end
	}

	/**
	 * Run every job of `jobs` — `haxe args` in `cwd`, or the `shell` command line in `cwd` when the job names one — at
	 * most `parallel` at a time, each as its own process under the `maxBuffer` cap of `run`, and answer their runs in
	 * `jobs` order. The processes share nothing but the machine, so a caller whose jobs write no common path may overlap
	 * them; one that cannot say so passes 1. On a target without an asynchronous process API the jobs run one after
	 * another.
	 *
	 * With `stopAfterFailure` a job that fails (any status but 0) ends every LATER job — a running one is killed, an
	 * unstarted one never starts — and those answer `cancelled`. Jobs start in order, so every job before a failure has
	 * started and runs to its end: the first failure in job order is the same run a sequential loop that stopped there
	 * would have seen, which is what lets a caller keep first-failure semantics while overlapping the compiles.
	 */
	public static function runAll(jobs: Array<SpawnJob>, maxBuffer: Int, parallel: Int, ?stopAfterFailure: Bool): Array<HaxeRun> {
		final stop: Bool = stopAfterFailure ?? false;
		#if nodejs
		// a shell job always goes through the driver: only there does a kill reach its whole process group
		if ((jobs.length <= 1 || parallel <= 1) && !Lambda.exists(jobs, j -> j.shell != null)) return runInOrder(jobs, maxBuffer, stop);
		final options: Dynamic = {
			encoding: 'utf8',
			input: haxe.Json.stringify(jobs),
			maxBuffer: (maxBuffer + OVERHEAD) * jobs.length
		};
		final res: ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync(
			js.Node.process.execPath, driverArgs(parallel, maxBuffer, stop), options
		);
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		final status: Null<Int> = (res.status: Null<Int>);
		final answer: Null<Array<HaxeRun>> = launchError != null || status != 0
			? null
			: try haxe.Json.parse(streamText(res.stdout)) catch (exception: haxe.Exception) null;
		if (answer != null && answer.length == jobs.length) return answer;
		// the driver itself failed: every job is answered as a run that produced no verdict
		final why: String = 'the parallel process driver failed (${launchError == null ? 'status $status' : Reflect.field(launchError, 'message')})';
		return [
			for (_ in jobs)
				{
					status: null,
					out: '',
					err: streamText(res.stderr),
					failure: why,
					overflowed: false
				}
		];
		#else
		return runInOrder(jobs, maxBuffer, stop);
		#end
	}

	/**
	 * `runAll` over `jobs` started in the BACKGROUND: they run while the caller goes on, and `PendingRuns.await` answers
	 * what `runAll` would have. On a target without an asynchronous process API nothing starts before `await`.
	 */
	public static function startAll(jobs: Array<SpawnJob>, maxBuffer: Int, parallel: Int): PendingRuns {
		return new PendingRuns(jobs, maxBuffer, parallel);
	}

	/**
	 * Run `command` through the platform shell in `cwd` (the process cwd when null), capturing both streams under a
	 * `maxBuffer` byte cap. Never throws; the same three answers as `run`. The native `sys` branch has no working
	 * directory, so a `cwd` other than the process one is refused there rather than run in the wrong place.
	 */
	#if (sys && !nodejs)
	/**
	 * Run `command` through the platform shell in `cwd` — the non-node counterpart of a `shell` job in `runAll`. The
	 * native `sys` branch has no working directory, so a `cwd` other than the process one is refused rather than run in
	 * the wrong place.
	 */
	private static function runShell(command: String, cwd: Null<String>): HaxeRun {
		if (cwd != null && haxe.io.Path.normalize(cwd) != haxe.io.Path.normalize(Sys.getCwd())) return {
			status: null,
			out: '',
			err: '',
			failure: 'a command cannot run in $cwd on this target',
			overflowed: false
		};
		return processRun(command, null, 'the command');
	}

	/**
	 * One `sys.io.Process` run to its end: `args` null runs `command` through the shell. Both pipes are drained BEFORE
	 * `exitCode()`: `-v` writes a line per parsed module, far more than a pipe buffer holds, and waiting on exit first
	 * deadlocks on exactly the runs this class exists to make. There is no byte cap here — the streams are read whole —
	 * so an overflow is a nodejs-only outcome.
	 */
	private static function processRun(command: String, args: Null<Array<String>>, what: String): HaxeRun {
		try {
			final process: sys.io.Process = new sys.io.Process(command, args);
			final out: String = process.stdout.readAll().toString();
			final err: String = process.stderr.readAll().toString();
			final code: Null<Int> = process.exitCode();
			process.close();
			return {
				status: code,
				out: out,
				err: err,
				failure: '',
				overflowed: false
			};
		} catch (exception: haxe.Exception) {
			return {
				status: null,
				out: '',
				err: '',
				failure: 'could not launch $what (${exception.message})',
				overflowed: false
			};
		}
	}
	#end

	/**
	 * How many compiles of one project may run at once on this machine (`parallelismFor`). `APQ_ORACLE_PARALLEL` (a
	 * positive integer) replaces the computed bound, for a machine the heuristic misjudges.
	 */
	public static function parallelism(): Int {
		final declared: Null<Int> = Std.parseInt(Sys.getEnv('APQ_ORACLE_PARALLEL') ?? '');
		if (declared != null && declared > 0) return declared;
		#if nodejs
		return parallelismFor(js.node.Os.cpus().length, js.node.Os.totalmem());
		#else
		return 1;
		#end
	}

	/**
	 * The bound for a machine of `cores` cores and `memory` bytes: every core but one, at most as many compiles as the
	 * memory holds at `COMPILE_MEMORY` each, at most `MAX_PARALLEL`, never fewer than one. A compile is one
	 * single-threaded process the caller only waits on, so the cores are the budget; the knee of anyparse's own process
	 * fan-out (`docs/design-principles.md` § 2) is about parse processes sharing a tree, not about compiles.
	 */
	public static function parallelismFor(cores: Int, memory: Float): Int {
		return Std.int(Math.max(1, Math.min(MAX_PARALLEL, Math.min(cores - 1, memory / COMPILE_MEMORY))));
	}

	/**
	 * `jobs` one after another, and — with `stop` — every job after the first failure answered `NOT_STARTED`: the
	 * sequential form of `runAll`, for the jobs that need no process group (`haxe` spawns on node; everything elsewhere).
	 */
	private static function runInOrder(jobs: Array<SpawnJob>, maxBuffer: Int, stop: Bool): Array<HaxeRun> {
		final runs: Array<HaxeRun> = [];
		var failed: Bool = false;
		for (job in jobs) {
			if (failed) {
				runs.push({
					status: null,
					out: '',
					err: '',
					failure: NOT_STARTED,
					overflowed: false,
					cancelled: true,
					unstarted: true
				});
				continue;
			}
			final shell: Null<String> = job.shell;
			final result: HaxeRun = shell == null
				? run(job.args, job.cwd, maxBuffer)
				: #if (sys && !nodejs) runShell(shell, job.cwd) #else {
					status: null,
					out: '',
					err: '',
					failure: 'a shell job runs through the process driver on this target',
					overflowed: false
				} #end;
			if (stop && result.status != 0) failed = true;
			runs.push(result);
		}
		return runs;
	}

	#if nodejs
	/** Coerce a possibly-null spawn stream field (Buffer|String under utf8) to a String. */
	private static function streamText(value: Dynamic): String {
		return value == null ? '' : '$value';
	}
	#end

	/**
	 * The node argument vector that runs the process driver over at most `parallel` jobs at once under `maxBuffer`, with
	 * `stop` as `stopAfterFailure`. The jobs go to its stdin as JSON and its runs come back on stdout, in job order.
	 */
	public static function driverArgs(parallel: Int, maxBuffer: Int, stop: Bool, ?files: { result: String, jobs: String }): Array<String> {
		final args: Array<String> = [
			'-e',
			PARALLEL_DRIVER,
			'--',
			'${Std.int(Math.max(1, parallel))}',
			'$maxBuffer',
			stop ? '1' : '0'
		];
		return files == null ? args : args.concat([files.result, files.jobs]);
	}

}

/**
 * One process `HaxeSpawn.runAll` runs: `haxe <args>`, or the `shell` command line when set, in `cwd` (the process cwd
 * when null), killed after `timeout` ms when that is positive.
 */
typedef SpawnJob = {
	var args: Array<String>;
	var cwd: Null<String>;
	var ?shell: String;
	var ?timeout: Int;

	/** Where the driver writes the job's process group leader (pid, then its start time) once it started. */
	var ?groupFile: String;
}

/**
 * What one `haxe` spawn produced: its exit `status` (null when the process gave none),
 * its `out` and `err` streams, and — the fields that keep a non-verdict apart from a
 * verdict — `failure`, non-empty only when no exit status could be obtained at all, and
 * `overflowed`, which says the process RAN and out-wrote its buffer rather than never
 * having started.
 *
 * Folding the last two into a null status would make "no `haxe` on PATH" and "the
 * compiler out-wrote the output buffer" one sentence, and those send a reader to
 * opposite places. `out` / `err` are the PARTIAL streams in the overflow case, which is
 * what lets a caller still quote a failing build's errors.
 */
typedef HaxeRun = {
	var status: Null<Int>;
	var out: String;
	var err: String;
	var failure: String;
	var overflowed: Bool;

	/** `runAll` under `stopAfterFailure` ended this job because an earlier one failed: no verdict, by design. */
	var ?cancelled: Bool;

	/** A cancelled job that never started — no process was spawned for it. */
	var ?unstarted: Bool;
}
