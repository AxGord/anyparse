package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphTypes;
import anyparse.query.Reach;
import anyparse.query.SymbolIndex;
import utest.Assert;
import utest.Test;

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
			'class Worker { public function run():Void {} }'
		]);
		Assert.equals(1, edges(g, 'A.a', 'Worker.run', Call).length);
	}

	public function testCallReceiverWithDeclaredReturnTypeResolves(): Void {
		// Both receiver forms in one test: the field `_w` and the accessor `getWorker()` name the
		// SAME declared type, so a fix that reads one form must not be able to lose the other.
		final g: CallGraph = graphOf([
			'class A { private final _w:Worker; function viaField():Void _w.run(); function getWorker():Worker return _w; function viaCall():Void getWorker().run(); }',
			'class Worker { public function run():Void {} }'
		]);
		Assert.equals(1, edges(g, 'A.viaField', 'Worker.run', Call).length);
		Assert.equals(1, edges(g, 'A.viaCall', 'Worker.run', Call).length);
		Assert.equals(0, [for (u in g.unresolved) if (u.reason.match(UnresolvedReceiver(_))) u].length);
	}

	public function testChainedCallReceiversResolveStepByStep(): Void {
		// Each hop reads ONE declared return type - the recursion the receiver arm brings with it,
		// not type inference; a hop whose callee carries no annotation ends the chain.
		final g: CallGraph = graphOf([
			'class A { function a():Void getMid().getWorker().run(); function getMid():Mid return null; }',
			'class Mid { public function getWorker():Worker return null; public function loose() return null; }',
			'class Worker { public function run():Void {} }'
		]);
		Assert.equals(1, edges(g, 'A.a', 'Worker.run', Call).length);
		final loose: CallGraph = graphOf([
			'class A { function a():Void getMid().loose().run(); function getMid():Mid return null; }',
			'class Mid { public function loose() return null; }',
			'class Worker { public function run():Void {} }'
		]);
		Assert.equals(0, edges(loose, 'A.a', 'Worker.run', Call).length);
		Assert.equals(1, [for (u in loose.unresolved) if (u.reason.match(UnresolvedReceiver(_))) u].length);
	}

	public function testNullableReturnReceiverStaysUnresolved(): Void {
		// `returnTypes` reports the OUTER nominal, so a `Null<T>` return names no dispatchable
		// type and there is no return-type SOURCE map to unwrap it with - refuse over a guess.
		final g: CallGraph = graphOf([
			'class A { function a():Void getWorker().run(); function getWorker():Null<Worker> return null; }',
			'class Worker { public function run():Void {} }'
		]);
		Assert.equals(0, edges(g, 'A.a', 'Worker.run', Call).length);
		Assert.equals(1, [for (u in g.unresolved) if (u.reason.match(UnresolvedReceiver(_))) u].length);
	}

	public function testNullWrappedReceiverUnwraps(): Void {
		final g: CallGraph = graphOf([
			'class A { private var _w:Null<Worker>; function a():Void _w.run(); }',
			'class Worker { public function run():Void {} }'
		]);
		Assert.equals(1, edges(g, 'A.a', 'Worker.run', Call).length);
	}

	public function testStaticCallOnKnownType(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void Util.go(); }',
			'class Util { public static function go():Void {} }'
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
			'class Base { public function parentMethod():Void {} }'
		]);
		Assert.equals(1, edges(g, 'Sub.f', 'Base.parentMethod', Call).length);
	}

	public function testVirtualEdgeToSubtypeOverride(): Void {
		final g: CallGraph = graphOf([
			'class A { private final _b:Base; function a():Void _b.run(); }',
			'class Base { public function run():Void {} }',
			'class Sub extends Base { override public function run():Void {} }'
		]);
		Assert.equals(1, edges(g, 'A.a', 'Base.run', Call).length);
		Assert.equals(1, edges(g, 'A.a', 'Sub.run', Virtual).length);
	}

	public function testBareCallGetsSameVirtualEdgeAsThisCall(): Void {
		// One variable: `hook()` vs `this.hook()`. A bare call to an INSTANCE member of the
		// enclosing type IS an implicit-`this` call, so it dispatches the same way.
		final g: CallGraph = graphOf([
			'class Base { public function hook():Void {} public function drive():Void hook(); public function driveThis():Void this.hook(); }',
			'class Sub extends Base { override public function hook():Void {} }'
		]);
		Assert.equals(1, edges(g, 'Base.driveThis', 'Sub.hook', Virtual).length);
		Assert.equals(1, edges(g, 'Base.drive', 'Sub.hook', Virtual).length);
	}

	public function testBareCallOnAbstractMemberReachesImplementation(): Void {
		// An `abstract` declaration has NO body, so without the virtual edge the chain from its
		// call sites into the implementation is broken in both directions.
		final g: CallGraph = graphOf([
			'abstract class Base { abstract private function hook():Void; public function drive():Void hook(); }',
			'class Sub extends Base { private function hook():Void work(); function work():Void {} }'
		]);
		Assert.equals(1, edges(g, 'Base.drive', 'Base.hook', Call).length);
		Assert.equals(1, edges(g, 'Base.drive', 'Sub.hook', Virtual).length);
	}

	@:pin('control') @:killer('M-GRAPH-STATIC-NO-VIRTUAL')
	public function testBareStaticCallGetsNoVirtualEdge(): Void {
		// Haxe does not inherit or override statics, so a same-named static on a subtype is a
		// DIFFERENT function - a virtual edge there would be fabricated.
		final g: CallGraph = graphOf([
			'class Base { public static function helper():Void {} public function drive():Void helper(); }',
			'class Sub extends Base { public static function helper():Void {} }'
		]);
		Assert.equals(1, edges(g, 'Base.drive', 'Base.helper', Call).length);
		Assert.equals(0, edges(g, 'Base.drive', 'Sub.helper', Virtual).length);
	}

	public function testBareLocalFunctionCallGetsNoVirtualEdge(): Void {
		// A local function shadowing a member name resolves to the local - nothing to dispatch.
		final g: CallGraph = graphOf([
			'class Base { public function hook():Void {} public function drive():Void { function hook():Void {} hook(); } }',
			'class Sub extends Base { override public function hook():Void {} }'
		]);
		Assert.equals(1, edges(g, 'Base.drive', 'Base.drive#hook', Call).length);
		Assert.equals(0, edges(g, 'Base.drive', 'Sub.hook', Virtual).length);
	}

	public function testLambdaArgGetsRefEdgeWithVia(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void Runner.create(() -> work()); function work():Void {} }',
			'class Runner { public static function create(fn:()->Void):Void {} }'
		]);
		final refs: Array<CallEdge> = [for (e in g.outEdges('A.a')) if (e.kind == Ref) e];
		Assert.equals(1, refs.length);
		Assert.equals('Runner.create', refs[0].via);
		Assert.equals(1, edges(g, refs[0].to, 'A.work', Call).length);
	}

	public function testMethodValueArgGetsRefEdge(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void listen(handler); function listen(fn:()->Void):Void {} function handler():Void {} }'
		]);
		final refs: Array<CallEdge> = edges(g, 'A.a', 'A.handler', Ref);
		Assert.equals(1, refs.length);
		Assert.equals('A.listen', refs[0].via);
	}

	public function testBindArgGetsRefEdgeWithVia(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void Timer.delay(tick.bind(1), 10); function tick(n:Int):Void {} }'
		]);
		final refs: Array<CallEdge> = edges(g, 'A.a', 'A.tick', Ref);
		Assert.equals(1, refs.length);
		Assert.equals('Timer.delay', refs[0].via);
	}

	public function testNewEdge(): Void {
		final g: CallGraph = graphOf([
			'class A { function a():Void { final w:Worker = new Worker(); } }',
			'class Worker { public function new() {} }'
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
			'class B { function run():Void {} }'
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
		final g: CallGraph = graphOf(['class A { function a():Void b(); function b():Void Sys.sleep(1); }']);
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
			'class Base { public function new() {} }'
		]);
		Assert.equals(1, edges(g, 'Sub.new', 'Base.new', Call).length);
		Assert.equals(0, [for (u in g.unresolved) if (u.reason.match(UnboundName('super'))) u].length);
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

	@:pin('control') @:killer('M-GRAPH-DYNAMIC-RECEIVER') @:killer('M-GRAPH-FIELD-FUNCTION-VALUE')
	public function testUnresolvedCallsCarryTheirReasonAndCaller(): Void {
		// A reachability walk admits different functions per reason, so the reasons must stay apart.
		final g: CallGraph = graphOf([
			'class A { var cb:() -> Void; function a(d:Dynamic, u):Void { cb(); this.cb(); d.run(); u.go(); nope(); } }'
		]);
		final reasons: Array<String> = [for (u in g.unresolved) if (u.from == 'A.a') Std.string(u.reason)];
		reasons.sort(Reflect.compare);
		Assert.equals(
			'DynamicReceiver(run),FunctionValue(cb),FunctionValue(cb),UnboundName(nope),UnresolvedReceiver(go)', reasons.join(',')
		);
	}

	@:pin('control') @:killer('M-GRAPH-SETTER-EDGE') @:killer('M-GRAPH-GETTER-EDGE') @:killer('M-GRAPH-ELEMENT-RECEIVER')
	@:killer('M-GRAPH-OWN-ACCESSOR-ANY-RECEIVER') @:killer('M-GRAPH-SETTER-READ-DIRECT')
	public function testPropertyAccessRunsItsAccessor(): Void {
		// A compound write reads AND writes.
		final g: CallGraph = graphOf([
			'class P { var other:P; @:isVar public var x(get, set):Int; function get_x():Int return x; '
			+ 'function set_x(v:Int):Int { trace(x); other.x = v; return x = v; } }',
			'class A { var p:P; var ps:Array<P>; function a():Void { p.x = 1; var y:Int = p.x; ps[0].x += 2; } }'
		]);
		Assert.equals(2, edges(g, 'A.a', 'P.set_x', Accessor).length);
		Assert.equals(2, edges(g, 'A.a', 'P.get_x', Accessor).length);
		// inside its own accessor the name is the stored field only for that accessor's own direction: a read
		// in the setter still runs the getter, and ANOTHER object's property runs its setter anywhere
		Assert.equals(0, edges(g, 'P.get_x', 'P.get_x', Accessor).length);
		Assert.equals(1, edges(g, 'P.set_x', 'P.get_x', Accessor).length);
		Assert.equals(1, edges(g, 'P.set_x', 'P.set_x', Accessor).length);
	}

	@:pin('control') @:killer('M-GRAPH-INIT-WIRING') @:killer('M-GRAPH-CTOR-OWN-INIT') @:killer('M-GRAPH-STATIC-INIT')
	public function testConstructionRunsTheInstanceInitializersOnly(): Void {
		// `Sub` declares no constructor, so `new Sub()` runs its initializers and then `Base.new`, which runs
		// `Base`'s; a STATIC initializer belongs to no constructor.
		final g: CallGraph = graphOf([
			'class Base { var b:Int = mk(); static var s:Int = st(); public function new() {} static function mk():Int return 1; '
			+ 'static function st():Int return 1; }',
			'class Sub extends Base { var c:Int = mk2(); static function mk2():Int return 1; }',
			'class A { function a():Void new Sub(); }'
		]);
		Assert.equals(1, edges(g, 'A.a', 'Sub.<init>', New).length);
		Assert.equals(1, edges(g, 'A.a', 'Base.new', New).length);
		Assert.equals(1, edges(g, 'Base.new', 'Base.<init>', Call).length);
		Assert.equals(1, edges(g, 'Base.<static>', 'Base.st', Call).length);
		Assert.equals(0, edges(g, 'Base.<init>', 'Base.st', Call).length);
	}

	@:pin('control') @:killer('M-GRAPH-VALUE-USE') @:killer('M-GRAPH-VALUE-USE-LAMBDA')
	public function testEveryValueUseOfAFunctionIsARef(): Void {
		final g: CallGraph = graphOf([
			'class A { var f:() -> Void; function a():Void f = h; function b():() -> Void return h; '
			+ 'function c():Void { var arr = [h]; var l = () -> 1; } function h():Void {} }'
		]);
		for (from in ['A.a', 'A.b', 'A.c']) Assert.equals(1, edges(g, from, 'A.h', Ref).length, from);
		Assert.equals(1, [for (e in g.outEdges('A.c')) if (e.kind == Ref && e.to.indexOf('#') >= 0) e].length);
	}

	@:pin('control') @:killer('M-GRAPH-FIELD-PATH-RECEIVER')
	public function testReceiverTypedThroughDeclaredMemberTypes(): Void {
		final g: CallGraph = graphOf([
			'class A extends Base { var w:Holder; function a():Void { w.worker.run(); inherited.run(); } }',
			'class Base { var inherited:Worker; }',
			'class Holder { public var worker:Worker; }',
			'class Worker { public function run():Void {} }'
		]);
		Assert.equals(2, edges(g, 'A.a', 'Worker.run', Call).length);
	}

	@:pin('control') @:killer('M-GRAPH-UPGRADE-EXTERNAL')
	public function testAddFilesUpgradesTheExternalPlaceholder(): Void {
		final a: { file: String, source: String } = { file: 'A.hx', source: 'class A { var w:Worker; function a():Void w.run(); }' };
		final w: { file: String, source: String } = {
			file: 'Worker.hx',
			source: 'class Worker { public function run():Void helper(); function helper():Void {} }'
		};
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final g: CallGraph = CallGraph.build([a], plugin, SymbolIndex.build([a, w], plugin));
		Assert.isTrue(g.node('Worker.run')?.isExternal == true);
		g.addFiles([w]);
		Assert.isTrue(g.node('Worker.run')?.isExternal == false);
		Assert.equals(1, edges(g, 'Worker.run', 'Worker.helper', Call).length);
		Assert.equals(1, edges(g, 'A.a', 'Worker.run', Call).length);
	}

	@:pin('control') @:killer('M-GRAPH-DYNAMIC-METHOD')
	public function testDynamicMethodCallIsAlsoAFunctionValueCall(): Void {
		// The body is the default; a reassignment runs another function, so both are recorded.
		final g: CallGraph = graphOf(['class A { dynamic function d():Void {} function a():Void d(); }']);
		Assert.equals(1, edges(g, 'A.a', 'A.d', Call).length);
		Assert.equals(1, [
			for (u in g.unresolved) if (u.from == 'A.a' && u.reason.match(FunctionValue('d'))) u
		].length);
	}

	@:pin('control') @:killer('M-GRAPH-ABSTRACT-THIS')
	public function testThisInsideAnAbstractIsTheUnderlyingValue(): Void {
		// `this.foo()` in `abstract Wrap(Under)` calls `Under.foo`; a bare `foo()` there is the abstract's own.
		final g: CallGraph = graphOf([
			'class Under { public function foo():Void {} }',
			'abstract Wrap(Under) { public function callsUnder():Void this.foo(); public function foo():Void {} public function bare():Void foo(); }'
		]);
		Assert.equals(1, edges(g, 'Wrap.callsUnder', 'Under.foo', Call).length);
		Assert.equals(0, edges(g, 'Wrap.callsUnder', 'Wrap.foo', Call).length);
		Assert.equals(1, edges(g, 'Wrap.bare', 'Wrap.foo', Call).length);
	}

	@:pin('control') @:killer('M-GRAPH-ABSTRACT-THIS-ALIAS')
	public function testThisInsideAnAbstractOverAnAliasIsTheAliasedType(): Void {
		// `abstract Rest<T>(NativeRest<T>)` over `typedef NativeRest<T> = Array<T>`: `this.copy()` calls the aliased type's
		// member — the std shape whose unresolved `this` calls made every conversion of it look like it could run anything.
		final g: CallGraph = graphOf([
			'class Under { public function foo():Void {} }',
			'private typedef Alias = Under; abstract Wrap(Alias) { public function callsUnder():Void this.foo(); }'
		]);
		Assert.equals(1, edges(g, 'Wrap.callsUnder', 'Under.foo', Call).length);
		Assert.equals(0, [for (u in g.unresolved) if (u.from == 'Wrap.callsUnder') u].length);
	}

	@:pin('control') @:killer('M-GRAPH-SUPERCLASS')
	public function testSuperIsTheSuperclassWhateverTheHeaderOrder(): Void {
		// `implements I extends A`: `super()` runs `A.new`, never the interface.
		final g: CallGraph = graphOf([
			'interface I {}',
			'class A { var a:Int = ia(); public function new() {} static function ia():Int return 1; }',
			'class D implements I extends A { public function new() { super(); } }'
		]);
		Assert.equals(1, edges(g, 'D.new', 'A.new', Call).length);
		Assert.isNull(g.node('I.new'));
	}

	@:pin('control') @:killer('M-GRAPH-SUPER-CTOR-RUN')
	public function testSuperCallRunsTheGeneratedConstructorsInitializers(): Void {
		// `B` declares no constructor, so `super()` in `C` runs `B`'s initializers and then `A.new`.
		final g: CallGraph = graphOf([
			'class A { public function new() {} }',
			'class B extends A { var b:Int = ib(); static function ib():Int return 1; }',
			'class C extends B { public function new() { super(); } }'
		]);
		Assert.equals(1, edges(g, 'C.new', 'B.<init>', Call).length);
	}

	@:pin('control') @:killer('M-GRAPH-WIRED-ONCE')
	public function testGrowingTheGraphAddsNoConstructorEdgeTwice(): Void {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final a: { file: String, source: String } = {
			file: 'A.hx',
			source: 'class A { var x:Int = f(); public function new() {} static function f():Int return 1; function g():Void new A(); }'
		};
		final g: CallGraph = CallGraph.build([a], plugin);
		final before: Int = g.edges.length;
		g.addFiles([{ file: 'B.hx', source: 'class B {}' }]);
		Assert.equals(before, g.edges.length);
	}

	@:pin('control') @:killer('M-GRAPH-SAFE-METHOD-VALUE')
	public function testMethodValueThroughNullSafeAccessIsARef(): Void {
		final g: CallGraph = graphOf([
			'class Base { public function run():Void {} }',
			'class Holder { var nb:Null<Base>; function safeArg():Void reg(nb?.run); function reg(f:Void->Void):Void {} }'
		]);
		Assert.equals(1, edges(g, 'Holder.safeArg', 'Base.run', Ref).length);
	}

	@:pin('control') @:killer('M-GRAPH-NEW-ARGS')
	public function testConstructorArgumentsHandOnEveryFunctionValue(): Void {
		// A ternary hands BOTH arms, and a `.bind` hands the bound method, to the constructor.
		final g: CallGraph = graphOf([
			'class Base { public function run():Void {} }',
			'class Taker { public function new(f:Void->Void) {} }',
			'class Holder { var b:Base; function tern(c:Bool):Void new Taker(c ? b.run : inst); function bound():Void new Taker(b.run.bind()); '
			+ 'function inst():Void {} }'
		]);
		Assert.equals(1, edges(g, 'Holder.tern', 'Base.run', Ref).length);
		Assert.equals(1, edges(g, 'Holder.tern', 'Holder.inst', Ref).length);
		Assert.equals(1, edges(g, 'Holder.bound', 'Base.run', Ref).length);
	}

	@:pin('control') @:killer('M-GRAPH-REF-OVERRIDES')
	public function testMethodValueReachesTheOverrides(): Void {
		// `reg(b.run)` hands over whatever `run` the value's run-time class has.
		final g: CallGraph = graphOf([
			'class Base { public function run():Void {} }',
			'class Sub extends Base { override public function run():Void {} }',
			'class Holder { var b:Base; function plain():Void reg(b.run); function reg(f:Void->Void):Void {} }'
		]);
		Assert.equals(1, edges(g, 'Holder.plain', 'Sub.run', Ref).length);
		Assert.equals('Base', edges(g, 'Holder.plain', 'Base.run', Ref)[0]?.dispatchType);
	}

	@:pin('control') @:killer('M-GRAPH-UNLOADED-METHOD-VALUE')
	public function testMethodValueOfATypeNotLoadedYetIsKept(): Void {
		// `f = L.handler` before `L`'s file arrives: a Ref to its placeholder, upgraded when it does.
		final a: { file: String, source: String } = {
			file: 'A.hx',
			source: 'class A { var f:Void->Void; function a():Void f = L.handler; }'
		};
		final l: { file: String, source: String } = { file: 'L.hx', source: 'class L { public static function handler():Void {} }' };
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final g: CallGraph = CallGraph.build([a], plugin, SymbolIndex.build([a, l], plugin));
		Assert.equals(1, edges(g, 'A.a', 'L.handler', Ref).length);
		g.addFiles([l]);
		Assert.isTrue(g.node('L.handler')?.isExternal == false);
	}

	@:pin('control') @:killer('M-GRAPH-CONSTRUCTION-LITERAL') @:killer('M-GRAPH-LITERAL-ARGUMENT') @:killer('M-GRAPH-LITERAL-ELEMENT')
	@:killer('M-GRAPH-LITERAL-RETURN') @:killer('M-GRAPH-LITERAL-ARMS') @:killer('M-GRAPH-LITERAL-REST') @:killer('M-GRAPH-LITERAL-LAMBDA')
	@:killer('M-GRAPH-LITERAL-MAP') @:killer('M-GRAPH-LITERAL-FIELD')
	public function testLiteralTypedAsAConstructedClassIsANew(): Void {
		// Wherever the written type says the literal is an `S` — a declaration, an argument, a return, an assignment,
		// an array element, a nullable, a field initializer — it runs `S`'s constructor.
		final g: CallGraph = graphOf([
			'@:structInit class S { public var x:Int; public function new(x:Int) this.x = x; }',
			'class M { var field:S = {x: 0}; function mk():Void { var s:S = {x: 1}; } function take(s:S):Void {} '
			+ 'function arg():Void take({x: 2}); function ret():S return {x: 3}; function assign():Void { var s:S; s = {x: 4}; } '
			+ 'function arr():Void { var a:Array<S> = [{x: 5}]; } function nul():Void { var n:Null<S> = {x: 6}; } '
			+ 'function sw(k:Int):S return switch k { case 0: {x: 7}; case _: { trace(k); {x: 8}; } }; '
			+ 'function ifE(c:Bool):S return if (c) {x: 9} else {x: 10}; function rest(...ss:S):Void {} '
			+ 'function restF():Void rest({x: 11}, {x: 12}); function lam():Void { final f:Void->S = () -> {x: 13}; } '
			+ 'function map():Void { final m:Map<String, S> = ["a" => {x: 14}]; } function anon():Void { final o:{s:S} = {s: {x: 15}}; } }'
		]);
		for (fn in [
			'M.mk',
			'M.arg',
			'M.ret',
			'M.assign',
			'M.arr',
			'M.nul',
			'M.<init>',
			'M.map',
			'M.anon',
			'M.lam#1'
		]) Assert.equals(1, edges(g, fn, 'S.new', New).length, fn);
		for (fn in ['M.sw', 'M.ifE', 'M.restF']) Assert.equals(2, edges(g, fn, 'S.new', New).length, fn);
	}

	@:pin('control') @:killer('M-GRAPH-CTOR-PLACEHOLDER')
	public function testConstructorNotLoadedYetIsTheOneTheChainDeclares(): Void {
		// `K` and `M` declare no constructor, `L` does: before any of them is loaded `new K()` already names `L.new`,
		// never a `K.new` nothing declares — and growing the graph in any order ends where building it at once does.
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final c: { file: String, source: String } = { file: 'C.hx', source: 'class C { function c():Void new K(); }' };
		final k: { file: String, source: String } = {
			file: 'K.hx',
			source: 'class K extends M { var v:Int = f(); static function f():Int return 1; }'
		};
		final m: { file: String, source: String } = {
			file: 'M.hx',
			source: 'class M extends L { var w:Int = h(); static function h():Int return 1; }'
		};
		final l: { file: String, source: String } = { file: 'L.hx', source: 'class L { public function new() {} }' };
		final g: CallGraph = CallGraph.build([c], plugin, SymbolIndex.build([c, k, m, l], plugin));
		Assert.equals(1, edges(g, 'C.c', 'L.new', New).length);
		Assert.isNull(g.node('K.new'));
		for (f in [k, m, l]) g.addFiles([f]);
		final all: CallGraph = CallGraph.build([c, k, m, l], plugin);
		final shape: CallGraph -> String -> Array<String> -> Void = (graph, from, out) ->
			for (e in graph.outEdges(from))
				out.push('${e.kind.label()}->${e.to}');
		final grown: Array<String> = [];
		final built: Array<String> = [];
		shape(g, 'C.c', grown);
		shape(all, 'C.c', built);
		grown.sort(Reflect.compare);
		built.sort(Reflect.compare);
		Assert.equals(built.join(','), grown.join(','));
	}

	@:pin('control') @:killer('M-GRAPH-SUPER-AMBIGUOUS')
	public function testSuperOfAnAmbiguousNameIsUnresolved(): Void {
		// Two types named `P`: which constructor `super()` runs is not provable by simple name.
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [
			{ file: 'a/P.hx', source: 'package a; class P { public function new() {} }' },
			{ file: 'b/P.hx', source: 'package b; class P { public function new() {} }' },
			{ file: 'C.hx', source: 'import a.P; class C extends P { public function new() { super(); } }' }
		];
		final g: CallGraph = CallGraph.build(files, plugin);
		Assert.equals(0, edges(g, 'C.new', 'P.new', Call).length);
		Assert.equals(1, [for (u in g.unresolved) if (u.from == 'C.new') u].length);
	}

	@:pin('control') @:killer('M-GRAPH-TYPE-ARGUMENT') @:killer('M-GRAPH-UNSUBSTITUTED-PARAM') @:killer('M-GRAPH-RETURN-PARAM')
	@:killer('M-GRAPH-FN-RETURN-PARAM') @:killer('M-GRAPH-INHERITED-ARGS') @:killer('M-GRAPH-CALL-ELEMENT')
	public function testTypeParametersInsideWrittenTypesAreSubstituted(): Void {
		// A class that happens to be named `T` is never what a member written with the parameter `T` holds: `Array<T>`,
		// `Null<T>` and a return `T` take the receiver's argument or the one `extends Box<W>` passes, and where there
		// is none the type is unknown.
		final g: CallGraph = graphOf([
			'class W { public function new() {} public function w():Void {} }',
			'class T { public function w():Void {} }',
			'class Box<T> { public var item:T; public var list:Array<T>; public var maybe:Null<T>; public function get():T return item; }',
			'class BoxW extends Box<W> {}',
			'class Lst<T> { public function all():Array<T> return []; }',
			'class Ch { var bw:Box<W>; var sub:BoxW; var raw:Box; var lst:Lst<W>; function allF():Void lst.all()[0].w(); '
			+ 'function listF():Void bw.list[0].w(); function maybeF():Void bw.maybe.w(); '
			+ 'function getF():Void bw.get().w(); function subF():Void sub.item.w(); function rawF():Void raw.item.w(); '
			+ 'function gen<T:W>(t:T):T return t; function genF():Void gen(new W()).w(); }'
		]);
		for (fn in ['Ch.listF', 'Ch.maybeF', 'Ch.getF', 'Ch.subF', 'Ch.allF']) Assert.equals(1, edges(g, fn, 'W.w', Call).length, fn);
		for (fn in ['Ch.listF', 'Ch.maybeF', 'Ch.getF', 'Ch.subF', 'Ch.rawF', 'Ch.genF'])
			Assert.equals(0, edges(g, fn, 'T.w', Call).length, fn);
	}

	@:pin('control') @:killer('M-GRAPH-TYPE-ARGUMENT') @:killer('M-GRAPH-TYPE-PARAM')
	public function testTypeParametersResolveThroughTheirArguments(): Void {
		// `box.item` is declared `T` on `Box<T>`: through `Box<W>` it is a `W`; a bare `x:T` names no type at all.
		final g: CallGraph = graphOf([
			'class W { public function w():Void {} }',
			'class Box<T> { public var item:T; }',
			'class G<T> { var box:Box<W>; function viaArg():Void box.item.w(); function viaParam(x:T):Void x.w(); }'
		]);
		Assert.equals(1, edges(g, 'G.viaArg', 'W.w', Call).length);
		Assert.isNull(g.node('T.w'));
		Assert.equals(1, [
			for (u in g.unresolved) if (u.from == 'G.viaParam' && u.reason.match(UnresolvedReceiver('w'))) u
		].length);
	}

	@:pin('control') @:killer('M-GRAPH-FN-TYPE-PARAM')
	public function testFunctionTypeParameterNamesNoType(): Void {
		final g: CallGraph = graphOf([
			'class W { public function w():Void {} }',
			'class G { function f<U:W>(x:U):Void x.w(); }'
		]);
		Assert.isNull(g.node('U.w'));
	}

	@:pin('control') @:killer('M-GRAPH-TYPEDEF-ALIAS')
	public function testTypedefAliasIsSeenThrough(): Void {
		final g: CallGraph = graphOf([
			'class Under { public function foo():Void {} }',
			'typedef Alias = Under;',
			'class G { function f(a:Alias):Void a.foo(); }'
		]);
		Assert.equals(1, edges(g, 'G.f', 'Under.foo', Call).length);
	}

	@:pin('control') @:killer('M-GRAPH-USING-ALL')
	public function testEveryUsingThatDeclaresTheExtensionIsATarget(): Void {
		// Which `ext` runs depends on the `using` order — the LAST one wins — so both are targets.
		final g: CallGraph = graphOf([
			'class Under { public function new() {} }',
			'class ExtA { public static function ext(u:Under):Void {} }',
			'class ExtB { public static function ext(u:Under):Void {} }',
			'using ExtA; using ExtB; class G { function f(u:Under):Void u.ext(); }'
		]);
		Assert.equals(1, edges(g, 'G.f', 'ExtA.ext', Call).length);
		Assert.equals(1, edges(g, 'G.f', 'ExtB.ext', Call).length);
	}

	@:pin('control') @:killer('M-GRAPH-IMPORT-UNLISTED') @:killer('M-GRAPH-UNLISTED-WILDCARD')
	public function testBareCallSomethingElseMaySupplyIsNeverAConstructor(): Void {
		// An enum constructor `Load` / `grow` exists, but an explicit static import binds `Load` to a type the index does
		// not hold, and a wildcard import of a type under a build macro may bring `grow` in.
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final e: { file: String, source: String } = { file: 'e/E.hx', source: 'package e; enum E { Load; grow; }' };
		final imported: CallGraph = CallGraph.build([
			e,
			{ file: 'A.hx', source: 'import u.Util.Load; class A { function a():Void Load(); }' }
		], plugin);
		Assert.equals(1, edges(imported, 'A.a', 'Util.Load', Call).length);
		final built: CallGraph = CallGraph.build([
			e,
			{ file: 'Gen.hx', source: '@:build(M.b()) class Gen {}' },
			{ file: 'B.hx', source: 'import Gen.*; class B { function b():Void grow(); }' }
		], plugin);
		Assert.equals('UnboundName(grow)', [for (u in built.unresolved) if (u.from == 'B.b') Std.string(u.reason)].join(','));
	}

	@:pin('control') @:killer('M-GRAPH-PLACEHOLDER-DISPATCH') @:killer('M-GRAPH-PLACEHOLDER-DECLARING')
	public function testCallToAMemberOfAnUnloadedSupertypeKeepsItsDispatch(): Void {
		// Before `Y` loads, `y()` / `this.y()` name `Y.y` — the declaring type's node its file upgrades — and dispatch on `X`,
		// so the override `Sub` declares is reached once it loads.
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final x: { file: String, source: String } = { file: 'X.hx', source: 'class X extends Y { function x():Void { y(); this.y(); } }' };
		final y: { file: String, source: String } = { file: 'Y.hx', source: 'class Y { public function y():Void {} }' };
		final g: CallGraph = CallGraph.build([x], plugin, SymbolIndex.build([x, y], plugin));
		final calls: Array<CallEdge> = edges(g, 'X.x', 'Y.y', Call);
		Assert.equals(2, calls.length);
		for (e in calls) Assert.equals('X', e.dispatchType);
		Assert.isNull(g.node('X.y'));
	}

	@:pin('control') @:killer('M-GRAPH-SELF-ALIAS-COUNT')
	public function testTypedefReExportIsNotASecondDeclaration(): Void {
		final g: CallGraph = graphOf(['package p; interface IMap { function get():Int; }', 'typedef IMap = p.IMap;']);
		Assert.equals(1, g.types.declarationCount('IMap'));
	}

	@:pin('control') @:killer('M-GRAPH-STATIC-FIELD-TYPE')
	public function testStaticFieldReadOffItsTypeIsTyped(): Void {
		final g: CallGraph = graphOf([
			'class W { public function w():Void {} }',
			'class Store { public static var held:W; }',
			'class G { function f():Void Store.held.w(); }'
		]);
		Assert.equals(1, edges(g, 'G.f', 'W.w', Call).length);
	}

	@:pin('control') @:killer('M-GRAPH-FORWARD') @:killer('M-GRAPH-FORWARD-ONLY')
	public function testForwardAbstractRoutesToTheUnderlying(): Void {
		final g: CallGraph = graphOf([
			'class Under { public function foo():Void {} public function bar():Void {} }',
			'@:forward abstract Fwd(Under) { public function new(u:Under) this = u; }',
			'@:forward(bar) abstract FwdSel(Under) { public function new(u:Under) this = u; }',
			'class G { function f(x:Fwd):Void x.foo(); function sel(x:FwdSel):Void { x.bar(); x.foo(); } }'
		]);
		Assert.equals(1, edges(g, 'G.f', 'Under.foo', Call).length);
		// `@:forward(bar)` forwards `bar` only: `foo` is not a member of `FwdSel`
		Assert.equals(1, edges(g, 'G.sel', 'Under.bar', Call).length);
		Assert.equals(0, edges(g, 'G.sel', 'Under.foo', Call).length);
	}

	@:pin('control') @:killer('M-GRAPH-PATH-SPELLING') @:killer('M-GRAPH-INHERITED-PLACEHOLDER')
	public function testOneFileUnderTwoSpellingsIsOneFile(): Void {
		// `./src/Y.hx` is `src/Y.hx`; and a bare call to a method a supertype not loaded yet declares names its placeholder.
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final x: { file: String, source: String } = { file: 'src/X.hx', source: 'class X extends Y { function x():Void y(); }' };
		final y: { file: String, source: String } = {
			file: 'src/Y.hx',
			source: 'class Y { public function new() {} public function y():Void {} }'
		};
		final g: CallGraph = CallGraph.build([x], plugin, SymbolIndex.build([x, y], plugin));
		Assert.equals(1, edges(g, 'X.x', 'Y.y', Call).length);
		g.addFiles([{ file: './src/Y.hx', source: y.source }]);
		g.addFiles([{ file: 'src/Y.hx', source: y.source }]);
		Assert.equals(1, g.types.declarationCount('Y'));
		Assert.isTrue(g.node('Y.y')?.isExternal == false);
	}

	@:pin('control') @:killer('M-GRAPH-USING-EXTENSION')
	public function testStaticExtensionResolvesThroughTheUsing(): Void {
		final g: CallGraph = graphOf([
			'class Under { public function foo():Void {} }',
			'class Ext { public static function ext(u:Under):Void {} }',
			'using Ext; class G { function f(u:Under):Void u.ext(); }'
		]);
		Assert.equals(1, edges(g, 'G.f', 'Ext.ext', Call).length);
		Assert.isNull(g.node('Under.ext'));
	}

	@:pin('control') @:killer('M-GRAPH-SUPERS-UNION')
	public function testSupertypesOfASharedNameAreUnioned(): Void {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final files: Array<{ file: String, source: String }> = [
			{ file: 'a/X.hx', source: 'package a; class X extends P {}' },
			{ file: 'b/X.hx', source: 'package b; class X extends Q {}' }
		];
		final types: CallGraphTypes = new CallGraphTypes(SymbolIndex.build(files, plugin), plugin.refShape());
		Assert.isTrue(types.supertypesOf('X').contains('P') && types.supertypesOf('X').contains('Q'));
		Assert.equals(2, types.declarationCount('X'));
	}

	@:pin('control') @:killer('M-GRAPH-INTERFACE-PROPERTY') @:killer('M-GRAPH-BODYLESS-FLAG')
	public function testInterfacePropertyRunsOnlyItsImplementations(): Void {
		// The interface declares no accessor body: the edge names a body-less declaration that dispatch goes through,
		// kept even while no implementation is loaded.
		final g: CallGraph = graphOf([
			'interface IP { var ip(get, never):Int; function m():Void; }',
			'class Impl implements IP { public var ip(get, never):Int; function get_ip():Int return 1; public function m():Void {} }',
			'class U { function f(i:IP):Int return i.ip; }'
		]);
		final declared: Null<FnNode> = g.node('IP.get_ip');
		Assert.isTrue(declared != null && declared.isBodyless && !declared.isExternal);
		Assert.isTrue(g.node('IP.m')?.isBodyless == true);
		Assert.equals('IP', edges(g, 'U.f', 'IP.get_ip', Accessor)[0]?.dispatchType);
		Assert.equals(1, edges(g, 'U.f', 'Impl.get_ip', Virtual).length);
		final alone: CallGraph = graphOf([
			'interface IP { var ip(get, never):Int; }',
			'class U { function f(i:IP):Int return i.ip; }'
		]);
		Assert.equals('IP', edges(alone, 'U.f', 'IP.get_ip', Accessor)[0]?.dispatchType);
	}

	@:pin('control') @:killer('M-GRAPH-ACCESS-RECORDED') @:killer('M-GRAPH-ACCESS-COUNTED')
	public function testUntypedPropertyAccessIsRecordedAgainstItsAccessor(): Void {
		// `p.x` on an unannotated `p` may run `get_x`; a `callers` of `get_x` must count it as a blind site.
		final g: CallGraph = graphOf([
			'class P { public var x(get, never):Int; function get_x():Int return 1; }',
			'class U { function f(p):Int return p.x; }'
		]);
		final getter: Null<FnNode> = g.node('P.get_x');
		Assert.notNull(getter);
		if (getter != null) Assert.equals(1, g.unresolvedAccessesRunning([getter]).length);
	}

	@:pin('control') @:killer('M-GRAPH-DISPATCH-TYPE')
	public function testInstanceCallRecordsTheTypeItDispatchesOn(): Void {
		final g: CallGraph = graphOf([
			'class Base { public function run():Void {} }',
			'class H { var b:Base; function f():Void b.run(); }'
		]);
		Assert.equals('Base', edges(g, 'H.f', 'Base.run', Call)[0]?.dispatchType);
	}

	@:pin('control') @:killer('M-GRAPH-UNBOUND-CAPITAL')
	public function testUnboundCapitalizedCallIsUnresolvedUnlessAnEnumConstructor(): Void {
		// `Imported()` may be a static function brought in by an import the graph does not follow; `Some(1)` builds a value
		// — the language finds the constructor by the expected type, imported or not.
		final g: CallGraph = graphOf([
			'enum E { Some(v:Int); }',
			'class A { function a():Void { Some(1); Imported(); } }'
		]);
		final names: Array<String> = [for (u in g.unresolved) if (u.from == 'A.a') Std.string(u.reason)];
		Assert.equals('UnboundName(Imported)', names.join(','));
	}

	@:pin('control') @:killer('M-GRAPH-ENUM-VS-STATIC')
	public function testEnumConstructorSharingAStaticFunctionNameIsUnresolved(): Void {
		final g: CallGraph = graphOf([
			'enum E { Load; } class A { function a():Void Load(); }',
			'class Util { public static function Load():Void {} }'
		]);
		Assert.equals(1, [for (u in g.unresolved) if (u.from == 'A.a') u].length);
	}

	@:pin('control') @:killer('M-GRAPH-IMPORTED-STATIC')
	public function testImportedStaticIsResolved(): Void {
		// `import u.Util.Load;`, `import u.Util.*;` and an alias bring statics in by simple name.
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final g: CallGraph = CallGraph.build([
			{
				file: 'u/Util.hx',
				source: 'package u; class Util { public static function Load():Void {} public static function Other():Void {} }'
			},
			{ file: 'e/E.hx', source: 'package e; enum E { Load; }' },
			{
				file: 'Main.hx',
				source: 'import u.Util.Load; import u.Util.*; import u.Util.Other as Run; '
				+ 'class Main { static function a():Void Load(); static function b():Void Other(); static function c():Void Run(); }'
			}
		], plugin);
		Assert.equals(1, edges(g, 'Main.a', 'Util.Load', Call).length);
		Assert.equals(1, edges(g, 'Main.b', 'Util.Other', Call).length);
		Assert.equals(1, edges(g, 'Main.c', 'Util.Other', Call).length);
	}

	private inline function graphOf(sources: Array<String>): CallGraph {
		return QueryTestHelpers.graphOf(sources);
	}

	private function edges(g: CallGraph, from: String, to: String, kind: EdgeKind): Array<CallEdge> {
		return [for (e in g.outEdges(from)) if (e.to == to && e.kind == kind) e];
	}

}
