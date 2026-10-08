package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The structured identity (`Check.FindingData`) every `thread-safety` finding carries: its family, the member it sits
 * in, its subject, and the whole chain the message caps. A tool keys findings by the first three, so they must not
 * move with the chain.
 */
class ThreadSafetyFindingDataTest extends Test {

	/** Finding (a) names the main-thread function, the sink, and every hop from the root, past the text's cap. */
	@:pin('control') @:killer('M-TS-DATA-CHAIN-CAPPED')
	public function testMainSinkDataCarriesTheWholeChain(): Void {
		#if (sys || nodejs)
		final hops: Int = 12;
		final calls: String = [
			for (i in 0...hops) 'function f$i():Void ${i + 1 < hops ? 'f${i + 1}()' : 'Sys.sleep(1)'};'
		].join(' ');
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}', ['class A { $calls }']
		);
		Assert.equals(1, found.length);
		final data: Null<FindingData> = found[0].data;
		Assert.notNull(data);
		if (data == null) return;
		Assert.equals('A', data.family);
		Assert.equals('A.f${hops - 1}', data.member);
		Assert.equals('Sys.sleep', data.subject);
		Assert.same([for (i in 0...hops) 'A.f$i'].concat(['Sys.sleep']), data.chain);
		Assert.stringContains('...', found[0].message, 'the text still caps the chain it shows');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A sink called from a lambda is the lambda's enclosing member's finding: a lambda's id moves with every lambda added before it. */
	@:pin('control') @:killer('M-TS-DATA-MEMBER-LAMBDA')
	public function testLambdaFindingNamesItsEnclosingMember(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}', [
			'class A { function boot():Void { final f:() -> Void = () -> Sys.sleep(1); f(); } }'
		]);
		Assert.same(['A.boot'], [for (v in found) v.data?.member]);
		Assert.stringContains('A.boot#', found[0].message, 'the message keeps the lambda\'s own id');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A dispatch reaching several sinks names them all, sorted, in the subject and at the chain's end. */
	@:pin('control') @:killer('M-TS-DATA-SUBJECT-UNSORTED')
	public function testSeveralSinksAreOneSortedSubject(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"sinks":["Zed.m","Ann.m"]}}}', [
			'interface I { function m():Void; }',
			'class Zed implements I { public function new() {} public function m():Void {} }',
			'class Ann implements I { public function new() {} public function m():Void {} }',
			'class A { final i:I = new Zed(); function boot():Void i.m(); }'
		]);
		Assert.same(['Ann.m / Zed.m'], [for (v in found) v.data?.subject]);
		Assert.same([['A.boot', 'Ann.m', 'Zed.m']], [for (v in found) v.data?.chain], 'the chain ends in each sink, sorted');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Finding (b) names the holder, the lock object, and the path from the holder to the call that blocks. */
	public function testLockHeldData(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> =
			ThreadSafetyCheckTest.violations(
				'{"rules":{"thread-safety":{"sinks":["File.saveContent"],"lockPairs":["Mut.lock/unlock"]}}}', [
					'class A { private final _m:Mut; function work():Void { _m.lock(); save(); _m.unlock(); } '
					+ 'function save():Void File.saveContent(1, 2); }',
					'class Mut { public function lock():Void {} public function unlock():Void {} }'
				]
			)
				.filter(v -> v.data?.family == 'B');
		Assert.same(
			[
				{
					family: 'B',
					member: 'A.work',
					subject: 'A._m',
					chain: ['A.work', 'A.save', 'File.saveContent']
				}
			],
			[
				for (v in found) v.data
			]
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Finding (c) names the holder and the lock; a bare `throw` has no chain past the holder. */
	public function testThrowHeldData(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> =
			ThreadSafetyCheckTest.violations(
				'{"rules":{"thread-safety":{"sinks":["Mutex.acquire"],"lockPairs":["Mutex.acquire/release"]}}}', [
					ThreadSafetyCheckTest.MUTEX,
					'class Db { final _m:Mutex = new Mutex(); public function new() {}'
					+ ' public function add(kind:Int):Void { _m.acquire(); if (kind == 0) throw "unsupported"; _m.release(); } }'
				]
			)
				.filter(v -> v.data?.family == 'C');
		Assert.same([
			{
				family: 'C',
				member: 'Db.add',
				subject: 'Db._m',
				chain: ['Db.add']
			}
		], [for (v in found) v.data]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Finding (d) names the main-side holder, the two locks sorted, and the main side's chain. */
	@:pin('control') @:killer('M-TS-DATA-SUBJECT-UNSORTED')
	public function testLockOrderData(): Void {
		#if (sys || nodejs)
		// `Db` renamed past `Fs`: the walk meets the background step's pair (`Zd._batch`, then `Fs._mutation`) first
		final found: Array<Violation> = ThreadSafetyCheckTest.orderFindings([
			for (source in ThreadSafetyCheckTest.storeFixture(
				'acquireMutation(); db.add(false); releaseMutation();', 'Runner.create(fs.download); fs.save();'
			)) source.replace('Db', 'Zd')
		]);
		Assert.same(
			[
				{
					family: 'D',
					member: 'Fs.save',
					subject: 'Fs._mutation / Zd._batch',
					chain: ['Fs.save', 'Zd.add', 'Mutex.acquire']
				}
			],
			[
				for (v in found) v.data
			]
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two main-thread holders make the same inversion: which one the finding names — its member, its anchor — must not
	 * depend on which the walk met first, so calling them in either order gives one finding.
	 */
	@:pin('control') @:killer('M-TS-ORDER-ONE-ARRIVAL')
	public function testLockOrderKeyIgnoresWalkOrder(): Void {
		#if (sys || nodejs)
		final keys: Array<Array<String>> = [
			for (start in [
				'Runner.create(fs.download); fs.save(); fs.store();',
				'Runner.create(fs.download); fs.store(); fs.save();'
			]) [
				for (v in ThreadSafetyCheckTest.orderFindings([
					for (source in ThreadSafetyCheckTest.storeFixture('acquireMutation(); db.add(false); releaseMutation();', start))
						source.replace(
							'public function save():Void',
							'public function store():Void { acquireMutation(); db.add(false); releaseMutation(); } public function save():Void'
						)
				])) '${v.data?.member} ${v.data?.subject} @${v.span?.from}'
			]
		];
		Assert.equals(1, keys[0].length);
		Assert.same(keys[0], keys[1]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two main-thread holders whose states stay apart (one also holds `_other`): the walk meets `store` first, a hop
	 * nearer the root, yet the finding names the least holder, `save` — the step kept is the one that precedes, not the
	 * first one seen.
	 */
	@:pin('control') @:killer('M-TS-ORDER-MAIN-FIRST-SEEN')
	public function testLockOrderNamesTheLeastHolder(): Void {
		#if (sys || nodejs)
		final sources: Array<String> = [
			for (source in ThreadSafetyCheckTest.storeFixture(
				'acquireMutation(); _other.acquire(); db.add(false); _other.release(); releaseMutation();',
				'Runner.create(fs.download); fs.store(); fs.wrap();'
			)) source.replace(
				'public function save():Void',
				'final _other:Mutex = new Mutex(); public function store():Void {'
				+ ' acquireMutation(); db.add(false); releaseMutation(); } public function wrap():Void save(); public function save():Void'
			)
		];
		Assert.same(['Fs.save'], [
			for (v in ThreadSafetyCheckTest.orderFindings(sources)) if (v.data?.subject == 'Db._batch / Fs._mutation') v.data?.member
		]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two main-thread holders reach ONE downstream state that takes the second lock: the holder the finding names is the
	 * least over every way into that state, so renaming a function outside the key (`p0` to `q0`), or swapping the two calls, does not move it.
	 */
	@:pin('control') @:killer('M-TS-ORDER-CLIMB-FIRST', 'M-TS-ORDER-ONE-ARRIVAL')
	public function testLockOrderKeySurvivesARenameOutsideIt(): Void {
		#if (sys || nodejs)
		final source: String = 'class Fs { final _a:Mutex = new Mutex(); final _b:Mutex = new Mutex(); public function new() {}'
			+ ' public static function main():Void { final fs:Fs = new Fs(); Runner.create(fs.bg); fs.p1(); fs.p0(); }'
			+ ' public function p1():Void alpha(); public function p0():Void zeta();'
			+ ' public function alpha():Void { _a.acquire(); t(); _a.release(); } public function zeta():Void { _a.acquire(); t(); _a.release(); }'
			+ ' public function t():Void { _b.acquire(); _b.release(); }'
			+ ' public function bg():Void { _b.acquire(); _a.acquire(); _a.release(); _b.release(); } }';
		final keys: Array<Array<String>> = [
			for (renamed in [
				source,
				source.replace('p0', 'q0'),
				source.replace('fs.p1(); fs.p0();', 'fs.p0(); fs.p1();')
			]) [
				for (v in ThreadSafetyCheckTest.orderFindings([renamed])) '${v.data?.member} ${v.data?.subject} @${v.span?.from}'
			]
		];
		Assert.same(['Fs.alpha Fs._a / Fs._b @${source.indexOf('t();')}'], keys[0]);
		Assert.same(keys[0], keys[1]);
		Assert.same(keys[0], keys[2], 'nor does calling the two holders in the other order');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A throw raised by a callee names the raising call's chain after the holder. */
	@:pin('control') @:killer('M-TS-DATA-RAISER-CHAIN')
	public function testThrowHeldDataFollowsTheRaiser(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(
			'{"rules":{"thread-safety":{"sinks":["Mutex.acquire"],"lockPairs":["Mutex.acquire/release"],"throwers":["FileSystem.createDirectory"]}}}',
			[ThreadSafetyCheckTest.MUTEX, ThreadSafetyCheckTest.watcherFixture('ensure(p);')]
		)
			.filter(v -> v.data?.family == 'C');
		Assert.same([['W.make', 'W.prepare', 'W.ensure', 'FileSystem.createDirectory']], [for (v in found) v.data?.chain]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A sink a field initializer runs, directly or in a lambda it holds, is the initializer's (`Type.<init>`). */
	@:pin('control') @:killer('M-TS-DATA-INIT-LAMBDA')
	public function testInitializerFindingsNameTheInitializer(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}', [
			'class A { final direct:Void = Sys.sleep(1); final later:() -> Void = () -> Sys.sleep(2); public function new() {} }'
		]);
		final members: Array<Null<String>> = [for (v in found) v.data?.member];
		members.sort(Reflect.compare);
		Assert.same(['A.<init>', 'A.<init>'], members);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Only the family findings carry data: a malformed option is the run's, not a finding's. */
	public function testMalformedOptionCarriesNoData(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"lockPairs":["Mutex"]}}}', ['class A { function boot():Void Sys.sleep(1); }']
		);
		Assert.same([true, false], [for (v in found) v.data != null]);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
