package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * FU12 `comments.trailingCommentOverflow: "above"`: a same-line `//` comment that ALONE carries its line past
 * `wrapping.maxLineLength` moves onto its own line above the statement or member it trails, at that element's
 * indent, and the code is laid out as if the comment were not there.
 *
 * The positive list the knob acts on, each pinned below: an element of a statement block (a function body, a
 * nested `{ }`, a lambda body) or of a type's member list; a `//` comment that is not a directive; an element
 * with no leading comment of its own; code that, alone, renders as ONE line that fits. Everything else - a
 * case body, a block comment, a directive, code that wraps or overflows on its own - keeps the pre-knob layout
 * byte for byte. Object fields and call arguments: `HxTrailingCommentOverflowListSliceTest`.
 *
 * Every moved form is pinned as a fixed point: re-read, the comment is the element's leading comment and nothing
 * is left to decide. The fixtures are 60 columns wide at tab 4, so a line's width can be checked by eye.
 */
@:nullSafety(Strict)
final class HxTrailingCommentOverflowSliceTest extends Test {

	private static final BASE: String =
		'"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 60}, "sameLine": {"ifBody": "fitLine"}';
	private static final CONFIG_ON: String = '{$BASE, "comments": {"trailingCommentOverflow": "above"}}';
	private static final CONFIG_OFF: String = '{$BASE}';
	private static final CONFIG_KEEP: String = '{$BASE, "comments": {"trailingCommentOverflow": "keep"}}';
	private static final CONFIG_COLLAPSE_ON: String =
		'{$BASE, "emptyLines": {"uniformStatementBlanks": "collapse"}, "comments": {"trailingCommentOverflow": "above"}}';
	private static final STMT_SRC: String =
		'class C {\n\tfunction f() {\n\t\tfinal value:Int = compute(alpha, beta); // explains the computation\n\t}\n}';
	private static final STMT_ABOVE: String =
		'class C {\n\tfunction f() {\n\t\t// explains the computation\n\t\tfinal value:Int = compute(alpha, beta);\n\t}\n}';
	private static final MEMBER_SRC: String = 'class C {\n\tvar counter:Int = 0; // a member comment long enough to overflow it\n}';
	private static final MEMBER_ABOVE: String = 'class C {\n\t// a member comment long enough to overflow it\n\tvar counter:Int = 0;\n}';

	/** The knob-off canonical form: the comment is what pushed the bare body below the `if`. */
	private static final GLUED_SRC: String =
		'class C {\n\tfunction f() {\n\t\tif (ready)\n\t\t\tgo(); // a comment on the glued body that overflows it\n\t}\n}';

	private static final GLUED_ABOVE: String =
		'class C {\n\tfunction f() {\n\t\t// a comment on the glued body that overflows it\n\t\tif (ready) go();\n\t}\n}';
	private static final BLANK_SRC: String =
		'class C {\n\tfunction f() {\n\t\tfirst();\n\n\t\trun(alphaArgument, betaArgument); // a note that is long enough\n\t}\n}';
	private static final BLANK_ABOVE: String =
		'class C {\n\tfunction f() {\n\t\tfirst();\n\n\t\t// a note that is long enough\n\t\trun(alphaArgument, betaArgument);\n\t}\n}';
	private static final NESTED_SRC: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tb();\n'
		+ '\t\t\tc(); // a nested block comment long enough to overflow\n\t\t}\n\t}\n}';
	private static final NESTED_ABOVE: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tb();\n'
		+ '\t\t\t// a nested block comment long enough to overflow\n\t\t\tc();\n\t\t}\n\t}\n}';
	private static final LAMBDA_SRC: String = 'class C {\n\tfunction f() {\n\t\trun(() -> {\n\t\t\tstep();\n'
		+ '\t\t\tnext(); // a lambda body comment that is long enough\n\t\t});\n\t}\n}';
	private static final LAMBDA_ABOVE: String = 'class C {\n\tfunction f() {\n\t\trun(() -> {\n\t\t\tstep();\n'
		+ '\t\t\t// a lambda body comment that is long enough\n\t\t\tnext();\n\t\t});\n\t}\n}';
	private static final COLLAPSE_SRC: String =
		'class C {\n\tfunction g() {\n\t\tone();\n\n\t\ttwo(); // a note long enough to overflow the sixty columns\n\t}\n}';
	private static final COLLAPSE_ABOVE: String =
		'class C {\n\tfunction g() {\n\t\tone();\n\t\t// a note long enough to overflow the sixty columns\n\t\ttwo();\n\t}\n}';

	/** Every comment here keeps its place under the knob: each line names the reason. */
	private static final STAYS_SRC: String = 'class C {\n\tfunction f() {\n\t\tcall(first); // fits on the line\n'
		+ '\t\tother(); // noqa: some-rule and more text so that it overflows\n\t\tthird(); // CHECKSTYLE:OFF and more text so that it '
		+ 'overflows the line\n\t\tfourth(); /* a block comment that is long enough to overflow it */\n\t\t// already led by a comment\n'
		+ '\t\tfifth(alpha); // and a trailing one that is long enough to overflow\n'
		+ '\t\tswitch x {\n\t\t\tcase 1:\n\t\t\t\tsixth(); // a case body comment that is long enough to '
		+ 'overflow\n\t\t}\n\t\tfinal wideIdentifierName:String = anotherIdentifierName; // c\n\t}\n}';

	/** Code that spans lines on its own: the comment trails its last line, as before. */
	private static final MULTI_LINE_SRC: String = 'class C {\n\tfunction f() {\n\t\tcall(alphaArgumentNumberOne,\n'
		+ '\t\t\tbetaArgumentNumberTwo,\n\t\t\tgammaArgument); // trailing comment that is long\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** The reported shape: a statement whose code fits and whose comment carries it past the width. */
	@:pin('control')
	@:killer('M-TCO-KNOB-IGNORED')
	public function testOverflowingStatementCommentMovesAbove(): Void {
		Assert.equals(STMT_ABOVE, on(STMT_SRC));
		Assert.equals(STMT_SRC, off(STMT_SRC));
	}

	/** A member of a type body: the member list opts in like a statement block. */
	public function testOverflowingMemberCommentMovesAbove(): Void {
		Assert.equals(MEMBER_ABOVE, on(MEMBER_SRC));
		Assert.equals(MEMBER_SRC, off(MEMBER_SRC));
	}

	/**
	 * The comment used to decide the CODE's layout: it pushed a glued `if` body onto its own line. Moved above,
	 * the code is laid out as if it were not there.
	 */
	public function testCodeLaidOutForTheCommentRegluesOnceItMoves(): Void {
		Assert.equals(GLUED_ABOVE, on(GLUED_SRC));
		Assert.equals(GLUED_SRC, off(GLUED_SRC));
	}

	/** A nested `{ }` statement block and a lambda body are statement blocks too. */
	public function testNestedAndLambdaBlocksMoveTheirComments(): Void {
		Assert.equals(NESTED_ABOVE, on(NESTED_SRC));
		Assert.equals(LAMBDA_ABOVE, on(LAMBDA_SRC));
	}

	/** A blank line before the element stays before the moved comment, which sits right above its code. */
	public function testBlankLineBeforeTheElementStaysAboveTheComment(): Void {
		Assert.equals(BLANK_ABOVE, on(BLANK_SRC));
	}

	/**
	 * `uniformStatementBlanks: collapse` deletes every blank of a uniformly blank block; the comment moves in the
	 * SAME pass. A gate on the collapse made the second pass move it instead (the writer then needed two rewrites).
	 */
	public function testUniformCollapseAndTheMoveLandInOnePass(): Void {
		Assert.equals(COLLAPSE_ABOVE, write(COLLAPSE_SRC, CONFIG_COLLAPSE_ON));
		Assert.equals(COLLAPSE_ABOVE, write(COLLAPSE_ABOVE, CONFIG_COLLAPSE_ON));
	}

	/**
	 * Outside the positive list nothing moves: a comment that fits, a `noqa` or `CHECKSTYLE` directive, a block
	 * comment, an element that already has a leading comment, a case body, and code that is too wide without its
	 * comment.
	 */
	@:pin('control')
	@:killer('M-TCO-DIRECTIVE-MOVED')
	@:killer('M-TCO-LEADING-IGNORED')
	@:killer('M-TCO-OVERWIDE-CODE-MOVED')
	public function testEverythingOutsideThePositiveListStays(): Void {
		Assert.equals(STAYS_SRC, on(STAYS_SRC));
		Assert.equals(STAYS_SRC, off(STAYS_SRC));
	}

	/**
	 * Code that spans lines alone keeps the comment on its last line, even where its FIRST line plus the
	 * comment would overflow: the question is whether the code is one line, not how wide its first line is.
	 */
	@:pin('control')
	@:killer('M-TCO-MULTILINE-MOVED')
	public function testMultiLineCodeKeepsItsComment(): Void {
		Assert.equals(MULTI_LINE_SRC, on(MULTI_LINE_SRC));
	}

	/** A line exactly at the width fits, so the comment stays; one column more and it moves. */
	@:pin('control')
	@:killer('M-TCO-BOUNDARY')
	public function testTheWidthBoundaryIsInclusive(): Void {
		final atWidth: String = stmt('x();', '// ' + rep('w', 60 - 16));
		final pastWidth: String = stmt('x();', '// ' + rep('w', 61 - 16));
		Assert.equals(atWidth, on(atWidth));
		Assert.equals(above('x();', '// ' + rep('w', 61 - 16)), on(pastWidth));
	}

	/** Code exactly at the width alone still fits, so its comment moves; one column more and the code does not. */
	@:pin('control')
	@:killer('M-TCO-OVERWIDE-CODE-MOVED')
	public function testCodeAtTheWidthStillCounts(): Void {
		final fits: String = rep('a', 60 - 11) + '();';
		final over: String = rep('a', 61 - 11) + '();';
		Assert.equals(above(fits, '// trailing'), on(stmt(fits, '// trailing')));
		Assert.equals(stmt(over, '// trailing'), on(stmt(over, '// trailing')));
	}

	/** Every moved form is a fixed point of the same config. */
	public function testMovedFormsAreFixedPoints(): Void {
		for (canon in [STMT_ABOVE, MEMBER_ABOVE, GLUED_ABOVE, BLANK_ABOVE, NESTED_ABOVE, LAMBDA_ABOVE]) Assert.equals(canon, on(canon));
	}

	/** `"keep"` and an unknown token are the default: nothing moves. */
	public function testKeepAndUnknownTokensAreInert(): Void {
		Assert.equals(STMT_SRC, write(STMT_SRC, CONFIG_KEEP));
		Assert.equals(STMT_SRC, write(STMT_SRC, '{$BASE, "comments": {"trailingCommentOverflow": "sideways"}}'));
	}

	private inline function on(src: String): String {
		return write(src, CONFIG_ON);
	}

	private inline function off(src: String): String {
		return write(src, CONFIG_OFF);
	}

	private function write(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/** A one-statement function whose statement is `code`, with `comment` trailing it when not empty. */
	private static function stmt(code: String, comment: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$code${comment == '' ? '' : ' ' + comment}\n\t}\n}';
	}

	/** `stmt` with `comment` moved onto its own line above `code`. */
	private static function above(code: String, comment: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$comment\n\t\t$code\n\t}\n}';
	}

	private static function rep(unit: String, times: Int): String {
		final buf: StringBuf = new StringBuf();
		for (_ in 0...times) buf.add(unit);
		return buf.toString();
	}

}
