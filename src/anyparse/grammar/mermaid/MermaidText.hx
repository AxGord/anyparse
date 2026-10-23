package anyparse.grammar.mermaid;

using StringTools;

/**
 * The label codec of the Mermaid grammar, declared once and named by every label terminal's
 * `@:decode` / `@:encode` pair. Mermaid has no backslash escape: a character the syntax would read
 * is written as an entity code `#name;` / `#123;`, which Mermaid hands to its HTML renderer as
 * `&name;` / `&#123;`. A label is one of three kinds, each its own grammar ctor:
 *
 *  - PLAIN — the text a reader sees. Codes decode to their characters; `<`, `>`, a `&` that would
 *    start a reference, `"`, an entity-shaped `#` and a backtick that would open a markdown string
 *    are re-escaped on write, so `Map<String, Int>` renders literally.
 *  - MARKUP — a label holding raw HTML (`a<br>b`), an HTML reference, or a code the codec does not
 *    resolve: the HTML Mermaid renders, so a code for `<` `>` `&` or an unknown name decodes to the
 *    HTML reference, and markup is written back raw.
 *  - MARKDOWN — the body of a ``"`…`"`` string, decoded like markup.
 *
 * A numeric code outside Unicode, or a surrogate, resolves to nothing and stays as written. The
 * codec scans with no regular expression, so it keeps no state between calls.
 */
@:nullSafety(Strict)
final class MermaidText {

	/** The highest Unicode code point. */
	private static inline final MAX_CODE_POINT: Int = 0x10FFFF;

	/** The first and last UTF-16 surrogate code points, which name no character. */
	private static inline final SURROGATE_FIRST: Int = 0xD800;

	private static inline final SURROGATE_LAST: Int = 0xDFFF;

	/** Digits beyond this many make a numeric code larger than any code point. */
	private static inline final MAX_CODE_DIGITS: Int = 7;

	/** Characters that never appear in a bare label: delimiters, the quote, the escapes, markup, `%%`. */
	private static inline final UNSAFE: String = '[](){}|"/\\#&;<>%';

	/** The named entity codes the codec resolves; any other name is markup. */
	private static final NAMED: Map<String, Int> = [
		'quot' => '"'.code,
		'amp' => '&'.code,
		'lt' => '<'.code,
		'gt' => '>'.code,
		'apos' => "'".code,
		'nbsp' => 0xA0
	];

	/** A plain node, pipe or subgraph-title label: bare when every character is safe, quoted otherwise. */
	public static inline function encodePlain(text: String): String {
		return encodePlainAvoiding(text, '');
	}

	/** A plain `-- text -->` label, which may not hold a `-` bare. */
	public static inline function encodePlainSolid(text: String): String {
		return encodePlainAvoiding(text, '-');
	}

	/** A plain `== text ==>` label, which may not hold a `=` bare. */
	public static inline function encodePlainThick(text: String): String {
		return encodePlainAvoiding(text, '=');
	}

	/** A plain `-. text .->` label, which may not hold a `.` bare. */
	public static inline function encodePlainDotted(text: String): String {
		return encodePlainAvoiding(text, '.');
	}

	/** The text a plain label shows: quotes stripped or a bare label trimmed, then its codes resolved. */
	public static function decodePlain(raw: String): String {
		return resolveCodes(unwrap(raw), false);
	}

	/** The HTML a markup label renders: quotes stripped or a bare label trimmed, then its codes resolved. */
	public static function decodeMarkup(raw: String): String {
		return resolveCodes(unwrap(raw), true);
	}

	/** The body of a ``"`…`"`` markdown string, its codes resolved as markup. */
	public static function decodeMarkdown(raw: String): String {
		return resolveCodes(raw.substring(2, raw.length - 2), true);
	}

	/** A markup label: always quoted, its markup raw. */
	public static function encodeMarkup(html: String): String {
		return '"${escape(html, false)}"';
	}

	/** A markdown string. */
	public static function encodeMarkdown(text: String): String {
		return '"`${escape(text, false, true)}`"';
	}

	/** One character as it is written inside a quoted label. */
	public static function escapeQuoted(code: Int): String {
		return code == '"'.code ? '#quot;' : String.fromCharCode(code);
	}

	/** Whether the character before `at` is a `&` — the `#` of a numeric HTML reference, which markup keeps. */
	private static inline function followsAmpersand(text: String, at: Int): Bool {
		return at > 0 && text.fastCodeAt(at - 1) == '&'.code;
	}

	private static inline function isAlphaNumeric(c: Int): Bool {
		return (c >= '0'.code && c <= '9'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= 'a'.code && c <= 'z'.code);
	}

	private static function encodePlainAvoiding(text: String, delimiter: String): String {
		return isBare(text, delimiter) ? text : '"${escape(text, true)}"';
	}

	private static function isBare(text: String, delimiter: String): Bool {
		if (text.length == 0 || text.trim() != text) return false;
		for (i in 0...text.length) {
			final c: String = text.charAt(i);
			if (UNSAFE.indexOf(c) >= 0 || c == delimiter || c == '\n' || c == '\r' || c == '\t') return false;
		}
		return true;
	}

	/** A quoted label's body, or a bare label trimmed. */
	private static function unwrap(raw: String): String {
		final quoted: Bool = raw.length >= 2 && raw.fastCodeAt(0) == '"'.code && raw.fastCodeAt(raw.length - 1) == '"'.code;
		return quoted ? raw.substring(1, raw.length - 1) : raw.trim();
	}

	/**
	 * `body` with each entity code replaced: by its character, or for
	 * `markup` by an HTML reference where the character is markup or unknown.
	 */
	private static function resolveCodes(body: String, markup: Bool): String {
		final buf: StringBuf = new StringBuf();
		var copied: Int = 0;
		var i: Int = 0;
		while (i < body.length) {
			final end: Int = followsAmpersand(body, i) ? -1 : codeEnd(body, i);
			if (end < 0) {
				i++;
				continue;
			}
			buf.addSub(body, copied, i - copied);
			buf.add(resolveCode(body.substring(i + 1, end - 1), markup));
			i = end;
			copied = end;
		}
		buf.addSub(body, copied, body.length - copied);
		return buf.toString();
	}

	private static function resolveCode(name: String, markup: Bool): String {
		final code: Null<Int> = codePoint(name);
		final reference: String = isNumeric(name) ? '&#$name;' : '&$name;';
		if (code == null) return markup ? reference : '#$name;';
		if (markup && (code == '<'.code || code == '>'.code || code == '&'.code)) return reference;
		return String.fromCharCode(code);
	}

	/** The code point `name` (the text between `#` and `;`) names, or null for an unknown name or an invalid number. */
	private static function codePoint(name: String): Null<Int> {
		if (!isNumeric(name)) return NAMED[name];
		if (name.length > MAX_CODE_DIGITS) return null;
		final code: Null<Int> = Std.parseInt(name);
		return code == null || code < 1 || code > MAX_CODE_POINT || (code >= SURROGATE_FIRST && code <= SURROGATE_LAST) ? null : code;
	}

	/** Whether `name` is all digits — a numeric code rather than a named one. */
	private static function isNumeric(name: String): Bool {
		for (i in 0...name.length) {
			final c: Int = name.fastCodeAt(i);
			if (c < '0'.code || c > '9'.code) return false;
		}
		return true;
	}

	/** The offset past the entity code `#name;` that starts at `at`, or -1 when none does. */
	private static function codeEnd(text: String, at: Int): Int {
		if (text.fastCodeAt(at) != '#'.code) return -1;
		var j: Int = at + 1;
		while (j < text.length && isAlphaNumeric(text.fastCodeAt(j))) j++;
		return j > at + 1 && j < text.length && text.fastCodeAt(j) == ';'.code ? j + 1 : -1;
	}

	/** Whether a `&` at `at` starts an HTML reference (`&name;`, `&#123;`). */
	private static function startsReference(text: String, at: Int): Bool {
		var j: Int = at + 1;
		while (j < text.length && (isAlphaNumeric(text.fastCodeAt(j)) || text.fastCodeAt(j) == '#'.code)) j++;
		return j > at + 1 && j < text.length && text.fastCodeAt(j) == ';'.code;
	}

	/**
	 * `text` as the body of a quoted label: the quote, an entity-shaped `#` and a backtick that would
	 * open a markdown string (every backtick inside one) escaped, and for `plain` the markup characters
	 * too. Unescaped runs are copied whole, so a multi-byte character is never split.
	 */
	private static function escape(text: String, plain: Bool, markdown: Bool = false): String {
		final buf: StringBuf = new StringBuf();
		var copied: Int = 0;
		for (i in 0...text.length) {
			final c: Int = text.fastCodeAt(i);
			final replacement: Null<String> = switch c {
				case '"'.code: '#quot;';
				case '#'.code if (codeEnd(text, i) >= 0 && (plain || !followsAmpersand(text, i))): '#35;';
				case '`'.code if (markdown || i == 0): '#96;';
				case _ if (plain): plainEscape(text, i);
				case _: null;
			};
			if (replacement == null) continue;
			buf.addSub(text, copied, i - copied);
			buf.add(replacement);
			copied = i + 1;
		}
		buf.addSub(text, copied, text.length - copied);
		return buf.toString();
	}

	/** The code a plain label writes for the markup character at `at`, or null when it needs none. */
	private static function plainEscape(text: String, at: Int): Null<String> {
		return switch text.fastCodeAt(at) {
			case '<'.code: '#lt;';
			case '>'.code: '#gt;';
			case '&'.code if (startsReference(text, at)): '#amp;';
			case _: null;
		};
	}

}
