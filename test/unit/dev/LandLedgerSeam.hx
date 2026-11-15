package unit.dev;

import devkit.ExecLedger;
import sys.FileSystem;

/** The stand-in battery's ledger for `LandTest`: the file the land hands it, and an earlier attempt's file left in the logs. */
@:nullSafety(Strict)
final class LandLedgerSeam {

	/** The wall the stand-in battery reports as its span. */
	public static inline final SPAN_MS: Float = 400;

	/** What an earlier attempt's battery left in the logs. */
	public static final STALE_ROW: String = 'stale-row';

	/** The stand-in battery writes one row and its span to the file `--ledger` names in `words`, as `dev battery` does. */
	public static function fill(words: Array<String>): Void {
		final at: Int = words.indexOf('--ledger');
		if (at < 0) return;
		final ledger: ExecLedger = new ExecLedger(words[at + 1]);
		ledger.record({ row: 'suite', phase: 'battery', wallMs: 300 });
		ledger.record({ row: ExecLedger.SPAN_ROW, phase: 'battery', wallMs: SPAN_MS });
	}

	/** An earlier attempt's battery file in `logs`: every land of the suite starts beside one. */
	public static function seedStale(logs: String): Void {
		FileSystem.createDirectory(logs);
		new ExecLedger('$logs/battery.ledger').record({ row: STALE_ROW, phase: 'battery', wallMs: 1 });
	}

}
