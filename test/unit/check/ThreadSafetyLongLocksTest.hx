package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.LongLockExplain.LongLock;
import anyparse.check.LongLockExplain.LongLockReport;
import anyparse.check.ThreadSafety;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * `thread-safety`'s `--explain-long` evidence (`LongLockExplain`): for every long lock, each reason it is long at its
 * site — `crossing`, `leak`, `blind`, `unnamed`, `spans-blocking` — what it is long by once its own reasons are set
 * aside, and the main-thread takes of locks that are not long. Recording evidence moves no finding.
 */
class ThreadSafetyLongLocksTest extends Test {

	#if (sys || nodejs)
	private static final CONFIG: String =
		'{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"lockPairs":["Mutex.acquire/release"]}}}';
	#end

	/** A release in a function that never took the lock makes it crossing, at that release. */
	public function testCrossingIsTheRelease(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {} function give():Void {'
			+ ' tick(); _m.release(); } function boot():Void { _m.acquire(); tick(); _m.release(); } function tick():Void {} }';
		final lock: Null<LongLock> = longLock(explain([source]), 'A._m');
		Assert.same([{ kind: 'crossing', holder: 'A.give', at: source.indexOf('_m.release') }], reasonsOf(lock));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's correlated `if (!batch) acquire … if (!batch) release` reads as a hold that may outlive its function: recorded
	 * as a leak, at the take — evidence of what the rule does today, not a claim it is right.
	 */
	public function testCorrelatedConditionalTakeReadsAsALeak(): Void {
		#if (sys || nodejs)
		final sources: Array<String> = ThreadSafetyCheckTest.storeFixture('db.add(false);', 'fs.save();');
		final lock: Null<LongLock> = longLock(explain(sources), 'Db._batch');
		Assert.same([
			{ kind: 'leak', holder: 'Db.add', at: sources[0].indexOf('_batch.acquire(); work()') }
		], reasonsOf(lock));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold spanning a call the graph resolves to nothing is blind, at its take. */
	public function testUnresolvedCallUnderTheHoldIsBlind(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' function work(f:() -> Void):Void { _m.acquire(); f(); _m.release(); } }';
		Assert.same(
			[{ kind: 'blind', holder: 'A.work', at: source.indexOf('_m.acquire') }], reasonsOf(longLock(explain([source]), 'A._m'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold across a blocking call grows long by it: the reason names the call and the path to the sink. */
	@:pin('control') @:killer('M-TS-LONG-NEVER-GROWS')
	public function testSpansBlockingNamesTheCallAndThePath(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' function work():Void { _m.acquire(); nap(); _m.release(); } function nap():Void Sys.sleep(1); }';
		final lock: Null<LongLock> = longLock(explain([source]), 'A._m');
		Assert.same([{ kind: 'spans-blocking', holder: 'A.work', at: source.indexOf('nap();') }], reasonsOf(lock));
		Assert.same(['A.nap'], [for (r in lock?.reasons ?? []) r.call]);
		Assert.same([['A.work', 'A.nap', 'Sys.sleep']], [for (r in lock?.reasons ?? []) r.chain]);
		Assert.isNull(lock?.aside, 'a lock that spans a blocking call needs no counterfactual');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A take on a member no seal holds names no lock: it is long as the pair's take, `unnamed`. */
	public function testUnsealedTakeIsUnnamed(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { public function new() {} function work(m:Mutex):Void { m.acquire(); m.release(); } }';
		Assert.same(
			[{ kind: 'unnamed', holder: 'A.work', at: source.indexOf('m.acquire') }],
			reasonsOf(longLock(explain([source]), 'Mutex.acquire'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A lock long by a leak alone is short once the leak is set aside; one that also spans a blocking call is long by
	 * it — what fixing the leak would and would not buy.
	 */
	@:pin('control') @:killer('M-TS-ASIDE-KEEPS-SEEDS')
	public function testAsideSetsTheLocksOwnReasonsAside(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); final _n:Mutex = new Mutex(); public function new() {}'
			+ ' function keep(x:Bool):Void { if (x) _m.acquire(); } function both(x:Bool):Void { if (x) _n.acquire(); Sys.sleep(1); } }';
		final report: LongLockReport = explain([source]);
		Assert.same([], longLock(report, 'A._m')?.aside, 'the leak was the only reason');
		Assert.same(['spans-blocking'], [for (r in longLock(report, 'A._n')?.aside ?? []) r.kind]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A lock the main thread takes and nothing makes long is listed apart, at its take. */
	public function testMainThreadTakeOfAShortLock(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' function boot():Void { _m.acquire(); tick(); _m.release(); } function tick():Void {} }';
		final report: LongLockReport = explain([source]);
		Assert.same([], [for (l in report.long) l.lock]);
		Assert.same(['A._m @ ${source.indexOf('_m.acquire')} in A.boot'], [
			for (t in report.mainShort) '${t.lock} @ ${t.span?.from} in ${t.holder}'
		]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Asking for the evidence changes no finding: the counterfactual solves run on taints of their own, after the report. */
	public function testExplainingMovesNoFinding(): Void {
		#if (sys || nodejs)
		final sources: Array<String> = [
			ThreadSafetyCheckTest.MUTEX,
			'class A { final _m:Mutex = new Mutex(); final _n:Mutex = new Mutex(); public function new() {} function keep(x:Bool):Void {'
				+ ' if (x) _m.acquire(); } function boot():Void { _n.acquire(); _m.acquire(); _m.release(); _n.release(); } }'
		];
		final plain: Array<String> = [for (v in run(sources, false).found) v.message];
		Assert.isTrue(plain.length > 0);
		Assert.same(plain, [for (v in run(sources, true).found) v.message]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The report of a `CONFIG` run over `sources` (plus `Mutex`). */
	private static function explain(sources: Array<String>): LongLockReport {
		final report: Null<LongLockReport> = run([ThreadSafetyCheckTest.MUTEX].concat(sources), true).report;
		if (report == null) throw 'thread-safety: an explaining run left no report';
		return report;
	}

	/** A `CONFIG` run over `sources`, explaining when `explaining`: its findings and its report. */
	private static function run(sources: Array<String>, explaining: Bool): { found: Array<Violation>, report: Null<LongLockReport> } {
		final dir: String = CliFixture.writeDir('threadsafetylong', [{ name: 'apqlint.json', source: CONFIG }]);
		final check: ThreadSafety = new ThreadSafety();
		check.explainLongLocks(explaining);
		final found: Array<Violation> = Linter.run(
			[for (i in 0...sources.length) { file: '$dir/F$i.hx', source: sources[i] }], new HaxeQueryPlugin(), [check]
		);
		CliFixture.removeDir(dir);
		return { found: found, report: check.longLocks };
	}

	private static function longLock(report: LongLockReport, lock: String): Null<LongLock> {
		return report.long.find(l -> l.lock == lock);
	}

	/** Each reason of `lock` as kind, holder and the offset of its site in its own source. */
	private static function reasonsOf(lock: Null<LongLock>): Array<{ kind: String, holder: String, at: Null<Int> }> {
		return [
			for (r in lock?.reasons ?? []) { kind: r.kind, holder: r.holder, at: r.span?.from }
		];
	}
	#end

}
