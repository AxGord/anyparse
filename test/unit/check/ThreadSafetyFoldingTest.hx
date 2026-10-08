package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * How `thread-safety` folds findings of one root cause onto one warning, the rest kept at `info` naming it: a sink's
 * own body is the sink's finding; every main-thread take of one lock waits for the same holders; a hold taken inside
 * another hold of the same function is that hold's finding.
 */
class ThreadSafetyFoldingTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep","Net.fetch","Lock.wait"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';

	private static inline final NET: String = 'class Lock { public function new() {} public function wait():Void {} }'
		+ ' class Net { final _done:Lock = new Lock(); public function new() {} public function fetch():Void { _done.wait(); }'
		+ ' public function fetchDeep():Void deep(); function deep():Void _done.wait(); }';

	/** TM's `LockMutex.lock` / `BlockingNativeURLLoader.go`: the wait a sink's own body makes is the sink's finding. */
	@:pin('control') @:killer('M-TS-INSIDE-SINK-OFF')
	public function testAWaitInsideASinksBodyIsTheSinks(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A Net.fetch | Lock.wait', 'warning A A.main | Net.fetch'], graded(run([
				NET,
				'class A { public static function main():Void { final n:Net = new Net(); n.fetch(); } }'
			])).filter(g -> g.indexOf('Net.deep') < 0)
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A function only a sink's body calls is that sink's machinery too. */
	@:pin('control') @:killer('M-TS-INSIDE-SINK-DIRECT-ONLY')
	public function testAFunctionOnlyASinkCallsIsTheSinks(): Void {
		#if (sys || nodejs)
		Assert.same(
			[
				'info A Net.deep | Lock.wait',
				'info A Net.fetch | Lock.wait',
				'warning A A.main | Net.fetch'
			],
			graded(run([
				NET,
				'class A { public static function main():Void { final n:Net = new Net(); n.fetch(); } }',
				'class B { public static function go():Void { final n:Net = new Net(); n.fetchDeep(); } }'
			], '{"rules":{"thread-safety":{"sinks":["Net.fetch","Net.fetchDeep","Lock.wait"]}}}')).filter(g -> g.indexOf('B.go') < 0)
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's `_batchMutex`: every main-thread take of one long lock waits for the same holders — one warning, at the take
	 * inside the lock's wrapper when there is one, else the first by member.
	 */
	@:pin('control') @:killer('M-TS-ONE-TAKE-OFF') @:killer('M-TS-ONE-TAKE-NO-WRAPPER')
	public function testMainTakesOfOneLockWarnOnce(): Void {
		#if (sys || nodejs)
		final source: String = 'class S { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' public function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); }'
			+ ' public function a():Void { _m.acquire(); _m.release(); } public function b():Void { _m.acquire(); _m.release(); }'
			+ ' MEMBERS public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s.a(); s.b(); CALLS } }';
		Assert.same(['info A S.b | Mutex.acquire', 'warning A S.a | Mutex.acquire'], takes(run([
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			StringTools.replace(StringTools.replace(source, 'MEMBERS', ''), 'CALLS', '')
		])), 'the first by member');
		Assert.same(
			[
				'info A S.a | Mutex.acquire',
				'info A S.b | Mutex.acquire',
				'warning A S.zLock | Mutex.acquire'
			],
			takes(run([
				ThreadSafetyCheckTest.MUTEX,
				RUNNER,
				StringTools.replace(
					StringTools.replace(
						source, 'MEMBERS', 'public function zLock():Void _m.acquire(); public function zUnlock():Void _m.release();'
					),
					'CALLS', 's.zLock(); s.zUnlock();'
				)
			])),
			'the wrapper'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** TM's `getText`: the tree lock taken inside the hold of `_mutationMutex` is that hold's finding. */
	@:pin('control') @:killer('M-TS-NEST-OFF')
	public function testAHoldInsideAnotherIsItsFinding(): Void {
		#if (sys || nodejs)
		Assert.same(['info B S.work | S._b', 'warning B S.work | S._a'], holds(run([
			ThreadSafetyCheckTest.MUTEX,
			RUNNER,
			'class S { final _a:Mutex = new Mutex(); final _b:Mutex = new Mutex(); public function new() {}'
			+ ' public function work():Void { _a.acquire(); _b.acquire(); Sys.sleep(1); _b.release(); _a.release(); }'
			+ ' public function ui():Void { _a.acquire(); _a.release(); _b.acquire(); _b.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s.ui(); } }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static inline final RUNNER: String = 'class Runner { public static function create(fn:()->Void):Void {} }';

	private static function run(sources: Array<String>, ?config: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(config ?? CONFIG, sources);
	}

	/** The findings of `found` of `family` as `<severity> <family> <member> | <subject>`, sorted. */
	private static function graded(found: Array<Violation>, ?family: String): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && (family == null || data.family == family))
					'${v.severity.label()} ${data.family} ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}

	private static inline function takes(found: Array<Violation>): Array<String> {
		return graded(found, 'A');
	}

	private static inline function holds(found: Array<Violation>): Array<String> {
		return graded(found, 'B');
	}
	#end

}
