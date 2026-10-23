package anyparse.grammar.mermaid;

import anyparse.format.ArrayMatrixWrap;
import anyparse.format.ConditionalIndentationPolicy;
import anyparse.format.Encoding;
import anyparse.format.SameLinePolicy;
import anyparse.format.TrailingCommaPolicy;
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.TextFormat;
import anyparse.format.text.TrailingSepPolicy;
import anyparse.format.text.UnknownPolicy;
import haxe.Exception;

/**
 * The `TextFormat` of the Mermaid flowchart grammar (`MmdFlowchart`).
 *
 * Mermaid is line-oriented, and the generated `skipWs` skips line breaks like any other
 * whitespace, so the grammar never reads a line break: what a line break separates, the grammar
 * tells apart by the token that starts the next statement, and the few places where a line end
 * decides the parse (an anonymous `subgraph`, a subgraph title, a style-less `linkStyle` curve, a comment) assert it with a
 * lookahead inside their own terminal. A `%%` comment is a STATEMENT rather than trivia, so the
 * format declares no line comment: `%%{ … }%%` directives share its opener and must not be
 * skipped.
 *
 * Labels have no backslash escape; they decode and encode through `MermaidText`, named by each
 * label terminal's `@:decode` / `@:encode`, which is why `unescapeChar` refuses.
 */
@:nullSafety(Strict)
final class MermaidFormat implements TextFormat {

	public static final instance: MermaidFormat = new MermaidFormat();

	public var name(default, null): String = 'Mermaid flowchart';
	public var version(default, null): String = '11';
	public var encoding(default, null): Encoding = Encoding.UTF8;
	public var mappingOpen(default, null): String = '{';
	public var mappingClose(default, null): String = '}';
	public var sequenceOpen(default, null): Null<String> = null;
	public var sequenceClose(default, null): Null<String> = null;
	public var keyValueSep(default, null): String = ':';
	public var entrySep(default, null): String = ',';
	public var whitespace(default, null): String = ' \t\n\r';
	public var lineComment(default, null): Null<String> = null;
	public var blockComment(default, null): Null<BlockCommentDelims> = null;
	public var keySyntax(default, null): KeySyntax = KeySyntax.Unquoted;
	public var stringQuote(default, null): Array<String> = ['"'];
	public var fieldLookup(default, null): FieldLookup = FieldLookup.ByPosition;
	public var trailingSep(default, null): TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null): MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null): UnknownPolicy = UnknownPolicy.Error;
	public var intType(default, null): Null<String> = null;
	public var floatType(default, null): Null<String> = null;
	public var boolType(default, null): Null<String> = null;
	public var stringType(default, null): Null<String> = null;
	public var anyType(default, null): Null<String> = null;
	public var spacedLeads(default, null): Array<String> = [];

	/** A pipe label hugs its link (`-->|yes|`) and a subgraph title its id (`one[One]`). */
	public var tightLeads(default, null): Array<String> = ['|', '['];

	public var intLiteral(default, null): EReg = ~/^[0-9]+/;
	public var floatLiteral(default, null): EReg = ~/^[0-9]+(?:\.[0-9]+)?/;
	public var boolLiterals(default, null): Null<BoolLiterals> = null;
	public var nullLiteral(default, null): Null<String> = null;

	/** One statement per line, a subgraph body indented by four spaces. */
	public var defaultWriteOptions(default, null): MermaidWriteOptions = {
		indentChar: Space,
		indentSize: 4,
		tabWidth: 4,
		lineWidth: 120,
		lineEnd: '\n',
		finalNewline: true,
		trailingWhitespace: false,
		maxConsecutiveBlanks: 1,
		commentStyle: Verbatim,
		arrayMatrixWrap: ArrayMatrixWrap.NoMatrixWrap,
		trailingComma: TrailingCommaPolicy.Keep,
		conditionalPolicy: ConditionalIndentationPolicy.Aligned,
		alignInlineSwitchCaseBody: false,
		comprehensionCuddledOpen: false,
		soleItemCuddledBrackets: false,
		methodChainCuddledLinks: false,
		ternaryCuddledBraces: false,
		addLineCommentSpace: false,
		normalizeLineCommentIndent: false,
		compressSuccessiveParenthesis: false,
		statementBreak: SameLinePolicy.Next
	};

	private function new() {}

	public function escapeChar(c: Int): String {
		return MermaidText.escapeQuoted(c);
	}

	public function unescapeChar(input: String, pos: Int): UnescapeResult {
		throw new Exception('a Mermaid label has no backslash escape; it decodes through MermaidText');
	}

}
