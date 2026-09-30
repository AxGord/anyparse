package unit.core;

import anyparse.core.Doc;
import anyparse.core.Renderer;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A paren-open probe measures the rest of its line up to where a later construct
 * breaks by itself, and a later probe inside a force-flat region can never break.
 * Built as a Doc directly: no writer producer places a probe after the asker in a
 * force-flat FRAME today, so only a hand-built nest reaches the frame-level guard. The same holds for the
 * other shapes here: a soft break under a boundary in the asker, a paren on an
 * unresolved probe's flat side, consecutive held-back spaces, a `LeadingBreak`.
 */
@:nullSafety(Strict)
@:access(anyparse.core.Renderer)
final class RendererParenSiblingRestTest extends Test {

	private static inline final WIDTH: Int = 20;
	private static inline final WIDE: Int = 40;

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

	/**
	 * The asker's content is a soft break under a `WrapBoundary` inside a `Flatten`:
	 * render ends the force-flat region at the boundary and restores break mode, so
	 * that break is a newline and the columns after the asker are not the measured
	 * ones. The call after it must not be taken as the line's end.
	 */
	@:pin('control')
	@:killer('M-PAREN-EXACT-SOFT-BOUNDARY')
	public function testASoftBreakUnderABoundaryInsideFlattenIsNotMeasured(): Void {
		final content: Doc = Flatten(WrapBoundary(Concat([Text('aaa'), Line(' '), Text('bbb')])));
		final doc: Doc = Concat([
			Text('x = '),
			parenOf(WIDE, Text('aaa bbb'), content),
			Text(' / '),
			call(25),
			Text('.m(xxx)')
		]);
		Assert.equals('x = (\n  aaa bbb\n) / f(aaaaaaaaaaaaaaaaaaaaaaaaa).m(xxx)', Renderer.render(doc, WIDE));
	}

	/**
	 * A later paren on the FLAT side of an `IfLineExceeds` the walk does not resolve
	 * ends the line only on that side: render may take the break side, whose head
	 * runs on past the paren's column, so the line is measured on the wider route.
	 */
	@:pin('control')
	@:killer('M-PAREN-ALT-ROUTE')
	public function testAParenOnAnUnresolvedFlatSideIsNoBreakPoint(): Void {
		final head: String = 'g(' + ''.lpad('b', 25) + ',';
		final breakSide: Doc = Concat([Text(head), Nest(2, Concat([Line('\n'), Text('z)')]))]);
		final flatSide: Doc = Concat([Text('g'), parenOf(WIDE, Text(''.lpad('b', 25)))]);
		final doc: Doc = Concat([
			Text('x = '),
			parenOf(WIDE, Text('aaaa')),
			Text(' / '),
			IfLineExceeds(WIDE + 1, breakSide, flatSide),
			Text(';')
		]);
		Assert.equals('x = (\n  aaaa\n) / g(bbbbbbbbbbbbbbbbbbbbbbbbb);', Renderer.render(doc, WIDE));
	}

	/**
	 * Two held-back `OptSpace`s both land before a plain group that render fits
	 * without them, so the walk must hold back both: holding back only the last put
	 * the group one column too far right, predicted its break, glued the asker, and
	 * the line overflowed.
	 */
	@:pin('control')
	@:killer('M-PAREN-PENDING-LAST-ONLY')
	public function testConsecutiveHeldBackSpacesAllStayOutOfTheColumn(): Void {
		final doc: Doc = Concat([
			Text('x = '),
			parenOf(WIDE, Text('aaaa')),
			OptSpace(' '),
			OptSpace(' '),
			call(27, 'b'),
			Text(';')
		]);
		Assert.equals('x = (\n  aaaa\n)  f(bbbbbbbbbbbbbbbbbbbbbbbbbbb);', Renderer.render(doc, WIDE));
	}

	/**
	 * An unresolved probe whose break side cannot be bounded (a verbatim multi-line
	 * token) takes the walk off the rendered path: no later paren ends the line.
	 */
	@:pin('control')
	@:killer('M-PAREN-SIBLING-OFF-PATH')
	public function testAnUnboundedBreakSideTakesTheWalkOffThePath(): Void {
		final b25: String = ''.lpad('b', 25);
		final unbounded: Doc = IfLineExceeds(WIDE + 1, Text('g($b25,\nz)'), Concat([Text('g'), parenOf(WIDE, Text(b25))]));
		final doc: Doc = Concat([Text('x = '), parenOf(WIDE, Text('aaaa')), Text(' / '), unbounded, Text(';')]);
		Assert.equals('x = (\n  aaaa\n) / g(bbbbbbbbbbbbbbbbbbbbbbbbb);', Renderer.render(doc, WIDE));
	}

	/**
	 * A group whose fit render decides on its tail may break, and its break route
	 * runs on with the wider side of an `IfBreak`: the line is measured with that
	 * surplus, so the asker opens instead of gluing into a 41-column line.
	 */
	@:pin('control')
	@:killer('M-PAREN-ALT-SURPLUS')
	public function testARunOnBreakRouteWidensTheLine(): Void {
		final runOn: Doc = GroupWithRestProbe(Concat([Text('h'), IfBreak(Text(''.lpad('c', 26)), Empty)]));
		final doc: Doc = Concat([
			Text('x = '),
			parenOf(WIDE, Text('aaaa')),
			Text(' / '),
			runOn,
			parenOf(WIDE, Text(''.lpad('b', 20))),
			Text(';;;;;;;;;;')
		]);
		Assert.equals('x = (\n  aaaa\n) / h(bbbbbbbbbbbbbbbbbbbb);;;;;;;;;;', Renderer.render(doc, WIDE));
	}

	/**
	 * The later paren sits on the flat side of an `IfLineExceeds` whose break side
	 * runs on without breaking: if render takes it, what follows the node lands on
	 * the same line, which no prediction made inside the node would count. The walk
	 * ends nowhere inside it, and the asker opens.
	 */
	@:pin('control')
	@:killer('M-PAREN-RUNON-SUSPEND')
	public function testARunOnRouteSuspendsPredictionsInsideItsNode(): Void {
		final runOn: Doc = IfLineExceeds(
			WIDE + 1, Text('g[' + ''.lpad('b', 20) + ']'), Concat([Text('g'), parenOf(WIDE, Text(''.lpad('b', 25)))])
		);
		final doc: Doc = Concat([Text('x = '), parenOf(WIDE, Text('aaaa')), Text(' / '), runOn, Text(' + ccccc;')]);
		Assert.equals('x = (\n  aaaa\n) / g[bbbbbbbbbbbbbbbbbbbb] + ccccc;', Renderer.render(doc, WIDE));
	}

	/**
	 * The suspension a run-on route puts on its node's subtree ends with that node:
	 * a later paren AFTER it still ends the line, so the asker stays glued.
	 */
	@:pin('control')
	@:killer('M-PAREN-RUNON-RESUME')
	public function testASuspensionEndsWithTheNodeItCovers(): Void {
		// The rest shares ONE frame, so the walk leaves the node by popping below it
		// rather than by moving to the next frame.
		final doc: Doc = Concat([
			Text('x = '),
			parenOf(WIDE, Text('aaaa')),
			Concat([
				Text(' / '),
				IfLineExceeds(WIDE + 1, Text('mm'), Text('m')),
				Text(' / '),
				parenOf(WIDE, Text(''.lpad('b', 24))),
				Text(';')
			])
		]);
		Assert.equals('x = (aaaa) / mm / (\n  bbbbbbbbbbbbbbbbbbbbbbbb\n);', Renderer.render(doc, WIDE));
	}

	/** Across frames: the node's frame is left, and its suspension with it. */
	@:pin('control')
	@:killer('M-PAREN-RUNON-FRAME')
	public function testASuspensionEndsWithItsFrame(): Void {
		final doc: Doc = Concat([
			Text('x = '),
			parenOf(WIDE, Text('aaaa')),
			Text(' / '),
			IfLineExceeds(WIDE + 1, Text('mm'), Text('m')),
			Text(' / '),
			parenOf(WIDE, Text(''.lpad('b', 24))),
			Text(';')
		]);
		Assert.equals('x = (aaaa) / mm / (\n  bbbbbbbbbbbbbbbbbbbbbbbb\n);', Renderer.render(doc, WIDE));
	}

	/**
	 * `LeadingBreak` renders its break outside a force-flat region and only its
	 * content inside one, so it keeps the asker's column exact only there, and in
	 * the rest it ends the column predictions.
	 */
	public function testALeadingBreakIsExactOnlyInsideAForceFlatRegion(): Void {
		final lead: Doc = LeadingBreak(2, Text('bb'));
		Assert.isFalse(Renderer.rendersAsMeasured(Concat([Text('aa'), lead])), 'outside a region its break is rendered');
		Assert.isTrue(Renderer.rendersAsMeasured(Flatten(Concat([Text('aa'), lead]))), 'inside one it is its content alone');
		Assert.isFalse(Renderer.keepsColumnExact(lead, false), 'in the rest it ends the predictions');
	}

	/** A hard region survives a `WrapBoundary`, so the soft break under it stays flat. */
	public function testASoftBreakUnderABoundaryInsideHardFlattenIsMeasured(): Void {
		final soft: Doc = WrapBoundary(Concat([Text('aaa'), Line(' '), Text('bbb')]));
		Assert.isTrue(Renderer.rendersAsMeasured(HardFlatten(soft)));
		Assert.isFalse(Renderer.rendersAsMeasured(Flatten(soft)));
	}

	private static function paren(inner: String): Doc {
		return parenOf(WIDTH, Text(inner));
	}

	private static function parenOf(width: Int, inner: Doc, ?flatInner: Doc): Doc {
		return IfFullLineExceeds(
			width + 1, Concat([Text('('), Nest(2, Concat([Line('\n'), inner])), Line('\n'), Text(')')]),
			Concat([Text('('), flatInner ?? inner, Text(')')])
		);
	}

	private static function call(argWidth: Int, fill: String = 'a'): Doc {
		return Group(Concat([
			Text('f('),
			Nest(2, Concat([Line(''), Text(''.lpad(fill, argWidth))])),
			Line(''),
			Text(')')
		]));
	}

}
