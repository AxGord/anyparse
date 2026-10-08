package anyparse.query;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.query.LintDiff.LintDiffPool;
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
 * the comparison is the one `LintDiff` already owns — a MULTISET over `(file, rule, severity, message)`, or `(file, rule,
 * severity, family, member, subject)` for a finding carrying a structured identity (`LintDiff.keyFor`), with the path and
 * measurement normalizations that module documents — and the only thing added here is the projection from a live `Violation` to the
 * key a recorded `LintFindingJson` produced, so the two compare at all.
 *
 * Pure by construction, like `LintDiff`: the CLI reads the snapshot, calls `added`, and writes
 * the refreshed one. That split is what lets a test state the multiset property directly
 * instead of through a process and a temp file.
 */
@:nullSafety(Strict)
final class LintBaseline {

	/**
	 * The `LintDiff` key of one live finding (`LintDiff.keyFor`) — the key `LintDiff.tally` gives the recorded side.
	 *
	 * `severity.label()` is the same spelling `LintFormat.recordOf` writes into the json
	 * record, which is what makes a live finding and a recorded one land on one key; reading
	 * the enum's ordinal instead would make every comparison a miss and the delta would
	 * silently be "everything is new".
	 */
	public static function keyOf(v: Violation, root: String, identities: LintMessageIdentities): String {
		final data: Null<FindingData> = v.data;
		return LintDiff.keyFor(
			LintDiff.normalizePath(v.file, root), v.rule, v.severity.label(),
			LintDiff.normalizeMessage(v.rule, v.message, root, identities), data
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
	 * empty tally it returns `all`, which is the fail-open direction a nudge wants (say too much rather than nothing).
	 *
	 * A finding no occurrence of its own key accounts for is then paired with one keyed the other way across `data`
	 * (`LintDiff.spendAcross`) — the pairing `lint-diff` makes, from the same pool, after every finding spent its own key.
	 */
	public static function added(
		all: Array<Violation>, baseline: LintDiffTally, root: String, identities: LintMessageIdentities
	): Array<Violation> {
		// a pool, because the tally belongs to the caller and a second call over the same baseline must see the same counts
		final pool: LintDiffPool = LintDiff.pool(baseline);
		final messages: Array<String> = [for (v in all) LintDiff.normalizeMessage(v.rule, v.message, root, identities)];
		// every finding spends its own key before any spends across `data`, so the answer does not hang on the run's order
		final spent: Array<Bool> = [
			for (i in 0...all.length) LintDiff.spendOwn(pool, keyOf(all[i], root, identities), messages[i])
		];
		for (i => v in all) if (!spent[i])
			spent[i] = LintDiff.spendAcross(
				pool, LintDiff.normalizePath(v.file, root), v.rule, v.severity.label(), messages[i], v.data != null
			);
		return [for (i => v in all) if (!spent[i]) v];
	}

}
