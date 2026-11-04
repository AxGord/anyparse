package anyparse.grammar.json;

import anyparse.format.ArrayMatrixWrap;
import anyparse.format.ConditionalIndentationPolicy;
import anyparse.format.Encoding;
import anyparse.format.TrailingCommaPolicy;
import anyparse.format.WriteOptions;
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.TextFormat;
import anyparse.format.text.TrailingSepPolicy;
import anyparse.format.text.UnknownPolicy;
import haxe.Exception;

using StringTools;

/**
 * Reference `TextFormat` for JSON.
 *
 * All literal characters, policies and escape handling for JSON live
 * here — the writer reads them from this instance instead of hardcoding
 * them. A user who needs JSON5 or HJSON clones this file and changes the
 * relevant fields (the class is `final`, and a `(default, null)` field
 * cannot be overridden); the library core never acquires a built-in
 * notion of "JSON" beyond this one class.
 *
 * Singleton: one shared instance is enough, since the format is pure
 * configuration with no per-parse state.
 */
@:nullSafety(Strict)
final class JsonFormat implements TextFormat {

	public static final instance: JsonFormat = new JsonFormat();

	/** JSON string-escape char code for backspace (`\b`). */
	private static inline final BACKSPACE: Int = 0x08;

	/** JSON string-escape char code for form feed (`\f`). */
	private static inline final FORM_FEED: Int = 0x0C;

	/** The line width of `defaultWriteOptions`. */
	private static inline final DEFAULT_LINE_WIDTH: Int = 120;

	/** A line width no document reaches. */
	private static inline final UNBOUNDED_LINE_WIDTH: Int = 0x3FFFFFFF;

	/** The first high surrogate; the low ones start where the high ones end. */
	private static inline final HIGH_SURROGATE: Int = 0xD800;

	private static inline final LOW_SURROGATE: Int = 0xDC00;
	private static inline final LAST_SURROGATE: Int = 0xDFFF;

	public var name(default, null): String = 'JSON';
	public var version(default, null): String = '1.0';
	public var encoding(default, null): Encoding = Encoding.UTF8;
	public var mappingOpen(default, null): String = '{';
	public var mappingClose(default, null): String = '}';
	public var sequenceOpen(default, null): Null<String> = '[';
	public var sequenceClose(default, null): Null<String> = ']';
	public var keyValueSep(default, null): String = ':';
	public var entrySep(default, null): String = ',';
	public var whitespace(default, null): String = ' \t\n\r';
	public var lineComment(default, null): Null<String> = null;
	public var blockComment(default, null): Null<BlockCommentDelims> = null;
	public var keySyntax(default, null): KeySyntax = KeySyntax.Quoted;
	public var stringQuote(default, null): Array<String> = ['"'];
	public var fieldLookup(default, null): FieldLookup = FieldLookup.ByName;
	public var trailingSep(default, null): TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null): MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null): UnknownPolicy = UnknownPolicy.Skip;

	/**
	 * Grammar-type paths for primitive JSON fields. The macro pipeline
	 * routes `Int` / `Float` / `Bool` / `String` schema fields through
	 * these named terminals so typed-JSON parsing reuses the standard
	 * JSON decoders instead of re-implementing them per parser. `null`
	 * for a slot disables the rewrite — the macro falls back to inline
	 * primitive handling (binary mode).
	 */
	public var intType(default, null): Null<String> = 'anyparse.grammar.json.JIntLit';

	public var floatType(default, null): Null<String> = 'anyparse.grammar.json.JNumberLit';
	public var boolType(default, null): Null<String> = 'anyparse.grammar.json.JBoolLit';
	public var stringType(default, null): Null<String> = 'anyparse.grammar.json.JStringLit';

	/**
	 * Universal container for "any JSON value". The ByName struct
	 * codepath routes `UnknownPolicy.Skip` through `parseJValue` and
	 * discards the result, avoiding a second hand-rolled skipper.
	 */
	public var anyType(default, null): Null<String> = 'anyparse.grammar.json.JValue';

	/**
	 * Star struct field open-delimiters that take a leading space from
	 * the preceding token. JSON keeps every open tight (`{"k":"v"}`,
	 * `[1,2]`) so the list is empty — documented here rather than
	 * relying on the extractor's default.
	 */
	public var spacedLeads(default, null): Array<String> = [];

	/**
	 * Optional `@:lead(...)` strings that emit tight — no leading
	 * separator, no trailing space. JSON has no optional `@:lead`
	 * fields in its core grammar, so the list is empty; declared
	 * explicitly to mirror the spacedLeads contract.
	 */
	public var tightLeads(default, null): Array<String> = [];

	public var intLiteral(default, null): EReg = ~/^-?(?:0|[1-9][0-9]*)/;
	public var floatLiteral(default, null): EReg = ~/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/;
	public var boolLiterals(default, null): Null<BoolLiterals> = { trueLit: 'true', falseLit: 'false' };
	public var nullLiteral(default, null): Null<String> = 'null';

	/**
	 * Default `WriteOptions` for JSON output: 4-space indent, no trailing
	 * newline. Generated JSON writers use this struct when the caller
	 * omits the `options` argument to `write()`.
	 */
	public var defaultWriteOptions(default, null): WriteOptions = writeOptions(DEFAULT_LINE_WIDTH);

	/**
	 * `WriteOptions` for a document no one reads by eye: nothing is wide enough to break, so the whole document is one
	 * line and carries no indentation.
	 */
	public var compactWriteOptions(default, null): WriteOptions = writeOptions(UNBOUNDED_LINE_WIDTH);

	private function new() {}

	/**
	 * `text` as one JSON string, quotes included. A lone surrogate keeps its escape: output is UTF-8, which cannot carry
	 * one, and written bare it would come back as a different character.
	 */
	public function quote(text: String): String {
		final out: StringBuf = new StringBuf();
		out.add('"');
		for (i in 0...text.length) {
			final c: Int = text.fastCodeAt(i);
			out.add(isLoneSurrogate(text, i, c) ? unicodeEscape(c) : escapeChar(c));
		}
		out.add('"');
		return out.toString();
	}

	public function escapeChar(c: Int): String {
		return switch c {
			case '"'.code: '\\"';
			case '\\'.code: '\\\\';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case '\t'.code: '\\t';
			case BACKSPACE: '\\b';
			case FORM_FEED: '\\f';
			case _:
				c < ' '.code ? unicodeEscape(c) : String.fromCharCode(c);
		};
	}

	public function unescapeChar(input: String, pos: Int): UnescapeResult {
		final esc: Null<Int> = input.charCodeAt(pos);
		if (esc == null) throw new Exception('unterminated escape at $pos');
		return switch esc {
			case '"'.code: { char: '"'.code, consumed: 1 };
			case '\\'.code: { char: '\\'.code, consumed: 1 };
			case '/'.code: { char: '/'.code, consumed: 1 };
			case 'n'.code: { char: '\n'.code, consumed: 1 };
			case 'r'.code: { char: '\r'.code, consumed: 1 };
			case 't'.code: { char: '\t'.code, consumed: 1 };
			case 'b'.code: { char: 0x08, consumed: 1 };
			case 'f'.code: { char: 0x0C, consumed: 1 };
			case 'u'.code:
				if (pos + 5 > input.length) throw new Exception('incomplete unicode escape at $pos'); // noqa: magic-number
				final hex: String = input.substring(pos + 1, pos + 5);
				final code: Null<Int> = Std.parseInt('0x$hex');
				if (code == null) throw new Exception('invalid unicode escape: $hex');
				{ char: code, consumed: 5 };
			case _:
				throw new Exception('invalid escape: \\${String.fromCharCode(esc)}');
		};
	}

	private static inline function isLow(c: Int): Bool {
		return c >= LOW_SURROGATE && c <= LAST_SURROGATE;
	}

	/** The `\uXXXX` escape of `c`, in the lower case every native JSON writer spells it in. */
	private static inline function unicodeEscape(c: Int): String {
		return '\\u${c.hex(4).toLowerCase()}';
	}

	/** The write options of JSON output at `lineWidth`. */
	private static function writeOptions(lineWidth: Int): WriteOptions {
		return {
			indentChar: Space,
			indentSize: 4,
			tabWidth: 4,
			lineWidth: lineWidth,
			lineEnd: '\n',
			finalNewline: false,
			trailingWhitespace: false,
			maxConsecutiveBlanks: -1,
			commentStyle: Verbatim,
			arrayMatrixWrap: ArrayMatrixWrap.NoMatrixWrap,
			trailingComma: TrailingCommaPolicy.Keep,
			conditionalPolicy: ConditionalIndentationPolicy.Aligned,
			alignInlineSwitchCaseBody: false,
			comprehensionCuddledOpen: false,
			soleItemCuddledBrackets: false,
			methodChainCuddledLinks: false,
			ternaryCuddledBraces: false,
			addLineCommentSpace: true,
			normalizeLineCommentIndent: false,
			compressSuccessiveParenthesis: true
		};
	}

	/** Whether the code unit `c` at `i` of `text` is half of a surrogate pair with no other half beside it. */
	private static function isLoneSurrogate(text: String, i: Int, c: Int): Bool {
		return c >= HIGH_SURROGATE && c < LOW_SURROGATE
			? i + 1 >= text.length || !isLow(text.fastCodeAt(i + 1))
			: isLow(c) && (i == 0 || text.fastCodeAt(i - 1) < HIGH_SURROGATE || text.fastCodeAt(i - 1) >= LOW_SURROGATE);
	}

}
