package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * `boundedRepeats` / `repeatBudgetMs` (`BoundedRepeats`): a repetition an entry bounds — `max` turns, `costMs` each,
 * `max × costMs` under the budget — runs as once, so the short sinks it repeats stay short; anything else repeats (TM's
 * `StandardFileSystem.listFolder`: 414 children at most, two indexed SELECTs each).
 */
class ThreadSafetyBoundedRepeatsTest extends Test {

	@:pin('control') @:killer('M-TS-BOUND-OFF')
	public function testABoundedLoopRunsAsOnce(): Void {
		#if (sys || nodejs)
		Assert.same(['info A L.a | Disk.stat'], mains(loop('{"site": "L.main", "max": 3, "costMs": 1}')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-BOUND-BUDGET')
	public function testABoundOverTheBudgetStillRepeats(): Void {
		#if (sys || nodejs)
		Assert.same(['info A L.a | Disk.stat', 'warning A L.main | L.a'], mains(loop('{"site": "L.main", "max": 100, "costMs": 1}')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-BOUND-CALL')
	public function testAnEntryForAnotherCallLeavesTheLoopRepeating(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A L.a | Disk.stat', 'warning A L.main | L.a'], mains(loop('{"site": "L.main", "call": "L.b", "max": 3, "costMs": 1}'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testNoBudgetBoundsNothing(): Void {
		#if (sys || nodejs)
		Assert.same(['info A L.a | Disk.stat', 'warning A L.main | L.a'], mains(loop('{"site": "L.main", "max": 3, "costMs": 1}', false)));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-BOUND-UNDER')
	public function testABoundedLoopUnderALockIsBrief(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(config('{"site": "H.work", "max": 3, "costMs": 1}', true), [
			ThreadSafetyCheckTest.MUTEX,
			DISK,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class H { public final _m:Mutex = new Mutex(); public function new() {}'
			+ ' public function work():Void { _m.acquire(); for (i in 0...3) Disk.stat("a"); _m.release(); }'
			+ ' public static function main():Void { final h:H = new H(); Runner.create(() -> h.work()); h._m.acquire(); h._m.release(); } }'
		]);
		Assert.same(['info B H.work | H._m'], graded(found, 'B'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static inline final DISK: String = 'class Disk { public static function stat(p:String):Void {} }';

	private static function config(entry: String, budget: Bool): String {
		return '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Disk.stat"],"shortSinks":["Disk.stat"],'
			+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],' + (budget ? '"repeatBudgetMs":50,' : '')
			+ '"boundedRepeats":[$entry]}}}';
	}

	/** `L.main` calls `a`, a short sink, in a loop of three turns, bounded by `entry`. */
	private static function loop(entry: String, budget: Bool = true): Array<Violation> {
		return ThreadSafetyCheckTest.violations(config(entry, budget), [
			DISK,
			'class L { static function a():Void Disk.stat("a"); static function b():Void {}'
			+ ' public static function main():Void for (i in 0...3) a(); }'
		]);
	}

	private static function mains(found: Array<Violation>): Array<String> {
		return graded(found, 'A');
	}

	private static function graded(found: Array<Violation>, family: String): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == family) '${v.severity.label()} $family ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
