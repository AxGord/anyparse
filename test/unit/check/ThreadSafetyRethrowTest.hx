package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A `catch` that throws its own variable again lets what its `try` raised go on (`ThrowReach`): the function raises,
 * and a lock its caller holds across it is left held by that throw (finding (c)). Any other `catch` keeps the exception.
 */
class ThreadSafetyRethrowTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Disk.make"],'
		+ '"throwers":["Disk.make"],"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"]}}}';

	/** The probe of the brief (`recall/probe-rethrow`): TM's `FolderWatcher.update`, `catch (e) { release; throw e; }`. */
	@:pin('control') @:killer('M-TS-RETHROW-OFF')
	public function testACatchThatRethrowsRaises(): Void {
		#if (sys || nodejs)
		Assert.same(['W.holdsAcross'], leaks(run('catch (exception:Dynamic) { inner.release(); throw exception; }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A `catch` throwing something else, or nothing, keeps the exception the `try` raised. */
	@:pin('control') @:killer('M-TS-RETHROW-ANY-NAME')
	public function testACatchThrowingAnotherValueKeepsIt(): Void {
		#if (sys || nodejs)
		Assert.same([], leaks(run('catch (exception:Dynamic) { inner.release(); throw other; }')), 'another value');
		Assert.same([], leaks(run('catch (exception:Dynamic) { inner.release(); }')), 'nothing');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A rethrow inside a function the `catch` only builds runs later, if ever, and raises nothing there. */
	@:pin('control') @:killer('M-TS-RETHROW-NESTED')
	public function testARethrowInANestedFunctionKeepsIt(): Void {
		#if (sys || nodejs)
		Assert.same([], leaks(run('catch (exception:Dynamic) { inner.release(); later(() -> throw exception); }')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A project function named in `throwers` raises for its callers, whatever its body shows (TM's `badNamesHandler`). */
	public function testAProjectFunctionNamedInThrowersRaises(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(
			StringTools.replace(CONFIG, '"throwers":["Disk.make"]', '"throwers":["Disk.make","W.guard"]'),
			sources('catch (exception:Dynamic) { inner.release(); }', 'guard();')
		);
		Assert.same(['W.holdsAcross'], leaks(found));
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `W.rethrows` takes `inner` around a `try` of `Disk.make` closed by `clause`; `holdsAcross` holds `outer` across it. */
	private static function sources(clause: String, ?extra: String): Array<String> {
		return [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class Disk { public static function make():Void {} }',
			'class W { final outer:Mutex = new Mutex(); final inner:Mutex = new Mutex(); final other:Dynamic = null; public function new() {}'
				+ ' function later(fn:()->Void):Void {} function guard():Void {}'
				+ ' public function rethrows():Void { inner.acquire(); try { Disk.make(); } $clause inner.release(); }'
				+ ' public function holdsAcross():Void { outer.acquire(); rethrows(); ${extra ?? ''} outer.release(); }'
				+ ' public static function main():Void { final w:W = new W(); Runner.create(() -> w.holdsAcross()); w.outer.acquire(); w.outer.release(); } }'
		];
	}

	private static inline function run(clause: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, sources(clause));
	}

	/** The members of the findings (c) of `found` on `W.outer`. */
	private static function leaks(found: Array<Violation>): Array<String> {
		return [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'C' && data.subject == 'W.outer') data.member;
			}
		];
	}
	#end

}
