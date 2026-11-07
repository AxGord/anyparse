package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary.Outcome;
import sys.FileSystem;

using StringTools;

/**
 * The one answer to "where is a landing made and judged before main moves": a detached worktree of the commit the main
 * checkout is at, in which `dev land` picks, builds, commits and runs the battery. Main's checkout moves only in `advance`,
 * a fast-forward to the candidate commit, so a landing that stops anywhere before it leaves main's branch, index and files
 * as they were, never mid-pick.
 */
@:nullSafety(Strict)
final class LandCandidate {

	/** The commit main was at when the tree was opened: the candidate's parent, and the only commit main may move from. */
	public var before(default, null): String = '';

	/** The candidate commit, or null before `made`. */
	public var commit(default, null): Null<String> = null;

	/** Whether main was fast-forwarded to the candidate. */
	public var advanced(default, null): Bool = false;

	/** The directory of the candidate tree. */
	public final tree: String;

	/** The main checkout. */
	private final _repo: String;

	public function new(repo: String, tree: String) {
		_repo = repo;
		this.tree = tree;
	}

	/** A detached tree of main's HEAD at `tree`, whatever an earlier run left there dropped first. */
	public function open(): Outcome {
		before = main(['rev-parse', 'HEAD']).out.trim();
		final left: Null<String> = drop();
		if (left != null) return Failed('the tree ${tree} an earlier landing left cannot be removed: $left');
		final added: Result = main(['worktree', 'add', '--force', '--detach', tree, before]);
		return added.ok ? Passed : Failed('no candidate tree of ${short(before)}: ${added.firstError()}');
	}

	/** `git` in the candidate tree. */
	public function git(words: Array<String>): Result {
		return cmd('git -C $tree $words').run();
	}

	/** The candidate tree's HEAD taken as the candidate commit; answers its short name. */
	public function made(): String {
		final head: String = git(['rev-parse', 'HEAD']).out.trim();
		commit = head;
		return short(head);
	}

	/**
	 * Main's checkout fast-forwarded to the candidate commit. Refused while main is not at the commit the candidate grew from
	 * (a fast-forward from an older commit would bring back what was taken off main), and by git when the move would
	 * overwrite a file changed in main's checkout; a refusal leaves main as it is.
	 */
	public function advance(): Outcome {
		final candidate: Null<String> = commit;
		if (candidate == null) return Failed('no candidate commit to move main to');
		final head: String = main(['rev-parse', 'HEAD']).out.trim();
		if (head != before) return Failed('main moved since the landing began (${short(before)} is now ${short(head)}) — not advanced');
		final moved: Result = main(['merge', '--ff-only', '--quiet', candidate]);
		if (!moved.ok) return Failed('`git merge --ff-only` refused: ${moved.firstError()} — main is as it was');
		advanced = true;
		return Passed;
	}

	/** The candidate tree removed; answers why it is left in place, or null. */
	public function drop(): Null<String> {
		if (!FileSystem.exists(tree)) return null;
		final removed: Result = main(['worktree', 'remove', '--force', tree]);
		return removed.ok ? null : removed.firstError();
	}

	/** Where main stands after the run, and the candidate a landing that did not advance made: the verdict's middle. */
	public function standing(): String {
		final candidate: Null<String> = commit;
		if (advanced && candidate != null) return 'main at ${short(candidate)}';
		final at: String = before == '' ? '' : ' at ${short(before)}';
		return candidate == null ? 'main untouched$at' : 'main untouched$at, candidate ${short(candidate)}';
	}

	/** The files under `bin/` git ignores in the candidate tree: what its build made, since a fresh tree holds none. */
	public function built(): Array<String> {
		return git(['ls-files', '--others', '--ignored', '--exclude-standard', '--', 'bin']).lines();
	}

	private function main(words: Array<String>): Result {
		return cmd('git -C $_repo $words').run();
	}

	private function short(sha: String): String {
		return main(['rev-parse', '--short', sha]).out.trim();
	}

}
