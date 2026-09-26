package unit.core;

import anyparse.core.Doc;
import anyparse.core.Renderer;
import haxe.Timer;
import utest.Assert;
import utest.Test;

/**
 * The renderer's search for a collapse candidate's `CollapseProbe` walks a Doc that is a DAG: a
 * two-branch ctor's branches share their operands, and a nest of them shares at every level. A
 * search that revisits a shared node pays `2^depth` — the nest below holds 49 distinct nodes and
 * `2^24` paths.
 *
 * utest has no operation counter to hand here, so the fixture bounds the CLOCK, with a margin of
 * orders of magnitude on both sides: the deduplicated search answers in microseconds, a revisiting
 * one takes seconds.
 */
@:nullSafety(Strict)
@:access(anyparse.core.Renderer)
final class RendererSharedDocTest extends Test {

	private static inline final DEPTH: Int = 24;
	private static inline final BUDGET_SECONDS: Float = 0.5;

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-PROBE-SEARCH-REVISITS')
	public function testProbeSearchVisitsASharedNodeOnce(): Void {
		var d: Doc = Text('x');
		for (_ in 0...DEPTH) d = IfBreak(Nest(1, d), d);
		final start: Float = Timer.stamp();
		final probe: Null<{ inner: Doc, hard: Bool }> = Renderer.findCollapseProbe(d);
		final elapsed: Float = Timer.stamp() - start;
		Assert.isNull(probe, 'the nest holds no probe');
		Assert.isTrue(elapsed < BUDGET_SECONDS, 'the search took ${elapsed}s over a nest of $DEPTH shared levels');
	}

	public function testTheSearchStillFindsAProbeBehindASharedNode(): Void {
		final shared: Doc = Concat([Text('a'), CollapseProbe(HardFlatten(Text('b')))]);
		final probe: Null<{ inner: Doc, hard: Bool }> = Renderer.findCollapseProbe(IfBreak(Nest(1, shared), shared));
		Assert.notNull(probe);
		Assert.isTrue(probe != null && probe.hard);
	}

}
