package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.ThreadSafety;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * Outer-lock dominance (`LockDominance`): when every long hold of `_inner` holds `_outer` on the same object, a thread
 * holding `_outer` never waits long for `_inner`, so a take of `_inner` under `_outer` is brief. Proven over every hold —
 * one long hold without `_outer`, a give of `_outer` before the long call, another object's lock: no dominance.
 */
class ThreadSafetyDominanceTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';

	/** TM's `_mutex` under `_batchMutex`: the long hold of `_inner` holds `_outer`, so `quick` waits for no long hold. */
	public function testATakeUnderTheOuterLockIsBrief(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info B D.quick | D._outer', 'warning B D.slow | D._outer'],
			holds(run(
				'public function slow():Void { _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release(); }',
				'd.slow();'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The main thread's own take of `_inner` while it must-holds `_outer` (every caller holds it) is brief too. */
	@:pin('control') @:killer('M-TS-DOM-OFF')
	public function testAMainTakeUnderTheOuterLockIsBrief(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class D { final _outer:Mutex = new Mutex(); final _inner:Mutex = new Mutex(); public function new() {}'
			+ ' public function slow():Void { _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release(); }'
			+ ' public function quick():Void { _outer.acquire(); takeInner(); _outer.release(); }'
			+ ' function takeInner():Void { _inner.acquire(); _inner.release(); }'
			+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.slow()); d.quick(); } }'
		]);
		Assert.same(['info'], [
			for (v in found) if (v.data?.family == 'A' && v.data?.member == 'D.takeInner') v.severity.label()
		]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One long hold of `_inner` without `_outer` and nothing dominates it: `quick` may wait for that one. */
	@:pin('control') @:killer('M-TS-DOM-ANY-HOLD')
	public function testALongHoldOutsideTheOuterLockBreaksDominance(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B D.quick | D._outer', 'warning B D.slow | D._outer'],
			holds(run(
				'public function slow():Void { _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release(); }'
				+ ' public function bare():Void { _inner.acquire(); Sys.sleep(1); _inner.release(); }',
				'd.slow(); d.bare();'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `_outer` given back before the long call: the long part of the hold of `_inner` holds nothing. */
	@:pin('control') @:killer('M-TS-DOM-RELEASE-IGNORED')
	public function testAGiveOfTheOuterLockBeforeTheLongCallBreaksDominance(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B D.quick | D._outer', 'warning B D.slow | D._outer'],
			holds(run(
				'public function slow():Void { _outer.acquire(); _inner.acquire(); _outer.release(); Sys.sleep(1); _inner.release(); }',
				'd.slow();'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A give of `_outer` on a path that returns at once reaches no call after it: the long call still holds it. */
	@:pin('control') @:killer('M-TS-DOM-EXITS-IGNORED')
	public function testAGiveOnAnExitingPathKeepsTheOuterLockHeld(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info B D.quick | D._outer', 'warning B D.slow | D._outer'],
			holds(run(
				'public function slow(n:Int):Void { _outer.acquire(); if (n > 0) { _outer.release(); return; } _inner.acquire();'
				+ ' Sys.sleep(1); _inner.release(); _outer.release(); }',
				'd.slow(1);'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's `if (!batch) _batchMutex.acquire()`: taken where the caller hands `batch = false`, held by the caller where it
	 * hands `true` — under every valuation the long hold of `_inner` holds `_outer`.
	 */
	@:pin('control') @:killer('M-TS-DOM-UNDECIDED') @:killer('M-TS-DOM-ENTRY-NONE')
	public function testAConditionalTakeTheValuationDecidesCounts(): Void {
		#if (sys || nodejs)
		Assert.same([
			'info B D.quick | D._outer',
			'warning B D.outer | D._outer',
			'warning B D.slow | D._outer'
		], holds(run(
			'public function slow(batch:Bool):Void { if (!batch) _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release();'
			+ ' if (!batch) _outer.release(); }' + ' public function outer():Void { _outer.acquire(); slow(true); _outer.release(); }',
			'd.slow(false); d.outer();'
		)));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Dominance is per object: `_outer` of this object says nothing of another object's `_inner`. */
	@:pin('control') @:killer('M-TS-DOM-ANY-OBJECT')
	public function testAnotherObjectsLockIsNotDominated(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B D.cross | D._outer', 'warning B D.slow | D._outer'],
			holds(run(
				'public function slow():Void { _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release(); }'
				+ ' public function cross(o:D):Void { _outer.acquire(); o._inner.acquire(); o._inner.release(); _outer.release(); }',
				'd.slow(); d.cross(new D());', false
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `D` declares `members`, `quick` (holding `_outer` across a call taking `_inner`) unless `withQuick` is
	 * false, and `ui` (the main thread's take of `_outer`); a spawned thread runs `background`, then `quick`.
	 */
	private static function run(members: String, background: String, withQuick: Bool = true, ?config: String): Array<Violation> {
		final quick: String = withQuick
			? ' public function quick():Void { _outer.acquire(); takeInner(); _outer.release(); }'
				+ ' function takeInner():Void { _inner.acquire(); _inner.release(); }'
			: '';
		final runQuick: String = withQuick ? ' d.quick();' : '';
		return ThreadSafetyCheckTest.violations(config ?? CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class D { final _outer:Mutex = new Mutex(); final _inner:Mutex = new Mutex(); public function new() {} $members$quick'
			+ ' public function ui():Void { _outer.acquire(); _outer.release(); }'
			+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> { $background$runQuick }); d.ui(); } }'
		]);
	}

	/** The hold findings (b) of `found` as `<severity> B <member> | <lock>`, sorted. */
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

	/** `--explain-long` names each dominated lock with the locks dominating it. */
	@:pin('control') @:killer('M-TS-DOM-EXPLAIN-DROPPED')
	public function testExplainLongNamesTheDominatedLock(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('threadsafetydominance', [{ name: 'apqlint.json', source: CONFIG }]);
		final check: ThreadSafety = new ThreadSafety();
		check.explainLongLocks(true);
		final sources: Array<String> = [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class D { final _outer:Mutex = new Mutex(); final _inner:Mutex = new Mutex(); public function new() {}'
				+ ' public function slow():Void { _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release(); }'
				+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.slow()); } }'
		];
		Linter.run([for (i in 0...sources.length) { file: '$dir/F$i.hx', source: sources[i] }], new HaxeQueryPlugin(), [check]);
		CliFixture.removeDir(dir);
		// both are held across the sleep: each long hold of either holds the other
		Assert.same([{ lock: 'D._inner', by: ['D._outer'] }, { lock: 'D._outer', by: ['D._inner'] }], check.longLocks?.dominated);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A hold dominates its own take: in the window of a hold of `_outer`, `_outer` is held, whatever a valuation can prove
	 * of the conditional take that opened it.
	 */
	@:pin('control') @:killer('M-TS-DOM-UNDER-HOLD-OFF')
	public function testAHoldDominatesItsOwnTake(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info B D.maybe | D._outer', 'warning B D.slow | D._outer'],
			holds(run(
				'public function slow():Void { _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release(); }'
				+ ' public function maybe(flag:Bool):Void { if (flag) _outer.acquire(); _inner.acquire(); _inner.release();'
				+ ' if (flag) _outer.release(); }',
				'd.slow(); d.maybe(Math.random() > 0.5);', false
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's `getFileCount`: a hold of `_inner` outside `_outer` whose only unresolved call is a `trace` the config names a
	 * short sink, run once: brief, so it leaves the dominance standing; in a loop it is long and breaks it.
	 */
	@:pin('control') @:killer('M-TS-DOM-BRIEF-NAMES-IGNORED') @:killer('M-TS-DOM-BRIEF-REPEATED')
	public function testABriefUnresolvedCallLeavesDominanceStanding(): Void {
		#if (sys || nodejs)
		final config: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"shortSinks":["trace"],'
			+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';
		final slow: String =
			'public function slow():Void { _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release(); }';
		Assert.same(
			['info B D.quick | D._outer', 'warning B D.slow | D._outer'],
			holds(run(
				slow + ' public function peek():Void { _inner.acquire(); trace("x"); _inner.release(); }', 'd.slow(); d.peek();', true,
				config
			)),
			'run once'
		);
		Assert.same(
			['warning B D.quick | D._outer', 'warning B D.slow | D._outer'],
			holds(run(
				slow + ' public function peek(xs:Array<Int>):Void { _inner.acquire(); for (x in xs) trace(x); _inner.release(); }',
				'd.slow(); d.peek([1]);', true, config
			)),
			'in a loop'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
