package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A function value handed to a call that runs it runs where it is handed: under the hold around that call, and as often
 * as that call repeats it (`Lambda.iter` runs it per element). Before, a hold's taint followed only invocations, so a
 * lock held across `Lambda.iter(paths, load)` — `load` blocking — was silent, and so was every lambda handed on under a
 * hold. A value handed to a call that runs it elsewhere — on another thread (`spawns`, `marshals`), once per event
 * (`registers`), never (`neverInvokes`) — taints nothing there.
 */
class ThreadSafetyHandedValueTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Disk.stat","Disk.peek"],'
		+ '"shortSinks":["Disk.peek"],"spawns":["Runner.create"],"marshals":["Ui.post"],"registers":["addEventListener"],'
		+ '"runsOnce":["Once.run"],"neverInvokes":["Never.drop"],"lockPairs":["Mutex.acquire/release"],'
		+ '"nonBlocking":["D.new the dispatcher stands for a library class, no project native",'
		+ '"D.addEventListener keeps the handler and runs nothing"]}}}';

	/**
	 * Review fixture `ep1b-iter-in-caller`: a method value, a lambda and a sink itself, each handed to `Lambda.iter` under the
	 * hold, and a value handed on inside a call the hold makes.
	 */
	@:pin('control') @:killer('M-TS-HANDED-RUNS-HERE') @:killer('M-TS-HANDED-WINDOW-OFF') @:killer('M-TS-HANDED-REACH-OFF')
	@:killer('M-TS-HANDED-SINK-OFF')
	public function testAHoldTaintsAValueHandedToACallThatRunsIt(): Void {
		#if (sys || nodejs)
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, load);')), 'a method value');
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, p -> Disk.stat(p));')), 'a lambda');
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, Disk.stat);')), 'a sink handed as a value');
		Assert.same(['S.work | S._m'], holds(run('scan();')), 'handed inside a call the hold makes');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The value repeats with the call it is handed to: a short sink once per element of `Lambda.iter` keeps the lock long,
	 * once under a `runsOnce` call it does not; a sink only a `catch` runs counts on the normal paths when the value repeats.
	 */
	@:pin('control') @:killer('M-TS-REPEAT-NO-ITERATES') @:killer('M-TS-RUNS-ONCE-OFF')
	public function testAHandedValueRepeatsWithTheCallItIsHandedTo(): Void {
		#if (sys || nodejs)
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, p -> Disk.peek(p));')), 'per element');
		Assert.same([], holds(run('Once.run("a", p -> Disk.peek(p));')), 'run once');
		Assert.same(['S.work | S._m'], holds(run('Lambda.iter(paths, caught);')), 'a catch per element');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A value a call runs on another thread, once per event or never, taints nothing under the hold around the call. */
	@:pin('control') @:killer('M-TS-HANDED-ELSEWHERE') @:killer('M-TS-CYCLE-REGISTERED')
	public function testAValueRunElsewhereTaintsNothing(): Void {
		#if (sys || nodejs)
		Assert.same([], holds(run('Runner.create(() -> Disk.stat("x"));')), 'spawned');
		Assert.same([], holds(run('Ui.post(() -> Disk.stat("x"));')), 'marshalled');
		Assert.same([], holds(run('new D().addEventListener("x", e -> Disk.stat(e));')), 'registered');
		Assert.same([], holds(run('Never.drop(() -> Disk.stat("x"));')), 'never run');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The main thread reaches a sink handed as a value to a call that runs it, as it reaches one it calls. */
	@:pin('control') @:killer('M-TS-HANDED-SINK-OFF')
	public function testAMainSinkHandedAsAValueIsReported(): Void {
		#if (sys || nodejs)
		Assert.same(['warning A S.main | Disk.stat'], mains(ThreadSafetyCheckTest.violations(CONFIG, [
			'class Disk { public static function stat(p:String):Void {} public static function peek(p:String):Void {} }',
			'class S { static final paths:Array<String> = ["a"]; public static function main():Void Lambda.iter(paths, Disk.stat); }'
		])));
		Assert.same([], mains(ThreadSafetyCheckTest.violations(CONFIG, [
			'class Disk { public static function stat(p:String):Void {} public static function peek(p:String):Void {} }',
			'class Never { public static function drop(f:String->Void):Void {} }',
			'class S { public static function main():Void Never.drop(Disk.stat); }'
		])), 'never run');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A method value of ANOTHER object that takes the held re-entrant lock on its own object waits for that object's
	 * lock: handed to a call that runs it, it re-takes nothing of the holder's.
	 */
	@:pin('control') @:killer('M-TS-HANDED-RETAKE')
	public function testAMethodValueOfAnotherObjectWaitsForItsLock(): Void {
		#if (sys || nodejs)
		Assert.same(
			['S.slow | S._m', 'S.work | S._m'],
			holds(ThreadSafetyCheckTest.violations(
				StringTools.replace(CONFIG, '"lockPairs"', '"reentrantLocks":["Mutex.acquire"],"lockPairs"'), [
					ThreadSafetyCheckTest.MUTEX,
					'class Runner { public static function create(fn:()->Void):Void {} }',
					'class Disk { public static function stat(p:String):Void {} }',
					'class S { final _m:Mutex = new Mutex(); final paths:Array<String> = ["a", "b"]; public function new() {}'
					+ ' function locked(p:String):Void { _m.acquire(); _m.release(); }'
					+ ' function slow():Void { _m.acquire(); Disk.stat("x"); _m.release(); }'
					+ ' public function work():Void { _m.acquire(); final o:S = new S(); Lambda.iter(paths, o.locked); _m.release(); }'
					+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); Runner.create(() -> s.slow());'
					+ ' s._m.acquire(); s._m.release(); } }'
				]
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Lock order through a value handed on: the main thread holds `_a` across `Lambda.iter`, whose lambda or method value
	 * takes `_b` there, while a spawned worker holds `_b` and takes `_a`. Before, the order walk followed calls only, so
	 * the take of `_b` was made under no hold and the pair went unreported. A value run on another thread, or kept to run
	 * per event, takes `_b` under no hold of `_a`.
	 */
	@:pin('control') @:killer('M-TS-ORDER-HANDED') @:killer('M-TS-ORDER-HANDED-ANYWHERE') @:killer('M-TS-ORDER-FOLLOWS-REFS')
	@:killer('M-TS-ORDER-HANDED-RANK') @:killer('M-TS-ORDER-HANDED-CLIMB') @:killer('M-TS-ORDER-HANDED-VIA')
	public function testALockTakenInAHandedValueOrdersUnderTheHold(): Void {
		#if (sys || nodejs)
		final pair: Array<String> = ['S.main | S._a / S._b'];
		Assert.same(pair, orders('Lambda.iter(paths, p -> { _b.acquire(); _b.release(); });'), 'a lambda');
		Assert.same(pair, orders('Lambda.iter(paths, takeB);'), 'a method value');
		Assert.same([], orders('Runner.create(() -> takeB("x"));'), 'spawned');
		Assert.same([], orders('Hub.on(takeB);'), 'registered');
		Assert.same([], orders('Never.drop(() -> takeB("x"));'), 'never run');
		// the same pair made through calls alone too: that way names it, whatever member sorts first
		final direct: Array<String> = ['S.zDirect | S._a / S._b'];
		Assert.same(direct, orders('Lambda.iter(paths, p -> { _b.acquire(); _b.release(); });', true), 'a lambda and a call');
		Assert.same(direct, orders('Lambda.iter(paths, takeB);', true), 'a method value and a call');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `S.work` runs on a spawned thread and holds `_m` across `held`; the main thread takes `_m` too. `load` blocks, `caught` blocks only in its `catch`, `scan` hands `load` to `Lambda.iter`.
	 */
	private static function run(held: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class Ui { public static function post(fn:()->Void):Void {} }',
			'class Once { public static function run(x:String, fn:String->Void):Void fn(x); }',
			'class Never { public static function drop(fn:()->Void):Void {} }',
			'extern class D { public function new(); public function addEventListener(type:String, fn:String->Void):Void; }',
			'class Disk { public static function stat(p:String):Void {} public static function peek(p:String):Void {}'
			+ ' public static function parse(p:String):Int { if (p.length > 0) throw "bad"; return 0; } }',
			'class S { final _m:Mutex = new Mutex(); final paths:Array<String> = ["a", "b"]; public function new() {}'
			+ ' function load(p:String):Void Disk.stat(p); function scan():Void Lambda.iter(paths, load);'
			+ ' function caught(p:String):Void { try { Disk.parse(p); } catch (e:Dynamic) { Disk.stat(p); } }'
			+ ' public function work():Void { _m.acquire(); $held _m.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s._m.acquire(); s._m.release(); } }'
		]);
	}

	/** The hold warnings (b) of `found` as `<member> | <lock>`, sorted: a hold across short calls run once is info. */
	private static function holds(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'B' && v.severity.label() == 'warning') '${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}

	/** The main-thread findings (a) of `found` as `<severity> A <member> | <subject>`, sorted. */
	private static function mains(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'A') '${v.severity.label()} A ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	/**
	 * The lock-order findings (D) as `<member> | <locks>`, sorted, of a run where `S.main` holds the static `_a` across
	 * `held` after spawning `work`, which holds `_b` and takes `_a`; `takeB` takes `_b`, `Hub.on` registers a handler. With
	 * `direct`, `main` then calls `zDirect`, which calls `takeB` holding `_a`.
	 */
	private static function orders(held: String, direct: Bool = false): Array<String> {
		final call: String = direct ? 'zDirect();' : '';
		final found: Array<Violation> =
			ThreadSafetyCheckTest.violations(
				'{"rules":{"thread-safety":{"sinks":["Mutex.acquire"],"spawns":["Runner.create"],"registers":["Hub.on"],'
				+ '"neverInvokes":["Never.drop"],"lockPairs":["Mutex.acquire/release"]}}}',
				[
					ThreadSafetyCheckTest.MUTEX,
					'class Runner { public static function create(fn:()->Void):Void {} }',
					'class Never { public static function drop(fn:()->Void):Void {} }',
					'class Hub { public static function on(fn:String->Void):Void {} }',
					'class S { static final _a:Mutex = new Mutex(); static final _b:Mutex = new Mutex();'
					+ ' static final paths:Array<String> = ["x", "y"]; static function takeB(p:String):Void { _b.acquire(); _b.release(); }'
					+ ' static function work():Void { _b.acquire(); _a.acquire(); _a.release(); _b.release(); }'
					+ (direct ? ' static function zDirect():Void { _a.acquire(); takeB("x"); _a.release(); }' : '')
					+ ' public static function main():Void { Runner.create(work); _a.acquire(); $held _a.release(); $call } }'
				]
			);
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'D') '${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
