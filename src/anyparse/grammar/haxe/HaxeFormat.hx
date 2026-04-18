package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.Encoding;
import anyparse.format.IndentChar;
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.TextFormat;
import anyparse.format.text.TextFormat.BlockComment;
import anyparse.format.text.TextFormat.BoolLiterals;
import anyparse.format.text.TextFormat.UnescapeResult;
import anyparse.format.text.TrailingSepPolicy;
import anyparse.format.text.UnknownPolicy;

/**
 * Text-format descriptor for the Haxe programming language.
 *
 * **Known debt**: the `TextFormat` interface was designed for structured-
 * text formats in the JSON family (mapping open/close, sequence open/close,
 * quote characters, key/value separator, trailing-separator policy, …).
 * These concepts do not apply cleanly to a programming language — `{}` in
 * Haxe delimits a class body, not a JSON mapping, and the literal
 * vocabulary of the language is far richer than anything a `TextFormat`
 * can express.
 *
 * `FormatReader.resolve` in the Phase 2 macro pipeline currently extracts
 * **only the `whitespace` field** from the resolved format class (see
 * `src/anyparse/macro/FormatReader.hx`), so implementing the interface
 * with placeholder values for the rest is enough to drive the existing
 * pipeline. A dedicated `LanguageFormat` interface will appear once the
 * Pratt / Indent strategies demand format-provided data that cannot be
 * expressed as a `TextFormat` shape; until then this class lives in the
 * grammar package rather than polluting `anyparse.format.text.*`.
 *
 * Singleton for the same reason as `JsonFormat`: the fields are pure
 * configuration with no per-parse state.
 */
@:nullSafety(Strict)
final class HaxeFormat implements TextFormat {

	public static final instance:HaxeFormat = new HaxeFormat();

	public var name(default, null):String = 'Haxe';
	public var version(default, null):String = '4';
	public var encoding(default, null):Encoding = Encoding.UTF8;

	public var mappingOpen(default, null):String = '{';
	public var mappingClose(default, null):String = '}';
	public var sequenceOpen(default, null):Null<String> = null;
	public var sequenceClose(default, null):Null<String> = null;
	public var keyValueSep(default, null):String = ':';
	public var entrySep(default, null):String = ',';

	public var whitespace(default, null):String = ' \t\n\r';
	public var lineComment(default, null):Null<String> = '//';
	public var blockComment(default, null):Null<BlockComment> = {open: '/*', close: '*/'};

	public var keySyntax(default, null):KeySyntax = KeySyntax.Unquoted;
	public var stringQuote(default, null):Array<String> = ['"', "'"];

	public var fieldLookup(default, null):FieldLookup = FieldLookup.ByName;

	public var trailingSep(default, null):TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null):MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null):UnknownPolicy = UnknownPolicy.Error;

	/**
	 * Star struct field open-delimiters that take a leading space from
	 * the preceding token. For Haxe only `{` block-opens do — `(` and
	 * `[` stay tight against the previous identifier, yielding
	 * `function main()` / `a[0]` / `new Foo(x)` rather than
	 * `function main ()` / `a [0]` / `new Foo (x)`.
	 */
	public var spacedLeads(default, null):Array<String> = ['{'];

	/**
	 * Optional `@:lead(...)` strings that emit tight — no leading
	 * separator, no trailing space. For Haxe the type-annotation colon
	 * is the canonical tight lead, so `function f():Int` and
	 * `var x:Type` keep their compact native layout instead of the
	 * spaced ` : ` that would be applied to keyword-like leads
	 * (`else`, `catch`).
	 */
	public var tightLeads(default, null):Array<String> = [':'];

	public var intLiteral(default, null):EReg = ~/^-?(?:0|[1-9][0-9]*)/;
	public var floatLiteral(default, null):EReg = ~/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/;
	public var boolLiterals(default, null):Null<BoolLiterals> = {trueLit: 'true', falseLit: 'false'};
	public var nullLiteral(default, null):Null<String> = 'null';

	/**
	 * Default `WriteOptions` for Haxe output: tab indent, 4-column tab
	 * width, terminal newline. Generated Haxe writers use this struct
	 * when the caller omits the `options` argument to `write()`.
	 *
	 * Declared as `HxModuleWriteOptions` (not the base `WriteOptions`)
	 * so Haxe-specific knobs (`sameLine*` from τ₁, `trailingComma*`
	 * from τ₂, …) are present in the defaulted struct — generated
	 * writers cast this value to `HxModuleWriteOptions` at entry.
	 *
	 * Same-line defaults match haxe-formatter's `sameLine` defaults
	 * (`ifElse`/`tryCatch`/`doWhile` are all same-line by default).
	 *
	 * Trailing-comma defaults mirror haxe-formatter's `trailingComma`
	 * defaults — all groups are `false` by default; the trailing `,`
	 * only appears when the user opts in per group.
	 *
	 * Body-placement defaults (ψ₄) are `Same` for `if` / `else` / `for`
	 * / `while` — non-block bodies stay on the same line as the
	 * preceding header. Opting into `Next` or `FitLine` requires an
	 * explicit `hxformat.json` override.
	 *
	 * Exception: `doBody` defaults to `Next` (ψ₅), matching haxe-
	 * formatter's `sameLine.doWhileBody: @:default(Next)` — the
	 * corpus reference expects `do` non-block bodies on the next line
	 * by default, and opting in to same-line requires
	 * `sameLine.doWhileBody: "same"` in the user's `hxformat.json`.
	 */
	public var defaultWriteOptions(default, null):HxModuleWriteOptions = {
		indentChar: Tab,
		indentSize: 1,
		tabWidth: 4,
		lineWidth: 120,
		lineEnd: '\n',
		finalNewline: true,
		sameLineElse: true,
		sameLineCatch: true,
		sameLineDoWhile: true,
		trailingCommaArrays: false,
		trailingCommaArgs: false,
		trailingCommaParams: false,
		ifBody: BodyPolicy.Same,
		elseBody: BodyPolicy.Same,
		forBody: BodyPolicy.Same,
		whileBody: BodyPolicy.Same,
		doBody: BodyPolicy.Next,
	};

	private function new() {}

	public function escapeChar(c:Int):String {
		return switch c {
			case '"'.code: '\\"';
			case '\\'.code: '\\\\';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case '\t'.code: '\\t';
			case _:
				if (c < 0x20) '\\x' + StringTools.hex(c, 2);
				else String.fromCharCode(c);
		};
	}

	public function unescapeChar(input:String, pos:Int):UnescapeResult {
		final esc:Null<Int> = input.charCodeAt(pos);
		if (esc == null) throw new haxe.Exception('unterminated escape at $pos');
		return switch esc {
			case '"'.code: {char: '"'.code, consumed: 1};
			case '\\'.code: {char: '\\'.code, consumed: 1};
			case 'n'.code: {char: '\n'.code, consumed: 1};
			case 'r'.code: {char: '\r'.code, consumed: 1};
			case 't'.code: {char: '\t'.code, consumed: 1};
			case '\''.code: {char: '\''.code, consumed: 1};
			case _: throw new haxe.Exception('invalid escape: \\${String.fromCharCode(esc)}');
		};
	}
}
