package anyparse.grammar.json;

import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * The `json` grammar's QUERY projection: a JSON document parsed by the span parser and walked onto
 * the engine's `QueryNode` tree by the generated walker (`JsonQueryWalker`), under a synthetic
 * `Document` root — the one tree the query plugin (`JsonQueryPlugin`) and the format-preserving
 * writer (`JsonLayoutWriter`) both read.
 *
 * The vocabulary is the grammar's own (`JValue`'s ctor names), and it is the `--select` vocabulary:
 *
 *  - `Document` — the synthetic root, holding the one top-level value; no span.
 *  - `JObject` — `{ … }`, its children the `Member`s in source order.
 *  - `Member` — one `"key": value` entry, NAMED by its decoded key (`Member:thread-safety`), its
 *    one child the value. Its span runs from the key's opening quote to the value's last byte.
 *  - `JArray` — `[ … ]`, its children the element values in source order.
 *  - `JString` — named by its DECODED value (`JString:api.NetRequest2.success`).
 *  - `JNumber`, `JBool`, `JNull` — unnamed; address one by position or `--nth`.
 *
 * Every span but the root value's is tight: it starts at the value's first byte and ends after its
 * last. The span parser's ROOT rule skips the document's leading whitespace itself, so its span
 * starts at offset 0; `parse` tightens it.
 */
@:nullSafety(Strict)
final class JsonProjection {

	/** The synthetic root kind. */
	public static inline final DOCUMENT: String = 'Document';

	/** `{ … }`. */
	public static inline final OBJECT: String = 'JObject';

	/** One `"key": value` entry of an object (`JEntry`'s `@:spanned` kind). */
	public static inline final MEMBER: String = 'Member';

	/** `[ … ]`. */
	public static inline final ARRAY: String = 'JArray';

	/** A string value. */
	public static inline final STRING: String = 'JString';

	/** Is `node` a container — a `JObject` or a `JArray`? */
	public static inline function isContainer(node: QueryNode): Bool {
		return node.kind == OBJECT || node.kind == ARRAY;
	}

	/** Is `code` JSON whitespace (`JsonFormat.whitespace`)? */
	public static inline function isSpace(code: Int): Bool {
		return JsonFormat.instance.whitespace.indexOf(String.fromCharCode(code)) >= 0;
	}

	/** Parse `source` and project it. Throws the parser's `ParseError` on a document that does not parse. */
	public static function parse(source: String): QueryNode {
		return new QueryNode(DOCUMENT, null, [for (value in JsonQueryWalker.walk(source, false)) tight(value, source)]);
	}

	/** `node`'s span; every projected node but the synthetic root carries one. */
	public static function spanOf(node: QueryNode): Span {
		final span: Null<Span> = node.span;
		if (span == null) throw new Exception('json: a ${node.kind} node carries no span');
		return span;
	}

	/** The offset of `member`'s `:` — back from its value's first byte over the whitespace between. */
	public static function colonOf(member: QueryNode, source: String): Int {
		var at: Int = spanOf(member.children[0]).from - 1;
		while (at > 0 && isSpace(source.fastCodeAt(at))) at--;
		if (source.charAt(at) != JsonFormat.instance.keyValueSep)
			throw new Exception('json: expected "${JsonFormat.instance.keyValueSep}" at offset $at');
		return at;
	}

	/** The offset just past `member`'s key — back from its `:` over the whitespace between. */
	public static function keyEndOf(member: QueryNode, source: String): Int {
		var at: Int = colonOf(member, source);
		while (at > 0 && isSpace(source.fastCodeAt(at - 1))) at--;
		return at;
	}

	/** The root `value` with its span past the document's leading whitespace. */
	private static function tight(value: QueryNode, source: String): QueryNode {
		final span: Span = spanOf(value);
		var from: Int = span.from;
		while (from < span.to && isSpace(source.fastCodeAt(from))) from++;
		return from == span.from ? value : new QueryNode(value.kind, value.name, value.children, new Span(from, span.to));
	}

}
