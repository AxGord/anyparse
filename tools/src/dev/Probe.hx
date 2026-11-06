package dev;

import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonFormat;
import dev.CompileSpec;
import dev.Expectation;
import dev.Parity.Invocation;
import dev.Parity.Outcome;
import devkit.Args;
import devkit.Command;
import devkit.Pool;
import devkit.RawJson;
import devkit.Result;
import devkit.TempDir;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev probe <area|kit.json> [--engine <apq.js>] [--compile] [--record] [--strict] [--threads <n>] [--repo <tree>]` — a reviewer's probe
 * kit run on ONE engine. A kit is a `dev parity` suite whose invocations each carry what an engine answered when the kit was
 * recorded: exit status, digests of both streams and of the files the invocation wrote, and whether the fixture then compiles
 * with haxe under each declared define set; with `run` in the compile spec it also runs the fixture and the files the invocation
 * started from, and records whether both print the same. Only the
 * invocations that deviate are printed, then one count line; exits 1 when one
 * does (`--strict`: or when a known-defect row moved). `--record` writes what the engine answers into the kit instead.
 * The invocations run in `--threads` engine processes (`apq --batch`) when the engine has that entry,
 * else one process each; `--per-process` runs each in a process of its own whatever the engine, and
 * `--process-parity` runs the kit both ways and prints only the invocations whose answers differ.
 */
@:nullSafety(Strict)
final class Probe {

	public static inline final USAGE: String =
		'usage: dev probe <area|kit.json> [--engine <apq.js>] [--compile] [--record] [--strict] [--threads <n>] [--per-process] [--process-parity] [--repo <tree>]';

	/** Where a kit named by its area lives, from the tree's root: `<KITS>/<area>/kit.json`. */
	public static inline final KITS: String = 'test/probes';

	/** The file of a kit inside its area's directory. */
	public static inline final KIT_FILE: String = 'kit.json';

	/** What stands in a recorded stream or file for the directory the invocation ran in, which differs on every run. */
	public static inline final FIXTURE_MARK: String = '<fixture>';

	/** The threads a gate's or a battery's kit run holds (`checkAll`). */
	public static inline final GATE_THREADS: Int = 2;

	/** How long one haxe compile may run before it is killed and answers a failure. */
	private static inline final COMPILE_TIMEOUT_MS: Int = 120000;

	private static inline final DEFAULT_THREADS: Int = 4;

	/** How many hex digits of a SHA-256 a digest keeps. */
	private static inline final DIGEST_WIDTH: Int = 16;

	/** How much of a deviating stream's first line a report row quotes. */
	private static inline final QUOTE_WIDTH: Int = 120;

	/** The key of an invocation's expectation in a kit. */
	private static inline final EXPECT_KEY: String = 'expect';

	/** Whether `verdict` passes: nothing deviates and, when `strict`, no known-defect row has moved either. */
	public static inline function holds(verdict: Verdict, strict: Bool): Bool {
		return verdict.deviating == 0 && !(strict && verdict.knownMoved > 0);
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		final threadsGiven: Null<String> = args.option('--threads');
		final threads: Null<Int> = threadsGiven == null ? DEFAULT_THREADS : Std.parseInt(threadsGiven);
		final record: Bool = args.flag('--record');
		final compileGiven: Bool = args.flag('--compile');
		final strict: Bool = args.flag('--strict');
		final perProcess: Bool = args.flag('--per-process');
		final parity: Bool = args.flag('--process-parity');
		final compile: Bool = record || compileGiven;
		final engineGiven: String = args.option('--engine') ?? Path.join([repo, 'bin', 'apq.js']);
		final given: Array<String> = args.positionals(['<area|kit.json>']);
		if (threads == null || threads < 1) throw new UsageError('--threads is a positive count, not $threadsGiven');
		if (!FileSystem.exists(engineGiven) || FileSystem.isDirectory(engineGiven))
			throw new UsageError('engine $engineGiven is not a file');
		final engine: String = FileSystem.fullPath(engineGiven);
		final oneProcess: Bool = Parity.oneProcessFor(engine, !perProcess);
		final kitFile: String = kitPath(repo, given[0]);
		final kit: Kit = load(kitFile);
		if (parity) {
			final lines: Array<String> = processParity(repo, engine, kit, threads);
			for (line in lines) Sys.println(line);
			final differing: Int = lines.filter(line -> line.startsWith('DIFF ')).length;
			Sys.println('probe: $differing of ${kit.invocations.length} invocations answer differently in one process — kit $kitFile');
			return differing == 0 ? 0 : 1;
		}
		final seen: Array<Seen> = observe(repo, engine, kit, compile, threads, oneProcess);
		if (record) {
			write(kitFile, seen);
			Sys.println('probe: recorded ${seen.length} invocations into $kitFile — engine $engine');
			return 0;
		}
		final verdict: Verdict = judge(kit, seen, compile);
		for (line in verdict.lines) Sys.println(line);
		final compiled: String = compile ? '' : ' (compile not checked: --compile)';
		final counts: String =
			'${verdict.deviating} of ${seen.length} invocations deviate, ${verdict.knownMoved} known-defect row(s) moved';
		Sys.println('probe: $counts$compiled — kit $kitFile, engine $engine');
		return holds(verdict, strict) ? 0 : 1;
	}

	/** The kit file `given` names: a path to a kit file or to a directory holding `kit.json`, else an area under `KITS`. */
	public static function kitPath(repo: String, given: String): String {
		final candidates: Array<String> = [
			given,
			Path.join([given, KIT_FILE]),
			Path.join([repo, KITS, given, KIT_FILE])
		];
		for (candidate in candidates) if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate))
			return FileSystem.fullPath(candidate);
		throw new UsageError('no probe kit $given (neither a kit file nor $KITS/$given/kit.json)');
	}

	/** The kit in `file`: its invocations as `dev parity` reads them, and beside each its compile check and its expectation. */
	public static function load(file: String): Kit {
		final invocations: Array<Invocation> = Parity.load(file).invocations;
		final raw: SuiteFile = SuiteFileParser.parse(File.getContent(file));
		final rows: Array<SuiteInvocation> = raw.invocations ?? [];
		return {
			invocations: invocations,
			cases: [
				for (row in rows)
					{
						compile: row.compile ?? raw.compile,
						expect: row.expect,
						knownDefect: row.knownDefect,
						fixpoint: row.fixpoint,
						outShape: row.outShape,
						outMinLines: row.outMinLines
					}
			]
		};
	}

	/**
	 * Every invocation of `kit` run on `engine`, each answer digested; compiled when `compile`. With `oneProcess` the invocations
	 * run in `threads` engine processes (`apq --batch`), else each through the shims of `shimTree` in a process of its own.
	 */
	public static function observe(shimTree: String, engine: String, kit: Kit, compile: Bool, threads: Int, oneProcess: Bool): Array<Seen> {
		return TempDir.with(work -> {
			final outcomes: Array<Outcome> = Parity.side(shimTree, engine, kit.invocations, work, threads, oneProcess);
			final seen: Array<Seen> = [
				for (i => outcome in outcomes) {
					final dir: String = work.file('$i');
					{
						answer: answerOf(kit.invocations[i].files, outcome, dir, kit.cases[i].outShape, kit.cases[i].outMinLines),
						out: normalize(outcome.out, dir),
						err: normalize(outcome.err, dir),
						failure: outcome.failure
					};
				}
			];
			if (compile) compileAll(kit, outcomes, seen, work, threads);
			rerun(shimTree, engine, kit, outcomes, seen, threads, oneProcess);
			seen;
		});
	}

	/** What one outcome answers, its streams and written files digested with the run's directory `dir` normalized away. */
	public static function answerOf(
		before: Map<String, String>, outcome: Outcome, dir: String, ?shape: String, minLines: Int = 1
	): Expectation {
		final written: Array<String> = [];
		final names: Array<String> = [for (name in outcome.files.keys()) name];
		for (name in before.keys()) if (!outcome.files.exists(name)) names.push(name);
		names.sort(Reflect.compare);
		for (name in names) {
			final after: Null<String> = outcome.files[name];
			if (after == before[name]) continue;
			written.push('$name\n${after == null ? '<removed>' : normalize(after, dir)}');
		}
		final shown: String = normalize(outcome.out + outcome.failure, dir);
		return {
			exit: outcome.status,
			out: digest(shape == null ? shown : shapeOf(shown, shape, minLines)),
			err: digest(normalize(outcome.err, dir)),
			files: digest(written.join('\n\u0000\n'))
		};
	}

	/**
	 * The report of a run: a block per deviating invocation, a known-defect row's block saying it moved (maybe fixed) and
	 * counted apart, since a fix to a defect the kit recorded is not a regression.
	 */
	public static function judge(kit: Kit, seen: Array<Seen>, compiled: Bool): Verdict {
		final verdict: Verdict = { lines: [], deviating: 0, knownMoved: 0 };
		for (i => row in seen) {
			final lines: Array<String> = deviations(kit.cases[i].expect, row, compiled);
			if (lines.length == 0) continue;
			final invocation: Invocation = kit.invocations[i];
			final known: Null<String> = kit.cases[i].knownDefect;
			if (known == null) {
				verdict.deviating++;
				verdict.lines.push('DEVIATES #$i ${invocation.name}: ${invocation.argv.join(' ')}');
			} else {
				verdict.knownMoved++;
				verdict.lines.push('KNOWN-DEFECT ROW MOVED (maybe fixed) #$i ${invocation.name}: $known');
			}
			for (line in lines) verdict.lines.push('  $line');
		}
		return verdict;
	}

	/** What deviates between the recorded `expected` and the `seen` answer, one line each; empty when nothing does. */
	public static function deviations(expected: Null<Expectation>, seen: Seen, compiled: Bool): Array<String> {
		if (expected == null) return ['not recorded: `dev probe --record` writes the expectation'];
		final answer: Expectation = seen.answer;
		final lines: Array<String> = [];
		if (expected.exit != answer.exit) lines.push('exit: ${expected.exit} → ${answer.exit}');
		if (expected.out != answer.out) lines.push('stdout: digest ${expected.out} → ${answer.out}, now ${firstLine(seen.out)}');
		if (expected.err != answer.err) lines.push('stderr: digest ${expected.err} → ${answer.err}, now ${firstLine(seen.err)}');
		if (expected.files != answer.files) lines.push('files written: digest ${expected.files} → ${answer.files}');
		if (expected.onePass != answer.onePass)
			lines.push('one pass (a second run over the output is a fixed point): ${expected.onePass} → ${answer.onePass}');
		if (expected.commentsKept != answer.commentsKept) lines.push('comments kept: ${expected.commentsKept} → ${answer.commentsKept}');
		final want: Null<Array<Bool>> = expected.compiles;
		final got: Null<Array<Bool>> = answer.compiles;
		if (compiled && want != null && got != null)
			for (k in 0...Std.int(Math.max(want.length, got.length)))
				if (want[k] != got[k]) lines.push('compiles with define set #$k: ${want[k]} → ${got[k]}');
		final wantSame: Null<Array<Bool>> = expected.sameRun;
		final gotSame: Null<Array<Bool>> = answer.sameRun;
		if (compiled && wantSame != null && gotSame != null)
			for (k in 0...Std.int(Math.max(wantSame.length, gotSame.length)))
				if (wantSame[k] != gotSame[k])
					lines.push('runs print the same as the original with define set #$k: ${wantSame[k]} → ${gotSame[k]}');
		if (lines.length > 0 && seen.failure != '') lines.unshift('failure: ${seen.failure}');
		return lines;
	}

	/**
	 * `text` with every spelling of the run's directory `dir` replaced by
	 * `FIXTURE_MARK`, and the pid `probe` stages its source under by `N`.
	 */
	public static function normalize(text: String, dir: String): String {
		final real: String = FileSystem.exists(dir) ? FileSystem.fullPath(dir) : dir;
		final spellings: Array<String> = real == dir ? [dir] : [real, dir];
		spellings.sort((a, b) -> b.length - a.length);
		var result: String = text;
		for (spelling in spellings) result = result.replace(spelling, FIXTURE_MARK);
		return ~/anyparse-last-probe\.[0-9]+\./g.replace(result, 'anyparse-last-probe.N.');
	}

	public static function digest(text: String): String {
		return Sha256.encode(text).substr(0, DIGEST_WIDTH);
	}

	/** The kit file `kitFile` with each invocation's expectation replaced by the answer `seen` holds for it, every other field kept. */
	public static function write(kitFile: String, seen: Array<Seen>): Void {
		final kit: JValue = JValueParser.parse(File.getContent(kitFile));
		final text: String = RawJson.print(recorded(kit, seen), '\t');
		File.saveContent(kitFile, '$text\n');
	}

	/**
	 * The `//` and `/* *\/` comments of C-family source `text`, each with its whitespace runs collapsed, sorted: a multiset to compare.
	 * A comment opener inside a string literal counts too, alike on both sides of a comparison.
	 */
	public static function commentsOf(text: String): Array<String> {
		final found: Array<String> = [];
		final comment: EReg = ~/\/\/[^\n]*|\/\*[\s\S]*?\*\//;
		var rest: String = text;
		while (comment.match(rest)) {
			found.push(~/\s+/g.replace(comment.matched(0), ' ').trim());
			rest = comment.matchedRight();
		}
		found.sort(Reflect.compare);
		return found;
	}

	/**
	 * Every area of `repo` run with its compile checks on the tree's own engine, its invocations in `threads` engine processes:
	 * the one answer to "does every probe kit still answer as recorded" for the slice gate and the battery. A row that deviates
	 * and a known-defect row that moved both fail (the slice that fixed a defect re-records the row and drops the field).
	 */
	public static function checkAll(repo: String, threads: Int): KitsReport {
		final engine: String = FileSystem.fullPath(Path.join([repo, 'bin', 'apq.js']));
		final oneProcess: Bool = Parity.oneProcessFor(engine, true);
		final report: KitsReport = {
			areas: 0,
			invocations: 0,
			failing: 0,
			failed: [],
			lines: []
		};
		for (area in areas(repo)) {
			final kit: Kit = load(kitPath(repo, area));
			final seen: Array<Seen> = observe(repo, engine, kit, true, threads, oneProcess);
			final verdict: Verdict = judge(kit, seen, true);
			report.areas++;
			report.invocations += seen.length;
			if (holds(verdict, true)) continue;
			report.failing += verdict.deviating + verdict.knownMoved;
			report.failed.push(area);
			for (line in verdict.lines) report.lines.push(line.startsWith('  ') ? line : '[$area] $line');
		}
		return report;
	}

	/** The areas of `repo` that hold a kit (`KITS/<area>/` + `KIT_FILE`), sorted. */
	public static function areas(repo: String): Array<String> {
		final root: String = Path.join([repo, KITS]);
		if (!FileSystem.exists(root)) return [];
		final found: Array<String> = [
			for (name in FileSystem.readDirectory(root)) if (FileSystem.exists(Path.join([root, name, KIT_FILE]))) name
		];
		found.sort(Reflect.compare);
		return found;
	}

	/**
	 * What `text` says of the line `shape` (a regular expression) describes: one word for every non-empty line fitting it, one for a
	 * line that does not, one for fewer than `minLines` lines. A row whose
	 * output is a list that grows with the product records this, not the list.
	 */
	public static function shapeOf(text: String, shape: String, minLines: Int = 1): String {
		final line: EReg = new EReg(shape, '');
		final lines: Array<String> = text.split('\n').filter(l -> l != '');
		if (lines.length < minLines) return 'too few lines';
		return lines.exists(l -> !line.match(l)) ? 'a line off the shape' : 'every line fits';
	}

	/**
	 * The invocations of `kit` whose one-process answer (`apq --batch`) differs from the answer of a process of their own — exit
	 * status, either stream with the fixture path and the probe pid normalized, or a written file — each as a `DIFF` line and its
	 * differences; empty when all agree. A difference is a process-scoped state one call leaked into the next.
	 */
	public static function processParity(shimTree: String, engine: String, kit: Kit, threads: Int): Array<String> {
		final apart: Array<Outcome> = TempDir.with(work ->
			normalized(Parity.side(shimTree, engine, kit.invocations, work, threads, false), work)
		);
		final together: Array<Outcome> = TempDir.with(work ->
			normalized(Parity.side(shimTree, engine, kit.invocations, work, threads, true), work)
		);
		final lines: Array<String> = [];
		for (i => invocation in kit.invocations) {
			final differences: Array<String> = Parity.differences(apart[i], together[i]);
			if (differences.length == 0) continue;
			lines.push('DIFF #$i ${invocation.name}: ${invocation.argv.join(' ')}');
			for (line in differences) lines.push('  $line');
		}
		return lines;
	}

	/** Each case's fixture as its invocation left it, compiled by haxe under each of its define sets; fills `seen[i].answer.compiles`. */
	private static function compileAll(kit: Kit, outcomes: Array<Outcome>, seen: Array<Seen>, work: TempDir, threads: Int): Void {
		final commands: Array<Command> = [];
		final owners: Array<Int> = [];
		final originals: Array<Bool> = [];
		for (i => outcome in outcomes) {
			final spec: Null<CompileSpec> = kit.cases[i].compile;
			if (spec == null) continue;
			final defines: Array<Array<String>> = spec.defines ?? [[]];
			final sides: Array<Bool> = spec.run == true ? [false, true] : [false];
			for (k => set in defines) {
				// the run flag also compiles the files the invocation started from, to compare what the two programs print
				for (original in sides) {
					final label: String = original ? 'original' : 'compile';
					final root: String = Parity.fixture(work.file('$label-$i-$k'), original ? kit.invocations[i].files : outcome.files);
					final at: String = spec.dir == null ? root : Path.join([root, spec.dir]);
					commands.push(Command.of(['haxe'].concat(spec.args).concat(set)).at(at).timeout(COMPILE_TIMEOUT_MS));
					owners.push(i);
					originals.push(original);
				}
			}
			seen[i].answer.compiles = [];
			if (spec.run == true) seen[i].answer.sameRun = [];
		}
		final results: Array<Result> = Pool.of(threads).run(commands);
		for (j => result in results) {
			final done: Bool = result.status == 0 && result.failure == '';
			final answer: Expectation = seen[owners[j]].answer;
			if (originals[j]) {
				final fixed: Result = results[j - 1];
				answer.sameRun?.push(done && fixed.status == 0 && fixed.failure == '' && fixed.out == result.out);
			} else {
				answer.compiles?.push(done);
			}
		}
	}

	private static function firstLine(text: String): String {
		final line: String = text.split('\n')[0];
		return line.length <= QUOTE_WIDTH ? '`$line`' : '`${line.substr(0, QUOTE_WIDTH - 1)}…`';
	}

	/**
	 * Each case with a `fixpoint` file whose run succeeded, run once more with
	 * its first stdout in that file: `onePass` holds when the second run answers
	 * the same, `commentsKept` when the output carries the file's comments as a multiset.
	 */
	private static function rerun(
		shimTree: String, engine: String, kit: Kit, outcomes: Array<Outcome>, seen: Array<Seen>, threads: Int, oneProcess: Bool
	): Void {
		final rows: Array<Int> = [
			for (i => probeCase in kit.cases) if (probeCase.fixpoint != null && outcomes[i].status == 0) i
		];
		if (rows.length == 0) return;
		final again: Array<Invocation> = [
			for (i in rows) {
				final invocation: Invocation = kit.invocations[i];
				final files: Map<String, String> = invocation.files.copy();
				files[kit.cases[i].fixpoint ?? ''] = outcomes[i].out;
				{
					name: invocation.name,
					argv: invocation.argv,
					stdin: invocation.stdin,
					files: files
				};
			}
		];
		TempDir.with(work -> {
			final second: Array<Outcome> = Parity.side(shimTree, engine, again, work, threads, oneProcess);
			for (j => i in rows) {
				final source: String = kit.invocations[i].files[kit.cases[i].fixpoint ?? ''] ?? '';
				seen[i].answer.onePass = second[j].status == outcomes[i].status && second[j].out == outcomes[i].out;
				seen[i].answer.commentsKept = commentsOf(source).join('\n') == commentsOf(outcomes[i].out).join('\n');
			}
		});
	}

	/** The kit `kit` with the `expect` of each invocation replaced by the answer `seen` holds for it, every other key kept as it stands. */
	private static function recorded(kit: JValue, seen: Array<Seen>): JValue {
		return switch kit {
			case JObject(entries):
				JObject([
					for (entry in entries)
						entry.key == 'invocations' ? JValueTools.entry('invocations', withExpectations(entry.value, seen)) : entry
				]);
			case _:
				kit;
		}
	}

	private static function withExpectations(rows: JValue, seen: Array<Seen>): JValue {
		return JArray([for (i => row in RawJson.items(rows)) withExpectation(row, seen[i].answer)]);
	}

	/** The invocation `row` with its `expect` set to `answer`: in place when it holds one, last otherwise. */
	private static function withExpectation(row: JValue, answer: Expectation): JValue {
		return switch row {
			case JObject(entries):
				final value: JEntry = JValueTools.entry(EXPECT_KEY, expectationValue(answer));
				final held: Bool = entries.exists(entry -> entry.key == EXPECT_KEY);
				final replaced: Array<JEntry> = [for (entry in entries) entry.key == EXPECT_KEY ? value : entry];
				JObject(held ? replaced : replaced.concat([value]));
			case _:
				row;
		}
	}

	/**
	 * The answer `answer` as the object a kit holds: the generated writer fixes the keys and their order and leaves an unset optional out.
	 */
	private static function expectationValue(answer: Expectation): JValue {
		return JValueParser.parse(ExpectationWriter.write(answer, JsonFormat.instance.compactWriteOptions));
	}

	/** `outcomes` with both streams normalized against the fixture directory each ran in under `work`. */
	private static function normalized(outcomes: Array<Outcome>, work: TempDir): Array<Outcome> {
		return [
			for (i => outcome in outcomes)
				{
					status: outcome.status,
					out: normalize(outcome.out, work.file('$i')),
					err: normalize(outcome.err, work.file('$i')),
					failure: outcome.failure,
					files: outcome.files
				}
		];
	}

}

/** A kit: its invocations as `dev parity` runs them, and the case beside each. */
typedef Kit = {
	var invocations: Array<Invocation>;
	var cases: Array<ProbeCase>;
}

/**
 * What a kit holds beside one invocation: how its fixture is compiled afterwards, what the recording engine answered, the defect
 * that answer is known to carry, and the fixture file the invocation's stdout rewrites (checked for one pass and kept comments).
 */
typedef ProbeCase = {

	var compile: Null<CompileSpec>;
	var expect: Null<Expectation>;
	var knownDefect: Null<String>;
	var fixpoint: Null<String>;

	/** A regular expression every stdout line fits: the row records that, not the list (`shapeOf`). */
	var ?outShape: String;

	/** The fewest non-empty stdout lines a row with an `outShape` may print: a floor under a list that only grows. */
	var ?outMinLines: Int;

}

/** One invocation's answer with both of its streams, normalized, for quoting a deviation. */
typedef Seen = {

	var answer: Expectation;
	var out: String;
	var err: String;

	/** Why the engine gave no answer, empty when it answered. */
	var failure: String;

}

/** A run's report lines, the invocations that deviate, and the known-defect rows that moved. */
typedef Verdict = {
	var lines: Array<String>;
	var deviating: Int;
	var knownMoved: Int;
}

/** What `Probe.checkAll` read: the areas and invocations run, the rows that fail, the areas holding them, and their report lines. */
typedef KitsReport = {
	var areas: Int;
	var invocations: Int;
	var failing: Int;
	var failed: Array<String>;
	var lines: Array<String>;
}
