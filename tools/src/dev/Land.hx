package dev;

import anyparse.core.PoolLease;
import devkit.Args;
import devkit.Branches;
import devkit.Cmd.cmd;
import devkit.Lease;
import devkit.Result;
import devkit.Summary;
import devkit.Tally;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev land <branch>` — the parent's landing of a reviewed slice branch in the tree that holds this `dev.js`, as ONE
 * command: the branch's single commit is applied on top of the checked-out branch (`git cherry-pick --no-commit`), so the
 * history stays linear, its append-only files merging as their `.gitattributes` say (`docs/decisions.md` by union,
 * `mutation-arms.json` by `dev merge-arms`), the three binaries rebuilt, the commit made with a `Slice: <ID>` trailer, then
 * `dev battery` (quick, or in full when the commit brings in a path where a shard and the one-process suite can
 * diverge, or the number of the landing, counted over every landing that runs the battery, is a multiple of ten — the
 * battery row says which) — and one verdict line. A branch that does not carry exactly one commit over the checked-out one
 * is refused; a conflict git cannot resolve or a failed build rolls the tree back to where it was; a red battery leaves the
 * commit for the caller to judge (docs/testing.md § "Landing a slice"). Any step after the pick that does not pass — one
 * that threw (`not run`) as much as one that failed — rolls it back.
 */
@:nullSafety(Strict)
final class Land {

	public static inline final USAGE: String = 'usage: dev land <branch> [-m <message>] [--no-battery] [--full] [--allow-blast] '
		+ '[--allow <row>]... [--snapshot] [--logs <dir>] [--repo <tree>]';

	/** Every this-many-th landing runs the battery in full, whatever it touched. */
	public static inline final FULL_EVERY: Int = 10;

	/** The merge driver `.gitattributes` names for `test/testkit/mutation-arms.json`. */
	private static inline final ARMS_DRIVER: String = 'anyparse-arms';

	/** What the battery may run before it is killed. */
	private static inline final BATTERY_TIMEOUT_MS: Int = 3 * 60 * 60 * 1000;

	/** Where, under the battery's snapshot directory, the landings are counted. */
	private static inline final TALLY_DIR: String = 'landings';

	private static final NO_BATTERY: String = '--no-battery';

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
		'tools/src/dev/Battery.hx',
		'src/anyparse/query/SharedParseTier.hx',
		'src/anyparse/query/FormatConfigDiscovery.hx',
		'src/anyparse/grammar/haxe/HaxeQueryPlugin.hx',
		'src/anyparse/macro/QueryWalkerCodegen.hx',
		'src/anyparse/runtime/'
	];

	/** The paths under `DIVERGENCE_PATHS` that bring in no divergence: the arm registry is data, no runner or cache reads it. */
	private static final DIVERGENCE_EXEMPT: Array<String> = ['test/testkit/mutation-arms.json'];

	private final _summary: Summary = new Summary();
	private final _repo: String;
	private final _branch: String;
	private final _logs: String;
	private final _compile: Compile;
	private final _exec: BatteryExec;
	private final _merged: MergedPaths;
	private final _print: String -> Void;

	/** Whether the pick of this run has begun, so a failed step rolls the tree back. */
	private var _picking: Bool = false;

	/** The commit the checked-out branch was at when the pick began: the only place a rollback may go back to. */
	private var _before: String = '';

	/** Whether this run built the binaries from the picked tree. */
	private var _built: Bool = false;

	/** The snapshot key of the commit the checked-out branch was at when the landing began, or null before the base step. */
	private var _base: Null<String> = null;

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
	 * Every step in turn, each only while the ones before it passed; answers the exit status. A pick a failed step rolls
	 * back leaves binaries built from the picked tree behind (they are not tracked), so they are rebuilt from HEAD.
	 */
	private function run(message: Null<String>, battery: Null<BatteryRequest>): Int {
		final steps: Array<{ name: String, step: () -> Outcome }> = [
			{ name: 'clean', step: clean },
			{ name: 'branch', step: shape },
			{ name: 'base', step: ensureBase.bind(battery) },
			{ name: 'pick', step: pick },
			{ name: 'build', step: build },
			{ name: 'commit', step: commit.bind(message) },
			{ name: 'battery', step: runBattery.bind(battery) }
		];
		var aborted: Bool = false;
		for (s in steps) if (_summary.passed()) {
			final outcome: Outcome = _summary.time(s.name, s.step);
			if (!outcome.match(Passed | Skipped(_))) aborted = rollback() || aborted;
		}
		if (aborted && _built) _summary.time(
			'rebuild', () -> switch _compile(_repo, Path.join([_logs, 'rebuild.log'])) {
				case Failed(why): Failed('the binaries are still the rolled-back pick\'s: $why');
				case other:
					_summary.detail('binaries rebuilt from HEAD after the rollback');
					other;
			}
		);
		_print(_summary.table());
		final passed: Bool = _summary.passed();
		_print('land $_branch: ${passed ? 'PASS' : 'FAIL'} — logs $_logs');
		return passed ? 0 : 1;
	}

	/**
	 * Roll back the pick of this run, if one has begun. The tree is the user's and keeps changing while the steps run, so
	 * `git reset --merge` takes back only what the pick staged and a conflicted pick leaves, and refuses — leaving the tree to
	 * its owner — when the user edited a file of the pick; when HEAD is no longer where the pick began nothing is touched.
	 * A step that threw is as unfinished as one that failed, so the caller asks after every step that did not pass, whichever
	 * way it ended. Answers whether the pick was rolled back.
	 */
	private function rollback(): Bool {
		if (!_picking) return false;
		_picking = false;
		if (git(['rev-parse', 'HEAD']).out.trim() != _before) {
			_summary.add('rollback', Failed('HEAD moved since the pick began — not rolled back, the tree is as it is'));
			return false;
		}
		final reset: Result = git(['reset', '--merge', _before]);
		if (reset.ok) return true;
		_summary.add('rollback', Failed('`git reset --merge` refused: ${reset.firstError()} — the tree is as it is'));
		return false;
	}

	private function clean(): Outcome {
		final dirty: Array<String> = git(['status', '--porcelain', '--untracked-files=no']).lines();
		return dirty.length == 0 ? Passed : Failed('the tree has uncommitted changes, first `${dirty[0]}`');
	}

	/**
	 * The branch carries exactly one commit the checked-out one lacks, and it is not a merge: a history of one commit per
	 * slice is what makes a landing a plain pick, and a branch of several is for its author to squash.
	 */
	private function shape(): Outcome {
		if (!git(['rev-parse', '-q', '--verify', '$_branch^{commit}']).ok) return Failed('no branch `$_branch` here');
		final ahead: Array<String> = git(['rev-list', '--parents', 'HEAD..$_branch']).lines();
		if (ahead.length == 0) return Failed('`$_branch` has no commit the checked-out branch lacks');
		if (ahead.length > 1)
			return Failed(
				'`$_branch` carries ${ahead.length} commits over the checked-out branch, a landing takes one — squash it first '
				+ '(`git reset --soft $$(git merge-base HEAD $_branch) && git commit`)'
			);
		if (ahead[0].split(' ').length != 2) return Failed('the commit of `$_branch` is a merge or a root — a landing takes a plain one');
		final landed: Null<String> = landedAs();
		return landed == null ? Passed : Failed('`$_branch` is landed already as $landed');
	}

	/**
	 * The commit of the checked-out branch that landed the branch's commit, or null: one carrying this slice's `Slice`
	 * trailer, or — for a landing made without the trailer — one with the same patch. A landing makes a new commit, so the
	 * branch is never an ancestor of the branch it landed on.
	 */
	private function landedAs(): Null<String> {
		final id: String = sliceId(_branch);
		for (sha in git(['log', 'HEAD', '--fixed-strings', '--grep', 'Slice: $id', '--format=%h']).lines()) {
			final slices: Array<String> = git(['log', '-1', '--format=%(trailers:key=Slice,valueonly)', sha]).lines().map(l -> l.trim());
			if (slices.contains(id)) return sha;
		}
		for (line in git(['cherry', 'HEAD', _branch]).lines()) if (line.startsWith('- ')) return 'a commit with the same patch';
		return null;
	}

	/** `git cherry-pick --no-commit` of the branch's commit with the arm registry's driver named; a conflict it leaves fails the step. */
	private function pick(): Outcome {
		final dev: String = Path.join([_repo, 'bin/dev.js']);
		_before = git(['rev-parse', 'HEAD']).out.trim();
		_picking = true;
		final run: Result = git([
			'-c',
			'merge.$ARMS_DRIVER.driver=node $dev merge-arms %O %A %B',
			'cherry-pick',
			'--no-commit',
			_branch
		]);
		if (run.ok) return Passed;
		final unmerged: Array<String> = git(['diff', '--name-only', '--diff-filter=U']).lines();
		return Failed(unmerged.length > 0 ? 'git could not merge ${unmerged.join(', ')}' : run.firstError());
	}

	/** `apq.js`, `test.js` and `dev.js` rebuilt from the picked tree, at once. */
	private function build(): Outcome {
		_built = true;
		return _compile(_repo, Path.join([_logs, 'build.log']));
	}

	/**
	 * The pick committed under `message`, or the message of the branch's commit, with the author and date of that commit and
	 * a `Slice: <ID>` trailer unless the message names a slice already.
	 */
	private function commit(message: Null<String>): Outcome {
		final file: String = Path.join([_logs, 'commit-message.txt']);
		File.saveContent(file, '${(message ?? git(['log', '-1', '--format=%B', _branch]).out).trim()}\n');
		final trailer: Result = git([
			'interpret-trailers',
			'--in-place',
			'--if-exists',
			'doNothing',
			'--trailer',
			'Slice: ${sliceId(_branch)}',
			file
		]);
		if (!trailer.ok) return Failed(trailer.firstError());
		final author: String = git(['log', '-1', '--format=%an <%ae>', _branch]).out.trim();
		final date: String = git(['log', '-1', '--format=%aI', _branch]).out.trim();
		final commit: Result = git(['commit', '-F', file, '--author', author, '--date', date]);
		if (!commit.ok) return Failed(commit.firstError());
		_picking = false;
		_summary.detail(git(['rev-parse', '--short', 'HEAD']).out.trim());
		return Passed;
	}

	/**
	 * `dev battery` over the landed tree, or a skip when there is no `request` (`--no-battery`). Quick or full is
	 * decided here, from what the commit brought in and the count of landings, and the row names why.
	 */
	private function runBattery(request: Null<BatteryRequest>): Outcome {
		if (request == null) return Skipped(NO_BATTERY);
		final landing: Int = Tally.next(Path.join([request.cache, TALLY_DIR]));
		final why: Null<String> = fullReason(_merged(_repo), landing, request.full, request.every);
		final mode: String = why == null ? 'battery quick' : 'battery full: $why';
		_summary.detail(mode);
		final flags: Array<String> = batteryFlags(request.allowBlast, request.snapshot, why != null, request.leased, request.allow, _base);
		return switch _exec(flags, _repo, Path.join([_logs, 'battery.log'])) {
			case Failed(failure): Failed('$mode — $failure');
			case other: other;
		};
	}

	private function git(words: Array<String>): Result {
		return cmd('git -C $_repo $words').run();
	}

	/** The detached tree at `tree`, if one is there; a tree git will not remove is left and said so. */
	private function dropTree(tree: String): Void {
		if (!FileSystem.exists(tree)) return;
		final removed: Result = git(['worktree', 'remove', '--force', tree]);
		if (!removed.ok) _summary.detail('the tree $tree is left in place: ${removed.firstError()}');
	}

	/**
	 * The snapshot of the commit the landing merges onto, in the cache, before anything is picked: a landing is judged against
	 * that commit and no other, and a snapshot that cannot be had leaves the tree untouched. A missing one is made by a battery
	 * over a detached tree of that commit that compares nothing; the snapshot is a reading, so a red battery of the base
	 * still serves — only a base whose battery left no snapshot fails.
	 */
	private function ensureBase(request: Null<BatteryRequest>): Outcome {
		if (request == null) return Skipped(NO_BATTERY);
		final head: String = git(['rev-parse', 'HEAD']).out.trim();
		_base = Battery.keyOf(_repo, head);
		final base: Null<String> = _base;
		return base == null ? Passed : baseSnapshot(request, base, head);
	}

	private function baseSnapshot(request: BatteryRequest, base: String, head: String): Outcome {
		final file: String = Path.join([request.cache, '$base-suite.txt']);
		if (FileSystem.exists(file)) return Passed;
		final tree: String = Path.join([_logs, 'base-$base']);
		dropTree(tree);
		final added: Result = git(['worktree', 'add', '--detach', tree, head]);
		if (!added.ok) return Failed('no tree of the base $base to snapshot: ${added.firstError()}');
		_summary.detail('base $base had no snapshot — made');
		final flags: Array<String> = batteryFlags(false, true, false, request.leased, []).concat(['--no-base', '--repo', tree]);
		final outcome: Outcome = _exec(flags, _repo, Path.join([_logs, 'battery-base.log']));
		dropTree(tree);
		if (!FileSystem.exists(file)) return Failed('the snapshot of the base $base could not be made — ${why(outcome)}');
		if (!outcome.match(Passed)) _summary.detail('the battery of the base $base was red — its snapshot is the base all the same');
		return Passed;
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final message: Null<String> = args.option('-m');
		final noBattery: Bool = args.flag(NO_BATTERY);
		final request: BatteryRequest = {
			allowBlast: args.flag('--allow-blast'),
			snapshot: args.flag('--snapshot'),
			allow: args.options('--allow'),
			full: args.flag('--full'),
			leased: PoolLease.threads(),
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
			compile: (tree, log) -> Binaries.compileWith(tree, log, [], Lease.ofEnvironment()),
			exec: execBattery,
			merged: mergedPaths,
			print: Sys.println
		});
	}

	/** The pick, the build and the battery of `options`; answers the exit status. */
	public static function land(options: LandOptions): Int {
		return new Land(options).run(options.message, options.battery);
	}

	/** The slice id a branch carries: its name past the last `/`, without the `hxqb-` prefix (`batch/hxqb-LAND-2` is `LAND-2`). */
	public static function sliceId(branch: String): String {
		final name: String = branch.substr(branch.lastIndexOf('/') + 1);
		return name.startsWith('hxqb-') ? name.substr('hxqb-'.length) : name;
	}

	/** `dev battery` with `flags` over `tree`, its output kept at `log`. */
	public static function execBattery(flags: Array<String>, tree: String, log: String): Outcome {
		final run: Result = cmd('node bin/dev.js battery $flags').at(tree).timeout(BATTERY_TIMEOUT_MS).run();
		File.saveContent(log, run.out + run.err);
		return run.ok ? Passed : Failed('${run.firstError()} — $log');
	}

	/**
	 * The battery's snapshot directory, which also keeps the count of landings: `$ANYPARSE_BLAST_CACHE`,
	 * else `anyparse-blast-cache` under the home directory, given the environment `env` reads.
	 */
	public static function cacheDir(env: String -> Null<String>): String {
		return env('ANYPARSE_BLAST_CACHE') ?? Path.join([env('HOME') ?? '', 'anyparse-blast-cache']);
	}

	/**
	 * The paths the commit at the head of `tree` changes against its parent — both sides of a rename — or null when git
	 * cannot say.
	 */
	public static function mergedPaths(tree: String): Null<Array<String>> {
		final diff: Result = cmd('git -C $tree diff --name-only --no-renames HEAD~1 HEAD').run();
		return diff.ok ? diff.lines() : null;
	}

	/**
	 * Why a landing runs the battery in full, or null when quick will do: it was asked for, the commit brought in a path
	 * where a shard and the one-process suite can diverge, its paths are unknown, or it is the `every`-th landing.
	 */
	public static function fullReason(changed: Null<Array<String>>, landing: Int, asked: Bool, every: Int): Null<String> {
		if (asked) return '--full';
		if (changed == null) return 'the merged paths are unknown';
		for (path in changed)
			if (!DIVERGENCE_EXEMPT.contains(path))
				for (prefix in DIVERGENCE_PATHS)
					if (path.startsWith(prefix)) return 'touches $path';
		return every > 0 && landing % every == 0 ? 'landing $landing' : null;
	}

	/**
	 * What `dev battery` is given. The monolith cross-check of the suite is not run at every landing, so `--quick`
	 * is the default (`fullReason` says when it is not); under a pool lease (`leased` threads) the suite takes the shards the
	 * lease leaves beside the battery's light branches; otherwise the battery
	 * sizes it, from its own count or from the lease its suite's branch takes.
	 */
	public static function batteryFlags(
		allowBlast: Bool, snapshot: Bool, full: Bool, leased: Null<Int>, allow: Array<String>, ?base: String
	): Array<String> {
		final flags: Array<String> = [];
		if (allowBlast) flags.push('--allow-blast');
		if (snapshot) flags.push('--snapshot');
		for (row in allow) {
			flags.push('--allow');
			flags.push(row);
		}
		if (!full) flags.push('--quick');
		if (base != null) {
			flags.push('--base');
			flags.push(base);
		}
		final shards: Null<Int> = Branches.share(leased, Battery.lightThreads());
		if (shards != null) {
			flags.push('-n');
			flags.push('$shards');
		}
		return flags;
	}

	/** Why the battery of a base left no snapshot. */
	private static function why(outcome: Outcome): String {
		return switch outcome {
			case Failed(failure): failure;
			case _: 'it left none';
		};
	}

}

/** The build of the three binaries `Land` runs after the merge: the tree and the log the transcripts go to. */
typedef Compile = (tree:String, log:String) -> Outcome;

/** The battery of a `Land` run: its flags, the snapshot directory that keeps the count of landings, and how often it runs in full. */
typedef BatteryRequest = {
	var allowBlast: Bool;
	var snapshot: Bool;

	/** The battery rows whose failure the verdict waives, each reported as allowed (`dev battery --allow`). */
	var allow: Array<String>;

	/** Whether the full battery was asked for. */
	var full: Bool;

	var leased: Null<Int>;
	var cache: String;
	var every: Int;
}

/** The paths a merge brought into the tree, or null when they cannot be read. */
typedef MergedPaths = (tree:String) -> Null<Array<String>>;
/** The run of `dev battery`: its flags, the tree it runs over and the log it leaves. */
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
