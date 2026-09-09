package anyparse.query;

import anyparse.check.Check.Violation;
import anyparse.query.LintDiff.LintDiffTally;
import anyparse.query.LintDiff.LintMessageIdentities;

/**
 * The findings a `--baseline` snapshot does NOT already carry — the delta a nudge or an edit
 * loop wants, and nothing else.
 *
 * WHY A SNAPSHOT AND NOT A LINE FILTER. The `PostToolUse` nudge behind a `hxq` write op has
 * to answer "did THIS edit introduce a finding", and it has only the file AFTER the edit. Every
 * cheaper answer lies the same way `LintDiff`'s own doc records: a text diff of two reports
 * re-keys every finding below the edit, because an inserted line moves their coordinates. So
 * the comparison is the one `LintDiff` already owns — a MULTISET over
 * `(file, rule, severity, message)` with the path and measurement normalizations that module
 * documents — and the only thing added here is the projection from a live `Violation` to the
 * key a recorded `LintFindingJson` produced, so the two compare at all.
 *
 * Pure by construction, like `LintDiff`: the CLI reads the snapshot, calls `added`, and writes
 * the refreshed one. That split is what lets a test state the multiset property directly
 * instead of through a process and a temp file.
 */
@:nullSafety(Strict)
final class LintBaseline {

	/**
	 * The `LintDiff` identity key of one live finding.
	 *
	 * `severity.label()` is the same spelling `LintFormat.recordOf` writes into the json
	 * record, which is what makes a live finding and a recorded one land on one key; reading
	 * the enum's ordinal instead would make every comparison a miss and the delta would
	 * silently be "everything is new".
	 */
	public static function keyOf(v: Violation, root: String, identities: LintMessageIdentities): String {
		return LintDiff.keyOf(
			LintDiff.normalizePath(v.file, root), v.rule, v.severity.label(),
			LintDiff.normalizeMessage(v.rule, v.message, root, identities)
		);
	}

	/**
	 * `all` minus what `baseline` already counted, in `all`'s own order.
	 *
	 * A MULTISET subtraction, not a set one: three `string-literal-dup` findings on one file
	 * share a key, and a run that turns three into four must report the fourth. Each match
	 * spends one unit of the baseline's count, so the surplus — and only the surplus — comes
	 * back.
	 *
	 * A baseline the run cannot read is the CALLER's problem, not this function's: handed an
	 * empty tally it returns `all`, which is the fail-open direction a nudge wants (say too
	 * much rather than nothing).
	 */
	public static function added(
		all: Array<Violation>, baseline: LintDiffTally, root: String, identities: LintMessageIdentities
	): Array<Violation> {
		// A copy, because the tally belongs to the caller and a second call over the same
		// baseline must see the same counts.
		final remaining: Map<String, Int> = baseline.counts.copy();
		return all.filter(v -> {
			final key: String = keyOf(v, root, identities);
			final left: Null<Int> = remaining[key];
			if (left == null || left <= 0) return true;
			remaining[key] = left - 1;
			return false;
		});
	}

}
