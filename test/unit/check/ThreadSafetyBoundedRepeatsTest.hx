package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

using Lambda;

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
		Assert.same(
			['info A L.a | Disk.stat', 'warning A L.main | for (i in 0...3)'], mains(loop('{"site": "L.main", "max": 100, "costMs": 1}'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-BOUND-CALL')
	public function testAnEntryForAnotherCallLeavesTheLoopRepeating(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A L.a | Disk.stat', 'warning A L.main | for (i in 0...3)'],
			mains(loop('{"site": "L.main", "call": "L.b", "max": 3, "costMs": 1}'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testNoBudgetBoundsNothing(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A L.a | Disk.stat', 'warning A L.main | for (i in 0...3)'],
			mains(loop('{"site": "L.main", "max": 3, "costMs": 1}', false))
		);
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

	/** An entry binds ONE repetition: over a member with nested loops it binds none, says why, and both loops repeat. */
	@:pin('control') @:killer('M-TS-BOUND-ONE')
	public function testAnEntryOverNestedLoopsBindsNone(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = nested('{"site": "N.run", "max": 3, "costMs": 1}');
		Assert.same(['warning A N.run | Disk.stat'], mains(found));
		Assert.isTrue(notice(found, 'boundedRepeats entry "N.run" dropped: 2 repetitions there'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A sibling loop the entry was not written for keeps repeating: the entry binds none of the two. */
	public function testAnEntryOverSiblingLoopsBindsNone(): Void {
		#if (sys || nodejs)
		final found: Array<String> = mains(siblings('{"site": "N.run", "max": 3, "costMs": 1}'));
		Assert.isTrue(found.contains('warning A N.run | for (i in 0...3)'));
		Assert.isTrue(found.contains('warning A N.run | while (pending())'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `loop` names the loop it binds by its header: that loop runs as once, its sibling keeps repeating. */
	public function testALoopEntryBindsThatLoopOnly(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = siblings('{"site": "N.run", "loop": "for (i in 0...3)", "max": 3, "costMs": 1}');
		Assert.same([
			'info A N.a | Disk.stat',
			'info A N.b | Disk.stat',
			'warning A N.run | while (pending())'
		], mains(found));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A lambda the member defines repeats on its own: its loop is one more repetition, and the entry binds none. */
	public function testALambdaLoopInTheMemberIsNoPartOfTheBound(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(config('{"site": "N.run", "max": 3, "costMs": 1}', true), [
			DISK,
			'class N { public static var cb:Array<String>->Void; public static function run():Void { for (i in 0...3) Disk.stat("a");'
			+ ' cb = rows -> for (r in rows) Disk.stat(r); } public static function main():Void { run(); cb(["x"]); } }'
		]);
		Assert.isTrue(mains(found).contains('warning A N.run | Disk.stat'));
		Assert.isTrue(notice(found, 'boundedRepeats entry "N.run" dropped: 3 repetitions there'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A `call` that is no string drops the whole entry — never widened to the member. */
	@:pin('control') @:killer('M-TS-BOUND-CALL-SHAPE')
	public function testAMalformedCallDropsTheEntry(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = twoLoops('{"site": "N.run", "call": ["N.a"], "max": 3, "costMs": 1}');
		Assert.same([
			'info A N.a | Disk.stat',
			'info A N.b | Disk.stat',
			'warning A N.run | for (i in 0...3)',
			'warning A N.run | for (x in xs)'
		], mains(found));
		Assert.isTrue(notice(found, 'boundedRepeats[0] dropped: "call" is not a string'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The well-formed `call` binds the loop around it alone. */
	public function testACallEntryBindsTheLoopAroundIt(): Void {
		#if (sys || nodejs)
		Assert.same([
			'info A N.a | Disk.stat',
			'info A N.b | Disk.stat',
			'warning A N.run | for (x in xs)'
		], mains(twoLoops('{"site": "N.run", "call": "N.a", "max": 3, "costMs": 1}')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A turn costing nothing would bound any number of turns: `costMs` must be positive, or the entry is dropped. */
	@:pin('control') @:killer('M-TS-BOUND-COST-ZERO')
	public function testAZeroCostDropsTheEntry(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = loop('{"site": "L.main", "max": 1000000000000, "costMs": 0}');
		Assert.same(['info A L.a | Disk.stat', 'warning A L.main | for (i in 0...3)'], mains(found));
		Assert.isTrue(notice(found, 'boundedRepeats[0] dropped: "costMs" is not a positive number'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `site` names one member, never a pattern — even one that happens to match a single member. */
	@:pin('control') @:killer('M-TS-BOUND-SITE-PATTERN')
	public function testASitePatternDropsTheEntry(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(config('{"site": "R.*", "max": 3, "costMs": 1}', true), [
			DISK,
			'class R { public static function run():Void for (i in 0...3) a(); static function a():Void Disk.stat("a"); }',
			'class Main { public static function main():Void R.run(); }'
		]);
		Assert.isTrue(mains(found).contains('warning A R.run | for (i in 0...3)'));
		Assert.isTrue(notice(found, 'boundedRepeats[0] dropped: "site" is a pattern'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Two bound loops, one inside the other, run the PRODUCT of their bounds: 10 × 10 turns of 1 ms are over 50. */
	@:pin('control') @:killer('M-TS-BOUND-PRODUCT')
	public function testNestedBoundsMultiply(): Void {
		#if (sys || nodejs)
		Assert.isTrue(
			mains(nested(
				'{"site": "N.run", "loop": "for (g in groups)", "max": 10, "costMs": 1},'
				+ ' {"site": "N.run", "loop": "for (x in g)", "max": 10, "costMs": 1}'
			)).contains('warning A N.run | Disk.stat')
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `loop` label with no rank that names several loops of the member binds none, and says so: a loop added later with
	 * the same header would otherwise take the bound its first was given (review round 2 `br1-a`, `br1-b`). The rank
	 * names one.
	 */
	@:pin('control') @:killer('M-TS-BOUND-LABEL-SEVERAL')
	public function testALabelNamingSeveralLoopsBindsNone(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = sameHeaders('{"site": "N.run", "loop": "for (i in 0...n)", "max": 3, "costMs": 1}');
		Assert.same([
			'info A N.a | Disk.stat',
			'info A N.b | Disk.stat',
			'warning A N.run | for (i in 0...n)',
			'warning A N.run | for (i in 0...n) #2'
		], mains(found));
		Assert.isTrue(notice(found, 'loop "for (i in 0...n)" names several loops there'));
		Assert.same([
			'info A N.a | Disk.stat',
			'info A N.b | Disk.stat',
			'warning A N.run | for (i in 0...n)'
		], mains(sameHeaders('{"site": "N.run", "loop": "for (i in 0...n) #2", "max": 3, "costMs": 1}')), 'the rank');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A loop's rank counts only the loops of its header that repeat a call which may block: one added beside it that
	 * blocks nothing leaves its label, and the key of the finding it names, as they were (review round 2 `ks2-a`, `ks2-b`).
	 */
	@:pin('control') @:killer('M-TS-LABEL-RANK-SINK')
	public function testALoopThatBlocksNothingTakesNoRank(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(config('{"site": "Z.none", "max": 1, "costMs": 1}', true), [
			DISK,
			'class K { static function a():Void Disk.stat("a");'
			+ ' static function p(xs:Array<String>):Void { var n:Int = 0; for (x in xs) n++; for (x in xs) a(); }'
			+ ' public static function main():Void p(["x"]); }'
		]);
		Assert.same(['info A K.a | Disk.stat', 'warning A K.p | for (x in xs)'], mains(found));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Bounds in different functions on one way multiply: 40 turns of a loop calling a function that loops 40 times are
	 * 1600 turns, over the budget though each bound alone is under it — on the main thread and under a lock alike
	 * (review round 2 `br2-nested-entries`). A short call run as once by bounds alone names them.
	 */
	@:pin('control') @:killer('M-TS-BOUND-ACROSS') @:killer('M-TS-BOUND-ACROSS-HOLD') @:killer('M-TS-BOUND-NOTE')
	public function testBoundsMultiplyAlongTheWay(): Void {
		#if (sys || nodejs)
		final entries: String = '{"site": "N.run", "max": 40, "costMs": 1}, {"site": "N.each", "max": 40, "costMs": 1}';
		final across: Array<Violation> = ThreadSafetyCheckTest.violations(config(entries, true), [
			DISK,
			'class N { static function each(ys:Array<String>):Void for (y in ys) Disk.stat(y);'
			+ ' public static function run(xs:Array<Array<String>>):Void for (x in xs) each(x);'
			+ ' public static function main():Void run([["x"]]); }'
		]);
		Assert.same(['info A N.each | Disk.stat', 'warning A N.run | for (x in xs)'], mains(across), 'main thread');
		final held: Array<Violation> = ThreadSafetyCheckTest.violations(
			config('{"site": "H.work", "max": 10, "costMs": 1}, {"site": "H.each", "max": 10, "costMs": 1}', true), [
				ThreadSafetyCheckTest.MUTEX,
				DISK,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class H { public final _m:Mutex = new Mutex(); public function new() {}'
				+ ' function each():Void for (i in 0...10) Disk.stat("a");'
				+ ' public function work():Void { _m.acquire(); for (i in 0...10) each(); _m.release(); }'
				+ ' public static function main():Void { final h:H = new H(); Runner.create(() -> h.work()); h._m.acquire(); h._m.release(); } }'
			]
		);
		Assert.same(['warning B H.work | H._m'], graded(held, 'B'), 'under a lock');
		final once: Array<Violation> = loop('{"site": "L.main", "max": 3, "costMs": 1}');
		Assert.isTrue(once.exists(v -> v.message.indexOf('`boundedRepeats` binds on its ways (L.main ≤ 3 × 1 ms)') >= 0), 'named');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static inline final DISK: String = 'class Disk { public static function stat(p:String):Void {} }';

	/** `N.run` loops `xs.length` times over `a`, then three times over `b`, both loops written `for (i in 0...n)`, bounded by `entry`. */
	private static function sameHeaders(entry: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(config(entry, true), [
			DISK,
			'class N { static function a():Void Disk.stat("a"); static function b():Void Disk.stat("b");'
			+ ' public static function run(xs:Array<String>):Void { var n:Int = xs.length; for (i in 0...n) a(); n = 3; for (i in 0...n) b(); }'
			+ ' public static function main():Void run(["x"]); }'
		]);
	}

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

	/** `N.run` calls a short sink inside a loop nested in another, bounded by `entries`. */
	private static function nested(entries: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(config(entries, true), [
			DISK,
			'class N { public static function run(groups:Array<Array<String>>):Void { for (g in groups) for (x in g) Disk.stat(x); }'
			+ ' public static function main():Void run([["a"]]); }'
		]);
	}

	/** `N.run` loops over `a` three times, then over `b` while `pending()`, bounded by `entry`. */
	private static function siblings(entry: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(config(entry, true), [
			DISK,
			'class N { static function pending():Bool return true; static function a():Void Disk.stat("a");'
			+ ' static function b():Void Disk.stat("b");'
			+ ' public static function run():Void { for (i in 0...3) a(); while (pending()) b(); }'
			+ ' public static function main():Void run(); }'
		]);
	}

	/** `N.run` loops over `a` three times and over `b` once per item, bounded by `entry`. */
	private static function twoLoops(entry: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(config(entry, true), [
			DISK,
			'class N { static function a():Void Disk.stat("a"); static function b():Void Disk.stat("b");'
			+ ' public static function run(xs:Array<String>):Void { for (i in 0...3) a(); for (x in xs) b(); }'
			+ ' public static function main():Void run(["x"]); }'
		]);
	}

	/** Whether `found` holds the config notice containing `text`. */
	private static function notice(found: Array<Violation>, text: String): Bool {
		return found.exists(v -> v.data == null && v.message.indexOf(text) >= 0);
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
