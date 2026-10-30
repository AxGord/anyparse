package dev;

import devkit.Args;
import haxe.Exception;
import haxe.Json;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev merge-arms <base> <ours> <theirs>` — the git merge driver of `test/testkit/mutation-arms.json`
 * (`.gitattributes` `merge=anyparse-arms`). A line merge cannot keep that file valid: two branches that each append an
 * arm both rewrite the old last record's closing line to take a comma. So the three versions are merged as RECORDS keyed
 * by `name`: one side's change to a record wins over the other side's silence, a record added on both sides keeps ours
 * first, and the result — written over `<ours>`, every record's text kept byte for byte — exits 0. Two different edits of
 * one record, an edit against a removal, or a file that does not read as the registry exits 1 and leaves `<ours>` alone,
 * so git reports the conflict as it would have.
 */
@:nullSafety(Strict)
final class MergeArms {

	public static inline final USAGE: String = 'usage: dev merge-arms <base> <ours> <theirs>';

	/** The key of the array that holds the records. */
	private static inline final ARRAY_KEY: String = '"arms": [';

	public static function main(argv: Array<String>): Int {
		final paths: Array<String> = new Args(argv).positionals(['<base>', '<ours>', '<theirs>']);
		final merged: Null<String> =
			try merge(File.getContent(paths[0]), File.getContent(paths[1]), File.getContent(paths[2])) catch (exception: MergeConflict) {
				Sys.stderr().writeString('merge-arms: ${exception.message}\n');
				null;
			};
		if (merged == null) return 1;
		File.saveContent(paths[1], merged);
		return 0;
	}

	/** The registry `base` becomes with the changes of both `ours` and `theirs`; throws `MergeConflict` when they collide. */
	public static function merge(base: String, ours: String, theirs: String): String {
		final b: RecordFile = parse(base);
		final o: RecordFile = parse(ours);
		final t: RecordFile = parse(theirs);
		final result: Array<ArmRecord> = [];
		final conflicts: Array<String> = [];
		for (record in o.records) switch side(textOf(b, record.key), record.text, textOf(t, record.key)) {
			case Keep(text):
				result.push({ key: record.key, text: text });
			case Drop:
			case Collide:
				conflicts.push(record.key);
		}
		final added: Array<String> = [
			for (record in o.records) if (textOf(b, record.key) == null && textOf(t, record.key) == null) record.key
		];
		for (i => record in t.records) if (textOf(o, record.key) == null) {
			final old: Null<String> = textOf(b, record.key);
			if (old != null) {
				// ours removed it: gone unless theirs changed it
				if (old != record.text) conflicts.push(record.key);
				continue;
			}
			var at: Int = 0;
			var k: Int = i - 1;
			while (k >= 0) {
				final before: String = t.records[k].key;
				final found: Int = result.findIndex(r -> r.key == before);
				if (found >= 0) {
					at = found + 1;
					break;
				}
				k--;
			}
			while (at < result.length && added.contains(result[at].key)) at++;
			result.insert(at, record);
		}
		if (conflicts.length > 0) throw new MergeConflict('both sides changed arm(s) ${conflicts.join(', ')} differently');
		return '${side3(b.head, o.head, t.head, 'the text before the records')}'
			+ [for (record in result) record.text].join(o.separator)
			+ side3(b.tail, o.tail, t.tail, 'the text after the records');
	}

	/** The registry `text` taken apart into its records, keyed by name, and the text around them. */
	public static function parse(text: String): RecordFile {
		final open: Int = text.indexOf(ARRAY_KEY);
		if (open < 0) throw new MergeConflict('no $ARRAY_KEY array');
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
			if (keys.contains(record.key)) throw new MergeConflict('arm ${record.key} is declared twice');
			keys.push(record.key);
		}
		return {
			head: text.substring(0, head),
			records: records,
			separator: separators.length > 0 ? separators[0] : ',\n\t\t',
			tail: text.substr(records.length == 0 ? head : last)
		};
	}

	/** The text of the record `key` in `file`, or null when it has none. */
	private static function textOf(file: RecordFile, key: String): Null<String> {
		final found: Null<ArmRecord> = file.records.find(r -> r.key == key);
		return found?.text;
	}

	/** What a merge does with a record ours holds as `mine`, given its `old` text in the base and `other` in theirs. */
	private static function side(old: Null<String>, mine: String, other: Null<String>): Merged {
		if (other == null) return if (old == null)
			Keep(mine)
		else if (old == mine)
			Drop
		else
			Collide;
		return if (other == mine || old == other)
			Keep(mine)
		else if (old == mine)
			Keep(other)
		else
			Collide;
	}

	/** The three-way merge of one unkeyed stretch of text, `what` naming it in a conflict. */
	private static function side3(old: String, mine: String, other: String, what: String): String {
		if (mine == other || old == other) return mine;
		if (old == mine) return other;
		throw new MergeConflict('both sides changed $what');
	}

	/** The `name` of the record `body`. */
	private static function keyOf(body: String): String {
		final parsed: Any = try Json.parse(body) catch (exception: Exception) throw new MergeConflict(
			'a record does not parse: ${exception.message}'
		);
		final name: Null<Any> = Reflect.field(parsed, 'name');
		if (!(name is String)) throw new MergeConflict('a record carries no string `name`');
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
		throw new MergeConflict('an arm record is never closed');
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

/** What a merge does with one record ours holds. */
enum Merged {
	Keep(text: String);
	Drop;
	Collide;
}

/** The two sides changed one thing differently, or a version does not read as the registry. */
class MergeConflict extends Exception {}
