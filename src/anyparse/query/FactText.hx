package anyparse.query;

import anyparse.query.CompilerFacts.CallFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import haxe.Json;
import haxe.io.Bytes;

/**
 * The text side of the compiler facts: reading a facts line without parsing it, the content hash a facts file records
 * per file, and whether a fact the compiler placed at a source range is about the expression written there.
 */
@:nullSafety(Strict)
final class FactText {

	/** The prefix every node line starts with, which the writer guarantees: id, home file, range. */
	private static final NODE_HEAD: EReg = ~/^\{"k":"node","id":("(?:[^"\\]|\\.)*"),"f":("(?:[^"\\]|\\.)*"),"p":\[(\d+),(\d+)\]/;

	/** A position in a file other than its record's: three numbers. */
	private static final FOREIGN_POSITION: EReg = ~/\[\d+,\d+,\d+\]/;

	/** A bare identifier. */
	private static final IDENTIFIER: EReg = ~/^[A-Za-z_][A-Za-z0-9_]*$/;

	/** The `NODE_HEAD` groups of a node's range. */
	private static inline final HEAD_MIN: Int = 3;

	private static inline final HEAD_MAX: Int = 4;

	/** The length of an accessor's `get_`/`set_` prefix. */
	private static inline final ACCESSOR_PREFIX: Int = 4;

	/**
	 * The head of a node line — id, home file as written, range — whether it holds a foreign position, and whether its
	 * body was generated; null for a line that is not one.
	 */
	public static function nodeHead(line: String): Null<NodeHead> {
		if (!NODE_HEAD.match(line)) return null;
		return {
			id: Json.parse(NODE_HEAD.matched(1)),
			file: Json.parse(NODE_HEAD.matched(2)),
			min: Std.parseInt(NODE_HEAD.matched(HEAD_MIN)) ?? 0,
			max: Std.parseInt(NODE_HEAD.matched(HEAD_MAX)) ?? 0,
			foreign: FOREIGN_POSITION.match(line),
			generated: line.indexOf(',"gen":true') >= 0 || line.indexOf(',"gi":true') >= 0 || line.indexOf(',"inl":') >= 0
		};
	}

	/** The `len:md5` of `source` as UTF-8, the hash the facts file records for each file it homes a record in. */
	public static function contentHash(source: String): String {
		final bytes: Bytes = Bytes.ofString(source);
		return '${bytes.length}:${haxe.crypto.Md5.make(bytes).toHex()}';
	}

	/** A line the table keeps, detached from the dump it was cut from so the dump's text can be freed. */
	public static function detached(line: String): String {
		#if js
		return js.Syntax.code('(" " + {0}).slice(1)', line);
		#else
		return line;
		#end
	}

	/** Whether `text` is a bare identifier. */
	public static function bare(text: String): Bool {
		return IDENTIFIER.match(text);
	}

	/**
	 * Every positioned type `n` records for an expression, with the member name the expression's text must spell for it
	 * to count (null when any text may carry it); a local's reads only when the asked text is a bare identifier (`bare`).
	 */
	public static function typedSites(n: FactNode, bare: Bool): Array<{ at: Null<FactPos>, type: String, member: Null<String> }> {
		final out: Array<{ at: Null<FactPos>, type: String, member: Null<String> }> = [];
		for (c in n.calls) {
			out.push({ at: c.at, type: c.result, member: calledMember(c) });
			final receiver: Null<String> = c.receiver;
			if (receiver != null) out.push({ at: c.receiverAt, type: receiver, member: null });
		}
		for (f in n.fields) out.push({ at: f.at, type: f.type, member: f.field });
		for (v in n.vars) out.push({ at: v.at, type: v.type, member: v.name });
		if (bare) for (r in n.reads) out.push({ at: r.at, type: r.type, member: null });
		for (s in n.strings) out.push({ at: s.at, type: s.operand, member: null });
		for (f in n.flows) if (f.via == 'arg' || f.via == 'arr' || f.via == 'obj') out.push({ at: f.at, type: f.from, member: null });
		for (x in n.news) {
			final id: String = CompilerFacts.baseId(x.type);
			out.push({ at: x.at, type: x.instance, member: id.substr(id.lastIndexOf('.') + 1) });
		}
		return out;
	}

	/** Whether `text` holds `name` as a whole word. */
	public static function mentions(text: String, name: String): Bool {
		var from: Int = text.indexOf(name);
		while (from >= 0) {
			final before: Int = from == 0 ? ' '.code : StringTools.fastCodeAt(text, from - 1);
			final end: Int = from + name.length;
			final after: Int = end >= text.length ? ' '.code : StringTools.fastCodeAt(text, end);
			if (!isWordChar(before) && !isWordChar(after)) return true;
			from = text.indexOf(name, from + 1);
		}
		return false;
	}

	/** The name a call site's text spells for what it calls — an accessor's property, a local function's binder — or null. */
	private static function calledMember(c: CallFact): Null<String> {
		final target: Null<String> = c.target;
		if (target == null || c.access == 'local' || c.access == 'value') return null;
		if (c.access == 'super') return 'super';
		final name: String = target.substr(target.lastIndexOf('.') + 1);
		return StringTools.startsWith(name, 'get_') || StringTools.startsWith(name, 'set_') ? name.substr(ACCESSOR_PREFIX) : name;
	}

	private static function isWordChar(c: Int): Bool {
		return c == '_'.code || (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code);
	}

}

/** A node line's head, read without parsing the line. */
typedef NodeHead = {
	final id: String;
	final file: String;
	final min: Int;
	final max: Int;
	final foreign: Bool;

	/**
	 * Whether no range of its file may claim the node: a body a macro placed (`gen`), a `@:generic` instance's copy of
	 * its generic class's body (`gi`), or a function spliced in from another body (`inl`). Such a node is found by id.
	 */
	final generated: Bool;
}
