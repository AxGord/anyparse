package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev land <branch>` — the parent's merge of a reviewed slice branch into the tree that holds this `dev.js`, as ONE
 * command: a `--no-ff` merge whose append-only files merge as their `.gitattributes` say (`docs/decisions.md` by union,
 * `mutation-arms.json` by `dev merge-arms`), the three binaries rebuilt, the merge committed, then `tools/battery.sh` —
 * and one verdict line. A conflict git cannot resolve or a failed build aborts the merge and leaves the tree as it was; a
 * red battery leaves the merge commit for the caller to judge (docs/testing.md § "Landing a slice").
 */
@:nullSafety(Strict)
final class Land {

	public static inline final USAGE: String = 'usage: dev land <branch> [-m <message>] [--no-battery] [--allow-blast] [--snapshot] '
		+ '[--logs <dir>] [--repo <tree>]';

	/** The merge driver `.gitattributes` names for `test/testkit/mutation-arms.json`. */
	private static inline final ARMS_DRIVER: String = 'anyparse-arms';

	/** What the battery may run before it is killed. */
	private static inline final BATTERY_TIMEOUT_MS: Int = 3 * 60 * 60 * 1000;

	private final _summary: Summary = new Summary();
	private final _repo: String;
	private final _branch: String;
	private final _logs: String;

	/** Whether a merge of this run is in progress, so a failed step aborts it. */
	private var _merging: Bool = false;

	/** Whether this run built the binaries from a merged tree. */
	private var _built: Bool = false;

	private function new(repo: String, branch: String, logs: String) {
		_repo = repo;
		_branch = branch;
		_logs = logs;
	}

	/**
	 * Every step in turn, each only while the ones before it passed; answers the exit status. A merge a failed step aborts
	 * leaves binaries built from the merged tree behind (they are not tracked), so they are rebuilt from HEAD.
	 */
	private function run(message: Null<String>, battery: Null<Array<String>>): Int {
		final steps: Array<{ name: String, step: () -> Outcome }> = [
			{ name: 'clean', step: clean },
			{ name: 'merge', step: merge },
			{ name: 'build', step: build },
			{ name: 'commit', step: commit.bind(message) },
			{ name: 'battery', step: runBattery.bind(battery) }
		];
		var aborted: Bool = false;
		for (s in steps) if (_summary.passed()) _summary.time(s.name, () -> {
			final outcome: Outcome = s.step();
			if (!outcome.match(Passed | Skipped(_)) && _merging) {
				if (!git(['merge', '--abort']).ok)
					_summary.add('abort', Failed('`git merge --abort` failed — the tree is still mid-merge'));
				aborted = true;
			}
			return outcome;
		});
		if (aborted && _built) _summary.time(
			'rebuild', () -> switch Binaries.compile(_repo, Path.join([_logs, 'rebuild.log'])) {
				case Failed(why): Failed('the binaries are still the aborted merge\'s: $why');
				case other:
					_summary.detail('binaries rebuilt from HEAD after the abort');
					other;
			}
		);
		Sys.println(_summary.table());
		final passed: Bool = _summary.passed();
		Sys.println('land $_branch: ${passed ? 'PASS' : 'FAIL'} — logs $_logs');
		return passed ? 0 : 1;
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
		return Binaries.compile(_repo, Path.join([_logs, 'build.log']));
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

	/** `tools/battery.sh` with `flags` over the merged tree, or a skip when `flags` is null (`--no-battery`). */
	private function runBattery(flags: Null<Array<String>>): Outcome {
		if (flags == null) return Skipped('--no-battery');
		final run: Result = cmd('tools/battery.sh $flags').at(_repo).timeout(BATTERY_TIMEOUT_MS).run();
		final log: String = Path.join([_logs, 'battery.log']);
		File.saveContent(log, run.out + run.err);
		return run.ok ? Passed : Failed('${run.firstError()} — $log');
	}

	private function git(words: Array<String>): Result {
		return cmd('git -C $_repo $words').run();
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final message: Null<String> = args.option('-m');
		final noBattery: Bool = args.flag('--no-battery');
		final battery: Array<String> = [for (flag in ['--allow-blast', '--snapshot']) if (args.flag(flag)) flag];
		final repo: String = Repo.resolve(args.option('--repo'));
		final logsOption: Null<String> = args.option('--logs');
		final branch: String = args.positionals(['<branch>'])[0];
		if (!noBattery && (Sys.getEnv('ANYPARSE_HXFORMAT_FORK') ?? '') == '')
			throw new UsageError('the battery needs ANYPARSE_HXFORMAT_FORK — set it, or pass --no-battery');
		final logs: String = logsOption ?? Path.join([Sys.getEnv('TMPDIR') ?? '/tmp', 'anyparse-land', branch.replace('/', '-')]);
		FileSystem.createDirectory(logs);
		return new Land(repo, branch, logs).run(message, noBattery ? null : battery);
	}

}
