package dev;

import haxe.Exception;
import haxe.Json;

using StringTools;

/**
 * The reader of `test/testkit/mutation-arms.json` as records keyed by `name`, each with its source text, and the text
 * around them — what the arms row of the slice gate selects from. The file merges through `apq merge-file`, by records
 * like every JSON document (`.gitattributes` `merge=anyparse`).
 */
@:nullSafety(Strict)
final class ArmRegistry {

	/** The key of the array that holds the records. */
	private static inline final ARRAY_KEY: String = '"arms": [';

	/** The registry `text` taken apart into its records, keyed by name, and the text around them. */
	public static function parse(text: String): RecordFile {
		final open: Int = text.indexOf(ARRAY_KEY);
		if (open < 0) throw new ArmRegistryError('no $ARRAY_KEY array');
		final records: Array<ArmRecord> = [];
		final separators: Array<String> = [];
		var at: Int = open + ARRAY_KEY.length;
		var head: Int = -1;
		var last: Int = at;
		while (true) {
			final start: Int = skipSpace(text, at);
			if (text.charAt(start) != '{') {
				if (records.length == 0) head = start;
				break;
			}
			if (records.length == 0)
				head = start;
			else
				separators.push(text.substring(last, start));
			final end: Int = objectEnd(text, start);
			final body: String = text.substring(start, end);
			records.push({ key: keyOf(body), text: body });
			last = end;
			final next: Int = skipSpace(text, end);
			if (text.charAt(next) != ',') break;
			at = next + 1;
		}
		final keys: Array<String> = [];
		for (record in records) {
			if (keys.contains(record.key)) throw new ArmRegistryError('arm ${record.key} is declared twice');
			keys.push(record.key);
		}
		return {
			head: text.substring(0, head),
			records: records,
			separator: separators.length > 0 ? separators[0] : ',\n\t\t',
			tail: text.substr(records.length == 0 ? head : last)
		};
	}

	/** The `name` of the record `body`. */
	private static function keyOf(body: String): String {
		final parsed: Any = try Json.parse(body) catch (exception: Exception) throw new ArmRegistryError(
			'a record does not parse: ${exception.message}'
		);
		final name: Null<Any> = Reflect.field(parsed, 'name');
		if (!(name is String)) throw new ArmRegistryError('a record carries no string `name`');
		return Std.string(name);
	}

	/** The index just past the `}` closing the object that opens at `start`, strings and escapes respected. */
	private static function objectEnd(text: String, start: Int): Int {
		var depth: Int = 0;
		var inString: Bool = false;
		var i: Int = start;
		while (i < text.length) {
			final c: String = text.charAt(i);
			if (inString) {
				if (c == '\\')
					i++;
				else if (c == '"')
					inString = false;
			} else if (c == '"') {
				inString = true;
			} else if (c == '{') {
				depth++;
			} else if (c == '}') {
				depth--;
				if (depth == 0) return i + 1;
			}
			i++;
		}
		throw new ArmRegistryError('an arm record is never closed');
	}

	/** The first index at or after `at` that is not white space. */
	private static function skipSpace(text: String, at: Int): Int {
		var i: Int = at;
		while (i < text.length && text.isSpace(i)) i++;
		return i;
	}

}

/** The registry taken apart: the text before the first record, the records, what separates them, and the rest. */
typedef RecordFile = {
	var head: String;
	var records: Array<ArmRecord>;
	var separator: String;
	var tail: String;
}

/** One arm record: its `name` and its source text. */
typedef ArmRecord = {
	var key: String;
	var text: String;
}

/**
 * A version that does not read as the registry: no `arms` array, a record without a string `name`, or a name declared twice.
 */
class ArmRegistryError extends Exception {}
