package anyparse.check;

import anyparse.core.PhaseTimings;

using StringTools;

#if nodejs
import anyparse.core.TempScratch;
import haxe.DynamicAccess;
import haxe.io.Path;
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
 *
 * ## Environment
 *
 * Every `haxe` the oracle starts — a compile, a `--wait` server, a `--connect` client, the jobs of the process driver — runs
 * in `childEnv`: this process's environment with the OCaml collector tuned (`gcSetting`, `DEFAULT_GC` unless
 * `APQ_ORACLE_GC` says otherwise), which buys compile time with a few hundred MB more per process — what
 * `parallelismFor` budgets. Nothing else is: the analyzer stays on in every spawn, because each of them reads the
 * compile's status or streams and the analyzer is one of the compiler phases that writes them (`docs/decisions.md`,
 * "O1"). The native `sys` branch runs in this process's environment as it is.
 */
@:nullSafety(Strict)
final class HaxeSpawn {

	/** The failure sentence of a job `runAll` never started because an earlier one failed under `stopAfterFailure`. */
	public static inline final NOT_STARTED: String = 'not started — an earlier job failed';

	/**
	 * The OCaml runtime parameters every `haxe` the oracle starts runs under unless `APQ_ORACLE_GC` names others: a
	 * 16M-word minor heap and a `space_overhead` of 400, which collect a compile's short-lived allocations far less
	 * often. The collector's settings change when memory is reclaimed, never what the compiler answers.
	 */
	public static inline final DEFAULT_GC: String = 's=16M,o=400';

	/** The `APQ_ORACLE_GC` value that leaves every compile under the runtime's own collector settings. */
	public static inline final GC_OFF: String = 'off';

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
	 * What a compile under a tuned collector (`gcSetting`) is budgeted on top of `COMPILE_MEMORY`: the larger minor heap
	 * and the later major collections of `DEFAULT_GC` raise a large project's peak by a few hundred megabytes.
	 */
	private static inline final GC_MEMORY: Float = 0.5 * 1024 * 1024 * 1024;

	/**
	 * What one job that names no `timeout` of its own is granted in `driverBound`: ten minutes, some twenty times what a
	 * large project's compile takes on a loaded machine.
	 */
	private static inline final JOB_BOUND: Float = 10 * 60 * 1000;

	/** What `driverBound` adds for the process driver itself: its start, the job launches, the answer. */
	private static inline final DRIVER_SLACK: Float = 60 * 1000;

	/** The largest `driverBound`: a millisecond count that still fits an `Int`. */
	private static inline final MAX_BOUND: Float = 2147483647;


	/**
	 * The node program a `tethered` job runs under, between the driver and the job: `argv[1]` is `1` when the tether leads
	 * a process group of its own, `argv[2]` the job as JSON (`cmd`, `args`, `shell`). The job's streams are the tether's,
	 * its stdin is a pipe the driver alone holds, and its exit status is the job's (127 when the job could not be
	 * launched). Once that pipe closes — the driver is gone, by whatever means — or a SIGINT, SIGTERM or SIGHUP reaches
	 * it, the tether kills its whole group (the job and everything the job started), or the job alone when it leads no
	 * group, and exits. Holds no single quote and no backslash: the driver carries it inside a single-quoted literal.
	 */
	private static inline final TETHER: String = 'const cp = require("child_process");'
		+ 'const lead = process.argv[1] === "1"; const job = JSON.parse(process.argv[2]);'
		+ 'const c = cp.spawn(job.cmd, job.args, { shell: job.shell === true, stdio: ["ignore", "inherit", "inherit"] });'
		+ 'let ended = false; function end() { if (ended) return; ended = true;'
		+ ' try { if (lead) process.kill(-process.pid, "SIGKILL"); else c.kill("SIGKILL"); }'
		+ ' catch (err) { try { c.kill("SIGKILL"); } catch (ignored) {} } process.exit(1); }'
		+ 'process.stdin.on("end", end); process.stdin.on("close", end); process.stdin.on("error", end); process.stdin.resume();'
		+ 'for (const s of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(s, end);'
		+ 'c.on("error", () => process.exit(127)); c.on("exit", code => process.exit(code === null ? 1 : code));';

	/**
	 * The node program `runAll` drives its jobs with: reads the jobs as JSON from the file `argv[5]` names and deletes
	 * it, keeps at most `argv[1]` of them running, kills one that out-writes `argv[2]` bytes or outlives its own `timeout`
	 * (ms, when positive), and prints every run as JSON in job order once all closed. A job runs `haxe <args>`, or its
	 * `shell` command line when it names one. With `argv[3]` = `1` a job that fails (any status but 0) kills every LATER
	 * job still running and starts none after it, so the first failure in job order is always one that ran to its end.
	 * Off Windows every job leads a process group of its own and a kill reaches the whole group — a shell's children (a
	 * build tool it started) die with it instead of writing on after their job was answered. A SIGINT, SIGTERM or SIGHUP
	 * to the driver kills every live job group before it exits: the groups are detached, so a Ctrl-C at the terminal no
	 * longer reaches them by itself. The driver also watches its parent: once `apq` is gone (its ppid changes — a SIGKILL leaves no
	 * handler to run) it does the same. A job naming a `groupFile` gets its process group leader written there
	 * (pid, then start time), so a run that takes over an abandoned generation can end the job the dead run left.
	 * With `argv[4]` naming a file (it is empty for `runAll`) the runs go there instead of stdout — written whole under a
	 * temporary name, then renamed, so the file exists only once it is complete: the end a driver running in the
	 * BACKGROUND (`PendingRuns`) answers through. Such a driver ended by a signal, or outliving `apq`, removes the
	 * directory holding its answer file. The driver never reads its stdin: a pipe handed to `spawnSync` as `input` can
	 * stall for good on macOS (`runAll`).
	 * A `tethered` job runs under `TETHER`, the driver holding the write end of its stdin: the job dies with the driver
	 * however the driver went, a SIGKILL of the whole process group `apq` and the driver share included — off Windows a
	 * job's group is its own, so that kill does not reach it. Off Windows a tethered job is killed like any other; on
	 * Windows, where a kill reaches the tether alone, its stdin is closed instead and the tether ends the job itself.
	 */
	private static inline final PARALLEL_DRIVER: String = "const cp = require('child_process');" + "const TETHER = '" + TETHER + "';"
		+ "const jobs = JSON.parse(require('fs').readFileSync(process.argv[5], 'utf8'));"
		+ "if (process.argv[5]) try { require('fs').unlinkSync(process.argv[5]); } catch (err) {}"
		+ "function drop() { if (process.argv[4]) try { require('fs').rmSync(require('path').dirname(process.argv[4]),"
		+ ' { recursive: true, force: true }); } catch (err) {} }'
		+ 'function emit(s) { const f = process.argv[4]; if (!f) { process.stdout.write(s); return; }'
		+ " require('fs').writeFileSync(f + '.part', s); require('fs').renameSync(f + '.part', f); }"
		+ "const limit = parseInt(process.argv[1]); const max = parseInt(process.argv[2]); const stop = process.argv[3] === '1';"
		+ "const group = process.platform !== 'win32';"
		+ 'const out = new Array(jobs.length); const kids = new Array(jobs.length); let next = 0, running = 0, done = 0;'
		+ 'function kill(c) { if (c.tethered && !group) { c.stdin.destroy(); return; }'
		+ " try { if (group) process.kill(-c.pid, 'SIGKILL'); else c.kill(); }"
		+ " catch (err) { try { c.kill('SIGKILL'); } catch (ignored) {} } }"
		+ 'function killAll() { for (const c of kids) if (c) kill(c); }'
		+ "for (const s of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(s, () => { killAll(); drop(); process.exit(1); });"
		+ 'const parent = process.ppid;'
		+ 'setInterval(() => { if (process.ppid !== parent) { killAll(); drop(); process.exit(1); } }, 500).unref();'
		+ "function recordGroup(j, c) { if (j.groupFile == null || c.pid == null) return; let st = '';"
		+ " try { if (group) st = cp.execFileSync('ps', ['-o', 'lstart=', '-p', String(c.pid)], { encoding: 'utf8' }).trim(); } catch (err) {}"
		+ " try { require('fs').writeFileSync(j.groupFile, c.pid + '\\n' + st); } catch (err) {} }"
		+ 'function cancelAfter(i) { for (let k = i + 1; k < jobs.length; k++) { if (out[k]) continue;'
		+ ' if (kids[k]) { kids[k].cancelled = true; kill(kids[k]); }'
		+ " else if (k >= next) { out[k] = { status: null, out: '', err: '', failure: '" + NOT_STARTED + "', overflowed: false,"
		+ ' cancelled: true, unstarted: true }; done++; } } next = jobs.length; }'
		+ 'function finish(i, rec) { if (out[i]) return; out[i] = rec; if (kids[i] && kids[i].timer) clearTimeout(kids[i].timer);'
		+ ' kids[i] = null; running--; done++;' + ' if (stop && rec.status !== 0 && !rec.cancelled) cancelAfter(i);'
		+ ' if (done === jobs.length) emit(JSON.stringify(out)); else start(); }'
		+ 'function start() { while (running < limit && next < jobs.length) { const i = next++; if (out[i]) continue; running++;'
		+ " const j = jobs[i]; const o = [], e = []; let size = 0, over = false; const what = j.shell == null ? 'haxe' : 'the command';"
		+ " const opts = { cwd: j.cwd == null ? undefined : j.cwd, stdio: [j.tethered ? 'pipe' : 'ignore', 'pipe', 'pipe'],"
		+ ' detached: group };'
		+ " const c = j.tethered ? cp.spawn(process.execPath, ['-e', TETHER, '--', group ? '1' : '0', JSON.stringify(j.shell == null"
		+ " ? { cmd: 'haxe', args: j.args } : { cmd: j.shell, args: [], shell: true })], opts)"
		+ " : j.shell == null ? cp.spawn('haxe', j.args, opts) : cp.spawn(j.shell, Object.assign({ shell: true }, opts));"
		+ " c.tethered = j.tethered === true; if (c.tethered) c.stdin.on('error', () => {}); kids[i] = c; recordGroup(j, c);"
		+ ' if (j.timeout > 0) c.timer = setTimeout(() => { c.timedOut = true; kill(c); }, j.timeout);'
		+ " c.stdout.on('data', d => { size += d.length; if (size > max) { over = true; kill(c); } else o.push(d); });"
		+ " c.stderr.on('data', d => e.push(d));"
		+ " c.on('error', err => finish(i, { status: null, out: '', err: '', failure: 'could not launch ' + what + ' (' + err.message + ')',"
		+ ' overflowed: false }));' + " c.on('close', code => finish(i, { status: over || c.cancelled || c.timedOut ? null : code,"
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
		final options: Dynamic = { encoding: 'utf8', maxBuffer: maxBuffer, env: childEnv() };
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
	 *
	 * The jobs reach the driver through a file (`writeJobs`), never through its stdin: an `input` piped to `spawnSync`
	 * can stall for good on macOS, about once in seven hundred calls at 200 KB (`docs/decisions.md`, "F1"), and the
	 * driver then waits on a read that never ends. A driver still running `bound` ms in (`driverBound` unless given) is wedged and is killed,
	 * and every job answers that it produced no verdict; nothing is retried, since a killed driver may have run any of
	 * its jobs.
	 */
	public static function runAll(
		jobs: Array<SpawnJob>, maxBuffer: Int, parallel: Int, ?stopAfterFailure: Bool, ?bound: Int
	): Array<HaxeRun> {
		return PhaseTimings.measure('haxe runAll', () -> runAllTimed(jobs, maxBuffer, parallel, stopAfterFailure, bound));
	}

	/** `runAll`, untimed. */
	private static function runAllTimed(
		jobs: Array<SpawnJob>, maxBuffer: Int, parallel: Int, stopAfterFailure: Null<Bool>, bound: Null<Int>
	): Array<HaxeRun> {
		final stop: Bool = stopAfterFailure ?? false;
		#if nodejs
		// a shell job always goes through the driver: only there does a kill reach its whole process group; a tethered one,
		// because only there is it tethered
		if ((jobs.length <= 1 || parallel <= 1) && !Lambda.exists(jobs, j -> j.shell != null || j.tethered == true))
			return runInOrder(jobs, maxBuffer, stop);
		// the jobs go in through a FILE and the driver's stdin is the null device: an `input` piped to `spawnSync` can
		// stall for good on macOS, the stdin socket drained while this process sleeps in `kevent` with bytes still to
		// write, and the driver then blocks on a read that never ends (`docs/decisions.md`, "F1")
		final batch: Null<DriverBatch> = writeJobs(jobs, 'apq-runall-');
		if (batch == null) return unanswered(jobs.length, 'the jobs could not be written for the parallel process driver', '');
		final limit: Int = bound ?? driverBound(jobs, parallel);
		final options: Dynamic = {
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'pipe'],
			// the driver hands its own environment to every job it starts
			env: childEnv(),
			maxBuffer: (maxBuffer + OVERHEAD) * jobs.length,
			// a driver that outlives every job's share of the bound is wedged: SIGKILL is the one signal a node process
			// blocked in a synchronous call, or a stopped one, cannot leave unanswered
			timeout: limit,
			killSignal: 'SIGKILL'
		};
		final res: ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync(
			js.Node.process.execPath, driverArgs(parallel, maxBuffer, stop, { result: '', jobs: batch.jobs }), options
		);
		dropBatch(batch.dir);
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		final status: Null<Int> = (res.status: Null<Int>);
		final answer: Null<Array<HaxeRun>> = launchError != null || status != 0
			? null
			: try haxe.Json.parse(streamText(res.stdout)) catch (exception: haxe.Exception) null;
		if (answer != null && answer.length == jobs.length) return answer;
		// the driver itself failed: every job is answered as a run that produced no verdict
		final code: Null<Dynamic> = launchError == null ? null : Reflect.field(launchError, 'code');
		final why: String = code != null && '$code' == 'ETIMEDOUT'
			? 'the parallel process driver did not answer within $limit ms and was killed'
			: 'the parallel process driver failed (${launchError == null ? 'status $status' : Reflect.field(launchError, 'message')})';
		return unanswered(jobs.length, why, streamText(res.stderr));
		#else
		return runInOrder(jobs, maxBuffer, stop);
		#end
	}

	/**
	 * `runAll` over `jobs` started in the BACKGROUND: they run while the caller goes on, and `PendingRuns.await` answers
	 * what `runAll` would have. On a target without an asynchronous process API nothing starts before `await`.
	 */
	public static function startAll(jobs: Array<SpawnJob>, maxBuffer: Int, parallel: Int, ?bound: Int): PendingRuns {
		return new PendingRuns(jobs, maxBuffer, parallel, bound);
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
		return parallelismFor(js.node.Os.cpus().length, js.node.Os.totalmem(), gcSetting() != null);
		#else
		return 1;
		#end
	}

	/**
	 * The bound for a machine of `cores` cores and `memory` bytes: every core but one, at most as many compiles as the
	 * memory holds at `COMPILE_MEMORY` each — plus `GC_MEMORY` when the compiles run under a `tunedCollector` — at most
	 * `MAX_PARALLEL`, never fewer than one. A compile is one single-threaded process the caller only waits on, so the
	 * cores are the budget; the knee of anyparse's own process fan-out (`docs/design-principles.md` § 2) is about parse
	 * processes sharing a tree, not about compiles.
	 */
	public static function parallelismFor(cores: Int, memory: Float, tunedCollector: Bool): Int {
		final perCompile: Float = COMPILE_MEMORY + (tunedCollector ? GC_MEMORY : 0);
		return Std.int(Math.max(1, Math.min(MAX_PARALLEL, Math.min(cores - 1, memory / perCompile))));
	}

	/**
	 * The `OCAMLRUNPARAM` a `haxe` the oracle starts runs under (`gcParams` of this process's environment), or null for
	 * none: `APQ_ORACLE_GC` (unset or empty: `DEFAULT_GC`; `off`: none of ours) over the `OCAMLRUNPARAM` — or, when that
	 * is unset, the `CAMLRUNPARAM` the OCaml runtime falls back to — this process inherited.
	 */
	public static function gcSetting(): Null<String> {
		return gcParams(Sys.getEnv('APQ_ORACLE_GC'), Sys.getEnv('OCAMLRUNPARAM') ?? Sys.getEnv('CAMLRUNPARAM'));
	}

	/**
	 * The runtime parameters `declared` (an `APQ_ORACLE_GC` value) and `inherited` (the caller's own `OCAMLRUNPARAM`)
	 * make, null for none. Every parameter `inherited` sets stays as it is, and ours join it only for the parameters it
	 * does not set: a caller who tuned the runtime for a reason of their own keeps it. Pure.
	 */
	public static function gcParams(declared: Null<String>, inherited: Null<String>): Null<String> {
		final asked: String = declared == null || declared.trim() == '' ? DEFAULT_GC : declared.trim();
		final own: Array<String> = asked == GC_OFF ? [] : [for (p in asked.split(',')) if (p.trim() != '') p.trim()];
		final kept: String = inherited == null ? '' : inherited.trim();
		final taken: Array<String> = [for (p in kept.split(',')) if (p.trim() != '') paramName(p)];
		final added: Array<String> = [for (p in own) if (!taken.contains(paramName(p))) p];
		final all: Array<String> = (kept == '' ? [] : [kept]).concat(added);
		return all.length == 0 ? null : all.join(',');
	}

	#if nodejs
	/**
	 * A directory of its own (`mkdtemp`: private to this user, and no other process can have named it first) holding
	 * `jobs` as JSON in the file the process driver reads its jobs from (`driverArgs`) and deletes once read; null when
	 * either could not be written. `dropBatch` removes it with whatever is left in it.
	 */
	public static function writeJobs(jobs: Array<SpawnJob>, prefix: String): Null<DriverBatch> {
		final dir: Null<String> =
			try js.node.Fs.mkdtempSync(Path.join([TempScratch.root(), prefix])) catch (exception: haxe.Exception) null;
		if (dir == null) return null;
		final file: String = Path.join([dir, 'jobs.json']);
		try sys.io.File.saveContent(file, haxe.Json.stringify(jobs)) catch (exception: haxe.Exception) {
			dropBatch(dir);
			return null;
		}
		return { dir: dir, jobs: file };
	}

	/** Remove the batch directory `dir` (`writeJobs`) and everything left in it. */
	public static function dropBatch(dir: String): Void {
		try js.Syntax.code(
			"require('fs').rmSync({0}, { recursive: true, force: true })", dir
		) catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// a leftover directory costs nothing but disk: no answer depends on it
		}
	}

	/**
	 * The environment every `haxe` the oracle starts runs in — this process's own, with `OCAMLRUNPARAM` set to
	 * `gcSetting` when that names any parameter. The process driver of `runAll` runs under it and hands it to every job,
	 * so a generate command's shell gets it too: the collector's settings change no output, only when memory is reclaimed.
	 */
	public static function childEnv(): DynamicAccess<Null<String>> {
		final own: DynamicAccess<String> = js.Node.process.env;
		final env: DynamicAccess<Null<String>> = {};
		for (key in own.keys()) env[key] = own[key];
		final gc: Null<String> = gcSetting();
		if (gc != null) env['OCAMLRUNPARAM'] = gc;
		return env;
	}
	#end

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

	/** The name of one `OCAMLRUNPARAM` parameter `param` (`s` of `s=16M`, `b` of the flag `b`). */
	private static inline function paramName(param: String): String {
		final eq: Int = param.indexOf('=');
		return (eq < 0 ? param : param.substr(0, eq)).trim();
	}

	#if nodejs
	/** Coerce a possibly-null spawn stream field (Buffer|String under utf8) to a String. */
	private static function streamText(value: Dynamic): String {
		return value == null ? '' : '$value';
	}
	#end

	/**
	 * The node argument vector that runs the process driver over at most `parallel` jobs at once under `maxBuffer`, with
	 * `stop` as `stopAfterFailure`. The jobs are read from the JSON file `files.jobs` names, and the runs come back in
	 * job order in the file `files.result` names, or on stdout when that is empty.
	 */
	public static function driverArgs(parallel: Int, maxBuffer: Int, stop: Bool, files: { result: String, jobs: String }): Array<String> {
		return [
			'-e',
			PARALLEL_DRIVER,
			'--',
			'${Std.int(Math.max(1, parallel))}',
			'$maxBuffer',
			stop ? '1' : '0',
			files.result,
			files.jobs
		];
	}

	/**
	 * The milliseconds a process driver running `jobs` at most `parallel` at a time may take before it counts as wedged:
	 * every round of `parallel` jobs the longest job's own `timeout` (`JOB_BOUND` for a job naming none), plus
	 * `DRIVER_SLACK`. Far above any honest run, so it can only end a driver that stopped doing its work — the bound exists
	 * so that nothing waits on one forever. Pure.
	 */
	public static function driverBound(jobs: Array<SpawnJob>, parallel: Int): Int {
		var longest: Float = 0;
		for (job in jobs) longest = Math.max(longest, job.timeout != null && job.timeout > 0 ? job.timeout : JOB_BOUND);
		final rounds: Float = Math.ceil(jobs.length / Math.max(1, parallel));
		return Std.int(Math.min(MAX_BOUND, rounds * longest + DRIVER_SLACK));
	}

	/**
	 * Every job of a batch of `count` answered as a run that produced no verdict, for `failure`, with `err` as its stderr
	 * and `cancelled` when the batch was ended on purpose.
	 */
	public static function unanswered(count: Int, failure: String, err: String, ?cancelled: Bool): Array<HaxeRun> {
		return [
			for (_ in 0...count)
				{
					status: null,
					out: '',
					err: err,
					failure: failure,
					overflowed: false,
					cancelled: cancelled
				}
		];
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

	/**
	 * The job never outlives the driver that started it, however the driver ends (`HaxeSpawn.TETHER`) — for a job that
	 * never ends by itself, a compilation server.
	 */
	var ?tethered: Bool;
}

/** A batch directory `HaxeSpawn.writeJobs` made, and the jobs file in it the process driver reads. */
typedef DriverBatch = {
	var dir: String;
	var jobs: String;
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
