package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.ThreadSafety;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * The `thread-safety` check: MAIN/BG context propagation over the call graph
 * (spawn callbacks go BG, marshal callbacks come back MAIN), finding (a) —
 * a main-context function directly calling a configured sink, finding (b) —
 * a lock held across a call that transitively reaches a sink. The rule is
 * config-driven and inert without a `thread-safety` entry in `apqlint.json`.
 */
class ThreadSafetyCheckTest extends Test {

	#if (sys || nodejs)
	private static final MUTEX: String =
		'class Mutex { public function new() {} public function acquire():Void {} public function release():Void {} }\n';
	#end

	public function testMainDirectSinkFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}', ['class A { function boot():Void Sys.sleep(1); }']
		);
		Assert.equals(1, vs.length);
		Assert.equals('thread-safety', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('Sys.sleep') != -1);
		Assert.isTrue(vs[0].message.indexOf('A.boot') != -1);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSpawnedCallbackNotFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["Runner.create"]}}}', [
			'class A { function boot():Void Runner.create(() -> Sys.sleep(1)); }',
			'class Runner { public static function create(fn:()->Void):Void {} }'
		]);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMarshalCallbackFlaggedAgain(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> =
			violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["Runner.create"],"marshals":["Ui.marshal"]}}}', [
				'class A { function boot():Void Runner.create(() -> Ui.marshal(() -> Sys.sleep(1))); }',
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class Ui { public static function marshal(fn:()->Void):Void {} }'
			]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Sys.sleep') != -1);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLockHeldAcrossBlockingCall(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> =
			violations('{"rules":{"thread-safety":{"sinks":["File.saveContent"],"lockPairs":["Mut.lock/unlock"]}}}', [
				'class A { private final _m:Mut; function work():Void { _m.lock(); File.saveContent(1, 2); _m.unlock(); } }',
				'class Mut { public function lock():Void {} public function unlock():Void {} }'
			]);
		final held: Array<Violation> = [for (v in vs) if (v.message.indexOf('holds') != -1) v];
		Assert.equals(1, held.length);
		Assert.isTrue(held[0].message.indexOf('A._m') != -1);
		Assert.isTrue(held[0].message.indexOf('File.saveContent') != -1);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCallAfterUnlockNotFlaggedAsHeld(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> =
			violations('{"rules":{"thread-safety":{"sinks":["File.saveContent"],"lockPairs":["Mut.lock/unlock"]}}}', [
				'class A { private final _m:Mut; function work():Void { _m.lock(); _m.unlock(); File.saveContent(1, 2); } }',
				'class Mut { public function lock():Void {} public function unlock():Void {} }'
			]);
		Assert.equals(0, [for (v in vs) if (v.message.indexOf('holds') != -1) v].length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testInertWithoutConfig(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{}', ['class A { function boot():Void Sys.sleep(1); }']);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('thread-safety'));
	}

	public function testSkipParseNoCrash(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}', ['class A { function broken( { ']);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A lock taken while another is held blocks only when someone holds IT across a blocking call: `_b` is held across
	 * a sleep in `s`, so taking it under `_a` in `w` is a blocking call, and a lock nothing holds long is not.
	 */
	public function testNestedAcquireBlocksOnlyOnALongLock(): Void {
		#if (sys || nodejs)
		final config: String = '{"rules":{"thread-safety":{"sinks":["Mut.lock","Sys.sleep"],"lockPairs":["Mut.lock/unlock"]}}}';
		final mut: String = 'class Mut { public function lock():Void {} public function unlock():Void {} }';
		final nested: String = 'function w():Void { _a.lock(); _b.lock(); _a.unlock(); _b.unlock(); }';
		final long: Array<Violation> = violations(config, [
			'class A { private final _a:Mut; private final _b:Mut; $nested function s():Void { _b.lock(); Sys.sleep(1); _b.unlock(); } }',
			mut
		]);
		Assert.equals(1, [for (v in long) if (v.message.indexOf('"A.w" holds') != -1) v].length);
		final short: Array<Violation> = violations(config, ['class A { private final _a:Mut; private final _b:Mut; $nested }', mut]);
		Assert.equals(0, [for (v in short) if (v.message.indexOf('holds') != -1) v].length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A lock sink the main thread calls is no stall when nothing ever holds that lock across a blocking call. */
	@:pin('control') @:killer('M-TS-LOCK-ALWAYS-BLOCKS')
	public function testAShortLockTakenOnMainIsQuiet(): Void {
		#if (sys || nodejs)
		Assert.same([], lockFindings([
			'class A { static final m:Mutex = new Mutex(); static var n:Int = 0; static function main():Void { m.acquire(); n++; m.release(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One function holding the lock across a sleep makes it long, and taking it on the main thread anywhere a stall. */
	@:pin('control') @:killer('M-TS-LONG-NEVER-GROWS')
	public function testALockHeldAcrossASleepStallsItsMainThreadTaker(): Void {
		#if (sys || nodejs)
		Assert.contains('main thread reaches blocking "Mutex.acquire": A.main -> Mutex.acquire', lockFindings([
			'class A { static final m:Mutex = new Mutex(); static function main():Void { Runner.create(work); m.acquire(); m.release(); }'
			+ ' static function work():Void { m.acquire(); Sys.sleep(1); m.release(); } }',
			'class Runner { public static function create(fn:()->Void):Void {} }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A member read as a value may be the lock another name takes — here `B.use` holds it across a sleep as `x` — so it
	 * names no lock, and a lock nothing names is long: the main-thread acquire stays reported.
	 */
	@:pin('control') @:killer('M-TS-UNSEALED-TRUSTED')
	public function testALockMemberThatEscapesStaysReported(): Void {
		#if (sys || nodejs)
		Assert.contains('main thread reaches blocking "Mutex.acquire": A.main -> Mutex.acquire', lockFindings([
			'class A { static final m:Mutex = new Mutex(); static function main():Void { Runner.create(B.use.bind(m)); m.acquire();'
			+ ' m.release(); } }',
			'class B { public static function use(x:Mutex):Void { x.acquire(); Sys.sleep(1); x.release(); } }',
			'class Runner { public static function create(fn:()->Void):Void {} }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A release on an early-return path closes the window on THAT path only: the sleep after the `if` is still held. */
	@:pin('control') @:killer('M-TS-WINDOW-IF-RELEASES')
	public function testAReleaseOnAnEarlyReturnKeepsTheRestOfTheWindow(): Void {
		#if (sys || nodejs)
		Assert.contains('"A.main" holds "A.m" across a call that can block: Sys.sleep', lockFindings([
			'class A { static final m:Mutex = new Mutex(); static var c:Bool; static function main():Void { m.acquire();'
			+ ' if (c) { m.release(); return; } Sys.sleep(1); m.release(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold only a background thread ever takes the lock around stalls no main-thread code: nothing is reported. */
	@:pin('control') @:killer('M-TS-HELD-ANY-THREAD')
	public function testAHoldOnlyABackgroundThreadTakesIsQuiet(): Void {
		#if (sys || nodejs)
		Assert.same([], lockFindings([
			'class A { static final m:Mutex = new Mutex(); static function main():Void Runner.create(work);'
			+ ' static function work():Void { m.acquire(); Sys.sleep(1); m.release(); } }',
			'class Runner { public static function create(fn:()->Void):Void {} }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A function releasing a lock it never took holds it across a function boundary: the lock is long. */
	@:pin('control') @:killer('M-TS-CROSSING-IGNORED')
	public function testAReleaseWithoutATakeMakesTheLockLong(): Void {
		#if (sys || nodejs)
		Assert.contains('main thread reaches blocking "Mutex.acquire": A.main -> Mutex.acquire', lockFindings([
			'class A { static final m:Mutex = new Mutex(); static function main():Void { m.acquire(); m.release(); }'
			+ ' public static function done():Void m.release(); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The owner's constructor holds its own fresh lock before the object reaches anyone: that hold blocks no one. */
	@:pin('control') @:killer('M-TS-CTOR-CONTENDED')
	public function testAHoldInTheOwnersConstructorBlocksNoOne(): Void {
		#if (sys || nodejs)
		Assert.same(['main thread reaches blocking "Sys.sleep": A.new -> Sys.sleep'], lockFindings([
			'class A { final m:Mutex = new Mutex(); public function new() { m.acquire(); Sys.sleep(1); m.release(); }'
			+ ' public function use():Void { m.acquire(); m.release(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold across a call the graph resolves to nothing — here a callback stored in a field — may block: the lock is long. */
	@:pin('control') @:killer('M-TS-BLIND-CALL-SHORT')
	public function testAHoldAcrossAnUnresolvedCallMakesTheLockLong(): Void {
		#if (sys || nodejs)
		Assert.contains('main thread reaches blocking "Mutex.acquire": A.main -> A.work -> Mutex.acquire', lockFindings([
			'class A { static final m:Mutex = new Mutex(); static var cb:() -> Void; static function main():Void { Runner.create(flush);'
			+ ' work(); } static function work():Void { m.acquire(); m.release(); } static function flush():Void { m.acquire(); cb();'
			+ ' m.release(); } }',
			'class Runner { public static function create(fn:()->Void):Void {} }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A constructor that hands `this` out BEFORE its hold is no private constructor: the hold across a sleep counts. */
	@:pin('control') @:killer('M-TS-CTOR-ESCAPE-BLIND')
	public function testAConstructorPublishingItselfFirstHoldsAContendedLock(): Void {
		#if (sys || nodejs)
		Assert.contains('"A.new" holds "A.m" across a call that can block: Sys.sleep', lockFindings([
			'class A { public static var instance:A; final m:Mutex = new Mutex(); public function new() { instance = this; m.acquire();'
			+ ' Sys.sleep(1); m.release(); } public function work():Void { m.acquire(); m.release(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A loop body is walked until its state settles: a lock taken on one pass is held across the sleep of the next. */
	@:pin('control') @:killer('M-TS-LOOP-ONE-PASS')
	public function testALockTakenInALoopIsHeldOnTheNextPass(): Void {
		#if (sys || nodejs)
		Assert.contains('"A.main" holds "A.m" across a call that can block: Sys.sleep', lockFindings([
			'class A { static final m:Mutex = new Mutex(); static function main():Void { for (i in 0...3) { Sys.sleep(1);'
			+ ' if (i == 0) m.acquire(); } m.release(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A lock call through a receiver the graph cannot type (`Dynamic`, a cast, a type parameter) may reach ANY object's
	 * member of that name, so the member is no longer sealed: its main-thread take stays reported.
	 */
	@:pin('control') @:killer('M-TS-UNNAMED-RECEIVER-SEALED')
	public function testALockCallThroughAnUntypedReceiverUnsealsTheMember(): Void {
		#if (sys || nodejs)
		final found: Array<String> = lockFindings([
			'class A { final m:Mutex = new Mutex(); public function new() {} public function work():Void { m.acquire(); m.release(); }'
			+ ' static function hold(d:Dynamic):Void d.m.acquire(); }'
		]);
		Assert.isTrue(found.exists(f -> f.indexOf('A.work -> Mutex.acquire') != -1), found.join('\n'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-ACCESSOR-TAINT')
	public function testLockHeldAcrossABlockingGetterFlagged(): Void {
		// Reading `_p.v` runs `get_v`, and that getter sleeps: the property read is a call like any other.
		#if (sys || nodejs)
		final vs: Array<Violation> =
			violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep","Mut.lock"],"lockPairs":["Mut.lock/unlock"]}}}', [
				'class A { private final _m:Mut; private final _p:P; function w():Void { _m.lock(); trace(_p.v); _m.unlock(); } }',
				'class P { public var v(get, never):Int; function get_v():Int { Sys.sleep(1); return 1; } }',
				'class Mut { public function lock():Void {} public function unlock():Void {} }'
			]);
		Assert.equals(1, [
			for (v in vs) if (v.message.indexOf('holds') != -1 && v.message.indexOf('P.get_v') != -1) v
		].length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTernarySpawnCallbackNotFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["Runner.create"]}}}', [
			'class A { var flag:Bool; function boot():Void Runner.create(flag ? work1 : work2); function work1():Void Sys.sleep(1); '
			+ 'function work2():Void Sys.sleep(1); }',
			'class Runner { public static function create(fn:()->Void):Void {} }'
		]);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMarshalBodySinkNotFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"marshals":["Ui.marshal"]}}}', [
			'class A { function boot():Void Ui.marshal(doWork); function doWork():Void {} }',
			'class Ui { public static function marshal(fn:()->Void):Void { Sys.sleep(0.01); } }'
		]);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testExcludedPathNotScanned(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"exclude":["F0.hx"]}}}', ['class A { function boot():Void Sys.sleep(1); }']
		);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testNonMatchingExcludeStillScanned(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"exclude":["elsewhere"]}}}',
			['class A { function boot():Void Sys.sleep(1); }']
		);
		Assert.equals(1, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMacroFunctionBodyNotRuntime(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}', ['class A { macro public static function gen():Void Sys.sleep(1); }']
		);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two config chains naming different sinks, one graph: each call site is judged by the chain of its own
	 * file, whichever file the run lists first, and the main-thread chain still crosses from one chain into the other.
	 */
	@:pin('control') @:killer('M-TS-FIRST-FILE-LISTS')
	public function testEachCallSiteJudgedByItsOwnChain(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'apqlint.json', source: '{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}' },
			{ name: 'a/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Gate.block"]}}}' },
			{ name: 'a/A.hx', source: 'class A { static function main():Void { Sys.sleep(1); Gate.block(); B.f(); } }' },
			{ name: 'a/Gate.hx', source: 'class Gate { public static function block():Void {} }' },
			{ name: 'b/B.hx', source: 'class B { public static function f():Void { Sys.sleep(2); Gate.block(); } }' }
		];
		for (order in [['a/A.hx', 'a/Gate.hx', 'b/B.hx'], ['b/B.hx', 'a/Gate.hx', 'a/A.hx']]) Assert.same([
			'a/A.hx: main thread reaches blocking "Gate.block": A.main -> Gate.block',
			'b/B.hx: main thread reaches blocking "Sys.sleep": A.main -> B.f -> Sys.sleep'
		], chainFindings(tree, order));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A node one chain names a sink is a plain function in a chain that does not: there it is tainted by the sink it
	 * calls, so a lock held across a call to it is reported, whichever file the run lists first.
	 */
	@:pin('control') @:killer('M-TS-TAINT-UNION-SINK')
	public function testASinkOfOneChainIsAPlainCallInAnother(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'x/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["A.n"]}}}' },
			{
				name: 'y/apqlint.json',
				source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Sys.sleep"],"lockPairs":["Mutex.acquire/release"]}}}'
			},
			{ name: 'x/X.hx', source: 'class X { static function main():Void { A.n(); } }' },
			{ name: 'y/A.hx', source: 'class A { public static function n():Void { Sys.sleep(1); } }' },
			{
				name: 'y/B.hx',
				source: MUTEX
					+ 'class B { static var m:Mutex = new Mutex(); public static function f():Void { m.acquire(); A.n(); m.release(); } }'
			}
		];
		for (order in [['x/X.hx', 'y/A.hx', 'y/B.hx'], ['y/A.hx', 'y/B.hx', 'x/X.hx']])
			Assert.contains('y/B.hx: "B.f" holds "B.m" across a call that can block: A.n -> Sys.sleep', chainFindings(tree, order));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A file whose chain names no sinks reports nothing but stays in the graph: its `spawns` registration still sends
	 * the callback to a background thread, so the sink call inside it is not a main-thread finding.
	 */
	@:pin('control') @:killer('M-TS-GRAPH-CUT')
	public function testAFileWithoutSinksStillShapesTheGraph(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'x/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["W.run"]}}}' },
			{ name: 'y/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"spawns":["W.run"]}}}' },
			{
				name: 'x/X.hx',
				source: 'class W { public static function run(f:()->Void):Void {} } class X { public static function work():Void {'
					+ ' Sys.sleep(1); } }'
			},
			{ name: 'y/Reg.hx', source: 'class Reg { static function main():Void { W.run(X.work); } }' }
		];
		for (order in [['x/X.hx', 'y/Reg.hx'], ['y/Reg.hx', 'x/X.hx']]) Assert.same([], chainFindings(tree, order));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A file whose chain names no sinks is scanned for the graph and never reported in — `skipReason` is the report gate. */
	@:pin('control') @:killer('M-TS-REPORT-UNGATED')
	public function testNoFindingInAFileWhoseChainNamesNoSinks(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'x/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}' },
			{ name: 'y/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"lockPairs":["Mutex.acquire/release"]}}}' },
			{ name: 'x/X.hx', source: 'class X { public static function work():Void { Sys.sleep(1); } }' },
			{
				name: 'y/Y.hx',
				source: '${MUTEX}class Y { static var m:Mutex = new Mutex(); public static function f():Void {'
					+ ' m.acquire(); X.work(); m.release(); } }'
			}
		];
		for (order in [['x/X.hx', 'y/Y.hx'], ['y/Y.hx', 'x/X.hx']])
			Assert.same(['x/X.hx: main thread reaches blocking "Sys.sleep": Y.f -> X.work -> Sys.sleep'], chainFindings(tree, order));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A malformed `lockPairs` entry of a chain that names no sinks is not reported: that chain reports nothing at all. */
	@:pin('control') @:killer('M-TS-MALFORMED-UNGATED')
	public function testAMalformedOptionOfANonReportingChainIsSilent(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'x/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Sys.sleep"],"lockPairs":["bad2"]}}}' },
			{ name: 'y/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"lockPairs":["bad"]}}}' },
			{ name: 'x/X.hx', source: 'class X { public static function work():Void { Sys.sleep(1); } }' },
			{ name: 'y/Y.hx', source: 'class Y { static function main():Void { X.work(); } }' }
		];
		for (order in [['x/X.hx', 'y/Y.hx'], ['y/Y.hx', 'x/X.hx']])
			Assert.same(
				[': malformed lockPairs entry "bad2" — expected "<lock pattern>/<unlock member>"'],
				chainFindings(tree, order).filter(f -> f.indexOf('malformed') != -1)
			);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A call of a function whose whole lock traffic is one take is that take: the caller holds the lock from the call on. */
	@:pin('control') @:killer('M-TS-WRAPPER-NONE')
	public function testAHoldTakenThroughAWrapperIsTheCallersHold(): Void {
		#if (sys || nodejs)
		Assert.contains('"A.main" holds "A.m" across a call that can block: Sys.sleep', lockFindings([
			'class A { static final m:Mutex = new Mutex(); static function lockIt():Void m.acquire();'
			+ ' static function unlockIt():Void m.release(); static function main():Void { lockIt(); Sys.sleep(1); unlockIt(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A wrapper's own take outlives its body and its partner's release precedes it by design: neither makes the lock long. */
	@:pin('control') @:killer('M-TS-WRAPPER-LEAKS', 'M-TS-WRAPPER-CROSSING')
	public function testABriefHoldThroughWrappersKeepsTheLockShort(): Void {
		#if (sys || nodejs)
		Assert.same([], lockFindings([
			'class A { static final m:Mutex = new Mutex(); static function lockIt():Void m.acquire();'
			+ ' static function unlockIt():Void m.release(); static function main():Void { lockIt(); unlockIt(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A function that releases on SOME path only is no release wrapper: the caller's hold goes on past the call. */
	@:pin('control') @:killer('M-TS-WRAPPER-MAY-RELEASE')
	public function testAConditionalReleaseIsNoWrapper(): Void {
		#if (sys || nodejs)
		Assert.contains('"A.main" holds "A.m" across a call that can block: Sys.sleep', lockFindings([
			'class A { static final m:Mutex = new Mutex(); static function lockIt():Void m.acquire();'
			+ ' static function unlockIt(c:Bool):Void if (c) m.release();'
			+ ' static function main():Void { lockIt(); unlockIt(true); Sys.sleep(1); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A function that takes on SOME path only is no take wrapper: its take leaks, so the lock stays long. */
	@:pin('control') @:killer('M-TS-WRAPPER-MAY-TAKE')
	public function testAConditionalTakeIsNoWrapper(): Void {
		#if (sys || nodejs)
		Assert.contains('main thread reaches blocking "Mutex.acquire": A.main -> A.lockIt -> Mutex.acquire', lockFindings([
			'class A { static final m:Mutex = new Mutex(); static function lockIt(c:Bool):Void if (c) m.acquire();'
			+ ' static function unlockIt():Void m.release(); static function main():Void { lockIt(true); unlockIt(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A wrapper called by its name through a receiver the graph cannot type has a caller no one sees: its take stays its own. */
	@:pin('control') @:killer('M-TS-WRAPPER-UNRESOLVED')
	public function testAWrapperCalledThroughAnUntypedReceiverKeepsItsTakeLong(): Void {
		#if (sys || nodejs)
		Assert.contains('main thread reaches blocking "Mutex.acquire": A.main -> B.lockIt -> Mutex.acquire', lockFindings([
			'class B { final m:Mutex = new Mutex(); public function new() {} public function lockIt():Void m.acquire();'
			+ ' public function unlockIt():Void m.release(); }',
			'class A { static function main(b:B, d:Dynamic):Void { b.lockIt(); b.unlockIt(); d.lockIt(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A call through an interface whose every implementation is the same wrapper is that wrapper's take. */
	@:pin('control') @:killer('M-TS-WRAPPER-NO-PASS-THROUGH')
	public function testAWrapperReachedThroughAnInterfaceTakesTheLock(): Void {
		#if (sys || nodejs)
		Assert.contains('"A.main" holds "B.m" across a call that can block: Sys.sleep', lockFindings([
			'interface I { function lockIt():Void; function unlockIt():Void; }',
			'class B implements I { final m:Mutex = new Mutex(); public function new() {} public function lockIt():Void m.acquire();'
			+ ' public function unlockIt():Void m.release(); }',
			'class A { static function main(i:I):Void { i.lockIt(); Sys.sleep(1); i.unlockIt(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The main thread through a `quietRoots` function reaches its sinks unreported. */
	@:pin('control') @:killer('M-TS-QUIET-IGNORED')
	public function testAPathThroughAQuietRootIsNotReported(): Void {
		#if (sys || nodejs)
		Assert.same([], violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"quietRoots":["A.shutdown"]}}}', [
			'class A { static function main():Void Ui.onExit(shutdown); static function shutdown():Void stop();'
			+ ' static function stop():Void Sys.sleep(1); }',
			'class Ui { public static function onExit(fn:()->Void):Void {} }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A sink a quiet root reaches is still reported when another main-thread path reaches it too. */
	@:pin('control') @:killer('M-TS-QUIET-SWALLOWS')
	public function testAnotherPathToAQuietSinkStillReports(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"quietRoots":["A.shutdown"]}}}', [
			'class A { static function main():Void save(); static function shutdown():Void save();'
			+ ' static function save():Void Sys.sleep(1); }'
		]);
		Assert.same(['main thread reaches blocking "Sys.sleep": A.main -> A.save -> Sys.sleep'], [for (v in vs) v.message]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** What a quiet root running on a background thread marshals to the main thread is as quiet as the root. */
	@:pin('control') @:killer('M-TS-QUIET-INTO-CALLBACK')
	public function testWhatAQuietRootRegistersRunsLoud(): Void {
		#if (sys || nodejs)
		Assert.same(
			[
				'main thread reaches blocking "Sys.sleep": A.shutdown -> A.shutdown#1 -> Sys.sleep',
				'main thread reaches blocking "Sys.sleep": A.shutdown#2 -> A.shutdown#2#3 -> Sys.sleep'
			],
			[
				for (v in violations(
					'{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["Runner.create"],"marshals":["Ui.marshal"],'
					+ '"quietRoots":["A.shutdown"]}}}',
					[
						'class A { static final ls:Array<()->Void> = []; static function shutdown():Void {'
						+ ' ls.push(() -> Sys.sleep(1)); Runner.create(() -> Ui.marshal(() -> Sys.sleep(2))); } }',
						'class Runner { public static function create(fn:()->Void):Void {} }',
						'class Ui { public static function marshal(fn:()->Void):Void {} }'
					]
				)) v.message
			]
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A quiet root loud main-thread code calls is no quiet root: its whole reach reports. */
	@:pin('control') @:killer('M-TS-QUIET-LOUD-CALLER')
	public function testAQuietRootALoudCallerCallsIsLoud(): Void {
		#if (sys || nodejs)
		Assert.same(
			[
				'main thread reaches blocking "Sys.sleep": A.main -> A.onButton -> A.shutdown -> Sys.sleep'
			],
			[
				for (v in violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"quietRoots":["A.shutdown"]}}}', [
					'class A { static function main():Void onButton(); static function onButton():Void shutdown();'
					+ ' static function shutdown():Void Sys.sleep(1); }'
				])) v.message
			]
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Re-entrance is per OBJECT: another instance's lock of the same member, taken under a hold, is a real wait. */
	@:pin('control') @:killer('M-TS-REENTRANT-ANY-OBJECT')
	public function testATakeOfAnotherObjectsLockBlocksUnderAReentrantHold(): Void {
		#if (sys || nodejs)
		Assert.same(['"C.transfer" holds "C._m" across a call that can block: Mutex.acquire'], heldBy('C.transfer', objectFixture()));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A wrapper called on another object takes that object's lock: a real wait under a re-entrant hold. */
	@:pin('control') @:killer('M-TS-REENTRANT-WRAPPER-ELSEWHERE')
	public function testAWrapperOnAnotherObjectBlocksUnderAReentrantHold(): Void {
		#if (sys || nodejs)
		Assert.same([
			'"C.transfer2" holds "C._m" across a call that can block: C.lockIt (the held lock, on another object)'
		], heldBy('C.transfer2', objectFixture()));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold of ANOTHER object's lock is no hold of the running object's: re-taking the own lock under it still waits. */
	@:pin('control') @:killer('M-TS-REENTRANT-HOLDER-ELSEWHERE')
	public function testAHoldOfAnotherObjectsLockIsNotReentrantForTheOwnLock(): Void {
		#if (sys || nodejs)
		Assert.same(['"C.cross" holds "C._m" across a call that can block: Mutex.acquire'], heldBy('C.cross', objectFixture()));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Re-taking the running object's own lock, directly or through its own methods, blocks nothing under its hold. */
	@:pin('control') @:killer('M-TS-SELF-NEVER')
	public function testARetakeOfTheOwnObjectsLockIsFree(): Void {
		#if (sys || nodejs)
		Assert.same([], heldBy('C.nested', objectFixture()));
		#else
		Assert.pass('non-sys target');
		#end
	}


	/** A hold of a `reentrantLocks` lock may take that same lock again: the re-take inside it blocks nothing. */
	@:pin('control') @:killer('M-TS-REENTRANT-IGNORED')
	public function testARetakeOfAHeldReentrantLockIsNoBlockingCall(): Void {
		#if (sys || nodejs)
		Assert.same([], heldBy('A.main', reentrantFixture('"reentrantLocks":["Mutex.acquire"],')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Re-entrance is a property a lock kind is GIVEN: an unlisted one keeps the re-take a blocking call. */
	@:pin('control') @:killer('M-TS-REENTRANT-ASSUMED')
	public function testARetakeOfAnUnlistedLockKindStillBlocks(): Void {
		#if (sys || nodejs)
		Assert.same(
			['"A.main" holds "A.m" across a call that can block: A.inner -> Mutex.acquire'], heldBy('A.main', reentrantFixture(''))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One finding per hold: the calls that block are counted, the first `EVIDENCE_CAP` distinct ones named, the rest counted. */
	@:pin('control') @:killer('M-TS-EVIDENCE-UNCAPPED')
	public function testAHoldIsOneFindingListingItsBlockingCalls(): Void {
		#if (sys || nodejs)
		final names: Array<String> = [for (i in 0...9) 'f$i'];
		Assert.same(
			[
				'"A.main" holds "A.m" across 11 calls that can block: Sys.sleep; '
				+ [for (n in names.slice(0, 7)) 'A.$n -> Sys.sleep'].join('; ') + '; +2 more'
			],
			heldBy('A.main', lockFindings([
				'class A { static final m:Mutex = new Mutex(); static function main():Void { m.acquire(); Sys.sleep(1); '
				+ [for (n in names) '$n();'].join(' ') + ' Sys.sleep(2); m.release(); } '
				+ [for (n in names) 'static function $n():Void Sys.sleep(1);'].join(' ') + ' }'
			]))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold's finding sits at the first call of the hold that can block. */
	@:pin('control') @:killer('M-TS-HOLD-ANCHOR-LAST')
	public function testAHoldIsAnchoredAtItsFirstBlockingCall(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { static final m:Mutex = new Mutex(); static function main():Void { m.acquire(); x();'
			+ ' Sys.sleep(1); Sys.sleep(2); m.release(); } static function x():Void {} }';
		final held: Array<Violation> = violations(
			'{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"lockPairs":["Mutex.acquire/release"]}}}', [MUTEX, source]
		).filter(v -> v.message.indexOf(' holds ') != -1);
		Assert.same([source.indexOf('Sys.sleep(1)')], [for (v in held) v.span?.from]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold of a lock no member names is reported under the pair's take member. */
	@:pin('control') @:killer('M-TS-UNKNOWN-LOCK-UNNAMED')
	public function testAHoldOfAnUnknownLockNamesThePair(): Void {
		#if (sys || nodejs)
		Assert.same(['"B.use" holds "Mutex.acquire" across a call that can block: Sys.sleep'], heldBy('B.use', lockFindings([
			'class A { static function main():Void B.use(new Mutex()); }',
			'class B { public static function use(x:Mutex):Void { x.acquire(); Sys.sleep(1); x.release(); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One main-thread finding per call site, naming every sink a dispatch there may reach. */
	@:pin('control') @:killer('M-TS-SITE-PER-TARGET')
	public function testAMainThreadCallSiteIsOneFinding(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["I.read","B.read"]}}}', [
			'interface I { function read():Void; }',
			'class B implements I { public function new() {} public function read():Void {} }',
			'class A { static function main(i:I):Void i.read(); }'
		]);
		Assert.same(['main thread reaches blocking "I.read" / "B.read": A.main -> I.read / B.read'], [for (v in vs) v.message]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The hold findings of `holder` among `found`. */
	private static function heldBy(holder: String, found: Array<String>): Array<String> {
		return found.filter(f -> f.indexOf('"$holder" holds') == 0);
	}

	/**
	 * Instance locks of two objects: `slow` holds its own across a sleep on a background thread, so `C._m` is long;
	 * `transfer`/`transfer2` take another object's under their own, `cross` its own under another's, `nested` its own twice.
	 */
	private function objectFixture(): Array<String> {
		final found: Array<String> = [
			for (v in violations(
				'{"rules":{"thread-safety":{"reentrantLocks":["Mutex.acquire"],"sinks":["Mutex.acquire","Sys.sleep"],'
				+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}',
				[
					MUTEX,
					'class C { public static final a:C = new C(); public static final b:C = new C(); final _m:Mutex = new Mutex();'
					+ ' public function new() {} public function lockIt():Void _m.acquire(); public function unlockIt():Void _m.release();'
					+ ' public function slow():Void { _m.acquire(); Sys.sleep(5); _m.release(); }'
					+ ' public function transfer(o:C):Void { _m.acquire(); o._m.acquire(); o._m.release(); _m.release(); }'
					+ ' public function transfer2(o:C):Void { lockIt(); o.lockIt(); o.unlockIt(); unlockIt(); }'
					+ ' public function cross(o:C):Void { o._m.acquire(); _m.acquire(); _m.release(); o._m.release(); }'
					+ ' public function nested():Void { _m.acquire(); inner(); this.lockIt(); this.unlockIt(); _m.release(); }'
					+ ' function inner():Void { _m.acquire(); _m.release(); }'
					+ ' public static function main():Void { Runner.create(() -> b.slow()); a.transfer(b); a.transfer2(b); a.cross(b);'
					+ ' a.nested(); } }',
					'class Runner { public static function create(fn:()->Void):Void {} }'
				]
			)) v.message
		];
		found.sort(Reflect.compare);
		return found;
	}

	/** `A.main` holding `A.m` across `A.inner`, which takes `A.m` again, while a background thread sleeps under it. */
	private function reentrantFixture(extraConfig: String): Array<String> {
		final found: Array<String> = [
			for (v in violations(
				'{"rules":{"thread-safety":{$extraConfig"sinks":["Mutex.acquire","Sys.sleep"],"spawns":["Runner.create"],'
				+ '"lockPairs":["Mutex.acquire/release"]}}}',
				[
					MUTEX,
					'class A { static final m:Mutex = new Mutex(); static function main():Void { Runner.create(work); m.acquire();'
					+ ' inner(); m.release(); } static function inner():Void { m.acquire(); m.release(); }'
					+ ' static function work():Void { m.acquire(); Sys.sleep(1); m.release(); } }',
					'class Runner { public static function create(fn:()->Void):Void {} }'
				]
			)) v.message
		];
		found.sort(Reflect.compare);
		return found;
	}
	#end

	#if (sys || nodejs)
	/** Every finding over `tree` with the run's files listed in `order`, as sorted `<relative path>: <message>` lines. */
	private function chainFindings(tree: Array<{ name: String, source: String }>, order: Array<String>): Array<String> {
		final root: String = CliFixture.writeTree('threadsafetychains', tree);
		final files: Array<{ file: String, source: String }> = [
			for (name in order) { file: '$root/$name', source: tree.find(t -> t.name == name)?.source ?? '' }
		];
		final vs: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), [new ThreadSafety()]);
		final found: Array<String> = [for (v in vs) '${v.file.substring(root.length + 1)}: ${v.message}'];
		found.sort(Reflect.compare);
		CliFixture.removeDir(root);
		return found;
	}

	/** Every finding of a `Mutex.acquire` / `Sys.sleep` run over `sources` (plus `Mutex`), the `Runner.create` spawn configured, sorted. */
	private function lockFindings(sources: Array<String>): Array<String> {
		final found: Array<String> = [
			for (v in violations(
				'{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"spawns":["Runner.create"],'
				+ '"lockPairs":["Mutex.acquire/release"]}}}',
				[MUTEX].concat(sources)
			)) v.message
		];
		found.sort(Reflect.compare);
		return found;
	}

	private function violations(config: String, sources: Array<String>): Array<Violation> {
		final dir: String = CliFixture.writeDir('threadsafety', [{ name: 'apqlint.json', source: config }]);
		final files: Array<{ file: String, source: String }> = [
			for (i in 0...sources.length) { file: '$dir/F$i.hx', source: sources[i] }
		];
		// Through `Linter.run`, not `run`: the `sinks` / `exclude` gate is `FileGated`, applied where findings enter the tool.
		final result: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), [new ThreadSafety()]);
		CliFixture.removeDir(dir);
		return result;
	}
	#end

}
