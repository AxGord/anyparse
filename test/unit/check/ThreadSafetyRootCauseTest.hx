package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * One warning per root cause (`RootCauseFold`, `MainSinkReport`): a hold long only by waiting for a lock whose long
 * holds warn themselves, or by work another warned hold does too, is info naming them; sink calls one main-thread way
 * runs together, and the calls one loop repeats, make one warning.
 */
class ThreadSafetyRootCauseTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep","Disk.read",'
		+ '"Disk.stat","Disk.list"],"shortSinks":["Disk.stat","Disk.list"],"spawns":["Runner.create"],'
		+ '"lockPairs":["Mutex.acquire/release"]}}}';

	/** the client's `StandardDiskSystem.saveXML`: under the mutation lock it waits for the tree lock `updateInternal` holds long. */
	@:pin('control') @:killer('M-TS-FOLD-OFF')
	public function testAHoldLongOnlyByWaitingForAWarnedHolderIsInfo(): Void {
		#if (sys || nodejs)
		Assert.same(['info B S.save | S._x', 'warning B S.scan | S._t'], holds(waits('')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** the client's `saveXML`, whose `catch` reports over HTTP: a call only a `catch` runs is no reason the warning warns. */
	@:pin('control') @:killer('M-TS-FOLD-NORMAL')
	public function testACallOnlyACatchRunsLeavesTheFoldStanding(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info B S.save | S._x', 'warning B S.scan | S._t'],
			holds(waits('', '', 'try { step(); } catch (e:Dynamic) { Sys.sleep(1); }'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A lock long also by a release in another function is long by what no hold names: the waiter keeps its warning. */
	@:pin('control') @:killer('M-TS-FOLD-CROSSING')
	public function testALockReleasedElsewhereLeavesTheWaiterWarned(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B S.save | S._x', 'warning B S.scan | S._t'],
			holds(waits(' public function close():Void _t.release();', 's.close();'), ['S.save', 'S.scan'])
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * the client's `renameCloudFolderBlocked` over the loop `moveCloudFolderSubItemsAction2` runs under its own lock: a hold whose
	 * every way to a sink call passes a function holding a lock across it is that hold's work, one warning — the hold nearest
	 * the call's. Two holds in one function covering each other keep the one nearest the work. A hold elsewhere across its
	 * own call to the same sink, of the same lock or another, is a stall of its own.
	 */
	@:pin('control') @:killer('M-TS-FOLD-SITE') @:killer('M-TS-FOLD-DEPTH') @:killer('M-TS-FOLD-SITE-LOCK')
	public function testHoldsLongByOneCallMakeOneWarning(): Void {
		#if (sys || nodejs)
		Assert.same(['info B A.a | A._x', 'warning B A.z | A._y'], holds(oneCall('_y', 'z()')), 'through a hold of another lock');
		Assert.same(['warning B A.a | A._x', 'warning B A.z | A._x'], holds(oneCall('_x', 'w()')), 'beside it');
		Assert.same(['warning B A.a | A._x', 'warning B A.z | A._y'], holds(oneCall('_y', 'w()')), 'beside another lock');
		final cycle: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			inOne('_x.acquire(); v(); _x.release(); _x.acquire(); w(); _x.release();')
		]);
		Assert.same(['info B A.f | A._x', 'warning B A.f | A._x'], holds(cycle), 'two holds of one function');
		Assert.same(['A.w -> Sys.sleep'], warnedWays(cycle), 'the one nearest its work stays');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two holds of one lock in two functions, each across its own call to the same sink, are two stalls on ONE thread as on
	 * two (the client's `RemoteDiskSystemBase.moveCloudFileBlocked` holding the batch lock across its own `getTimestamp` stat, beside
	 * `addCloudActionValidated` reaching that stat through `addCloudAction2`; `StandardDiskSystem.loadModelContent` on the
	 * I/O worker against `getText` on the sync worker): narrowing one hold frees nothing of the other, so neither covers.
	 */
	@:pin('control') @:killer('M-TS-FOLD-SITE-LOCK')
	public function testHoldsOfOneLockInTwoFunctionsAreTwoStalls(): Void {
		#if (sys || nodejs)
		final two: Array<String> = ['warning B A.a | A._x', 'warning B A.z | A._x'];
		Assert.same(two, holds(twoThreads('Runner.create(() -> s.a()); Pool.create(() -> s.z());')), 'two threads');
		Assert.same(two, holds(twoThreads('Runner.create(() -> s.a()); Runner.create(() -> s.z());')), 'two callbacks of one spawn');
		Assert.same(two, holds(twoThreads('Runner.create(() -> { s.a(); s.z(); }); s.z();')), 'one thread, among more');
		Assert.same(two, holds(twoThreads('Runner.create(() -> { s.a(); s.z(); });')), 'one thread');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two locks no member names (each a getter's value) are not one lock for covering, though both are keyed by their
	 * pair's take member: two holds one after the other in one function, each across the same work, stall on their own
	 * (review round 2 `u2p`).
	 */
	@:pin('control') @:killer('M-TS-FOLD-UNNAMED-SAME')
	public function testUnnamedLocksNeverCoverEachOther(): Void {
		#if (sys || nodejs)
		final s: String = 'class S { final _a:Mutex = new Mutex(); final _b:Mutex = new Mutex(); public function new() {}'
			+ ' function io():Void Sys.sleep(1); function getA():Mutex return _a; function getB():Mutex return _b;'
			+ ' function g():Void { final m:Mutex = getA(); m.acquire(); io(); m.release();'
			+ ' final n:Mutex = getB(); n.acquire(); io(); n.release(); }'
			+ ' public function peekB():Void { _b.acquire(); _b.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.g()); s.peekB(); } }';
		Assert.same(
			['warning B S.g | Mutex.acquire', 'warning B S.g | Mutex.acquire'],
			holds(ThreadSafetyCheckTest.violations(CONFIG, [ThreadSafetyCheckTest.MUTEX, RUNNER, s]))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A recursion through a value handed on that runs (`n.each(k -> walk(k))`) re-enters the walk under the lock, as a
	 * direct one does: the walk repeats its sink and is not covered by a hold reaching it once; a value the runtime only
	 * registers runs per event, closing no cycle under the lock (review round 2 `r1`).
	 */
	@:pin('control') @:killer('M-TS-CYCLE-REGISTERED')
	public function testARecursionThroughACallbackRepeatsUnderTheLock(): Void {
		#if (sys || nodejs)
		final walk: String = 'class S { final _m:Mutex = new Mutex(); public function new() {} function io():Void Sys.sleep(1);'
			+ ' function f(root:Node):Void { _m.acquire(); walk(root); _m.release(); _m.acquire(); io(); _m.release(); }'
			+ ' public function peek():Void { _m.acquire(); _m.release(); }'
			+ ' public static function main():Void { final s:S = new S(); final r:Node = new Node();'
			+ ' Runner.create(() -> s.f(r)); s.peek(); }';
		final node: String = 'class Node { public var kids:Array<Node> = []; public function new() {}'
			+ ' public function each(f:Node->Void):Void for (k in kids) f(k); }';
		final runs: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			node,
			'$walk function walk(n:Node):Void { io(); n.each(k -> walk(k)); } }'
		]);
		Assert.same(['info B S.f | S._m', 'warning B S.f | S._m'], holds(runs), 'a callback that runs');
		Assert.same(['S.walk -> S.io -> Sys.sleep'], warnedWays(runs), 'a callback that runs: the walk stays');
		final hub: String = 'interface IHub { function addEventListener(f:Node->Void):Void; }'
			+ ' class Node { public var hub:IHub = null; public function new() {} }';
		final registered: Array<Violation> = ThreadSafetyCheckTest.violations(
			StringTools.replace(CONFIG, '"spawns"', '"registers":["addEventListener"],"spawns"'), [
				ThreadSafetyCheckTest.MUTEX,
				RUNNER,
				hub,
				'$walk function walk(n:Node):Void { io(); n.hub.addEventListener(k -> walk(k)); } }'
			]
		);
		Assert.same(['info B S.f | S._m', 'warning B S.f | S._m'], holds(registered), 'a registration');
		Assert.same(['S.io -> Sys.sleep'], warnedWays(registered), 'a registration: the hold nearest the sink stays');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two holds of different locks one after the other in one function are two stalls: one does not cover the other
	 * for sharing the work's sink (review round 2 `s1`). One taken inside the other does.
	 */
	@:pin('control') @:killer('M-TS-FOLD-NEST-LOCK')
	public function testHoldsOfTwoLocksOneAfterTheOtherAreTwoStalls(): Void {
		#if (sys || nodejs)
		final s: String = 'class S { final _a:Mutex = new Mutex(); final _b:Mutex = new Mutex(); public function new() {}'
			+ ' function io():Void Sys.sleep(1); public function peekA():Void { _a.acquire(); _a.release(); }'
			+ ' public function peekB():Void { _b.acquire(); _b.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(s.f); s.peekA(); s.peekB(); }';
		Assert.same(['warning B S.f | S._a', 'warning B S.f | S._b'], holds(ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'$s function f():Void { _a.acquire(); io(); _a.release(); _b.acquire(); io(); _b.release(); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** the client's `PathIO.deleteRecursive`: the sink calls one main-thread way into a function runs make one warning. */
	@:pin('control') @:killer('M-TS-WAY-OFF')
	public function testSinkCallsOfOneWayMakeOneWarning(): Void {
		#if (sys || nodejs)
		Assert.same(['info A F.f | Sys.sleep', 'warning A F.f | Disk.read'], mains(ThreadSafetyCheckTest.violations(CONFIG, [
			DISK,
			'class F { static function f():Void { Disk.read("a"); Sys.sleep(1); } public static function main():Void f(); }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** the client's `repairShareAttr`: the calls one loop repeats make one warning, keyed by the first. */
	@:pin('control') @:killer('M-TS-LOOP-KEY')
	public function testTheCallsOfOneLoopMakeOneWarning(): Void {
		#if (sys || nodejs)
		Assert.same(
			[
				'info A L.a | Disk.stat',
				'info A L.b | Disk.list',
				'warning A L.main | for (i in 0...3)'
			],
			mains(ThreadSafetyCheckTest.violations(CONFIG, [
				DISK,
				'class L { static function a():Void Disk.stat("a"); static function b():Void Disk.list("b");'
				+ ' public static function main():Void for (i in 0...3) { a(); b(); } }'
			]))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two takes of one lock whose holds name the same calls share one finding (review `c5`, `c5b`): one warned hold,
	 * which never covers itself — the warning stays.
	 */
	@:pin('control') @:killer('M-TS-FOLD-SELF')
	public function testTwoTakesSharingAFindingDoNotCoverEachOther(): Void {
		#if (sys || nodejs)
		final branches: String =
			'public function work(c:Bool):Void { if (c) _b.acquire(); else _b.acquire(); Sys.sleep(1); _b.release(); }';
		Assert.same(['warning B S.work | S._b'], holds(twoTakes(branches, '', 's.work(Math.random() > 0.5);')));
		final directives: String =
			'public function work():Void {\n#if mac\n_b.acquire();\n#else\n_b.acquire();\n#end\nSys.sleep(1); _b.release(); }';
		Assert.same(['warning B S.work | S._b'], holds(twoTakes(directives, '', 's.work();')), 'one take per #if branch');
		// a hold waiting for that lock folds onto the warning, which stays (review `c5c`)
		Assert.same(
			['info B S.zother | S._a', 'warning B S.work | S._b'],
			holds(twoTakes(
				branches, 'public function zother():Void { _a.acquire(); _b.acquire(); _b.release(); _a.release(); }',
				's.work(Math.random() > 0.5); s.zother();'
			)),
			'chained'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A hold reaching a sink call once covers no hold repeating that call under its lock (the client's `VolumeWatcher.rename`'s
	 * one stat against `updateInternal`'s walk over the tree): the repeating hold keeps the warning, and the one-call
	 * hold folds onto it.
	 */
	@:pin('control') @:killer('M-TS-FOLD-SITE-ONCE')
	public function testAHoldReachingACallOnceCoversNoRepeatingOne(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			inOne('_x.acquire(); for (i in 0...3) v(); _x.release(); _x.acquire(); w(); _x.release();')
		]);
		Assert.same(['info B A.f | A._x', 'warning B A.f | A._x'], holds(found));
		Assert.same(['A.v -> A.w -> Sys.sleep'], warnedWays(found), 'the repeating hold stays');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A call reached through a function a cycle of calls re-enters repeats however the trail found it (the client's
	 * `VolumeWatcher.updateInternal`, whose `checkNode` walks the tree recursively): no hold reaching it once covers it.
	 */
	@:pin('control') @:killer('M-TS-FOLD-SITE-CYCLE') @:killer('M-TS-CYCLE-REF')
	public function testACallUnderARecursiveWalkRepeats(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			inOne('_x.acquire(); walk(3); _x.release(); _x.acquire(); w(); _x.release();')
		]);
		Assert.same(['info B A.f | A._x', 'warning B A.f | A._x'], holds(found));
		Assert.same(['A.walk -> A.w -> Sys.sleep'], warnedWays(found), 'the walk stays');
		// a recursion through a value handed to a call that runs it once: no call on the way repeats, the walk still does
		final once: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG.replace('"spawns"', '"runsOnce":["Once.run"],"spawns"'), [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class Once { public static function run(x:Int, fn:Int->Void):Void fn(x); }',
			'class A { final _x:Mutex = new Mutex(); public function new() {}'
			+ ' function walk(n:Int):Void { step(); if (n > 0) Once.run(n - 1, k -> walk(k)); } function step():Void Sys.sleep(1);'
			+ ' public function f():Void { _x.acquire(); walk(3); _x.release(); _x.acquire(); step(); _x.release(); }'
			+ ' public static function main():Void { final s:A = new A(); Runner.create(() -> s.f()); s._x.acquire(); s._x.release(); } }'
		]);
		Assert.same(['info B A.f | A._x', 'warning B A.f | A._x'], holds(once), 'through a value run once');
		Assert.same(['A.walk -> A.step -> Sys.sleep'], warnedWays(once), 'through a value run once: the walk stays');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A call is covered only when EVERY blocking call it reaches is (review round 4 `f1`): the second hold's `both()` reaches
	 * the read the first hold also holds `_x` across, and a sleep no other hold reaches. Read from its first trail alone, the
	 * call was covered by the first, the hold turned info, and nothing named the sleep. Now it keeps its warning whichever call
	 * the walk finds first, and the first folds onto it; without the sleep the two cover each other and the one nearest its
	 * work stays.
	 */
	@:pin('control') @:killer('M-TS-FOLD-EVERY-END') @:killer('M-TS-FOLD-ENDS-WALK') @:killer('M-TS-FOLD-PASSES-PATH')
	@:killer('M-TS-FOLD-NAMED-ONLY') @:killer('M-TS-FOLD-UNNAMED-NOTE')
	public function testACallIsCoveredOnlyWhenEveryBlockingCallItReachesIs(): Void {
		#if (sys || nodejs)
		final both: Array<Violation> = twoWays('shared(); deep();');
		Assert.same(['info B A.f | A._x', 'warning B A.f | A._x'], holds(both));
		Assert.same(['A.both -> A.shared -> Disk.read'], warnedWays(both), 'the hold reaching the sleep stays');
		// the warning names the sleep it stays for, which its first way does not show
		final kept: Null<Violation> = both.filter(v -> v.data?.member == 'A.f' && v.severity == Severity.Warning)[0];
		Assert.isTrue(
			kept?.message.endsWith(' — its calls also reach A.both -> A.deep -> Sys.sleep, which no warning names') == true, kept?.message
		);
		final one: Array<Violation> = twoWays('shared();');
		Assert.same(['info B A.f | A._x', 'warning B A.f | A._x'], holds(one), 'one blocking call');
		Assert.same(['A.shared -> Disk.read'], warnedWays(one), 'one blocking call: the hold nearest it stays');
		// a hold on the way covers a call only when EVERY way to its sink passes that hold's function: `S.x` reaches the
		// sleep through `p`, which holds `_y` across it, and through `slow` too, outside any hold of `_y`
		Assert.same(['warning B S.p | S._y', 'warning B S.x | S._x'], holds(passing('p(); slow();')), 'a way past the hold');
		Assert.same(['info B S.x | S._x', 'warning B S.p | S._y'], holds(passing('p();')), 'every way past the hold');
		// a hold covers another only by the work its finding names: the second names the read, so the sleep it also reaches
		// covers nothing, and the third, long by that sleep alone, keeps its warning
		final named: String = 'class A { final _x:Mutex = new Mutex(); public function new() {}'
			+ ' public function f():Void { _x.acquire(); shared(); _x.release(); _x.acquire(); both(); _x.release();'
			+ ' _x.acquire(); far(); _x.release(); } function both():Void { shared(); deep(); }'
			+ ' function far():Void farther(); function farther():Void deep();'
			+ ' function deep():Void Sys.sleep(1); function shared():Void Disk.read("x");'
			+ ' public static function main():Void { final s:A = new A(); Runner.create(() -> s.f());'
			+ ' s._x.acquire(); s._x.release(); } }';
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [ThreadSafetyCheckTest.MUTEX, RUNNER, DISK, named]);
		Assert.same(['info B A.f | A._x', 'warning B A.f | A._x', 'warning B A.f | A._x'], holds(found), 'named work only');
		Assert.same(['A.far -> A.farther -> A.deep -> Sys.sleep', 'A.shared -> Disk.read'], warnedWays(found), 'named work only: kept');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A hold covers a sink call of another only when EVERY way the other's calls take to it passes the hold's function
	 * (review round 5, G3): `S.x` reaches the sleep through `p`, which holds `_y` across it, AND by calling `io` itself,
	 * outside any hold of `_y`. Two calls reaching one sink are two ways; folding them to the first call's used to cover
	 * the second by the first's, in whichever order they were written. With the take of a lock no sink, `p`'s first way
	 * ends at the sleep too, as the client's `Mutex.acquire` (a `lockPairs` take, not a sink) does.
	 */
	@:pin('control') @:killer('M-TS-FOLD-SAME-WAY') @:killer('M-TS-FOLD-PARTS-ONCE')
	public function testTwoCallsReachingOneSinkAreTwoWays(): Void {
		#if (sys || nodejs)
		Assert.same(['warning B S.p | S._y', 'warning B S.x | S._x'], holds(acrossCalls('p(); io();')), 'the covered way first');
		Assert.same(['warning B S.p | S._y', 'warning B S.x | S._x'], holds(acrossCalls('io(); p();')), 'the uncovered way first');
		Assert.same(['info B S.x | S._x', 'warning B S.p | S._y'], holds(acrossCalls('p(); p();')), 'every way past the hold');
		// `q` reaches the sleep through `p` too, by a way of its own: two reasons, one covering hold, said once
		final twice: Array<Violation> = acrossCalls('q(); p();');
		Assert.same(['info B S.x | S._x', 'warning B S.p | S._y'], holds(twice), 'two ways past the hold');
		final folded: Null<Violation> = twice.filter(v -> v.data?.member == 'S.x')[0];
		Assert.isTrue(
			folded?.message.endsWith(' — long only through work S.p also holds a lock across, reported there') == true, folded?.message
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A suppressed warning reports nothing, so it covers nothing (review round 4 `f2`): `A.b` holds `_x` across the sleep
	 * `A.a` holds it across too, and `A.a`'s warning carries `noqa`. `A.b` used to fold onto it, leaving the stall named only
	 * by an info finding.
	 */
	@:pin('control') @:killer('M-TS-FOLD-SUPPRESSED') @:killer('M-TS-FOLD-SUPPRESSED-WAIT') @:killer('M-TS-NEST-SUPPRESSED')
	@:killer('M-TS-WAY-SUPPRESSED') @:killer('M-TS-ONE-TAKE-SUPPRESSED')
	public function testASuppressedWarningCoversNothing(): Void {
		#if (sys || nodejs)
		final s: String = 'class A { final _x:Mutex = new Mutex(); public function new() {} function io():Void Sys.sleep(1);\n'
			+ ' function pad():Void io();\n public function f():Void {\n _x.acquire(); io(); _x.release(); // noqa: thread-safety\n'
			+ ' _x.acquire(); pad(); _x.release(); }\n'
			+ ' public static function main():Void { final s:A = new A(); Runner.create(() -> s.f());'
			+ ' s._x.acquire(); s._x.release(); } }';
		final silenced: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [ThreadSafetyCheckTest.MUTEX, RUNNER, s]);
		Assert.same(['warning B A.f | A._x'], holds(silenced));
		Assert.same(['A.pad -> A.io -> Sys.sleep'], warnedWays(silenced));
		final plain: String = s.replace(' // noqa: thread-safety', '');
		final open: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [ThreadSafetyCheckTest.MUTEX, RUNNER, plain]);
		Assert.same(['info B A.f | A._x', 'warning B A.f | A._x'], holds(open), 'not suppressed');
		Assert.same(['A.io -> Sys.sleep'], warnedWays(open), 'not suppressed: the hold nearest the sleep stays');
		// a hold waiting for a lock whose long hold is silenced
		final waiting: String = 'class S { final _t:Mutex = new Mutex(); final _x:Mutex = new Mutex(); public function new() {}\n'
			+ ' public function scan():Void { _t.acquire(); Sys.sleep(1); _t.release(); } // noqa: thread-safety\n'
			+ ' public function save():Void { _x.acquire(); _t.acquire(); _t.release(); _x.release(); }\n'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> { s.scan(); s.save(); });'
			+ ' s._x.acquire(); s._x.release(); s._t.acquire(); s._t.release(); } }';
		Assert.same(
			['warning B S.save | S._x'],
			holds(ThreadSafetyCheckTest.violations(CONFIG, [ThreadSafetyCheckTest.MUTEX, RUNNER, waiting])), 'a wait'
		);
		// a hold taken inside a hold whose warning is silenced
		final nested: String = 'class N { final _x:Mutex = new Mutex(); final _y:Mutex = new Mutex(); public function new() {}\n'
			+ ' function io():Void Sys.sleep(1); public function f():Void { _x.acquire(); io(); // noqa: thread-safety\n'
			+ ' _y.acquire(); io(); _y.release(); _x.release(); }\n'
			+ ' public static function main():Void { final s:N = new N(); Runner.create(() -> s.f());'
			+ ' s._x.acquire(); s._x.release(); s._y.acquire(); s._y.release(); } }';
		Assert.same(
			['warning B N.f | N._y'],
			holds(ThreadSafetyCheckTest.violations(CONFIG, [ThreadSafetyCheckTest.MUTEX, RUNNER, nested])), 'nested'
		);
		// of one main-thread way's sink calls, one not silenced keeps the warning
		Assert.same(['warning A F.f | Sys.sleep'], mains(ThreadSafetyCheckTest.violations(CONFIG, [
			DISK,
			'class F { static function f():Void {\n Disk.read("a"); // noqa: thread-safety\n Sys.sleep(1); }\n'
			+ ' public static function main():Void f(); }'
		])), 'one way');
		// of one lock's main-thread takes, one not silenced keeps the warning
		Assert.same(['warning A S.put | Mutex.acquire'], mains(ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class S { static final _m:Mutex = new Mutex(); static function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); }\n'
			+ ' static function get():Void { _m.acquire(); // noqa: thread-safety\n _m.release(); }\n'
			+ ' static function put():Void { _m.acquire(); _m.release(); }\n'
			+ ' public static function main():Void { Runner.create(work); get(); put(); } }'
		])), 'one lock');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A hold turned info onto another hold's finding says so when that finding ends info itself (review round 4, T3's
	 * helper-pair text): `S.b` takes `_y` inside its hold of `_x`, and every way of that hold to the sleep passes `S.c`, which
	 * holds `_z` across it, so it folds onto `S.c`'s. The `_y` hold's message names a finding that warns nowhere, and says
	 * where its work is reported.
	 */
	@:pin('control') @:killer('M-TS-COVER-INFO-NOTE')
	public function testAHoldTurnedOntoAnInfoFindingSaysSo(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class S { final _x:Mutex = new Mutex(); final _y:Mutex = new Mutex(); final _z:Mutex = new Mutex(); public function new() {}'
			+ ' function io():Void Sys.sleep(1); public function c():Void { _z.acquire(); io(); _z.release(); }'
			+ ' public function b():Void { _x.acquire(); _y.acquire(); c(); _y.release(); _x.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> { s.c(); s.b(); });'
			+ ' s._x.acquire(); s._x.release(); s._y.acquire(); s._y.release(); s._z.acquire(); s._z.release(); } }'
		]);
		Assert.same(['info B S.b | S._x', 'info B S.b | S._y', 'warning B S.c | S._z'], holds(found));
		final inner: Null<Violation> = found.filter(v -> v.data?.member == 'S.b' && v.data?.subject == 'S._y')[0];
		Assert.isTrue(inner?.message.endsWith(NAMED_INFO) == true, inner?.message);
		final outer: Null<Violation> = found.filter(v -> v.data?.member == 'S.c')[0];
		Assert.isFalse(outer?.message.contains(NAMED_INFO) == true, outer?.message);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** What a hold turned onto another's finding adds when that finding ends info. */
	private static inline final NAMED_INFO: String = ' — that finding is itself info and says where its work is reported';

	private static inline final RUNNER: String = 'class Runner { public static function create(fn:()->Void):Void {} }';

	private static inline final DISK: String = 'class Disk { public static function read(p:String):Void {}'
		+ ' public static function stat(p:String):Void {} public static function list(p:String):Void {} }';

	/** `S.save` holds `_x` while it takes `_t`, which `S.scan` holds across a sleep, both on a worker; `more` adds members. */
	private static function waits(more: String, ?worker: String, ?saving: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class S { final _t:Mutex = new Mutex(); final _x:Mutex = new Mutex(); public function new() {}'
			+ ' public function scan():Void { _t.acquire(); Sys.sleep(1); _t.release(); }'
			+ ' function step():Void {} public function save():Void { _x.acquire(); _t.acquire(); _t.release(); ${saving ?? ''} _x.release(); }$more'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> { s.scan(); s.save(); ${worker ?? ''} });'
			+ ' s._x.acquire(); s._x.release(); s._t.acquire(); s._t.release(); } }'
		]);
	}

	/** `A.a` holding `_x` across `v`, which calls `w`, and `A.z` holding `zLock` across `w` itself: both long by `w`'s sleep. */
	private static function oneCall(zLock: String, vCalls: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class A { final _x:Mutex = new Mutex(); final _y:Mutex = new Mutex(); public function new() {}'
			+ ' public function a():Void { _x.acquire(); v(); _x.release(); } function v():Void $vCalls; function w():Void Sys.sleep(1);'
			+ ' public function z():Void { $zLock.acquire(); w(); $zLock.release(); }'
			+ ' public static function main():Void { final s:A = new A(); Runner.create(() -> { s.a(); s.z(); });'
			+ ' s._x.acquire(); s._x.release(); s._y.acquire(); s._y.release(); } }'
		]);
	}
	/** `A.a` holding `_x` across a read, `A.b` holding it across `both()`, which runs `body`; `deep()` sleeps. */
	private static function twoWays(body: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			DISK,
			'class A { final _x:Mutex = new Mutex(); public function new() {}'
			+ ' public function f():Void { _x.acquire(); shared(); _x.release(); _x.acquire(); both(); _x.release(); }'
			+ ' function both():Void { $body }' + ' function deep():Void Sys.sleep(1); function shared():Void Disk.read("x");'
			+ ' public static function main():Void { final s:A = new A(); Runner.create(() -> s.f());'
			+ ' s._x.acquire(); s._x.release(); } }'
		]);
	}

	/** `S.x` holding `_x` across `both()`, which runs `body`; `p` holds `_y` across `io()`, and `slow` reaches `io()` holding nothing. */
	private static function passing(body: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class S { final _x:Mutex = new Mutex(); final _y:Mutex = new Mutex(); public function new() {}'
			+ ' function io():Void Sys.sleep(1); function p():Void { _y.acquire(); io(); _y.release(); }'
			+ ' function pad():Void io(); function slow():Void pad(); function both():Void { $body }'
			+ ' public function x():Void { _x.acquire(); both(); _x.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> { s.x(); s.p(); });'
			+ ' s._x.acquire(); s._x.release(); s._y.acquire(); s._y.release(); } }'
		]);
	}
	/**
	 * `S.x` holding `_x` across `body` itself; `p` holds `_y` across `io()`, which sleeps. A lock's take is no sink here, so
	 * a call into `p` names the sleep as its first way.
	 */
	private static function acrossCalls(body: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG.replace('"Mutex.acquire",', ''), [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class S { final _x:Mutex = new Mutex(); final _y:Mutex = new Mutex(); public function new() {}'
			+ ' function io():Void Sys.sleep(1); function p():Void { _y.acquire(); io(); _y.release(); } function q():Void p();'
			+ ' public function x():Void { _x.acquire(); $body _x.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> { s.x(); s.p(); });'
			+ ' s._x.acquire(); s._x.release(); s._y.acquire(); s._y.release(); } }'
		]);
	}

	/** `oneCall`'s `A.a` and `A.z`, both holding `_x` across `w`, run from the main thread by `running`. */
	private static function twoThreads(running: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG.replace('"spawns":["Runner.create"]', '"spawns":["Runner.create","Pool.create"]'), [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class Pool { public static function create(fn:()->Void):Void {} }',
			'class A { final _x:Mutex = new Mutex(); public function new() {}'
			+ ' public function a():Void { _x.acquire(); v(); _x.release(); } function v():Void w(); function w():Void Sys.sleep(1);'
			+ ' public function z():Void { _x.acquire(); w(); _x.release(); }'
			+ ' public static function main():Void { final s:A = new A(); $running' + ' s._x.acquire(); s._x.release(); } }'
		]);
	}
	/** `S` with locks `_a` and `_b`, `work` and `more` declared, a worker running `background`, and the main thread taking both. */
	private static function twoTakes(work: String, more: String, background: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class S { final _a:Mutex = new Mutex(); final _b:Mutex = new Mutex(); public function new() {} $work $more'
			+ ' public function peek():Void { _a.acquire(); _a.release(); _b.acquire(); _b.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> { $background }); s.peek(); } }'
		]);
	}
	private static function holds(found: Array<Violation>, ?only: Array<String>): Array<String> {
		return graded(found, 'B', only);
	}

	private static function mains(found: Array<Violation>): Array<String> {
		return graded(found, 'A', null);
	}

	private static function graded(found: Array<Violation>, family: String, only: Null<Array<String>>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == family && (only == null || only.contains(data.member)))
					'${v.severity.label()} $family ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

	/**
	 * `A`, whose one function `f` runs `body` on a worker: holds of one lock in one function cover each other (`nests`), the
	 * shape a fold among holds of ONE hold's work takes — `v` reaches the sleep through `w`, `walk` repeats it.
	 */
	private static function inOne(body: String): String {
		return 'class A { final _x:Mutex = new Mutex(); public function new() {} function v():Void w(); function w():Void Sys.sleep(1);'
			+ ' function walk(n:Int):Void { w(); if (n > 0) walk(n - 1); }'
			+ ' public function f():Void { $body } public static function main():Void { final s:A = new A();'
			+ ' Runner.create(() -> s.f()); s._x.acquire(); s._x.release(); } }';
	}

	/** The calls each warned hold (b) of `found` names, after "can block: ", sorted. */
	private static function warnedWays(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) if (v.data?.family == 'B' && v.severity == Severity.Warning) {
				final at: Int = v.message.indexOf('can block: ');
				at < 0 ? v.message : v.message.substr(at + 'can block: '.length).split(' — ')[0];
			}
		];
		out.sort(Reflect.compare);
		return out;
	}

}
