package unit.minilex;

import anyparse.format.ArrayMatrixWrap;
import anyparse.format.ConditionalIndentationPolicy;
import anyparse.format.Encoding;
import anyparse.format.TrailingCommaPolicy;
import anyparse.format.WriteOptions;
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.TextFormat.BlockCommentDelims;
import anyparse.format.text.UnknownPolicy;

/**
 * A second grammar's format, declaring delimiters that share NOT ONE BYTE with Haxe's:
 * `#` opens a line comment, `<# … #>` a block one, `@ … @` a string.
 *
 * It exists so the generated lexical pass can be asked the question no Haxe-only pin can:
 * does `Build.buildLexicalScan` READ these declarations, or does the macro know what a
 * comment looks like? The `MiniLexScan` built from it must find `#` and must NOT find `//`.
 */
@:nullSafety(Strict)
final class MiniLexFormat {

	public static final instance: MiniLexFormat = new MiniLexFormat();

	public var name(default, null): String = 'MiniLex';
	public var version(default, null): String = '1.0';
	public var encoding(default, null): Encoding = Encoding.UTF8;
	public var whitespace(default, null): String = ' \t\n\r';
	public var lineComment(default, null): Null<String> = '#';
	public var blockComment(default, null): Null<BlockCommentDelims> = { open: '<#', close: '#>' };
	public var mappingOpen(default, null): String = '(';
	public var mappingClose(default, null): String = ')';
	public var sequenceOpen(default, null): Null<String> = '[';
	public var sequenceClose(default, null): Null<String> = ']';
	public var keyValueSep(default, null): String = ':';
	public var entrySep(default, null): String = ',';
	public var stringQuote(default, null): Array<String> = ['@'];
	public var keySyntax(default, null): KeySyntax = KeySyntax.Unquoted;
	public var fieldLookup(default, null): FieldLookup = FieldLookup.ByName;
	public var onMissing(default, null): MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null): UnknownPolicy = UnknownPolicy.Skip;
	public var defaultWriteOptions(default, null): WriteOptions = {
		indentChar: Tab,
		indentSize: 1,
		tabWidth: 4,
		lineWidth: 80,
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

	private function new() {}

	/** Identity passthrough — `MiniLex` has no escapes the writer must re-emit. */
	public inline function escapeChar(c: Int): String {
		return String.fromCharCode(c);
	}

}
