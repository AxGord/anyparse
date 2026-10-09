package anyparse.check;

import anyparse.query.CallGraph;

using Lambda;

/** One `boundedRepeats` entry, resolved: the repeating calls of `members` (into `calls`, when named) run at most `max` times. */
typedef BoundedRepeat = {
	/** The graph ids of the member the repeating call sits in. */
	final members: Array<String>;

	/** The graph ids of the call it repeats; null: every repeating call of the member. */
	final calls: Null<Array<String>>;

	final max: Float;

	/** The measured worst cost of one repetition — every short sink call it makes — in milliseconds. */
	final costMs: Float;
}

/**
 * `boundedRepeats` / `repeatBudgetMs`: a repetition whose iteration count is bounded small does not make a short sink
 * long. Positive and mechanical: an entry names the member a repeating call sits in (`site`, a `lockPairs`-style
 * pattern; `call` narrows it to one repeated call), the bound (`max`, pointed at in code or measured) and the measured
 * worst cost of one repetition (`costMs`); the repetition counts as once only when `max × costMs` stays under
 * `repeatBudgetMs`. An unlisted repetition, an entry missing a number, or a rule with no budget stays repeating. The
 * evidence for each number lives in the project's docs, never in code.
 */
@:nullSafety(Strict)
final class BoundedRepeats {

	/** The budget `repeatBudgetMs` of `config`'s `thread-safety`, or null when unset or not a positive number. */
	public static function budget(config: LintConfig): Null<Float> {
		final value: Null<Float> = config.numberOption('thread-safety', 'repeatBudgetMs');
		return value != null && value > 0 ? value : null;
	}

	/** The well-formed `boundedRepeats` entries of `config`, resolved over `graph`; a malformed one is dropped. */
	public static function entries(config: LintConfig, graph: CallGraph): Array<BoundedRepeat> {
		final out: Array<BoundedRepeat> = [];
		for (record in config.recordListOption('thread-safety', 'boundedRepeats')) {
			final site: Null<String> = record.strings['site'];
			final max: Float = record.numbers['max'] ?? 0;
			final cost: Float = record.numbers['costMs'] ?? -1;
			if (site == null || !(max > 0) || !(cost >= 0)) continue;
			final call: Null<String> = record.strings['call'];
			out.push({
				members: graph.matchIds(site),
				calls: call == null ? null : graph.matchIds(call),
				max: max,
				costMs: cost
			});
		}
		return out;
	}

	/** The signature of `config`'s entries and budget, telling two option sets apart. */
	public static function signature(config: LintConfig): String {
		return [
				for (r in config.recordListOption('thread-safety', 'boundedRepeats'))
					'${r.strings['site']}>${r.strings['call']}:${r.numbers['max']}x${r.numbers['costMs']}'
			].join(',') + '\t${budget(config)}';
	}

	/**
	 * Whether the repeating call into `callee` from `member` runs few enough times, each cheap enough, that it repeats
	 * nothing: an entry of `bounded` names it and `max × costMs < budget`.
	 */
	public static function short(bounded: Array<BoundedRepeat>, budget: Null<Float>, member: String, callee: String): Bool {
		if (budget == null) return false;
		final limit: Float = budget;
		return bounded.exists(b -> b.members.contains(member) && (b.calls == null || b.calls.contains(callee)) && b.max * b.costMs < limit);
	}

}
