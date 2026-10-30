package dev;

import dev.SliceMeasure.EdgeReading;
import dev.SliceMeasure.EdgeShare;
import devkit.Args;
import devkit.Cmd.cmd;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev slice-stats` — whether improving the project gets easier, read deterministically from git: every slice landed on the
 * first-parent history of a revision (a merge of a `batch/hxqb-<ID>` branch, or a commit carrying the `Slice` trailer `dev
 * land` writes) is one row, and the rows are summed by week. A row's time runs from the first authored commit of the slice
 * to its landing; its review rounds and tokens are the trailers `dev land --rounds/--tokens` writes, else the
 * `review-rounds: N` / `tokens: N` fields of its line in the `--queue` file. `--edges` and `--clones` add what each
 * revision's own sources say (`SliceMeasure`).
 */
@:nullSafety(Strict)
final class SliceStats {

	public static inline final USAGE: String = 'usage: dev slice-stats [--since <date>] [--rev <rev>] [--queue <file>] [--edges] '
		+ '[--clones] [--roots <dir>[,<dir>]...] [--cache <dir>] [--repo <tree>]';

	/** What separates the fields of one `git log` record, and the records. */
	private static inline final FIELD: String = '\x1f';

	private static inline final RECORD: String = '\x1e';
	private static inline final SECONDS_PER_HOUR: Float = 3600;
	private static inline final SECONDS_PER_DAY: Int = 86400;
	private static inline final DAYS_PER_WEEK: Int = 7;

	/** Days from a Monday to 1970-01-01, a Thursday. */
	private static inline final EPOCH_WEEKDAY: Int = 3;

	private static inline final PERCENT: Float = 100;
	private static inline final THOUSAND: Float = 1000;

	/** The length of `YYYY-MM-DD`, the day an ISO time starts with. */
	private static inline final ISO_DAY_LENGTH: Int = 10;

	/** The text of an unknown value in a table. */
	private static inline final NONE: String = '-';

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		final since: Null<String> = args.option('--since');
		final rev: String = args.option('--rev') ?? 'HEAD';
		final queue: Null<String> = args.option('--queue');
		final edges: Bool = args.flag('--edges');
		final clones: Bool = args.flag('--clones');
		final roots: Array<String> = (args.option('--roots') ?? SliceMeasure.DEFAULT_ROOTS).split(',').filter(r -> r != '');
		final cache: String = args.option('--cache') ?? SliceMeasure.defaultCache();
		args.done();
		final queueText: Null<String> = queue == null ? null : File.getContent(queue);
		final measure: Null<SliceMeasure> = edges || clones ? new SliceMeasure(repo, roots, cache) : null;
		final rows: Array<SliceRow> = [
			for (landing in landings(repo, rev, since)) rowOf(repo, withQueue(landing, queueText), measure, edges, clones)
		];
		Sys.println(sliceTable(rows, edges, clones));
		Sys.println('');
		Sys.println(trendTable(trend(rows), edges, clones));
		return 0;
	}

	/** The slices landed on the first-parent history of `rev` (since `since`, as `git log --since` reads it), oldest first. */
	public static function landings(repo: String, rev: String, since: Null<String>): Array<Landing> {
		final format: String = logFormat();
		final window: Array<String> = since == null ? [] : ['--since=$since'];
		final out: Array<Landing> = parseLog(cmd('git -C $repo log --first-parent --format=$format $window $rev').check().out);
		for (landing in out) {
			final authored: Array<Float> = [
				for (line in cmd('git -C $repo log --format=%at ${landing.branch}').check().lines()) Std.parseFloat(line)
			];
			for (at in authored) if (at < landing.started) landing.started = at;
		}
		return out;
	}

	/** The landings of the `git log` output `out` in `logFormat`, oldest first; each starts when it landed until its branch is read. */
	public static function parseLog(out: String): Array<Landing> {
		final found: Array<Landing> = [];
		for (record in out.split(RECORD)) {
			final fields: Array<String> = record.trim().split(FIELD);
			if (fields.length < 7) continue;
			final landing: Null<Landing> = landingOf(fields);
			if (landing != null) found.unshift(landing);
		}
		return found;
	}

	/**
	 * The landing one `git log` record spells, or null when the commit lands no slice: a merge whose subject names a
	 * `batch/hxqb-<ID>` branch (`Merge batch/hxqb-<ID>: …`, `Merge branch 'batch/hxqb-<ID>'`), or a single-parent commit
	 * carrying a `Slice` trailer.
	 */
	public static function landingOf(fields: Array<String>): Null<Landing> {
		final commit: String = fields[0];
		final parents: Array<String> = fields[1].split(' ').filter(p -> p != '');
		final landed: Float = Std.parseFloat(fields[2]);
		final merge: EReg = ~/^merge (?:branch ')?(batch\/hxqb-[^\s:']+)/i;
		final slice: String = fields[4].split(',')[0].trim();
		final id: Null<String> = if (parents.length == 2 && merge.match(fields[3]))
			Land.sliceId(merge.matched(1))
		else if (parents.length == 1 && slice != '')
			slice
		else
			null;
		return id == null ? null : {
			id: id,
			commit: commit,
			base: parents[0],
			branch: parents.length == 2 ? '${parents[0]}..${parents[1]}' : '${parents[0]}..$commit',
			landed: landed,
			started: landed,
			rounds: count(fields[5]),
			tokens: count(fields[6])
		};
	}

	/** `landing` with the rounds and tokens its trailers lack taken from its line in the queue text `queue`, if any. */
	public static function withQueue(landing: Landing, queue: Null<String>): Landing {
		if (queue == null || landing.rounds != null && landing.tokens != null) return landing;
		final head: String = '] ${landing.id} ';
		for (line in queue.split('\n')) if (line.startsWith('- [') && line.indexOf(head) == '- [x'.length) {
			final rounds: EReg = ~/review-rounds:\s*([0-9][0-9_]*)/;
			final tokens: EReg = ~/(?:^|[^-])tokens:\s*([0-9][0-9_]*)/;
			if (landing.rounds == null && rounds.match(line)) landing.rounds = count(rounds.matched(1));
			if (landing.tokens == null && tokens.match(line)) landing.tokens = count(tokens.matched(1));
			break;
		}
		return landing;
	}

	/** The added and deleted lines under `src/` and `test/` of `git diff --numstat` output lines. */
	public static function lineCounts(numstat: Array<String>): LineCounts {
		final src: LineCount = { added: 0, deleted: 0 };
		final test: LineCount = { added: 0, deleted: 0 };
		for (line in numstat) {
			final cells: Array<String> = line.split('\t');
			if (cells.length < 3) continue;
			final into: Null<LineCount> = if (cells[2].startsWith('src/'))
				src
			else if (cells[2].startsWith('test/'))
				test
			else
				null;
			if (into == null) continue;
			into.added += Std.parseInt(cells[0]) ?? 0;
			into.deleted += Std.parseInt(cells[1]) ?? 0;
		}
		return { src: src, test: test };
	}

	/** The `.hx` modules `git diff --name-status` output lines add, and those they edit — a rename is an edit. */
	public static function moduleCounts(nameStatus: Array<String>): ModuleCounts {
		var fresh: Int = 0;
		var edited: Int = 0;
		for (line in nameStatus) {
			final cells: Array<String> = line.split('\t');
			if (!cells[cells.length - 1].endsWith('.hx')) continue;
			switch line.charAt(0) {
				case 'A':
					fresh++;
				case 'M', 'R':
					edited++;
				case _:
			}
		}
		return { fresh: fresh, edited: edited };
	}

	/** The Monday (UTC) of the week the time `seconds` since the epoch falls in, as `YYYY-MM-DD`. */
	public static function weekOf(seconds: Float): String {
		final day: Int = Math.floor(seconds / SECONDS_PER_DAY);
		final monday: Int = day - ((day + EPOCH_WEEKDAY) % DAYS_PER_WEEK + DAYS_PER_WEEK) % DAYS_PER_WEEK;
		return dayOf(monday * SECONDS_PER_DAY);
	}

	/** The rows summed by the week each landed in, oldest week first. */
	public static function trend(rows: Array<SliceRow>): Array<WeekRow> {
		final weeks: Array<WeekRow> = [];
		final hours: Map<String, Array<Float>> = [];
		final rounds: Map<String, Array<Int>> = [];
		for (row in rows) {
			final key: String = weekOf(row.landing.landed);
			var week: Null<WeekRow> = weeks.length > 0 && weeks[weeks.length - 1].week == key ? weeks[weeks.length - 1] : null;
			if (week == null) {
				week = {
					week: key,
					slices: 0,
					hours: 0,
					rounds: null,
					tokens: null,
					src: 0,
					test: 0,
					fresh: 0,
					edited: 0,
					edges: null,
					clones: null
				};
				weeks.push(week);
				hours[key] = [];
				rounds[key] = [];
			}
			week.slices++;
			hours[key]?.push(row.hours);
			final r: Null<Int> = row.landing.rounds;
			if (r != null) rounds[key]?.push(r);
			final t: Null<Int> = row.landing.tokens;
			if (t != null) week.tokens = (week.tokens ?? 0) + t;
			week.src += row.src.added;
			week.test += row.test.added;
			week.fresh += row.fresh;
			week.edited += row.edited;
			final e: Null<EdgeShare> = row.edges;
			if (e != null) {
				final sum: EdgeShare = week.edges ?? { added: 0, existing: 0, fresh: 0 };
				sum.added += e.added;
				sum.existing += e.existing;
				sum.fresh += e.fresh;
				week.edges = sum;
			}
			final c: Null<Int> = row.clones;
			if (c != null) week.clones = (week.clones ?? 0) + c;
		}
		for (week in weeks) {
			week.hours = median(hours[week.week] ?? []);
			final known: Array<Int> = rounds[week.week] ?? [];
			if (known.length > 0) week.rounds = known.fold((r, sum) -> sum + r, 0) / known.length;
		}
		return weeks;
	}

	/** One line per slice: its id, landing day, hours, rounds, tokens, lines, modules, and the readings asked for. */
	public static function sliceTable(rows: Array<SliceRow>, edges: Bool, clones: Bool): String {
		final header: Array<String> = [
			'slice',
			'landed',
			'hours',
			'rounds',
			'tokens',
			'src +/-',
			'test +/-',
			'new/edited'
		];
		if (edges) header.push('edges ->old');
		if (clones) header.push('dup');
		final cells: Array<Array<String>> = [
			for (row in rows) {
				final line: Array<String> = [
					row.landing.id,
					dayOf(row.landing.landed),
					decimal(row.hours),
					optional(row.landing.rounds),
					thousands(row.landing.tokens),
					'+${row.src.added}/-${row.src.deleted}',
					'+${row.test.added}/-${row.test.deleted}',
					'${row.fresh}/${row.edited}'
				];
				if (edges) line.push(edgeCell(row.edges));
				if (clones) line.push(signed(row.clones));
				line;
			}
		];
		return render(header, cells);
	}

	/** One line per week: slices, median hours, mean rounds, tokens, lines added, modules, and the readings asked for. */
	public static function trendTable(weeks: Array<WeekRow>, edges: Bool, clones: Bool): String {
		final header: Array<String> = [
			'week',
			'slices',
			'median h',
			'rounds',
			'tokens',
			'src +',
			'test +',
			'new/edited'
		];
		if (edges) header.push('edges ->old');
		if (clones) header.push('dup');
		final cells: Array<Array<String>> = [
			for (week in weeks) {
				final rounds: Null<Float> = week.rounds;
				final line: Array<String> = [
					week.week,
					'${week.slices}',
					decimal(week.hours),
					rounds == null ? NONE : decimal(rounds),
					thousands(week.tokens),
					'${week.src}',
					'${week.test}',
					'${week.fresh}/${week.edited}'
				];
				if (edges) line.push(edgeCell(week.edges));
				if (clones) line.push(signed(week.clones));
				line;
			}
		];
		return render(header, cells);
	}

	/** The day (UTC) the time `seconds` since the epoch falls in, as `YYYY-MM-DD`. */
	public static function dayOf(seconds: Float): String {
		return new js.lib.Date(seconds * THOUSAND).toISOString().substr(0, ISO_DAY_LENGTH);
	}

	/** `value` with one decimal digit. */
	private static inline function decimal(value: Float): String {
		return js.Syntax.code('{0}.toFixed(1)', value);
	}

	/** The `git log` format `parseLog` reads: hash, parents, commit time, subject and the `Slice`, rounds and tokens trailers. */
	private static function logFormat(): String {
		final trailer: String -> String = key -> '%(trailers:key=$key,valueonly,separator=%x2C)';
		return [
			'%H',
			'%P',
			'%ct',
			'%s',
			trailer('Slice'),
			trailer(Land.ROUNDS_TRAILER),
			trailer(Land.TOKENS_TRAILER)
		].join('%x1f')
			+ '%x1e';
	}

	/** The row of `landing`: its time, its lines and modules against its base, and the readings asked for. */
	private static function rowOf(repo: String, landing: Landing, measure: Null<SliceMeasure>, edges: Bool, clones: Bool): SliceRow {
		final range: Array<String> = [landing.base, landing.commit];
		final lines: LineCounts = lineCounts(cmd('git -C $repo diff --numstat -M $range -- src test').check().lines());
		final modules: ModuleCounts = moduleCounts(cmd('git -C $repo diff --name-status -M $range').check().lines());
		var share: Null<EdgeShare> = null;
		var dup: Null<Int> = null;
		if (measure != null) {
			if (edges) {
				final before: EdgeReading = measure.edges(landing.base);
				share = SliceMeasure.share(before, measure.edges(landing.commit));
			}
			if (clones) dup = measure.clones(landing.commit) - measure.clones(landing.base);
		}
		return {
			landing: landing,
			hours: (landing.landed - landing.started) / SECONDS_PER_HOUR,
			src: lines.src,
			test: lines.test,
			fresh: modules.fresh,
			edited: modules.edited,
			edges: share,
			clones: dup
		};
	}

	/** The first count of a trailer's values, or a queue field's (`1_234` reads as `1234`); null when there is none. */
	private static function count(text: String): Null<Int> {
		final digits: String = text.split(',')[0].replace('_', '').trim();
		return digits == '' ? null : Std.parseInt(digits);
	}

	private static function median(values: Array<Float>): Float {
		if (values.length == 0) return 0;
		final sorted: Array<Float> = values.copy();
		sorted.sort(Reflect.compare);
		final mid: Int = sorted.length >> 1;
		return sorted.length % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
	}

	private static function optional(value: Null<Int>): String {
		return value == null ? NONE : '$value';
	}

	private static function thousands(value: Null<Int>): String {
		return value == null ? NONE : '${Math.round(value / THOUSAND)}k';
	}

	private static function signed(value: Null<Int>): String {
		return if (value == null)
			NONE
		else if (value > 0)
			'+$value'
		else
			'$value';
	}

	/** The edges a slice added and the share of those landing inside the roots that land in a module its base held. */
	private static function edgeCell(share: Null<EdgeShare>): String {
		if (share == null) return NONE;
		final inside: Int = share.existing + share.fresh;
		return inside == 0 ? '${share.added} ${NONE}' : '${share.added} ${Math.round(share.existing * PERCENT / inside)}%';
	}

	/** `cells` under `header`, each column as wide as its widest cell, the first left-aligned and the rest right-aligned. */
	private static function render(header: Array<String>, cells: Array<Array<String>>): String {
		final all: Array<Array<String>> = [header].concat(cells);
		final widths: Array<Int> = [for (_ in header) 0];
		for (row in all) for (i => cell in row) if (cell.length > widths[i]) widths[i] = cell.length;
		return [
			for (row in all) [
				for (i => cell in row) i == 0 ? cell.rpad(' ', widths[i]) : cell.lpad(' ', widths[i])
			].join('  ').rtrim()
		].join('\n');
	}

}

/** One slice landed on the history: its id, the landing commit and its base, its branch's range, and its markers. */
typedef Landing = {
	var id: String;
	var commit: String;
	var base: String;

	/** The slice's own commits as a revision range: the landing commit alone for a linear landing. */
	var branch: String;

	/** When the landing was committed and when the slice's first commit was authored, in seconds since the epoch. */
	var landed: Float;

	var started: Float;
	var rounds: Null<Int>;
	var tokens: Null<Int>;
}

/** The lines a slice added and deleted under one root. */
typedef LineCount = {
	var added: Int;
	var deleted: Int;
}

/** The lines a slice added and deleted under `src/` and under `test/`. */
typedef LineCounts = {
	var src: LineCount;
	var test: LineCount;
}

/** The `.hx` modules a slice added, and those it edited. */
typedef ModuleCounts = {
	var fresh: Int;
	var edited: Int;
}

/** The reading of one landed slice. */
typedef SliceRow = {
	var landing: Landing;
	var hours: Float;
	var src: LineCount;
	var test: LineCount;

	/** The `.hx` modules the slice added, and those it edited. */
	var fresh: Int;

	var edited: Int;
	var edges: Null<EdgeShare>;

	/** How the duplicate-code findings moved, added minus removed. */
	var clones: Null<Int>;
}

/** The slices landed in one week, summed: hours as their median, rounds as their mean, the rest as totals. */
typedef WeekRow = {
	/** The Monday the week starts on. */
	var week: String;

	var slices: Int;
	var hours: Float;
	var rounds: Null<Float>;
	var tokens: Null<Int>;
	var src: Int;
	var test: Int;
	var fresh: Int;
	var edited: Int;
	var edges: Null<EdgeShare>;
	var clones: Null<Int>;
}
