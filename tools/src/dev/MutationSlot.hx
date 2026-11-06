package dev;

import anyparse.check.oracle.HaxeSpawn;
import anyparse.query.BuildFailure;
import anyparse.query.Cli.TestSummaryResult;
import anyparse.query.MutationVerdict;
import anyparse.query.cli.TestTranscript;
import dev.MutationCheck.TrackRow;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.FixtureCache;
import devkit.NarrowBuild;
import devkit.Pool;
import devkit.Result;
import haxe.Exception;
import haxe.crypto.Md5;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * One job slot of a `dev mutation-check` run (`--slot <n> <workroot>`): a worktree of its own and, unless the run says
 * otherwise, one warm `haxe --wait` server, taking the run's tracks in deal order until none is left. A track resets the
 * slot to the base, applies its patch, builds (or switches the composed build's arm on), runs its tests and leaves its
 * verdict in the workroot, where the parent's report reads it. A killer-first track first tries a narrow build of its
 * pinned classes alone and takes the full build only when that does not settle it. The verdict comes from `MutationVerdict` in THIS
 * process, built from the unmutated tree: a track's own build is compiled from the mutated source.
 */
@:nullSafety(Strict)
final class MutationSlot {

	/** The workroot's files the parent writes for its slots. */
	public static inline final ROWS: String = 'rows';

	public static inline final ORDER: String = 'order';

	/** The pid every slot follows: a slot whose parent is gone takes no further track. */
	public static inline final OWNER: String = 'owner';

	public static inline final KILLER_FIRST: String = 'killer-first';
	public static inline final BUILD_ONLY: String = 'build-only';
	public static inline final SCHEMA: String = 'schema';

	/** Present when the slots keep compiler servers. */
	public static inline final SERVERS: String = 'servers';

	/** The environment variable naming the file a slot rewrites as each track ends: a gate's sign of life for the arms row. */
	public static inline final PROGRESS_VAR: String = 'APQ_ARMS_PROGRESS';

	/** The directory a slot claims a track in, one `mkdir` per track: the first slot to make it runs it. */
	private static inline final CLAIMS: String = 'claims';

	/** Seconds a warm build may take before its server counts as hung, unless `APQ_MUTATION_BUILD_TIMEOUT` says otherwise. */
	private static inline final BUILD_TIMEOUT_S: Int = 300;

	/** The slices a killer-first track's fallback run is dealt into, unless `APQ_MUTATION_FALLBACK_SLICES` says otherwise. */
	private static inline final FALLBACK_SLICES: Int = 4;

	/** What one suite run may take before it is killed. */
	private static inline final SUITE_TIMEOUT_MS: Int = 2 * 60 * 60 * 1000;

	/** How often a track the composed build may stand for looks whether that build has answered. */
	private static inline final SCHEMA_POLL_MS: Int = 2000;

	private static inline final MS_PER_SECOND: Int = 1000;

	/** The verdict of a track that produced no usable transcript. */
	private static inline final RUN_FAIL: String = 'RUN-FAIL';

	/** The environment variable a suite run's compiler shim goes first on. */
	private static inline final PATH: String = 'PATH';

	/** The environment variable that turns the narrow build off, so every track takes the full build. */
	private static inline final NO_NARROW: String = 'APQ_MUTATION_NO_NARROW';

	private static final TEST_JS: String = 'test.js';

	/** Block this thread for `ms` milliseconds without spawning anything. */
	public static inline function pause(ms: Int): Void {
		js.Syntax.code('Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, {0})', ms);
	}

	/**
	 * Whether a track may try a narrow build: only under killer-first, never in a build-only run — `--check-apply` asks
	 * whether the WHOLE tree compiles, which a narrow build cannot answer — and not when `off` (`APQ_MUTATION_NO_NARROW`) is set.
	 */
	public static inline function narrows(killerFirst: Bool, buildOnly: Bool, off: Null<String>): Bool {
		return killerFirst && !buildOnly && (off ?? '') == '';
	}

	/** Take tracks in deal order until none is left or the parent is gone; always answers 0 (a verdict is a file). */
	public static function run(slot: Int, workroot: String): Int {
		final rows: Array<TrackRow> = decodeRows(File.getContent(Path.join([workroot, ROWS])));
		final order: Array<String> = File.getContent(Path.join([workroot, ORDER])).split('\n').filter(n -> n != '');
		final owner: Null<Int> = Std.parseInt(File.getContent(Path.join([workroot, OWNER])).trim());
		final schema: Null<String> = FileSystem.exists(Path.join([workroot, SCHEMA]))
			? File.getContent(Path.join([workroot, SCHEMA])).trim()
			: null;
		final slotCtx: SlotContext = {
			workroot: workroot,
			slot: slot,
			wt: slotDir(workroot, slot),
			server: FileSystem.exists(Path.join([workroot, SERVERS])) ? new SlotServer(workroot, slot) : null,
			buildOnly: FileSystem.exists(Path.join([workroot, BUILD_ONLY])),
			killerFirst: FileSystem.exists(Path.join([workroot, KILLER_FIRST])),
			schema: schema
		};
		if (!FileSystem.exists(Path.join([workroot, CLAIMS])))
			try js.node.Fs.mkdirSync(Path.join([workroot, CLAIMS])) catch (exception: Exception) { // noqa: swallowed-exception
				// another slot made it first
			}
		for (name in order) {
			if (owner != null && !alive(owner)) break;
			if (!claim(workroot, name)) continue;
			final row: Null<TrackRow> = rows.find(r -> r.name == name);
			if (row == null) {
				writeVerdict(workroot, name, RUN_FAIL, 'track \'$name\' vanished between the parent\'s parse and this slot\'s');
				continue;
			}
			try {
				track(slotCtx, row);
			} catch (exception: Exception) {
				writeVerdict(workroot, name, RUN_FAIL, 'slot $slot failed on it: ${oneLine(exception.message)}');
			}
		}
		slotCtx.server?.stop();
		return 0;
	}

	/** The worktree of slot `s`. */
	public static function slotDir(workroot: String, s: Int): String {
		return Path.join([workroot, 'slot-$s']);
	}

	/** `row` as one line of the workroot's rows file. */
	public static function encodeRow(row: TrackRow): String {
		return [row.name, row.patch, row.filter, row.expected].join('\t');
	}

	/** The rows file `text`, as `encodeRow` wrote it. */
	public static function decodeRows(text: String): Array<TrackRow> {
		return [
			for (line in text.split('\n')) if (line != '') {
				final cells: Array<String> = line.split('\t');
				{
					name: cells[0],
					patch: cells[1] ?? '',
					filter: cells[2] ?? '',
					expected: cells[3] ?? ''
				};
			}
		];
	}

	/**
	 * Leave `verdict` and its `detail` as track `name`'s answer, and say so in the file `PROGRESS_VAR` names when it names one: a
	 * gate watching this run for silence sees each track end.
	 */
	public static function writeVerdict(workroot: String, name: String, verdict: String, detail: String): Void {
		File.saveContent(Path.join([workroot, '$name.verdict']), '$verdict\n$detail\n');
		final progress: String = Sys.getEnv(PROGRESS_VAR) ?? '';
		if (progress != '') File.saveContent(progress, 'arms: $name $verdict');
	}

	/** Track `name`'s verdict and detail; `RUN-FAIL` when it left none. */
	public static function readVerdict(workroot: String, name: String): Array<String> {
		final file: String = Path.join([workroot, '$name.verdict']);
		if (!FileSystem.exists(file)) return [RUN_FAIL, 'no verdict written'];
		final lines: Array<String> = File.getContent(file).split('\n');
		return [lines[0], lines[1] ?? ''];
	}

	/** `text` on one line, each line break a space — how a log is quoted in a verdict detail. */
	public static function oneLine(text: String): String {
		return text.split('\n').join(' ');
	}

	/**
	 * The `APQ_TEST` value running exactly the tests that can answer the expectations `expected` (comma-separated):
	 * `test:<e>` selects every test whose `<fq.Class>.<method>` contains `<e>`, the substring rule `MutationVerdict`
	 * matches an expectation by. Such a run holds every test that can match an expectation and nothing else, so an
	 * expectation is matched there exactly when it is matched in the filtered run.
	 */
	public static function killerTokens(expected: String): String {
		return [for (e in expected.split(',')) if (e.trim() != '') 'test:${e.ltrim()}'.rtrim()].join(',');
	}

	/**
	 * Whether a killer-first reading `c` answers the verdict for the filtered run: KILLED, or a MISMATCH that matched at
	 * least one of `expected`. A run that matched none leaves the filtered run's own question open — green, or red only
	 * among tests this run left out.
	 */
	public static function matchedAny(c: Classified, expected: String): Bool {
		if (c.verdict == 'KILLED') return true;
		if (c.verdict != 'MISMATCH') return false;
		final missing: EReg = ~/^.*\(missing: (.*)\)$/;
		if (!missing.match(c.full ?? c.detail)) return false;
		final named: String = missing.matched(1);
		return named != '' && named.split(', ').length < expected.split(',').length;
	}

	/**
	 * The `APQ_TEST` value of each of `slices` slices of the filtered run `filter` (`<class>#<i>/<k>` for every class),
	 * whose union is that run; null when `filter` is not a plain class list.
	 */
	public static function fallbackTokens(filter: String, slices: Int): Null<Array<String>> {
		return filter == '' || filter == 'ALL' || filter.indexOf('#') >= 0 || filter.indexOf('test:') >= 0 ? null : [
			for (i in 0...slices) [for (cls in filter.split(',')) '$cls#$i/$slices'].join(',')
		];
	}

	/** The transcripts `logs` — the slices of one run when there are several — classified against `expected`. */
	public static function classify(expected: String, logs: Array<String>): Classified {
		final want: Array<String> = [for (e in expected.split(',')) if (e.trim() != '') e.trim()];
		final parsed: Array<TestSummaryResult> = [for (log in logs) TestTranscript.parseTestSummary(File.getContent(log))];
		final result: MutationVerdictResult = MutationVerdict.classify(
			parsed.length == 1 ? parsed[0] : MutationVerdict.merge(parsed), want
		);
		return { verdict: MutationVerdict.label(result.kind), detail: result.detail, full: result.full };
	}

	/** The report cell naming why the build whose log is `log` failed, out of `BuildFailure`; the log's path when unreadable. */
	public static function buildDetail(log: String): String {
		final text: Null<String> = try File.getContent(log) catch (exception: Exception) null;
		if (text == null) return log;
		final failure: BuildFailureResult = BuildFailure.classify(text);
		return '${BuildFailure.label(failure.cause)} | ${failure.line} ($log)';
	}

	/** Whether the process `pid` exists; one this process may not signal still does. */
	public static function alive(pid: Int): Bool {
		return try {
			js.Syntax.code('process.kill({0}, 0)', pid);
			true;
		} catch (exception: Exception) {
			Reflect.field(exception.native, 'code') == 'EPERM';
		};
	}

	/**
	 * The test classes `expected` names, each once and sorted: an expectation is a class `isClass` answers for, or a
	 * `<class>.<method>` whose class it answers for. Null when an expectation names neither or none is given: such a
	 * track has no narrow build.
	 */
	public static function narrowClasses(expected: String, isClass: String -> Bool): Null<Array<String>> {
		final classes: Array<String> = [];
		for (entry in expected.split(',')) {
			final want: String = entry.trim();
			if (want == '') continue;
			final dot: Int = want.lastIndexOf('.');
			// a bare name has no owner: `substr(0, -1)` would read as the name minus its last character
			final owner: String = dot > 0 ? want.substr(0, dot) : '';
			final cls: Null<String> = if (isClass(want))
				want
			else if (owner != '' && isClass(owner))
				owner
			else
				null;
			if (cls == null) return null;
			if (!classes.contains(cls)) classes.push(cls);
		}
		if (classes.length == 0) return null;
		classes.sort(Reflect.compare);
		return classes;
	}

	/**
	 * Whether a narrow build's `reading` settles a track expecting `expected`: only a kill does, and only when the same
	 * classes all passed in a narrow build of the unmutated tree (`base`), since a class that fails outside the full
	 * registry would read as a kill.
	 */
	public static function takesNarrowKill(reading: Null<Classified>, expected: String, base: String): Bool {
		return reading != null && matchedAny(reading, expected) && base == 'SURVIVED';
	}

	/** One track in this slot, its verdict left in the workroot. */
	private static function track(ctx: SlotContext, row: TrackRow): Void {
		final workroot: String = ctx.workroot;
		final name: String = row.name;
		if (!prepare(ctx, row)) return;
		final started: Float = Sys.time();
		final mutant: Null<String> = schemaArm(ctx, name);
		if (mutant == null && narrowTrack(ctx, row)) return;
		final buildLog: String = Path.join([workroot, '$name.build.log']);
		final own: String = Path.join([workroot, 'build-$name']);
		final kind: Null<String> = mutant != null ? 'schema' : buildTrack(ctx, own, buildLog);
		if (kind == null) {
			writeVerdict(workroot, name, 'BUILD-FAIL', buildDetail(buildLog));
			return;
		}
		// candidates are dealt last, so a slot that reaches one is done building: its server's memory goes back
		if (mutant != null) ctx.server?.stop();
		final built: Float = Sys.time();
		final timing: String = Path.join([workroot, '$name.timing']);
		if (ctx.buildOnly) {
			File.saveContent(timing, '$kind ${seconds(started, built)}\n');
			writeVerdict(workroot, name, 'APPLIES', 'the patched tree compiles');
			return;
		}
		final log: String = Path.join([workroot, '$name.log']);
		final testJs: String = Path.join([mutant != null ? ctx.schema ?? own : own, TEST_JS]);
		final ran: SuiteRun = runTests(ctx, row, suiteCommand(ctx, testJs, mutant), log);
		File.saveContent(timing, '$kind ${seconds(started, built)} ${seconds(built, Sys.time())} ${ran.phase}\n');
		final reading: Null<Classified> = ran.reading;
		if (reading == null) {
			writeVerdict(workroot, name, RUN_FAIL, 'classifier aborted on ${ran.read}');
			return;
		}
		settle(workroot, name, log, reading);
	}

	/**
	 * The track's private `test.js` in `build`, through the slot's warm server when there is one; answers how it was
	 * built (`warm`, `restarted`, `cold`), or null when it does not build. A server answer is trusted only as a SUCCESS:
	 * a failed warm build is repeated through a fresh server, and a second failure cold, whose log is the verdict's.
	 */
	private static function buildTrack(ctx: SlotContext, build: String, log: String): Null<String> {
		FileSystem.createDirectory(build);
		final out: String = Path.join([build, TEST_JS]);
		final server: Null<SlotServer> = ctx.server;
		if (server != null) for (attempt in ['warm', 'restarted']) {
			final port: Null<Int> = server.port(ctx.wt);
			if (port == null) break;
			final warm: Result = cmd('haxe --connect 127.0.0.1:$port test-js-common.hxml ${Binaries.CODEGEN} -js $out')
				.at(ctx.wt)
				.timeout(buildTimeoutMs())
				.run();
			saveLog(log, warm);
			if (warm.ok) {
				server.recycleIfLarge();
				return attempt;
			}
			server.stop();
			FileSystem.rename(log, '$log.$attempt');
		}
		final cold: Result = cmd('haxe test-js-common.hxml ${Binaries.CODEGEN} -js $out').at(ctx.wt).run();
		saveLog(log, cold);
		return cold.ok ? 'cold' : null;
	}

	/**
	 * The arm id of track `name` when the composed build (`--schema`) stands for it, else null. A candidate waits here
	 * until the build answered; one it left out, or every candidate of a build that failed, is built per arm.
	 */
	private static function schemaArm(ctx: SlotContext, name: String): Null<String> {
		final dir: Null<String> = ctx.schema;
		if (dir == null) return null;
		final candidates: String = Path.join([dir, 'candidates']);
		if (!FileSystem.exists(candidates) || !File.getContent(candidates).split('\n').contains(name)) return null;
		final state: String = Path.join([dir, 'state']);
		while (!FileSystem.exists(state)) pause(SCHEMA_POLL_MS);
		if (File.getContent(state).trim() != 'ready') return null;
		for (line in File.getContent(Path.join([dir, 'map'])).split('\n')) {
			final cells: Array<String> = line.split(' ');
			if (cells.length >= 2 && cells[0] == name) return cells[1];
		}
		return null;
	}

	/** Whether this slot takes track `name`: the first slot to make its claim directory does. */
	private static function claim(workroot: String, name: String): Bool {
		return try {
			js.node.Fs.mkdirSync(Path.join([workroot, CLAIMS, name]));
			true;
		} catch (exception: Exception) {
			false;
		};
	}

	/** A run's transcript as one file: its stdout, its stderr, and why it gave no exit status when it gave none. */
	private static function saveLog(file: String, result: Result): Void {
		File.saveContent(file, transcript(result));
	}

	private static function transcript(result: Result): String {
		return result.out + result.err + (result.failure == '' ? '' : '${result.failure}\n');
	}

	/** Whole seconds from `from` to `to`. */
	private static function seconds(from: Float, to: Float): Int {
		return Std.int(to - from);
	}

	/** The positive integer the environment variable `name` holds, else `fallback`. */
	private static function envInt(name: String, fallback: Int): Int {
		final value: Null<Int> = Std.parseInt(Sys.getEnv(name) ?? '');
		return value != null && value > 0 ? value : fallback;
	}

	/**
	 * Reset the slot to the base and apply `row`'s patch; false, the track's verdict left, when either fails. git rewrites
	 * only the files that differ, so every other file keeps the mtime the slot's server cached it under.
	 */
	private static function prepare(ctx: SlotContext, row: TrackRow): Bool {
		final reset: Result = cmd('git -C ${ctx.wt} reset --hard -q').run();
		final clean: Null<Result> = reset.ok ? cmd('git -C ${ctx.wt} clean -fdxq').run() : null;
		final wtLog: String = Path.join([ctx.workroot, '${row.name}.wt.log']);
		File.saveContent(wtLog, transcript(reset) + (clean == null ? '' : transcript(clean)));
		if (clean == null || !clean.ok) {
			writeVerdict(ctx.workroot, row.name, 'WT-FAIL', 'slot ${ctx.slot} could not be reset: ${oneLine(File.getContent(wtLog))}');
			return false;
		}
		// `--` so a patch path beginning with `-` is a path
		final applied: Result = cmd('git -C ${ctx.wt} apply -- ${row.patch}').run();
		File.saveContent(Path.join([ctx.workroot, '${row.name}.apply.log']), applied.err + applied.failure);
		if (applied.ok) return true;
		writeVerdict(ctx.workroot, row.name, 'PATCH-FAIL', oneLine(applied.err + applied.failure));
		return false;
	}

	/**
	 * The tests of `row`, their transcript at `log`, classified. Under killer-first the pinned tests run alone first, and
	 * their reading is the verdict whenever it matched an expectation (`matchedAny`); otherwise the filtered run answers —
	 * dealt into slices run at once when the filter is a plain class list, whose union it is.
	 */
	private static function runTests(ctx: SlotContext, row: TrackRow, suite: String -> Command, log: String): SuiteRun {
		if (ctx.killerFirst && row.expected != '') {
			final killers: String = '$log.killers';
			saveLog(killers, suite(killerTokens(row.expected)).run());
			final reading: Null<Classified> = classifyOrNull(row.expected, [killers]);
			if (reading != null && matchedAny(reading, row.expected)) {
				FileSystem.rename(killers, log);
				return { phase: 'killers', reading: reading, read: log };
			}
			final slices: Null<Array<String>> = fallbackTokens(row.filter, envInt('APQ_MUTATION_FALLBACK_SLICES', FALLBACK_SLICES));
			if (slices != null) {
				final logs: Array<String> = [for (i in 0...slices.length) '$log.slice$i'];
				for (i => run in Pool.of(slices.length).map(slices, suite)) saveLog(logs[i], run);
				final sliced: Null<Classified> = classifyOrNull(row.expected, logs);
				// one transcript to open, the slices in order
				File.saveContent(log, [for (file in logs) File.getContent(file)].join(''));
				return { phase: 'sliced', reading: sliced, read: '$log.slice*' };
			}
		}
		saveLog(log, suite(row.filter).run());
		return { phase: 'filtered', reading: classifyOrNull(row.expected, [log]), read: log };
	}

	/**
	 * One suite run of the runner `testJs` in the slot over an `APQ_TEST` filter (`ALL`: every class), the fixture cache's
	 * shim first on its `PATH` when the run has one, and the composed build's arm `mutant` switched on when given. A track
	 * never inherits a filter or an arm from the caller.
	 */
	private static function suiteCommand(ctx: SlotContext, testJs: String, mutant: Null<String>): String -> Command {
		final shim: String = Path.join([ctx.workroot, 'fixture-cache/bin']);
		final inherited: String = Sys.getEnv(PATH) ?? '';
		final shimmed: Bool = FileSystem.exists(Path.join([shim, 'haxe']));
		final path: String = shimmed ? '$shim:$inherited' : inherited;
		return filter -> Shard.callerGc(
			cmd('node $testJs')
				.at(ctx.wt)
				.env(PATH, path)
				.env(HaxeSpawn.ANSWER_ENV, FixtureCache.answer(shimmed ? shim : null))
				.env('APQ_TEST', filter == 'ALL' ? '' : filter)
				.env('APQ_MUTANT', mutant ?? '')
				.timeout(SUITE_TIMEOUT_MS)
		);
	}

	/** `classify`, or null when a transcript cannot be read. */
	private static function classifyOrNull(expected: String, logs: Array<String>): Null<Classified> {
		return try classify(expected, logs) catch (exception: Exception) null;
	}

	/** Leave `reading` as the verdict of track `name`, whose transcript is `log`. */
	private static function settle(workroot: String, name: String, log: String, reading: Classified): Void {
		final full: Null<String> = reading.full;
		// the uncapped row goes into the transcript, where a name the capped row elided is still findable
		if (full != null) File.saveContent(log, '${File.getContent(log)}\n--- mutation-verdict: uncapped ${reading.verdict} ---\n$full\n');
		writeVerdict(workroot, name, reading.verdict, reading.verdict == RUN_FAIL ? '${reading.detail} ($log)' : reading.detail);
	}

	/**
	 * Settle `row` from a narrow build of its expectations' classes alone, the rest of the suite left untyped. False when
	 * the track still needs the full build, with the slot's tree mutated as `prepare` left it.
	 */
	private static function narrowTrack(ctx: SlotContext, row: TrackRow): Bool {
		if (!narrows(ctx.killerFirst, ctx.buildOnly, Sys.getEnv(NO_NARROW))) return false;
		final classes: Null<Array<String>> = narrowClasses(
			row.expected, name -> FileSystem.exists(Path.join([ctx.wt, 'test', '${name.split('.').join('/')}.hx']))
		);
		if (classes == null) return false;
		final workroot: String = ctx.workroot;
		final log: String = Path.join([workroot, '${row.name}.log']);
		final clock: NarrowClock = { build: 0, run: 0 };
		if (!narrowRun(ctx, classes, Path.join([workroot, 'narrow-${row.name}']), killerTokens(row.expected), '$log.narrow', clock))
			return false;
		final reading: Null<Classified> = classifyOrNull(row.expected, ['$log.narrow']);
		if (reading == null || !matchedAny(reading, row.expected)) return false;
		// one base run per class set and run: the set's verdict is a file of the workroot, which every slot reads
		final key: String = Md5.encode(classes.join(','));
		final baseVerdict: String = Path.join([workroot, 'narrow-base-$key.verdict']);
		if (!FileSystem.exists(baseVerdict)) {
			if (!cmd('git -C ${ctx.wt} apply -R -- ${row.patch}').run().ok) return false;
			final baseLog: String = Path.join([workroot, 'narrow-base-$key.log']);
			final base: Null<Classified> = narrowRun(ctx, classes, Path.join([workroot, 'narrow-base-$key']), 'ALL', baseLog, clock)
				? classifyOrNull('', [baseLog])
				: null;
			File.saveContent(baseVerdict, base?.verdict ?? RUN_FAIL);
			final reapplied: Result = cmd('git -C ${ctx.wt} apply -- ${row.patch}').run();
			if (!reapplied.ok) {
				writeVerdict(
					workroot, row.name, 'PATCH-FAIL', 'not re-applied after the narrow base: ${oneLine(reapplied.err + reapplied.failure)}'
				);
				return true;
			}
		}
		if (!takesNarrowKill(reading, row.expected, File.getContent(baseVerdict))) return false;
		FileSystem.rename('$log.narrow', log);
		File.saveContent(
			Path.join([workroot, '${row.name}.timing']), 'narrow ${seconds(0, clock.build)} ${seconds(0, clock.run)} killers\n'
		);
		settle(workroot, row.name, log, reading);
		return true;
	}

	/**
	 * Build the narrow test binary of `classes` into `dir` and run `filter` on it into `log`, charging `clock`; false when
	 * the build fails.
	 */
	private static function narrowRun(
		ctx: SlotContext, classes: Array<String>, dir: String, filter: String, log: String, clock: NarrowClock
	): Bool {
		FileSystem.createDirectory(dir);
		final from: Float = Sys.time();
		final built: Result = cmd(
			'haxe test-js-common.hxml ${Binaries.CODEGEN} -D ${NarrowBuild.define(classes)} -js ${Path.join([dir, TEST_JS])}'
		).at(ctx.wt).timeout(buildTimeoutMs()).run();
		saveLog('$log.build', built);
		final ran: Float = Sys.time();
		clock.build += ran - from;
		if (!built.ok) return false;
		saveLog(log, suiteCommand(ctx, Path.join([dir, TEST_JS]), null)(filter).run());
		clock.run += Sys.time() - ran;
		return true;
	}

	/** What one build may take before it counts as hung: `BUILD_TIMEOUT_S` unless `APQ_MUTATION_BUILD_TIMEOUT` says otherwise. */
	private static function buildTimeoutMs(): Int {
		return envInt('APQ_MUTATION_BUILD_TIMEOUT', BUILD_TIMEOUT_S) * MS_PER_SECOND;
	}

}

/** What every track of one slot shares. */
typedef SlotContext = {
	var workroot: String;
	var slot: Int;

	/** The slot's worktree. */
	var wt: String;

	var server: Null<SlotServer>;
	var buildOnly: Bool;
	var killerFirst: Bool;

	/** The composed build's directory, or null. */
	var schema: Null<String>;
}

/** One classified run: the verdict label, the row detail, and the uncapped detail when the row elided names. */
typedef Classified = {
	var verdict: String;
	var detail: String;
	var full: Null<String>;
}

/** A track's tests run: which run answered, its reading (null when unreadable), and the transcript(s) it read. */
typedef SuiteRun = {
	var phase: String;
	var reading: Null<Classified>;
	var read: String;
}

/** The seconds a narrow attempt spent building and running, charged to the track's timing row. */
typedef NarrowClock = {
	var build: Float;
	var run: Float;
}
