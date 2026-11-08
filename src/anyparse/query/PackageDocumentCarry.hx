package anyparse.query;

import anyparse.grammar.json.JsonNative;
import anyparse.grammar.json.JsonProjection;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.io.Path;

using Lambda;

/**
 * The one answer to "how do the records of a registry kept one document per package move between its documents": a document
 * is cut at its record array by the JSON parse span of each record (so the text of every record and the gaps between
 * records are kept byte for byte), each record not in the document of its type's package is carried to that one, and a
 * missing document is made in the shape of the one that sent the record.
 *
 * Not reachable from macro code: the parse spans come from the JSON query projection, a generated parser a macro cannot
 * use. Which document holds a type is `PackageDocuments`, which macro code reads.
 */
@:nullSafety(Strict)
final class PackageDocumentCarry {

	/** How a document spells the package of the root types in its comment. */
	private static inline final ROOT_NAME: String = '(root)';

	/** The gap between two records of a document that holds fewer than two. */
	private static inline final DEFAULT_GAP: String = ',\n\t\t';

	/**
	 * The documents of `documents` (all of one registry directory) whose records sit in the wrong one, rewritten with each
	 * such record moved to the document of its type's package. A document left without a record is named in `emptied`;
	 * a target that does not exist yet is made from the document that sent it, its comment naming the new package.
	 * Documents already in place are not returned.
	 */
	public static function carry(documents: Array<RegistryDocument>, keys: Array<String>): CarriedDocuments {
		final path: Null<Array<String>> = keys.map(key -> key.split('.')).find(p -> p.length == 2);
		if (path == null) return { written: [], emptied: [] };
		final parsed: Array<ParsedDocument> = documents.map(d -> parse(d, path[0], path[1]));
		final incoming: Map<String, Array<Record>> = [];
		final sender: Map<String, ParsedDocument> = [];
		for (doc in parsed) {
			final stay: Array<Record> = [];
			for (record in doc.records) {
				final target: String = PackageDocuments.documentFor(record.type);
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
	 * `text` cut at the array `arrayKey` of its top-level object into the text before its records, each record's own text,
	 * the gap the document puts between records, and the text after; null when the document has no such array. A document
	 * that does not parse throws. The extent of a record is its span in the JSON parse.
	 */
	public static function cut(text: String, arrayKey: String): Null<RecordCut> {
		final array: Null<QueryNode> = arrayAt(text, arrayKey);
		if (array == null) return null;
		final spans: Array<Span> = [];
		for (element in array.children) {
			if (element.kind != JsonProjection.OBJECT) break;
			spans.push(JsonProjection.spanOf(element));
		}
		final records: Array<String> = spans.map(span -> text.substring(span.from, span.to));
		final first: Int = spans.length > 0 ? spans[0].from : skipSpace(text, JsonProjection.spanOf(array).from + 1);
		return {
			prefix: text.substring(0, first),
			records: records,
			gap: spans.length > 1 ? text.substring(spans[0].to, spans[1].from) : DEFAULT_GAP,
			suffix: text.substring(spans.length > 0 ? spans[spans.length - 1].to : first)
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
		return name == PackageDocuments.ROOT_DOCUMENT ? ROOT_NAME : Path.withoutExtension(name);
	}

	/** The records of `document` in the array `arrayKey`, and the text around them. */
	private static function parse(document: RegistryDocument, arrayKey: String, field: String): ParsedDocument {
		final cut: Null<RecordCut> =
			try cut(document.source, arrayKey) catch (exception: Exception) throw new Exception('${document.file}: ${exception.message}');
		if (cut == null) throw new Exception('${document.file} has no "$arrayKey" array');
		final records: Array<Record> = [];
		for (body in cut.records) {
			final type: Null<String> =
				try JsonNative.stringField(
					body, field
				) catch (exception: Exception) throw new Exception('${document.file}: a record does not parse: ${exception.message}');
			records.push({ text: body, type: type ?? throw new Exception('${document.file}: a record carries no string "$field"') });
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

	/** The first index at or after `at` that is not white space. */
	private static function skipSpace(text: String, at: Int): Int {
		var i: Int = at;
		while (i < text.length && text.isSpace(i)) i++;
		return i;
	}

	/** The array at member `arrayKey` of the top-level object of `text`, null when the document has none. */
	private static function arrayAt(text: String, arrayKey: String): Null<QueryNode> {
		final root: Null<QueryNode> = JsonProjection.parse(text).children[0];
		if (root == null || root.kind != JsonProjection.OBJECT) return null;
		for (member in root.children) if (member.name == arrayKey) {
			final value: QueryNode = member.children[0];
			return value.kind == JsonProjection.ARRAY ? value : null;
		}
		return null;
	}

}

/** One document of a registry kept as a directory: its path and its text. */
typedef RegistryDocument = {
	final file: String;
	final source: String;
}

/** A document cut at one array: see `PackageDocumentCarry.cut`. */
typedef RecordCut = {
	final prefix: String;
	final records: Array<String>;
	final gap: String;
	final suffix: String;
}

/** What `PackageDocumentCarry.carry` changed: the documents to write, and the ones left without a record that go. */
typedef CarriedDocuments = {
	final written: Array<RegistryDocument>;
	final emptied: Array<String>;
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
