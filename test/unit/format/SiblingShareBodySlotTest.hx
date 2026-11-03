package unit.format;

import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.format.SiblingPolicy;
import anyparse.format.SiblingShare;

/**
 * `SiblingShare.bodySlot`: which vote a body below its head casts from what the writer alone can see, and that a list
 * that is not sharing, or a body whose policy does not fit, stays the plain Doc it came in as.
 */
class SiblingShareBodySlotTest extends Test {

	private static final OWN: Doc = Doc.Text('own');
	private static final HELD: Doc = Doc.Text('held');

	/** Off is the plain Doc itself, so the slot is no slot and `decide` has nothing to read. */
	public function testAListThatDoesNotShareKeepsThePlainDoc(): Void {
		Assert.isTrue(SiblingShare.bodySlot(SiblingPolicy.Off, true, OWN, 2, false, HELD, false) == OWN);
	}

	/** Only a fitting policy decides beside the head, and a body under any other is below it for that reason alone. */
	@:pin('control')
	@:killer('M-SIBLING-BODY-IGNORES-FITLINE')
	public function testABodyWhosePolicyDoesNotFitCastsNoVote(): Void {
		Assert.isTrue(SiblingShare.bodySlot(SiblingPolicy.AnyBreak, false, OWN, 2, false, HELD, false) == OWN);
	}

	public function testTwoStatementsLead(): Void {
		Assert.equals(vote(SiblingShare.placedSlot(SiblingPolicy.AnyBreak, true, OWN)), bodyVote(2, true, HELD, false));
	}

	/** A sole statement its shape keeps below the head leads like two of them do. */
	@:pin('control')
	@:killer('M-SIBLING-BODY-SOLE-SHAPE-DOES-NOT-LEAD')
	public function testASoleStatementItsShapeRefusesLeads(): Void {
		Assert.equals(vote(SiblingShare.placedSlot(SiblingPolicy.AnyBreak, true, OWN)), bodyVote(1, false, HELD, false));
	}

	public function testAnEmptyBodyVotesWithoutLeading(): Void {
		Assert.equals(vote(SiblingShare.placedSlot(SiblingPolicy.AnyBreak, false, OWN)), bodyVote(0, false, null, false));
	}

	/** A sole statement a comment held below keeps its glued form to measure, and `last` is that statement only when it is the sole one. */
	@:pin('control')
	@:killer('M-SIBLING-BODY-HELD-NOT-MEASURED')
	public function testACommentHeldStatementMeasuresItsGluedForm(): Void {
		Assert.equals(vote(SiblingShare.commentedSlot(SiblingPolicy.AnyBreak, OWN, HELD, false)), bodyVote(1, true, HELD, false));
		Assert.notEquals(vote(SiblingShare.placedSlot(SiblingPolicy.AnyBreak, false, OWN)), bodyVote(1, true, HELD, false));
	}

	public function testACommentHeldStatementWithNoFlatFormLeadsWhenGlueIsRefused(): Void {
		final broken: Doc = Doc.Concat([Doc.Text('a'), D.hardline()]);
		Assert.equals(vote(SiblingShare.placedSlot(SiblingPolicy.AnyBreak, true, OWN)), bodyVote(1, true, broken, true));
	}

	private static function bodyVote(count: Int, soleFlat: Bool, last: Null<Doc>, refuseGlue: Bool): Int {
		return vote(SiblingShare.bodySlot(SiblingPolicy.AnyBreak, true, OWN, count, soleFlat, last, refuseGlue));
	}

	private static function vote(d: Doc): Int {
		return switch d {
			case Doc.IfIndentWidthExceeds(width, _, _, _): width;
			case _: throw 'not a slot: $d';
		};
	}

}
