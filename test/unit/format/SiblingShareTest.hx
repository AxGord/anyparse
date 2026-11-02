package unit.format;

import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.format.SiblingPolicy;
import anyparse.format.SiblingShare;

using StringTools;

/**
 * `SiblingShare` over hand-built Docs: `decide` leaves no slot behind, whatever the slots voted, and it reads a vote
 * by its band, so no other number in a width slot can be taken for one.
 */
@:nullSafety(Strict)
class SiblingShareTest extends Test {

	private static inline final WIDTH: Int = 40;
	private static inline final NO_WIDTH: Int = -1;

	/** A list of a fitting and an over-wide sibling, both still voting: one verdict reaches both. */
	public function testTheWidestSiblingDecidesForAll(): Void {
		final list: Doc = SiblingShare.decide(listOf([slot('aa'), slot(''.lpad('b', WIDTH + 1))]), SiblingPolicy.AnyBreak, WIDTH);
		Assert.equals(0, votes(list), 'no slot survives the decision');
		Assert.equals(2, verdicts(list), 'both siblings carry the verdict');
	}

	/** A lone sibling has nobody to share with: it decides alone and carries no verdict. */
	public function testALoneSlotKeepsItsOwnForm(): Void {
		final list: Doc = SiblingShare.decide(listOf([slot('aa')]), SiblingPolicy.AnyBreak, WIDTH);
		Assert.equals(0, votes(list), 'no slot survives the decision');
		Assert.equals(0, verdicts(list), 'and no verdict is written');
	}

	/** A slot that leads resolves the list without a width read, and leaves no vote behind either. */
	public function testALeadingSlotResolvesTheList(): Void {
		final led: Doc = SiblingShare.placedSlot(SiblingPolicy.AnyBreak, true, Doc.Text('c'));
		final list: Doc = SiblingShare.decide(listOf([slot('aa'), led]), SiblingPolicy.AnyBreak, WIDTH);
		Assert.equals(0, votes(list), 'no slot survives the decision');
		Assert.equals(2, verdicts(list), 'both siblings carry the forced verdict');
	}

	/** `Off` writes no slot and decides nothing: the Doc comes back as it went in. */
	public function testOffIsTheOwnForm(): Void {
		final own: Doc = Doc.Text('c');
		Assert.equals(own, SiblingShare.placedSlot(SiblingPolicy.Off, true, own));
		final list: Doc = listOf([own]);
		Assert.equals(list, SiblingShare.decide(list, SiblingPolicy.Off, WIDTH));
	}

	/** A negative width is a vote only inside the band `SiblingShare` writes: another number keeps its place. */
	@:pin('control')
	@:killer('M-SIBLING-VOTE-ANY-NEGATIVE')
	public function testANegativeWidthOutsideTheBandIsNoVote(): Void {
		final measured: Doc = Doc.IfIndentWidthExceeds(NO_WIDTH, WIDTH, Doc.Text('b'), Doc.Text('f'));
		final list: Doc = SiblingShare.decide(listOf([measured, Doc.Text('x')]), SiblingPolicy.AnyBreak, WIDTH);
		Assert.equals(1, count(list, width -> width == NO_WIDTH), 'the number is left where it was');
	}

	private static function slot(body: String): Doc {
		return SiblingShare.fitLineSlot(SiblingPolicy.AnyBreak, 1, Doc.Text(body), false, WIDTH, false);
	}

	private static function listOf(items: Array<Doc>): Doc {
		return Doc.Concat(items);
	}

	/** A slot left unresolved: every vote sits below `NO_WIDTH`. */
	private static function votes(d: Doc): Int {
		return count(d, width -> width < NO_WIDTH);
	}

	private static function verdicts(d: Doc): Int {
		return count(d, width -> width >= 0);
	}

	/** The number of width probes of `d` whose width answers `pred`, each probe's flat form walked once. */
	private static function count(d: Doc, pred: Int -> Bool): Int {
		var found: Int = 0;
		function walk(n: Doc): Void {
			switch n {
				case Doc.IfIndentWidthExceeds(width, _, _, flat):
					if (pred(width)) found++;
					walk(flat);
				case _:
					D.mapChildrenShared(n, c -> {
						walk(c);
						c;
					});
			}
		}
		walk(d);
		return found;
	}

}
