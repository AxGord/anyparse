package anyparse.check;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueWriter;
import anyparse.query.CallGraph;

/**
 * One `boundedRepeats` entry, resolved: the one repetition of `member` (of its call into `calls`, when named) runs at most `max` times.
 */
typedef BoundedRepeat = {
	/** The `site` as written, naming the entry in a notice. */
	final site: String;

	/** The graph id of the one member `site` names; null for a dropped entry. */
	final member: Null<String>;

	/** The graph ids of the call it repeats; null: the member's one repetition, whatever it calls. */
	final calls: Null<Array<String>>;

	/** The header of the loop it bounds (`CallRepetition.loopLabel`, `for (id in update)`); null: whichever one repetition is there. */
	final loop: Null<String>;

	final max: Float;

	/** The measured worst cost of one repetition — every short sink call it makes — in milliseconds. */
	final costMs: Float;

	/** Why the entry is dropped and bounds nothing; null for a well-formed one. */
	final problem: Null<String>;
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
 * do NOT add up — each is judged alone. An entry that is not an object of `site`, `max`, `costMs` and optional `call`,
 * `loop` and `evidence` — a field of the wrong type, a `max` or `costMs` that is not positive, a `site` naming no member or
 * several, a `call` naming nothing, an unknown key — is dropped whole, with the reason (`problem`), never widened. The
 * evidence for each number lives in the project's config (`evidence`), never in code.
 */
@:nullSafety(Strict)
final class BoundedRepeats {

	/** The fields an entry may carry. */
	private static final KEYS: Array<String> = ['site', 'call', 'loop', 'max', 'costMs', 'evidence'];

	/** The budget `repeatBudgetMs` of `config`'s `thread-safety`, or null when unset or not a positive number. */
	public static function budget(config: LintConfig): Null<Float> {
		final value: Null<Float> = config.numberOption('thread-safety', 'repeatBudgetMs');
		return value != null && value > 0 ? value : null;
	}

	/**
	 * The `boundedRepeats` entries of `config`, resolved over `graph`; a malformed one is kept dropped, naming its `problem`.
	 */
	public static function entries(config: LintConfig, graph: CallGraph): Array<BoundedRepeat> {
		final raw: Null<JValue> = config.jsonOption('thread-safety', 'boundedRepeats');
		return switch raw {
			case null: [];
			case JArray(items): [for (item in items) entry(item, graph)];
			case _: [dropped('boundedRepeats', 'the option is not a list of objects')];
		}
	}

	/**
	 * The signature of `config`'s entries, as written, and budget, telling two option sets apart.
	 */
	public static function signature(config: LintConfig): String {
		final raw: Null<JValue> = config.jsonOption('thread-safety', 'boundedRepeats');
		return (raw == null ? '' : JValueWriter.write(raw)) + '\t${budget(config)}';
	}

	/** The entry `item` resolved over `graph`, or dropped naming why. */
	private static function entry(item: JValue, graph: CallGraph): BoundedRepeat {
		final fields: Null<Map<String, JValue>> = fieldsOf(item);
		if (fields == null) return dropped('?', 'the entry is not an object');
		final written: Null<String> = stringOf(fields['site']);
		final site: String = written ?? '?';
		for (key in fields.keys()) if (!KEYS.contains(key)) return dropped(site, 'unknown key "$key"');
		if (written == null) return dropped(site, '`site` is not a string');
		if (site.indexOf('*') >= 0) return dropped(site, '`site` is a pattern, not one member');
		final members: Array<String> = graph.matchIds(site);
		if (members.length != 1) return dropped(site, '`site` names ${members.length} members, not one');
		final max: Float = numberOf(fields['max']) ?? 0;
		if (!(max > 0)) return dropped(site, '`max` is not a positive number');
		final cost: Float = numberOf(fields['costMs']) ?? 0;
		if (!(cost > 0)) return dropped(site, '`costMs` is not a positive number');
		for (key in ['call', 'loop']) if (fields.exists(key) && stringOf(fields[key]) == null)
			return dropped(site, '`$key` is not a string');
		final call: Null<String> = stringOf(fields['call']);
		final calls: Null<Array<String>> = call == null ? null : graph.matchIds(call);
		if (calls != null && calls.length == 0) return dropped(site, '`call` "$call" names nothing');
		final loop: Null<String> = stringOf(fields['loop']);
		return {
			site: site,
			member: members[0],
			calls: calls,
			loop: loop == null ? null : StringTools.trim(~/\s+/g.replace(loop, ' ')),
			max: max,
			costMs: cost,
			problem: null
		};
	}

	/** An entry that bounds nothing, naming `site` and why. */
	private static function dropped(site: String, problem: String): BoundedRepeat {
		return {
			site: site,
			member: null,
			calls: null,
			loop: null,
			max: 0,
			costMs: 0,
			problem: problem
		};
	}

	/** The fields of the object `item` by key; null when it is no object. */
	private static function fieldsOf(item: JValue): Null<Map<String, JValue>> {
		return switch item {
			case JObject(entries): [for (e in entries) (e.key: String) => e.value];
			case _: null;
		}
	}

	private static function stringOf(value: Null<JValue>): Null<String> {
		return switch value {
			case JString(v): (v: String);
			case _: null;
		}
	}

	private static function numberOf(value: Null<JValue>): Null<Float> {
		return switch value {
			case JNumber(v): (v: Float);
			case _: null;
		}
	}

}
