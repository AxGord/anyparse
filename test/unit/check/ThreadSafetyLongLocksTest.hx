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
using StringTools;

/**
 * `thread-safety`'s `--explain-long` evidence (`LongLockExplain`): for every long lock, EVERY reason it is long at
 * EVERY site — `crossing`, `leak`, `blind` (naming the calls), `unnamed`, `spans-blocking` (naming the call, the path
 * and the long lock a take waits for) — what it is long by once its own reasons are set aside, and the main-thread takes
 * of locks that are not long. Recording evidence moves no finding.
 */
class ThreadSafetyLongLocksTest extends Test {

	/** The config every case runs under: `Mutex.acquire` a lock and a sink, `Sys.sleep` a sink. */
	public static final CONFIG: String =
		'{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"lockPairs":["Mutex.acquire/release"]}}}';

	/** Every release in a function that never took the lock makes it crossing, each at its own release. */
	public function testCrossingIsEveryRelease(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {} function give():Void {'
			+ ' tick(); _m.release(); } function give2():Void { tick(); _m.release(); } function boot():Void { _m.acquire(); tick();'
			+ ' _m.release(); } function tick():Void {} }';
		Assert.same([
			{ kind: 'crossing', holder: 'A.give', at: source.indexOf('_m.release') },
			{ kind: 'crossing', holder: 'A.give2', at: source.indexOf('_m.release', source.indexOf('give2')) }
		], reasonsOf(longLock(explain([source]), 'A._m')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's correlated `if (!batch) acquire … if (!batch) release` reads as a hold that may outlive its function: recorded
	 * as a leak, at the take — evidence of what the rule does today, not a claim it is right. A second leaking take is a
	 * second reason.
	 */
	public function testCorrelatedConditionalTakeReadsAsALeak(): Void {
		#if (sys || nodejs)
		final sources: Array<String> = ThreadSafetyCheckTest.storeFixture('db.add(false);', 'fs.save();');
		final db: String = sources[0].replace(
			'function work():Void {}', 'function work():Void {} function other(b:Bool):Void { if (!b) _batch.acquire(); }'
		);
		Assert.same([
			{ kind: 'leak', holder: 'Db.add', at: db.indexOf('_batch.acquire(); work()') },
			{ kind: 'leak', holder: 'Db.other', at: db.indexOf('_batch.acquire(); }', db.indexOf('function other')) }
		], reasonsOf(longLock(explain([db, sources[1]]), 'Db._batch')).filter(r -> r.kind == 'leak'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold spanning calls the graph resolves to nothing is blind, at its take, naming each such call. */
	public function testBlindNamesTheUnresolvedCalls(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' function work(f:() -> Void, g:() -> Void):Void { _m.acquire(); f(); g(); _m.release(); } }';
		final lock: Null<LongLock> = longLock(explain([source]), 'A._m');
		Assert.same([{ kind: 'blind', holder: 'A.work', at: source.indexOf('_m.acquire') }], reasonsOf(lock));
		Assert.same([['f', 'g']], [for (r in lock?.reasons ?? []) [for (c in r.unresolved) c.name]]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold across a blocking call: the reason names the call and the path to the sink, and no lock it waits for. */
	@:pin('control') @:killer('M-TS-LONG-NEVER-GROWS')
	public function testSpansBlockingNamesTheCallAndThePath(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' function work():Void { _m.acquire(); nap(); _m.release(); } function nap():Void Sys.sleep(1); }';
		final lock: Null<LongLock> = longLock(explain([source]), 'A._m');
		Assert.same([{ kind: 'spans-blocking', holder: 'A.work', at: source.indexOf('nap();') }], reasonsOf(lock));
		Assert.same(['A.nap'], [for (r in lock?.reasons ?? []) r.call]);
		Assert.same([['A.work', 'A.nap', 'Sys.sleep']], [for (r in lock?.reasons ?? []) r.chain]);
		Assert.same([null], [for (r in lock?.reasons ?? []) r.via]);
		Assert.isNull(lock?.aside, 'a lock that spans a blocking call needs no counterfactual');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Every blocking call every hold spans is listed — not only the one the solve met first. */
	@:pin('control') @:killer('M-TS-SPANS-FIRST-ONLY')
	public function testEverySpansBlockingCallIsListed(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _l:Mutex = new Mutex(); public function new() {}'
			+ ' function work():Void { _l.acquire(); nap(); nap2(); _l.release(); }'
			+ ' function more():Void { _l.acquire(); nap(); _l.release(); }'
			+ ' function nap():Void Sys.sleep(1); function nap2():Void Sys.sleep(2); }';
		Assert.same([
			{ kind: 'spans-blocking', holder: 'A.work', at: source.indexOf('nap();') },
			{ kind: 'spans-blocking', holder: 'A.work', at: source.indexOf('nap2();') },
			{ kind: 'spans-blocking', holder: 'A.more', at: source.indexOf('nap();', source.indexOf('more')) }
		], reasonsOf(longLock(explain([source]), 'A._l')));
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
		// `_n` is long only because its hold takes `_m`: with `_m`'s leak set aside `_n` is short, so `_m`'s hold of `_n` blocks nothing
		final circular: String = 'class B { final _m:Mutex = new Mutex(); final _n:Mutex = new Mutex(); public function new() {}'
			+ ' function keep(x:Bool):Void { if (x) _m.acquire(); }'
			+ ' function a():Void { _n.acquire(); _m.acquire(); _m.release(); _n.release(); }'
			+ ' function b():Void { _m.acquire(); _n.acquire(); _n.release(); _m.release(); } }';
		final loop: LongLockReport = explain([circular]);
		Assert.same(
			['spans-blocking'],
			[for (r in longLock(loop, 'B._m')?.reasons ?? []) if (r.via == 'B._n') r.kind],
			'held across a long lock'
		);
		Assert.same([], longLock(loop, 'B._m')?.aside, 'the lock it waits for is long only by this one');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The cascade: `_l` is long by a crossing release, and its hold takes `_m`, long by a leak. Set aside, `_l` is still
	 * long — by spanning the take of `_m`, which the reason names as the lock it waits for.
	 */
	@:pin('control') @:killer('M-TS-VIA-DROPPED')
	public function testAsideNamesTheLongLockAHoldWaitsFor(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _l:Mutex = new Mutex(); final _m:Mutex = new Mutex(); public function new() {}'
			+ ' function give():Void { tick(); _l.release(); } function keep(x:Bool):Void { if (x) _m.acquire(); }'
			+ ' function work():Void { _l.acquire(); _m.acquire(); _m.release(); _l.release(); } function tick():Void {} }';
		final aside: Array<{ via: Null<String>, at: Null<Int> }> = [
			for (r in longLock(explain([source]), 'A._l')?.aside ?? []) { via: r.via, at: r.span?.from }
		];
		Assert.same([{ via: 'A._m', at: source.indexOf('_m.acquire(); _m.release') }], aside);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A lock the main thread takes and nothing makes long is listed apart, at its take; a quiet root's take is marked quiet. */
	@:pin('control') @:killer('M-TS-MAINSHORT-LOUD-ONLY')
	public function testMainThreadTakesOfAShortLock(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' function boot():Void { _m.acquire(); tick(); _m.release(); }'
			+ ' function shutdown():Void { _m.acquire(); tick(); _m.release(); } function tick():Void {} }';
		final report: Null<LongLockReport> = run(
			[ThreadSafetyCheckTest.MUTEX, source],
			true,
			'{"rules":{"thread-safety":{"sinks":["Mutex.acquire"],"lockPairs":["Mutex.acquire/release"],"quietRoots":["A.shutdown"]}}}'
		).report;
		Assert.same([], [for (l in report?.long ?? []) l.lock]);
		Assert.same(
			[
				'A._m @ ${source.indexOf('_m.acquire')} in A.boot quiet=false',
				'A._m @ ${source.indexOf('_m.acquire', source.indexOf('shutdown'))} in A.shutdown quiet=true'
			],
			[
				for (t in report?.mainShort ?? []) '${t.lock} @ ${t.span?.from} in ${t.holder} quiet=${t.quiet}'
			]
		);
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
		final plain: Array<String> = [for (v in run(sources, false, CONFIG).found) v.message];
		Assert.isTrue(plain.length > 0);
		Assert.same(plain, [for (v in run(sources, true, CONFIG).found) v.message]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The report of a `CONFIG` run over `sources` (plus `Mutex`). */
	private static function explain(sources: Array<String>): LongLockReport {
		final report: Null<LongLockReport> = run([ThreadSafetyCheckTest.MUTEX].concat(sources), true, CONFIG).report;
		if (report == null) throw 'thread-safety: an explaining run left no report';
		return report;
	}

	/** A run of `config` over `sources`, explaining when `explaining`: its findings and its report. */
	private static function run(
		sources: Array<String>, explaining: Bool, config: String
	): { found: Array<Violation>, report: Null<LongLockReport> } {
		final dir: String = CliFixture.writeDir('threadsafetylong', [{ name: 'apqlint.json', source: config }]);
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
