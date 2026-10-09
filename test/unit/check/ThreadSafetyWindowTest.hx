package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * The window of a hold walks a local declaration's initializer and an array literal's elements in place, and takes a
 * `break` / `continue` for a jump inside its loop: none of them is a path out of the function, so none leaves the lock
 * held — which would make it long, and every main-thread take of it a warning (TM's `StandardFileSystem.getXML`, whose
 * `final xml = try … catch` releases before it rethrows; `listFolder`'s comprehension).
 */
class ThreadSafetyWindowTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';

	@:pin('control') @:killer('M-TS-WIN-DECL')
	public function testATryInADeclarationReleasingBeforeItRethrowsLeavesNothingHeld(): Void {
		#if (sys || nodejs)
		Assert.same([], takes(run('final v:Int = try { f(); } catch (e:Dynamic) { _m.release(); throw e; };')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-WIN-JUMP')
	public function testAContinueStaysInTheLoop(): Void {
		#if (sys || nodejs)
		Assert.same([], takes(run('for (i in 0...3) { if (i == 1) continue; f(); }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-WIN-ARRAY') @:killer('M-TS-WIN-FOREXPR')
	public function testAComprehensionIsWalkedAsALoop(): Void {
		#if (sys || nodejs)
		Assert.same([], takes(run('final xs:Array<Int> = [for (i in 0...3) { if (i == 1) continue; f(); }];')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-WIN-CAUGHT-THROW')
	public function testAThrowACatchInterceptsStaysInTheFunction(): Void {
		#if (sys || nodejs)
		Assert.same([], takes(run('try { if (f() == 2) throw "x"; } catch (e:Dynamic) { _m.release(); throw e; }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAReturnUnderTheLockStillLeaks(): Void {
		#if (sys || nodejs)
		Assert.same(['M.main'], takes(run('for (i in 0...3) { if (i == 1) return; f(); }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `W.work` takes `_m`, runs `body`, releases; the worker runs it while the main thread takes `_m`. */
	private static function run(body: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class W { public final _m:Mutex = new Mutex(); public function new() {} function f():Int return 1;'
			+ ' public function work():Void { _m.acquire(); $body _m.release(); } }',
			'class M { public static function main():Void { final w:W = new W(); Runner.create(() -> w.work()); w._m.acquire(); w._m.release(); } }'
		]);
	}

	/** The members whose main-thread take of a lock warns (finding (a) of `Mutex.acquire`). */
	private static function takes(found: Array<Violation>): Array<String> {
		return [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'A' && data.subject == 'Mutex.acquire' && v.severity.label() == 'warning') data.member;
			}
		];
	}
	#end

}
