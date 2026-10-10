package anyparse.check;

import anyparse.grammar.json.JValue;
import anyparse.runtime.EditDistance;
import haxe.Exception;

/**
 * One well-formed `boundedRepeats` entry, as written: the member, the
 * call or loop header it narrows to, the bound and the cost of a turn.
 */
typedef BoundedRepeatEntry = {
	final site: String;
	final call: Null<String>;
	final loop: Null<String>;
	final max: Float;
	final costMs: Float;
}

/**
 * ONE chain's `thread-safety` options, read and checked in one place: every key the rule knows, each of the shape it
 * needs, and a line in `problems` for everything the read leaves out — a key no option has, a value of the wrong shape,
 * a list item or a `boundedRepeats` entry dropped — so a malformed config never reads as a quiet one.
 *
 * Shapes. A LIST (`LIST_KEYS`) is an array of strings, a non-string item dropped with a note; a FLAG (`FLAG_KEYS`) is
 * `true` or `false`; `repeatBudgetMs` a positive number; `boundedRepeats` an array of objects, each with a `site`
 * string naming one member (no pattern), a positive `max`, a positive `costMs`,
 * an optional `call` and `loop` string and an optional `evidence` string (read
 * by people, never by the rule); `lockPairs` items are `<lock pattern>/<unlock member>`. Any other shape is dropped,
 * whole, and said: the option then reads as absent, which is what it read as before, silently.
 *
 * `runsOnce` is read as a LIST like the others; what it means is its consumer's.
 */
@:nullSafety(Strict)
final class ThreadSafetyOptions {

	/** The rule's id, under which `apqlint.json` keeps these options. */
	public static inline final RULE: String = 'thread-safety';

	/** The keys holding a list of call patterns (`lockPairs`: of pairs; `exclude`: of path runs). */
	public static final LIST_KEYS: Array<String> = [
		'sinks',
		'spawns',
		'marshals',
		'lockPairs',
		'quietRoots',
		'reentrantLocks',
		'throwers',
		'neverInvokes',
		'mainThreadChecks',
		'exclude',
		'shortSinks',
		'iterates',
		'registers',
		'sharedLocks',
		'nonThrowing',
		'runsOnce'
	];

	/** The keys holding `true` or `false`. */
	public static final FLAG_KEYS: Array<String> = ['closedWorld', 'compilerFacts'];

	/** The keys every rule takes, which the linter reads itself when well-formed (`LintConfig.parseRule`). */
	private static final LIFTED_KEYS: Array<String> = ['enabled', 'severity'];

	private static inline final BUDGET_KEY: String = 'repeatBudgetMs';
	private static inline final BOUNDED_KEY: String = 'boundedRepeats';

	/** What the read left out, one line each, by key. */
	public final problems: Array<String> = [];

	/** The well-formed `boundedRepeats` entries. */
	public final boundedRepeats: Array<BoundedRepeatEntry> = [];

	/** The positive `repeatBudgetMs`, or null when unset or dropped. */
	public final repeatBudgetMs: Null<Float>;

	/** Whether the chain writes any option for the rule at all, well-formed or not: one that does is a config to report on. */
	public final declared: Bool;

	/** The option keys the chain writes, well-formed or not. */
	private final _written: Array<String>;

	/** Each LIST key -> its strings; a key absent or dropped holds none. */
	private final _lists: Map<String, Array<String>> = [];

	/** Each FLAG key -> its value; a key absent or dropped is false. */
	private final _flags: Map<String, Bool> = [];

	private function new(config: LintConfig) {
		_written = config.optionKeys(RULE);
		declared = _written.length > 0;
		repeatBudgetMs = readKeys(config);
		for (pair in list('lockPairs')) if (pair.lastIndexOf('/') <= 0)
			problems.push('malformed lockPairs entry "$pair" — expected "<lock pattern>/<unlock member>"');
	}

	/** The strings of the LIST option `key` (`LIST_KEYS`); none when it is absent or was dropped. */
	public function list(key: String): Array<String> {
		if (!LIST_KEYS.contains(key)) throw new Exception('thread-safety: "$key" is no list option');
		return _lists[key] ?? [];
	}

	/** Whether the chain writes the option `key`, whatever its shape. */
	public inline function wrote(key: String): Bool {
		return _written.contains(key);
	}

	/** The FLAG option `key` (`FLAG_KEYS`); false when it is absent or was dropped. */
	public function flag(key: String): Bool {
		if (!FLAG_KEYS.contains(key)) throw new Exception('thread-safety: "$key" is no flag option');
		return _flags[key] == true;
	}

	/** Every option this read keeps, as one string: two reads keeping the same options have the same signature. */
	public function signature(): String {
		final parts: Array<String> = [for (key in LIST_KEYS) key + '=' + list(key).join('\n')];
		for (key in FLAG_KEYS) parts.push('$key=${flag(key)}');
		parts.push('$BUDGET_KEY=$repeatBudgetMs');
		for (b in boundedRepeats) parts.push('${b.site}>${b.call}@${b.loop}:${b.max}x${b.costMs}');
		return parts.join('\t');
	}

	/** Reads every option key of `config`, each by its shape, an unknown one said; answers the budget. */
	private function readKeys(config: LintConfig): Null<Float> {
		var budget: Null<Float> = null;
		for (key in config.optionKeys(RULE)) {
			final value: Null<JValue> = config.jsonOption(RULE, key);
			if (value == null) continue;
			if (LIST_KEYS.contains(key))
				_lists[key] = readList(key, value);
			else if (FLAG_KEYS.contains(key))
				readFlag(key, value);
			else if (key == BUDGET_KEY)
				budget = readBudget(value);
			else if (key == BOUNDED_KEY)
				readBounded(value);
			else if (LIFTED_KEYS.contains(key))
				// the linter lifts a well-formed one out before the rule reads its options: what is left is of another shape
				problems.push('option "$key" is not ${key == 'enabled' ? 'true or false' : 'a severity name'} — ignored');
			else
				problems.push(unknownKey(key));
		}
		return budget;
	}

	/** The strings of the LIST option `key` written `value`, every other item dropped and said. */
	private function readList(key: String, value: JValue): Array<String> {
		final out: Array<String> = [];
		switch value {
			case JArray(items):
				LintConfig.collectStrings(items, out);
				final skipped: Int = items.length - out.length;
				if (skipped > 0) problems.push('option "$key" ignored $skipped value(s) that are not strings');
			case _:
				problems.push('option "$key" is not an array of strings — ignored');
		}
		return out;
	}

	/** Records the FLAG option `key` written `value`, a value that is not a boolean dropped and said. */
	private function readFlag(key: String, value: JValue): Void {
		switch value {
			case JBool(v):
				_flags[key] = v;
			case _:
				problems.push('option "$key" is not true or false — ignored');
		}
	}

	/** The budget written `value`; null, and said, when it is not a positive number. */
	private function readBudget(value: JValue): Null<Float> {
		final budget: Null<Float> = switch value {
			case JNumber(v): (v: Float);
			case _: null;
		};
		if (budget != null && budget > 0) return budget;
		problems.push('option "$BUDGET_KEY" is not a positive number — ignored');
		return null;
	}

	/** Records every well-formed `boundedRepeats` entry of `value`, each other one dropped and said. */
	private function readBounded(value: JValue): Void {
		final items: Array<JValue> = switch value {
			case JArray(items): items;
			case _:
				problems.push('option "$BOUNDED_KEY" is not an array of objects — ignored');
				[];
		};
		for (i in 0...items.length) switch items[i] {
			case JObject(fields):
				var site: Null<String> = null;
				var call: Null<String> = null;
				var loop: Null<String> = null;
				var max: Null<Float> = null;
				var cost: Null<Float> = null;
				final wrong: Array<String> = [];
				for (field in fields) switch [field.key, field.value] {
					case ['site', JString(v)]:
						site = v;
					case ['call', JString(v)]:
						call = v;
					case ['loop', JString(v)]:
						loop = v;
					case ['max', JNumber(v)]:
						max = (v: Float);
					case ['costMs', JNumber(v)]:
						cost = (v: Float);
					case ['evidence', JString(_)]:
					case ['site' | 'call' | 'loop' | 'max' | 'costMs' | 'evidence', _]:
						wrong.push('"${field.key}" is not a ${field.key == 'max' || field.key == 'costMs' ? 'number' : 'string'}');
					case _:
						wrong.push('unknown key "${field.key}"');
				}
				final siteName: Null<String> = site;
				final bound: Null<Float> = max;
				final turn: Null<Float> = cost;
				final dropped: String = '$BOUNDED_KEY[$i] dropped: ';
				if (wrong.length > 0)
					problems.push('$BOUNDED_KEY[$i] dropped: ${wrong.join(', ')}');
				else if (siteName == null)
					problems.push(dropped + 'it names no "site"');
				else if (siteName.indexOf('*') >= 0)
					problems.push(dropped + '"site" is a pattern, not one member');
				else if (bound == null || !(bound > 0))
					problems.push(dropped + '"max" is not a positive number');
				else if (turn == null || !(turn > 0))
					problems.push(dropped + '"costMs" is not a positive number');
				else {
					// re-bound: strict null-safety does not carry a narrowed local into a structure literal
					final named: String = siteName;
					final most: Float = bound;
					final each: Float = turn;
					boundedRepeats.push({
						site: named,
						call: call,
						loop: loop,
						max: most,
						costMs: each
					});
				}
			case _:
				problems.push('$BOUNDED_KEY[$i] is not an object — dropped');
		}
	}

	/** `config`'s `thread-safety` options. */
	public static inline function read(config: LintConfig): ThreadSafetyOptions {
		return new ThreadSafetyOptions(config);
	}

	/** The line for an unknown option `key`, naming the nearest known one when there is one. */
	private static function unknownKey(key: String): String {
		final known: Array<String> = LIST_KEYS.concat(FLAG_KEYS).concat([BUDGET_KEY, BOUNDED_KEY]);
		final near: Array<String> = EditDistance.closest(key, known)
			.filter(candidate -> candidate.indexOf(key) >= 0 || EditDistance.between(key, candidate, key.length) * 2 < key.length);
		return near.length == 0 ? 'unknown option "$key" — ignored' : 'unknown option "$key" — ignored (did you mean "${near[0]}"?)';
	}

}
