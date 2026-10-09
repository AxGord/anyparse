package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A hold taken inside a hold of the same lock that every caller keeps is the enclosing hold's (`LockDominance.enclosed`):
 * TM's `StandardFileSystem.cloudLocalRenameAndMoveItem` takes `_batchMutex` inside the sync's own batch hold.
 */
class ThreadSafetyEnclosedHoldTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],"reentrantLocks":["Mutex.acquire"]}}}';

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
		Assert.same(['warning B S.inner | S._m', 'warning B S.outer | S._m'], holds(run('s.bare(true);')));
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
