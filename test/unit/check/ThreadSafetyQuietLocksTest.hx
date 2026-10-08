package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * Takes that never wait, whatever their lock is (`QuietLocks`): a lock only ever taken through a `sharedLocks` member,
 * and a take in its owner's constructor before the object can reach another thread.
 */
class ThreadSafetyQuietLocksTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Shared.lock","Shared.lockShared","Mutex.acquire",'
		+ '"Sys.sleep"],"spawns":["Runner.create"],"lockPairs":["Shared.lock/unlock","Shared.lockShared/unlockShared","Mutex.acquire/release"],'
		+ '"sharedLocks":["Shared.lockShared"]}}}';

	private static inline final SHARED: String = 'class Shared { public function new() {} public function lock():Void {}'
		+ ' public function unlock():Void {} public function lockShared():Void {} public function unlockShared():Void {} }';

	/**
	 * TM's `APIToken._refreshReadWriteLock`: taken only with `lockShared`, so no take of it waits — neither the main
	 * thread's take nor anyone behind the worker's hold.
	 */
	@:pin('control') @:killer('M-TS-SHARED-OFF') @:killer('M-TS-SHARED-HOLD')
	public function testALockOnlyTakenSharedNeverWaits(): Void {
		#if (sys || nodejs)
		Assert.same([], graded(run('')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One exclusive take of the same lock anywhere and the shared takes wait for it. */
	@:pin('control') @:killer('M-TS-SHARED-ANY')
	public function testAnExclusiveTakeMakesTheSharedOnesWait(): Void {
		#if (sys || nodejs)
		// the main thread's takes of one lock wait for the same holders: one warns, the other names it
		Assert.same([
			'info A T.ui | Shared.lockShared',
			'warning A T.ex | Shared.lock',
			'warning B T.slow | T._l'
		], graded(run('public function ex():Void { _l.lock(); _l.unlock(); }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** TM's `CloudDatabase.new`: a take of the instance's own lock in its constructor, before the object escapes, waits for no one. */
	@:pin('control') @:killer('M-TS-CTOR-TAKE')
	public function testAConstructorsOwnTakeNeverWaits(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class C { final _m:Mutex = new Mutex(); public function new() { _m.acquire(); _m.release(); }'
			+ ' public function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); }'
			+ ' public static function main():Void { final c:C = new C(); Runner.create(() -> c.work()); new C(); } }'
		]);
		Assert.same([], graded(found).filter(g -> g.indexOf(' A C.new ') >= 0));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A worker's shared hold of `T._l` across a sleep and a main-thread shared take of it, beside `members`. */
	private static function run(members: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			SHARED,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class T { final _l:Shared = new Shared(); public function new() {} $members'
			+ ' public function slow():Void { _l.lockShared(); Sys.sleep(1); _l.unlockShared(); }'
			+ ' public function ui():Void { _l.lockShared(); _l.unlockShared(); }'
			+ ' public static function main():Void { final t:T = new T(); Runner.create(() -> t.slow()); t.ui(); ${members == '' ? '' : 't.ex();'} } }'
		]);
	}

	/** The warnings and infos of `found` of families A and B as `<severity> <family> <member> | <subject>`, sorted. */
	private static function graded(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && (data.family == 'A' || data.family == 'B') && data.subject != 'Sys.sleep')
					'${v.severity.label()} ${data.family} ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
