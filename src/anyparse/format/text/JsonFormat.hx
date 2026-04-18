package anyparse.format.text;

import anyparse.format.Encoding;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;
import anyparse.format.text.TextFormat.BlockComment;
import anyparse.format.text.TextFormat.BoolLiterals;
import anyparse.format.text.TextFormat.UnescapeResult;

/**
 * Reference `TextFormat` for JSON.
 *
 * All literal characters, policies and escape handling for JSON live
 * here — the writer reads them from this instance instead of hardcoding
 * them. A user who needs JSON5 or HJSON subclasses (or clones) this
 * file and overrides the relevant fields; the library core never
 * acquires a built-in notion of "JSON" beyond this one class.
 *
 * Singleton: one shared instance is enough, since the format is pure
 * configuration with no per-parse state.
 */
@:nullSafety(Strict)
final class JsonFormat implements TextFormat {

	public static final instance:JsonFormat = new JsonFormat();

	public var name(default, null):String = 'JSON';
	public var version(default, null):String = '1.0';
	public var encoding(default, null):Encoding = Encoding.UTF8;

	public var mappingOpen(default, null):String = '{';
	public var mappingClose(default, null):String = '}';
	public var sequenceOpen(default, null):Null<String> = '[';
	public var sequenceClose(default, null):Null<String> = ']';
	public var keyValueSep(default, null):String = ':';
	public var entrySep(default, null):String = ',';

	public var whitespace(default, null):String = ' \t\n\r';
	public var lineComment(default, null):Null<String> = null;
	public var blockComment(default, null):Null<BlockComment> = null;

	public var keySyntax(default, null):KeySyntax = KeySyntax.Quoted;
	public var stringQuote(default, null):Array<String> = ['"'];

	public var fieldLookup(default, null):FieldLookup = FieldLookup.ByName;

	public var trailingSep(default, null):TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null):MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null):UnknownPolicy = UnknownPolicy.Skip;

	/**
	 * Grammar-type paths for primitive JSON fields. The macro pipeline
	 * routes `Int` / `Float` / `Bool` / `String` schema fields through
	 * these named terminals so typed-JSON parsing reuses the standard
	 * JSON decoders instead of re-implementing them per parser. `null`
	 * for a slot disables the rewrite — the macro falls back to inline
	 * primitive handling (binary mode).
	 */
	public var intType(default, null):Null<String> = 'anyparse.grammar.json.JIntLit';
	public var floatType(default, null):Null<String> = 'anyparse.grammar.json.JNumberLit';
	public var boolType(default, null):Null<String> = 'anyparse.grammar.json.JBoolLit';
	public var stringType(default, null):Null<String> = 'anyparse.grammar.json.JStringLit';

	/**
	 * Universal container for "any JSON value". The ByName struct
	 * codepath routes `UnknownPolicy.Skip` through `parseJValue` and
	 * discards the result, avoiding a second hand-rolled skipper.
	 */
	public var anyType(default, null):Null<String> = 'anyparse.grammar.json.JValue';

	/**
	 * Star struct field open-delimiters that take a leading space from
	 * the preceding token. JSON keeps every open tight (`{"k":"v"}`,
	 * `[1,2]`) so the list is empty — documented here rather than
	 * relying on the extractor's default.
	 */
	public var spacedLeads(default, null):Array<String> = [];

	public var intLiteral(default, null):EReg = ~/^-?(?:0|[1-9][0-9]*)/;
	public var floatLiteral(default, null):EReg = ~/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/;
	public var boolLiterals(default, null):Null<BoolLiterals> = {trueLit: 'true', falseLit: 'false'};
	public var nullLiteral(default, null):Null<String> = 'null';

	/**
	 * Default `WriteOptions` for JSON output: 4-space indent, no trailing
	 * newline. Generated JSON writers use this struct when the caller
	 * omits the `options` argument to `write()`.
	 */
	public var defaultWriteOptions(default, null):WriteOptions = {
		indentChar: Space,
		indentSize: 4,
		tabWidth: 4,
		lineWidth: 120,
		lineEnd: '\n',
		finalNewline: false,
	};

	private function new() {}

	public function escapeChar(c:Int):String {
		return switch c {
			case '"'.code: '\\"';
			case '\\'.code: '\\\\';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case '\t'.code: '\\t';
			case 0x08: '\\b';
			case 0x0C: '\\f';
			case _:
				if (c < 0x20) '\\u' + StringTools.hex(c, 4);
				else String.fromCharCode(c);
		};
	}

	public function unescapeChar(input:String, pos:Int):UnescapeResult {
		final esc:Null<Int> = input.charCodeAt(pos);
		if (esc == null) throw new haxe.Exception('unterminated escape at $pos');
		return switch esc {
			case '"'.code: {char: '"'.code, consumed: 1};
			case '\\'.code: {char: '\\'.code, consumed: 1};
			case '/'.code: {char: '/'.code, consumed: 1};
			case 'n'.code: {char: '\n'.code, consumed: 1};
			case 'r'.code: {char: '\r'.code, consumed: 1};
			case 't'.code: {char: '\t'.code, consumed: 1};
			case 'b'.code: {char: 0x08, consumed: 1};
			case 'f'.code: {char: 0x0C, consumed: 1};
			case 'u'.code:
				if (pos + 5 > input.length) throw new haxe.Exception('incomplete unicode escape at $pos');
				final hex:String = input.substring(pos + 1, pos + 5);
				final code:Null<Int> = Std.parseInt('0x$hex');
				if (code == null) throw new haxe.Exception('invalid unicode escape: $hex');
				{char: code, consumed: 5};
			case _:
				throw new haxe.Exception('invalid escape: \\${String.fromCharCode(esc)}');
		};
	}
}
