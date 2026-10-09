package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A hold taken inside a hold of the same lock that every caller keeps is the enclosing hold's (`LockDominance.enclosed`):
 * TM's `StandardFileSystem.cloudLocalRenameAndMoveItem` takes `_batchMutex` inside the sync's own batch hold. Every
 * caller is known only under `closedWorld`; the enclosing hold's warning must reach the enclosed one's function.
 */
class ThreadSafetyEnclosedHoldTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],"reentrantLocks":["Mutex.acquire"],"closedWorld":true}}}';

	@:pin('control') @:killer('M-TS-ENCLOSED-OFF')
	public function testAHoldEveryCallerEnclosesIsTheirs(): Void {
		#if (sys || nodejs)
		Assert.same(['info B S.inner | S._m', 'warning B S.outer | S._m'], holds(run('')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-ENCLOSED-ANY-STATE')
	public function testOneCallerOutsideTheLockKeepsItsOwn(): Void {
		#if (sys || nodejs)
		// not enclosed, the outer hold still folds onto the inner one: both are long by the same `Sys.sleep` (`RootCauseFold`)
		Assert.same(['info B S.outer | S._m', 'warning B S.inner | S._m'], holds(run('s.bare(true);')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The enclosed hold's note says what the enclosing warning does name: the call into its function — with no re-entrant
	 * take, the re-take there, not the sleep (review `enclosed-False`).
	 */
	@:pin('control') @:killer('M-TS-ENCLOSED-NOTE')
	public function testTheNoteNamesTheEnclosingWarning(): Void {
		#if (sys || nodejs)
		final config: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"spawns":["Runner.create"],'
			+ '"lockPairs":["Mutex.acquire/release"],"closedWorld":true}}}';
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(config, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class D { final _l:Mutex = new Mutex(); public function new() {} public function outer():Void { _l.acquire(); inner(); _l.release(); }'
			+ ' function inner():Void { _l.acquire(); Sys.sleep(1); _l.release(); }'
			+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.outer()); d.outer(); } }'
		]);
		Assert.same(
			[
				' — taken inside a hold of D._l every caller keeps, whose warning at D.outer is long through the call into this one'
			],
			[
				for (v in found) if (v.data?.family == 'B' && v.data?.member == 'D.inner') v.message.substring(v.message.indexOf(' — '))
			]
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A hold the callers keep is no enclosure once a caller may give the lock back on the way to the call: through a value
	 * it hands on to run (`U.now(drop)`), or a call on an unresolved call's result (`self().dropAll()`) — the enclosed hold
	 * keeps its own warning (reviews `give-release-in-callback-now`, `chain-chained-unresolved`).
	 */
	@:pin('control') @:killer('M-TS-RELEASE-CALLBACK') @:killer('M-TS-BLIND-START')
	public function testAGiveOnTheCallersWayBreaksTheEnclosure(): Void {
		#if (sys || nodejs)
		Assert.same(['info B D.inner | D._l', 'warning B D.outer | D._l'], holds(giving('', '')), 'control');
		Assert.same(
			['info B D.outer | D._l', 'warning B D.inner | D._l'],
			holds(giving('U.now(drop);', 'function drop():Void _l.release();')), 'handed on'
		);
		Assert.same(
			['info B D.outer | D._l', 'warning B D.inner | D._l'],
			holds(giving('self().dropAll();', 'function self():Dynamic return this; public function dropAll():Void _l.release();')),
			'chained'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function run(more: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class S { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' function inner(flag:Bool):Void { _m.acquire(); if (flag) Sys.sleep(2); Sys.sleep(1); _m.release(); }'
			+ ' public function outer():Void { _m.acquire(); inner(false); _m.release(); }'
			+ (more == '' ? '' : ' public function bare(flag:Bool):Void inner(flag);')
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> { s.outer(); $more }); s._m.acquire(); s._m.release(); } }'
		]);
	}

	/** `D.outer` holding `_l` across `way` and a call into `inner`, which holds it across a sleep; every caller in the run. */
	private static function giving(way: String, members: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class U { public static function now(f:Dynamic):Void f(); }',
			'class D { final _l:Mutex = new Mutex(); public function new() {} $members'
			+ ' public function outer():Void { _l.acquire(); $way inner(); _l.release(); }'
			+ ' function inner():Void { _l.acquire(); Sys.sleep(1); _l.release(); } public function peek():Void { _l.acquire(); _l.release(); }'
			+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.outer()); d.peek(); } }'
		]);
	}
	private static function holds(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'B') '${v.severity.label()} B ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
