package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.CommentRewrite;
import anyparse.query.RefactorSupport;
import unit.cli.CliFixture;
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

	/**
	 * A GUTTER-LESS block indents its interior one level DEEPER than its own delimiters, and the
	 * continuation answered with the DELIMITERS' indent — so every line the splice added landed one
	 * level short of the text it joined. `fmt --list` calls the result canonical (the writer re-emits
	 * a comment interior byte for byte) and the rule that reads continuation prefixes only knew the
	 * star-guttered spellings, so nothing in this project could see it.
	 */
	public function testMultilineReplacementKeepsGutterlessMemberIndent(): Void {
		final src: String = 'class C {\n\t/**\n\t\tA member doc line.\n\t\tSecond line.\n\t**/\n\tfunction f() {}\n}';
		final text: String = okText(cr(src, 'A member doc line.', 'A member doc line.\nAn added line.', false));
		Assert.isTrue(text.contains('\t/**\n\t\tA member doc line.\n\t\tAn added line.\n\t\tSecond line.\n\t**/'), text);
	}

	/**
	 * The same block at TYPE level, whose delimiters sit at column 0 — the shape whose added lines
	 * landed flush left, which is what a slice of this campaign actually committed.
	 */
	public function testMultilineReplacementKeepsGutterlessTypeIndent(): Void {
		final src: String = '/**\n\tA type doc line.\n\tSecond line.\n**/\nclass C {}';
		final text: String = okText(cr(src, 'A type doc line.', 'A type doc line.\nAn added line.', false));
		Assert.isTrue(text.contains('/**\n\tA type doc line.\n\tAn added line.\n\tSecond line.\n**/'), text);
	}

	/**
	 * Growing a ONE-LINE `/** X *\/` past one line has to open the block, or the closer rides the last
	 * content line — and the writer then re-bases that lone continuation onto the member indent,
	 * eating the space before its star and leaving `\t* text *\/` misaligned under the opener.
	 */
	public function testOneLineDocGrownToSeveralOpensTheBlock(): Void {
		final src: String = 'class C {\n\t/** One liner. */\n\tfunction f() {}\n}';
		final text: String = okText(cr(src, 'One liner.', 'First line.\nSecond line.', false));
		Assert.isTrue(text.contains('\t/**\n\t * First line.\n\t * Second line.\n\t */'), text);
	}

	/**
	 * An over-long replacement produced a comment line past the configured width that NOTHING
	 * measured — `fmt --list` clean, comment interiors verbatim, no rule reading doc line width.
	 * The op refuses instead, unless the block was already over-width (its style is not this op's
	 * to police) or the caller passes `--allow-wide`.
	 */
	public function testOverWideReplacementRefused(): Void {
		final src: String = 'class C {\n\t/**\n\t * A short line.\n\t */\n\tfunction f() {}\n}';
		final long: String = 'A rewritten sentence that runs on and on and on and on and on and on and on and on and on '
			+ 'and on and on and on and on and on and on and on and on and on and on past every plausible width.';
		Assert.isTrue(isErr(cr(src, 'A short line.', long, false)));
	}

	/**
	 * The width gate is waived by `--allow-wide`, so the op still reaches a line the caller means to
	 * leave long (a URL, a table row) without asking them to re-flow it.
	 *
	 * FALSE START, recorded because it is the trap this slice was told to look for in its own
	 * fixtures: the first version of this control asserted that a block ALREADY carrying an
	 * over-width line is exempt, so a second one may be added silently. That is a carve-out that
	 * leaks exactly where a project's docs are already sloppy — the gate subtracts the lines that
	 * were ALREADY over-width, not the blocks that hold them, and `testPreExistingWideLineNotRefused`
	 * is what pins that half.
	 */
	public function testOverWideReplacementAllowedWithFlag(): Void {
		final src: String = 'class C {\n\t/**\n\t * A short line.\n\t */\n\tfunction f() {}\n}';
		final long: String = 'A rewritten sentence that runs on and on and on and on and on and on and on and on and on '
			+ 'and on and on and on and on and on and on and on and on and on and on past every plausible width.';
		final res: EditResult = CommentRewrite.rewrite(src, 'A short line.', long, false, true, new HaxeQueryPlugin(), null, true);
		Assert.isTrue(okText(res).contains(long), okText(res));
	}

	/** An untouched over-width line elsewhere in the file is not the edit's doing — it does not refuse. */
	public function testPreExistingWideLineNotRefused(): Void {
		final wide: String = 'An existing line that already runs on and on and on and on and on and on and on and on and '
			+ 'on and on and on and on and on and on and on and on and on and on and on past every plausible width.';
		final src: String = 'class C {\n\t/**\n\t * $wide\n\t * A short line.\n\t */\n\tfunction f() {}\n}';
		final text: String = okText(cr(src, 'A short line.', 'A shorter one.', false));
		Assert.isTrue(text.contains('A shorter one.'), text);
	}

	/**
	 * EDITING an over-width line is allowed as long as it does not get wider — a typo fix inside a
	 * long doc line must not need `--allow-wide`.
	 *
	 * FOUND BY REVIEW, and it is why the gate compares COUNT and WIDEST rather than the set of line
	 * TEXTS. An edit necessarily changes the text of the line it edits, so under text identity every
	 * touched over-width line read as a newly gained one and the op refused a rename that SHORTENED a
	 * 155-column line to 154 — in exactly the case the gate's own doc promised to allow.
	 */
	public function testEditingAWideLineShorterNotRefused(): Void {
		final wide: String = 'An existing sentence that already runs on and on and on and on and on and on and on and on '
			+ 'and on and on and on and on and on and on and on and on and on and on past every plausible width.';
		final src: String = 'class C {\n\t/**\n\t * $wide\n\t */\n\tfunction f() {}\n}';
		final text: String = okText(cr(src, 'An existing sentence', 'An old sentence', false));
		Assert.isTrue(text.contains('An old sentence that already runs'), text);
	}

	/**
	 * A one-line doc that does NOT start its own line is re-opened too. A first draft required it to,
	 * and at column 0 the writer then ate the space before the continuation's star — `* Second line.
	 * *\/` — which is the very corruption the re-open exists to prevent, reached through the guard
	 * that was supposed to be the safe half of it.
	 */
	public function testTrailingOneLineDocGrownIsOpenedToo(): Void {
		final text: String = okText(cr('class C {} /** One liner. */\nclass D {}', 'One liner.', 'First line.\nSecond line.', false));
		Assert.isTrue(text.contains('/**\n * First line.\n * Second line.\n */'), text);
		Assert.isFalse(text.contains('* Second line. */'), text);
	}

	/**
	 * An EMPTY doc block has no interior line to read a continuation off, and the closer's own ` *\/`
	 * is not one — read as a gutter it answers with a bare space and the next splice lands there.
	 *
	 * HAND-ASSEMBLED against `commentContinuation` directly, after the mutation that drops the
	 * closer-skip killed nothing: no find can reach the body of a block that has no text in it, so
	 * no `comment-rewrite` fixture can exercise the clause at all.
	 */
	public function testEmptyDocBlockContinuationIsTheDocGutter(): Void {
		final src: String = 'class C {\n\t/**\n\t */\n\tfunction f() {}\n}';
		final tok: { from: Int, to: Int, isLine: Bool } = { from: src.indexOf('/**'), to: src.indexOf('*/') + 2, isLine: false };
		Assert.equals('\t * ', RefactorSupport.commentContinuation(src, tok));
	}

	/** The other closer spelling — an empty GUTTER-LESS block ends `**\/`, and it is skipped too. */
	public function testEmptyGutterlessBlockContinuationIsTheDocGutter(): Void {
		final src: String = 'class C {\n\t/**\n\t**/\n\tfunction f() {}\n}';
		final tok: { from: Int, to: Int, isLine: Bool } = { from: src.indexOf('/**'), to: src.indexOf('**/') + 3, isLine: false };
		Assert.equals('\t * ', RefactorSupport.commentContinuation(src, tok));
	}

	/**
	 * Making an ALREADY over-width line wider is still refused — otherwise the gate would let a long
	 * line grow without limit as long as no second one appeared, which is what a count-only
	 * comparison does (measured: dropping the `widest` half killed no fixture until this one).
	 */
	public function testWideningAnAlreadyWideLineRefused(): Void {
		final wide: String = 'An existing sentence that already runs on and on and on and on and on and on and on and on '
			+ 'and on and on and on and on and on and on and on and on and on and on past every plausible width.';
		final src: String = 'class C {\n\t/**\n\t * $wide\n\t */\n\tfunction f() {}\n}';
		Assert.isTrue(isErr(cr(src, 'An existing sentence', 'An existing and considerably longer sentence', false)));
	}

	/**
	 * A replacement whose FIRST line is empty leaves the BARE gutter, not a gutter and a trailing
	 * space. `reflowIntoComment` rtrims for the same reason; the re-open did not, and the writer
	 * re-emits a comment interior verbatim, so `fmt --list` calls trailing whitespace in one
	 * canonical while the project's own `hxformat.json` sets `indentation.trailingWhitespace: false`.
	 */
	public function testOneLineDocGrownWithEmptyFirstLineHasNoTrailingSpace(): Void {
		final src: String = 'class C {\n\t/** One liner. */\n\tfunction f() {}\n}';
		final text: String = okText(cr(src, 'One liner.', '\nSecond line.', false));
		Assert.isTrue(text.contains('\t/**\n\t *\n\t * Second line.\n\t */'), text);
	}

	/**
	 * The re-open derives the closer by chopping the continuation's `* `, so a continuation that does
	 * not end in one — a GUTTER-LESS block's bare indentation — would lose two characters of its own
	 * indentation and put the closer under the block. It is handed back untouched instead.
	 */
	public function testOpenGrownDocBlockLeavesAGutterlessContinuationAlone(): Void {
		Assert.equals('* A\n\t\tB', RefactorSupport.openGrownDocBlock('* A\n\t\tB', '\t\t'));
	}

	/**
	 * The width refusal names the line the EDIT added, not the file\'s widest. The decision is still
	 * the aggregate - how many over-width comment lines there are and how wide the widest is, against
	 * the same source canonicalised but unedited - so a file that already holds a wider line is not
	 * refused for holding it. What changed is WHICH line the message quotes.
	 *
	 * At the base commit this refusal read `at 253 columns` and quoted a doc line the replacement
	 * never touched, in a file whose only fault was owning it. That is how the guard blocked S45 on
	 * two files and read as broken.
	 */
	public function testWidthRefusalNamesTheLineTheEditAdded(): Void {
		final untouched: String = ''.rpad('w', 250);
		final grown: String = ''.rpad('g', 180);
		final src: String = '/**\n * $untouched\n * padme\n */\nclass C {}';
		final message: String = errText(cr(src, 'padme', grown, false));
		Assert.isTrue(message.contains(grown), 'the refusal quotes the line the replacement wrote: $message');
		Assert.isFalse(message.contains(untouched), 'and not the wider one it never touched: $message');
		Assert.isTrue(message.contains('at 183 columns'), 'with that line\'s own width: $message');
	}

	/** The same file, edited so nothing new crosses the width: the pre-existing 250-column line refuses nothing. */
	public function testPreExistingWideLineAloneDoesNotRefuse(): Void {
		final untouched: String = ''.rpad('w', 250);
		final src: String = '/**\n * $untouched\n * padme\n */\nclass C {}';
		Assert.isTrue(okText(cr(src, 'padme', 'short', false)).contains('short'));
	}

	/**
	 * The single-file default is a PREVIEW, and the preview arm did not count what it printed. So
	 * every `apq comment-rewrite <find> <replace> <one file>` wrote the rewritten source to stdout and
	 * then said on stderr that no comment body in the file contained the find text - a false negative
	 * on the op\'s own diagnostic, in the shape a user reaches for first.
	 *
	 * Both halves in one test, so neither passes alone: a find that MATCHES must not say it did not,
	 * and a find that does not match must still say so - that line exists because `rewrote 0 file(s)`
	 * used to read as "the text was already right".
	 */
	public function testPreviewCountsWhatItPrinted(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('crprev', [{ name: 'C.hx', source: '/**\n * Alpha beta gamma.\n */\nclass C {}\n' }]);
		final path: String = '$dir/C.hx';
		final hit: String = CliFixture.captureStderr(() -> Assert.equals(0, Cli.run(['comment-rewrite', 'beta', 'BETA', path])));
		Assert.equals(-1, hit.indexOf('contains the find text'), 'a matching preview does not claim it matched nothing: $hit');
		final miss: String = CliFixture.captureStderr(() -> Assert.equals(0, Cli.run(['comment-rewrite', 'zqxwv', 'BETA', path])));
		Assert.isTrue(miss.indexOf('contains the find text') != -1, 'a real miss still says so: $miss');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stderr capture needs the node target');
		#end
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

	/** The `Err` message of `res`, or a failure when it was `Ok`. */
	private function errText(res: EditResult): String {
		return switch res {
			case Ok(text):
				Assert.fail('expected Err, got Ok: $text');
				'';
			case Err(message): message;
		};
	}

}
