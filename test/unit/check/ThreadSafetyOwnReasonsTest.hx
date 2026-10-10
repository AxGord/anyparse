package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * A lock long on its own, without a blocking call in sight: a hold spanning an unresolved call — brief when a bare
 * `shortSinks` name names it and it runs once under the hold, or when only a `catch` runs it — and a hold its function
 * hands off, never giving the lock back, which is long whatever its window spans.
 */
class ThreadSafetyOwnReasonsTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"shortSinks":["trace"],"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';

	/**
	 * TM's `SerFile._mutex`: its only reason to be long was a `trace` under the hold — TM routes `trace` to its log
	 * writer, and the call resolves to nothing. A bare `shortSinks` name run once under the hold is brief.
	 */
	@:pin('control') @:killer('M-TS-BLIND-BRIEF-OFF') @:killer('M-TS-DOM-BRIEF-NAMES-IGNORED')
	public function testABriefUnresolvedCallOnceLeavesTheLockShort(): Void {
		#if (sys || nodejs)
		Assert.same(['info A S.ui | Mutex.acquire'], takes(run('trace("x");')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The same call in a loop under the hold, or a call no `shortSinks` name names, keeps the lock long. */
	@:pin('control') @:killer('M-TS-DOM-BRIEF-REPEATED')
	public function testARepeatedOrUnknownUnresolvedCallKeepsTheLockLong(): Void {
		#if (sys || nodejs)
		Assert.same(['warning A S.ui | Mutex.acquire'], takes(run('for (i in 0...3) trace("x");')), 'repeated');
		Assert.same(['warning A S.ui | Mutex.acquire'], takes(run('final d:Dynamic = null; d.poke();')), 'unknown');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An unresolved call only a `catch` runs makes the lock long only on an error path. */
	@:pin('control') @:killer('M-TS-BLIND-CATCH-OFF')
	public function testAnUnresolvedCallInACatchIsAnErrorPath(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run('try { step(); } catch (e:Dynamic) { final d:Dynamic = null; d.poke(); }');
		Assert.same(['info A S.ui | Mutex.acquire'], takes(found));
		Assert.isTrue(found.exists(v -> v.message.indexOf('only on an error path (catch at ') >= 0), 'names the catch');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * TM's `FolderWatcher.reset`: it takes the tree lock and never gives it back — the next `update()` does — so the hold
	 * lasts past its end, however brief the calls its own window spans. (The second lock keeps it from being a lock
	 * wrapper, whose take is its caller's hold.)
	 */
	@:pin('control') @:killer('M-TS-HANDOFF-OFF') @:killer('M-TS-HANDOFF-GIVES')
	public function testAHoldItsFunctionNeverGivesBackIsLong(): Void {
		#if (sys || nodejs)
		final handed: Array<Violation> = run(
			'', 'public function reset():Void { _o.acquire(); _m.acquire(); _o.release(); step(); }', 'Runner.create(() -> s.reset());'
		);
		Assert.same(['warning B S.reset | S._m'], holds(handed));
		Assert.isTrue(handed.exists(v -> v.message.indexOf('no path of the function gives it back') >= 0), 'says why');
		Assert.same(
			[],
			holds(run(
				'', 'public function reset(c:Bool):Void { _m.acquire(); if (c) return; step(); _m.release(); }',
				'Runner.create(() -> s.reset(Math.random() > 0.5));'
			)),
			'given back on a path'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A function whose window spans a call into a function that releases the lock without taking it gives it back. */
	@:pin('control') @:killer('M-TS-HANDOFF-CROSSING')
	public function testACallOfAReleaserGivesTheLockBack(): Void {
		#if (sys || nodejs)
		Assert.same(
			[],
			handedOff(run(
				'',
				'public function reset():Void { _o.acquire(); _m.acquire(); _o.release(); step(); finish(); }'
				+ ' function finish():Void { _o.acquire(); _m.release(); _o.release(); }',
				'Runner.create(() -> s.reset());'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * A background hold of `S._m` spanning `held`, a main-thread take of it, and `members` with `background` run on a
	 * worker beside them.
	 */
	private static function run(held: String, ?members: String, ?background: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class S { final _m:Mutex = new Mutex(); final _o:Mutex = new Mutex(); public function new() {} function step():Void {}'
			+ ' public function work():Void { _m.acquire(); $held _m.release(); } ${members ?? ''}'
			+ ' public function ui():Void { _m.acquire(); _m.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); ${background ?? ''} s.ui(); } }'
		]);
	}

	/** The findings of `found` of `family` as `<severity> <family> <member> | <subject>`, sorted. */
	private static function graded(found: Array<Violation>, family: String): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == family) '${v.severity.label()} ${data.family} ${data.member} | ${data.subject}';
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

	/** The members of the findings of `found` saying their hold is handed off. */
	private static function handedOff(found: Array<Violation>): Array<String> {
		return [
			for (v in found) if (v.data != null && v.message.indexOf('no path of the function gives it back') >= 0) v.data.member
		];
	}
	#end

}
