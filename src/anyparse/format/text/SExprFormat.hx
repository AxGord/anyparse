package anyparse.format.text;

import anyparse.format.ArrayMatrixWrap;
import anyparse.format.Encoding;
import anyparse.format.WriteOptions;
import anyparse.format.text.TextFormat.BlockCommentDelims;
import anyparse.format.text.TextFormat.BoolLiterals;
import anyparse.format.text.TextFormat.UnescapeResult;

/**
 * Reference `TextFormat` for S-expressions.
 *
 * Minimal Lisp-style atom-and-list syntax: bare atoms separated by
 * whitespace, lists wrapped in parens, strings double-quoted with
 * backslash escapes. Used by `apq ast` as the default (non-JSON)
 * output. The library never acquires a built-in "S-expr" concept — this
 * file is the entire vocabulary; users wanting a dialect (R7RS reader,
 * lispy DSL, etc.) clone or subclass.
 *
 * Writer-driven slice — the parser-side regex on `SAtomLit` /
 * `SQuotedStringLit` exists only so the macro pipeline's ShapeBuilder
 * accepts the grammar; `Build.buildParser` is not invoked on `SValue`.
 *
 * Singleton: one shared instance, format is pure configuration.
 */
@:nullSafety(Strict)
final class SExprFormat implements TextFormat {

	public static final instance: SExprFormat = new SExprFormat();

	public var name(default, null): String = 'S-expression';
	public var version(default, null): String = '1.0';
	public var encoding(default, null): Encoding = Encoding.UTF8;
	public var mappingOpen(default, null): String = '(';
	public var mappingClose(default, null): String = ')';
	public var sequenceOpen(default, null): Null<String> = '(';
	public var sequenceClose(default, null): Null<String> = ')';
	public var keyValueSep(default, null): String = ' ';
	public var entrySep(default, null): String = ' ';
	public var whitespace(default, null): String = ' \t\n\r';
	public var lineComment(default, null): Null<String> = ';';
	public var blockComment(default, null): Null<BlockCommentDelims> = null;
	public var keySyntax(default, null): KeySyntax = KeySyntax.Unquoted;
	public var stringQuote(default, null): Array<String> = ['"'];
	public var fieldLookup(default, null): FieldLookup = FieldLookup.ByPosition;
	public var trailingSep(default, null): TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null): MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null): UnknownPolicy = UnknownPolicy.Skip;
	public var intType(default, null): Null<String> = null;
	public var floatType(default, null): Null<String> = null;
	public var boolType(default, null): Null<String> = null;
	public var stringType(default, null): Null<String> = null;
	public var anyType(default, null): Null<String> = null;
	public var spacedLeads(default, null): Array<String> = [];
	public var tightLeads(default, null): Array<String> = [];
	public var intLiteral(default, null): EReg = ~/^-?(?:0|[1-9][0-9]*)/;
	public var floatLiteral(default, null): EReg = ~/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/;
	public var boolLiterals(default, null): Null<BoolLiterals> = null;
	public var nullLiteral(default, null): Null<String> = null;

	/**
	 * Default `WriteOptions` for S-expr output: 2-space indent (Lisp
	 * convention), no trailing newline. The `apq ast` text path appends
	 * its own terminator.
	 */
	public var defaultWriteOptions(default, null): WriteOptions = {
		indentChar: Space,
		indentSize: 2,
		tabWidth: 2,
		lineWidth: 100,
		lineEnd: '\n',
		finalNewline: false,
		trailingWhitespace: false,
		maxConsecutiveBlanks: -1,
		commentStyle: Verbatim,
		arrayMatrixWrap: ArrayMatrixWrap.NoMatrixWrap,
		conditionalPolicy: ConditionalIndentationPolicy.Aligned,
		alignInlineSwitchCaseBody: false,
		addLineCommentSpace: true,
		compressSuccessiveParenthesis: true,
	};

	private function new() {}

	public function escapeChar(c: Int): String {
		return switch c {
			case '"'.code: '\\"';
			case '\\'.code: '\\\\';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case '\t'.code: '\\t';
			case _:
				if (c < ' '.code)
					'\\u' + StringTools.hex(c, 4);
				else
					String.fromCharCode(c);
		};
	}

	public function unescapeChar(input: String, pos: Int): UnescapeResult {
		final esc: Null<Int> = input.charCodeAt(pos);
		if (esc == null) throw new haxe.Exception('unterminated escape at $pos');
		return switch esc {
			case '"'.code: { char: '"'.code, consumed: 1 };
			case '\\'.code: { char: '\\'.code, consumed: 1 };
			case 'n'.code: { char: '\n'.code, consumed: 1 };
			case 'r'.code: { char: '\r'.code, consumed: 1 };
			case 't'.code: { char: '\t'.code, consumed: 1 };
			case _:
				throw new haxe.Exception('invalid escape: \\${String.fromCharCode(esc)}');
		};
	}

}
