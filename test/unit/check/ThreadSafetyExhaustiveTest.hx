package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * The catch-all of a `switch` over a closed `enum abstract` whose every value an earlier case names is no path
 * (`ExhaustiveSwitches`): TM's `FileList.reload` throws in the `case _` of a switch over `FileListViewType` (LIST, GRID),
 * built only by its constants and a `@:from` mapping every string onto them.
 */
class ThreadSafetyExhaustiveTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire"],"spawns":["Runner.create"],'
		+ '"lockPairs":["Mutex.acquire/release"]}}}';

	private static inline final CLOSED: String = 'enum abstract V(Int) { final A; final B;'
		+ ' @:from static function of(s:String):V return s == "a" ? A : B; }';

	@:pin('control') @:killer('M-TS-EXH-OFF') @:killer('M-TS-EXH-OPAQUE')
	public function testACatchAllNoValueReachesIsNoPathInAValue(): Void {
		#if (sys || nodejs)
		Assert.same([], leaks(run(CLOSED, 'V', 'use(switch mode { case A: 1; case B: 2; case _: throw "x"; });')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-EXH-STRUCT')
	public function testACatchAllNoValueReachesIsNoPathInAStatement(): Void {
		#if (sys || nodejs)
		Assert.same([], leaks(run(CLOSED, 'V', 'switch mode { case A: step(); case B: step(); case _: throw "x"; }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-EXH-ALL-NAMED')
	public function testAValueNoCaseNamesReachesIt(): Void {
		#if (sys || nodejs)
		Assert.same(['S.work'], leaks(run(CLOSED, 'V', 'switch mode { case A: step(); case _: throw "x"; }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-EXH-FROM')
	public function testAFromClauseOpensTheAbstract(): Void {
		#if (sys || nodejs)
		Assert.same(
			['S.work'],
			leaks(run(
				'enum abstract V(Int) from Int { final A; final B; }', 'V',
				'switch mode { case A: step(); case B: step(); case _: throw "x"; }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-EXH-FROMFN')
	public function testAFunctionBuildingAnyValueOpensTheAbstract(): Void {
		#if (sys || nodejs)
		Assert.same(
			['S.work'],
			leaks(run(
				'enum abstract V(Int) { final A; final B; @:from static function of(i:Int):V return cast i; }', 'V',
				'switch mode { case A: step(); case B: step(); case _: throw "x"; }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testANullableSubjectReachesIt(): Void {
		#if (sys || nodejs)
		Assert.same(['S.work'], leaks(run(CLOSED, 'Null<V>', 'switch mode { case A: step(); case B: step(); case _: throw "x"; }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function run(abstractDecl: String, modeType: String, held: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			abstractDecl,
			'class S { final _m:Mutex = new Mutex(); var mode:$modeType = null; public function new() {} function step():Void {} function use(n:Int):Void {}'
			+ ' public function work():Void { _m.acquire(); $held _m.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s._m.acquire(); s._m.release(); } }'
		]);
	}

	/** The members of the findings (c) of `found`. */
	private static function leaks(found: Array<Violation>): Array<String> {
		return [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'C') data.member;
			}
		];
	}
	#end

}
