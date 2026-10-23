package anyparse.grammar.mermaid;

using StringTools;

/**
 * The label codec of the Mermaid grammar, declared once and named by every label terminal's
 * `@:decode` / `@:encode` pair, so an AST label is the TEXT a reader sees and any string round-trips.
 *
 * Mermaid has no backslash escape: a label is either bare (delimited by the bracket that encloses it)
 * or double-quoted, and a character the syntax would read is written as an entity code `#name;` or
 * `#123;`, which Mermaid hands to the browser as `&name;`. `decode` strips the quotes (or trims a bare
 * label) and resolves the entity codes it knows; an unknown `#name;` stays in the text, because
 * Mermaid would render it as an entity too. `encode` writes a label bare when every character is safe
 * in every position the label can occupy, and quoted otherwise: inside the quotes `"` becomes
 * `#quot;`, a `#` that would start a known entity becomes `#35;`, and a backtick that would open or
 * break a markdown string becomes `#96;`. A label that starts and ends with a backtick IS a markdown
 * string, as in Mermaid itself.
 */
@:nullSafety(Strict)
final class MermaidText {

	/** Characters that never appear in a bare label: delimiters, the quote, the escape and markdown openers. */
	private static inline final UNSAFE: String = '[](){}|"/\\`#&;<>';

	/** One entity code, anchored where a scan finds it. */
	private static final ENTITY: EReg = ~/#([A-Za-z0-9]+);/;

	/** Every entity code of a label. */
	private static final ENTITIES: EReg = ~/#([A-Za-z0-9]+);/g;

	/** A numeric entity code (`#124;`). */
	private static final DIGITS: EReg = ~/^[0-9]+$/;

	/** The named entity codes the codec resolves; any other name stays in the text. */
	private static final NAMED: Map<String, Int> = [
		'quot' => '"'.code,
		'amp' => '&'.code,
		'lt' => '<'.code,
		'gt' => '>'.code,
		'apos' => "'".code,
		'nbsp' => 0xA0
	];

	/** A node, pipe or subgraph-title label. */
	public static inline function encode(text: String): String {
		return encodeAvoiding(text, '');
	}

	/** The label of a `-- text -->` edge, which may not hold a `-` bare. */
	public static inline function encodeSolid(text: String): String {
		return encodeAvoiding(text, '-');
	}

	/** The label of a `== text ==>` edge, which may not hold a `=` bare. */
	public static inline function encodeThick(text: String): String {
		return encodeAvoiding(text, '=');
	}

	/** The label of a `-. text .->` edge, which may not hold a `.` bare. */
	public static inline function encodeDotted(text: String): String {
		return encodeAvoiding(text, '.');
	}

	/** The text a label spells: quotes stripped or a bare label trimmed, then the entity codes resolved. */
	public static function decode(raw: String): String {
		final quoted: Bool = raw.length >= 2 && raw.fastCodeAt(0) == '"'.code && raw.fastCodeAt(raw.length - 1) == '"'.code;
		return ENTITIES.map(quoted ? raw.substring(1, raw.length - 1) : raw.trim(), entity -> {
			final code: Null<Int> = codeOf(entity.matched(1));
			code == null ? entity.matched(0) : String.fromCharCode(code);
		});
	}

	/** One character as it is written inside a quoted label. */
	public static function escapeQuoted(code: Int): String {
		return code == '"'.code ? '#quot;' : String.fromCharCode(code);
	}

	private static function encodeAvoiding(text: String, delimiter: String): String {
		return isBare(text, delimiter) ? text : quote(text);
	}

	private static function isBare(text: String, delimiter: String): Bool {
		if (text.length == 0 || text.trim() != text) return false;
		for (i in 0...text.length) {
			final c: String = text.charAt(i);
			if (UNSAFE.indexOf(c) >= 0 || c == delimiter || c == '\n' || c == '\r' || c == '\t') return false;
		}
		return true;
	}

	private static function codeOf(name: String): Null<Int> {
		return DIGITS.match(name) ? Std.parseInt(name) : NAMED[name];
	}

	private static function quote(text: String): String {
		final markdown: Bool = text.length >= 2 && text.startsWith('`') && text.endsWith('`');
		final buf: StringBuf = new StringBuf();
		buf.add('"');
		for (i in 0...text.length) {
			final c: Int = text.fastCodeAt(i);
			final edge: Bool = i == 0 || i == text.length - 1;
			if (c == '#'.code && startsEntity(text, i))
				buf.add('#35;');
			else if (c == '`'.code && (markdown ? !edge : i == 0))
				buf.add('#96;');
			else
				buf.add(escapeQuoted(c));
		}
		buf.add('"');
		return buf.toString();
	}

	private static function startsEntity(text: String, at: Int): Bool {
		return ENTITY.matchSub(text, at) && ENTITY.matchedPos().pos == at && codeOf(ENTITY.matched(1)) != null;
	}

}
