package dev;

import anyparse.core.PoolLease;
import devkit.CpuMeter;
import devkit.ExecLedger;
import devkit.Summary.Outcome;
import haxe.Timer;

/**
 * The one answer to "what did a detached run that holds one lease for its whole life cost, as one ledger row": its wall, the
 * cpu of the processes it started (a meter whose usage files live beside the run's records) and the threads its caller's lease
 * granted (`WF_THREADS`), so a lease taker that outlives the land is judged against its use like any other.
 */
@:nullSafety(Strict)
final class DetachedRow {

	/** The suffix of the directory a run keeps the usage files of the processes it starts in. */
	public static final METERS: String = 'cpu';

	private static inline final MS_PER_SECOND: Float = 1000;

	/** `body` as the row `row` of `phase` in the ledger of `cache`, whatever its outcome; the meter's files are `<sha>.cpu` in `dir`. */
	public static function run(cache: String, dir: String, sha: String, phase: String, row: String, body: () -> Outcome): Outcome {
		CpuMeter.begin(PostLand.fileIn(dir, sha, METERS));
		final outcome: Outcome = record(cache, phase, row, held -> {
			held(PoolLease.threads());
			return body();
		});
		CpuMeter.end();
		return outcome;
	}

	/**
	 * The one answer to "record a body as one ledger row": `body` as the row `row` of `phase` in the ledger of `cache`, whatever its
	 * outcome, with its wall, the cpu of the processes it started (when a `CpuMeter` is running) and the threads it reports through
	 * the function it is given (none when it holds none the pool granted).
	 */
	public static function record(cache: String, phase: String, row: String, body: (Null<Int> -> Void) -> Outcome): Outcome {
		final at: Float = Date.now().getTime();
		final started: Float = Timer.stamp();
		final began: Null<CpuStamp> = CpuMeter.stamp();
		var threads: Null<Int> = null;
		final outcome: Outcome = body(held -> threads = held);
		final landed: LedgerRow = {
			row: row,
			phase: phase,
			wallMs: (Timer.stamp() - started) * MS_PER_SECOND,
			at: at
		};
		final used: Null<Float> = CpuMeter.since(began);
		if (used != null) landed.cpuS = used;
		if (threads != null) landed.threads = threads;
		ExecLedger.under(cache).record(landed);
		return outcome;
	}

}
