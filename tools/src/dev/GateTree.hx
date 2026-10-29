package dev;

import dev.SliceGate.Baseline;
import dev.SliceGate.InfraSnapshot;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Result;
import devkit.Summary;
import devkit.TempDir;
import haxe.Exception;
import haxe.Json;
import haxe.crypto.Sha1;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The tree a slice gate runs on: what it was asked, the base the slice is measured against, the files the slice changed,
 * the table its rows report into, and the commands every row runs there on the tree's own engine.
 */
@:nullSafety(Strict)
final class GateTree {

	/** Why a gate that compares with the baseline cannot run. */
	public static inline final NO_BASELINE: String = 'no baseline — run `dev slice-gate <worktree> --baseline` before the first edit';

	/** The scope of a whole-tree lint of this project. */
	public static final TREE_SCOPE: Array<String> = ['src', 'test', 'tools'];

	/** How long a quoted error may grow in a report row. */
	private static inline final QUOTE_WIDTH: Int = 150;

	/** The environment variable that pins which `apq.js` the `hxq` shim runs. */
	private static inline final ENGINE_VAR: String = 'HXQ_BIN';

	/** The characters of a commit or a digest a report row spells. */
	private static inline final SHORT_HASH: Int = 9;

	/** The probe's own source: the jvm row runs when it moves, as when `src/` does. */
	private static inline final JVM_PROBE: String = 'tools/src/dev/JvmPortability.hx';

	/** The directories whose change can move a lint rule's findings: `query` and `check`, `query/cli` excepted. */
	private static final RULE_CODE: EReg = ~/^src\/anyparse\/(check|query)\/(?!cli\/)/;

	public final summary: Summary = new Summary();

	/** The files the slice changed against the base, committed or not, untracked ones included, as they are now. */
	public final touched: Array<String> = [];

	public final options: GateOptions;
	public final tree: String;
	public final logs: String;

	/** What `--baseline` recorded, or null in a `--baseline` run and before one. */
	public final baseline: Null<Baseline>;

	/** The commit the slice is measured against: HEAD for `--baseline`, else the baseline's. */
	public final base: String;

	/** Each touched file a rename moved, mapped to the path it had at the base. */
	private final _moved: Map<String, String>;

	public function new(options: GateOptions) {
		this.options = options;
		tree = options.tree;
		logs = options.logs;
		final file: String = log('baseline.json');
		baseline = !options.baseline && FileSystem.exists(file) ? Json.parse(File.getContent(file)) : null;
		base = options.baseline
			? gitIn(tree, ['rev-parse', 'HEAD']).trim()
			: baseline?.base ?? gitIn(tree, ['merge-base', 'HEAD', 'main']).trim();
		final changed: ChangedPaths = options.baseline
			? { paths: [], moved: [] }
			: changedPaths(gitIn(tree, ['diff', '--name-status', '-M', base]));
		final untracked: Array<String> = options.baseline ? [] : gitIn(tree, ['ls-files', '--others', '--exclude-standard']).split('\n');
		for (name in changed.paths.concat(untracked)) if (
			name != '' && !touched.contains(name) && FileSystem.exists(Path.join([tree, name]))
		)
			touched.push(name);
		_moved = changed.moved;
	}

	public inline function apq(): String {
		return Path.join([tree, 'bin/apq.js']);
	}

	public inline function log(name: String): String {
		return Path.join([logs, name]);
	}

	/** `git <args>` in the tree, its standard output; a failure throws. */
	public inline function git(args: Array<String>): String {
		return gitIn(tree, args);
	}

	/** `hxq <args>` in `dir` on the worktree's engine, whatever tree it reads. */
	public inline function hxq(dir: String, args: Array<String>): Command {
		return shim(tree, dir, args);
	}

	/** `command` run in the worktree on its engine. */
	public function inTree(command: Command): Result {
		return command.at(tree).env(ENGINE_VAR, apq()).run();
	}

	/**
	 * `hxq <args>` as `hxq` runs it, its standard error written to the file `errLog` (truncated first) instead of a pipe.
	 * A command that is chatty on stderr — a lint whose oracle reports every configuration unavailable — would otherwise fill
	 * the pipe, and a writer that meets a full pipe has nowhere to put the rest.
	 */
	public function hxqLogged(dir: String, args: Array<String>, errLog: String): Command {
		final shim: String = Path.join([tree, 'bin/hxq']);
		return logged(['sh', shim].concat(args), errLog).at(dir).env(ENGINE_VAR, apq());
	}

	/** `body` over a detached checkout of the base, removed afterwards; a step that throws is `NotRun`. */
	public function withBaseCheckout(body: String -> Outcome): Outcome {
		final scratch: TempDir = TempDir.create();
		final checkout: String = scratch.file('base');
		final outcome: Outcome = try {
			cmd('git -C $tree worktree add --detach $checkout $base').check();
			body(checkout);
		} catch (exception: Exception) NotRun(clip(exception.message));
		cmd('git -C $tree worktree remove --force $checkout').run();
		scratch.dispose();
		return outcome;
	}

	/** The path the touched file `file` had at the base. */
	public function baseOf(file: String): String {
		return _moved[file] ?? file;
	}

	/** Whether the jvm probe has anything to check: `src/` or the probe moved. */
	public function jvmMoved(): Bool {
		return touched.exists(f -> f.startsWith('src/') || f == JVM_PROBE);
	}

	/** Whether the slice touched code that can move a lint rule's findings. */
	public function ruleCodeMoved(): Bool {
		return touched.exists(f -> RULE_CODE.match(f));
	}

	/** The snapshot each `--infra-tree` of a `--baseline` run is linted into. */
	public function infraSnapshots(): Array<InfraSnapshot> {
		return [for (i => dir in options.infra) { tree: dir, snapshot: log('infra-$i.json') }];
	}

	public static inline function short(hash: String): String {
		return hash.trim().substr(0, SHORT_HASH);
	}

	public static inline function signed(n: Int): String {
		return n >= 0 ? '+$n' : '$n';
	}

	/** The `hxq` shim of `tree` run in `dir` with `args`, pinned to the engine `tree` built: no staleness probe, no rebuild. */
	public static function shim(tree: String, dir: String, args: Array<String>): Command {
		final shim: String = Path.join([tree, 'bin/hxq']);
		return cmd('sh $shim $args').at(dir).env(ENGINE_VAR, Path.join([tree, 'bin/apq.js']));
	}

	/** `argv` run with its standard error written to the file `errLog` (truncated first) and nothing on the error pipe. */
	public static function logged(argv: Array<String>, errLog: String): Command {
		return Command.of(['sh', '-c', 'exec "$$@" 2>"$$0"', errLog].concat(argv));
	}

	/**
	 * The paths `git diff --name-status -M` printed as `text` names as they are now, and each renamed one's path at the
	 * base: a rename row is `R<score>\t<old>\t<new>`, every other row `<status>\t<path>`.
	 */
	public static function changedPaths(text: String): ChangedPaths {
		final paths: Array<String> = [];
		final moved: Map<String, String> = [];
		for (line in text.split('\n')) {
			final cells: Array<String> = line.split('\t');
			if (cells.length == 3 && cells[0].startsWith('R')) {
				paths.push(cells[2]);
				moved[cells[2]] = cells[1];
			} else if (cells.length == 2) {
				paths.push(cells[1]);
			}
		}
		return { paths: paths, moved: moved };
	}

	/** `git <args>` in `dir`, its standard output; a failure throws. */
	public static function gitIn(dir: String, args: Array<String>): String {
		return cmd('git -C $dir $args').text();
	}

	/** The SHA-1 of `git diff` in `dir`, as `git -C <dir> diff | shasum` prints it. */
	public static function diffDigest(dir: String): String {
		return Sha1.encode(cmd('git -C $dir diff').text());
	}

	/**
	 * What `dir` holds now, for a cache key: in a git tree its HEAD, its `git diff` digest and its untracked files; in any
	 * other directory every file's path, size and modification time.
	 */
	public static function treeState(dir: String): String {
		if (!FileSystem.exists(Path.join([dir, '.git']))) return Sha1.encode(fileStamps(dir, '').join('\n'));
		final untracked: String = cmd('git -C $dir ls-files --others --exclude-standard').text();
		return '${gitIn(dir, ['rev-parse', 'HEAD']).trim()} ${diffDigest(dir)} ${Sha1.encode(untracked)}';
	}

	/** The first line of `run` that reads like an error, else its first line, clipped for a report row. */
	public static function quote(run: Result): String {
		return clip(run.firstError());
	}

	public static function clip(text: String): String {
		return text.length <= QUOTE_WIDTH ? text : '${text.substr(0, QUOTE_WIDTH - 1)}…';
	}

	/** The path (under `dir`, from `prefix`), size and modification time of every file below `dir/prefix`, in name order. */
	private static function fileStamps(dir: String, prefix: String): Array<String> {
		final names: Array<String> = FileSystem.readDirectory(Path.join([dir, prefix]));
		names.sort(Reflect.compare);
		final stamps: Array<String> = [];
		for (name in names) {
			final path: String = prefix == '' ? name : '$prefix/$name';
			final full: String = Path.join([dir, path]);
			if (FileSystem.isDirectory(full)) {
				for (stamp in fileStamps(dir, path)) stamps.push(stamp);
			} else {
				final stat: sys.FileStat = FileSystem.stat(full);
				stamps.push('$path ${stat.size} ${stat.mtime.getTime()}');
			}
		}
		return stamps;
	}

}

/** What `dev slice-gate` was asked, as the gate and each of its branches read it. */
typedef GateOptions = {
	var tree: String;
	var logs: String;

	/** A `--baseline` run, which records rather than compares. */
	var baseline: Bool;

	var frozen: Array<String>;
	var infra: Array<String>;
	var arms: Array<String>;
	var allow: Array<String>;
	var noArms: Bool;

	/** The threads a heavy row (the suite's shards, the arms' jobs) may take, or null for each tool's own default. */
	var threads: Null<Int>;

	/** The run a branch reports to: a gate's own, handed to its branches with `--run`. */
	var run: String;
}

/** What `git diff --name-status -M` names: the changed paths as they are now, and each renamed one's path at the base. */
typedef ChangedPaths = {
	var paths: Array<String>;
	var moved: Map<String, String>;
}
