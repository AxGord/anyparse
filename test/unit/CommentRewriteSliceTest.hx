package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CommentRewrite;
import anyparse.query.RefactorSupport.EditResult;
import utest.Assert;
import utest.Test;

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

	/**
	 * A multi-line LITERAL find, written with the ` * ` continuation prefixes the source carries.
	 *
	 * Matching runs against a body whose line breaks — and those prefixes — are collapsed to one
	 * space, and the find is normalised the same way, so both spellings of a multi-line find work.
	 * Before that they BOTH failed and the CLI said "rewrote 0 file(s)", which reads as "the text
	 * was already right".
	 */
	public function testLiteralMultilineFindWithPrefixes(): Void {
		final src: String = '/**\n * First line.\n * Second line.\n */\nclass C {}';
		final text: String = okText(cr(src, 'First line.\n * Second line.', 'One line.', false));
		Assert.isTrue(text.contains('One line.'), text);
		Assert.isFalse(text.contains('Second line.'), text);
	}

	/** The same find written WITHOUT the prefixes — a plain newline between the two lines. */
	public function testLiteralMultilineFindWithoutPrefixes(): Void {
		final src: String = '/**\n * First line.\n * Second line.\n */\nclass C {}';
		final text: String = okText(cr(src, 'First line.\nSecond line.', 'One line.', false));
		Assert.isTrue(text.contains('One line.'), text);
	}

	/** A `--regex` find still sees the RAW body, prefixes and newline included. */
	public function testRegexSeesRawBodyAcrossLines(): Void {
		final src: String = '/**\n * First line.\n * Second line.\n */\nclass C {}';
		final text: String = okText(cr(src, 'First line\\.\\s+\\*\\s+Second', 'Merged', true));
		Assert.isTrue(text.contains('Merged line.'), text);
	}

	/**
	 * A replacement carrying a real NEWLINE gets the block's own ` * ` continuation on every
	 * line it adds. Spliced raw it produced a line with no gutter at all, and the writer then
	 * re-based the whole run onto that shallowest line — so ONE bad line pushed its guttered
	 * siblings one level deeper, `fmt --list` still called the file canonical, and no lint rule
	 * read a continuation prefix. The assertion spans BOTH halves of the splice in one string,
	 * so it cannot pass on an untransformed input.
	 */
	public function testMultilineReplacementKeepsMemberGutter(): Void {
		final src: String = 'class C {\n\t/**\n\t * A member doc whose text wraps over\n\t * two lines.\n\t */\n\tfunction f() {}\n}';
		final text: String = okText(cr(src, 'A member doc whose text', 'A member doc\nsplit here whose text', false));
		Assert.isTrue(text.contains('\t/**\n\t * A member doc\n\t * split here whose text wraps over\n\t * two lines.\n\t */'), text);
	}

	/** The same at a TYPE-level block, whose continuation is ` * ` and not `\t * `. */
	public function testMultilineReplacementKeepsTypeGutter(): Void {
		final src: String = '/**\n * First sentence.\n */\nclass C {}';
		final text: String = okText(cr(src, 'First sentence.', 'First sentence.\nAn added line.', false));
		Assert.isTrue(text.contains('/**\n * First sentence.\n * An added line.\n */'), text);
	}

	/** A blank line in the replacement becomes the block's bare gutter, not trailing whitespace. */
	public function testBlankReplacementLineBecomesBareGutter(): Void {
		final src: String = '/**\n * First sentence.\n */\nclass C {}';
		final text: String = okText(cr(src, 'First sentence.', 'First sentence.\n\nA new paragraph.', false));
		Assert.isTrue(text.contains('/**\n * First sentence.\n *\n * A new paragraph.\n */'), text);
	}

	/**
	 * A caller who writes the gutter themselves is not doubled — the op strips it before adding
	 * its own. GREEN AT BASE BY CONSTRUCTION, and measured so: the raw splice put ` * An added
	 * line.` at column 0, which made it the shallowest line of the run, and the writer re-based
	 * the whole block onto the member indent — the one caller-written shape the old splice
	 * survived. Its value is that the strip does not break it, proved by mutation: with
	 * `RefactorSupport.ungutter` returned to the identity the reflow prepends a second gutter and
	 * this test is the one that flips.
	 */
	public function testCallerSuppliedGutterIsNotDoubled(): Void {
		final src: String = 'class C {\n\t/**\n\t * First sentence.\n\t */\n\tfunction f() {}\n}';
		final text: String = okText(cr(src, 'First sentence.', 'First sentence.\n * An added line.', false));
		Assert.isTrue(text.contains('\t/**\n\t * First sentence.\n\t * An added line.\n\t */'), text);
		Assert.isFalse(text.contains('* * An added line'), text);
	}

	/** A LINE comment continues with `//`, not with a star gutter. */
	public function testMultilineReplacementInLineComment(): Void {
		final src: String = 'class C {\n\t// one note\n\tvar x = 1;\n}';
		final text: String = okText(cr(src, 'one note', 'one note\nand a second', false));
		Assert.isTrue(text.contains('\t// one note\n\t// and a second'), text);
	}

	/** A `--regex` replacement is re-prefixed too — the splice is just as raw on that path. */
	public function testRegexMultilineReplacementKeepsGutter(): Void {
		final src: String = '/**\n * First sentence.\n */\nclass C {}';
		final text: String = okText(cr(src, 'First (sentence)\\.', 'First $1.\nSecond line.', true));
		Assert.isTrue(text.contains('/**\n * First sentence.\n * Second line.\n */'), text);
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
