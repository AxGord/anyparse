package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * omega-fnsig-boundary: a function signature whose flat width lands EXACTLY one
 * column past maxLineLength must wrap (fillLineWithLeadingBreak), matching the
 * haxe-formatter fork. The body's opening `{` is the head of a `BodyGroup` that
 * every static width measure defers to width 0, so the flat width used for the
 * `functionSignature` exceedsMaxLineLength wrap decision came up one column
 * short: a 141-column signature measured as 140 and stayed hugged (over the
 * limit) instead of opening. The `{` must count toward the signature line width.
 * Guard: a signature at EXACTLY the limit (140) stays on one line. Identifiers
 * are synthetic and bear no relation to any downstream code.
 */
@:nullSafety(Strict)
final class HxFnSigExceedsBoundaryWrapTest extends Test {

	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "functionSignature": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 100}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	/** A two-param signature whose flat width is 141 (one column over 140) OPENS: leading break after `(`, params packed, `)` + return on their own line. */
	public function testOneColumnOverBoundaryWrapsSignature(): Void {
		final src: String = 'class M {\n\tprivate static function mergeCoachUsers(a:Array<FileListShareCoachUser>, b:Array<FileListShareCoachUser>):Array<FileListShareCoachUser> {\n\t\treturn a;\n\t}\n}';
		final expected: String = 'class M {\n\tprivate static function mergeCoachUsers(\n\t\ta:Array<FileListShareCoachUser>, b:Array<FileListShareCoachUser>\n\t):Array<FileListShareCoachUser> {\n\t\treturn a;\n\t}\n}';
		Assert.equals(expected, triviaWrite(src));
	}

	/** GUARD: a signature whose flat width is EXACTLY 140 (at the limit, not over) stays hugged on one line. */
	public function testAtBoundaryStaysUnwrapped(): Void {
		final src: String = 'class M {\n\tprivate static function mergeCoachUser(a:Array<FileListShareCoachUser>, b:Array<FileListShareCoachUser>):Array<FileListShareCoachUser> {\n\t\treturn a;\n\t}\n}';
		Assert.equals('class M {\n\tprivate static function mergeCoachUser(a:Array<FileListShareCoachUser>, b:Array<FileListShareCoachUser>):Array<FileListShareCoachUser> {\n\t\treturn a;\n\t}\n}', triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CFG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
