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

	/** The line width of `defaultWriteOptions`. */
	private static inline final DEFAULT_LINE_WIDTH: Int = 120;

	/** A line width no document reaches. */
	private static inline final UNBOUNDED_LINE_WIDTH: Int = 0x3FFFFFFF;

	/** The indent of `defaultWriteOptions`. */
	private static inline final DEFAULT_INDENT: Int = 4;

	/** The indent of `expandedWriteOptions`. */
	private static inline final EXPANDED_INDENT: Int = 2;

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
	 * The class a generated parser and writer reach the engine's own JSON through (`JsonNative`), read at compile time:
	 * a by-name schema then gets a shape check over a native parse and a direct compact writer
	 * (`anyparse.macro.NativeDocLowering`). A format with none generates neither.
	 */
	public var nativeDoor(default, null): Null<String> = 'anyparse.grammar.json.JsonNative';

	/**
	 * The targets whose generated parser reads through `nativeDoor`, each a compile define: where the door is measured to
	 * beat the byte-level parser (`docs/formats.md` § "The native door").
	 */
	public var nativeTargets(default, null): Array<String> = ['js', 'cpp', 'jvm'];

	/**
	 * The targets whose compact writer hands the door's writer a copy of the record; elsewhere it appends to a buffer. Only
	 * where the door's writer leaves out a key the copy holds as absent, which `haxe.Json`'s printer writes as `null`.
	 */
	public var nativeWriteTargets(default, null): Array<String> = ['js'];

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
	public var defaultWriteOptions(default, null): WriteOptions = writeOptions(DEFAULT_LINE_WIDTH, DEFAULT_INDENT, false);

	/**
	 * `WriteOptions` for a document no one reads by eye: one line, no whitespace at all. A generated by-name writer takes
	 * this very record to its direct compact path (`JsonNative.isCompact`); a schema that path cannot write renders it
	 * through the Doc writer, one line with a space after each comma.
	 */
	public var compactWriteOptions(default, null): WriteOptions = writeOptions(UNBOUNDED_LINE_WIDTH, DEFAULT_INDENT, false);

	/**
	 * `WriteOptions` for a report a person reads and a tool diffs line by line: two spaces of indent, a space after each
	 * colon, and every non-empty container broken, one member per line at any width — a line width of zero, where no
	 * group fits flat. The layout `JSON.stringify(value, null, '  ')` prints.
	 */
	public var expandedWriteOptions(default, null): WriteOptions = writeOptions(0, EXPANDED_INDENT, true);

	private function new() {}

	/** `text` as one JSON string, quotes included (`JsonText.quote`). */
	public inline function quote(text: String): String {
		return JsonText.quote(text);
	}

	public function escapeChar(c: Int): String {
		return JsonText.escapeChar(c);
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

	/** The write options of JSON output at `lineWidth`, indented by `indentSize` spaces, `keyValueSpace` after each colon. */
	private static function writeOptions(lineWidth: Int, indentSize: Int, keyValueSpace: Bool): WriteOptions {
		return {
			indentChar: Space,
			indentSize: indentSize,
			tabWidth: DEFAULT_INDENT,
			lineWidth: lineWidth,
			lineEnd: '\n',
			finalNewline: false,
			keyValueSpace: keyValueSpace,
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

}
