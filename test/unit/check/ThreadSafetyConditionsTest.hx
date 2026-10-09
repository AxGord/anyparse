package unit.check;

import utest.Assert;
import utest.Test;

/**
 * The `thread-safety` check's path conditions: a call cut by what the code around it says — a value stored into a
 * `dynamic` member runs where the member runs, a `neverInvokes` target runs nothing it is handed, a branch of a
 * `mainThreadChecks` call runs on its own threads only, a `Bool` or `null` argument decides the callee's branches — and
 * the functions nothing can reach under `closedWorld`.
 */
class ThreadSafetyConditionsTest extends Test {

	#if (sys || nodejs)
	/** `W`, whose `dynamic` member `onDone` runs where `run` calls it. */
	private static final STORE_SLOT: String =
		'class W { public function new() {} public dynamic function onDone():Void {} public function run():Void onDone(); }';
	#end

	/**
	 * A method assigned to a `dynamic` member runs where the member runs — here only in `W.run`, which a spawned thread
	 * calls — and never at the assignment in `A`'s constructor, so the main thread reaches no sleep.
	 */
	@:pin('control') @:killer('M-TS-STORE-INERT')
	public function testAValueStoredInADynamicMemberRunsWhereTheMemberRuns(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('', [
			STORE_SLOT,
			'class A { final w:W = new W(); public function new() { w.onDone = done; Runner.create(w.run); }'
			+ ' function done():Void Sys.sleep(1); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The member invoked on the main thread runs the stored value there, and the chain names the invocation, not the assignment. */
	@:pin('control') @:killer('M-TS-STORE-UNMIRRORED')
	public function testAStoredValueInvokedOnTheMainThreadIsReachedThroughTheInvoker(): Void {
		#if (sys || nodejs)
		Assert.same(
			[
				'main thread reaches blocking "Sys.sleep": A.new -> W.run -> A.done -> Sys.sleep'
			],
			sleepFindings('', [
				STORE_SLOT,
				'class A { final w:W = new W(); public function new() { w.onDone = done; w.run(); } function done():Void Sys.sleep(1); }'
			])
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A call of the member's name the graph cannot resolve may run the stored value anywhere: the assignment keeps its context. */
	@:pin('control') @:killer('M-TS-STORE-SEALED-BLIND')
	public function testAStoredValueAnUnresolvedCallMayRunKeepsTheAssignersContext(): Void {
		#if (sys || nodejs)
		Assert.same(
			[
				'main thread reaches blocking "Sys.sleep" (also reachable from a background thread): A.new -> A.done -> Sys.sleep'
			],
			sleepFindings('', [
				STORE_SLOT,
				'class A { final w:W = new W(); public function new() { w.onDone = done; Runner.create(w.run); }'
				+ ' function done():Void Sys.sleep(1); }',
				'class B { public function new() {} public function poke(x:Dynamic):Void Runner.create(() -> x.onDone()); }'
			])
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A handler handed to a `neverInvokes` target (`Disp.removeEventListener`) runs from no call there: `dispose` reaches nothing. */
	@:pin('control') @:killer('M-TS-NEVER-INVOKES-BY-TARGET')
	public function testAHandlerHandedToANeverInvokesTargetRunsNowhereFromThere(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('"neverInvokes":["Disp.removeEventListener"]', [
			'class Disp { public function new() {} public function addEventListener(t:String, f:()->Void):Void {}'
			+ ' public function removeEventListener(t:String, f:()->Void):Void {} }',
			'class A { final d:Disp = new Disp(); public function new() '
			+ 'Runner.create(listen); function listen():Void d.addEventListener("e", handler);'
			+ ' public function dispose():Void d.removeEventListener("e", handler); function handler():Void Sys.sleep(1); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A bare `neverInvokes` name matches the call as written, even one the graph resolves to nothing (a library supertype's method). */
	@:pin('control') @:killer('M-TS-NEVER-INVOKES-BY-NAME')
	public function testABareNeverInvokesNameMatchesAnUnresolvedCall(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('"neverInvokes":["removeEventListener"]', [
			'class A extends LibrarySprite { public function new() Runner.create(listen); function listen():Void addEventListener("e", '
			+ 'handler); public function dispose():Void removeEventListener("e", handler); function handler():Void Sys.sleep(1); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The branch a `mainThreadChecks` call says runs off the main thread reaches nothing on it (`APIEntity2.get`'s shape). */
	@:pin('control') @:killer('M-TS-MAIN-CHECK-IGNORED')
	public function testTheOffMainBranchOfAMainThreadCheckIsNoMainStall(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('"mainThreadChecks":["T.isMain"]', [
			'class T { public static function isMain():Bool return true; }',
			'class Api { public static function get():Void T.isMain() ? async() : blocked(); static function async():Void {}'
			+ ' static function blocked():Void Sys.sleep(1); }',
			'class A { public static function main():Void Api.get(); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A check written as a property is read through its getter, the call the graph records at the read. */
	@:pin('control') @:killer('M-TS-MAIN-CHECK-NO-GETTER')
	public function testAMainThreadCheckPropertyIsReadThroughItsGetter(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('"mainThreadChecks":["T.isMain"]', [
			'class T { public static var isMain(get, never):Bool; static function get_isMain():Bool return true; }',
			'class Api { public static function get():Void if (!T.isMain) Sys.sleep(1); }',
			'class A { public static function main():Void Api.get(); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `final done = check ? null : new Lock()` then `done != null && done.wait()`: the wait runs only off the main thread
	 * (`LogWriter.truncate`).
	 */
	@:pin('control') @:killer('M-TS-NULL-LOCAL-UNREAD')
	public function testANullTestOfALocalTheCheckChoseIsTheChecksAnswer(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('"mainThreadChecks":["T.isMain"]', [
			'class T { public static function isMain():Bool return true; }',
			'class Lock { public function new() {} public function wait():Bool { Sys.sleep(1); return true; } }',
			'class L { public static function truncate():Bool { final done:Null<Lock> = T.isMain() ? null : new Lock();'
			+ ' return done != null && done.wait(); } }',
			'class A { public static function main():Void L.truncate(); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** What follows `if (T.isMain()) return;` in its block runs off the main thread only. */
	@:pin('control') @:killer('M-TS-EARLY-EXIT-UNREAD')
	public function testCodeAfterAnEarlyExitOnTheCheckRunsOnTheOtherThreads(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('"mainThreadChecks":["T.isMain"]', [
			'class T { public static function isMain():Bool return true; }',
			'class Api { public static function put():Void { if (T.isMain()) return; Sys.sleep(1); } }',
			'class A { public static function main():Void Api.put(); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `work(false)` from the main thread never runs `if (sleep) Sys.sleep(1)`; only the spawned `work(true)` does. */
	@:pin('control') @:killer('M-TS-ARG-UNBOUND', 'M-TS-STATES-UNCONDITIONED')
	public function testABoolLiteralArgumentDecidesTheCalleesBranch(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('', [
			'class W { public static function work(sleep:Bool):Void if (sleep) nap(); static function nap():Void Sys.sleep(1); }',
			'class A { public static function main():Void { W.work(false); Runner.create(() -> W.work(true)); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An omitted argument takes the callee's `Bool` literal default. */
	@:pin('control') @:killer('M-TS-DEFAULT-UNREAD')
	public function testAnOmittedArgumentTakesItsBoolDefault(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('', [
			'class W { public static function work(?n:Int, sleep:Bool = false):Void if (sleep) Sys.sleep(1); }',
			'class A { public static function main():Void W.work(); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A parameter handed on bare carries the value its own caller gave it (`getItemDataByItemPath(path, load)`). */
	@:pin('control') @:killer('M-TS-ARG-PARAM-UNREAD', 'M-TS-STATES-UNBOUND')
	public function testAParameterHandedOnCarriesItsValue(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('', [
			'class W { public static function outer(load:Bool):Void inner(load); static function inner(load:Bool):Void if (load) '
			+ 'Sys.sleep(1); }',
			'class A { public static function main():Void W.outer(false); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A `?fs` left out is null, so `if (fs != null) fs.save()` never runs (`SessionModel.checkSharedCloudId`). */
	@:pin('control') @:killer('M-TS-NULL-PARAM-UNREAD')
	public function testAnOmittedOptionalParameterIsNull(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('', [
			'class Fs { public function new() {} public function save():Void Sys.sleep(1); }',
			'class W { public static function go(?fs:Fs):Void if (fs != null) fs.save(); }',
			'class A { public static function main():Void W.go(); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `work(true)` with `?n:Int` first: Haxe skips `n` and hands `true` to `sleep`, so position alone does not bind it —
	 * an argument whose written type is not the optional parameter's keeps every value unknown.
	 */
	@:pin('control') @:killer('M-TS-SKIP-UNCHECKED')
	public function testAnArgumentHaxeMaySkipAnOptionalParameterForBindsNothing(): Void {
		#if (sys || nodejs)
		Assert.same(['main thread reaches blocking "Sys.sleep": A.main -> W.work -> Sys.sleep'], sleepFindings('', [
			'class W { public static function work(?n:Int, sleep:Bool = false):Void if (sleep) Sys.sleep(1); }',
			'class A { public static function main():Void W.work(true); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A parameter the body writes holds what the write gave it, not the argument: the branch stays reachable. */
	@:pin('control') @:killer('M-TS-PARAM-WRITE-IGNORED')
	public function testAWrittenParameterIsNotTracked(): Void {
		#if (sys || nodejs)
		Assert.same(['main thread reaches blocking "Sys.sleep": A.main -> W.work -> Sys.sleep'], sleepFindings('', [
			'class W { public static function work(sleep:Bool):Void { sleep = !sleep; if (sleep) Sys.sleep(1); } }',
			'class A { public static function main():Void W.work(false); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `db.add(true)` under `_mutation` never takes `_batch` (`if (!batch)`): the main thread orders nothing backwards. The
	 * spawned `add(false)` takes it holding nothing, so the take is no dead one.
	 */
	@:pin('control') @:killer('M-TS-ORDER-UNCONDITIONED')
	public function testATakeABoolArgumentRulesOutOrdersNothing(): Void {
		#if (sys || nodejs)
		Assert.same(
			[],
			ThreadSafetyCheckTest.orderFindings(ThreadSafetyCheckTest.storeFixture(
				'acquireMutation(); db.add(true); releaseMutation();',
				'Runner.create(fs.download); Runner.create(() -> fs.db.add(false)); fs.save();'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A hold whose take a Bool argument rules out holds nothing: the spawned `op(true)` touches the tree with `_batch` free.
	 * The main thread's `op(false)` takes both in the other order, one thread against itself.
	 */
	@:pin('control') @:killer('M-TS-ORDER-HOLD-UNCONDITIONED')
	public function testAHoldABoolArgumentRulesOutHoldsNothingInOrder(): Void {
		#if (sys || nodejs)
		Assert.same([], ThreadSafetyCheckTest.orderFindings([
			'class Tree { public final lock:Mutex = new Mutex(); public function new() {} public function touch():Void {'
			+ ' lock.acquire(); lock.release(); } }',
			'class Db { final _batch:Mutex = new Mutex(); final t:Tree = new Tree(); public function new() {}'
			+ ' public function op(batch:Bool):Void { if (!batch) _batch.acquire(); t.touch(); if (!batch) _batch.release(); }'
			+ ' public function ui():Void { t.lock.acquire(); _batch.acquire(); _batch.release(); t.lock.release(); }'
			+ ' public static function main():Void { final db:Db = new Db(); Runner.create(() -> db.op(true)); db.op(false); db.ui(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold on the main thread across a call that blocks only off it (`if (!T.isMain()) Sys.sleep(1)`) blocks nothing. */
	@:pin('control') @:killer('M-TS-TAINT-UNCONDITIONED')
	public function testAHoldAcrossACallBlockingOnlyOnAnotherThreadIsQuiet(): Void {
		#if (sys || nodejs)
		Assert.same([], [
			for (v in sleepFindings('"mainThreadChecks":["T.isMain"],"lockPairs":["Mutex.acquire/release"]', [
				ThreadSafetyCheckTest.MUTEX,
				'class T { public static function isMain():Bool return true; }',
				'class A { final _m:Mutex = new Mutex(); public function new() {} public function ui():Void { _m.acquire(); put(); '
				+ '_m.release(); } function put():Void if (!T.isMain()) Sys.sleep(1); public static function main():Void new A().ui(); }'
			])) if (v.indexOf('holds') != -1) v
		]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Under `closedWorld`, a method nothing in the run calls runs on no thread: its sleep is no main stall. */
	@:pin('control') @:killer('M-TS-CLOSED-WORLD-UNREAD')
	public function testUnderAClosedWorldAnUncalledMethodRunsNowhere(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('"closedWorld":true', [
			'class A { public function new() {} public function unused():Void Sys.sleep(1); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A constructor nothing constructs is still an entry point under `closedWorld`: the runtime may make the object. */
	@:pin('control') @:killer('M-TS-SEAL-CTOR')
	public function testUnderAClosedWorldAConstructorStaysARoot(): Void {
		#if (sys || nodejs)
		Assert.same(
			['main thread reaches blocking "Sys.sleep": Main.new -> Sys.sleep'],
			sleepFindings('"closedWorld":true', ['class Main { public function new() Sys.sleep(1); }'])
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An `override` of a library supertype's method is the library's to call: it stays a root under `closedWorld`. */
	@:pin('control') @:killer('M-TS-SEAL-OVERRIDE')
	public function testUnderAClosedWorldAnOverrideStaysARoot(): Void {
		#if (sys || nodejs)
		Assert.same(['main thread reaches blocking "Sys.sleep": A.tick -> Sys.sleep'], sleepFindings('"closedWorld":true', [
			'class A extends LibrarySprite { public function new() {} override function tick():Void Sys.sleep(1); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A method an interface the index does not hold may declare is reached through it: it stays a root under `closedWorld`. */
	@:pin('control') @:killer('M-TS-SEAL-SUPERTYPE')
	public function testUnderAClosedWorldAnUnindexedInterfacesMemberStaysARoot(): Void {
		#if (sys || nodejs)
		Assert.same(['main thread reaches blocking "Sys.sleep": A.tick -> Sys.sleep'], sleepFindings('"closedWorld":true', [
			'class A implements LibraryTicker { public function new() {} public function tick():Void Sys.sleep(1); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A method an unresolved call may name (`x.tick()` on a `Dynamic`) may run from there: it stays a root under `closedWorld`. */
	@:pin('control') @:killer('M-TS-SEAL-UNRESOLVED')
	public function testUnderAClosedWorldAMethodAnUnresolvedCallMayNameStaysARoot(): Void {
		#if (sys || nodejs)
		Assert.same(['main thread reaches blocking "Sys.sleep": A.tick -> Sys.sleep'], sleepFindings('"closedWorld":true', [
			'class A { public function new() {} public function tick():Void Sys.sleep(1); }',
			'class B { public static function main():Void { final x:Dynamic = null; x.tick(); } }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold in a method no thread runs holds nothing: no finding for `dead`, whose throw under `_m` never happens. */
	@:pin('control') @:killer('M-TS-DEAD-HOLDS-KEPT')
	public function testUnderAClosedWorldAHoldNoThreadRunsIsQuiet(): Void {
		#if (sys || nodejs)
		Assert.same([], sleepFindings('"closedWorld":true,"lockPairs":["Mutex.acquire/release"]', [
			ThreadSafetyCheckTest.MUTEX,
			'class A { final _m:Mutex = new Mutex(); public function new() {} public function dead(n:Int):Void { _m.acquire();'
			+ ' if (n > 0) throw "n"; _m.release(); } public function ui():Void { _m.acquire(); _m.release(); }'
			+ ' public static function main():Void new A().ui(); }'
		]));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `final` local bound to a condition decides a read of its name only where that read means it: in its block, after
	 * it. A read outside the block or outside the lambda that declares it means the member (review r4 `A1`, `A2`).
	 */
	@:pin('control') @:killer('M-TS-COND-LOCAL-ANY-BLOCK')
	public function testAFinalLocalDecidesOnlyTheReadsItBinds(): Void {
		#if (sys || nodejs)
		final reached: Array<String> = [
			'main thread reaches blocking "Sys.sleep" (also reachable from a background thread): S.main -> S.save -> Sys.sleep'
		];
		Assert.same([], sleepFindings('', [savesUnder('final ready:Bool = !batch; if (ready) Sys.sleep(1);')]), 'the local');
		Assert.same(reached, sleepFindings('', [
			savesUnder('if (c) { final ready:Bool = !batch; use(ready); } if (ready) Sys.sleep(1);')
		]), 'an inner block');
		Assert.same(reached, sleepFindings('', [
			savesUnder('final f:() -> Void = () -> { final ready:Bool = !batch; use(ready); }; f(); if (ready) Sys.sleep(1);')
		]), 'a lambda');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `S.save(batch)` runs `body`; the main thread saves a batch, a worker a single one. */
	private static function savesUnder(body: String): String {
		return 'class S { var ready:Bool = true; var c:Bool = true; public function new() {} function use(b:Bool):Void {}'
			+ ' function save(batch:Bool):Void { $body }'
			+ ' public static function main():Void { final s:S = new S(); s.save(true); Runner.create(() -> s.save(false)); } }';
	}

	/**
	 * Every message of a `Sys.sleep` run over `sources` (plus `Runner`, whose `create` is a spawn), `extra` added to the
	 * rule's options (`"key":value,…` or empty), sorted.
	 */
	private static function sleepFindings(extra: String, sources: Array<String>): Array<String> {
		final found: Array<String> = [
			for (v in ThreadSafetyCheckTest.violations(
				'{"rules":{"thread-safety":{"sinks":["Sys.sleep","Lock.wait","Mutex.acquire"],"spawns":["Runner.create"]'
				+ (extra.length > 0 ? ',$extra' : '') + '}}}',
				['class Runner { public static function create(fn:()->Void):Void {} }'].concat(sources)
			)) v.message
		];
		found.sort(Reflect.compare);
		return found;
	}
	#end

}
