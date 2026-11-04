package anyparse.check.common.design;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import haxe.Exception;

/**
 * The readers of the rule options that DECLARE framework knowledge rather than tune a threshold —
 * `prefer-api-idiom`'s `idioms` and `typed-event-constant`'s event types — and of the mutation-arm
 * registry document `guard-pin-arm-reach` names. Their shapes are richer than the typed option
 * accessors of `LintConfig` read (a list of objects, a key whose wrong type must be NAMED rather than dropped), so the
 * raw JSON is walked here, on the config side of the layer boundary, and the rules receive only plain records.
 *
 * Per-entry lenient like `frameworks`: an entry or key this reader cannot use is dropped or ignored, and every such
 * decision appends one line to `problems` — a dropped declaration that says nothing is indistinguishable from one that
 * works. The caller decides where the lines go; the rules print each once per process, except `guard-pin-arm-reach`, which
 * reports each as a finding.
 */
@:nullSafety(Strict)
final class RuleDeclaration {

	/** The `prefer-api-idiom` option holding the idiom list. */
	private static inline final IDIOMS_KEY: String = 'idioms';

	private static inline final EVENT_BASE_KEY: String = 'eventBase';
	private static inline final TYPE_ABSTRACT_KEY: String = 'typeAbstract';
	private static inline final LISTENER_METHODS_KEY: String = 'listenerMethods';

	/** The key of a mutation-arm registry's records. */
	private static inline final ARMS_KEY: String = 'arms';

	/** The keys an idiom entry may carry. */
	private static final ENTRY_KEYS: Array<String> = ['type', 'fields', 'method', 'copy', 'subtypes'];

	/** The keys an arm must hold as strings; `MutationArmJson` requires the same for the op that refuses a whole registry. */
	private static final ARM_KEYS: Array<String> = ['name', 'type', 'method'];

	/**
	 * The idiom entries rule `ruleId` declares under `idioms` in `config`, each a well-formed `IdiomSpec`, in declared
	 * order; empty when the key is absent.
	 */
	public static function idioms(config: LintConfig, ruleId: String, problems: Array<String>): Array<IdiomSpec> {
		final entries: Array<JValue> = switch config.jsonOption(ruleId, IDIOMS_KEY) {
			case null: return [];
			case JArray(items): items;
			case _:
				problems.push('"$IDIOMS_KEY" is not an array — ignored');
				return [];
		};
		final out: Array<IdiomSpec> = [];
		for (i in 0...entries.length) {
			final spec: Null<IdiomSpec> = parseEntry(entries[i], '$IDIOMS_KEY[$i]', problems);
			if (spec != null) out.push(spec);
		}
		return out;
	}

	/**
	 * The event types rule `ruleId` declares in `config` — `eventBase`, `typeAbstract` and a non-empty `listenerMethods` —
	 * or null when one is absent or unusable.
	 */
	public static function eventTypes(config: LintConfig, ruleId: String, problems: Array<String>): Null<EventSpec> {
		final base: Null<String> = typePath(config, ruleId, EVENT_BASE_KEY, problems);
		final abstractName: Null<String> = typePath(config, ruleId, TYPE_ABSTRACT_KEY, problems);
		final listeners: Null<Array<String>> = switch config.jsonOption(ruleId, LISTENER_METHODS_KEY) {
			case null: null;
			case JArray(items):
				final names: Array<String> = [];
				LintDocuments.collectStrings(items, names);
				if (names.length != items.length || names.exists(n -> n == '')) {
					problems.push('"$LISTENER_METHODS_KEY" holds a value that is not a method name — ignored');
					null;
				} else {
					names;
				}
			case _:
				problems.push('"$LISTENER_METHODS_KEY" is not an array — ignored');
				null;
		};
		if (base == null || abstractName == null || listeners == null) return null;
		final declaredBase: String = base;
		final declaredAbstract: String = abstractName;
		final declaredListeners: Array<String> = listeners;
		return declaredListeners.length == 0
			? null
			: { eventBase: declaredBase, typeAbstract: declaredAbstract, listenerMethods: declaredListeners };
	}

	/**
	 * The `arms` records of a mutation-arm registry document `content` by name — each a `{name, type, method}` object, any
	 * other key ignored — for `guard-pin-arm-reach`. A record it cannot use is dropped alone and a text that holds no `arms`
	 * array reads as none, each with lines in `problems` under `label`, so a bad record costs only itself.
	 */
	public static function armRegistry(content: String, label: String, problems: Array<String>): Map<String, ArmTarget> {
		final out: Map<String, ArmTarget> = [];
		final document: JValue = try {
			JValueParser.parse(content);
		} catch (exception: Exception) {
			problems.push('$label is not JSON: ${exception.message}');
			return out;
		};
		switch JValueTools.field(document, ARMS_KEY) {
			case JArray(records):
				for (index => record in records) {
					final arm: Null<ArmTarget> = armOf(record, '$label arm #${index + 1}', problems);
					if (arm != null) out[arm.name] = arm;
				}
			case _:
				problems.push('$label holds no "$ARMS_KEY" array');
		}
		return out;
	}

	/** The record's target, or null when one of its fields is no string; one line per such field goes to `problems`. */
	private static function armOf(record: JValue, position: String, problems: Array<String>): Null<ArmTarget> {
		final name: Null<String> = stringField(record, 'name');
		final type: Null<String> = stringField(record, 'type');
		final method: Null<String> = stringField(record, 'method');
		if (name != null && type != null && method != null) return { name: name, type: type, method: method };
		final shown: String = name == null ? position : '$position "$name"';
		for (key in ARM_KEYS) if (stringField(record, key) == null) problems.push('$shown: "$key" is not a string — dropped');
		return null;
	}

	/** The string at `key` of `record`, or null when it holds anything else. */
	private static function stringField(record: JValue, key: String): Null<String> {
		return switch JValueTools.field(record, key) {
			case JString(value): value;
			case _: null;
		};
	}

	/** A type-path key of rule `ruleId`'s options, or null when absent; a value that is no non-empty string is named. */
	private static function typePath(config: LintConfig, ruleId: String, key: String, problems: Array<String>): Null<String> {
		return switch config.jsonOption(ruleId, key) {
			case null: null;
			case JString(v) if (v != ''): v;
			case _:
				problems.push('"$key" is not a type path — ignored');
				null;
		};
	}

	/** One `idioms` entry → its spec, or null with the reason in `problems`. */
	private static function parseEntry(raw: JValue, label: String, problems: Array<String>): Null<IdiomSpec> {
		final fields: Array<{ key: String, value: JValue }> = switch raw {
			case JObject(entries): [for (e in entries) { key: e.key, value: e.value }];
			case _:
				problems.push('$label is not an object — dropped');
				return null;
		};
		var type: Null<String> = null;
		var names: Null<Array<String>> = null;
		var method: Null<String> = null;
		var copy: Null<String> = null;
		var subtypes: Bool = false;
		for (f in fields) switch [f.key, f.value] {
			case ['type', JString(v)]:
				type = v;
			case ['method', JString(v)]:
				method = v;
			case ['copy', JString(v)]:
				copy = v;
			case ['subtypes', JBool(v)]:
				subtypes = v;
			case ['fields', JArray(items)]:
				final strings: Array<String> = [];
				LintDocuments.collectStrings(items, strings);
				names = strings.length == items.length ? strings : null;
			case [key, _] if (ENTRY_KEYS.contains(key)):
				problems.push('$label "$key" has the wrong type — dropped');
				return null;
			case [key, _]:
				problems.push('$label declares unknown key "$key" — ignored');
		}
		final declaredType: Null<String> = type;
		final declaredFields: Null<Array<String>> = names;
		if (declaredType == null || declaredType == '') {
			problems.push('$label declares no "type" — dropped');
			return null;
		}
		if (declaredFields == null || declaredFields.length == 0 || declaredFields.exists(n -> n == '')) {
			problems.push('$label ("$declaredType") declares no "fields" list of names — dropped');
			return null;
		}
		final distinct: Array<String> = [];
		for (n in declaredFields) if (!distinct.contains(n)) distinct.push(n);
		if (distinct.length != declaredFields.length) {
			problems.push('$label ("$declaredType") names a field twice — dropped');
			return null;
		}
		if ((method == null || method == '') != (copy == null || copy == '')) return {
			type: declaredType,
			fields: declaredFields,
			method: method == '' ? null : method,
			copy: copy == '' ? null : copy,
			subtypes: subtypes
		};
		problems.push('$label ("$declaredType") must declare exactly one of "method" and "copy" — dropped');
		return null;
	}

}

/** One `prefer-api-idiom` entry as declared — see `PreferApiIdiom` for the shape. */
typedef IdiomSpec = {
	final type: String;
	final fields: Array<String>;
	final method: Null<String>;
	final copy: Null<String>;
	final subtypes: Bool;
}

/** `typed-event-constant`'s declaration, as read. */
typedef EventSpec = {
	final eventBase: String;
	final typeAbstract: String;
	final listenerMethods: Array<String>;
}

/** One mutation arm of a registry: its name and the member it cuts. */
typedef ArmTarget = {
	final name: String;
	final type: String;
	final method: String;
}
