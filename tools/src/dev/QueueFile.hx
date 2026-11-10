package dev;

import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import haxe.Exception;

using StringTools;

/** A note on a queue line: who wrote it, when, and what it says. */
typedef QueueNote = {
	final from: String;
	final date: String;
	final text: String;
}

/** One line of the queue file, the fields every consumer asks for; a field the line lacks is empty. */
typedef QueueLine = {
	final id: String;
	final status: String;
	final owner: String;
	final text: String;
	final ended: String;
	final base: String;
	final touches: Array<String>;
	final after: Array<String>;
	final notes: Array<QueueNote>;
}

/**
 * The one answer to "what does the queue file say about a line": reads the `tasks:` list of the queue (`.claude/batch/queue.yaml`)
 * into `QueueLine`s. The project has no YAML grammar; this reads only the shape the queue tools write — a two-space `- id:` entry,
 * four-space `key: value` fields, a `|-` block for `text`, a flow list for `touches` / `after`, `- from:` entries for `notes`.
 */
@:nullSafety(Strict)
final class QueueFile {

	private static final ENTRY: String = '  - id: ';
	private static final FIELD: EReg = ~/^    ([a-z_]+):(.*)$/;
	private static final NOTE_FROM: String = '      - from: ';
	private static final NOTE_FIELD: EReg = ~/^        ([a-z_]+): (.*)$/;

	/** The line `id` of `queue` (the file's text), or null when it has none. */
	public static function find(queue: String, id: String): Null<QueueLine> {
		for (line in read(queue)) if (line.id == id) return line;
		return null;
	}

	/** Every line of `queue`'s `tasks:` list, in file order. */
	public static function read(queue: String): Array<QueueLine> {
		final rows: Array<String> = queue.split('\n');
		final start: Int = rows.indexOf('tasks:');
		final entries: Array<Array<String>> = [];
		if (start >= 0) for (row in rows.slice(start + 1)) {
			if (row.startsWith(ENTRY)) entries.push([]);
			if (entries.length > 0) entries[entries.length - 1].push(row);
		}
		return entries.map(entry);
	}

	private static function entry(rows: Array<String>): QueueLine {
		final fields: Map<String, String> = [];
		final notes: Array<QueueNote> = [];
		fields['id'] = rows[0].substr(ENTRY.length).trim();
		var index: Int = 1;
		while (index < rows.length) {
			final row: String = rows[index++];
			if (!FIELD.match(row)) continue;
			final key: String = FIELD.matched(1);
			final value: String = FIELD.matched(2).trim();
			final body: Array<String> = [while (index < rows.length && !FIELD.match(rows[index])) rows[index++]];
			if (key == 'notes')
				readNotes(body, notes)
			else
				fields[key] = value.startsWith('|') ? body.map(unindent).join('\n').rtrim() : scalar(value);
		}
		return {
			id: fields['id'] ?? '',
			status: fields['status'] ?? '',
			owner: fields['owner'] ?? '',
			text: fields['text'] ?? '',
			ended: fields['ended'] ?? '',
			base: fields['base'] ?? '',
			touches: list(fields['touches'] ?? ''),
			after: list(fields['after'] ?? ''),
			notes: notes
		};
	}

	private static function readNotes(rows: Array<String>, into: Array<QueueNote>): Void {
		final maps: Array<Map<String, String>> = [];
		for (row in rows) {
			if (row.startsWith(NOTE_FROM))
				maps.push(['from' => scalar(row.substr(NOTE_FROM.length).trim())])
			else if (maps.length > 0 && NOTE_FIELD.match(row))
				maps[maps.length - 1].set(NOTE_FIELD.matched(1), scalar(NOTE_FIELD.matched(2).trim()));
		}
		for (map in maps) into.push({ from: map.get('from') ?? '', date: map.get('date') ?? '', text: map.get('text') ?? '' });
	}

	/** A plain scalar as written, or the string a double-quoted one spells (JSON escapes). */
	private static function scalar(value: String): String {
		if (value.length < 2 || !value.startsWith('"') || !value.endsWith('"')) return value;
		return try {
			JValueTools.string(JValueParser.parse(value)) ?? value;
		} catch (_: Exception) {
			value;
		}
	}

	private static function list(value: String): Array<String> {
		return !value.startsWith('[') || !value.endsWith(']') ? [] : [
			for (item in value.substring(1, value.length - 1).split(',')) if (item.trim() != '') item.trim()
		];
	}

	private static function unindent(row: String): String {
		return row.startsWith('      ') ? row.substr(6) : row.trim();
	}

}
