package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.CallGraph;
import anyparse.query.CallGraph.CallEdge;
import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.Reach;

/**
 * The approximate call graph behind `apq callees` / `callers` / `reach` and
 * the `thread-safety` check: bare / `this.` / receiver-typed / static call
 * resolution, `Null<T>` receiver unwrap, virtual dispatch over-approximation,
 * `Ref` edges for lambdas / method values / `.bind` with their `via` seam,
 * external nodes for out-of-scope targets, and honest `unresolved` recording.
 */
class CallGraphTest extends Test {

	public function testBareCallResolvesToSameClassMethod(): Void {
		final g: CallGraph = graphOf(['class A { function a():Void b(); function b():Void {} }']);
		Assert.equals(1, edges(g, 'A.a', 'A.b', Call).length);
	}

	public function testThisCallResolves(): Void {
		final g: CallGraph = graphOf(['class A { function a():Void this.b(); function b():Void {} }']);
		Assert.equals(1, edges(g, 'A.a', 'A.b', Call).length);
	}

	public function testLocalFunctionCallAndContains(): Void {
		final g: CallGraph = graphOf(['class A { function a():Void { function helper():Void {} helper(); } }']);
		Assert.equals(1, edges(g, 'A.a', 'A.a#helper', Call).length);
		Assert.equals(1, edges(g, 'A.a', 'A.a#helper', Contains).length);
	}

	public function testAnnotatedReceiverResolvesAcrossFiles(): Void {
		final g: CallGraph = graphOf([
			'class A { private final _w:Worker; function a():Void _w.run(); }',
			'class Worker { public function run():Void {} }',
		]);
		Assert.equals(1, edges(g, 'A.a', 'Worker.run', Call).length);
	}

	public function testNullWrappedReceiverUnwraps(): Void {
		final g: CallGraph = graphOf([
			'class A { private var _w:Null<Worker>; function a():Void _w.run(); }',
			'class Worker { public function run():Void {} }',
		]);
		Assert.equals(1, edges(g, 'A.a', 'Worker.run', Call).length);
	}

	public function testStaticCallOnKnownType(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void Util.go(); }',
			'class Util { public static function go():Void {} }',
		]);
		Assert.equals(1, edges(g, 'A.a', 'Util.go', Call).length);
	}

	public function testUnknownStaticBecomesExternalNode(): Void {
		final g: CallGraph = graphOf(['class A { function a():Void Sys.sleep(1); }']);
		Assert.equals(1, edges(g, 'A.a', 'Sys.sleep', Call).length);
		final node: Null<FnNode> = g.node('Sys.sleep');
		Assert.notNull(node);
		if (node != null) Assert.isTrue(node.isExternal);
	}

	public function testInheritedBareCallResolvesThroughSupertype(): Void {
		final g: CallGraph = graphOf([
			'class Sub extends Base { function f():Void parentMethod(); }',
			'class Base { public function parentMethod():Void {} }',
		]);
		Assert.equals(1, edges(g, 'Sub.f', 'Base.parentMethod', Call).length);
	}

	public function testVirtualEdgeToSubtypeOverride(): Void {
		final g: CallGraph = graphOf([
			'class A { private final _b:Base; function a():Void _b.run(); }',
			'class Base { public function run():Void {} }',
			'class Sub extends Base { override public function run():Void {} }',
		]);
		Assert.equals(1, edges(g, 'A.a', 'Base.run', Call).length);
		Assert.equals(1, edges(g, 'A.a', 'Sub.run', Virtual).length);
	}

	public function testLambdaArgGetsRefEdgeWithVia(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void Runner.create(() -> work()); function work():Void {} }',
			'class Runner { public static function create(fn:()->Void):Void {} }',
		]);
		final refs: Array<CallEdge> = [for (e in g.outEdges('A.a')) if (e.kind == Ref) e];
		Assert.equals(1, refs.length);
		Assert.equals('Runner.create', refs[0].via);
		Assert.equals(1, edges(g, refs[0].to, 'A.work', Call).length);
	}

	public function testMethodValueArgGetsRefEdge(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void listen(handler); function listen(fn:()->Void):Void {} function handler():Void {} }',
		]);
		final refs: Array<CallEdge> = edges(g, 'A.a', 'A.handler', Ref);
		Assert.equals(1, refs.length);
		Assert.equals('A.listen', refs[0].via);
	}

	public function testBindArgGetsRefEdgeWithVia(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void Timer.delay(tick.bind(1), 10); function tick(n:Int):Void {} }',
		]);
		final refs: Array<CallEdge> = edges(g, 'A.a', 'A.tick', Ref);
		Assert.equals(1, refs.length);
		Assert.equals('Timer.delay', refs[0].via);
	}

	public function testNewEdge(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void { final w:Worker = new Worker(); } }',
			'class Worker { public function new() {} }',
		]);
		Assert.equals(1, edges(g, 'A.a', 'Worker.new', New).length);
	}

	public function testIndirectCallRecordedAsUnresolved(): Void {
		final g: CallGraph = graphOf(['class A { function a(fn:()->Void):Void fn(); }']);
		Assert.isTrue(g.unresolved.length > 0);
		Assert.equals(0, g.outEdges('A.a').length);
	}

	public function testResolveTargetBareAndQualified(): Void {
		final g: CallGraph = graphOf([
			'class A { function run():Void {} }',
			'class B { function run():Void {} }',
		]);
		Assert.equals(2, g.resolveTarget('run').length);
		Assert.equals(1, g.resolveTarget('A.run').length);
		Assert.equals(1, g.resolveTarget('pkg.sub.A.run').length);
	}

	public function testMatchIdsWildcard(): Void {
		final g: CallGraph = graphOf(['class A { function x():Void {} function y():Void {} }']);
		Assert.equals(2, g.matchIds('A.*').length);
	}

	public function testReachFindsShortestPath(): Void {
		final g: CallGraph = graphOf(['class A { function a():Void b(); function b():Void Sys.sleep(1); }',]);
		final paths: Array<Array<CallEdge>> = Reach.paths(g, ['A.a'], ['Sys.sleep'], 10, [Call, Ref, New, Virtual]);
		Assert.equals(1, paths.length);
		Assert.equals(2, paths[0].length);
		Assert.equals('A.b', paths[0][1].from);
	}

	public function testFieldInitializerCallsLandOnInitNode(): Void {
		final g: CallGraph = graphOf([
			'class A { private final _x:Int = compute(); static function compute():Int return 1; }'
		]);
		Assert.equals(1, edges(g, 'A.<init>', 'A.compute', Call).length);
	}

	public function testSkipParseNoCrash(): Void {
		final g: CallGraph = graphOf(['class A { function f() { ']);
		Assert.equals(1, g.skippedFiles.length);
		Assert.equals(0, g.edges.length);
	}

	public function testSuperCtorCallResolves(): Void {
		final g: CallGraph = graphOf([
			'class Sub extends Base { public function new() super(); }',
			'class Base { public function new() {} }',
		]);
		Assert.equals(1, edges(g, 'Sub.new', 'Base.new', Call).length);
		Assert.equals(0, [for (u in g.unresolved) if (u.reason.indexOf('super') != -1) u].length);
	}

	public function testMacroReificationNotWalked(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():haxe.macro.Expr return macro { work(); }; function work():Void {} }'
		]);
		Assert.equals(0, edges(g, 'A.a', 'A.work', Call).length);
	}

	public function testMacroModifierFunctionNotWalked(): Void {
		// A `macro`-modified function is compile-time code — it is neither registered as a
		// node nor its body walked, so no call edge is fabricated from it.
		final g: CallGraph = graphOf(['class A { macro static function m() { work(); } function work():Void {} }']);
		Assert.isNull(g.node('A.m'));
		Assert.equals(0, edges(g, 'A.m', 'A.work', Call).length);
	}

	private function graphOf(sources: Array<String>): CallGraph {
		return QueryTestHelpers.graphOf(sources);
	}

	private function edges(g: CallGraph, from: String, to: String, kind: EdgeKind): Array<CallEdge> {
		return [for (e in g.outEdges(from)) if (e.to == to && e.kind == kind) e];
	}

}
