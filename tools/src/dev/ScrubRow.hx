package dev;

import devkit.Result;
import devkit.Summary.Outcome;

/**
 * The one answer to "what does the slice gate's `scrub` row say of its two `scrub-guard` runs": a failing run is `Failed`
 * whatever the other run said, and only a clean pair can be `NotRun` — when the tree scan had no token list to check.
 */
@:nullSafety(Strict)
final class ScrubRow {

	/** What `scrub-guard` writes on stderr when nothing is configured for the tree scan. */
	private static inline final UNCONFIGURED: String = 'nothing checked';

	/** The verdict of the row from the tree scan `tree` and the range scan `range`. */
	public static function verdict(tree: Result, range: Result): Outcome {
		if (!tree.ok || !range.ok) return Failed(GateTree.quote(tree.ok ? range : tree));
		return tree.err.indexOf(UNCONFIGURED) >= 0
			? NotRun('no token list — set ANYPARSE_SCRUB_LIST (or ANYPARSE_SCRUB_PRIVATE_ROOTS)')
			: Passed;
	}

}
