package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CommentRewrite;
import anyparse.query.RefactorSupport.EditResult;

using StringTools;

/**
 * Probe for `apq comment-rewrite` — text find/replace scoped to COMMENT bodies
 * (the write-twin of `lit`). Drives `CommentRewrite.rewrite` directly on
 * in-memory sources (pure, JS-native) with `reformat = true`. Covers literal
 * line / block edits, the body-only boundary (delimiters untouched), the
 * `--regex` `${N}` / `${N+K}` group template (the col-bump), the no-match
 * no-op, string-literal immunity, and the parse-breaking-replacement refusal.
 */
class CommentRewriteSliceTest extends Test {

	/** Literal replace inside a line comment. */
	public function testLiteralLineComment(): Void {
		final src: String = 'class C {\n\t// the old name here\n\tvar x = 1;\n}';
		final text: String = okText(cr(src, 'old', 'new', false));
		Assert.isTrue(text.contains('// the new name here'));
	}

	/** Literal replace inside a block comment. */
	public function testLiteralBlockComment(): Void {
		final src: String = 'class C {\n\t/* the old name */\n\tvar x = 1;\n}';
		final text: String = okText(cr(src, 'old', 'new', false));
		Assert.isTrue(text.contains('/* the new name */'));
	}

	/** Only the body changes — the opener and surrounding code are intact. */
	public function testBodyOnlyDelimitersUntouched(): Void {
		final src: String = 'class C {\n\t// keep // markers\n\tvar x = 1;\n}';
		final text: String = okText(cr(src, 'keep', 'drop', false));
		Assert.isTrue(text.contains('// drop // markers'));
		Assert.isTrue(text.contains('var x = 1;'));
	}

	/** `--regex` `$1` expands a capture group. */
	public function testRegexGroupExpand(): Void {
		final src: String = 'class C {\n\t// name=foo end\n\tvar x = 1;\n}';
		final text: String = okText(cr(src, 'name=(\\w+)', "[$1]", true));
		Assert.isTrue(text.contains('// [foo] end'));
	}

	/** `--regex` `${1+1}` shifts an integer group — the col-bump, all matches. */
	public function testRegexIntShiftAllMatches(): Void {
		final src: String = 'class C {\n\t// col 5 and col 9 here\n\tvar x = 1;\n}';
		final text: String = okText(cr(src, 'col (\\d+)', "col ${1+1}", true));
		Assert.isTrue(text.contains('// col 6 and col 10 here'));
	}

	/** No matching comment text → unchanged Ok (a no-op, not an error). */
	public function testNoMatchUnchanged(): Void {
		final src: String = 'class C {\n\t// nothing to see\n\tvar x = 1;\n}';
		final text: String = okText(cr(src, 'absent', 'X', false));
		Assert.equals(src, text);
	}

	/** A comment-opener inside a STRING literal is not a comment — left alone. */
	public function testStringLiteralImmune(): Void {
		final src: String = 'class C {\n\t// col 5 marker\n\tvar s = "col 5 in a string";\n}';
		final text: String = okText(cr(src, 'col 5', 'col 6', false));
		Assert.isTrue(text.contains('// col 6 marker'));
		Assert.isTrue(text.contains('"col 5 in a string"'));
	}

	/** A replacement that injects a block-comment closer breaks the parse → Err. */
	public function testParseBreakingReplacementRefused(): Void {
		final src: String = 'class C {\n\t/* x marks */\n\tvar y = 1;\n}';
		Assert.isTrue(isErr(cr(src, 'x marks', 'a */ b', false)));
	}

	/** A phrase split across two ` * ` doc lines is matched and replaced (cross-line literal). */
	public function testLiteralCrossLineDocComment(): Void {
		final src: String = 'class C {\n\t/**\n\t * the quick brown\n\t * fox jumps\n\t */\n\tpublic function f():Void {}\n}';
		final text: String = okText(cr(src, 'quick brown fox', 'NIMBLE BEAST', false));
		Assert.isTrue(text.contains('NIMBLE BEAST'));
		Assert.isFalse(text.contains('quick brown'));
		Assert.isFalse(text.contains('fox'));
	}

	/** A phrase contained WITHIN one line of a multi-line doc is replaced normally (no over-collapse). */
	public function testLiteralWithinOneDocLine(): Void {
		final src: String = 'class C {\n\t/**\n\t * the quick brown\n\t * fox jumps\n\t */\n\tpublic function f():Void {}\n}';
		final text: String = okText(cr(src, 'quick brown', 'slow red', false));
		Assert.isTrue(text.contains('slow red'));
		Assert.isFalse(text.contains('quick brown'));
		Assert.isTrue(text.contains('fox jumps'));
	}

	/** Cross-line literal match works with CRLF (`\r\n`) line endings, not only LF. */
	public function testLiteralCrossLineCrlf(): Void {
		final src: String = 'class C {\r\n\t/**\r\n\t * the quick brown\r\n\t * fox jumps\r\n\t */\r\n\tpublic function f():Void {}\r\n}';
		final text: String = okText(cr(src, 'quick brown fox', 'BF', false));
		Assert.isTrue(text.contains('BF'));
		Assert.isFalse(text.contains('quick brown'));
	}

	private function cr(src: String, find: String, replace: String, regex: Bool): EditResult {
		return CommentRewrite.rewrite(src, find, replace, regex, true, new HaxeQueryPlugin());
	}

	private function okText(res: EditResult): String {
		return switch res {
			case Ok(text): text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
	}

	private function isErr(res: EditResult): Bool {
		return switch res {
			case Ok(_): false;
			case Err(_): true;
		};
	}

}
