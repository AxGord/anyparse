package devkit;

import haxe.io.Path;
import js.Node;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The one answer to "which wall time has a command shown on each size of a flexible lease": the finished runs of a leased
 * command, recorded as one line `key TAB threads TAB ms` in a file under the blast cache, and the per-size seconds of an
 * `Ask` read back from them. A key is a lease label without what differs between runs of one command (`keyOf`). The file
 * is advisory and bounded: appends are single lines, and a compaction racing an append may lose that line.
 */
@:nullSafety(Strict)
final class LeaseHistory {

	/** The latest runs per key and size that count; older ones are no reading of today's tree. */
	public static inline final RECENT: Int = 10;

	/** Fewer runs than this on a size say nothing about it. */
	public static inline final MIN_RUNS: Int = 3;

	/** The most lines the file keeps; past it a record compacts the file. */
	public static inline final MAX_LINES: Int = 400;

	/** The file's name under the cache directory. */
	public static final FILE: String = 'lease-history.tsv';

	/** The percentile of a size's runs taken as its time. */
	private static inline final PERCENTILE: Float = 0.9;

	private static inline final MS_PER_SECOND: Float = 1000;

	/** What differs between runs of one command and names none of it: a slice or task id, a commit hash. */
	private static final RUN_SPECIFIC: EReg = ~/\b[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+\b|\b[A-Z]\d+\b|\b(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b/g;

	private final _file: String;

	public function new(file: String) {
		_file = file;
	}

	/** One more finished run of `key` on `threads` threads that took `ms`; a reading that is no time is not recorded. */
	public function record(key: String, threads: Int, ms: Float): Void {
		if (key == '' || threads < 1 || !(ms > 0)) return;
		final directory: String = Path.directory(_file);
		if (directory != '' && !FileSystem.exists(directory)) FileSystem.createDirectory(directory);
		js.node.Fs.appendFileSync(_file, '$key\t$threads\t${Math.round(ms)}\n');
		final lines: Array<String> = linesOf();
		if (lines.length <= MAX_LINES) return;
		final temp: String = '$_file.${Node.process.pid}.tmp';
		File.saveContent(temp, bounded(lines).map(line -> '$line\n').join(''));
		FileSystem.rename(temp, _file);
	}

	/** A run of `key` that began with this process and ends now, on the `threads` its lease granted (none: not recorded). */
	public function recordLived(key: String, threads: Null<Int>): Void {
		if (threads != null) record(key, threads, Node.process.uptime() * MS_PER_SECOND);
	}

	/**
	 * The seconds `key` takes on each size from `min` to `max`, or null when the history cannot tell every size: a size run
	 * `MIN_RUNS` times keeps its own p90, the others come from the curve through the sizes known (`curve`).
	 */
	public function seconds(key: String, min: Int, max: Int): Null<Map<Int, Int>> {
		final runs: Map<Int, Array<Float>> = [];
		for (line in linesOf()) {
			final fields: Array<String> = line.split('\t');
			if (fields.length != 3 || fields[0] != key) continue;
			final threads: Null<Int> = Std.parseInt(fields[1]);
			final ms: Float = Std.parseFloat(fields[2]);
			if (threads == null || !(ms > 0)) continue;
			final seen: Array<Float> = runs[threads] ?? [];
			seen.push(ms);
			runs[threads] = seen.slice(-RECENT);
		}
		final known: Map<Int, Float> = [];
		for (threads => times in runs) {
			final p: Null<Float> = p90(times);
			if (p != null) known[threads] = p;
		}
		final fitted: Null<Map<Int, Float>> = curve(known, min, max);
		return fitted == null ? null : [
			for (threads => ms in fitted) threads => Std.int(Math.max(1, Math.ceil(ms / MS_PER_SECOND)))
		];
	}

	private function linesOf(): Array<String> {
		return FileSystem.exists(_file) ? File.getContent(_file).split('\n').filter(line -> line != '') : [];
	}

	/** The history kept in the cache directory `cache`. */
	public static function under(cache: String): LeaseHistory {
		return new LeaseHistory(Path.join([cache, FILE]));
	}

	/** The identity of a lease's work across runs: its `label` with run ids and commit hashes dropped, as the pool keys its own history. */
	public static function keyOf(label: String): String {
		return RUN_SPECIFIC.replace(label.trim(), '*').replace('\t', ' ').replace('\n', ' ');
	}

	/** The nearest-rank percentile of `times` once there are `MIN_RUNS`, else null. */
	public static function p90(times: Array<Float>): Null<Float> {
		if (times.length < MIN_RUNS) return null;
		final sorted: Array<Float> = times.copy();
		sorted.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		return sorted[Math.ceil(PERCENTILE * sorted.length) - 1];
	}

	/**
	 * The time on each size from `min` to `max`: a size in `known` keeps it, the others come from `t(k) = a + b / k` (`a`,
	 * `b` at least 0: a serial and a parallel part) fitted by least squares through every known size, those outside the range
	 * too. Fewer than two known sizes fit nothing: a range they do not cover has no curve (null).
	 */
	public static function curve(known: Map<Int, Float>, min: Int, max: Int): Null<Map<Int, Float>> {
		final out: Map<Int, Float> = [];
		var missing: Bool = false;
		for (size in min ... max + 1) {
			final time: Null<Float> = known[size];
			if (time == null)
				missing = true;
			else
				out[size] = time;
		}
		if (!missing) return out;
		final sizes: Array<Int> = [for (size in known.keys()) size];
		if (sizes.length < 2) return null;
		var sx: Float = 0;
		var st: Float = 0;
		var sxx: Float = 0;
		var sxt: Float = 0;
		for (size in sizes) {
			final x: Float = 1 / size;
			final t: Float = known[size] ?? 0;
			sx += x;
			st += t;
			sxx += x * x;
			sxt += x * t;
		}
		final n: Float = sizes.length;
		final det: Float = n * sxx - sx * sx;
		var b: Float = det == 0 ? 0 : (n * sxt - sx * st) / det;
		var a: Float = (st - b * sx) / n;
		// a time that grows with the threads, or a negative serial part, is noise: one term fits
		if (b < 0) {
			b = 0;
			a = st / n;
		} else if (a < 0) {
			a = 0;
			b = sxt / sxx;
		}
		for (size in min ... max + 1) if (!out.exists(size)) out[size] = a + b / size;
		return out;
	}

	/** `lines` cut to what the file keeps: the newest `RECENT` of every key and size, and of those the newest `MAX_LINES`. */
	public static function bounded(lines: Array<String>): Array<String> {
		final seen: Map<String, Int> = [];
		final kept: Array<String> = [];
		var i: Int = lines.length;
		while (i-- > 0) {
			final fields: Array<String> = lines[i].split('\t');
			final series: String = fields.length == 3 ? '${fields[0]}\t${fields[1]}' : lines[i];
			final count: Int = (seen[series] ?? 0) + 1;
			seen[series] = count;
			if (count <= RECENT) kept.push(lines[i]);
		}
		kept.reverse();
		return kept.slice(-MAX_LINES);
	}

}
