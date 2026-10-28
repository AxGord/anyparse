package anyparse.query.cli;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import haxe.Json;

/**
 * A dotted key path into a DATA document (`apq get`), walked over the grammar's projected tree with no
 * grammar named: an object is the grammar's `RefShape.objectLiteralKind`, its children entries NAMED by
 * their decoded key whose last child is the value; an array is `arrayLiteralKind`, its children the
 * elements; a string is one of `stringLiteralKinds`, NAMED by its decoded value. Any other leaf is a
 * scalar whose value is its source text.
 *
 * Path syntax: segments joined by `.`; a segment of digits indexes an array; `\.` is a dot inside a key and
 * `\\` a backslash; the empty path and `.` name the whole document.
 */
@:nullSafety(Strict)
final class DataPath {

	private static inline final SEPARATOR: String = '.';
	private static inline final ESCAPE: String = '\\';

	/**
	 * Can a document of the grammar `shape` describes be walked at all — does it declare an object or an array
	 * kind? A grammar with neither (a diagram) has no key or index to name.
	 */
	public static inline function walkable(shape: RefShape): Bool {
		return shape.objectLiteralKind != null || shape.arrayLiteralKind != null;
	}

	/** The segments of `path`; throws `UsageFailure` on an escape that escapes nothing. */
	public static function parse(path: String): Array<String> {
		if (path == '' || path == SEPARATOR) return [];
		final segments: Array<String> = [];
		var current: StringBuf = new StringBuf();
		var at: Int = 0;
		while (at < path.length) {
			final char: String = path.charAt(at);
			if (char == ESCAPE) {
				final next: String = path.charAt(at + 1);
				if (next != SEPARATOR && next != ESCAPE)
					throw new UsageFailure('path "$path": "\\" at offset $at escapes neither "." nor "\\"');
				current.add(next);
				at += 2;
				continue;
			}
			if (char == SEPARATOR) {
				segments.push(current.toString());
				current = new StringBuf();
			} else {
				current.add(char);
			}
			at++;
		}
		segments.push(current.toString());
		return segments;
	}

	/** `segments` written back as a path — the inverse of `parse`, for messages. */
	public static function format(segments: Array<String>): String {
		return [
			for (segment in segments) segment.split(ESCAPE).join(ESCAPE + ESCAPE).split(SEPARATOR).join(ESCAPE + SEPARATOR)
		].join(SEPARATOR);
	}

	/**
	 * The value `node` stands for: a wrapper that is neither a container nor a string and holds exactly one
	 * child — a document root, an object entry — stands for that child.
	 */
	public static function valueOf(node: QueryNode, shape: RefShape): QueryNode {
		var value: QueryNode = node;
		while (!isContainer(value, shape) && !isString(value, shape) && value.children.length == 1) value = value.children[0];
		return value;
	}

	/** The value at `segments` from `start` (a value, see `valueOf`), or why there is none. */
	public static function resolve(start: QueryNode, segments: Array<String>, shape: RefShape): DataLookup {
		var node: QueryNode = valueOf(start, shape);
		for (i in 0...segments.length) {
			final segment: String = segments[i];
			final next: Null<QueryNode> = step(node, segment, shape);
			if (next == null) {
				final at: String = i == 0 ? 'the document' : '"${format(segments.slice(0, i))}"';
				return Missing('$at is ${describe(node, shape)} — no ${node.kind == shape.arrayLiteralKind ? 'index' : 'key'} "$segment"');
			}
			node = valueOf(next, shape);
		}
		return Found(node);
	}

	/**
	 * `value` as `apq get` prints it: a string decoded and unquoted, a scalar as written, an object or array as
	 * compact JSON.
	 */
	public static function render(value: QueryNode, source: String, shape: RefShape): String {
		return isString(value, shape) ? value.name ?? '' : json(value, source, shape);
	}

	/** `value` as compact JSON: strings quoted and escaped, scalars as written, keys in source order. */
	public static function json(value: QueryNode, source: String, shape: RefShape): String {
		if (isString(value, shape)) return Json.stringify(value.name ?? '');
		if (value.kind == shape.objectLiteralKind) return '{'
			+ [
				for (entry in value.children) Json.stringify(entry.name ?? '') + ':${json(valueOf(entry, shape), source, shape)}'
			].join(',') + '}';
		if (value.kind == shape.arrayLiteralKind)
			return '[' + [for (element in value.children) json(valueOf(element, shape), source, shape)].join(',') + ']';
		final span: Null<Span> = value.span;
		if (span == null || value.children.length > 0) throw new UsageFailure('a ${value.kind} node is not a data value');
		return source.substring(span.from, span.to);
	}

	private static inline function isContainer(node: QueryNode, shape: RefShape): Bool {
		return node.kind == shape.objectLiteralKind || node.kind == shape.arrayLiteralKind;
	}

	private static inline function isString(node: QueryNode, shape: RefShape): Bool {
		final kinds: Null<Array<String>> = shape.stringLiteralKinds;
		return kinds != null && kinds.contains(node.kind);
	}

	/** The child `segment` names in `node`: the LAST entry of that key (as a JSON reader keeps it), or the element at that index. */
	private static function step(node: QueryNode, segment: String, shape: RefShape): Null<QueryNode> {
		if (node.kind == shape.objectLiteralKind) {
			var found: Null<QueryNode> = null;
			for (entry in node.children) if (entry.name == segment) found = entry;
			return found;
		}
		if (node.kind != shape.arrayLiteralKind) return null;
		final index: Null<Int> = SourceText.parseStrictInt(segment);
		return index == null || index < 0 || index >= node.children.length ? null : node.children[index];
	}

	private static function describe(node: QueryNode, shape: RefShape): String {
		if (node.kind != shape.objectLiteralKind)
			return node.kind == shape.arrayLiteralKind
				? 'an array of ${node.children.length}'
				: 'a ${node.kind}, not an object or an array';
		final keys: Array<String> = [for (entry in node.children) '"${entry.name ?? ''}"'];
		return keys.length == 0 ? 'an empty object' : 'an object with keys ${keys.join(', ')}';
	}

}

/** What `DataPath.resolve` answers. */
enum DataLookup {
	Found(value: QueryNode);
	Missing(why: String);
}
