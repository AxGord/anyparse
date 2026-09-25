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
	private static inline final MAX_PARALLEL: Int = 4;

	/**
	 * The memory one compile of a large project is budgeted, in bytes: a measured peak of a little over a gigabyte,
	 * plus headroom for everything else the machine runs.
	 */
	private static inline final COMPILE_MEMORY: Float = 2.0 * 1024 * 1024 * 1024;

	/**
	 * The node program `runAll` drives its jobs with: reads the jobs as JSON on stdin, keeps at most `argv[1]` of them
	 * running, kills one that out-writes `argv[2]` bytes, and prints every run as JSON in job order once all closed. A
	 * job runs `haxe <args>`, or its `shell` command line when it names one. With `argv[3]` = `1` a job that fails
	 * (any status but 0) kills every LATER job still running and starts none after it, so the first failure in job
	 * order is always one that ran to its end.
	 */
	private static inline final PARALLEL_DRIVER: String = "const cp = require('child_process');"
		+ "const jobs = JSON.parse(require('fs').readFileSync(0, 'utf8'));"
		+ "const limit = parseInt(process.argv[1]); const max = parseInt(process.argv[2]); const stop = process.argv[3] === '1';"
		+ "const out = new Array(jobs.length); const kids = new Array(jobs.length); let next = 0, running = 0, done = 0;"
		+ "function cancelAfter(i) { for (let k = i + 1; k < jobs.length; k++) { if (out[k]) continue;"
		+ " if (kids[k]) { kids[k].cancelled = true; kids[k].kill(); }"
		+ " else if (k >= next) { out[k] = { status: null, out: '', err: '', failure: '" + NOT_STARTED + "', overflowed: false,"
		+ " cancelled: true, unstarted: true }; done++; } } next = jobs.length; }"
		+ "function finish(i, rec) { if (out[i]) return; out[i] = rec; kids[i] = null; running--; done++;"
		+ " if (stop && rec.status !== 0 && !rec.cancelled) cancelAfter(i);"
		+ " if (done === jobs.length) process.stdout.write(JSON.stringify(out)); else start(); }"
		+ "function start() { while (running < limit && next < jobs.length) { const i = next++; if (out[i]) continue; running++;"
		+ " const j = jobs[i]; const o = [], e = []; let size = 0, over = false; const what = j.shell == null ? 'haxe' : 'the command';"
		+ " const opts = { cwd: j.cwd == null ? undefined : j.cwd, stdio: ['ignore', 'pipe', 'pipe'] };"
		+ " const c = j.shell == null ? cp.spawn('haxe', j.args, opts) : cp.spawn(j.shell, Object.assign({ shell: true }, opts));"
		+ " kids[i] = c;" + " c.stdout.on('data', d => { size += d.length; if (size > max) { over = true; c.kill(); } else o.push(d); });"
		+ " c.stderr.on('data', d => e.push(d));"
		+ " c.on('error', err => finish(i, { status: null, out: '', err: '', failure: 'could not launch ' + what + ' (' + err.message + ')',"
		+ " overflowed: false }));"
		+ " c.on('close', code => finish(i, { status: over || c.cancelled ? null : code, out: Buffer.concat(o).toString('utf8'),"
		+ " err: Buffer.concat(e).toString('utf8'), failure: c.cancelled ? 'cancelled — an earlier job failed'"
		+ " : over ? what + ' out-wrote its ' + max + ' byte output buffer' : '', overflowed: over, cancelled: c.cancelled === true })); } }"
		+ "if (jobs.length === 0) process.stdout.write('[]'); else start();";

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
		try {
			final process: sys.io.Process = new sys.io.Process('haxe', args);
			// Both pipes drained BEFORE `exitCode()`: `-v` writes a line per parsed module, far
			// more than a pipe buffer holds, and waiting on exit first deadlocks on exactly the
			// runs this class exists to make. `maxBuffer` has no counterpart here — the streams
			// are read whole — so an overflow is a nodejs-only outcome.
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
				failure: 'could not launch haxe (${exception.message})',
				overflowed: false
			};
		}
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
	public static function runAll(
		jobs: Array<{ args: Array<String>, cwd: Null<String>, ?shell: String }>, maxBuffer: Int, parallel: Int, ?stopAfterFailure: Bool
	): Array<HaxeRun> {
		final stop: Bool = stopAfterFailure ?? false;
		#if nodejs
		if (jobs.length <= 1 || parallel <= 1) return runInOrder(jobs, maxBuffer, stop);
		final options: Dynamic = {
			encoding: 'utf8',
			input: haxe.Json.stringify(jobs),
			maxBuffer: (maxBuffer + OVERHEAD) * jobs.length
		};
		final res: ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync(
			js.Node.process.execPath, ['-e', PARALLEL_DRIVER, '--', '$parallel', '$maxBuffer', stop ? '1' : '0'], options
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
	 * Run `command` through the platform shell in `cwd` (the process cwd when null), capturing both streams under a
	 * `maxBuffer` byte cap. Never throws; the same three answers as `run`. The native `sys` branch has no working
	 * directory, so a `cwd` other than the process one is refused there rather than run in the wrong place.
	 */
	public static function runShell(command: String, cwd: Null<String>, maxBuffer: Int): HaxeRun {
		#if nodejs
		final options: Dynamic = {
			encoding: 'utf8',
			maxBuffer: maxBuffer,
			shell: true,
			stdio: ['ignore', 'pipe', 'pipe']
		};
		if (cwd != null) Reflect.setField(options, 'cwd', cwd);
		final res: ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync(command, options);
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		if (launchError == null) return {
			status: (res.status: Null<Int>),
			out: streamText(res.stdout),
			err: streamText(res.stderr),
			failure: '',
			overflowed: false
		};
		final code: Null<Dynamic> = Reflect.field(launchError, 'code');
		final overflowed: Bool = code != null && '$code' == 'ENOBUFS';
		return {
			status: null,
			out: streamText(res.stdout),
			err: streamText(res.stderr),
			failure: overflowed
				? 'the command out-wrote its $maxBuffer byte output buffer'
				: 'could not launch the command (${Reflect.field(launchError, 'message')})',
			overflowed: overflowed
		};
		#elseif sys
		if (cwd != null && haxe.io.Path.normalize(cwd) != haxe.io.Path.normalize(Sys.getCwd())) return {
			status: null,
			out: '',
			err: '',
			failure: 'a command cannot run in $cwd on this target',
			overflowed: false
		};
		try {
			final process: sys.io.Process = new sys.io.Process(command);
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
				failure: 'could not launch the command (${exception.message})',
				overflowed: false
			};
		}
		#else
		return {
			status: null,
			out: '',
			err: '',
			failure: 'a child process requires a sys or nodejs target',
			overflowed: false
		};
		#end
	}

	/**
	 * How many compiles of one project may run at once: at most `MAX_PARALLEL`, at most half the cores, and at most as
	 * many as the machine's memory holds at `COMPILE_MEMORY` each — never fewer than one. `APQ_ORACLE_PARALLEL` (a
	 * positive integer) replaces the computed bound, for a machine the heuristic misjudges.
	 */
	public static function parallelism(): Int {
		final declared: Null<Int> = Std.parseInt(Sys.getEnv('APQ_ORACLE_PARALLEL') ?? '');
		if (declared != null && declared > 0) return declared;
		#if nodejs
		final byCpu: Int = Std.int(js.node.Os.cpus().length / 2);
		final byMemory: Int = Std.int(js.node.Os.totalmem() / COMPILE_MEMORY);
		return Std.int(Math.max(1, Math.min(MAX_PARALLEL, Math.min(byCpu, byMemory))));
		#else
		return 1;
		#end
	}

	/**
	 * `jobs` one after another through `run` / `runShell`, and — with `stop` — every job after the first failure
	 * answered `NOT_STARTED`: the sequential form of `runAll`.
	 */
	private static function runInOrder(
		jobs: Array<{ args: Array<String>, cwd: Null<String>, ?shell: String }>, maxBuffer: Int, stop: Bool
	): Array<HaxeRun> {
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
			final result: HaxeRun = shell == null ? run(job.args, job.cwd, maxBuffer) : runShell(shell, job.cwd, maxBuffer);
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
