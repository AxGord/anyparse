package anyparse.format.text;

import anyparse.format.CommentStyle;
import anyparse.format.Encoding;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;
import anyparse.format.text.TextFormat.BlockCommentDelims;
import anyparse.format.text.TextFormat.BoolLiterals;
import anyparse.format.text.TextFormat.UnescapeResult;

/**
 * Minimal schema-format for the shared C-family block comment widget.
 *
 * `Build.buildParser` requires a `@:schema(...)` reference on every
 * `@:peg` grammar to resolve format-specific literals and policies.
 * The shared `BlockComment` widget is `@:raw` — wraps and seps come
 * from grammar metadata, not the format — but a schema is still
 * required by the macro pipeline. This class provides the minimum
 * fields the macro reads, with values that route the typedef-struct
 * lowering through the positional path (Unquoted `keySyntax`) so
 * `BlockCommentLine` parses as `<ws><body>` rather than as a JSON
 * mapping `{ws: ..., body: ...}`.
 *
 * Lives in the engine package so the widget can be shared across
 * plugin grammars without depending on any specific language format.
 */
@:nullSafety(Strict)
final class CFamilyCommentFormat implements TextFormat {

	public static final instance:CFamilyCommentFormat = new CFamilyCommentFormat();

	public var name(default, null):String = 'CFamilyComment';
	public var version(default, null):String = '1.0';
	public var encoding(default, null):Encoding = Encoding.UTF8;

	public var mappingOpen(default, null):String = '';
	public var mappingClose(default, null):String = '';
	public var sequenceOpen(default, null):Null<String> = null;
	public var sequenceClose(default, null):Null<String> = null;
	public var keyValueSep(default, null):String = '';
	public var entrySep(default, null):String = '';

	public var whitespace(default, null):String = ' \t\n\r';
	public var lineComment(default, null):Null<String> = null;
	public var blockComment(default, null):Null<BlockCommentDelims> = null;

	public var keySyntax(default, null):KeySyntax = KeySyntax.Unquoted;
	public var stringQuote(default, null):Array<String> = [];

	public var fieldLookup(default, null):FieldLookup = FieldLookup.ByName;

	public var trailingSep(default, null):TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null):MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null):UnknownPolicy = UnknownPolicy.Error;

	public var spacedLeads(default, null):Array<String> = [];
	public var tightLeads(default, null):Array<String> = [];

	public var intLiteral(default, null):EReg = ~/^/;
	public var floatLiteral(default, null):EReg = ~/^/;
	public var boolLiterals(default, null):Null<BoolLiterals> = null;
	public var nullLiteral(default, null):Null<String> = null;

	public var defaultWriteOptions(default, null):WriteOptions = {
		indentChar: Tab,
		indentSize: 4,
		tabWidth: 4,
		lineWidth: 120,
		lineEnd: '\n',
		finalNewline: false,
		trailingWhitespace: false,
		commentStyle: Verbatim,
		addLineCommentSpace: true,
	};

	private function new() {}

	public function escapeChar(c:Int):String return String.fromCharCode(c);

	public function unescapeChar(input:String, pos:Int):UnescapeResult {
		return {char: StringTools.fastCodeAt(input, pos), consumed: 1};
	}
}
