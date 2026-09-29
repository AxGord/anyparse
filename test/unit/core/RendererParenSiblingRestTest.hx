package unit.core;

import anyparse.core.Doc;
import anyparse.core.Renderer;
import utest.Assert;
import utest.Test;

/**
 * A paren-open probe measures the rest of its line up to where a later construct
 * breaks by itself, and a later probe inside a force-flat region can never break.
 * Built as a Doc directly: no writer producer places a probe after the asker in a
 * force-flat FRAME today, so only a hand-built nest reaches the frame-level guard.
 */
@:nullSafety(Strict)
final class RendererParenSiblingRestTest extends Test {

	private static inline final WIDTH: Int = 20;

	public function new(): Void {
		super();
	}

	/**
	 * The asker sits under a `WrapBoundary` inside a `Flatten`, so the frames after
	 * it are force-flat: the second paren renders flat whatever its line, is no
	 * break point, and the first paren is the only thing that can shorten the line.
	 */
	@:pin('control')
	@:killer('M-PAREN-SIBLING-FORCE-FLAT-FRAME')
	public function testAProbeInAForceFlatFrameIsNoBreakPoint(): Void {
		final doc: Doc = Flatten(Concat([
			WrapBoundary(Concat([Text('x = '), paren('aaaa')])),
			Text(' / '),
			paren('bbbbbbbbbb')
		]));
		Assert.equals('x = (\n  aaaa\n) / (bbbbbbbbbb)', Renderer.render(doc, WIDTH));
	}

	/** Without the force-flat region the second paren is a break point, and it is the one that opens. */
	public function testTheSameProbeOutsideTheRegionIsABreakPoint(): Void {
		final doc: Doc = Concat([Text('x = '), paren('aaaa'), Text(' / '), paren('bbbbbbbbbb')]);
		Assert.equals('x = (aaaa) / (\n  bbbbbbbbbb\n)', Renderer.render(doc, WIDTH));
	}

	private static function paren(inner: String): Doc {
		return IfFullLineExceeds(
			WIDTH + 1, Concat([Text('('), Nest(2, Concat([Line('\n'), Text(inner)])), Line('\n'), Text(')')]),
			Concat([Text('('), Text(inner), Text(')')])
		);
	}

}
