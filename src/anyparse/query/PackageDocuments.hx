package anyparse.query;

import haxe.Exception;
import haxe.Json;
import haxe.io.Path;

using Lambda;

/** One document of a registry kept as a directory: its path and its text. */
typedef RegistryDocument = {
	final file: String;
	final source: String;
}

/** A document cut at one array: see `PackageDocuments.cut`. */
typedef RecordCut = {
	final prefix: String;
	final records: Array<String>;
	final gap: String;
	final suffix: String;
}

/** What `PackageDocuments.carry` changed: the documents to write, and the ones left without a record that go. */
typedef CarriedDocuments = {
	final written: Array<RegistryDocument>;
	final emptied: Array<String>;
}

/**
 * The one answer to "which document of a registry kept one document per package holds a record of this type": the one
 * named after the type's package (`_root.json` for a type with none). The directory reader refuses a record in any
 * other document, and a module relocation carries the record to the document of its new package, creating it when
 * missing.
 *
 * A record is an object of the array at the first segment of a registry key (`arms.type`: the elements of `arms`), its
 * type path the string at the second. The text of every record and the gaps between records are kept byte for byte.
 */
@:nullSafety(Strict)
final class PackageDocuments {

	/** The document of the types that have no package. */
	public static inline final ROOT_DOCUMENT: String = '_root.json';

	/** How a document spells the package of the root types in its comment. */
	private static inline final ROOT_NAME: String = '(root)';

	/** The gap between two records of a document that holds fewer than two. */
	private static inline final DEFAULT_GAP: String = ',\n\t\t';

	/** The package of the type path `type`: its leading lower-initial segments, `''` for none. */
	public static function packageOf(type: String): String {
		final segments: Array<String> = [];
		for (segment in type.split('.')) {
			if (segment == '' || segment.charAt(0) != segment.charAt(0).toLowerCase()) break;
			segments.push(segment);
		}
		return segments.join('.');
	}

	/** The name of the document that holds records of the type `type`. */
	public static function documentFor(type: String): String {
		final pkg: String = packageOf(type);
		return pkg == '' ? ROOT_DOCUMENT : pkg + RegistryFiles.EXTENSION;
	}

	/** The complaint about a record of `type` kept in the document named `document`, or null when it belongs there. */
	public static function misplacement(document: String, type: String): Null<String> {
		final expected: String = documentFor(type);
		return document == expected ? null : 'holds a record for $type, which belongs in $expected';
	}

	/**
	 * The documents of `documents` (all of one registry directory) whose records sit in the wrong one, rewritten with each
	 * such record moved to the document of its type's package. A document left without a record is named in `emptied`;
	 * a target that does not exist yet is made from the document that sent it, its comment naming the new package.
	 * Documents already in place are not returned.
	 */
	public static function carry(documents: Array<RegistryDocument>, keys: Array<String>): CarriedDocuments {
		final path: Null<Array<String>> = [for (key in keys) key.split('.')].find(p -> p.length == 2);
		if (path == null) return { written: [], emptied: [] };
		final parsed: Array<ParsedDocument> = [for (d in documents) parse(d, path[0], path[1])];
		final incoming: Map<String, Array<Record>> = [];
		final sender: Map<String, ParsedDocument> = [];
		for (doc in parsed) {
			final stay: Array<Record> = [];
			for (record in doc.records) {
				final target: String = documentFor(record.type);
				if (target == nameOf(doc)) {
					stay.push(record);
					continue;
				}
				final queue: Array<Record> = incoming[target] ?? [];
				queue.push(record);
				incoming[target] = queue;
				if (!sender.exists(target)) sender[target] = doc;
			}
			doc.kept = stay;
		}
		final written: Array<RegistryDocument> = [];
		final emptied: Array<String> = [];
		for (doc in parsed) {
			final extra: Array<Record> = incoming[nameOf(doc)] ?? [];
			incoming.remove(nameOf(doc));
			if (doc.kept.length == doc.records.length && extra.length == 0) continue;
			final all: Array<Record> = doc.kept.concat(extra);
			if (all.length == 0)
				emptied.push(doc.file);
			else
				written.push({ file: doc.file, source: assemble(doc, all, doc.prefix) });
		}
		for (name => records in incoming) {
			final from: ParsedDocument = sender[name] ?? parsed[0];
			written.push({
				file: Path.join([Path.directory(from.file), name]),
				source: assemble(
					from, records, from.prefix.replace('package ${packageName(nameOf(from))}.', 'package ${packageName(name)}.')
				)
			});
		}
		return { written: written, emptied: emptied };
	}

	/**
	 * `text` cut at the array `arrayKey` into the text before its records, each record's own text, the gap the document
	 * puts between records, and the text after; null when the document has no such array. A record that never closes
	 * throws.
	 */
	public static function cut(text: String, arrayKey: String): Null<RecordCut> {
		final opener: String = '"$arrayKey": [';
		final open: Int = text.indexOf(opener);
		if (open < 0) return null;
		final records: Array<String> = [];
		var gap: String = DEFAULT_GAP;
		final first: Int = skipSpace(text, open + opener.length);
		var cursor: Int = first;
		var lastEnd: Int = first;
		while (text.charAt(cursor) == '{') {
			final end: Int = objectEnd(text, cursor);
			if (records.length == 1) gap = text.substring(lastEnd, cursor);
			records.push(text.substring(cursor, end));
			lastEnd = end;
			final next: Int = skipSpace(text, end);
			if (text.charAt(next) != ',') break;
			cursor = skipSpace(text, next + 1);
		}
		return {
			prefix: text.substring(0, first),
			records: records,
			gap: gap,
			suffix: text.substring(lastEnd)
		};
	}

	/** The file name of `doc`. */
	private static inline function nameOf(doc: ParsedDocument): String {
		return Path.withoutDirectory(doc.file);
	}

	/** The text of `doc` with its records replaced by `records`, joined by the gap the document already uses. */
	private static function assemble(doc: ParsedDocument, records: Array<Record>, prefix: String): String {
		return prefix + records.map(r -> r.text).join(doc.gap) + doc.suffix;
	}

	/** How a document named `name` spells its package in its comment. */
	private static function packageName(name: String): String {
		return name == ROOT_DOCUMENT ? ROOT_NAME : Path.withoutExtension(name);
	}

	/** The records of `document` in the array `arrayKey`, and the text around them. */
	private static function parse(document: RegistryDocument, arrayKey: String, field: String): ParsedDocument {
		final cut: Null<RecordCut> =
			try cut(document.source, arrayKey) catch (exception: Exception) throw new Exception('${document.file}: ${exception.message}');
		if (cut == null) throw new Exception('${document.file} has no "$arrayKey" array');
		final records: Array<Record> = [];
		for (body in cut.records) {
			final parsed: Any = try Json.parse(body) catch (exception: Exception) throw new Exception(
				'${document.file}: a record does not parse: ${exception.message}'
			);
			final type: Null<Any> = Reflect.field(parsed, field);
			if (!(type is String)) throw new Exception('${document.file}: a record carries no string "$field"');
			records.push({ text: body, type: Std.string(type) });
		}
		return {
			file: document.file,
			records: records,
			kept: records,
			gap: cut.gap,
			prefix: cut.prefix,
			suffix: cut.suffix
		};
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
		throw new Exception('a record is never closed');
	}

	/** The first index at or after `at` that is not white space. */
	private static function skipSpace(text: String, at: Int): Int {
		var i: Int = at;
		while (i < text.length && text.isSpace(i)) i++;
		return i;
	}

}

/** One record: its source text and the type path it names. */
private typedef Record = {
	final text: String;
	final type: String;
}

/** A document cut into the text before its records, the records, and the text after. */
private typedef ParsedDocument = {
	final file: String;
	final records: Array<Record>;
	var kept: Array<Record>;
	final gap: String;
	final prefix: String;
	final suffix: String;
}
