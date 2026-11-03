package dev;

import anyparse.grammar.json.JValue;

/**
 * The registry line counts of a gate baseline as its document keeps them, a JSON object of `<name>: <count>`: the document
 * the gate of an earlier engine wrote reads the same, so the keys are data and the object stays a raw `JValue`.
 */
final class BaselineLists {

	/** The counts of `names`, each read by `countOf`. */
	public static function of(names: Array<String>, countOf: String -> Int): JValue {
		return JObject([for (name in names) { key: name, value: JNumber(countOf(name)) }]);
	}

	/** The count recorded under `name`, or null when `lists` holds none. */
	public static function count(lists: JValue, name: String): Null<Int> {
		return switch lists {
			case JObject(entries):
				var found: Null<Int> = null;
				for (entry in entries) switch entry.value {
					case JNumber(v) if (entry.key == name):
						found = Std.int(v);
					case _:
				}
				found;
			case _: null;
		}
	}

}
