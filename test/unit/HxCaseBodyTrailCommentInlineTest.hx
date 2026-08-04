package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * omega-case-trail-comment-inline — an ORPHAN TRAIL comment must not
 * disqualify a case body from the label line.
 *
 * `_caseBodyFlattenable` required the body Star's orphan trailing-comment
 * run to be EMPTY, so one commented-out case between two live ones pushed
 * the body above it below its label while its siblings stayed inline. The
 * cause is invisible in the output — the reader sees an asymmetric switch
 * and no reason for it:
 *
 * ```
 * case SIZE:
 *     size = cast(d, Int);
 * // case ALIGN: align = cast(d, Align);
 * case BOLD: bold = cast(d, Bool);
 * ```
 *
 * The comment never needed the body out of the way. It renders on its own line(s) at LABEL indent after the body, which is
 * where the `nestBody` path already put it whenever the body was non-empty
 * (issue_392) — so the fit path emits the body placement first and the
 * trail docs after it, at label level.
 *
 * NARROWED TO `FitLine` ON PURPOSE. `_flatCase` (`Same`, and `Keep` on
 * same-line source) keeps the empty-trail requirement: it is the policy the
 * fork corpus runs under, and this is a placement change, not a parity fix.
 * `_fitCase` is opt-in per project, so the relaxation lands only where the
 * knob was chosen. Measured accordingly: the fork corpus runs the DEFAULT
 * config and comes out byte-identical per fixture, while a tree formatted
 * with `caseBody` / `expressionCase: fitLine` does move — which is the
 * point of the slice, not a regression in it.
 *
 * MEASUREMENT. An element carrying trail docs cannot render on one line, so
 * the sibling pre-pass measures it as `-1` and it contributes NOTHING to
 * the widest-sibling width — the same answer a glued body gives. It
 * therefore never LEADS a spread, and its own over-wide body still breaks
 * on its own through the `BodyGroup` the fit path wraps it in (which holds
 * the BODY alone — the trail docs sit outside it). It does FOLLOW: under
 * someone else's trigger it goes below its label with everyone.
 *
 * GUARDS vs DISCRIMINATORS. Stash-verified against the pre-slice engine:
 * `testATrailCommentBodyJoinsItsLabel` and
 * `testABlankAfterTheTrailCommentIsPreserved` are the two that FAIL there.
 * Every other test here is a guard — byte-identical before the slice —
 * pinning that the relaxation left untouched the shapes that must keep
 * their placement, and that the newly-inline unit still follows a trigger
 * and still contributes no width.
 *
 * Per `feedback_unit_test_trivia_writer.md`: the knobs are visible only
 * through `HaxeModuleTriviaParser` / `HaxeModuleTriviaWriter`.
 */
@:nullSafety(Strict)
final class HxCaseBodyTrailCommentInlineTest extends Test {

	/** The owner-reported shape: one commented-out case between three live ones. */
	private static final TRAIL_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (t) {\n\t\t\tcase A: size = cast(d, Int);\n'
		+ '\t\t\t// case B: align = cast(d, Align);\n\t\t\tcase C: bold = cast(d, Bool);\n\t\t\tcase _:\n\t\t}\n\t}\n}\n';

	/** A blank line between the orphan trail and the next label (the trailBA channel). */
	private static final TRAIL_BLANK_AFTER_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (t) {\n'
		+ '\t\t\tcase A: size = cast(d, Int);\n\t\t\t// orphan note\n\n\t\t\tcase C: bold = cast(d, Bool);\n\t\t\tcase _:\n\t\t}\n\t}\n}\n';

	/**
	 * A blank line BEFORE the comment. The blank hands the comment to the
	 * next case as a LEADING comment of the outer Star, so the body Star's
	 * orphan trail is empty and this case was already inline — a guard that
	 * the relaxation did not disturb that attachment.
	 */
	private static final TRAIL_BLANK_BEFORE_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (t) {\n'
		+ '\t\t\tcase A: size = cast(d, Int);\n\n\t\t\t// orphan note\n\t\t\tcase C: bold = cast(d, Bool);\n\t\t\tcase _:\n\t\t}\n\t}\n}\n';

	/** A LEADING comment on the body statement — still disqualifying, it would land inside the label line. */
	private static final LEAD_COMMENT_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (t) {\n\t\t\tcase A:\n'
		+ '\t\t\t\t// a note about the body\n\t\t\t\tsize = cast(d, Int);\n\t\t\tcase C: bold = cast(d, Bool);\n\t\t\tcase _:\n'
		+ '\t\t}\n\t}\n}\n';

	/** A trailing comment captured on the LABEL — a different comment, and still refused. */
	private static final LABEL_TRAIL_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (t) {\n\t\t\tcase A: // a note\n'
		+ '\t\t\t\tsize = cast(d, Int);\n\t\t\tcase C: bold = cast(d, Bool);\n\t\t\tcase _:\n\t\t}\n\t}\n}\n';

	/** The trail-comment case is the WIDEST — the unit the pre-pass cannot measure. */
	private static final WIDE_TRAIL_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (t) {\n'
		+ '\t\t\tcase A: aaaa(bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n\t\t\t// orphan note\n\t\t\tcase C: cc(d);\n'
		+ '\t\t\tcase _:\n\t\t}\n\t}\n}\n';

	/**
	 * A blank line before the orphan comment on the LAST case — the position
	 * where a following case cannot claim the comment as its own leading one.
	 * Measured: the blank detaches it from the body Star here too, so this
	 * case's body was ALREADY inline before the relaxation. The fixture pins
	 * that the trailBB blank channel came through untouched.
	 */
	private static final LAST_CASE_BLANK_BEFORE_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (t) {\n'
		+ '\t\t\tcase A: size = cast(d, Int);\n\t\t\tcase C: bold = cast(d, Bool);\n\n\t\t\t// orphan note behind a blank\n'
		+ '\t\t}\n\t}\n}\n';

	/** A multi-statement sibling triggers structurally; the trail-comment case must FOLLOW it down. */
	private static final FOLLOWS_TRIGGER_SRC: String = 'class M {\n\tfunction f():Void {\n\t\tswitch (t) {\n'
		+ '\t\t\tcase A: size = cast(d, Int);\n\t\t\t// orphan note\n\t\t\tcase C:\n\t\t\t\tfinal u:Int = k();\n\t\t\t\tu;\n'
		+ '\t\t}\n\t}\n}\n';

	public function new(): Void {
		super();
	}

	/** The body joins its label and the comment keeps its own line(s), at label indent, after it. */
	public function testATrailCommentBodyJoinsItsLabel(): Void {
		final out: String = write(TRAIL_SRC, json(140));
		Assert.isTrue(out.indexOf('case A: size = cast(d, Int);') != -1, 'the body must join its label: <$out>');
		Assert.isTrue(
			out.indexOf('case A: size = cast(d, Int);\n\t\t\t// case B: align = cast(d, Align);') != -1,
			'and the comment must follow it at label indent: <$out>'
		);
		Assert.isTrue(out.indexOf('case A:\n') == -1, 'nothing may push the body below the label: <$out>');
	}

	/** The siblings that were already inline are untouched — the whole point is that the switch reads uniformly. */
	public function testTheSiblingsAreUnaffected(): Void {
		final out: String = write(TRAIL_SRC, json(140));
		Assert.isTrue(out.indexOf('case C: bold = cast(d, Bool);') != -1, 'the live sibling stays inline: <$out>');
	}

	/** A blank before the comment keeps the body inline and the blank in place, on the last case as on any other. */
	public function testABlankBeforeTheTrailCommentOnTheLastCaseIsPreserved(): Void {
		final out: String = write(LAST_CASE_BLANK_BEFORE_SRC, json(140));
		Assert.isTrue(
			out.indexOf('case C: bold = cast(d, Bool);\n\n\t\t\t// orphan note behind a blank\n\t\t}') != -1,
			'body inline, blank kept, comment at label indent before the closing brace: <$out>'
		);
	}

	/** The trailBA channel: a source blank between the comment and the next label survives the new placement. */
	public function testABlankAfterTheTrailCommentIsPreserved(): Void {
		final out: String = write(TRAIL_BLANK_AFTER_SRC, json(140));
		Assert.isTrue(
			out.indexOf('case A: size = cast(d, Int);\n\t\t\t// orphan note\n\n\t\t\tcase C:') != -1,
			'body inline, comment at label indent, blank line kept: <$out>'
		);
	}

	/** A blank BEFORE the comment reattaches it to the next case; that case then leads with it, as before. */
	public function testABlankBeforeTheTrailCommentKeepsItsAttachment(): Void {
		final out: String = write(TRAIL_BLANK_BEFORE_SRC, json(140));
		Assert.isTrue(out.indexOf('case A: size = cast(d, Int);') != -1, 'the first body stays inline: <$out>');
		Assert.isTrue(
			out.indexOf('\n\n\t\t\t// orphan note\n\t\t\tcase C: bold = cast(d, Bool);') != -1, 'blank + comment + label: <$out>'
		);
	}

	/** A LEADING comment on the body element still disqualifies it — inline, the comment would swallow the body. */
	public function testALeadingCommentOnTheBodyStillDropsIt(): Void {
		final out: String = write(LEAD_COMMENT_SRC, json(140));
		Assert.isTrue(out.indexOf('case A:\n\t\t\t\t// a note about the body') != -1, 'body stays below its label: <$out>');
	}

	/** A comment captured on the LABEL is a different comment and `_fitCase` still refuses it. */
	public function testALabelCapturedTrailingCommentIsStillRefused(): Void {
		final out: String = write(LABEL_TRAIL_SRC, json(140));
		Assert.isTrue(out.indexOf('case A: // a note\n\t\t\t\tsize = cast(d, Int);') != -1, 'label comment keeps the body below: <$out>');
	}

	/**
	 * The measurement decision, pinned in both directions: the trail-comment
	 * unit cannot be measured (its element Doc carries the comment's
	 * hardline), so it contributes no width and does not spread its siblings
	 * — while its own over-wide body still breaks, because the fit path
	 * measures the BODY alone inside its `BodyGroup`.
	 */
	public function testAWideTrailCommentUnitBreaksAloneWithoutSpreading(): Void {
		final out: String = write(WIDE_TRAIL_SRC, json(48));
		Assert.isTrue(out.indexOf('case A:\n\t\t\t\taaaa(') != -1, 'its own over-wide body still breaks: <$out>');
		Assert.isTrue(out.indexOf('case C: cc(d);') != -1, 'but it never leads a spread: <$out>');
	}

	/** Coordination still reaches it: under a structural trigger the trail-comment case goes below its label too. */
	public function testATrailCommentUnitFollowsAStructuralTrigger(): Void {
		final out: String = write(FOLLOWS_TRIGGER_SRC, json(140));
		Assert.isTrue(out.indexOf('case A:\n\t\t\t\tsize = cast(d, Int);') != -1, 'the trail-comment case follows the trigger: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t// orphan note\n\t\t\tcase C:') != -1, 'and the comment stays at label indent: <$out>');
	}

	/**
	 * The relaxation is `FitLine`-only. `Same` commits the body to the label
	 * line with a hard separator the trail docs would have to be threaded
	 * past, and it is the policy the fork corpus runs under — so it keeps
	 * the empty-trail requirement and the `nestBody` break it produces.
	 */
	public function testTheCommittedFlatPolicyStillDropsTheBody(): Void {
		final same: String = write(TRAIL_SRC, '{"wrapping": {"maxLineLength": 140}, "sameLine": {"caseBody": "same"}}');
		Assert.isTrue(same.indexOf('case A:\n\t\t\t\tsize = cast(d, Int);') != -1, 'Same keeps the body below its label: <$same>');
		Assert.isTrue(same.indexOf('\n\t\t\t// case B: align = cast(d, Align);') != -1, 'with the comment at label indent: <$same>');
	}

	/** The new placement must reach its fixed point in ONE pass. */
	public function testIsIdempotent(): Void {
		final j: String = json(140);
		final fixtures: Array<{ name: String, src: String }> = [
			{ name: 'TRAIL_SRC', src: TRAIL_SRC },
			{ name: 'TRAIL_BLANK_AFTER_SRC', src: TRAIL_BLANK_AFTER_SRC },
			{ name: 'TRAIL_BLANK_BEFORE_SRC', src: TRAIL_BLANK_BEFORE_SRC },
			{ name: 'LAST_CASE_BLANK_BEFORE_SRC', src: LAST_CASE_BLANK_BEFORE_SRC },
			{ name: 'FOLLOWS_TRIGGER_SRC', src: FOLLOWS_TRIGGER_SRC },
		];
		for (f in fixtures) {
			final pass1: String = write(f.src, j);
			final pass2: String = write(pass1, j);
			Assert.equals(pass1, pass2, '${f.name}: the placement must reach its fixed point in one pass');
			Assert.equals(pass2, write(pass2, j), '${f.name}: the fixed point must hold on a third pass');
		}
	}

	private inline function json(maxLineLength: Int): String {
		return '{"wrapping": {"maxLineLength": $maxLineLength}, "sameLine": {"caseBody": "fitLine", "expressionCase": "fitLine"}}';
	}

	private inline function write(src: String, cfg: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(cfg));
	}

}
