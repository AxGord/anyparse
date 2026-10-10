package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A `catch` that throws its own variable again lets what its `try` raised go on (`ThrowReach`): the function raises,
 * and a lock its caller holds across it is left held by that throw (finding (c)). So does one throwing anything
 * else — it runs only where the `try` failed — and a typed one, which lets an exception of no known type through.
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

	/**
	 * A `catch` runs only where its `try` failed, so whatever it throws is that failure going on: a wrapper of the caught
	 * value, the value in parentheses, an alias of it, another value (review r4 `R1`, `R2`, `R4`). One throwing nothing
	 * keeps it.
	 */
	@:pin('control') @:killer('M-TS-RETHROW-ANY-NAME')
	public function testACatchThrowingAnyValueRaises(): Void {
		#if (sys || nodejs)
		Assert.same(
			['W.holdsAcross'],
			leaks(run('catch (exception:Dynamic) { inner.release(); throw new haxe.Exception("w", exception); }')), 'a wrapper'
		);
		Assert.same(['W.holdsAcross'], leaks(run('catch (exception:Dynamic) { inner.release(); throw (exception); }')), 'parentheses');
		Assert.same(
			['W.holdsAcross'],
			leaks(run('catch (exception:Dynamic) { inner.release(); final x:Dynamic = exception; throw x; }')), 'an alias'
		);
		Assert.same(['W.holdsAcross'], leaks(run('catch (exception:Dynamic) { inner.release(); throw other; }')), 'another value');
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

	/**
	 * What a `throwers` call raises is of no known type: a typed `catch` lets it through (review r4 `R5`), a catch-all
	 * keeps it.
	 */
	@:pin('control') @:killer('M-TS-THROW-TYPED-INTERCEPTS') @:killer('M-TS-CATCH-ANY-TYPE')
	public function testATypedCatchLetsAThrowersExceptionThrough(): Void {
		#if (sys || nodejs)
		Assert.same(['W.holdsAcross', 'W.rethrows'], leaks(run('catch (exception:haxe.io.Eof) { inner.release(); }'), true));
		Assert.same([], leaks(run('catch (exception:haxe.Exception) { inner.release(); }'), true), 'the exception type');
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

	/** The members of the findings (c) of `found` on `W.outer` — on `W.inner` too where `inner` is set — sorted. */
	private static function leaks(found: Array<Violation>, inner: Bool = false): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'C' && (data.subject == 'W.outer' || inner && data.subject == 'W.inner')) data.member;
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
