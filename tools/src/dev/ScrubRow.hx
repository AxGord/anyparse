package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import devkit.Summary.Outcome;

using StringTools;

/**
 * The one answer to "what does the slice gate's `scrub` row say of its two `scrub-guard` runs, and from which commit does the
 * range run start": a failing run is `Failed` whatever the other run said, and only a clean pair can be `NotRun` — when the tree
 * scan had no token list to check and the machine did not declare nothing private (`PrivateDeclaration`), which makes the row
 * `Skipped`.
 */
@:nullSafety(Strict)
final class ScrubRow {

	/** What `scrub-guard` writes on stderr when nothing is configured for the tree scan. */
	private static final UNCONFIGURED: String = 'nothing checked';

	/** Where the range scan of the scrub row starts: the last commit the slice shares with main, whatever base was recorded. */
	public static function rangeStart(tree: String): String {
		return GateTree.gitIn(tree, ['merge-base', 'main', 'HEAD']).trim();
	}

	/**
	 * Why `base` cannot be trusted as the slice's start, or null when main contains it. A commit under a base main does not
	 * contain is on no history the gate reads, so the range scan would pass it unread.
	 */
	public static function staleBase(tree: String, base: String): Null<String> {
		if (cmd('git -C $tree merge-base --is-ancestor $base main').run().ok) return null;
		final short: String = GateTree.short(base);
		return 'base $short is not an ancestor of main: run `git rebase --onto main $short` in the worktree';
	}

	/** The verdict of the row from the tree scan `tree` and the range scan `range`. */
	public static function verdict(tree: Result, range: Result): Outcome {
		return if (!tree.ok || !range.ok)
			Failed(GateTree.quote(tree.ok ? range : tree))
		else if (tree.err.indexOf(UNCONFIGURED) >= 0)
			PrivateDeclaration.unlessDeclared(
				'no token list — set ANYPARSE_SCRUB_LIST (or ANYPARSE_SCRUB_PRIVATE_ROOTS), or declare ${PrivateDeclaration.VAR}=none'
			)
		else
			Passed;
	}

}
