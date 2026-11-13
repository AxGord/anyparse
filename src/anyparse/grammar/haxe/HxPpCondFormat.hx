package anyparse.grammar.haxe;

import anyparse.format.Encoding;
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.TextFormat;
import anyparse.format.text.TrailingSepPolicy;
import anyparse.format.text.UnknownPolicy;

using StringTools;

/**
 * The blank a Haxe preprocessor condition admits between two tokens, declared once for `HxCondValue`: spaces, tabs and
 * line breaks, and `/* *\/` block comments. A `//` comment is not one — the compiler refuses `#if (a // c` followed by
 * `|| b` on the next line — so `lineComment` is null and a condition holding one is not read.
 *
 * Carries only what the macro pipeline reads of a schema; the JSON-shaped fields are inert placeholders, as in
 * `CFamilyCommentFormat`.
 */
@:nullSafety(Strict)
final class HxPpCondFormat implements TextFormat {

	public static final instance: HxPpCondFormat = new HxPpCondFormat();

	public var name(default, null): String = 'HaxePpCond';
	public var version(default, null): String = '1.0';
	public var encoding(default, null): Encoding = Encoding.UTF8;
	public var mappingOpen(default, null): String = '';
	public var mappingClose(default, null): String = '';
	public var sequenceOpen(default, null): Null<String> = null;
	public var sequenceClose(default, null): Null<String> = null;
	public var keyValueSep(default, null): String = '';
	public var entrySep(default, null): String = '';
	public var whitespace(default, null): String = ' \t\n\r';
	public var lineComment(default, null): Null<String> = null;
	public var blockComment(default, null): Null<BlockCommentDelims> = { open: '/*', close: '*/', doc: '/**' };
	public var keySyntax(default, null): KeySyntax = KeySyntax.Unquoted;
	public var stringQuote(default, null): Array<String> = [];
	public var fieldLookup(default, null): FieldLookup = FieldLookup.ByName;
	public var trailingSep(default, null): TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null): MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null): UnknownPolicy = UnknownPolicy.Error;
	public var spacedLeads(default, null): Array<String> = [];
	public var tightLeads(default, null): Array<String> = [];
	public var intLiteral(default, null): EReg = ~/^/;
	public var floatLiteral(default, null): EReg = ~/^/;
	public var boolLiterals(default, null): Null<BoolLiterals> = null;
	public var nullLiteral(default, null): Null<String> = null;
	public var defaultWriteOptions(default, null): HxModuleWriteOptions = new HxModuleWriteOptions();

	private function new() {}

	public function escapeChar(c: Int): String return String.fromCharCode(c);

	public function unescapeChar(input: String, pos: Int): UnescapeResult {
		return { char: input.fastCodeAt(pos), consumed: 1 };
	}

}
