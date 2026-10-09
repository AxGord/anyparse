package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * A multi-lock helper (TM's `StandardFileSystem.acquireMutationLocks`: `_batchMutex`, then `_mutationMutex`) takes its
 * locks for its caller: each call of it opens a hold of every lock it takes, judged where it is called, exactly as a
 * single-lock wrapper's take is. The helper's own takes, and the gives of its releasing twin, are its callers'.
 */
class ThreadSafetyHelperHoldsTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';

	/** `CONFIG` declaring every caller in the run: the meet over a function's callers then says what it holds on entry. */
	private static inline final CLOSED: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],"closedWorld":true}}}';

	/**
	 * The probe of the brief (`recall/probe-helper`): the hold is the caller's, of both locks. The helper's own take of
	 * `b` is judged over the helper's window, where the thread waits for `a` — long by the caller's sleep — holding `b`.
	 */
	@:pin('control') @:killer('M-TS-HELPER-B-OFF') @:killer('M-TS-HELPER-OWN-WINDOW')
	public function testTheHelpersCallerHoldsBothLocks(): Void {
		#if (sys || nodejs)
		// both caller holds are long by the one `Sys.sleep`: one warning, the other folded onto it (`RootCauseFold`); the
		// helper's wait for `a` folds onto the caller's warning of `a`'s work
		Assert.same(
			['info B H.takeBoth | H.b', 'info B H.viaBoth | H.a', 'warning B H.viaBoth | H.b'],
			holds(run('takeBoth(); Sys.sleep(1); giveBoth();', ''))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The releasing twin's gives are its caller's releases: no lock is long for being given back by it, so no take of one blocks. */
	@:pin('control') @:killer('M-TS-HELPER-CROSSING')
	public function testTheTwinsGiveIsNoCrossingRelease(): Void {
		#if (sys || nodejs)
		Assert.same([], takes(run('takeBoth(); giveBoth();', '')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Nor does the twin's give break a dominance: `a` taken under `b` on the main thread stays brief. */
	@:pin('control') @:killer('M-TS-HELPER-DOM-CROSSING')
	public function testTheTwinsGiveLeavesDominanceStanding(): Void {
		#if (sys || nodejs)
		// a take of a long lock folds into the main thread's other take of it; a dominated one is short on its own
		Assert.same([true], [
			for (v in run(
				'takeBoth(); Sys.sleep(1); giveBoth();',
				'public function useA():Void { b.acquire(); takeA(); b.release(); }'
				+ ' function takeA():Void { a.acquire(); a.release(); }',
				'h.useA();', null, CLOSED
			)) if (v.data?.member == 'H.takeA') v.message.indexOf(' — short: ') >= 0
		]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Every lock the helper's call takes is held across the caller's calls: a take of a lock `b` dominates is brief
	 * under `a`'s hold too — in a callee the main thread also calls bare, so no meet over its callers says so.
	 */
	@:pin('control') @:killer('M-TS-HELPER-SIBLINGS') @:killer('M-TS-SAME-LOCAL-ROOT') @:killer('M-TS-HELPER-GIVE-OBJECT')
	public function testTheHelpersOtherLocksAreHeldToo(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info B H.viaBoth | H.a', 'info B H.viaBoth | H.b'],
			holds(run(
				'takeBoth(); takeC(); giveBoth();',
				'public function takeC():Void { c.acquire(); c.release(); }'
				+ ' public function slowC():Void { b.acquire(); c.acquire(); Sys.sleep(1); c.release(); b.release(); }',
				'h.takeC();', 'h.slowC();'
			)).filter(g -> g.indexOf('viaBoth') >= 0)
		);
		// brief, not folded as long through `slowC`'s warning (`RootCauseFold`)
		Assert.isFalse(
			run(
				'takeBoth(); takeC(); giveBoth();',
				'public function takeC():Void { c.acquire(); c.release(); }'
				+ ' public function slowC():Void { b.acquire(); c.acquire(); Sys.sleep(1); c.release(); b.release(); }',
				'h.takeC();', 'h.slowC();'
			).exists(v -> v.message.indexOf(' — long only through ') >= 0 && v.message.indexOf('viaBoth') >= 0)
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A function doing work between its takes is no helper (review `c1`): its own takes hand their locks off, and the
	 * sleep under the first one is judged where it runs.
	 */
	@:pin('control') @:killer('M-TS-HELPER-BODY-WORK')
	public function testWorkInsideATakingHelperIsJudged(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = pair(
			'function lockBoth():Void { _a.acquire(); Sys.sleep(1); _b.acquire(); }',
			'function unlockBoth():Void { _b.release(); _a.release(); }', 'lockBoth(); unlockBoth();', ''
		);
		Assert.same(['warning B S.lockBoth | S._a'], holds(found));
		// no helper, its take hands the lock off on its own: a helper's would be its caller's
		Assert.same([true], [
			for (v in found) if (v.data?.family == 'B') v.message.indexOf(' — and no path of the function gives it back') >= 0
		]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Nor is a releasing function that works before its gives (review `c1b`): it runs under the locks its caller holds,
	 * so the caller's hold spans the call into it.
	 */
	@:pin('control') @:killer('M-TS-HELPER-BODY-WORK')
	public function testWorkInsideAGivingHelperIsHeldByItsCaller(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B S.lockBoth | S._a', 'warning B S.work | S._a'],
			holds(pair(
				'function lockBoth():Void { _a.acquire(); _b.acquire(); }',
				'function unlockBoth():Void { Sys.sleep(1); _b.release(); _a.release(); }', 'lockBoth(); unlockBoth();', ''
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A helper reached through a dispatch is no helper (review `c4`): the call may run another override, taking nothing,
	 * so the override's takes leak on their own.
	 */
	@:pin('control') @:killer('M-TS-HELPER-DISPATCH')
	public function testAHelperReachedByDispatchIsNone(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B S.lockBoth | Base._a'],
			holds(source(
				'class Base { public final _a:Mutex = new Mutex(); public final _b:Mutex = new Mutex(); public function new() {}'
				+ ' public function lockBoth():Void {} public function unlockBoth():Void {} }'
				+ ' class S extends Base { public function new() { super(); }'
				+ ' override public function lockBoth():Void { _a.acquire(); _b.acquire(); }'
				+ ' override public function unlockBoth():Void { _b.release(); _a.release(); }'
				+ ' public static function work(x:Base):Void { x.lockBoth(); Sys.sleep(1); x.unlockBoth(); }'
				+ ' public function peek():Void { _a.acquire(); _a.release(); }'
				+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> work(s)); s.peek(); } }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A hold a helper's call opens and its function hands off, giving it back nowhere, is long past its function's end
	 * (review `c10`): the caller-side give check decides it as it does any other hold.
	 */
	@:pin('control') @:killer('M-TS-HELPER-HANDOFF')
	public function testAHelpersHoldHandedOffByItsCallerIsLong(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B S.begin | S._a', 'warning B S.lockBoth | S._a'],
			holds(pair(
				'function lockBoth():Void { _a.acquire(); _b.acquire(); }', 'function unlockBoth():Void { _b.release(); _a.release(); }',
				'begin(); Sys.sleep(1); unlockBoth();', 'public function begin():Void { lockBoth(); note(); } function note():Void {}'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A hold its function hands off outlives the window of a hold around it (review `c9`): it is no inner hold of that
	 * one, and stays a warning of its own.
	 */
	@:pin('control') @:killer('M-TS-NEST-HANDOFF')
	public function testAHandedOffHoldIsNoInnerHold(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B S.begin | S._a', 'warning B S.begin | S._b'],
			holds(source(
				'class S { final _a:Mutex = new Mutex(); final _b:Mutex = new Mutex(); public function new() {}'
				+ ' public function begin():Void { _a.acquire(); _b.acquire(); note(); _a.release(); }'
				+ ' public function end():Void { _b.release(); } function note():Void {}'
				+ ' public function work():Void { begin(); Sys.sleep(1); end(); }'
				+ ' public function peek():Void { _a.acquire(); _a.release(); _b.acquire(); _b.release(); }'
				+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s.peek(); } }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `H` with the two-lock helper pair, `viaBoth` running `body` on a worker (with `background` after it), `members`,
	 * and the main thread taking `a` and `b` (and running `main`).
	 */
	private static function run(body: String, members: String, ?main: String, ?background: String, ?config: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(config ?? CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class H { public final a:Mutex = new Mutex(); public final b:Mutex = new Mutex(); public final c:Mutex = new Mutex();'
			+ ' public function new() {} function takeBoth():Void { b.acquire(); a.acquire(); }'
			+ ' function giveBoth():Void { a.release(); b.release(); } public function viaBoth():Void { $body } $members'
			+ ' public static function main():Void { final h:H = new H(); Runner.create(() -> { h.viaBoth(); ${background ?? ''} });'
			+ ' h.a.acquire(); h.a.release(); h.b.acquire(); h.b.release(); ${main ?? ''} } }'
		]);
	}

	/** `code` beside the `Mutex` and the `Runner`, under `CONFIG`. */
	private static function source(code: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			code
		]);
	}

	/**
	 * `S` with two locks, the taking function `lock` and the releasing one `unlock`, `work` running `body` on a worker,
	 * `members`, and the main thread taking `_a`.
	 */
	private static function pair(lock: String, unlock: String, body: String, members: String): Array<Violation> {
		return source(
			'class S { final _a:Mutex = new Mutex(); final _b:Mutex = new Mutex(); public function new() {} $lock $unlock'
			+ ' public function work():Void { $body } public function peek():Void { _a.acquire(); _a.release(); } $members'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s.peek(); } }'
		);
	}

	/** The findings of `found` of `family` as `<severity> <family> <member> | <subject>`, sorted. */
	private static function graded(found: Array<Violation>, family: String): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == family) '${v.severity.label()} ${data.family} ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}

	private static inline function holds(found: Array<Violation>): Array<String> {
		return graded(found, 'B');
	}

	private static inline function takes(found: Array<Violation>): Array<String> {
		return graded(found, 'A');
	}
	#end

}
