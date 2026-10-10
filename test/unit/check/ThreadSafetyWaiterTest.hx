package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * A `thread-safety` hold finding (b) is a stall only when something waits for the hold: the main thread never waits
 * for a hold of its own, so a hold no background thread runs is reported only when the main thread itself works long
 * under it — a long sink or a repeating short one, never a take of another lock, which is a wait on whoever holds that.
 * A holder whose thread is only an assumption (nothing in the graph runs it) keeps its finding.
 */
class ThreadSafetyWaiterTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep","FileSystem.stat"],'
		+ '"shortSinks":["FileSystem.stat"],"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';

	/**
	 * TM's `getFolderLastCloudActionAction2`: only the main thread holds `_a`, across a take of `_b` that a background
	 * hold makes long, once per item — the main thread waits for `_b` (finding (a) at the take), and no thread it
	 * stalls waits for `_a`: however often it is repeated, a wait for another lock is no work of the holder's own.
	 */
	@:pin('control') @:killer('M-TS-B-MAIN-ONLY-KEPT') @:killer('M-TS-OWN-WORK-TAKES')
	public function testAHoldOnlyTheMainThreadRunsIsNoStall(): Void {
		#if (sys || nodejs)
		final held: Array<String> = holds(
			run('s.ui();', 'public function ui():Void { _a.acquire(); for (i in 0...3) { _b.acquire(); _b.release(); } _a.release(); }')
		);
		Assert.same(['S.work | S._b'], held);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** TM's `FileListMoveFiles.moveItems`: the main thread's own per-item loop under the lock is the stall, and stays reported. */
	@:pin('control') @:killer('M-TS-OWN-WORK-DROPPED')
	public function testAMainOnlyHoldOverItsOwnLongWorkStays(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(
			's.ui(["a"]);', 'public function ui(ps:Array<String>):Void { _a.acquire(); for (p in ps) FileSystem.stat(p); _a.release(); }'
		);
		Assert.same(['S.ui | S._a'], holds(found));
		final own: Null<Violation> = found.find(v -> v.data?.member == 'S.ui' && v.data?.family == 'B');
		Assert.stringContains('main thread only', own?.message ?? '');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A holder nothing in the graph calls runs on a thread the analysis only assumes: its finding stays. */
	@:pin('control') @:killer('M-TS-B-ASSUMED-IGNORED')
	public function testAHolderOfUnknownThreadKeepsItsFinding(): Void {
		#if (sys || nodejs)
		Assert.same(
			['S.orphan | S._a', 'S.work | S._b'],
			holds(run('', 'public function orphan():Void { _a.acquire(); _b.acquire(); _b.release(); _a.release(); }'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `S.work` holds `_b` on a spawned thread across a sleep, the main thread takes `_a` in `peek` and runs `start`, and
	 * `S` declares `member` besides.
	 */
	private static function run(start: String, member: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class S { final _a:Mutex = new Mutex(); final _b:Mutex = new Mutex(); public function new() {}'
			+ ' public function work():Void { _b.acquire(); Sys.sleep(1); _b.release(); }'
			+ ' public function peek():Void { _a.acquire(); _a.release(); } $member'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s.peek(); $start } }'
		]);
	}

	/** The hold findings (b) of `found` as `<member> | <lock>`, sorted. */
	private static function holds(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'B') '${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
