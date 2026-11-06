package anyparse.query;

import anyparse.format.text.TextFormat.UnescapeResult;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonFormat;
import anyparse.grammar.json.JsonProjection;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * A data file a project declares to hold TYPE PATHS at some of its keys — a mutation-arm registry's `type`, a lint
 * config's owned types. `keys` are dotted key paths from the document root, arrays transparent (`arms.type` is the
 * `type` of every element of `arms`).
 */
typedef TypePathRegistry = {

	final file: String;
	final keys: Array<String>;

	/** The registry is a directory of documents named after the package of the types they hold (`PackageDocuments`). */
	@:optional final byPackage: Bool;

	/** The registry's records also name MEMBERS of those types (`MemberRegistryRename`). */
	@:optional final members: MemberKeys;

}

/**
 * The record layout of a registry that names members: the top-level array `records`, and per record the string fields
 * holding its name (`name`), the owner's module path (`type`), the member's name (`member`), the kind addressing it
 * (`kind`, else `defaultKind`) and the paired source fragments that cut it (`find`, `replace`, one string or a list). A
 * field of `opaque` holds source text no edit of a rename can prove, so its value is only reported.
 */
typedef MemberKeys = {
	final records: String;
	final name: String;
	final type: String;
	final member: String;
	final kind: String;
	final defaultKind: String;
	final find: String;
	final replace: String;
	final opaque: Array<String>;
}

/**
 * A string value of a registry record: the decoded text, the span between its quotes, and where each decoded code unit
 * starts in the document (one entry more than the text is long), so an edit of the decoded text lands on the raw bytes.
 */
typedef StringSlot = {
	final value: String;
	final inner: Span;
	final offsets: Array<Int>;
}

/** One edit of a registry document, as `CanonicalEdit.applyEdits` takes it. */
typedef RegistryEdit = {
	var span: Span;
	var text: String;
}

/** One record of a registry that names members, read through its `MemberKeys`. */
typedef MemberRecord = {
	final name: String;
	final type: String;
	final kind: String;
	final member: Null<StringSlot>;
	final finds: Array<StringSlot>;
	final replaces: Array<StringSlot>;
	final opaque: Array<{ key: String, slot: StringSlot }>;
}

/** A relocated type: its qualified path before and after. */
typedef TypePathMove = {
	final oldPath: String;
	final newPath: String;
}

/**
 * The declared-registry half of a module relocation. A registry value that spells a relocated path is rewritten by the
 * same token rewrite as every other text (`ModulePathTokens`); what only the declaration can show is a value that names
 * types WITHOUT spelling one — a glob (`pkg.Mod*`) — whose match over a relocated type would flip, which no token rewrite
 * can repair and the relocation therefore refuses.
 */
@:nullSafety(Strict)
final class TypePathRegistries {

	/**
	 * One line per value of `registry` (whose text is `json`) that names a relocated type in one place and not in the
	 * other, or the reason the file cannot be read as JSON. Empty when the relocation keeps every glob's reach.
	 */
	public static function globRefusals(registry: TypePathRegistry, json: String, moved: Array<TypePathMove>): Array<String> {
		final root: JValue = try {
			JValueParser.parse(json);
		} catch (exception: Exception) {
			return ['declared type-path registry ${registry.file} is not JSON: ${exception.message}'];
		};
		final out: Array<String> = [];
		for (key in registry.keys) for (value in valuesAt(root, key.split('.'), 0)) if (isGlob(value)) {
			final re: EReg = Glob.qualifiedNames(value);
			for (m in moved) if (re.match(m.oldPath) != re.match(m.newPath))
				out.push(
					'${registry.file} "$key" holds the pattern "$value", which matches ${re.match(m.oldPath) ? m.oldPath : m.newPath}'
					+ ' but not ${re.match(m.oldPath) ? m.newPath : m.oldPath}'
					+ ' — the move changes what it names; narrow or widen it by hand first'
				);
		}
		return out;
	}

	/** The records of the document `json` as `members` lays them out. Throws the JSON parser's error on a document that does not parse. */
	public static function memberRecords(members: MemberKeys, json: String): Array<MemberRecord> {
		return [
			for (record in recordsOf(JsonProjection.parse(json), members.records))
				{
					name: firstString(record, members.name, json)?.value ?? '',
					type: firstString(record, members.type, json)?.value ?? '',
					kind: firstString(record, members.kind, json)?.value ?? members.defaultKind,
					member: firstString(record, members.member, json),
					finds: stringsAt(record, members.find, json),
					replaces: stringsAt(record, members.replace, json),
					opaque: [
						for (key in members.opaque) for (slot in stringsAt(record, key, json)) { key: key, slot: slot }
					]
				}
		];
	}

	/** The document edit that replaces the decoded range `[from, to)` of `slot` with `text`, which needs no JSON escape. */
	public static function spliceOf(slot: StringSlot, from: Int, to: Int, text: String): RegistryEdit {
		return { span: new Span(slot.offsets[from], slot.offsets[to]), text: text };
	}

	/** Whether `value` carries a glob metacharacter. */
	private static inline function isGlob(value: String): Bool {
		return value.indexOf('*') >= 0 || value.indexOf('?') >= 0 || value.indexOf('[') >= 0;
	}

	/** The objects of the array a top-level member `records` holds. */
	private static function recordsOf(root: QueryNode, records: String): Array<QueryNode> {
		return [
			for (object in root.children) if (object.kind == JsonProjection.OBJECT)
				for (m in object.children) if (m.kind == JsonProjection.MEMBER && m.name == records)
					for (array in m.children) if (array.kind == JsonProjection.ARRAY)
						for (item in array.children) if (item.kind == JsonProjection.OBJECT) item
		];
	}

	/** The string values of `record`'s member `key`: its one string, or the strings of its array. */
	private static function stringsAt(record: QueryNode, key: String, json: String): Array<StringSlot> {
		final out: Array<StringSlot> = [];
		for (m in record.children) if (m.kind == JsonProjection.MEMBER && m.name == key) for (value in m.children) {
			final items: Array<QueryNode> = value.kind == JsonProjection.ARRAY ? value.children : [value];
			for (item in items) if (item.kind == JsonProjection.STRING) out.push(slotOf(item, json));
		}
		return out;
	}

	/** The first string value of `record`'s member `key`; null when it holds none. */
	private static function firstString(record: QueryNode, key: String, json: String): Null<StringSlot> {
		return stringsAt(record, key, json)[0];
	}

	/** The string node `value` decoded by the format's own `unescapeChar`; the parser has refused an escape JSON does not define. */
	private static function slotOf(value: QueryNode, json: String): StringSlot {
		final span: Span = JsonProjection.spanOf(value);
		final inner: Span = new Span(span.from + 1, span.to - 1);
		final decoded: StringBuf = new StringBuf();
		final offsets: Array<Int> = [];
		var i: Int = inner.from;
		while (i < inner.to) {
			final escape: Null<UnescapeResult> = json.fastCodeAt(i) == '\\'.code ? JsonFormat.instance.unescapeChar(json, i + 1) : null;
			final unit: String = escape == null ? json.charAt(i) : String.fromCharCode(escape.char);
			for (_ in 0...unit.length) offsets.push(i);
			decoded.add(unit);
			i += escape == null ? 1 : 1 + escape.consumed;
		}
		offsets.push(inner.to);
		return { value: decoded.toString(), inner: inner, offsets: offsets };
	}

	/** Every string at `path[i..]` under `node`, arrays transparent. */
	private static function valuesAt(node: Null<JValue>, path: Array<String>, i: Int): Array<String> {
		return switch node {
			case JArray(items):
				[for (item in items) for (v in valuesAt(item, path, i)) v];
			case JString(text):
				i == path.length ? [text] : [];
			case JObject(_) if (i < path.length):
				valuesAt(JValueTools.field(node, path[i]), path, i + 1);
			case _:
				[];
		};
	}

}
