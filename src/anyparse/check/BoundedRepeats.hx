package anyparse.check;

import anyparse.check.ThreadSafetyOptions.BoundedRepeatEntry;
import anyparse.query.CallGraph;

/**
 * One `boundedRepeats` entry, resolved: the one repetition of `member` (of its call into `calls`, when named) runs at most `max` times.
 */
typedef BoundedRepeat = {
	/** The `site` as written, naming the entry in a notice. */
	final site: String;

	/** The graph id of the one member `site` names. */
	final member: String;

	/** The graph ids of the call it repeats; null: the member's one repetition, whatever it calls. */
	final calls: Null<Array<String>>;

	/** The header of the loop it bounds (`CallRepetition.loopLabel`, `for (id in update)`); null: whichever one repetition is there. */
	final loop: Null<String>;

	final max: Float;

	/** The measured worst cost of one repetition — every short sink call it makes — in milliseconds. */
	final costMs: Float;
}

/**
 * `boundedRepeats` / `repeatBudgetMs`: a repetition whose iteration count is bounded small does not make a short sink
 * long. Positive and mechanical: an entry names ONE member (`site`, a `Type.member` id, no pattern) and binds ONE
 * repetition of its code — a loop, or a function value handed to a call that may run it repeatedly — the
 * only one there, the loop whose header `loop` spells (`for (id in update)`, whitespace aside), or the
 * one around the call `call` names (`CallRepetition`); the bound (`max`, pointed at in code or measured)
 * and the measured worst cost of one repetition (`costMs`) make it count as once while `max × costMs` stays under
 * `repeatBudgetMs`. Every other repetition of the member — a loop nested in the bound one, a sibling loop, a loop in a
 * lambda the member defines — stays repeating. A call several bound repetitions enclose in one function runs the
 * product of their bounds, judged against the budget once; repetitions in different functions on one main-thread way
 * do NOT add up — each is judged alone. The options are read and checked by `ThreadSafetyOptions` (a field of the wrong
 * type, a `max` or `costMs` that is not positive, a `site` pattern, an unknown key); here an entry whose `site` names no
 * member or several, or whose `call` names nothing, is dropped whole and said, never widened, and `CallRepetition` says
 * an entry binding no repetition or several. The evidence for each number lives in the project's config (`evidence`),
 * never in code.
 */
@:nullSafety(Strict)
final class BoundedRepeats {

	/**
	 * The well-formed entries `records` (`ThreadSafetyOptions.boundedRepeats`) resolved over `graph`; an entry whose `site`
	 * names no function of the run or several, or whose `call` names nothing, bounds nothing, and is said in `problems`.
	 */
	public static function entries(records: Array<BoundedRepeatEntry>, graph: CallGraph, problems: Array<String>): Array<BoundedRepeat> {
		final out: Array<BoundedRepeat> = [];
		for (record in records) {
			final members: Array<String> = graph.matchIds(record.site);
			final call: Null<String> = record.call;
			final calls: Null<Array<String>> = call == null ? null : graph.matchIds(call);
			final loop: Null<String> = record.loop;
			if (members.length == 0)
				problems.push('boundedRepeats site "${record.site}" matches no function of the run — it bounds nothing');
			else if (members.length > 1)
				problems.push('boundedRepeats site "${record.site}" names ${members.length} functions, not one — it bounds nothing');
			else if (call != null && calls != null && calls.length == 0)
				problems.push('boundedRepeats call "$call" (site "${record.site}") matches no function of the run — it bounds nothing');
			else
				out.push({
					site: record.site,
					member: members[0],
					calls: calls,
					loop: loop == null ? null : StringTools.trim(~/\s+/g.replace(loop, ' ')),
					max: record.max,
					costMs: record.costMs
				});
		}
		return out;
	}

}
