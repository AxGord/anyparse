package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.LongLockExplain.LongLock;
import anyparse.check.LongLockExplain.LongLockKind;
import anyparse.check.LongLockExplain.LongLockReason;
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
	 * TM's correlated `if (!batch) acquire … if (!batch) release`: the parameter is a fixed flag (`FixedFlags`), so the
	 * window is traced once per value and no run takes without giving back — no leak. A take nothing gives back is one.
	 */
	@:pin('control') @:killer('M-TS-FLAGS-OFF')
	public function testCorrelatedConditionalTakeIsNoLeak(): Void {
		#if (sys || nodejs)
		final sources: Array<String> = ThreadSafetyCheckTest.storeFixture('db.add(false);', 'fs.save();');
		final db: String = sources[0].replace(
			'function work():Void {}', 'function work():Void {} function other(b:Bool):Void { if (!b) _batch.acquire(); }'
		);
		Assert.same([
			{ kind: 'leak', holder: 'Db.other', at: db.indexOf('_batch.acquire(); }', db.indexOf('function other')) }
		], reasonsOf(longLock(explain([db, sources[1]]), 'Db._batch')).filter(r -> r.kind == 'leak'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A flag the function writes is no fixed flag: the correlated take and give still read as a leak. */
	@:pin('control') @:killer('M-TS-FLAGS-WRITTEN')
	public function testAWrittenFlagIsNoFixedFlag(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' public function take(b:Bool):Void { if (b) _m.acquire(); b = !b; if (b) _m.release(); }'
			+ ' public static function main():Void { new A().take(true); } }';
		Assert.same(['A.take'], [
			for (r in reasonsOf(longLock(explain([source]), 'A._m'))) if (r.kind == 'leak') r.holder
		]);
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

	/**
	 * A virtual call dispatching to several targets is a reason per target, in `reasons` and `aside` alike — one
	 * normaliser, so the two lists compare: here `_w` is long by a leak, and its hold across `upd` blocks through each override.
	 */
	@:pin('control') @:killer('M-TS-REASONS-DEDUP-BY-SITE')
	public function testAVirtualCallIsAReasonPerTarget(): Void {
		#if (sys || nodejs)
		final sources: Array<String> = [
			'class W { final _w:Mutex = new Mutex(); final _s:Mutex = new Mutex(); public function new() {}'
				+ ' function keep(x:Bool):Void { if (x) _w.acquire(); } function blindS(f:() -> Void):Void { _s.acquire(); f(); _s.release(); }'
				+ ' public function save(t:Int):Void { _w.acquire(); upd(t); _w.release(); } public function upd(t:Int):Void write();'
				+ ' function write():Void { _s.acquire(); _s.release(); } }',
			'class D extends W { override public function upd(t:Int):Void super.upd(t); }',
			'class E extends W { override public function upd(t:Int):Void super.upd(t); }'
		];
		final lock: Null<LongLock> = longLock(explain(sources), 'W._w');
		Assert.same(['D.upd', 'E.upd', 'W.upd'], sortedCalls(lock?.reasons ?? []));
		Assert.same(['D.upd', 'E.upd', 'W.upd'], sortedCalls(lock?.aside ?? []));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A hold waiting for the lock ITSELF — a re-take on another object, a call that takes it again — blocks only once the
	 * lock is long already: such reasons are circular, left out of `reasons` and `aside`, and counted.
	 */
	@:pin('control') @:killer('M-TS-CIRCULAR-COUNTED')
	public function testACircularReTakeIsCountedApart(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {}'
			+ ' function keep(x:Bool):Void { if (x) _m.acquire(); } function other(o:A):Void { _m.acquire(); o.inner(); _m.release(); }'
			+ ' public function inner():Void { _m.acquire(); _m.release(); } }';
		final lock: Null<LongLock> = longLock(explain([source]), 'A._m');
		Assert.same(['leak'], [for (r in lock?.reasons ?? []) r.kind]);
		Assert.equals(1, lock?.circular);
		Assert.same([], lock?.aside, 'nothing but the lock itself holds it long once the leak is set aside');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A hold the control-flow walk cannot trace — a take in a field initializer — is its own reason, `untraced`. */
	public function testAnInitializerTakeIsUntraced(): Void {
		#if (sys || nodejs)
		final source: String = 'class A { final n:Mutex = new Mutex(); final w:Int = { n.acquire(); 2; }; public function new() {}'
			+ ' function boot():Void { n.acquire(); n.release(); } }';
		Assert.same(
			[{ kind: 'untraced', holder: 'A.<init>', at: source.indexOf('n.acquire') }], reasonsOf(longLock(explain([source]), 'A.n'))
		);
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

	/**
	 * A flag whose name something else in the function declares is no fixed flag: an `if` reading the name past that
	 * declaration reads the other binding, so the correlated take and give still read as a leak (review r4 `L2`, `L2d`).
	 */
	@:pin('control') @:killer('M-TS-FLAGS-SHADOW') @:killer('M-TS-FLAGS-WRITTEN')
	public function testAShadowedFlagIsNoFixedFlag(): Void {
		#if (sys || nodejs)
		for (shadow in ['var b:Bool = c();', 'final b:Bool = b && c();']) {
			final source: String = 'class A { final _m:Mutex = new Mutex(); public function new() {} function c():Bool return false;'
				+ ' public function take(b:Bool):Void { if (b) _m.acquire(); $shadow if (b) _m.release(); }'
				+ ' public static function main():Void { new A().take(true); } }';
			Assert.same(['A.take'], [
				for (r in reasonsOf(longLock(explain([source]), 'A._m'))) if (r.kind == 'leak') r.holder
			], shadow);
		}
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

	/** The calls the `spans-blocking` reasons of `reasons` name, sorted. */
	private static function sortedCalls(reasons: Array<LongLockReason>): Array<Null<String>> {
		final calls: Array<Null<String>> = [for (r in reasons) if (r.kind == LongLockKind.SpansBlocking) r.call];
		calls.sort(Reflect.compare);
		return calls;
	}
	#end

}
