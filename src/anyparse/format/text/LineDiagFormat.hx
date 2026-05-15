package anyparse.format.text;

import anyparse.format.CommentStyle;
import anyparse.format.Encoding;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;
import anyparse.format.text.TextFormat.BlockCommentDelims;
import anyparse.format.text.TextFormat.BoolLiterals;
import anyparse.format.text.TextFormat.UnescapeResult;

/**
 * `TextFormat` for the flat one-line diagnostic output of
 * `apq refs` / `apq search` / `apq meta`
 * (`path:line:col: …` style).
 *
 * Unlike `JsonFormat` / `SExprFormat`, this format injects **no**
 * structural punctuation of its own — no `{}`/`[]` wrappers, no
 * key/entry separators. Every literal (`:`, `: [`, `] `, ` -> `,
 * `, `, the inter-line `\n`) is carried by per-field
 * `@:lead`/`@:trail`/`@:sep` metadata on the line grammar typedefs in
 * `anyparse.query.format.line`. The format is `ByPosition` so no field
 * keys are emitted; string fields use verbatim terminals
 * (`LineText`), so nothing is quoted or escaped. This is the project's
 * declarative-writer dogfood for the human-diagnostic surface, sister
 * to the S-expr tree path.
 *
 * Singleton: pure configuration, no per-write state.
 */
@:nullSafety(Strict)
final class LineDiagFormat implements TextFormat {

	public static final instance:LineDiagFormat = new LineDiagFormat();

	public var name(default, null):String = 'line-diagnostic';
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

	public var fieldLookup(default, null):FieldLookup = FieldLookup.ByPosition;

	public var trailingSep(default, null):TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null):MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null):UnknownPolicy = UnknownPolicy.Skip;

	public var intType(default, null):Null<String> = 'anyparse.query.format.line.LineIntLit';
	public var floatType(default, null):Null<String> = null;
	public var boolType(default, null):Null<String> = null;
	public var stringType(default, null):Null<String> = 'anyparse.query.format.line.LineText';
	public var anyType(default, null):Null<String> = null;

	public var spacedLeads(default, null):Array<String> = [];
	public var tightLeads(default, null):Array<String> = [];

	public var intLiteral(default, null):EReg = ~/^-?(?:0|[1-9][0-9]*)/;
	public var floatLiteral(default, null):EReg = ~/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/;
	public var boolLiterals(default, null):Null<BoolLiterals> = null;
	public var nullLiteral(default, null):Null<String> = null;

	/**
	 * Diagnostic lines never wrap (a huge `lineWidth` disables the
	 * Doc `sepList` break decision) and the grammar's own `@:trail`
	 * owns the final newline, so `finalNewline` is off.
	 */
	public var defaultWriteOptions(default, null):WriteOptions = {
		indentChar: Space,
		indentSize: 2,
		tabWidth: 2,
		lineWidth: 1000000,
		lineEnd: '\n',
		finalNewline: false,
		trailingWhitespace: false,
		maxConsecutiveBlanks: -1,
		commentStyle: Verbatim,
		addLineCommentSpace: true,
	};

	private function new() {}

	public function escapeChar(c:Int):String {
		return String.fromCharCode(c);
	}

	public function unescapeChar(input:String, pos:Int):UnescapeResult {
		throw new haxe.Exception('LineDiagFormat is writer-only');
	}
}
