package dev;

import anyparse.query.RegistryFiles;
import haxe.Exception;
import haxe.Json;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The reader of the arm registry (`test/testkit/arms`, one document per package) as records keyed by `name`, each with its
 * source text — what the arms row of the slice gate selects from. The documents merge through `apq merge-file`, by records
 * like every JSON document (`.gitattributes` `merge=anyparse`).
 */
@:nullSafety(Strict)
final class ArmRegistry {

	/** The registry, from the tree's root: one document per package, named after it. */
	public static inline final DIRECTORY: String = 'test/testkit/arms';

	/** The single document the registry was kept in before it was split; a base older than the split still has it. */
	public static inline final LEGACY_FILE: String = 'test/testkit/mutation-arms.json';

	/** The key of the array that holds the records. */
	private static inline final ARRAY_KEY: String = '"arms": [';

	/** The records of the registry document `text`, in its order; a name declared twice in it is refused. */
	public static function parse(text: String): Array<ArmRecord> {
		final open: Int = text.indexOf(ARRAY_KEY);
		if (open < 0) throw new ArmRegistryError('no $ARRAY_KEY array');
		final records: Array<ArmRecord> = [];
		var at: Int = open + ARRAY_KEY.length;
		while (true) {
			final start: Int = skipSpace(text, at);
			if (text.charAt(start) != '{') break;
			final body: String = text.substring(start, objectEnd(text, start));
			records.push({ key: keyOf(body), text: body });
			final next: Int = skipSpace(text, start + body.length);
			if (text.charAt(next) != ',') break;
			at = next + 1;
		}
		final keys: Array<String> = [];
		for (record in records) {
			if (keys.contains(record.key)) throw new ArmRegistryError('arm ${record.key} is declared twice');
			keys.push(record.key);
		}
		return records;
	}

	/** The records of several documents, in their order; a name declared in two of them is refused. */
	public static function parseAll(texts: Array<String>): Array<ArmRecord> {
		final records: Array<ArmRecord> = [];
		for (text in texts) for (record in parse(text)) {
			if (records.exists(r -> r.key == record.key)) throw new ArmRegistryError('arm ${record.key} is declared in two documents');
			records.push(record);
		}
		return records;
	}

	/** The records of the registry at `path` — a directory of documents, or one document. */
	public static function read(path: String): Array<ArmRecord> {
		final files: Array<String> = RegistryFiles.of(path);
		if (files.length == 0) throw new ArmRegistryError('no arm registry at $path');
		return parseAll([for (file in files) File.getContent(file)]);
	}

	/** The registry at `path` as ONE document — what `MutationArm.cuts` and `armNames` read. */
	public static function merged(path: String): String {
		return '{"arms": [' + [for (record in read(path)) record.text].join(',') + ']}';
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

/** One arm record: its `name` and its source text. */
typedef ArmRecord = {
	var key: String;
	var text: String;
}

/**
 * A version that does not read as the registry: no `arms` array, a record without a string `name`, or a name declared twice.
 */
class ArmRegistryError extends Exception {}
