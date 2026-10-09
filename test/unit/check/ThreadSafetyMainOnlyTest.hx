package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A hold only the main thread runs stalls no other thread; what it reports is the main thread's own long work under
 * the lock — finding (a)'s. Where (a) already warns of that work at another member (the sink's own call, or the
 * repeating call that owns it), the hold adds no second warning (TM's `StandardFileSystem.deleteItem` over
 * `deleteItemInternal`'s per-child unlinks); where (a) reports it at the holder itself (TM's `FileListMoveFiles.moveItems`
 * loop), the hold keeps its warning.
 */
class ThreadSafetyMainOnlyTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep","Disk.stat"],'
		+ '"shortSinks":["Disk.stat"],"lockPairs":["Mutex.acquire/release"]}}}';

	@:pin('control') @:killer('M-TS-MAINONLY-ELSEWHERE-OFF')
	public function testWorkReportedAtACalleeLeavesTheHoldInfo(): Void {
		#if (sys || nodejs)
		Assert.same(['info B M.ui | M._m'], holds(run('work();')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-MAINONLY-SAME-MEMBER')
	public function testWorkReportedAtTheHolderKeepsTheWarning(): Void {
		#if (sys || nodejs)
		Assert.same(['warning B M.ui | M._m'], holds(run('Sys.sleep(1);')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-MAINONLY-MOVED')
	public function testWorkOwnedByARepeatingCalleeLeavesTheHoldInfo(): Void {
		#if (sys || nodejs)
		Assert.same(['info B M.ui | M._m'], holds(run('many();')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function run(held: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Disk { public static function stat(p:String):Void {} }',
			'class M { final _m:Mutex = new Mutex(); public function new() {} function work():Void Sys.sleep(1);'
			+ ' function many():Void for (i in 0...3) one(); function one():Void Disk.stat("x");'
			+ ' public function ui():Void { _m.acquire(); $held _m.release(); }'
			+ ' public static function main():Void { final m:M = new M(); m.ui(); } }'
		]);
	}

	private static function holds(found: Array<Violation>): Array<String> {
		return [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'B') '${v.severity.label()} B ${data.member} | ${data.subject}';
			}
		];
	}
	#end

}
