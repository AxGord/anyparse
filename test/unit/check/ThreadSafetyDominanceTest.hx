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

	/** `CONFIG` declaring that every caller is in the run: only then does the meet over a function's callers say what it holds. */
	private static inline final CLOSED: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],"closedWorld":true}}}';

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

	/**
	 * The main thread's own take of `_inner` while it must-holds `_outer` (every caller holds it) is brief too — under
	 * `closedWorld`, where every caller is in the run.
	 */
	@:pin('control') @:killer('M-TS-DOM-OFF')
	public function testAMainTakeUnderTheOuterLockIsBrief(): Void {
		#if (sys || nodejs)
		Assert.same(['info'], mainTakesOfInner(CLOSED));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Without `closedWorld`, code outside the run may call `takeInner` holding nothing (`hxq lint core` over a project
	 * whose `plugins/` calls it): its callers in the run say nothing of what it holds on entry, and its take stays long.
	 */
	@:pin('control') @:killer('M-TS-MEET-OUTSIDE')
	public function testAnOpenWorldCalleeHoldsNothingOnEntry(): Void {
		#if (sys || nodejs)
		Assert.same(['warning'], mainTakesOfInner(CONFIG));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Every way `_outer` may be given back while the long hold of `_inner` runs breaks the dominance, so the main
	 * thread's take of `_inner` under `_outer` stays long — the review's give-detection holes, one probe each, beside the
	 * control where nothing gives it back early.
	 */
	@:pin('control') @:killer('M-TS-LEAVES-CAUGHT-THROW') @:killer('M-TS-COVER-RETAKE')
	public function testAGiveOnTheWayToTheLongCallBreaksDominance(): Void {
		#if (sys || nodejs)
		Assert.same([1], [
			shortQuickTakes(givingBack('_inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release();', ''))
		], 'control');
		// a throw a `catch` in the same function stops goes on to the sleep (review `exit-throw-caught-after`)
		Assert.same([0], [
			shortQuickTakes(givingBack(
				'_inner.acquire(); try { if (flag) { _outer.release(); throw "x"; } } catch (e:haxe.Exception) {} Sys.sleep(1);'
				+ ' _inner.release(); if (!flag) _outer.release();',
				'public var flag:Bool = false;'
			))
		], 'caught throw');
		// `_inner` taken again after the give that covered it, before `_outer` goes (review `cover-retake-before-give`)
		Assert.same([0], [
			shortQuickTakes(
				givingBack('_inner.acquire(); _inner.release(); _inner.acquire(); _outer.release(); Sys.sleep(1); _inner.release();', '')
			)
		], 'retaken');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A give a value handed on runs (`U.now(() -> _outer.release())`) gives back where it is handed (review
	 * `give-release-in-callback-now`). Two mechanisms each catch it — the untaken give that keeps `_outer` from dominating
	 * anything, and the give point where the value is handed — so no single cut does: a guard of the review's probe.
	 */
	@:pin('guard')
	public function testAGiveACallbackRunsNowBreaksDominance(): Void {
		#if (sys || nodejs)
		for (handed in [
			'U.now(() -> _outer.release());',
			'U.now(dropOuter);',
			'U.each([1], _ -> _outer.release());'
		]) Assert.same([0], [
			shortQuickTakes(
				givingBack('_inner.acquire(); $handed Sys.sleep(1); _inner.release();', 'function dropOuter():Void _outer.release();')
			)
		], handed);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A function that takes the lock gives back what it took only where the take ran first, on the same object
	 * (reviews `close-take-in-other-branch`, `handoff-handoff-other-object`).
	 */
	@:pin('control') @:killer('M-TS-GIVE-PATH') @:killer('M-TS-GIVE-OBJECT')
	public function testAGiveOfWhatTheFunctionDidNotTakeBreaksDominance(): Void {
		#if (sys || nodejs)
		Assert.same([0], [
			shortQuickTakes(givingBack(
				'_inner.acquire(); close(true); Sys.sleep(1); _inner.release();',
				'function close(force:Bool):Void { if (!force) _outer.acquire(); _outer.release(); }', 'd.close(false);'
			))
		], 'other branch');
		Assert.same([0], [
			shortQuickTakes(givingBack(
				'_inner.acquire(); handOff(other); Sys.sleep(1); _inner.release(); other._outer.release();',
				'function handOff(o:D):Void { o._outer.acquire(); _outer.release(); }', '', 'other:D'
			))
		], 'other object');
		// a take an undecidable condition guards runs on some path to the give only
		Assert.same([0], [
			shortQuickTakes(givingBack(
				'_inner.acquire(); maybeClose(); Sys.sleep(1); _inner.release();',
				'function maybeClose():Void { if (Math.random() > 0.5) _outer.acquire(); _outer.release(); }'
			))
		], 'some path');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A give a loop repeats after one take gives back more than it took: every turn after the first releases a hold
	 * begun elsewhere, and the lock dominates nothing (review round 2 `k1`; `k2` writes the second give out).
	 */
	@:pin('control') @:killer('M-TS-GIVE-REPEATED')
	public function testAGiveRepeatedAfterOneTakeBreaksDominance(): Void {
		#if (sys || nodejs)
		final rest: String = '_inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release();';
		Assert.same([0], [
			shortQuickTakes(
				givingBack(rest, 'public function kick():Void { _outer.acquire(); for (i in 0...2) _outer.release(); }', '', '', 'd.kick()')
			)
		], 'a loop');
		Assert.same([1], [
			shortQuickTakes(givingBack(rest, 'public function kick():Void { _outer.acquire(); _outer.release(); }', '', '', 'd.kick()'))
		], 'once');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A call made on an unresolved call's result is blind too, wherever it starts (review `chain-chained-unresolved`); the
	 * untaken give `dropAll` makes keeps `_outer` from dominating anything as well, so no single cut breaks it: a guard.
	 */
	@:pin('guard')
	public function testACallOnAnUnresolvedResultIsBlind(): Void {
		#if (sys || nodejs)
		Assert.same([0], [
			shortQuickTakes(givingBack(
				'_inner.acquire(); self().dropAll(); Sys.sleep(1); _inner.release();',
				'public var any:Dynamic; function self():Dynamic return this; public function dropAll():Void _outer.release();',
				'd.any = d;'
			))
		]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A lock some thread gives back without having taken it excludes no one for sure, nor does one only ever taken shared
	 * or taken through two pairs of one class (reviews `kick-untaken-release-elsewhere`, `dom-sharedonly`, `dom-shared-False`).
	 */
	@:pin('control') @:killer('M-TS-DOM-OWNERLESS') @:killer('M-TS-DOM-SHARED')
	public function testOnlyAnOwnedExclusiveLockDominates(): Void {
		#if (sys || nodejs)
		Assert.same([0], [
			shortQuickTakes(givingBack(
				'_inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release();', 'public function kick():Void _outer.release();', '',
				'', 'd.kick()'
			))
		], 'given back elsewhere');
		final rw: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Rw.lock","Rw.lockShared","Sys.sleep"],'
			+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release","Rw.lock/unlock","Rw.lockShared/unlockShared"]';
		final shared: String = 'class D { final _rw:Rw = new Rw(); final _inner:Mutex = new Mutex(); public function new() {}'
			+ ' public function slow():Void { _rw.lockShared(); _inner.acquire(); Sys.sleep(1); _inner.release(); _rw.unlockShared(); }'
			+ ' public function quick():Void { _rw.lockShared(); _inner.acquire(); _inner.release(); _rw.unlockShared(); }'
			+ ' public function writer():Void { _rw.lock(); _rw.unlock(); }'
			+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> { d.slow(); d.writer(); }); d.quick(); } }';
		for (sharedLocks in [',"sharedLocks":["Rw.lockShared"]}}}', '}}}']) Assert.same([0], [
			shortQuickTakes(ThreadSafetyCheckTest.violations(rw + sharedLocks, [
				ThreadSafetyCheckTest.MUTEX,
				RW,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				shared
			]))
		], sharedLocks);
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
	 * hands `true` — under every valuation the long hold of `_inner` holds `_outer` — the caller's part known only under `closedWorld`.
	 */
	@:pin('control') @:killer('M-TS-DOM-UNDECIDED') @:killer('M-TS-DOM-ENTRY-NONE')
	public function testAConditionalTakeTheValuationDecidesCounts(): Void {
		#if (sys || nodejs)
		Assert.same([
			'info B D.outer | D._outer',
			'info B D.quick | D._outer',
			'warning B D.slow | D._outer'
		], holds(run(
			'public function slow(batch:Bool):Void { if (!batch) _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release();'
			+ ' if (!batch) _outer.release(); }' + ' public function outer():Void { _outer.acquire(); slow(true); _outer.release(); }',
			'd.slow(false); d.outer();', true, CLOSED
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
	 * `D` whose worker runs `slow(params)` — `_outer`, `_inner`, then `rest` — beside `members`, and whose main thread runs
	 * `quick` (`_outer`, then `_inner`), after `main` and with `background` on another worker.
	 */
	private static function givingBack(
		rest: String, members: String, main: String = '', params: String = '', background: String = ''
	): Array<Violation> {
		final args: String = params == '' ? '' : 'new D()';
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class U { public static function each(xs:Array<Int>, f:Int->Void):Void { for (x in xs) f(x); }'
			+ ' public static function now(f:()->Void):Void f(); }',
			'class D { public final _outer:Mutex = new Mutex(); final _inner:Mutex = new Mutex(); public function new() {} $members'
			+ ' public function slow($params):Void { _outer.acquire(); $rest }'
			+ ' public function quick():Void { _outer.acquire(); _inner.acquire(); _inner.release(); _outer.release(); }'
			+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.slow($args));'
			+ (background == '' ? '' : ' Runner.create(() -> $background);') + ' $main d.quick(); } }'
		]);
	}

	/** How many of the main thread's takes in `quick` are graded short; -1 when the fixture reports fewer than both. */
	private static function shortQuickTakes(found: Array<Violation>): Int {
		final takes: Array<Violation> = [for (v in found) if (v.data?.family == 'A' && v.data?.member == 'D.quick') v];
		// both of `quick`'s takes reach the main thread: fewer means the fixture said nothing (a parse failure)
		if (takes.length < 2) return -1;
		return takes.filter(v -> v.message.indexOf(' — short: ') >= 0).length;
	}
	/** The severities of the findings (a) at `takeInner`'s take of `_inner`, which only `quick` calls, on the main thread. */
	private static function mainTakesOfInner(config: String): Array<String> {
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(config, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class D { final _outer:Mutex = new Mutex(); final _inner:Mutex = new Mutex(); public function new() {}'
			+ ' public function slow():Void { _outer.acquire(); _inner.acquire(); Sys.sleep(1); _inner.release(); _outer.release(); }'
			+ ' public function quick():Void { _outer.acquire(); takeInner(); _outer.release(); }'
			+ ' function takeInner():Void { _inner.acquire(); _inner.release(); }'
			+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.slow()); d.quick(); } }'
		]);
		return [
			for (v in found) if (v.data?.family == 'A' && v.data?.member == 'D.takeInner') v.severity.label()
		];
	}

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
	@:pin('control') @:killer('M-TS-DOM-UNDER-HOLD-OFF') @:killer('M-TS-RUNS-AS-IS')
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

	/** A reader-writer lock: `lock` takes it exclusive, `lockShared` shared. */
	private static inline final RW: String = 'class Rw { public function new() {} public function lock():Void {} public function unlock():Void {}'
		+ ' public function lockShared():Void {} public function unlockShared():Void {} }';

}
