package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import haxe.io.Path;

using StringTools;

/** What a commit on main is made of: its message, the paths it takes whole, and whether it replaces HEAD. */
typedef MainCommitPlan = {

	var message: Null<String>;
	var paths: Array<String>;
	var amend: Bool;

	/** Lines appended to the message after a blank line, such as `Co-Authored-By: …`. */
	var trailers: Array<String>;

}

/** How a commit reaches the land lock. */
typedef MainCommitLock = {

	/** The `wf-run` to take the lock through, or null for the one `LandLock.locate` finds. */
	var wfRun: Null<String>;

	/** The seconds to wait for a landing in flight. */
	var wait: Int;

	/** Commit without the lock: a landing in flight fails at its advance. */
	var unlocked: Bool;

}

/**
 * `dev main-commit [--amend] -m <message> <path>…` — the one answer to "how does the parent commit to main without moving it
 * under a landing": the paths are staged and committed whole inside `LandLock`, so a commit waits for a landing in flight and
 * a landing's advance never finds main moved. A tree dirty outside the named paths is refused, and an amend only of a commit
 * that is no landing and is not pushed. `dev decision --commit` is this command's `prelude` over the ledger.
 */
@:nullSafety(Strict)
final class MainCommit {

	public static inline final USAGE: String = 'usage: dev main-commit [--amend] [-m <message>] [--trailer <line>]… [--repo <dir>] [--wait <seconds>] '
		+ '[--wf-run <path> | --unlocked] <path>…';

	/** The trailer a landing writes on its commit, which an amend must not touch. */
	private static final LANDING_TRAILER: String = 'Slice';

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final amend: Bool = args.flag('--amend');
		final message: Null<String> = args.option('-m');
		final trailers: Array<String> = args.options('--trailer');
		final lock: MainCommitLock = lockOf(args);
		final repo: String = Repo.resolve(args.option('--repo'));
		final paths: Array<String> = args.rest(['<path>']);
		if (message == null && !amend) throw new UsageError('missing -m <message>');
		return commit(repo, {
			message: message,
			paths: paths,
			amend: amend,
			trailers: trailers
		}, lock, () -> {});
	}

	/** The lock options of `args`: `--wf-run`, `--wait` and `--unlocked`. */
	public static function lockOf(args: Args): MainCommitLock {
		final seconds: Int = Std.parseInt(args.option('--wait') ?? '${LandLock.DEFAULT_WAIT}') ?? -1;
		if (seconds < 0) throw new UsageError('--wait takes a number of seconds');
		return { wfRun: args.option('--wf-run'), wait: seconds, unlocked: args.flag('--unlocked') };
	}

	/**
	 * `plan` committed on `repo`'s checked-out branch under the land lock, after `prelude` (a write into the named paths) ran
	 * inside it; answers the exit status. Nothing is written when the lock is not granted, and a refusal throws before `prelude`.
	 */
	public static function commit(repo: String, plan: MainCommitPlan, lock: MainCommitLock, prelude: () -> Void): Int {
		if (lock.unlocked) {
			Sys.println('main-commit: NO LOCK — a landing in flight fails at its advance');
			return commitHeld(repo, plan, prelude);
		}
		final wfRun: Null<String> = lock.wfRun ?? LandLock.locate(Sys.getEnv('WF_PLUGIN_ROOT'), Sys.getEnv('HOME'));
		if (wfRun == null) throw new UsageError('no wf-run found to take the lock through — pass --wf-run <path>, or --unlocked');
		return LandLock.hold(
			wfRun, lock.wait, 'main-commit', text -> Sys.println('main-commit: $text'), () -> commitHeld(repo, plan, prelude)
		);
	}

	/** Whether the changed file `changed` is one of `paths` or lies under one. */
	public static function covered(paths: Array<String>, changed: String): Bool {
		for (path in paths) {
			final dir: String = path.endsWith('/') ? path : '$path/';
			if (changed == path || changed.startsWith(dir)) return true;
		}
		return false;
	}

	/** `plan` committed, the land lock being held by the caller. */
	private static function commitHeld(repo: String, plan: MainCommitPlan, prelude: () -> Void): Int {
		final paths: Array<String> = plan.paths;
		if (!git(repo, ['symbolic-ref', '-q', 'HEAD']).ok) throw new UsageError('refused: HEAD is detached — no branch to commit to');
		for (path in paths) if (path == '' || Path.isAbsolute(path) || path.startsWith('..'))
			throw new UsageError('refused: `$path` is not a path inside the tree');
		final outside: Array<String> = git(repo, ['-c', 'core.quotepath=off', 'diff', '--name-only', 'HEAD'])
			.lines()
			.filter(changed -> !covered(paths, changed));
		if (outside.length > 0)
			throw new UsageError('refused: the tree has uncommitted changes outside ${paths.join(' ')}, first `${outside[0]}`');
		if (plan.amend) {
			final landing: String = git(repo, ['log', '-1', '--format=%(trailers:key=$LANDING_TRAILER,valueonly)']).out.trim();
			if (landing != '') throw new UsageError('refused: HEAD is a landing (Slice: $landing) — an amend would rewrite it');
			final pushed: Array<String> = git(repo, ['branch', '--remotes', '--contains', 'HEAD']).lines();
			if (pushed.length > 0) throw new UsageError('refused: HEAD is pushed (${pushed[0].trim()}) — an amend would rewrite it');
		}
		prelude();
		final failure: Null<String> = stage(repo, plan);
		if (failure != null) {
			final unstaged: Result = git(repo, ['reset', '--quiet', '--'].concat(paths));
			throw new UsageError('$failure — the paths are left changed${unstaged.ok ? ' and unstaged' : ''}');
		}
		final made: Result = git(repo, ['log', '-1', '--format=%h %s']);
		Sys.println('main-commit: ${made.out.trim()}');
		return 0;
	}

	/** The paths staged and committed; answers why not, or null. */
	private static function stage(repo: String, plan: MainCommitPlan): Null<String> {
		final paths: Array<String> = plan.paths;
		final added: Result = git(repo, ['add', '--all', '--'].concat(paths));
		if (!added.ok) return added.firstError();
		if (!plan.amend && git(repo, ['diff', '--cached', '--quiet', '--'].concat(paths)).ok)
			return 'refused: nothing to commit in ${paths.join(' ')}';
		final message: Null<String> = plan.message;
		final words: Array<String> = ['commit', '--quiet'];
		if (plan.amend) words.push('--amend');
		if (message == null) {
			words.push('--no-edit');
		} else {
			words.push('-m');
			words.push(plan.trailers.length == 0 ? message : '$message\n\n${plan.trailers.join('\n')}');
		}
		final committed: Result = git(repo, words.concat(['--']).concat(paths));
		return committed.ok ? null : committed.firstError();
	}

	private static function git(repo: String, words: Array<String>): Result {
		return cmd('git -C $repo $words').run();
	}

}
