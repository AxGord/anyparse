package unit;

import anyparse.check.Check.Violation;
import anyparse.check.DocCommentContinuation;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `doc-comment-continuation` check: an interior line of a STAR-GUTTERED block comment
 * that breaks the block's own ` * ` continuation prefix — lost it, carries it at the wrong
 * indent, or carries it twice.
 *
 * This is the only channel in the project that can see the class. The writer re-emits a
 * comment interior byte for byte, so a corrupted block is writer-canonical (`fmt --list`
 * clean) and every node-based rule is blind to trivia. The fixtures below are the shapes
 * three writer-emit ops actually produced on this repository's own tree.
 *
 * The CONTROLS are as load-bearing as the findings, because the rule reads prose: an
 * unguttered block comment, a markdown bullet, a bold marker, a deeper-indented code line
 * inside a doc, a comment shape inside a STRING literal, and a trailing comment after code
 * must all stay silent. Each of those is green at base BY CONSTRUCTION — the rule did not
 * exist — so their value is the mutation proof recorded in the slice report, not the pass.
 */
class DocCommentContinuationCheckTest extends Test {

	/** The `comment-rewrite` raw-splice shape: a line inside the block with no gutter at all. */
	public function testFlushLeftInteriorLineFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\t/**\n\t * Kept line.\n\tlost its gutter.\n\t */\n\tfunction f() {}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('doc-comment-continuation', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('doc-comment continuation line lost its ` * ` gutter', vs[0].message);
	}

	/** The writer's re-base shape: a gutter one level deeper than the block that owns it. */
	public function testDeeperGutterFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\t/**\n\t\t * Too deep.\n\t * Right here.\n\t */\n\tfunction f() {}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('doc-comment continuation line carries its ` * ` gutter at a different indent than its block', vs[0].message);
	}

	/**
	 * The Haxe-standard-library / OpenFL doc style: no gutter at all, body indented one level
	 * under the opener, markdown bullets inside. Reading only the FIRST CHARACTER of the opening
	 * interior line counted a `*` bullet as a gutter and reported every line of such a block —
	 * measured, 36 findings over the 2624 stdlib files and 254 over openfl, and the fix DELETED
	 * the bullet markers. A gutter star is followed by whitespace; a bullet's is the whole marker.
	 */
	public function testGutterlessBulletBlockIgnored(): Void {
		final src: String = 'class C {\n\t/**\n\t\tThis value controls the messages, a sum of some of these flags:\n\n'
			+ '\t\t* 0x001 Start of major GC cycle.\n\t\t* 0x002 Minor collection and major GC slice.\n\t**/\n\tfunction f() {}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, fixed(src));
	}

	/** `**BETA**` opens a gutter-less block with a star that is bold, not a gutter. */
	public function testBoldOpenerIgnored(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t\t**BETA**\n\n\t\tCreates a thing.\n\t**/\n\tfunction f() {}\n}').length);
	}

	/**
	 * A block whose every line already agrees on ONE gutter is a house style, whatever indent it
	 * chose — here one level deeper than its opener, which is how openfl and lime write theirs.
	 * Judging it against the OPENER's indent reported 142 correct blocks across those two
	 * libraries. What the rule reports is a line disagreeing with its own block.
	 */
	public function testUnanimousBlockAtItsOwnIndentIgnored(): Void {
		Assert.equals(
			0,
			violations('class C {\n\t/**\n\t\t* Used to determine the format.\n\t\t* The value is a constant.\n\t*/\n\tfunction f() {}\n}')
				.length
		);
	}

	/** …and one line breaking that same block's agreement IS reported, and repaired onto it. */
	public function testOutlierInADeeperBlockFlagged(): Void {
		final src: String = 'class C {\n\t/**\n\t\t* Reads a string. The string is assumed to be\n\t\t* prefixed with a length.\n'
			+ '\t\t\t\tThis method is similar to readUTF().\n\t*/\n\tfunction f() {}\n}';
		Assert.equals(3, violations(src).length);
	}

	/** Every interior line on the block's own prefix: nothing to report. */
	public function testWellFormedBlockClean(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * One.\n\t * Two.\n\t */\n\tfunction f() {}\n}').length);
	}

	/** A type-level block at column 0 has prefix ` *`, not the member form. */
	public function testTypeLevelBlockUsesItsOwnIndent(): Void {
		Assert.equals(0, violations('/**\n * One.\n * Two.\n */\nclass C {}').length);
		Assert.equals(1, violations('/**\n * One.\n\t * Two.\n */\nclass C {}').length);
	}

	/**
	 * A block comment with NO gutter is a different, legitimate style — commented-out code, a
	 * free-form paragraph — and the rule never inspects it. Green at base by construction.
	 */
	public function testUngutteredBlockIgnored(): Void {
		Assert.equals(0, violations('class C {\n\t/*\n\tfunction old() {}\n\tvar dead = 1;\n\t*/\n}').length);
	}

	/**
	 * A block written in the COMPACT `<indent>*` spelling end to end is a house style, not a
	 * corruption — it is the only shape the rule found on 868 Pony files, and flagging it would
	 * have made a prose-rewriting rule a style police. The block picks the spelling ITS OWN lines
	 * use, so a consistent block is silent whichever one it chose.
	 */
	public function testCompactGutterBlockIgnored(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t* One.\n\t* Two.\n\t*/\n\tfunction f() {}\n}').length);
	}

	/** …and a line that disagrees with a compact block IS reported, on that block's own spelling. */
	public function testOutlierInACompactBlockFlagged(): Void {
		final src: String = 'class C {\n\t/**\n\t* One.\n\t* Two.\n\tthree.\n\t*/\n\tfunction f() {}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\t/**\n\t* One.\n\t* Two.\n\t* three.\n\t*/\n\tfunction f() {}\n}', fixed(src));
	}

	/**
	 * A BLANK interior line is out of scope: it has no prefix to break and the comment renders
	 * identically either way. Reporting it would turn the rule into a style police over every
	 * paragraph break in the tree. Green at base by construction.
	 */
	public function testBlankInteriorLineIgnored(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * One.\n\n\t * Two.\n\t */\n\tfunction f() {}\n}').length);
	}

	/**
	 * A markdown bullet is content, not a second gutter. The doubling test consumes exactly ONE
	 * separating space before it looks for the prefix again, which is what tells the two apart.
	 * Green at base by construction.
	 */
	public function testMarkdownBulletNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * Items:\n\t * * first\n\t * * second\n\t */\n\tfunction f() {}\n}').length);
	}

	/**
	 * A NESTED bullet is content too, and it is why the doubling arm is not widened to the
	 * ` *  * ` form: over this tree and 679 Pony files that pattern matched exactly two lines
	 * and both were nested bullets like this one.
	 */
	public function testNestedBulletNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * Items:\n\t *     * nested\n\t */\n\tfunction f() {}\n}').length);
	}

	/** A bold marker is not a gutter either — no whitespace follows the second star. */
	public function testBoldMarkerNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * **Drops** the semicolon.\n\t */\n\tfunction f() {}\n}').length);
	}

	/**
	 * A line indented DEEPER THAN the prefix still carries the prefix, so a fenced code block
	 * inside a doc is untouched. Green at base by construction.
	 */
	public function testIndentedCodeInsideDocKept(): Void {
		Assert.equals(0, violations('class C {\n\t/**\n\t * Example:\n\t *     final x = 1;\n\t */\n\tfunction f() {}\n}').length);
	}

	/**
	 * The scan rides `RefactorSupport.collectCommentTokens`, which is string-aware, so a
	 * corrupted doc block spelled inside a STRING literal is a fixture and not a finding.
	 * Green at base by construction.
	 */
	public function testCommentShapeInsideStringIgnored(): Void {
		// The block shape must OPEN ITS OWN LINE inside the string, or the token gate would skip
		// it for a reason that has nothing to do with string-awareness and the fixture would pass
		// with `collectCommentTokens` blind to strings.
		Assert.equals(0, violations('class C {\n\tvar s = "head\n/**\n\t\t * deep\nflush\n */\n";\n}').length);
	}

	/**
	 * A block sharing its line with preceding CODE is skipped: what its continuation should be
	 * indented to is a guess once the opener does not start the line, and guessing is how a rule
	 * that rewrites prose gets it wrong. The fixture is deliberately one the rule WOULD flag if
	 * the gate were dropped — a guttered first interior line and an unguttered second — because a
	 * two-line trailing comment has no interior line at all and would pass on the wrong gate.
	 */
	public function testTrailingBlockAfterCodeIgnored(): Void {
		Assert.equals(0, violations('class C {\n\tvar x = 1; /* note\n\t * kept\nflush\n\tdone */\n}').length);
	}

	/** A one-line block has no interior line to judge. */
	public function testSingleLineBlockIgnored(): Void {
		Assert.equals(0, violations('class C {\n\t/** One-liner. */\n\tfunction f() {}\n}').length);
	}

	/** The fix restores the block's prefix on a line that lost it, keeping the text byte for byte. */
	public function testFixRestoresLostGutter(): Void {
		final src: String = 'class C {\n\t/**\n\t * Kept line.\n\tlost its gutter.\n\t */\n\tfunction f() {}\n}';
		Assert.equals('class C {\n\t/**\n\t * Kept line.\n\t * lost its gutter.\n\t */\n\tfunction f() {}\n}', fixed(src));
	}

	/**
	 * A line that lost its gutter keeps whatever indentation it carried BEYOND the block's own —
	 * a code sample indented inside a doc survives the repair. `ltrim`ing the whole run instead
	 * flattened a four-space sample against the gutter, which is content destroyed by a fix.
	 */
	public function testFixKeepsIndentationInsideTheBlock(): Void {
		final src: String = 'class C {\n\t/**\n\t * Example:\n\t    final y = 2;\n\t */\n\tfunction f() {}\n}';
		// The four spaces the line carried BEYOND the block's own `\t` survive verbatim.
		Assert.equals('class C {\n\t/**\n\t * Example:\n\t *    final y = 2;\n\t */\n\tfunction f() {}\n}', fixed(src));
	}

	/**
	 * A gutter-only line in a CRLF file keeps its `\r` — dropping it leaves one bare-LF line among
	 * CRLF siblings. `EmptyDocTag.lineRunSpan` guards the same hazard for the same reason.
	 */
	public function testFixKeepsCarriageReturn(): Void {
		final src: String = 'class C {\r\n\t/**\r\n\t * one\r\n\t\t *\r\n\t * two\r\n\t */\r\n\tfunction f() {}\r\n}';
		Assert.equals('class C {\r\n\t/**\r\n\t * one\r\n\t *\r\n\t * two\r\n\t */\r\n\tfunction f() {}\r\n}', fixed(src));
	}

	/** The fix pulls a too-deep gutter back onto the block's own indent. */
	public function testFixCorrectsDeeperGutter(): Void {
		final src: String = 'class C {\n\t/**\n\t\t * Too deep.\n\t * Right here.\n\t */\n\tfunction f() {}\n}';
		Assert.equals('class C {\n\t/**\n\t * Too deep.\n\t * Right here.\n\t */\n\tfunction f() {}\n}', fixed(src));
	}

	/** The whole corruption shape at once — one deepened line, three that lost the gutter. */
	public function testRealWorldShapeAllFourLines(): Void {
		final src: String = 'class C {\n\t/**\n\t\t * Only the FIRST link is reported per pass: the scan spans the whole scope, so\n'
			+ '\tthe earlier declaration reads as an occurrence of the middle one and keeps it\n'
			+ '\tlive. The driver loops to a fixed point, and each pass promotes the next link\n\tto first.\n\t */\n\tfunction f() {}\n}';
		Assert.equals(4, violations(src).length);
		final out: String = fixed(src);
		Assert.equals(
			'class C {\n\t/**\n\t * Only the FIRST link is reported per pass: the scan spans the whole scope, so\n'
			+ '\t * the earlier declaration reads as an occurrence of the middle one and keeps it\n\t * live. The driver loops to a fixed '
			+ 'point, and each pass promotes the next link\n\t * to first.\n\t */\n\tfunction f() {}\n}',
			out
		);
		Assert.equals(0, violations(out).length);
	}

	private function violations(src: String): Array<Violation> {
		return new DocCommentContinuation().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new DocCommentContinuation(), src);
	}

}
