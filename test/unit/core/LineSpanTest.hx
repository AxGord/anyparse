package unit.core;

import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.LineSpan;
import anyparse.core.Renderer;

/**
 * `LineSpan` read directly through the renderer: `ifLeft` takes `left` only when a line was written since a `begin`
 * of this render, on a frame free to break.
 */
final class LineSpanTest extends Test {

	private static inline final WIDTH: Int = 80;

	public function testLeftAfterALineBreakSinceBegin(): Void {
		Assert.equals('a\nL', Renderer.render(D.concat([LineSpan.begin(), D.text('a'), D.hardline(), read()]), WIDTH));
	}

	public function testSameWithNoLineBreakSinceBegin(): Void {
		Assert.equals('x\naS', Renderer.render(D.concat([D.text('x'), D.hardline(), LineSpan.begin(), D.text('a'), read()]), WIDTH));
	}

	/** A forced-flat frame cannot take the side that breaks, whatever the record says. */
	@:pin('control')
	@:killer('M-LINE-SPAN-BREAKS-FORCED-FLAT')
	public function testAForcedFlatFrameKeepsSame(): Void {
		final doc: Doc = Doc.Flatten(D.concat([LineSpan.begin(), D.text('a\nb'), read()]));
		Assert.equals('a\nbS', Renderer.render(doc, WIDTH));
	}

	/** A line written with no `begin` in the render is nothing the read can compare against. */
	@:pin('control')
	@:killer('M-LINE-SPAN-READS-WITHOUT-BEGIN')
	public function testNoBeginKeepsSame(): Void {
		Assert.equals('a\nS', Renderer.render(D.concat([D.text('a'), D.hardline(), read()]), WIDTH));
	}

	private static inline function read(): Doc {
		return LineSpan.ifLeft(D.text('L'), D.text('S'));
	}

}
