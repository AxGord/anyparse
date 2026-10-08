package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A hold judged across its callees: the lock it holds, on the object it holds it on, is carried into each call made on
 * that object (`LockDominance.carry`) — a stable field of the running object, or a stable field of one — so a take of a
 * lock it dominates there, or a re-take of it, waits for no long hold. A callee that may give the lock back carries
 * nothing.
 */
class ThreadSafetyCarriedHoldTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],"reentrantLocks":["Mutex.acquire"]}}}';

	/**
	 * `_mutex` is dominated by `_batch` (its one long hold holds both); `lookup` takes `_mutex`, `nested` re-takes
	 * `_batch`, and `drop` gives `_batch` back without taking it.
	 */
	private static inline final DB: String = 'class Db { public final batch:Mutex = new Mutex(); public final mutex:Mutex = new Mutex();'
		+ ' public function new() {} public function batchLock():Void batch.acquire(); public function batchUnlock():Void batch.release();'
		+ ' public function lookup():Void { mutex.acquire(); mutex.release(); }'
		+ ' public function nested():Void { batchLock(); mutex.acquire(); mutex.release(); batchUnlock(); }'
		+ ' public function drop():Void { batchUnlock(); mutex.acquire(); mutex.release(); }'
		+ ' public function slow():Void { batch.acquire(); mutex.acquire(); Sys.sleep(1); mutex.release(); batch.release(); } }';

	/** TM's `RemoteFileSystemBase.removeFileBlocked`: `_batchMutex` held, `_cloudDatabase.getFileByCloudId` takes `_mutex`. */
	@:pin('control') @:killer('M-TS-CARRY-OFF')
	public function testADominatedTakeInACalleeOnTheHeldObjectIsBrief(): Void {
		#if (sys || nodejs)
		Assert.same(['info B Fs.work | Db.batch'], work(own('_db.batchLock(); _db.lookup(); _db.batchUnlock();')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A re-take of the held re-entrant lock on its object, in a callee, waits for nothing. */
	@:pin('control') @:killer('M-TS-CARRY-RETAKE')
	public function testARetakeInACalleeIsBrief(): Void {
		#if (sys || nodejs)
		Assert.same(['info B Fs.work | Db.batch'], work(own('_db.batchLock(); _db.nested(); _db.batchUnlock();')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A callee that gives the held lock back carries nothing past it. */
	@:pin('control') @:killer('M-TS-CARRY-RELEASE')
	public function testACalleeGivingTheLockBackCarriesNothing(): Void {
		#if (sys || nodejs)
		Assert.same(['warning B Fs.work | Db.batch'], work(own('_db.batchLock(); _db.drop();')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A take on ANOTHER object's lock is no take under the hold. */
	@:pin('control') @:killer('M-TS-CARRY-OBJECT')
	public function testATakeOnAnotherObjectIsNotUnderTheHold(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B Fs.work | Db.batch'],
			work(own('_db.batchLock(); _other.mutex.acquire(); _other.mutex.release(); _db.batchUnlock();'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's `FileSystemBase`: `fileSystem.cloudDatabase.batchLock()` — a `var` assigned only in the constructor, and a
	 * `final` field of it, name one object for good, carried into `fileSystem.cloudDatabase.lookup()`.
	 */
	@:pin('control') @:killer('M-TS-PATH-TWO-LINK') @:killer('M-TS-PATH-CTOR')
	public function testAPathOfStableFieldsNamesTheHeldObject(): Void {
		#if (sys || nodejs)
		Assert.same(['info B Fs.work | Db.batch'], work(path('')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same `var` written outside the constructor names no object. */
	@:pin('control') @:killer('M-TS-PATH-STABLE-ANY')
	public function testAFieldWrittenOutsideTheConstructorNamesNoObject(): Void {
		#if (sys || nodejs)
		Assert.same(['warning B Fs.work | Db.batch'], work(path('public function swap(h:Holder):Void holder = h;')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `Fs` holding a `final _db` (and `_other`), with `body` as `work`. */
	private static function own(body: String): String {
		return 'class Fs { final _db:Db; final _other:Db; public function new(db:Db, other:Db) { _db = db; _other = other; }'
			+ ' public function work():Void { $body } }';
	}

	/** `Fs` reaching its `Db` through `holder.db`, `holder` a `var` assigned in the constructor, beside `members`. */
	private static function path(members: String): String {
		return 'class Holder { public final db:Db; public function new(db:Db) { this.db = db; } }'
			+ ' class Fs { public var holder:Holder; public function new(db:Db, other:Db) { holder = new Holder(db); } $members'
			+ ' public function work():Void { holder.db.batchLock(); holder.db.lookup(); holder.db.batchUnlock(); } }';
	}

	/**
	 * The findings (b) of `Fs.work` over `DB` and `fs`, run on a worker while the main thread takes `Db.batch` — and
	 * calls `lookup` and `nested` itself, so no meet over their callers holds `batch` on entry.
	 */
	private static function work(fs: String): Array<String> {
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			DB,
			fs,
			'class M { public static function main():Void { final db:Db = new Db(); final fs:Fs = new Fs(db, new Db());'
			+ ' Runner.create(() -> db.slow()); Runner.create(() -> fs.work()); db.batchLock(); db.batchUnlock(); db.lookup(); db.nested(); } }'
		]);
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'B' && data.member == 'Fs.work')
					'${v.severity.label()} B ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
