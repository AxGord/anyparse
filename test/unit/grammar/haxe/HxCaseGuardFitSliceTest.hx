package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * Case-guard condition wrapping must not count the case BODY when
 * deciding whether the `case P if (cond):` label fits, and a genuinely
 * overlong guard must keep ladder lines indented.
 *
 * Repro from TM `DropDownList.hx` (2026-08-11): a guard label of 117
 * visible columns (maxLineLength 140) was torn open because the writer
 * measured label PLUS the glued one-line body (170 cols) even though the
 * `caseBody: fitLine` policy then dropped the body to its own line
 * anyway. Flip threshold measured at exactly label+space+body = 141.
 *
 * Second defect on the SAME path: when the guard condition genuinely
 * overflows, the ladder emits the first operand line and the closing
 * `)` at column 0 (zero indent) instead of the case-label indent.
 */
@:nullSafety(Strict)
final class HxCaseGuardFitSliceTest extends Test {

	/** The TM-mirror config every fixture formats under. */
	private static final CONFIG: String =
		'{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}}';

	/**
	 * Label = 117 cols at 3 tabs; body = 52 cols. Label fits alone,
	 * label+glued body would be 170 > 140 — the body must drop, the
	 * label must stay ONE line.
	 */
	public function testGuardLabelFitDoesNotCountBody(): Void {
		final src: String = 'class M {\n\tfunction f(keyCode:Int):Void {\n\t\tswitch keyCode {\n'
			+ '\t\t\tcase 1:\n\t\t\t\tfoo();\n\t\t\t\tbar();\n'
			+ '\t\t\tcase _ if ((keyCode >= \'0\'.code && keyCode <= \'9\'.code) || (keyCode >= \'A\'.code && keyCode <= \'Z\'.code)):\n'
			+ '\t\t\t\tselectItemByFirstChar(String.fromCharCode(keyCode));\n\t\t}\n\t}\n}\n';
		final out: String = write(src, CONFIG);
		Assert.isTrue(
			out.indexOf('case _ if ((keyCode >= \'0\'.code && keyCode <= \'9\'.code) || (keyCode >= \'A\'.code && keyCode <= \'Z\'.code)):')
				!= -1,
			'a guard label that fits must stay on one line regardless of body width: <$out>'
		);
	}

	/**
	 * The already-broken source shape of the same guard must be REJOINED
	 * (fitLine is a width decision, not a source-shape one).
	 */
	public function testGuardRejoinsSourceBrokenLabelThatFits(): Void {
		final src: String = 'class M {\n\tfunction f(keyCode:Int):Void {\n\t\tswitch keyCode {\n\t\t\tcase 1:\n\t\t\t\tfoo();\n'
			+ '\t\t\t\tbar();\n\t\t\tcase _ if ((\n\t\t\t\tkeyCode >= \'0\'.code && keyCode <= \'9\'.code\n'
			+ '\t\t\t) || (keyCode >= \'A\'.code && keyCode <= \'Z\'.code)):\n'
			+ '\t\t\t\tselectItemByFirstChar(String.fromCharCode(keyCode));\n\t\t}\n\t}\n}\n';
		final out: String = write(src, CONFIG);
		Assert.isTrue(
			out.indexOf('case _ if ((keyCode >= \'0\'.code && keyCode <= \'9\'.code) || (keyCode >= \'A\'.code && keyCode <= \'Z\'.code)):')
				!= -1,
			'a source-broken guard label that fits must rejoin to one line: <$out>'
		);
	}

	/**
	 * A guard whose label alone is 149 cols must break — but every
	 * produced line must carry indentation (the unfixed ladder emitted
	 * the first operand and the closing paren at column 0).
	 */
	public function testOverflowGuardLadderKeepsIndent(): Void {
		final src: String = 'class M {\n\tfunction f(keyCodeVariable:Int):Void {\n\t\tswitch keyCodeVariable {\n\t\t\tcase 1:\n'
			+ '\t\t\t\tfoo();\n\t\t\t\tbar();\n' + '\t\t\tcase _ if ((keyCodeVariable >= \'0\'.code && keyCodeVariable <= \'9\'.code) || ('
			+ 'keyCodeVariable >= \'A\'.code && keyCodeVariable <= \'Z\'.code)):\n\t\t\t\ttrace(2);\n\t\t}\n\t}\n}\n';
		final out: String = write(src, CONFIG);
		for (line in out.split('\n')) if (line.length != 0)
			Assert.isTrue(
				StringTools.startsWith(line, '\t') || StringTools.startsWith(line, 'class') || StringTools.startsWith(line, '}'),
				'no produced line may sit at column 0 except class braces, got <$line> in <$out>'
			);
	}

	private inline function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
