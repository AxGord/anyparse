package dev;

import anyparse.core.PoolLease;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.FixtureCache;
import devkit.Pool;
import devkit.Result;
import devkit.TmpLifecycle;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev mutation-check <manifest>` — every track of a manifest (one deliberate breakage: a patch, an `APQ_TEST` filter and
 * the failures it expects) applied in a job slot, built, run and classified into one verdict row; exits 0 only when every
 * track is KILLED. The slots, their compiler servers and the fixture cache are `docs/testing.md` § "Mutation runs"; one
 * slot's work is `MutationSlot`.
 */
@:nullSafety(Strict)
final class MutationCheck {

	public static inline final USAGE: String = 'usage: dev mutation-check <manifest> [--jobs N] [--keep] [--build-only] [--killer-first] '
		+ '[--schema <dir>] [--base <ref>] [--repo <tree>]';

	/** The prefix `devkit.TmpLifecycle` claims this tool's work directory under, and sweeps it by. */
	private static inline final WORK_PREFIX: String = 'anyparse-mutcheck';

	/** The memory one default job is budgeted, in GiB: a warm compiler server and a suite process. */
	private static inline final GIB_PER_JOB: Int = 5;

	/** The cores a default job count leaves to this process, git and the machine's other work. */
	private static inline final SPARE_CORES: Int = 2;

	private static inline final BYTES_PER_GIB: Float = 1024 * 1024 * 1024;

	/** What one slot may run before it is killed: a slot that outlives a whole sweep is wedged. */
	private static inline final SLOT_TIMEOUT_MS: Int = 24 * 60 * 60 * 1000;

	/** The widths of a report row's verdict, name and filter columns. */
	private static inline final VERDICT_WIDTH: Int = 10;

	private static inline final NAME_WIDTH: Int = 20;
	private static inline final FILTER_WIDTH: Int = 14;

	/** The cells of a timing record: the build kind, its seconds, the suite run's seconds, the run that answered. */
	private static inline final KIND_CELL: Int = 0;

	private static inline final BUILD_CELL: Int = 1;
	private static inline final RUN_CELL: Int = 2;
	private static inline final PHASE_CELL: Int = 3;

	/** A manifest line's fields: name, patch, filter and expectations — the last one keeps any further `|`. */
	private static inline final MANIFEST_FIELDS: Int = 4;

	/** The order a timing line names the build kinds in (`MutationSlot`). */
	private static final BUILD_KINDS: Array<String> = ['warm', 'restarted', 'cold', 'schema'];

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final slot: Null<String> = args.option('--slot');
		if (slot != null) return MutationSlot.run(Std.parseInt(slot) ?? 0, args.positionals(['<workroot>'])[0]);
		final jobs: Null<String> = args.option('--jobs');
		final keep: Bool = args.flag('--keep');
		final buildOnly: Bool = args.flag('--build-only');
		final killerFirst: Bool = args.flag('--killer-first');
		final schema: Null<String> = args.option('--schema');
		final base: Null<String> = args.option('--base');
		final repo: String = Repo.resolve(args.option('--repo'));
		final manifest: String = args.positionals(['<manifest>'])[0];
		return run({
			repo: repo,
			manifest: manifest,
			jobs: jobs,
			keep: keep,
			buildOnly: buildOnly,
			killerFirst: killerFirst,
			schema: schema == null ? null : FileSystem.fullPath(schema),
			base: base ?? 'HEAD'
		});
	}

	/**
	 * Run every track of `job.manifest` and print the report; answers the exit status — 0 when every track is KILLED, 1
	 * when one is not, 2 when the manifest or the options are refused before any track runs.
	 */
	public static function run(job: CheckJob): Int {
		if (!FileSystem.exists(job.manifest)) return refuse(['manifest \'${job.manifest}\' not found']);
		final dir: String = FileSystem.fullPath(Path.directory(job.manifest) == '' ? '.' : Path.directory(job.manifest));
		final rows: Array<TrackRow> = switch parseManifest(File.getContent(job.manifest), job.manifest, dir) {
			case Rows(rows): rows;
			case Refused(why): return refuse([why]);
		};
		if (rows.length == 0) return refuse(['manifest \'${job.manifest}\' has no tracks']);
		final dupes: Array<String> = duplicates([for (row in rows) row.name]);
		if (dupes.length > 0) return refuse(['duplicate track name(s): ${dupes.join(' ')}']);
		final missing: Array<String> = [
			for (row in rows) if (!FileSystem.exists(row.patch)) 'track \'${row.name}\': patch \'${row.patch}\' not found'
		];
		if (missing.length > 0) return refuse(missing);
		final jobs: Int = switch jobsFor(job.jobs, PoolLease.threads(), js.node.Os.cpus().length, js.node.Os.totalmem()) {
			case Count(n, note):
				if (note != null) Sys.stderr().writeString('dev mutation-check: $note\n');
				n;
			case Unusable(why):
				return refuse([why]);
		};
		final dirs: TmpLifecycle = TmpLifecycle.fromEnv();
		final workroot: String = dirs.claimAfterSweep(WORK_PREFIX, job.repo);
		Sys.println('workroot: $workroot');
		final slots: Array<Int> = [];
		final status: Int = try execute(job, rows, Std.int(Math.min(jobs, rows.length)), workroot, slots) catch (exception: Exception) {
			release(job, dirs, workroot, slots, 1);
			throw exception;
		};
		release(job, dirs, workroot, slots, status);
		return status;
	}

	/**
	 * The tracks of a manifest's `text` (read from `manifest`, whose directory `dir` resolves a relative patch path), or
	 * why the first malformed line is refused. A blank line and one whose first non-blank character is `#` are skipped.
	 */
	public static function parseManifest(text: String, manifest: String, dir: String): ManifestParse {
		final rows: Array<TrackRow> = [];
		for (i => line in text.split('\n')) {
			final at: String = '$manifest:${i + 1}';
			if (line.trim() == '' || line.trim().startsWith('#')) continue;
			final fields: Array<String> = line.split('|');
			if (fields.length < MANIFEST_FIELDS) return Refused('$at: expected $MANIFEST_FIELDS \'|\'-separated fields');
			final name: String = fields[0].trim();
			final patch: String = fields[1].trim();
			final filter: String = fields[2].trim();
			if (name == '' || !~/^[A-Za-z0-9_.-]+$/.match(name)) return Refused('$at: bad track name \'$name\' (allowed: A-Za-z0-9_.-)');
			if (patch == '') return Refused('$at: track \'$name\' has no patch file');
			if (filter == '') return Refused('$at: track \'$name\' has an empty APQ_TEST filter (use ALL for the whole suite)');
			rows.push({
				name: name,
				patch: Path.isAbsolute(patch) ? patch : Path.join([dir, patch]),
				filter: filter,
				expected: fields.slice(MANIFEST_FIELDS - 1).join('|').trim()
			});
		}
		return Rows(rows);
	}

	/**
	 * The job slots a machine of `cores` cores and `memory` bytes runs by default: every core but `SPARE_CORES`, at most
	 * one per `GIB_PER_JOB` of memory, at least one. Memory is the binding term on a large machine. Under a pool lease of
	 * `held` threads the lease replaces the cores: the pool, not the machine, says how many processes may run.
	 */
	public static function defaultJobs(cores: Int, memory: Float, ?held: Int): Int {
		final byMemory: Int = Std.int(Math.ffloor(memory / BYTES_PER_GIB) / GIB_PER_JOB);
		return Std.int(Math.max(1, Math.min(held ?? cores - SPARE_CORES, byMemory)));
	}

	/**
	 * The slot count for `asked` (the `--jobs` text) on a machine of `cores` cores and `memory` bytes: the default when
	 * nothing is asked, else the number asked. Under a pool lease of `held` threads no more than `held` slots run, however
	 * many are asked — an ask above the lease is clamped, and says so — so the lease bounds the real processes.
	 */
	public static function jobsFor(asked: Null<String>, held: Null<Int>, cores: Int, memory: Float): JobCount {
		if (asked == null) return Count(defaultJobs(cores, memory, held), null);
		final n: Int = (~/^[0-9]+$/.match(asked) ? Std.parseInt(asked) : null) ?? 0;
		if (n < 1) return Unusable('--jobs must be a positive integer, got \'$asked\'');
		return held != null && n > held
			? Count(held, '--jobs $n exceeds the pool lease of $held thread(s): running $held')
			: Count(n, null);
	}

	/** The report row of one track. */
	public static function reportRow(verdict: String, name: String, filter: String, detail: String): String {
		return '${verdict.rpad(' ', VERDICT_WIDTH)} ${name.rpad(' ', NAME_WIDTH)} filter=${filter.rpad(' ', FILTER_WIDTH)} $detail';
	}

	/**
	 * Where a run's time went, out of each track's timing record (`MutationSlot`: `<build kind> <build s>` and, once its
	 * suite ran, `<run s> <phase>`): per build kind the tracks and their mean build seconds, then the suite runs, their
	 * mean, and how many the killer-first run answered. Null when no track recorded any.
	 */
	public static function timingLine(records: Array<String>): Null<String> {
		final count: Map<String, Int> = [];
		final seconds: Map<String, Float> = [];
		var runs: Int = 0;
		var runSeconds: Float = 0;
		var killers: Int = 0;
		for (record in records) {
			final cells: Array<String> = [for (cell in ~/\s+/g.split(record.trim())) if (cell != '') cell];
			if (cells.length <= BUILD_CELL) continue;
			final kind: String = cells[KIND_CELL];
			count[kind] = (count[kind] ?? 0) + 1;
			seconds[kind] = (seconds[kind] ?? 0) + (Std.parseFloat(cells[BUILD_CELL]) ?? 0);
			if (cells.length > RUN_CELL) {
				runs++;
				runSeconds += Std.parseFloat(cells[RUN_CELL]) ?? 0;
			}
			if (cells.length > PHASE_CELL && cells[PHASE_CELL] == 'killers') killers++;
		}
		if (!count.keys().hasNext()) return null;
		final kinds: Array<String> = BUILD_KINDS.filter(k -> count.exists(k))
			.concat([for (k in count.keys()) if (!BUILD_KINDS.contains(k)) k]);
		final builds: String = [
			for (k in kinds) ' $k builds ${count[k]} (mean ${Math.round((seconds[k] ?? 0) / (count[k] ?? 1))}s),'
		].join('');
		final killerNote: String = killers > 0 ? ', $killers answered killer-first' : '';
		return 'timing:$builds suite runs $runs (mean ${runs == 0 ? 0 : Math.round(runSeconds / runs)}s)$killerNote';
	}

	/** Make the slots, run every track in them and print the report; answers the exit status. */
	private static function execute(job: CheckJob, rows: Array<TrackRow>, jobs: Int, workroot: String, slots: Array<Int>): Int {
		// created one after another: concurrent `git worktree add`s race over `.git/worktrees`
		for (s in 1...jobs + 1) {
			final added: Result = cmd('git -C ${job.repo} worktree add --detach --quiet ${MutationSlot.slotDir(workroot, s)} ${job.base}')
				.run();
			File.saveContent(Path.join([workroot, 'slot-$s.wt.log']), added.err + added.failure);
			if (added.ok) slots.push(s);
		}
		if (slots.length == 0) {
			final why: String = MutationSlot.oneLine(File.getContent(Path.join([workroot, 'slot-1.wt.log'])));
			for (row in rows) MutationSlot.writeVerdict(workroot, row.name, 'WT-FAIL', 'worktree add failed: $why');
		}
		File.saveContent(Path.join([workroot, MutationSlot.ROWS]), [for (row in rows) '${MutationSlot.encodeRow(row)}\n'].join(''));
		File.saveContent(Path.join([workroot, MutationSlot.OWNER]), '${js.Node.process.pid}\n');
		if (job.killerFirst) File.saveContent(Path.join([workroot, MutationSlot.KILLER_FIRST]), '');
		if (job.buildOnly) File.saveContent(Path.join([workroot, MutationSlot.BUILD_ONLY]), '');
		final schema: Null<String> = job.schema;
		if (schema != null) File.saveContent(Path.join([workroot, MutationSlot.SCHEMA]), '$schema\n');
		if (!isSet('APQ_MUTATION_NO_SERVER')) File.saveContent(Path.join([workroot, MutationSlot.SERVERS]), '');
		if (!isSet('APQ_MUTATION_NO_FIXTURE_CACHE') && !job.buildOnly) fixtureCache(job, workroot);
		File.saveContent(Path.join([workroot, MutationSlot.ORDER]), dealOrder(rows, schema).join('\n') + '\n');
		if (slots.length > 0) {
			final devJs: String = FileSystem.fullPath(js.Node.__filename);
			final ran: Array<Result> = Pool.of(slots.length)
				.map(
					slots, s -> Shard.callerGc(cmd('node $devJs mutation-check --slot $s $workroot').tethered().timeout(SLOT_TIMEOUT_MS))
				);
			for (i => result in ran) {
				File.saveContent(Path.join([workroot, 'slot-${slots[i]}.log']), result.out + result.err + result.failure);
				if (!result.ok)
					Sys.stderr().writeString(
						'dev mutation-check: slot ${slots[i]} ended abnormally (${result.firstError()}'
						+ ') — see the per-track verdicts below\n'
					);
			}
		}
		final timing: Null<String> = timingLine([
			for (row in rows) {
				final file: String = Path.join([workroot, '${row.name}.timing']);
				if (FileSystem.exists(file)) File.getContent(file);
			}
		]);
		if (timing != null) Sys.println(timing);
		final tally: Null<String> = FixtureCache.tally(Path.join([workroot, 'fixture-cache/tally']));
		if (tally != null) Sys.println('fixture cache: $tally');
		return report(job, rows, workroot);
	}

	/** Print a row per track and the totals; answers 0 when every track is KILLED (or APPLIES), else 1. */
	private static function report(job: CheckJob, rows: Array<TrackRow>, workroot: String): Int {
		var killed: Int = 0;
		var applies: Int = 0;
		var survived: Int = 0;
		var mismatch: Int = 0;
		var errors: Int = 0;
		for (row in rows) {
			final read: Array<String> = MutationSlot.readVerdict(workroot, row.name);
			switch read[0] {
				case 'KILLED':
					killed++;
				case 'APPLIES':
					applies++;
				case 'SURVIVED':
					survived++;
				case 'MISMATCH':
					mismatch++;
				case _:
					errors++;
			}
			Sys.println(reportRow(read[0], row.name, row.filter, read[1]));
		}
		Sys.println(
			job.buildOnly
				? '${rows.length} tracks: $applies applies, $errors did not build'
				: '${rows.length} tracks: $killed killed, $survived survived, $mismatch mismatch, $errors error'
		);
		final status: Int = survived + mismatch + errors == 0 ? 0 : 1;
		Sys.println(
			!job.keep && status == 0
				? 'workroot: $workroot (removed — every track passed; --keep to keep it)'
				: 'workroot: $workroot (logs and verdicts kept)'
		);
		return status;
	}

	/**
	 * The order the slots take the tracks in: manifest order, a track the composed build (`--schema`) may stand for
	 * last — it waits on that build, and the per-arm builds are the long pole.
	 */
	private static function dealOrder(rows: Array<TrackRow>, schema: Null<String>): Array<String> {
		final names: Array<String> = [for (row in rows) row.name];
		if (schema == null) return names;
		final file: String = Path.join([schema, 'candidates']);
		final candidates: Array<String> = FileSystem.exists(file) ? File.getContent(file).split('\n') : [];
		return names.filter(n -> !candidates.contains(n)).concat(names.filter(n -> candidates.contains(n)));
	}

	/** Prune the fixture-cache store and put its `haxe` shim where the slots look for it; says so when it cannot. */
	private static function fixtureCache(job: CheckJob, workroot: String): Void {
		final home: String = Sys.getEnv('XDG_CACHE_HOME') ?? Path.join([Sys.getEnv('HOME') ?? '', '.cache']);
		final entries: String = nonEmpty(Sys.getEnv('APQ_SUITE_FIXTURE_CACHE')) ?? Path.join([home, 'anyparse/fixture-cache']);
		FixtureCache.prune(entries, FixtureCache.maxAgeDays());
		final cache: String = Path.join([workroot, 'fixture-cache']);
		FileSystem.createDirectory(cache);
		final why: Null<String> =
			try FixtureCache.shim(
				job.repo, entries, Path.join([cache, 'bin']), Path.join([cache, 'tally'])
			) catch (exception: Exception) exception.message;
		if (why != null)
			Sys.stderr()
				.writeString('dev mutation-check: the fixture cache could not be set up ($why) — every fixture compile runs for real\n');
	}

	/**
	 * Remove every slot worktree; remove `workroot` after an all-KILLED run that is not kept, and mark it kept under
	 * `--keep`. Any other run leaves it for the sweep's grace period.
	 */
	private static function release(job: CheckJob, dirs: TmpLifecycle, workroot: String, slots: Array<Int>, status: Int): Void {
		for (s in slots) cmd('git -C ${job.repo} worktree remove --force ${MutationSlot.slotDir(workroot, s)}').run();
		cmd('git -C ${job.repo} worktree prune').run();
		if (!job.keep && status == 0) {
			final refused: Null<String> = dirs.discard(workroot, job.repo);
			if (refused != null) Sys.stderr().writeString('dev mutation-check: $refused\n');
		} else if (job.keep) {
			dirs.markKeep(workroot);
		}
	}

	/** Every name `names` holds more than once, sorted. */
	private static function duplicates(names: Array<String>): Array<String> {
		final seen: Map<String, Int> = [];
		for (name in names) seen[name] = (seen[name] ?? 0) + 1;
		final twice: Array<String> = [for (name => n in seen) if (n > 1) name];
		twice.sort(Reflect.compare);
		return twice;
	}

	/** Print each of `lines` as this tool's refusal; answers the usage-error status. */
	private static function refuse(lines: Array<String>): Int {
		for (line in lines) Sys.stderr().writeString('dev mutation-check: $line\n');
		return 2;
	}

	private static function isSet(name: String): Bool {
		return nonEmpty(Sys.getEnv(name)) != null;
	}

	private static function nonEmpty(value: Null<String>): Null<String> {
		return value == null || value == '' ? null : value;
	}

}

/** One `dev mutation-check` run, as `MutationCheck.run` takes it. */
typedef CheckJob = {
	var repo: String;
	var manifest: String;

	/** The job slots asked for, unparsed; null for the default (`MutationCheck.defaultJobs`). */
	var jobs: Null<String>;

	var keep: Bool;
	var buildOnly: Bool;
	var killerFirst: Bool;

	/** The composed build's directory (`dev mutation-arm`), or null. */
	var schema: Null<String>;

	/** The commit every slot worktree is made from. */
	var base: String;
}

/** One track of a manifest: its name, its patch (an absolute path), its `APQ_TEST` filter and its expectations. */
typedef TrackRow = {
	var name: String;
	var patch: String;
	var filter: String;
	var expected: String;
}

/** The job slots a run takes: their count and a note when an ask was cut down, or why the ask is refused. */
enum JobCount {
	Count(n: Int, note: Null<String>);
	Unusable(why: String);
}

/** A manifest read: its tracks, or why a line of it is refused. */
enum ManifestParse {
	Rows(rows: Array<TrackRow>);
	Refused(why: String);
}
