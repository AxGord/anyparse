package dev;

import devkit.Args;
import devkit.Branches;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import devkit.Tally;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev land <branch>` — the parent's merge of a reviewed slice branch into the tree that holds this `dev.js`, as ONE
 * command: a `--no-ff` merge whose append-only files merge as their `.gitattributes` say (`docs/decisions.md` by union,
 * `mutation-arms.json` by `dev merge-arms`), the three binaries rebuilt, the merge committed, then `tools/battery.sh` (quick,
 * or in full when the merge brings in a path where a shard and the one-process suite can diverge, or the number of the
 * landing, counted over every landing that runs the battery, is a multiple of ten — the battery row says which) — and one
 * verdict line. A conflict git cannot resolve or a failed build aborts the merge and leaves the tree as it was; a red battery
 * leaves the merge commit for the caller to judge (docs/testing.md § "Landing a slice"). Any step after the merge that does
 * not pass — one that threw (`not run`) as much as one that failed — aborts the merge.
 */
@:nullSafety(Strict)
final class Land {

	public static inline final USAGE: String = 'usage: dev land <branch> [-m <message>] [--no-battery] [--full] [--allow-blast] '
		+ '[--snapshot] [--logs <dir>] [--repo <tree>]';

	/** Every this-many-th landing runs the battery in full, whatever it touched. */
	public static inline final FULL_EVERY: Int = 10;

	/** The merge driver `.gitattributes` names for `test/testkit/mutation-arms.json`. */
	private static inline final ARMS_DRIVER: String = 'anyparse-arms';

	/** What the battery may run before it is killed. */
	private static inline final BATTERY_TIMEOUT_MS: Int = 3 * 60 * 60 * 1000;

	/**
	 * The threads the battery's other branches hold beside its suite (fmt, the lint's two arms, the jvm probe); what a pool
	 * lease leaves is the suite's shard count, as in the slice gate.
	 */
	private static inline final BATTERY_LIGHT_THREADS: Int = 4;

	/** Where, under the battery's snapshot directory, the landings are counted. */
	private static inline final TALLY_DIR: String = 'landings';

	/**
	 * Where a shard and the one-process run of the suite can diverge, so a landing that brings a path in is checked against
	 * both: the test kit and runner, the shard planning and the transcript parity it is judged by, the battery script, the
	 * process-scoped runtime caches (docs/design-principles.md § 2) and the runtime itself. A path is a prefix.
	 */
	private static final DIVERGENCE_PATHS: Array<String> = [
		'test/testkit/',
		'tools/src/dev/Shard',
		'src/anyparse/query/Shard',
		'src/anyparse/query/cli/TestTranscript.hx',
		'test/RunTests.hx',
		'tools/battery.sh',
		'src/anyparse/query/SharedParseTier.hx',
		'src/anyparse/query/FormatConfigDiscovery.hx',
		'src/anyparse/grammar/haxe/HaxeQueryPlugin.hx',
		'src/anyparse/macro/QueryWalkerCodegen.hx',
		'src/anyparse/runtime/'
	];

	private final _summary: Summary = new Summary();
	private final _repo: String;
	private final _branch: String;
	private final _logs: String;
	private final _compile: Compile;
	private final _exec: BatteryExec;
	private final _merged: MergedPaths;
	private final _print: String -> Void;

	/** Whether a merge of this run is in progress, so a failed step aborts it. */
	private var _merging: Bool = false;

	/** Whether this run built the binaries from a merged tree. */
	private var _built: Bool = false;

	private function new(options: LandOptions) {
		_repo = options.repo;
		_branch = options.branch;
		_logs = options.logs;
		_compile = options.compile;
		_exec = options.exec;
		_merged = options.merged;
		_print = options.print;
	}

	/**
	 * Every step in turn, each only while the ones before it passed; answers the exit status. A merge a failed step aborts
	 * leaves binaries built from the merged tree behind (they are not tracked), so they are rebuilt from HEAD.
	 */
	private function run(message: Null<String>, battery: Null<BatteryRequest>): Int {
		final steps: Array<{ name: String, step: () -> Outcome }> = [
			{ name: 'clean', step: clean },
			{ name: 'merge', step: merge },
			{ name: 'build', step: build },
			{ name: 'commit', step: commit.bind(message) },
			{ name: 'battery', step: runBattery.bind(battery) }
		];
		var aborted: Bool = false;
		for (s in steps) if (_summary.passed()) {
			final outcome: Outcome = _summary.time(s.name, s.step);
			if (!outcome.match(Passed | Skipped(_))) aborted = abortMerge() || aborted;
		}
		if (aborted && _built) _summary.time(
			'rebuild', () -> switch _compile(_repo, Path.join([_logs, 'rebuild.log'])) {
				case Failed(why): Failed('the binaries are still the aborted merge\'s: $why');
				case other:
					_summary.detail('binaries rebuilt from HEAD after the abort');
					other;
			}
		);
		_print(_summary.table());
		final passed: Bool = _summary.passed();
		_print('land $_branch: ${passed ? 'PASS' : 'FAIL'} — logs $_logs');
		return passed ? 0 : 1;
	}

	/**
	 * Abort the merge of this run, if one is in progress. A step that threw is as unfinished as one that failed, so the
	 * caller asks after every step that did not pass, whichever way it ended. Answers whether a merge was aborted.
	 */
	private function abortMerge(): Bool {
		if (!_merging) return false;
		if (!git(['merge', '--abort']).ok) _summary.add('abort', Failed('`git merge --abort` failed — the tree is still mid-merge'));
		return true;
	}

	private function clean(): Outcome {
		final dirty: Array<String> = git(['status', '--porcelain', '--untracked-files=no']).lines();
		return dirty.length == 0 ? Passed : Failed('the tree has uncommitted changes, first `${dirty[0]}`');
	}

	/** `git merge --no-ff --no-commit` with the arm registry's driver named; a conflict it leaves fails the step. */
	private function merge(): Outcome {
		final dev: String = Path.join([_repo, 'bin/dev.js']);
		final run: Result = git([
			'-c',
			'merge.$ARMS_DRIVER.driver=node $dev merge-arms %O %A %B',
			'merge',
			'--no-ff',
			'--no-commit',
			_branch
		]);
		_merging = git(['rev-parse', '-q', '--verify', 'MERGE_HEAD']).ok;
		if (run.ok) return Passed;
		final unmerged: Array<String> = git(['diff', '--name-only', '--diff-filter=U']).lines();
		return Failed(unmerged.length > 0 ? 'git could not merge ${unmerged.join(', ')}' : run.firstError());
	}

	/** `apq.js`, `test.js` and `dev.js` rebuilt from the merged tree, at once. */
	private function build(): Outcome {
		_built = true;
		return _compile(_repo, Path.join([_logs, 'build.log']));
	}

	/** The merge committed under `message`, or `Merge <branch>: <the branch tip's subject>`. */
	private function commit(message: Null<String>): Outcome {
		final subject: String = message ?? 'Merge $_branch: ${git(['log', '-1', '--format=%s', _branch]).out.trim()}';
		final commit: Result = git(['commit', '--no-edit', '-m', subject]);
		if (!commit.ok) return Failed(commit.firstError());
		_merging = false;
		_summary.detail(git(['rev-parse', '--short', 'HEAD']).out.trim());
		return Passed;
	}

	/**
	 * `tools/battery.sh` over the merged tree, or a skip when there is no `request` (`--no-battery`). Quick or full is
	 * decided here, from what the merge brought in and the count of landings, and the row names why.
	 */
	private function runBattery(request: Null<BatteryRequest>): Outcome {
		if (request == null) return Skipped('--no-battery');
		final landing: Int = Tally.next(Path.join([request.cache, TALLY_DIR]));
		final why: Null<String> = fullReason(_merged(_repo), landing, request.full, request.every);
		final mode: String = why == null ? 'battery quick' : 'battery full: $why';
		_summary.detail(mode);
		final flags: Array<String> = batteryFlags(request.allowBlast, request.snapshot, why != null, request.leased);
		return switch _exec(flags, _repo, Path.join([_logs, 'battery.log'])) {
			case Failed(failure): Failed('$mode — $failure');
			case other: other;
		};
	}


	private function git(words: Array<String>): Result {
		return cmd('git -C $_repo $words').run();
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final message: Null<String> = args.option('-m');
		final noBattery: Bool = args.flag('--no-battery');
		final request: BatteryRequest = {
			allowBlast: args.flag('--allow-blast'),
			snapshot: args.flag('--snapshot'),
			full: args.flag('--full'),
			leased: Branches.leased(),
			cache: cacheDir(Sys.getEnv),
			every: FULL_EVERY
		};
		final repo: String = Repo.resolve(args.option('--repo'));
		final logsOption: Null<String> = args.option('--logs');
		final branch: String = args.positionals(['<branch>'])[0];
		if (!noBattery && (Sys.getEnv('ANYPARSE_HXFORMAT_FORK') ?? '') == '')
			throw new UsageError('the battery needs ANYPARSE_HXFORMAT_FORK — set it, or pass --no-battery');
		final logs: String = logsOption ?? Path.join([Sys.getEnv('TMPDIR') ?? '/tmp', 'anyparse-land', branch.replace('/', '-')]);
		FileSystem.createDirectory(logs);
		return land({
			repo: repo,
			branch: branch,
			logs: logs,
			message: message,
			battery: noBattery ? null : request,
			compile: Binaries.compile,
			exec: runScript,
			merged: mergedPaths,
			print: Sys.println
		});
	}

	/** The merge, the build and the battery of `options`; answers the exit status. */
	public static function land(options: LandOptions): Int {
		return new Land(options).run(options.message, options.battery);
	}

	/** `tools/battery.sh` with `flags` over `tree`, its output kept at `log`. */
	public static function runScript(flags: Array<String>, tree: String, log: String): Outcome {
		final run: Result = cmd('tools/battery.sh $flags').at(tree).timeout(BATTERY_TIMEOUT_MS).run();
		File.saveContent(log, run.out + run.err);
		return run.ok ? Passed : Failed('${run.firstError()} — $log');
	}

	/** The battery's snapshot directory as `tools/battery.sh` spells its default, given the environment `env` reads. */
	public static function cacheDir(env: String -> Null<String>): String {
		return env('ANYPARSE_BLAST_CACHE') ?? Path.join([env('HOME') ?? '', 'anyparse-blast-cache']);
	}

	/**
	 * The paths the merge commit of `tree` changes against its first parent — both sides of a rename — or null when git
	 * cannot say.
	 */
	public static function mergedPaths(tree: String): Null<Array<String>> {
		final diff: Result = cmd('git -C $tree diff --name-only --no-renames HEAD^1 HEAD').run();
		return diff.ok ? diff.lines() : null;
	}

	/**
	 * Why a landing runs the battery in full, or null when quick will do: it was asked for, the merge brought in a path
	 * where a shard and the one-process suite can diverge, its paths are unknown, or it is the `every`-th landing.
	 */
	public static function fullReason(changed: Null<Array<String>>, landing: Int, asked: Bool, every: Int): Null<String> {
		if (asked) return '--full';
		if (changed == null) return 'the merged paths are unknown';
		for (path in changed) for (prefix in DIVERGENCE_PATHS) if (path.startsWith(prefix)) return 'touches $path';
		return every > 0 && landing % every == 0 ? 'landing $landing' : null;
	}

	/**
	 * What `tools/battery.sh` is given. The monolith cross-check of the suite is not run at every landing, so `--quick`
	 * is the default (`fullReason` says when it is not); under a pool lease (`leased` threads) the suite takes the shards the
	 * lease leaves beside the battery's light branches, otherwise the script keeps its own count.
	 */
	public static function batteryFlags(allowBlast: Bool, snapshot: Bool, full: Bool, leased: Null<Int>): Array<String> {
		final flags: Array<String> = [];
		if (allowBlast) flags.push('--allow-blast');
		if (snapshot) flags.push('--snapshot');
		if (!full) flags.push('--quick');
		final shards: Null<Int> = Branches.share(leased, BATTERY_LIGHT_THREADS);
		if (shards != null) {
			flags.push('-n');
			flags.push('$shards');
		}
		return flags;
	}

}

/** The build of the three binaries `Land` runs after the merge: the tree and the log the transcripts go to. */
typedef Compile = (tree:String, log:String) -> Outcome;

/** The battery of a `Land` run: its flags, the snapshot directory that keeps the count of landings, and how often it runs in full. */
typedef BatteryRequest = {
	var allowBlast: Bool;
	var snapshot: Bool;

	/** Whether the full battery was asked for. */
	var full: Bool;

	var leased: Null<Int>;
	var cache: String;
	var every: Int;
}

/** The paths a merge brought into the tree, or null when they cannot be read. */
typedef MergedPaths = (tree:String) -> Null<Array<String>>;
/** The run of `tools/battery.sh`: its flags, the tree it runs over and the log it leaves. */
typedef BatteryExec = (flags:Array<String>, tree:String, log:String) -> Outcome;
/** What a run of `Land` is given: what to merge into where, and the two seams a test replaces (the build and the output). */
typedef LandOptions = {
	var repo: String;
	var branch: String;
	var logs: String;
	var message: Null<String>;

	/** The battery to run; null runs none. */
	var battery: Null<BatteryRequest>;

	var compile: Compile;
	var exec: BatteryExec;
	var merged: MergedPaths;
	var print: String -> Void;
}
