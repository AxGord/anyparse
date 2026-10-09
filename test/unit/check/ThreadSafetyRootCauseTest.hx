package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * One warning per root cause (`RootCauseFold`, `MainSinkReport`): a hold long only by waiting for a lock whose long
 * holds warn themselves, or by work another warned hold does too, is info naming them; sink calls one main-thread way
 * runs together, and the calls one loop repeats, make one warning.
 */
class ThreadSafetyRootCauseTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep","Disk.read",'
		+ '"Disk.stat","Disk.list"],"shortSinks":["Disk.stat","Disk.list"],"spawns":["Runner.create"],'
		+ '"lockPairs":["Mutex.acquire/release"]}}}';

	/** TM's `StandardFileSystem.saveXML`: under the mutation lock it waits for the tree lock `updateInternal` holds long. */
	@:pin('control') @:killer('M-TS-FOLD-OFF')
	public function testAHoldLongOnlyByWaitingForAWarnedHolderIsInfo(): Void {
		#if (sys || nodejs)
		Assert.same(['info B S.save | S._x', 'warning B S.scan | S._t'], holds(waits('')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** TM's `saveXML`, whose `catch` reports over HTTP: a call only a `catch` runs is no reason the warning warns. */
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
	 * TM's `renameCloudFolderBlocked` over the loop `moveCloudFolderSubItemsAction2` runs under its own lock: two holds
	 * long by one sink call make one warning, the hold nearest that call's.
	 */
	@:pin('control') @:killer('M-TS-FOLD-SITE') @:killer('M-TS-FOLD-DEPTH')
	public function testHoldsLongByOneCallMakeOneWarning(): Void {
		#if (sys || nodejs)
		Assert.same(['info B A.a | A._x', 'warning B A.z | A._y'], holds(ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class A { final _x:Mutex = new Mutex(); final _y:Mutex = new Mutex(); public function new() {}'
			+ ' public function a():Void { _x.acquire(); v(); _x.release(); } function v():Void w(); function w():Void Sys.sleep(1);'
			+ ' public function z():Void { _y.acquire(); w(); _y.release(); }'
			+ ' public static function main():Void { final s:A = new A(); Runner.create(() -> { s.a(); s.z(); });'
			+ ' s._x.acquire(); s._x.release(); s._y.acquire(); s._y.release(); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** TM's `FSUtil.deleteRecursive`: the sink calls one main-thread way into a function runs make one warning. */
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

	/** TM's `repairShareAttr`: the calls one loop repeats make one warning, keyed by the first. */
	@:pin('control') @:killer('M-TS-LOOP-KEY')
	public function testTheCallsOfOneLoopMakeOneWarning(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A L.a | Disk.stat', 'info A L.b | Disk.list', 'warning A L.main | L.a'],
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
	 * A hold reaching a sink call once covers no hold repeating that call under its lock (TM's `FolderWatcher.rename`'s
	 * one stat against `updateInternal`'s walk over the tree): the repeating hold keeps the warning, and the one-call
	 * hold folds onto it.
	 */
	@:pin('control') @:killer('M-TS-FOLD-SITE-ONCE')
	public function testAHoldReachingACallOnceCoversNoRepeatingOne(): Void {
		#if (sys || nodejs)
		Assert.same(['info B A.z | A._y', 'warning B A.a | A._x'], holds(ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class A { final _x:Mutex = new Mutex(); final _y:Mutex = new Mutex(); public function new() {}'
			+ ' public function a():Void { _x.acquire(); for (i in 0...3) v(); _x.release(); } function v():Void w();'
			+ ' function w():Void Sys.sleep(1); public function z():Void { _y.acquire(); w(); _y.release(); }'
			+ ' public static function main():Void { final s:A = new A(); Runner.create(() -> { s.a(); s.z(); });'
			+ ' s._x.acquire(); s._x.release(); s._y.acquire(); s._y.release(); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
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

}
