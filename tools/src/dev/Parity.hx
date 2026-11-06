package dev;

import anyparse.check.oracle.HaxeRun;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonFormat;
import anyparse.query.cli.BatchAnswer;
import anyparse.query.cli.BatchAnswersParser;
import anyparse.query.cli.BatchCalls;
import anyparse.query.cli.BatchCallsWriter;
import anyparse.query.cli.BatchRun;
import devkit.Args;
import devkit.Command;
import devkit.Pool;
import devkit.RawJson;
import devkit.Result;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev parity <base-commit|engine> <tip-engine> [--suite <file>] [--out <dir>] [--threads <n>] [--verbose] [--one-process]
 * [--repo <tree>]` — a declared list of CLI invocations run on two engines, and only the invocations whose exit status,
 * standard output, standard error or written files differ printed, then one
 * count line. Each invocation runs in a fresh copy of its fixture files at the
 * same path on both sides, through the `bin/apq` / `bin/hxq` shim of the tree this tool sits in, so the engine is the only
 * thing that differs. A base given as a commit is built by `dev base-engine`. `--one-process` runs each side's invocations in
 * `--threads` engine processes (`apq --batch`) when its engine has that entry, else one process each. Exits 1 when an invocation differs.
 */
@:nullSafety(Strict)
final class Parity {

	public static inline final USAGE: String =
		'usage: dev parity <base-commit|engine> <tip-engine> [--suite <file>] [--out <dir>] [--threads <n>] [--verbose] [--one-process] [--repo <tree>]';

	/** The suite run when the caller names none, from the tree's root. */
	public static inline final DEFAULT_SUITE: String = 'tools/parity/default-suite.json';

	/** How long one invocation may run before it is killed and answers a failure. */
	private static inline final TIMEOUT_MS: Int = 120000;

	private static inline final DEFAULT_THREADS: Int = 4;

	/** How much of a differing line a report row quotes. */
	private static inline final QUOTE_WIDTH: Int = 120;

	/** The node flag the `bin/apq` shim runs the engine with, kept for a batch process so the two modes run alike. */
	private static inline final NODE_FLAGS: String = '--max-semi-space-size=64';

	/** The shims an invocation may name as its program: both run the engine `HXQ_BIN` pins. */
	private static final SHIMS: Array<String> = ['apq', 'hxq'];

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		final suiteFile: String = args.option('--suite') ?? Path.join([repo, DEFAULT_SUITE]);
		final out: Null<String> = args.option('--out');
		final threadsGiven: Null<String> = args.option('--threads');
		final threads: Null<Int> = threadsGiven == null ? DEFAULT_THREADS : Std.parseInt(threadsGiven);
		final verbose: Bool = args.flag('--verbose');
		final oneProcess: Bool = args.flag('--one-process');
		final given: Array<String> = args.positionals(['<base-commit|engine>', '<tip-engine>']);
		if (threads == null || threads < 1) throw new UsageError('--threads is a positive count, not $threadsGiven');
		if (!isFile(given[1])) throw new UsageError('tip engine ${given[1]} is not a file');
		final tip: String = FileSystem.fullPath(given[1]);
		final base: String = isFile(given[0])
			? FileSystem.fullPath(given[0])
			: BaseEngine.forCommit(repo, given[0], BaseEngine.defaultCache());
		final suite: Suite = load(suiteFile);
		final invocations: Array<Invocation> = suite.commandHelp
			? suite.invocations.concat(helpInvocations(repo, tip, suite.files))
			: suite.invocations;
		final runs: Array<Comparison> = compare(repo, base, tip, invocations, threads, oneProcess);
		var differing: Int = 0;
		for (i => run in runs) {
			if (verbose)
				Sys.println(
					'#$i ${run.base.status}/${run.tip.status} ${run.differences.length == 0 ? 'same' : 'DIFF'} ${run.invocation.name}'
				);
			if (run.differences.length == 0) continue;
			differing++;
			Sys.println('DIFF #$i ${run.invocation.name}: ${run.invocation.argv.join(' ')}');
			for (line in run.differences) Sys.println('  $line');
			if (out != null) keep(out, i, run);
		}
		Sys.println('parity: $differing of ${runs.length} invocations differ — base $base, tip $tip');
		return differing == 0 ? 0 : 1;
	}

	/** Every invocation run on the engine `base` and on `tip` through the shims of `shimTree`, at most `threads` at once. */
	public static function compare(
		shimTree: String, base: String, tip: String, invocations: Array<Invocation>, threads: Int, oneProcess: Bool
	): Array<Comparison> {
		return TempDir.with(work -> {
			final before: Array<Outcome> = side(shimTree, base, invocations, work, threads, oneProcessFor(base, oneProcess));
			final after: Array<Outcome> = side(shimTree, tip, invocations, work, threads, oneProcessFor(tip, oneProcess));
			[
				for (i => invocation in invocations)
					{
						invocation: invocation,
						base: before[i],
						tip: after[i],
						differences: differences(before[i], after[i])
					}
			];
		});
	}

	/** What differs between two outcomes of one invocation, one line each; empty when nothing does. */
	public static function differences(base: Outcome, tip: Outcome): Array<String> {
		final lines: Array<String> = [];
		if (base.status != tip.status) lines.push('exit: ${base.status} → ${tip.status}');
		if (base.failure != tip.failure) lines.push('failure: base `${clip(base.failure)}` / tip `${clip(tip.failure)}`');
		final out: Null<String> = streamDifference('stdout', base.out, tip.out);
		if (out != null) lines.push(out);
		final err: Null<String> = streamDifference('stderr', base.err, tip.err);
		if (err != null) lines.push(err);
		final changed: Array<String> = [
			for (name => text in base.files) if (tip.files.exists(name) && tip.files[name] != text) name
		];
		final onlyBase: Array<String> = [for (name in base.files.keys()) if (!tip.files.exists(name)) name];
		final onlyTip: Array<String> = [for (name in tip.files.keys()) if (!base.files.exists(name)) name];
		for (group in [
			{ label: 'files differ', names: changed },
			{ label: 'only base wrote', names: onlyBase },
			{ label: 'only tip wrote', names: onlyTip }
		]) if (group.names.length > 0) {
			group.names.sort(Reflect.compare);
			lines.push('${group.label}: ${group.names.join(', ')}');
		}
		return lines;
	}

	/** The first line where the stream `label` of the two sides parts, with each side's line count; null when they are equal. */
	public static function streamDifference(label: String, base: String, tip: String): Null<String> {
		if (base == tip) return null;
		final a: Array<String> = base.split('\n');
		final b: Array<String> = tip.split('\n');
		var i: Int = 0;
		while (i < a.length && i < b.length && a[i] == b[i]) i++;
		final left: String = i < a.length ? '`${clip(a[i])}`' : '<end>';
		final right: String = i < b.length ? '`${clip(b[i])}`' : '<end>';
		return '$label: line ${i + 1}: base $left / tip $right (base ${a.length} lines, tip ${b.length})';
	}

	/** The command names the `Commands:` block of `apq --help` lists, in its order. */
	public static function commandsOf(help: String): Array<String> {
		final names: Array<String> = [];
		final row: EReg = ~/^  ([a-z][a-z0-9-]*)(\s|$)/;
		var inBlock: Bool = false;
		for (line in help.split('\n')) {
			if (line.trim() == 'Commands:') {
				inBlock = true;
			} else if (inBlock) {
				if (!row.match(line)) break;
				names.push(row.matched(1));
			}
		}
		return names;
	}

	/** The suite in the JSON file `file`: its fixture files, its invocations, and whether every command's `--help` joins them. */
	public static function load(file: String): Suite {
		if (!FileSystem.exists(file)) throw new UsageError('suite $file not found');
		final parsed: SuiteFile = SuiteFileParser.parse(File.getContent(file));
		final files: Map<String, String> = filesOf(parsed.files);
		final invocations: Array<Invocation> = [];
		for (given in parsed.invocations ?? []) {
			if (given.argv.length == 0 || !SHIMS.contains(given.argv[0]))
				throw new UsageError('invocation ${given.name} of $file runs `${given.argv.join(' ')}`, not `apq|hxq …`');
			invocations.push({
				name: given.name,
				argv: given.argv,
				stdin: given.stdin,
				files: given.files == null ? files : filesOf(given.files)
			});
		}
		return { files: files, invocations: invocations, commandHelp: parsed.commandHelp == true };
	}

	/**
	 * Every invocation of `invocations` run by `engine` from a fresh copy of its fixture in `work`, `threads` at a time: each in a
	 * process of its own through the tree's shim, or with `oneProcess` all in `threads` engine processes (`apq --batch`), which
	 * answer as the separate processes would.
	 */
	public static function side(
		shimTree: String, engine: String, invocations: Array<Invocation>, work: TempDir, threads: Int, oneProcess: Bool
	): Array<Outcome> {
		final dirs: Array<String> = [for (i => invocation in invocations) fixture(work.file('$i'), invocation.files)];
		final results: Array<Result> = if (oneProcess) {
			batched(engine, invocations, dirs, work, threads);
		} else {
			final commands: Array<Command> = [
				for (i => invocation in invocations) {
					final command: Command = shim(shimTree, engine, invocation.argv).at(dirs[i]).timeout(TIMEOUT_MS);
					final stdin: Null<String> = invocation.stdin;
					stdin == null ? command : command.input(stdin);
				}
			];
			Pool.of(threads).run(commands);
		};
		return [
			for (i => result in results)
				{
					status: result.status,
					out: result.out,
					err: result.err,
					failure: result.failure,
					files: snapshot(dirs[i], '')
				}
		];
	}

	/** The directory `dir`, emptied and holding `files` (path relative to it => content). */
	public static function fixture(dir: String, files: Map<String, String>): String {
		js.Syntax.code("require('fs').rmSync({0}, { recursive: true, force: true })", dir);
		FileSystem.createDirectory(dir);
		for (name => text in files) {
			final path: String = Path.join([dir, name]);
			FileSystem.createDirectory(Path.directory(path));
			File.saveContent(path, text);
		}
		return dir;
	}

	/** The engine argv a shim invocation `argv` runs — what `bin/hxq` and `bin/apq` pass on: `hxq` names the Haxe default grammar. */
	public static function engineArgv(argv: Array<String>): Array<String> {
		final rest: Array<String> = argv.slice(1);
		return argv[0] == 'hxq' && rest.length > 0 ? [rest[0], '--lang-default', 'haxe'].concat(rest.slice(1)) : rest;
	}

	/**
	 * Whether `engine` runs its invocations in one process when that is `wanted`: only an engine that has the `apq --batch`
	 * entry, which a bare `--batch` tells apart (its usage line, where an older engine answers `unknown subcommand`).
	 */
	public static function oneProcessFor(engine: String, wanted: Bool): Bool {
		if (!wanted) return false;
		final probe: Result = Command.of(['node', NODE_FLAGS, engine, BatchRun.FLAG])
			.at(Path.directory(engine))
			.timeout(TIMEOUT_MS)
			.run();
		return probe.err.startsWith('usage: apq ${BatchRun.FLAG} ');
	}

	/** `apq <command> --help` for every command the engine `engine` lists, each over `files`. */
	private static function helpInvocations(shimTree: String, engine: String, files: Map<String, String>): Array<Invocation> {
		final help: Result = shim(shimTree, engine, ['apq', '--help']).at(shimTree).run();
		final names: Array<String> = commandsOf(help.out);
		if (names.length == 0) throw new haxe.Exception('`apq --help` of $engine lists no command');
		return names.map(name -> {
			name: 'help $name',
			argv: ['apq', name, '--help'],
			stdin: null,
			files: files
		});
	}

	/** `argv` (`apq|hxq <command> …`) run by the shim of `shimTree` on `engine`, the code cache off on both sides alike. */
	private static function shim(shimTree: String, engine: String, argv: Array<String>): Command {
		return Command.of(['sh', Path.join([shimTree, 'bin', argv[0]])].concat(argv.slice(1)))
			.env('HXQ_BIN', engine)
			.env('HXQ_CODE_CACHE', '0');
	}

	/** Every file below `dir/prefix`, by its path relative to `dir`, with its content. */
	private static function snapshot(dir: String, prefix: String): Map<String, String> {
		final files: Map<String, String> = [];
		for (name in FileSystem.readDirectory(Path.join([dir, prefix]))) {
			final path: String = prefix == '' ? name : '$prefix/$name';
			final full: String = Path.join([dir, path]);
			if (FileSystem.isDirectory(full))
				for (inner => text in snapshot(dir, path)) files[inner] = text;
			else
				files[path] = File.getContent(full);
		}
		return files;
	}

	/** Both sides' streams of the differing invocation `i`, written to `<dir>/<i>.{base,tip}.{out,err}`. */
	private static function keep(dir: String, i: Int, run: Comparison): Void {
		FileSystem.createDirectory(dir);
		File.saveContent(Path.join([dir, '$i.base.out']), run.base.out);
		File.saveContent(Path.join([dir, '$i.base.err']), run.base.err);
		File.saveContent(Path.join([dir, '$i.tip.out']), run.tip.out);
		File.saveContent(Path.join([dir, '$i.tip.err']), run.tip.err);
	}

	private static function filesOf(given: Null<JValue>): Map<String, String> {
		final files: Map<String, String> = [];
		switch given {
			case JObject(entries):
				for (entry in entries) files[entry.key] = RawJson.text(entry.value) ?? '';
			case _:
		}
		return files;
	}

	private static function isFile(path: String): Bool {
		return FileSystem.exists(path) && !FileSystem.isDirectory(path);
	}

	private static function clip(text: String): String {
		return text.length <= QUOTE_WIDTH ? text : '${text.substr(0, QUOTE_WIDTH - 1)}…';
	}

	/**
	 * `invocations` split into at most `threads` runs of `apq --batch`, each over a contiguous share, answered per invocation in
	 * order. A share whose engine process gave no answer fails each of its invocations with that process's first error.
	 */
	private static function batched(
		engine: String, invocations: Array<Invocation>, dirs: Array<String>, work: TempDir, threads: Int
	): Array<Result> {
		final size: Int = Math.ceil(invocations.length / threads);
		final shares: Array<Array<Int>> = [];
		var from: Int = 0;
		while (from < invocations.length) {
			shares.push([for (i in from ... Std.int(Math.min(from + size, invocations.length))) i]);
			from += size;
		}
		final commands: Array<Command> = [
			for (s => share in shares) {
				final calls: BatchCalls = {
					calls: share.map(i -> {argv: engineArgv(invocations[i].argv), cwd: dirs[i], stdin: invocations[i].stdin })
				};
				final callsFile: String = work.file('batch-$s.json');
				File.saveContent(callsFile, BatchCallsWriter.write(calls, JsonFormat.instance.compactWriteOptions));
				Command.of([
					'node',
					NODE_FLAGS,
					engine,
					BatchRun.FLAG,
					callsFile,
					work.file('batch-$s-answers.json')
				])
					.env('HXQ_BIN', engine)
					.at(work.file(''))
					.timeout(TIMEOUT_MS * share.length);
			}
		];
		final results: Array<Result> = [];
		for (s => run in Pool.of(threads).run(commands)) {
			final answersFile: String = work.file('batch-$s-answers.json');
			final answers: Array<BatchAnswer> = run.ok && FileSystem.exists(answersFile)
				? BatchAnswersParser.parse(File.getContent(answersFile)).answers
				: [];
			for (k => i in shares[s]) {
				final failure: String = 'apq ${BatchRun.FLAG} gave no answer: ${run.firstError()}';
				final answer: HaxeRun = k < answers.length
					? {
						status: answers[k].status,
						out: answers[k].out,
						err: answers[k].err,
						failure: '',
						overflowed: false
					}
					: {
						status: null,
						out: '',
						err: '',
						failure: failure,
						overflowed: false
					};
				results.push(new Result('batch #$i', answer));
			}
		}
		return results;
	}

}

/** A parity suite: the fixture files every invocation starts from unless it names its own, and the invocations. */
typedef Suite = {

	var files: Map<String, String>;
	var invocations: Array<Invocation>;

	/** Whether `apq <command> --help` of every command the tip engine lists joins the invocations. */
	var commandHelp: Bool;

}

/** One CLI call of a suite: its program (`apq` or `hxq`) and arguments, its standard input, and the files it starts from. */
typedef Invocation = {
	var name: String;
	var argv: Array<String>;
	var stdin: Null<String>;
	var files: Map<String, String>;
}

/** What one engine answered to one invocation: exit status, both streams, a failure to run, and the fixture files after it. */
typedef Outcome = {
	var status: Null<Int>;
	var out: String;
	var err: String;
	var failure: String;
	var files: Map<String, String>;
}

/** One invocation with both engines' outcomes and what differs between them. */
typedef Comparison = {
	var invocation: Invocation;
	var base: Outcome;
	var tip: Outcome;
	var differences: Array<String>;
}
