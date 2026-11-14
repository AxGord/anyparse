package unit.core;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;

/** `DocMeasure.walkFlatLeaves` is the one flat-order walk: callers see visible leaves left to right,
* the flat side of every `If*`, and no forced hardline. */
@:nullSafety(Strict)
class FlatLeafWalkTest extends Test {

	/** An `If*` contributes its flat side, not its broken side. */
	@:pin('control')
	@:killer('M-FLATLEAF-IF-FLAT-SIDE')
	public function testIfContributesItsFlatSide(): Void {
		Assert.same(['a', 'f', 'z'], leaves(Concat([Text('a'), IfBreak(Text('B'), Text('f')), Text('z')])));
	}

	/** A forced hardline is not a leaf; a soft line and an `OptSpace` are. */
	@:pin('control')
	@:killer('M-FLATLEAF-HARDLINE')
	public function testHardlineIsNotALeaf(): Void {
		Assert.same(['a', ' ', '_', 'z'], leaves(Concat([Text('a'), Line('\n'), Line(' '), OptSpace('_'), Text('z')])));
	}

	/** A leaf answering true ends the walk: later leaves are never visited. */
	@:pin('control')
	@:killer('M-FLATLEAF-STOP')
	public function testTrueStopsTheWalk(): Void {
		Assert.same(['a', 'b'], leaves(Concat([Text('a'), Text('b'), Text('c')]), 'b'));
	}

	private static function leaves(d: Doc, ?stopAt: String): Array<String> {
		final out: Array<String> = [];
		DocMeasure.walkFlatLeaves(d, leaf -> {
			final s: String = switch leaf {
				case Text(t, _, _), Line(t), OptSpace(t): t;
				case _: '';
			};
			out.push(s);
			return s == stopAt;
		});
		return out;
	}

}
