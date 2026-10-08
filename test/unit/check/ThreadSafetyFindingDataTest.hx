package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

using Lambda;

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

	/** A dispatch reaching several sinks names them all, sorted, whatever order the graph found them in. */
	@:pin('control') @:killer('M-TS-DATA-SINKS-UNSORTED')
	public function testSeveralSinksAreOneSortedSubject(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"sinks":["Zed.m","Ann.m"]}}}', [
			'interface I { function m():Void; }',
			'class Zed implements I { public function new() {} public function m():Void {} }',
			'class Ann implements I { public function new() {} public function m():Void {} }',
			'class A { final i:I = new Zed(); function boot():Void i.m(); }'
		]);
		Assert.same(['Ann.m / Zed.m'], [for (v in found) v.data?.subject]);
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
	@:pin('control') @:killer('M-TS-DATA-ORDER-PAIR-UNSORTED')
	public function testLockOrderData(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.orderFindings(ThreadSafetyCheckTest.storeFixture(
			'acquireMutation(); db.add(false); releaseMutation();', 'Runner.create(fs.download); fs.save();'
		));
		Assert.same(
			[
				{
					family: 'D',
					member: 'Fs.save',
					subject: 'Db._batch / Fs._mutation',
					chain: ['Fs.save', 'Db.add', 'Mutex.acquire']
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
