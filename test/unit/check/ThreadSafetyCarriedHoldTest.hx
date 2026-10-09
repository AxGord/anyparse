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
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],"reentrantLocks":["Mutex.acquire"],"closedWorld":true}}}';

	/**
	 * `_mutex` is dominated by `_batch` (its one long hold holds both); `lookup` takes `_mutex`, and `nested` re-takes
	 * `_batch`.
	 */
	private static inline final DB: String = 'class Db { public final batch:Mutex = new Mutex(); public final mutex:Mutex = new Mutex();'
		+ ' public function new() {} public function batchLock():Void batch.acquire(); public function batchUnlock():Void batch.release();'
		+ ' public function lookup():Void { mutex.acquire(); mutex.release(); }'
		+ ' public function nested():Void { batchLock(); mutex.acquire(); mutex.release(); batchUnlock(); }'
		+ ' public function slow():Void { batch.acquire(); mutex.acquire(); Sys.sleep(1); mutex.release(); batch.release(); } }';

	/**
	 * `DB` with `drop`, which gives `_batch` back without taking it: `_batch` then excludes no one for sure, so it
	 * dominates nothing (`LockDominance`) — wherever `drop` is called.
	 */
	private static inline final DB_DROP: String = 'class Db { public final batch:Mutex = new Mutex(); public final mutex:Mutex = new Mutex();'
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

	/**
	 * A callee that gives the held lock back carries nothing past it. Its untaken give also keeps `_batch` from
	 * dominating anything (`LockDominance.excludes`), so no single cut breaks this any more: a guard.
	 */
	@:pin('guard')
	public function testACalleeGivingTheLockBackCarriesNothing(): Void {
		#if (sys || nodejs)
		Assert.same(['info B Fs.work | Db.batch (folded)'], work(own('_db.batchLock(); _db.drop();'), DB_DROP));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A take on ANOTHER object's lock is no take under the hold — another field's, or the running object's own. */
	@:pin('control') @:killer('M-TS-CARRY-OBJECT')
	public function testATakeOnAnotherObjectIsNotUnderTheHold(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B Fs.work | Db.batch'], work(own('_db.batchLock(); _other.batchLock(); _other.batchUnlock(); _db.batchUnlock();'))
		);
		// `Fs` a `Db` itself: its own `batch` is not the one it holds on `_db`
		final self: String = StringTools.replace(
			StringTools.replace(
				own('_db.batchLock(); batch.acquire(); batch.release(); _db.batchUnlock();'), 'class Fs {', 'class Fs extends Db {'
			),
			'{ _db = db;', '{ super(); _db = db;'
		);
		Assert.same(['warning B Fs.work | Db.batch'], work(self), 'its own object');
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

	/**
	 * A field an interface declares is declared again by each implementer: a write there writes the interface's field,
	 * and a constant-named `Reflect.setField` / `setProperty` writes the field so named — either one names no object
	 * through the path (review round 2 `o1`, `o3`).
	 */
	@:pin('control') @:killer('M-TS-PATH-INTERFACE') @:killer('M-TS-PATH-REFLECT')
	public function testAnImplementersOrAReflectiveWriteNamesNoObject(): Void {
		#if (sys || nodejs)
		final config: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"spawns":["Runner.create"],'
			+ '"lockPairs":["Mutex.acquire/release"],"closedWorld":true}}}';
		final db: String = 'class Db { public final batch:Mutex = new Mutex(); public final mutex:Mutex = new Mutex(); public function new() {}'
			+ ' public function batchLock():Void batch.acquire(); public function batchUnlock():Void batch.release();'
			+ ' public function lookup():Void { mutex.acquire(); mutex.release(); }'
			+ ' public function slow():Void { batch.acquire(); mutex.acquire(); Sys.sleep(1); mutex.release(); batch.release(); } }';
		final main: String = 'class M { public static function main():Void { final a:Db = new Db(); final b:Db = new Db();'
			+ ' final fs:Fs = new Fs(a, b); final w:W = new W(fs); Runner.create(() -> { a.slow(); b.slow(); });'
			+ ' Runner.create(() -> w.work()); Runner.create(() -> Swapper.go(fs, b)); a.batchLock(); a.batchUnlock(); } }';
		inline function graded(fsDecl: String, fsType: String, swap: String): Array<String> {
			return [
				for (v in ThreadSafetyCheckTest.violations(config, [
					ThreadSafetyCheckTest.MUTEX,
					'class Runner { public static function create(fn:()->Void):Void {} }',
					db,
					fsDecl,
					'class W { final fs:$fsType; public function new(f:$fsType) { fs = f; }'
					+ ' public function work():Void { fs.db.batchLock(); fs.db.lookup(); fs.db.batchUnlock(); } }',
					'class Swapper { public static function go(f:Fs, b:Db):Void { $swap } }',
					main
				])) if (v.data?.family == 'B' && v.data?.member == 'W.work') v.severity.label()
			];
		}
		final plain: String = 'class Fs { public var db:Db; public function new(a:Db, b:Db) { db = a; } }';
		Assert.same(['info'], graded(plain, 'Fs', ''), 'written in the constructor only');
		Assert.same(
			['warning'],
			graded(
				'interface IFs { var db:Db; } class Fs implements IFs { public var db:Db;'
				+ ' public function new(a:Db, b:Db) { db = a; Runner.create(() -> db = b); } }',
				'IFs', ''
			),
			'an implementer'
		);
		Assert.same(['warning'], graded(plain, 'Fs', 'Reflect.setField(f, "db", b);'), 'a reflective write');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `var` written in a lambda or a local function the constructor makes is written whenever that function runs: it
	 * names no object.
	 */
	@:pin('control') @:killer('M-TS-PATH-CTOR-LAMBDA')
	public function testAWriteInAFunctionTheConstructorMakesIsNoConstructorWrite(): Void {
		#if (sys || nodejs)
		Assert.same(['info B Fs.work | Db.batch (folded)'], work(path('', ' Runner.create(() -> holder = new Holder(other));')));
		Assert.same(['info B Fs.work | Db.batch (folded)'], work(path('', ' function swap():Void holder = new Holder(other);')), 'local');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A constructor writing the field of ANOTHER object changes that object's after its construction. */
	@:pin('control') @:killer('M-TS-PATH-OWN')
	public function testAConstructorWritingAnotherObjectsFieldNamesNoObject(): Void {
		#if (sys || nodejs)
		Assert.same(['info B Fs.work | Db.batch (folded)'], work(path('', ' if (peer != null) peer.holder = new Holder(other);')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A `static var` the instance constructor assigns is assigned again by every construction. */
	@:pin('control') @:killer('M-TS-PATH-STATIC')
	public function testAStaticVarWrittenInTheConstructorNamesNoObject(): Void {
		#if (sys || nodejs)
		Assert.same(['info B Fs.work | Db.batch (folded)'], work(path('', '', 'static var holder:Holder;')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A run that leaves out a file of the project sees not every write of it, whatever `closedWorld` declares: the `var`
	 * names no object, and the run says why it reads the chain as open.
	 */
	@:pin('control') @:killer('M-TS-PATH-COMPLETE') @:killer('M-TS-COVER-WALK') @:killer('M-TS-COVER-NOTE')
	public function testARunOverPartOfTheProjectSeesNotEveryWrite(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(path(''), [{ name: 'Plugin.hx', source: PLUGIN }]);
		Assert.same(['info B Fs.work | Db.batch (folded)'], holds(found));
		Assert.contains(CLOSED_NOTE, [for (v in found) if (v.file == '') v.message]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A file `exclude` names is no part of the project: leaving it out of the run leaves the project covered. */
	@:pin('control') @:killer('M-TS-COVER-EXCLUDE')
	public function testAnExcludedFileIsNoPartOfTheProject(): Void {
		#if (sys || nodejs)
		final config: String = StringTools.replace(CONFIG, '"closedWorld":true', '"closedWorld":true,"exclude":["Plugin.hx"]');
		final found: Array<Violation> =
			ThreadSafetyCheckTest.violations(config, sources(path('')), [{ name: 'Plugin.hx', source: PLUGIN }]);
		Assert.same(['info B Fs.work | Db.batch'], holds(found));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same `var` written outside the constructor names no object. */
	@:pin('control') @:killer('M-TS-PATH-STABLE-ANY')
	public function testAFieldWrittenOutsideTheConstructorNamesNoObject(): Void {
		#if (sys || nodejs)
		Assert.same(['info B Fs.work | Db.batch (folded)'], work(path('public function swap(h:Holder):Void holder = h;')));
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

	/**
	 * `Fs` reaching its `Db` through `holder.db`, `holder` (declared by `field`) assigned in the constructor and then
	 * `ctor`, beside `members`.
	 */
	private static function path(members: String, ctor: String = '', field: String = 'public var holder:Holder;'): String {
		return 'class Holder { public final db:Db; public function new(db:Db) { this.db = db; } }'
			+ ' class Fs { $field public function new(db:Db, other:Db, ?peer:Fs) { holder = new Holder(db);$ctor } $members'
			+ ' public function work():Void { holder.db.batchLock(); holder.db.lookup(); holder.db.batchUnlock(); } }';
	}

	/** What a finding folded onto the warnings covering it says (`RootCauseFold`): a long wait, not a brief one. */
	private static inline final FOLDED: String = ' — long only through ';

	/**
	 * The findings (b) of `Fs.work` over `db` (`DB` unless given) and `fs`, `(folded)` marking one
	 * long only through other warnings, run on a worker while the main thread takes `Db.batch` — and
	 * calls `lookup` and `nested` itself, so no meet over their callers holds `batch` on entry.
	 */
	private static function work(fs: String, ?db: String): Array<String> {
		return holds(ThreadSafetyCheckTest.violations(CONFIG, sources(fs, db), []));
	}

	/** The run over `sources(fs)`, `beside` on disk next to it. */
	private static inline function run(fs: String, beside: Array<{ name: String, source: String }>): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, sources(fs), beside);
	}

	/** The files of a run over `fs` and `db` (`DB` unless given). */
	private static function sources(fs: String, ?db: String): Array<String> {
		return [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			db ?? DB,
			fs,
			'class M { public static function main():Void { final db:Db = new Db(); final fs:Fs = new Fs(db, new Db());'
				+ ' Runner.create(() -> db.slow()); Runner.create(() -> fs.work()); db.batchLock(); db.batchUnlock(); db.lookup(); db.nested(); } }'
		];
	}

	/** The findings (b) of `Fs.work` in `found`, as `<severity> B <member> | <subject>`, `(folded)` marking a folded one. */
	private static function holds(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'B' && data.member == 'Fs.work')
					'${v.severity.label()} B ${data.member} | ${data.subject}' + (v.message.indexOf(FOLDED) >= 0 ? ' (folded)' : '');
			}
		];
		out.sort(Reflect.compare);
		return out;
	}

	/** A project file the run leaves out, writing `Fs.holder` (`ProjectCoverage`). */
	private static inline final PLUGIN: String = 'class Plugin { public static function install(fs:Fs, h:Holder):Void fs.holder = h; }';

	/** What a run says of a `closedWorld` it does not cover (`ThreadSafety.listsByFile`). */
	private static inline final CLOSED_NOTE: String = 'option "closedWorld" holds only for a run over the whole project it closes — this run leaves'
		+ ' part of it out, so it is read as false';
	#end

}
