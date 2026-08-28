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
}
