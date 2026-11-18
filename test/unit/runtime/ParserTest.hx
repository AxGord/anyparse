package unit.runtime;

import anyparse.runtime.Parser;
import anyparse.runtime.PendingTrivia;
import anyparse.runtime.StringInput;

/** The byte scans a generated Star loop calls on its `Parser` context. */
@:nullSafety(Strict)
final class ParserTest extends Test {

	public function testAStashIsRestoredAfterABraceTerminatedValue(): Void {
		final ctx: Parser = new Parser(new StringInput('a = {}  \n\n'));
		final saved: PendingTrivia = stash();
		ctx.restorePendingAfterGap(10, saved);
		Assert.equals(saved, ctx.pendingTrivia);
	}

	public function testAStashIsRestoredAfterAValueWhoseLineBreakWasConsumed(): Void {
		final ctx: Parser = new Parser(new StringInput('a = 1  \n\n'));
		final saved: PendingTrivia = stash();
		ctx.restorePendingAfterGap(9, saved);
		Assert.equals(saved, ctx.pendingTrivia);
	}

	public function testAStashStaysDroppedAfterAValueWhoseGapIsStillInTheInput(): Void {
		final ctx: Parser = new Parser(new StringInput('a = 1;  \n\n'));
		ctx.restorePendingAfterGap(7, stash());
		Assert.isNull(ctx.pendingTrivia);
	}

	public function testNoStashLeavesThePendingSlotAlone(): Void {
		final ctx: Parser = new Parser(new StringInput('{}'));
		ctx.restorePendingAfterGap(2, null);
		Assert.isNull(ctx.pendingTrivia);
	}

	private static function stash(): PendingTrivia {
		return {
			blankBefore: true,
			blankAfterLeadingComments: false,
			newlineBefore: true,
			leadingComments: []
		};
	}

}
