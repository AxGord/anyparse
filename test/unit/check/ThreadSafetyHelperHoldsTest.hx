package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A multi-lock helper (TM's `StandardFileSystem.acquireMutationLocks`: `_batchMutex`, then `_mutationMutex`) takes its
 * locks for its caller: each call of it opens a hold of every lock it takes, judged where it is called, exactly as a
 * single-lock wrapper's take is. The helper's own takes, and the gives of its releasing twin, are its callers'.
 */
class ThreadSafetyHelperHoldsTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';

	/** The probe of the brief (`recall/probe-helper`): the hold is the caller's, of both locks, and the helper holds nothing. */
	@:pin('control') @:killer('M-TS-HELPER-B-OFF') @:killer('M-TS-HELPER-OWN-TAKES')
	public function testTheHelpersCallerHoldsBothLocks(): Void {
		#if (sys || nodejs)
		Assert.same(['warning B H.viaBoth | H.a', 'warning B H.viaBoth | H.b'], holds(run('takeBoth(); Sys.sleep(1); giveBoth();', '')));
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
				'h.useA();'
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
	@:pin('control') @:killer('M-TS-HELPER-SIBLINGS')
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
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `H` with the two-lock helper pair, `viaBoth` running `body` on a worker (with `background` after it), `members`,
	 * and the main thread taking `a` and `b` (and running `main`).
	 */
	private static function run(body: String, members: String, ?main: String, ?background: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class H { public final a:Mutex = new Mutex(); public final b:Mutex = new Mutex(); public final c:Mutex = new Mutex();'
			+ ' public function new() {} function takeBoth():Void { b.acquire(); a.acquire(); }'
			+ ' function giveBoth():Void { a.release(); b.release(); } public function viaBoth():Void { $body } $members'
			+ ' public static function main():Void { final h:H = new H(); Runner.create(() -> { h.viaBoth(); ${background ?? ''} });'
			+ ' h.a.acquire(); h.a.release(); h.b.acquire(); h.b.release(); ${main ?? ''} } }'
		]);
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
