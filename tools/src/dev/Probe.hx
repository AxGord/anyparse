package dev;

import dev.Parity.Invocation;
import dev.Parity.Outcome;
import devkit.Args;
import devkit.Command;
import devkit.Pool;
import devkit.Result;
import devkit.TempDir;
import haxe.Json;
import haxe.crypto.Sha256;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev probe <area|kit.json> [--engine <apq.js>] [--compile] [--record] [--threads <n>] [--repo <tree>]` — a reviewer's probe
 * kit run on ONE engine. A kit is a `dev parity` suite whose invocations each carry what an engine answered when the kit was
 * recorded: exit status, digests of both streams and of the files the invocation wrote, and whether the fixture then compiles
 * with haxe under each declared define set. Only the invocations that deviate are printed, then one count line; exits 1 when one
 * does. `--record` writes what the engine answers into the kit instead.
 */
@:nullSafety(Strict)
final class Probe {

	public static inline final USAGE: String =
		'usage: dev probe <area|kit.json> [--engine <apq.js>] [--compile] [--record] [--threads <n>] [--repo <tree>]';

	/** Where a kit named by its area lives, from the tree's root: `<KITS>/<area>/kit.json`. */
	public static inline final KITS: String = 'test/probes';

	/** What stands in a recorded stream or file for the directory the invocation ran in, which differs on every run. */
	public static inline final FIXTURE_MARK: String = '<fixture>';

	/** How long one haxe compile may run before it is killed and answers a failure. */
	private static inline final COMPILE_TIMEOUT_MS: Int = 120000;

	private static inline final DEFAULT_THREADS: Int = 4;

	/** How many hex digits of a SHA-256 a digest keeps. */
	private static inline final DIGEST_WIDTH: Int = 16;

	/** How much of a deviating stream's first line a report row quotes. */
	private static inline final QUOTE_WIDTH: Int = 120;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		final threadsGiven: Null<String> = args.option('--threads');
		final threads: Null<Int> = threadsGiven == null ? DEFAULT_THREADS : Std.parseInt(threadsGiven);
		final record: Bool = args.flag('--record');
		final compile: Bool = record || args.flag('--compile');
		final engineGiven: String = args.option('--engine') ?? Path.join([repo, 'bin', 'apq.js']);
		final given: Array<String> = args.positionals(['<area|kit.json>']);
		if (threads == null || threads < 1) throw new UsageError('--threads is a positive count, not $threadsGiven');
		if (!FileSystem.exists(engineGiven) || FileSystem.isDirectory(engineGiven))
			throw new UsageError('engine $engineGiven is not a file');
		final engine: String = FileSystem.fullPath(engineGiven);
		final kitFile: String = kitPath(repo, given[0]);
		final kit: Kit = load(kitFile);
		final seen: Array<Seen> = observe(repo, engine, kit, compile, threads);
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
		return verdict.deviating == 0 ? 0 : 1;
	}

	/** The kit file `given` names: a path to a kit file or to a directory holding `kit.json`, else an area under `KITS`. */
	public static function kitPath(repo: String, given: String): String {
		final candidates: Array<String> = [
			given,
			Path.join([given, 'kit.json']),
			Path.join([repo, KITS, given, 'kit.json'])
		];
		for (candidate in candidates) if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate))
			return FileSystem.fullPath(candidate);
		throw new UsageError('no probe kit $given (neither a kit file nor $KITS/$given/kit.json)');
	}

	/** The kit in `file`: its invocations as `dev parity` reads them, and beside each its compile check and its expectation. */
	public static function load(file: String): Kit {
		final invocations: Array<Invocation> = Parity.load(file).invocations;
		final raw: KitFile = Json.parse(File.getContent(file));
		final rows: Array<KitRow> = raw.invocations ?? [];
		return {
			invocations: invocations,
			cases: [
				for (row in rows)
					{
						compile: row.compile ?? raw.compile,
						expect: row.expect,
						knownDefect: row.knownDefect,
						fixpoint: row.fixpoint
					}
			]
		};
	}

	/** Every invocation of `kit` run on `engine` through the shims of `shimTree`, each answer digested; compiled when `compile`. */
	public static function observe(shimTree: String, engine: String, kit: Kit, compile: Bool, threads: Int): Array<Seen> {
		return TempDir.with(work -> {
			final outcomes: Array<Outcome> = Parity.side(shimTree, engine, kit.invocations, work, threads);
			final seen: Array<Seen> = [
				for (i => outcome in outcomes) {
					final dir: String = work.file('$i');
					{
						answer: answerOf(kit.invocations[i].files, outcome, dir),
						out: normalize(outcome.out, dir),
						err: normalize(outcome.err, dir)
					};
				}
			];
			if (compile) compileAll(kit, outcomes, seen, work, threads);
			rerun(shimTree, engine, kit, outcomes, seen, threads);
			seen;
		});
	}

	/** What one outcome answers, its streams and written files digested with the run's directory `dir` normalized away. */
	public static function answerOf(before: Map<String, String>, outcome: Outcome, dir: String): Expectation {
		final written: Array<String> = [];
		final names: Array<String> = [for (name in outcome.files.keys()) name];
		for (name in before.keys()) if (!outcome.files.exists(name)) names.push(name);
		names.sort(Reflect.compare);
		for (name in names) {
			final after: Null<String> = outcome.files[name];
			if (after == before[name]) continue;
			written.push('$name\n${after == null ? '<removed>' : normalize(after, dir)}');
		}
		return {
			exit: outcome.status,
			out: digest(normalize(outcome.out + outcome.failure, dir)),
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
		if (compiled && want != null && got != null) {
			for (k in 0...Std.int(Math.max(want.length, got.length))) if (want[k] != got[k])
				lines.push('compiles with define set #$k: ${want[k]} → ${got[k]}');
		}
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
		final raw: KitFile = Json.parse(File.getContent(kitFile));
		for (i => row in raw.invocations ?? []) row.expect = seen[i].answer;
		File.saveContent(kitFile, Json.stringify(raw, null, '\t') + '\n');
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

	/** Each case's fixture as its invocation left it, compiled by haxe under each of its define sets; fills `seen[i].answer.compiles`. */
	private static function compileAll(kit: Kit, outcomes: Array<Outcome>, seen: Array<Seen>, work: TempDir, threads: Int): Void {
		final commands: Array<Command> = [];
		final owners: Array<Int> = [];
		for (i => outcome in outcomes) {
			final spec: Null<CompileSpec> = kit.cases[i].compile;
			if (spec == null) continue;
			final defines: Array<Array<String>> = spec.defines ?? [[]];
			for (k => set in defines) {
				final root: String = Parity.fixture(work.file('compile-$i-$k'), outcome.files);
				final at: String = spec.dir == null ? root : Path.join([root, spec.dir]);
				commands.push(Command.of(['haxe'].concat(spec.args).concat(set)).at(at).timeout(COMPILE_TIMEOUT_MS));
				owners.push(i);
			}
			seen[i].answer.compiles = [];
		}
		final results: Array<Result> = Pool.of(threads).run(commands);
		for (j => result in results) seen[owners[j]].answer.compiles?.push(result.status == 0 && result.failure == '');
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
		shimTree: String, engine: String, kit: Kit, outcomes: Array<Outcome>, seen: Array<Seen>, threads: Int
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
			final second: Array<Outcome> = Parity.side(shimTree, engine, again, work, threads);
			for (j => i in rows) {
				final source: String = kit.invocations[i].files[kit.cases[i].fixpoint ?? ''] ?? '';
				seen[i].answer.onePass = second[j].status == outcomes[i].status && second[j].out == outcomes[i].out;
				seen[i].answer.commentsKept = commentsOf(source).join('\n') == commentsOf(outcomes[i].out).join('\n');
			}
		});
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
}

/** A haxe compile of an invocation's fixture: the arguments, run in `dir` of it, once per define set (one empty set by default). */
typedef CompileSpec = {
	var args: Array<String>;
	var ?dir: String;
	var ?defines: Array<Array<String>>;
}

/** An engine's answer to one invocation: exit status and digests of stdout, stderr and the files it wrote, and each compile's verdict. */
typedef Expectation = {
	var exit: Null<Int>;
	var out: String;
	var err: String;
	var files: String;
	var ?compiles: Array<Bool>;
	var ?onePass: Bool;
	var ?commentsKept: Bool;
}

/** One invocation's answer with both of its streams, normalized, for quoting a deviation. */
typedef Seen = {
	var answer: Expectation;
	var out: String;
	var err: String;
}

/** A kit file as JSON spells it: a parity suite plus a default compile check and each invocation's own and its expectation. */
typedef KitFile = {
	var ?compile: CompileSpec;
	var ?invocations: Array<KitRow>;
}

/**
 * One invocation of a kit file beyond its parity fields: its own compile check and its recorded expectation.
 */
typedef KitRow = {
	var ?compile: CompileSpec;
	var ?expect: Expectation;
	var ?knownDefect: String;
	var ?fixpoint: String;
}

/** A run's report lines, the invocations that deviate, and the known-defect rows that moved. */
typedef Verdict = {
	var lines: Array<String>;
	var deviating: Int;
	var knownMoved: Int;
}
