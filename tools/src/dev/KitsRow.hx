package dev;

import dev.Probe.KitsReport;
import devkit.Summary;

using Lambda;

/**
 * The one answer to "what row do the probe kits make in a gate's table": the slice gate and the battery both show it, and a
 * deviating kit row, like a moved known-defect row, fails it.
 */
@:nullSafety(Strict)
final class KitsRow {

	/**
	 * `Probe.checkAll` over `repo` as an outcome, its reading a detail of `summary`; on a failure `show` gets every report line.
	 * The failure names the areas and how to acknowledge an intended change.
	 */
	public static function outcome(repo: String, summary: Summary, show: Array<String> -> Void): Outcome {
		if (Probe.areas(repo).length == 0) return Skipped('no kit under ${Probe.KITS}');
		final report: KitsReport = Probe.checkAll(repo, Probe.GATE_THREADS);
		summary.detail('${report.areas} kit(s), ${report.invocations} invocations');
		if (report.failing == 0) return Passed;
		show(report.lines);
		return Failed(failure(report));
	}

	/**
	 * What a failed `report` says: the failing rows by area, the command that re-records each area for an intended change, and the
	 * first report line. `--record` keeps every other field of a row, so a moved known-defect row also needs its `knownDefect` deleted.
	 */
	public static function failure(report: KitsReport): String {
		final record: String = [for (area in report.failed) 'node bin/dev.js probe $area --record --compile'].join('; ');
		final moved: Bool = report.lines.exists(line -> line.indexOf('KNOWN-DEFECT ROW MOVED') >= 0);
		final delete: String = moved ? ', and delete the knownDefect field of each row reported KNOWN-DEFECT ROW MOVED' : '';
		return '${report.failing} row(s) in ${report.failed.join(', ')}; for an intended change run $record$delete: ${report.lines[0]}';
	}

}
