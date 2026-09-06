package unit.lowering;

import unit.grammar.haxe.HxWriteFixture;
import utest.Assert;
import utest.Test;

/**
 * The `BeforeLeading` trivia slot — `WriterTriviaSlotLowering.buildBeforeLeadingSep` wraps a bare
 * non-first Ref's inter-field separator so the comments captured in the gap between the preceding
 * content and the sub-rule's first token are emitted in front of it.
 *
 * One shape grows the slot (`TriviaPairSlots.isBareNonFirstRef`) and one source shape fills it: a
 * member whose modifier run is followed by a block comment carrying an internal newline. The
 * modifier Star's `collectTrailingFull` refuses that comment because of the newline, so it lands in
 * this gap and nothing else can carry it. The fork corpus has the case
 * (`lineends/issue_598_multiline_comment_var`) and the unit suite had NOTHING: forcing the
 * separator back to its bare form leaves the whole suite green, which is a statement about the
 * suite rather than about the slot. On the shape below that same cut makes `hxq fmt` answer
 * `the writer round trip would drop the comment`.
 *
 * The two guards are the shapes that route elsewhere: a gap comment with no internal newline is
 * taken by the modifier Star upstream, and a member with no gap comment never grows a non-empty
 * slot. Both stay byte-identical with the layer removed, which is what makes the fixture above
 * discriminate instead of merely moving with the writer.
 */
@:nullSafety(Strict)
final class BeforeLeadingCommentSlotTest extends Test {

	/** The slot is not knob-driven, so the config only has to be a valid one. */
	private static final DEFAULTS: String = '{}';

	/** A block comment between `public` and `var` whose interior spans two lines. */
	private static final MULTILINE_GAP_COMMENT: String = 'class Main {\n\tpublic /*\n\t */var foo:Int;\n}';

	/** The same gap comment written on one line — captured by the modifier Star, not by the slot. */
	private static final ONE_LINE_GAP_COMMENT: String = 'class Main {\n\tprivate /**/var foo:Int;\n}';

	/** No gap comment at all: the slot exists and is empty, which is byte-inert by construction. */
	private static final NO_GAP_COMMENT: String = 'class Main {\n\tpublic var bar:Int;\n}';

	public function new(): Void {
		super();
	}

	/** Without the layer the captured comment never reaches the separator and the member loses it. */
	@:pin('control')
	@:killer('M-BEFORE-LEADING-COMMENT-DROP')
	public function testAMultilineGapCommentReachesTheOutput(): Void {
		Assert.equals('class Main {\n\tpublic /*\n\t */\n\tvar foo:Int;\n}', HxWriteFixture.triviaWrite(MULTILINE_GAP_COMMENT, DEFAULTS));
	}

	/** The upstream half of the pair: this comment is the modifier Star's, so the slot is empty. */
	@:pin('guard')
	public function testAOneLineGapCommentIsCarriedUpstream(): Void {
		Assert.equals('class Main {\n\tprivate /**/ var foo:Int;\n}', HxWriteFixture.triviaWrite(ONE_LINE_GAP_COMMENT, DEFAULTS));
	}

	/** An empty slot emits the plain separator either way, so this one cannot discriminate. */
	@:pin('guard')
	public function testAMemberWithNoGapCommentIsUnchanged(): Void {
		Assert.equals(NO_GAP_COMMENT, HxWriteFixture.triviaWrite(NO_GAP_COMMENT, DEFAULTS));
	}

}
