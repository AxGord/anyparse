package anyparse.check;

import anyparse.check.ThreadSafetyOptions.BoundedRepeatEntry;
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
 * evidence for each number belongs beside its entry, as the unread `evidence` key (`ThreadSafetyOptions`), never in
 * code. The options are read and checked by `ThreadSafetyOptions`; an entry matching no function is said.
 */
@:nullSafety(Strict)
final class BoundedRepeats {

	/**
	 * The well-formed entries `records` (`ThreadSafetyOptions.boundedRepeats`) resolved over `graph`; an entry whose `site`
	 * or `call` matches no function of the run bounds nothing, and is said in `problems`.
	 */
	public static function entries(records: Array<BoundedRepeatEntry>, graph: CallGraph, problems: Array<String>): Array<BoundedRepeat> {
		final out: Array<BoundedRepeat> = [];
		for (record in records) {
			final members: Array<String> = graph.matchIds(record.site);
			final call: Null<String> = record.call;
			final calls: Null<Array<String>> = call == null ? null : graph.matchIds(call);
			if (members.length == 0)
				problems.push('boundedRepeats site "${record.site}" matches no function of the run — it bounds nothing');
			if (call != null && calls != null && calls.length == 0)
				problems.push('boundedRepeats call "$call" (site "${record.site}") matches no function of the run — it bounds nothing');
			out.push({
				members: members,
				calls: calls,
				max: record.max,
				costMs: record.costMs
			});
		}
		return out;
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
