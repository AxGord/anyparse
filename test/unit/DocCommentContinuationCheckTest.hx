package unit;

import anyparse.check.Check.Violation;
import anyparse.check.DocCommentContinuation;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `doc-comment-continuation` check: an interior line of a block comment that breaks the
 * continuation prefix its own block uses — a STAR-GUTTERED block judged by its gutter (lost,
 * carried at the wrong indent, or carried twice) and a GUTTER-LESS `/**` one by its INDENTATION.
 *
 * This is the only channel in the project that can see the class. The writer re-emits a
 * comment interior byte for byte, so a corrupted block is writer-canonical (`fmt --list`
 * clean) and every node-based rule is blind to trivia. The fixtures below are the shapes
 * three writer-emit ops actually produced on this repository's own tree.
 *
 * The CONTROLS are as load-bearing as the findings, because the rule reads prose: a `/*` block of
 * commented-out code, a markdown bullet, a bold marker, a deeper-indented code line inside a doc, a
 * comment shape inside a STRING literal, a trailing comment after code, and — for the gutter-less
 * arm — a first line padded for prose, a tab-against-spaces mix and an interior written flush with
 * its delimiters must all stay silent. Each of those is green at base BY CONSTRUCTION — the rule did not
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
	 * A `/*` block with no gutter is commented-out code, where indentation is CONTENT, and the rule
	 * does not judge it. The interior here steps BACK to the delimiter indent, which in a `/**` doc
	 * block is the splice signature — so it is the `/*`-vs-`/**` clause that acquits this fixture and
	 * not one of its neighbours.
	 *
	 * VACUITY, found by review: the original shape (every interior line at one indent) was acquitted
	 * by the flush-with-delimiters clause instead, and stayed acquitted when re-spelled as `/**`. Its
	 * doc also said the rule "never inspects" a gutter-less block, which the gutter-less arm made
	 * false.
	 */
	public function testUngutteredBlockIgnored(): Void {
		Assert.equals(0, violations('class C {\n\t/*\n\t\tfunction old() {}\n\tvar dead = 1;\n\t\treturn;\n\t*/\n}').length);
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

	/**
	 * A GUTTER-LESS block (`/**` … `**\/`, the Haxe-stdlib spelling) indents its interior one level
	 * deeper than its delimiters and carries no star at all. The rule required a gutter star on the
	 * first interior line, so this whole family fell through.
	 *
	 * ⚠️ The 227 lines in 23 files S23 measured are NOT this family's — that population is what the
	 * STAR arm found on this repository's own ` * `-guttered tree, and an earlier draft of this doc
	 * claimed it as evidence for the gutter-less arm. The arm's real evidence is a producer/detector
	 * pair the slice ran end to end: `hxq comment-rewrite` at the base commit, splicing a line into
	 * the stdlib's own `haxe/ds/StringMap.hx` doc, landed it at column 0; `fmt --list` called the
	 * result canonical and the rule at base reported nothing; this arm reports exactly that line, and
	 * its `--fix` reproduces byte for byte what the fixed splice writes. Across 4599 external files
	 * the arm's own finding count is zero.
	 */
	public function testGutterlessBlockBrokenIndentReported(): Void {
		final src: String = 'class C {\n\t/**\n\t\tOne line.\n\tLost a level.\n\t\tThree.\n\t**/\n\tfunction f() {}\n}';
		final found: Array<Violation> = violations(src);
		Assert.equals(1, found.length);
		// The WORDING is the finding's whole payload here — a gutter-less block has no ` * ` to have
		// lost, and the guttered arm's two messages both name one.
		Assert.equals('doc-comment continuation line does not carry its block\'s own indentation', found[0].message);
	}

	/**
	 * A line SHALLOWER than the delimiters, not merely at them — what a hand edit or a pre-S23 splice
	 * into an indented block leaves. An earlier draft aborted the whole judgement on any line whose
	 * indentation did not start with the block's, which acquitted this outright.
	 */
	public function testGutterlessLineUnderTheDelimiterIndentReported(): Void {
		final src: String = 'class C {\n\t/**\n\t\tOne line.\nFlush left.\n\t\tThree.\n\t**/\n\tfunction f() {}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\t/**\n\t\tOne line.\n\t\tFlush left.\n\t\tThree.\n\t**/\n\tfunction f() {}\n}', fixed(src));
	}

	/** The gutter-less repair keeps a `\r`, so a CRLF file does not gain one bare-LF line. */
	public function testFixKeepsCarriageReturnGutterless(): Void {
		final src: String = 'class C {\r\n\t/**\r\n\t\tOne line.\r\n\tLost a level.\r\n\t\tThree.\r\n\t**/\r\n\tfunction f() {}\r\n}';
		Assert.equals(
			'class C {\r\n\t/**\r\n\t\tOne line.\r\n\t\tLost a level.\r\n\t\tThree.\r\n\t**/\r\n\tfunction f() {}\r\n}', fixed(src)
		);
	}

	/**
	 * A gutter-less block whose lines all agree is a house style, not a splice. The gutter arm reaches
	 * that outcome through an explicit unanimity loop; this arm has none — a consistent block simply
	 * has no line at or under its delimiter indent for `breakage` to report.
	 */
	public function testGutterlessBlockUnanimousIsClean(): Void {
		final src: String = 'class C {\n\t/**\n\t\tOne line.\n\t\tTwo.\n\t\tThree.\n\t**/\n\tfunction f() {}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A line indented DEEPER than the block's own interior is a code sample or a list — untouched. */
	public function testGutterlessDeeperLineIsClean(): Void {
		final src: String = 'class C {\n\t/**\n\t\tExample:\n\n\t\t\tfinal y = 2;\n\t\tDone.\n\t**/\n\tfunction f() {}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A block at column 0 whose interior sits at one tab, with one line flush left — the S38 shape. */
	public function testGutterlessTypeLevelFlushLeftLineReported(): Void {
		final src: String = '/**\n\tOne line.\nLost every level.\n\tThree.\n**/\nclass C {}';
		Assert.equals(1, violations(src).length);
	}

	/** The fix restores the block's own interior indentation, keeping the line's content byte for byte. */
	public function testFixRestoresGutterlessIndent(): Void {
		final src: String = 'class C {\n\t/**\n\t\tOne line.\n\tLost a level.\n\t\tThree.\n\t**/\n\tfunction f() {}\n}';
		final out: String = fixed(src);
		Assert.equals('class C {\n\t/**\n\t\tOne line.\n\t\tLost a level.\n\t\tThree.\n\t**/\n\tfunction f() {}\n}', out);
		// The repair is a fixed point, the way `testRealWorldShapeAllFourLines` proves it for the
		// gutter arm — a fix that still reports is a fix that will be applied again next pass.
		Assert.equals(0, violations(out).length);
	}

	/** A star-guttered block is still judged by the gutter arm — the two arms do not cross. */
	public function testGutteredBlockStillJudgedByItsGutter(): Void {
		final src: String = 'class C {\n\t/**\n\t * One line.\n\tLost the gutter.\n\t * Three.\n\t */\n\tfunction f() {}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C {\n\t/**\n\t * One line.\n\t * Lost the gutter.\n\t * Three.\n\t */\n\tfunction f() {}\n}', fixed(src));
	}

	/**
	 * FIRST-LINE PROSE PADDING. Judging a gutter-less block against its first interior line's
	 * indentation — the way the gutter arm judges a gutter — reported this shape across the Haxe
	 * standard library: a first line whose extra leading spaces align prose, not structure
	 * (`lua/lib/lrexlib/Rex.hx`). A gutter star anchors a prefix; bare indentation does not.
	 */
	public function testGutterlessProsePaddedFirstLineIgnored(): Void {
		final src: String = 'class C {\n\t/**\n\t\t  This function searches for all matches of the pattern,\n'
			+ '\t\tand replaces them according to the parameters.\n\t**/\n\tfunction f() {}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** The same shape one level up — the first line padded, the block at column 0 (`js/html/svg`). */
	public function testGutterlessProsePaddedTypeLevelIgnored(): Void {
		final src: String = '/**\n\t Creates a begin instance time for the current time.\n\n\t@throws DOMError\n**/\nclass C {}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A `/*` block is commented-out code or a banner, where indentation is CONTENT — the standard
	 * library keeps a whole C# method inside one at four different levels (`cs/internal/Runtime.hx`).
	 * Only a `/**` doc block is judged by its indentation.
	 *
	 * VACUITY, FOUND BY MUTATION AND RECORDED: the first version of this fixture was the stdlib's own
	 * `cs/internal/Runtime.hx` block verbatim, and dropping the `/**` clause killed NOTHING — that
	 * block opens at column 0 and holds no line at column 0, so it is the delimiter-indent clause
	 * that acquits it, not this one. The shape below is the one that needs this clause: a `/*` block
	 * whose interior DOES step back to the delimiter indent, which in a doc block is the splice.
	 */
	public function testGutterlessCommentedOutCodeIgnored(): Void {
		final src: String = 'class C {\n\t/*\n\t\tif (a) return b;\n\telse\n\t\treturn c;\n\t*/\n\tfunction g() {}\n}';
		Assert.equals(0, violations(src).length);
		// The identical shape as a DOC block is the splice signature, and does report.
		Assert.equals(1, violations('class C {\n\t/**\n\t\tif (a) return b;\n\telse\n\t\treturn c;\n\t**/\n\tfunction g() {}\n}').length);
	}

	/** A block whose lines share no indentation at all (a tab against spaces) is not a splice. */
	public function testGutterlessTabAgainstSpacesIgnored(): Void {
		final src: String = '/**\n\tThis library is an extern for a polyfill library of common lua table\n    methods.\n**/\nclass C {}';
		Assert.equals(0, violations(src).length);
	}

	/** A block written FLUSH with its own delimiters has no deeper line to have fallen away from. */
	public function testGutterlessFlushWithDelimitersIgnored(): Void {
		final src: String =
			'class C {\n\t/**\n\tText at the delimiter level.\n\t\tan indented sample\n\tMore text.\n\t**/\n\tfunction f() {}\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A block whose interior is SPACE-indented while its delimiters are tab-indented shares no
	 * indentation with them, so there is no "its own" prefix to judge against and the rule stays out.
	 *
	 * HAND-ASSEMBLED after a zero-kill mutation arm: dropping the clause that requires an interior
	 * line to start with the block's indent killed nothing against the fixtures then present, and
	 * neither did the two stdlib shapes that motivated it — they are acquitted one clause earlier.
	 * This is the shape that actually needs it, and no real file in 4599 external ones produced it.
	 */
	public function testGutterlessSpaceInteriorUnderTabDelimitersIgnored(): Void {
		final src: String =
			'class C {\n\t/**\n  Space line one.\n  Space line two.\n\tA line at the delimiter indent.\n\t**/\n\tfunction f() {}\n}';
		Assert.equals(0, violations(src).length);
	}

	private function violations(src: String): Array<Violation> {
		return new DocCommentContinuation().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new DocCommentContinuation(), src);
	}

}
