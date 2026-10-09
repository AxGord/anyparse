package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A lock no sealed member names is told apart by its pair's take member alone: a hold of one stalls the main thread
 * only when the main thread takes that pair somewhere (TM's `FoldersIncrementalCloudUpdatesCache.lock`, a `lockPairs`
 * entry only the sync workers ever take).
 */
class ThreadSafetyUnnamedLockTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Gate.close","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Gate.close/open"]}}}';

	@:pin('control') @:killer('M-TS-UNNAMED-PAIR')
	public function testAnUnnamedLockNoMainThreadTakesStallsNoOne(): Void {
		#if (sys || nodejs)
		Assert.same([], holds(run('')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAMainTakeOfThePairKeepsTheFinding(): Void {
		#if (sys || nodejs)
		Assert.same(['warning B W.work | Gate.close'], holds(run('final g:Gate = new Gate(); g.close(); g.open();')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `W.work` takes the gate it is handed — no member names it — across a sleep on a worker; `main` runs `more`. */
	private static function run(more: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			'class Gate { public function new() {} public function close():Void {} public function open():Void {} }',
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class W { public static function work(g:Gate):Void { g.close(); Sys.sleep(1); g.open(); }'
			+ ' public static function main():Void { Runner.create(() -> work(new Gate())); $more } }'
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
