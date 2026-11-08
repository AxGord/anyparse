package dev;

import anyparse.query.ShardPlan;
import anyparse.util.Compare;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Result;
import devkit.Summary;
import devkit.TempDir;
import haxe.Exception;
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

	/** The file `--baseline` records its readings in, beside the corpus snapshot it saves. */
	public static inline final BASELINE_FILE: String = 'baseline.json';

	public static inline final SWEEP_BASE: String = 'sweep-base.json';

	/** The environment variable that names the corpus the suite's harness reads. */
	public static inline final FORK_VAR: String = 'ANYPARSE_HXFORMAT_FORK';

	/** The environment variable that pins which `apq.js` the `hxq` shim runs. */
	public static inline final ENGINE_VAR: String = 'HXQ_BIN';

	/** The scope of a whole-tree lint of this project. */
	public static final TREE_SCOPE: Array<String> = ['src', 'test', 'tools'];

	/** The file names the formatter reads its options from, in any folder. */
	public static final FORMATTER_CONFIGS: Array<String> = ['hxformat.json', '.hxformat.json'];

	/** The snapshot the suite's corpus class writes in a tree, relative to it. */
	private static inline final SWEEP_SNAPSHOT: String = 'bin/.last-sweep.json';

	/** Where the corpus class rotates the previous snapshot to before each write, relative to the tree. */
	private static inline final SWEEP_PREVIOUS: String = 'bin/.prev-sweep.json';

	/** How long a quoted error may grow in a report row. */
	private static inline final QUOTE_WIDTH: Int = 150;

	/** The characters of a commit or a digest a report row spells. */
	private static inline final SHORT_HASH: Int = 9;

	/** The probe's own source and build file: the jvm probe runs when either moves, as when an engine input does. */
	private static final JVM_PROBE_FILES: Array<String> = ['tools/src/dev/JvmPortability.hx', 'tools/jvm-portability.hxml'];

	/** The directories whose change can move a lint rule's findings: `query` and `check`, `query/cli` excepted. */
	private static final RULE_CODE: EReg = ~/^src\/anyparse\/(check|query)\/(?!cli\/)/;

	/** The sources, build files, launch shims and configuration `bin/apq.js` is made from, run through and reads. */
	private static final ENGINE_INPUT: EReg = ~/^(src\/|bin\/(apq|hxq)$|bin\/apq-[^\/]*\.hxml$|apq\.json$)/;

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
		final file: String = log(BASELINE_FILE);
		baseline = !options.baseline && FileSystem.exists(file) ? BaselineParser.parse(File.getContent(file)) : null;
		base = options.baseline
			? gitIn(tree, ['rev-parse', 'HEAD']).trim()
			: options.base ?? baseline?.base ?? gitIn(tree, ['merge-base', 'HEAD', 'main']).trim();
		final changed: ChangedPaths = options.baseline ? { paths: [], moved: [] } : touchedSince(tree, base);
		for (name in changed.paths) touched.push(name);
		_moved = changed.moved;
	}

	public inline function apq(): String {
		return Path.join([tree, 'bin/apq.js']);
	}

	public inline function log(name: String): String {
		return Path.join([logs, name]);
	}

	/** Where the branch whose first row is `first` leaves its report. */
	public inline function branchReport(first: String): String {
		return log('rows/$first.json');
	}

	/**
	 * The file that branch rewrites as it makes progress: the name of each row as it starts, and the arms row's track as each
	 * ends (`MutationSlot.PROGRESS_VAR`). A branch that stops rewriting it is stalled.
	 */
	public inline function branchProgress(first: String): String {
		return '${branchReport(first)}.progress';
	}

	/** `git <args>` in the tree, its standard output; a failure throws. */
	public inline function git(args: Array<String>): String {
		return gitIn(tree, args);
	}

	/** `hxq <args>` in `dir` on the worktree's engine, whatever tree it reads. */
	public inline function hxq(dir: String, args: Array<String>): Command {
		return shim(tree, dir, args);
	}

	/** Whether the slice touched code that can move a lint rule's findings. */
	public inline function ruleCodeMoved(): Bool {
		return touched.exists(isRuleCode);
	}

	/** Whether the jvm probe has anything to check: an input of the engine or the probe moved. */
	public inline function jvmMoved(): Bool {
		return touched.exists(isJvmInput);
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

	/** The path the touched file `file` had at the base. */
	public function baseOf(file: String): String {
		return _moved[file] ?? file;
	}

	/** The snapshot each `--infra-tree` of a `--baseline` run is linted into. */
	public function infraSnapshots(): Array<InfraSnapshot> {
		return [for (i => dir in options.infra) { tree: dir, snapshot: log('infra-$i.json') }];
	}

	/**
	 * Remove the recorded baseline and the base suite reading kept beside it before a new baseline is taken: a `--baseline` run
	 * that fails a row, or the build, must leave the gate with NO baseline, never with the older one.
	 */
	public function retireBaseline(): Void {
		for (name in [BASELINE_FILE, BaseSuite.FILE, SWEEP_BASE]) {
			final file: String = log(name);
			if (FileSystem.exists(file)) FileSystem.deleteFile(file);
		}
	}

	/** Why the suite left no corpus snapshot in the tree, or null when it left one. */
	public function snapshotProblem(): Null<String> {
		return FileSystem.exists(Path.join([tree, SWEEP_SNAPSHOT]))
			? null
			: 'the suite left no corpus snapshot ($SWEEP_SNAPSHOT): no corpus case ran under $FORK_VAR';
	}

	public static inline function short(hash: String): String {
		return hash.trim().substr(0, SHORT_HASH);
	}

	public static inline function signed(n: Int): String {
		return n >= 0 ? '+$n' : '$n';
	}

	/**
	 * Whether the environment names a corpus for the suite to run.
	 */
	public static inline function forkSet(): Bool {
		return (Sys.getEnv(FORK_VAR) ?? '') != '';
	}

	/**
	 * Whether `file` is an input of the engine `bin/apq.js`: its sources, its build files and the configuration it reads. A slice that
	 * touches none of them leaves the engine, and every row that only measures the engine, as the base had it.
	 */
	public static inline function isEngineInput(file: String): Bool {
		return ENGINE_INPUT.match(file);
	}

	/** Why the fork the corpus class reads is unusable, or null when it is unset or a directory: a misconfiguration. */
	public static function forkProblem(): Null<String> {
		final fork: String = Sys.getEnv(FORK_VAR) ?? '';
		return fork != '' && (!FileSystem.exists(fork) || !FileSystem.isDirectory(fork))
			? clip('$FORK_VAR=$fork is no directory, so the suite ran no corpus')
			: null;
	}

	/**
	 * Move the corpus snapshot a previous run of the suite left in `tree` to the previous-sweep slot, the rotation the corpus class
	 * does before its own write: the snapshot a row reads afterwards is then the run's own, or none.
	 */
	public static function clearSnapshotIn(tree: String): Void {
		final file: String = Path.join([tree, SWEEP_SNAPSHOT]);
		if (FileSystem.exists(file)) FileSystem.rename(file, Path.join([tree, SWEEP_PREVIOUS]));
	}

	/** Whether `file` is code that can move a lint rule's findings: `query` and `check`, `query/cli` excepted. */
	public static function isRuleCode(file: String): Bool {
		return RULE_CODE.match(file);
	}

	/**
	 * The files in `tree` that differ from `base`, committed or not, untracked ones included, existing ones only, each
	 * renamed one paired with its path at the base. A `tree` that is no git work tree throws.
	 */
	public static function touchedSince(tree: String, base: String): ChangedPaths {
		final changed: ChangedPaths = changedPaths(stagedDiff(tree, base));
		final paths: Array<String> = [];
		for (name in changed.paths) if (name != '' && !paths.contains(name) && FileSystem.exists(Path.join([tree, name]))) paths.push(name);
		return { paths: paths, moved: changed.moved };
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

	/**
	 * The corpus row's verdict on what the suite left it, or null when nothing is missing: `fork` and `snapshot` name what is
	 * wrong, `selected` the classes an impact run held (null for a whole run). Only a missing snapshot of a selection without
	 * the corpus class is left to the land's whole suite; a bad fork, or a corpus class that ran and wrote nothing, fails.
	 */
	public static function corpusShortfall(fork: Null<String>, snapshot: Null<String>, selected: Null<Array<String>>): Null<Outcome> {
		if (fork != null) return Failed(fork);
		if (snapshot == null) return null;
		return selected != null && !selected.contains(ShardPlan.CORPUS_CLASS)
			? Skipped('the impact suite ran no corpus case — the land runs it')
			: Failed(snapshot);
	}

	/**
	 * What the fmt row's project half formats: the whole tree when the engine or a formatter config moved, else only the touched
	 * `.hx` files, since every other file formats as it did at the base. Empty when there is nothing to format.
	 */
	public static function fmtScope(touched: Array<String>): Array<String> {
		return ForkFmt.owedBy(touched) ? TREE_SCOPE.copy() : XconfigFmt.hxFilesOf(touched);
	}

	/**
	 * Whether `file` makes the jvm probe's answer: an engine input or the probe itself. The one answer to "must the jvm probe run?"
	 * for the slice gate and the battery both.
	 */
	public static function isJvmInput(file: String): Bool {
		return isEngineInput(file) || JVM_PROBE_FILES.contains(file);
	}

	/**
	 * `body` over a detached checkout of `commit` made from the repository of `tree`, removed afterwards whatever `body` did; a step
	 * that throws, or a commit that cannot be checked out, is `NotRun`.
	 */
	public static function withCheckout(tree: String, commit: String, body: String -> Outcome): Outcome {
		final scratch: TempDir = TempDir.create();
		final checkout: String = scratch.file('base');
		final outcome: Outcome = try {
			cmd('git -C $tree worktree add --detach $checkout $commit').check();
			body(checkout);
		} catch (exception: Exception) {
			NotRun(clip(exception.message));
		};
		cmd('git -C $tree worktree remove --force $checkout').run();
		scratch.dispose();
		return outcome;
	}

	/** The path (under `dir`, from `prefix`), size and modification time of every file below `dir/prefix`, in name order. */
	private static function fileStamps(dir: String, prefix: String): Array<String> {
		final names: Array<String> = FileSystem.readDirectory(Path.join([dir, prefix]));
		names.sort(Compare.compareString);
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

	/**
	 * `git diff --name-status -M <base>` of the tree as a `git add -A` would leave it, read through a copy of the index so the caller's
	 * own is untouched: git pairs a moved file with its old path only once the new path is in an index, and a move not yet staged
	 * (a filesystem move) must read as the move the gate sees after the commit.
	 */
	private static function stagedDiff(tree: String, base: String): String {
		return TempDir.with(scratch -> {
			final index: String = scratch.file('index');
			final own: String = gitIn(tree, ['rev-parse', '--git-path', 'index']).trim();
			File.copy(Path.isAbsolute(own) ? own : Path.join([tree, own]), index);
			cmd('git -C $tree add -A').env('GIT_INDEX_FILE', index).check();
			return cmd('git -C $tree diff --cached --name-status -M $base').env('GIT_INDEX_FILE', index).text();
		});
	}

}

/** What `dev slice-gate` was asked, as the gate and each of its branches read it. */
typedef GateOptions = {

	var tree: String;
	var logs: String;

	/** A `--baseline` run, which records rather than compares. */
	var baseline: Bool;

	/** The commit to measure against instead of the baseline's (null: the baseline's, else the merge-base with main). */
	@:optional var base: Null<String>;
	var frozen: Array<String>;
	var infra: Array<String>;
	var arms: Array<String>;
	var allow: Array<String>;

	/** The arms whose row in the arms row does not fail it, the rest of the row still deciding (`--allow arms` waives it whole). */
	var allowArms: Array<String>;
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
