package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;
import anyparse.check.HaxeSpawn.SpawnJob;

using StringTools;

#if nodejs
import anyparse.core.TempScratch;
import haxe.io.Path;
#end

/**
 * A `HaxeSpawn.runAll` batch running in the BACKGROUND (`HaxeSpawn.startAll`): the process driver is started
 * at once and the caller goes on with its own work; `await` blocks until every job closed and answers
 * exactly what `runAll` would have, `cancel` ends the batch.
 *
 * The driver is talked to through two files, since a synchronous caller never lets node deliver a pipe's data or a
 * child's exit: the jobs go in through one, and the runs come back through the other, which exists only once it is
 * complete. A driver that died without an answer — found by probing its pid, as an exited child nobody reaped still
 * holds one — is answered like a failed `runAll` driver: every job a run that produced no verdict. The driver already
 * ends every job it started when this process is gone, so an abandoned batch leaves nothing running.
 *
 * On a target without an asynchronous process API nothing starts before `await`, which then runs `runAll`.
 */
@:nullSafety(Strict)
final class PendingRuns {

	/** Milliseconds between two looks for the answer while `await` blocks. */
	private static inline final POLL_MS: Int = 20;

	/** Looks between two probes of whether the driver still lives. */
	private static inline final POLLS_PER_PROBE: Int = 25;

	/** The bound of the random suffix that keeps two batches' files apart. */
	private static inline final SUFFIX_BOUND: Int = 0x7fffffff;

	private final _jobs: Array<SpawnJob>;
	private final _maxBuffer: Int;
	private final _parallel: Int;

	private var _answer: Null<Array<HaxeRun>> = null;

	#if nodejs
	private var _pid: Null<Int> = null;
	private var _result: String = '';
	private var _input: String = '';
	#end

	public function new(jobs: Array<SpawnJob>, maxBuffer: Int, parallel: Int) {
		_jobs = jobs;
		_maxBuffer = maxBuffer;
		_parallel = parallel;
		#if nodejs
		if (jobs.length == 0) {
			_answer = [];
			return;
		}
		final base: String = Path.join([TempScratch.root(), 'apq-pending-${Std.random(SUFFIX_BOUND)}']);
		_input = '$base.jobs.json';
		_result = '$base.runs.json';
		try {
			sys.io.File.saveContent(_input, haxe.Json.stringify(jobs));
			final child: Dynamic = js.node.ChildProcess.spawn(
				js.Node.process.execPath, HaxeSpawn.driverArgs(parallel, maxBuffer, false, { result: _result, jobs: _input }),
				{ stdio: 'ignore' }
			);
			// a batch nobody awaits must not keep this process alive: the driver ends its jobs once this process is gone
			child.unref();
			_pid = child.pid;
		} catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// a driver that could not be started leaves `_pid` null, and `await` runs the batch in the foreground
		}
		#end
	}

	/**
	 * The runs of every job in job order, as `runAll` answers them — blocking until the batch ended. Asked again, the
	 * same answer. A batch whose driver could not be started runs now, in the foreground.
	 */
	public function await(): Array<HaxeRun> {
		final held: Null<Array<HaxeRun>> = _answer;
		if (held != null) return held;
		#if nodejs
		final pid: Null<Int> = _pid;
		final answer: Array<HaxeRun> = pid == null ? HaxeSpawn.runAll(_jobs, _maxBuffer, _parallel) : collect(pid);
		#else
		final answer: Array<HaxeRun> = HaxeSpawn.runAll(_jobs, _maxBuffer, _parallel);
		#end
		_answer = answer;
		return answer;
	}

	/**
	 * End the batch: the driver ends every job it started, and a later `await` answers every job as cancelled. A batch
	 * already answered keeps its answer.
	 */
	public function cancel(): Void {
		if (_answer != null) return;
		#if nodejs
		final pid: Null<Int> = _pid;
		if (pid != null) try js.Node.process.kill(pid, 'SIGTERM') catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// a driver already gone has nothing left to end
		} forget();
		#end
		_answer = [
			for (_ in _jobs)
				{
					status: null,
					out: '',
					err: '',
					failure: 'cancelled — the batch was abandoned',
					overflowed: false,
					cancelled: true
				}
		];
	}

	#if nodejs
	/** Block until driver `pid` wrote its answer, or died without one, and read it. */
	private function collect(pid: Int): Array<HaxeRun> {
		var polls: Int = 0;
		while (!sys.FileSystem.exists(_result)) {
			if (++polls % POLLS_PER_PROBE == 0 && !living(pid)) break;
			pause(POLL_MS);
		}
		final text: Null<String> = try sys.io.File.getContent(_result) catch (exception: haxe.Exception) null;
		forget();
		final answer: Null<Array<HaxeRun>> = text == null ? null : try haxe.Json.parse(text) catch (exception: haxe.Exception) null;
		return answer != null && answer.length == _jobs.length ? answer : [
			for (_ in _jobs)
				{
					status: null,
					out: '',
					err: '',
					failure: 'the background process driver ended without an answer',
					overflowed: false
				}
		];
	}

	/** Delete the batch's two files. */
	private function forget(): Void {
		for (path in [_input, _result]) try sys.FileSystem.deleteFile(path) catch (exception: haxe.Exception) { // noqa: swallowed-exception
			// a leftover file costs nothing but disk: the answer never depends on it
		}
	}

	/**
	 * Whether `pid` still runs. A child this process never reaped stays a zombie that a signal probe still finds, so
	 * off Windows `ps` is asked for its state as well.
	 */
	private static function living(pid: Int): Bool {
		// signal 0 delivers nothing: it only asks whether the pid exists
		try
			js.Syntax.code('process.kill({0}, 0)', pid)
		catch (exception: haxe.Exception)
			return false;
		if (js.Node.process.platform == 'win32') return true;
		final res: Dynamic = js.node.ChildProcess.spawnSync('ps', ['-o', 'stat=', '-p', '$pid'], { encoding: 'utf8' });
		// no `ps` to ask: the signal probe's answer stands
		if (res.error != null) return true;
		final state: String = StringTools.trim(res.stdout == null ? '' : '${res.stdout}');
		return state != '' && !state.startsWith('Z');
	}

	/** Block this thread for `ms` milliseconds without spawning anything. */
	private static inline function pause(ms: Int): Void {
		js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, {0})', ms);
	}
	#end

}
