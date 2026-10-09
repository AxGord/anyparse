package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A `catch` whose `try` runs only `nonThrowing` calls is no path (`DeadCatches`): TM's
 * `FileSystemNativeExtensions.getMTime` wraps hxcpp's `FileSystem.stat` — which builds a zeroed record for a missing
 * path and never throws — in a `catch` reporting the error by a blocking request.
 */
class ThreadSafetyDeadCatchTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],"nonThrowing":["Disk.stat"]}}}';

	/** The catch behind a `nonThrowing` call never runs: the hold spans no blocking call. */
	@:pin('control') @:killer('M-TS-DEADCATCH-OFF')
	public function testACatchAroundANonThrowingCallIsNoPath(): Void {
		#if (sys || nodejs)
		Assert.same([], holds(run('Disk.stat(p).mtime')));
		Assert.same(
			['info B S.work | S._m'],
			holds(run('Disk.stat(p).mtime', StringTools.replace(CONFIG, '"nonThrowing":["Disk.stat"]', '"nonThrowing":[]'))), 'unlisted'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Any other call in the `try` may throw, and the catch is a path. */
	@:pin('control') @:killer('M-TS-DEADCATCH-ANY-CALL')
	public function testAnotherCallMakesTheCatchAPath(): Void {
		#if (sys || nodejs)
		// a path, but only an error one: info (γ1)
		Assert.same(['info B S.work | S._m'], holds(run('other()')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A field read off anything but a `nonThrowing` call's value may fault on a null. */
	@:pin('control') @:killer('M-TS-DEADCATCH-FIELD')
	public function testAFieldReadOffAValueMakesTheCatchAPath(): Void {
		#if (sys || nodejs)
		Assert.same(['info B S.work | S._m'], holds(run('last.mtime')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The `try` body itself still runs: a `nonThrowing` sink there blocks as ever. */
	@:pin('control') @:killer('M-TS-DEADCATCH-BODY')
	public function testTheTryBodyStillRuns(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B S.work | S._m'],
			holds(run('Disk.stat(p).mtime', StringTools.replace(CONFIG, '"Sys.sleep"]', '"Sys.sleep","Disk.stat"]'), true))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A string interpolating a call or a field read runs it: the `catch` around it is a path (review r4 `d1`, `d2`). */
	@:pin('control') @:killer('M-TS-DEADCATCH-INTERP')
	public function testAnInterpolatedStringRunsWhatItInterpolates(): Void {
		#if (sys || nodejs)
		Assert.same(['info B S.work | S._m'], holds(run("Disk.stat('${risky()}').mtime")), 'a call');
		Assert.same(['info B S.work | S._m'], holds(run("Disk.stat('${last.x.y}').mtime")), 'a field read');
		Assert.same([], holds(run("Disk.stat('plain').mtime")), 'no interpolation');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `nonThrowing` method called off a value runs what builds the value, which may throw or be null: the `catch` around
	 * it is a path (review r4 `d3`, `d5`). Off a type's name it is not.
	 */
	@:pin('control') @:killer('M-TS-DEADCATCH-RECEIVER')
	public function testACallOffAValueMayThrow(): Void {
		#if (sys || nodejs)
		final config: String = StringTools.replace(CONFIG, '"nonThrowing":["Disk.stat"]', '"nonThrowing":["Disk.stat","Disk.istat"]');
		Assert.same(['info B S.work | S._m'], holds(run('disk().istat(p)', config)), 'a call receiver');
		Assert.same(['info B S.work | S._m'], holds(run('d.istat(p)', config)), 'a field receiver');
		Assert.same([], holds(run('Disk.stat(p)', config)), 'a type name');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A bare name read as a property runs its getter, which may throw (review r4 `d4`); a parameter does not. */
	@:pin('control') @:killer('M-TS-DEADCATCH-PROPERTY') @:killer('M-TS-DEADCATCH-BINDING')
	public function testAPropertyReadRunsItsGetter(): Void {
		#if (sys || nodejs)
		Assert.same(['info B S.work | S._m'], holds(run('Disk.stat(p).mtime == limit')), 'a property');
		Assert.same([], holds(run('Disk.stat(p).mtime == p')), 'a parameter');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A name bound somewhere else in the function — a lambda's parameter, a local after the read — does not bind the read:
	 * it reads the property, whose getter may throw (review round 2 `dc1-prop-shadowed-elsewhere`). A local declared
	 * before it in its block does.
	 */
	@:pin('control') @:killer('M-TS-DEADCATCH-BINDING-SCOPE')
	public function testABindingElsewhereInTheFunctionDoesNotBindTheRead(): Void {
		#if (sys || nodejs)
		final read: String = 'Disk.stat(p).mtime == limit';
		Assert.same(['info B S.work | S._m'], holds(run(read, null, false, '[1].map(limit -> limit + 1);')), "a lambda's parameter");
		Assert.same([], holds(run(read, null, false, 'final limit:Int = 1;')), 'a local before the read');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `S.work` holds `_m` across `mtime()`, which runs `before`, then a `try` evaluating `value` whose `catch` sleeps (or,
	 * `quiet`, does not).
	 */
	private static function run(value: String, ?config: String, quiet: Bool = false, before: String = ''): Array<Violation> {
		final reported: String = quiet ? 'null;' : 'Sys.sleep(1); null;';
		return ThreadSafetyCheckTest.violations(config ?? CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			'class Disk { public function new() {} public static function stat(p:String):Dynamic return null;'
			+ ' public function istat(p:String):Dynamic return null; }',
			'class S { final _m:Mutex = new Mutex(); var last:Dynamic = null; var d:Disk = null; public function new() {} function other():Void {}'
			+ ' function risky():String { throw "boom"; } function disk():Disk { throw "boom"; }'
			+ ' var limit(get, never):Int; function get_limit():Int { throw "boom"; }'
			+ ' function mtime(p:String):Dynamic { $before return try { $value; } catch (e:Dynamic) { $reported }; }'
			+ ' public function work():Void { _m.acquire(); mtime("x"); _m.release(); }'
			+ ' public static function main():Void { final s:S = new S(); Runner.create(() -> s.work()); s._m.acquire(); s._m.release(); } }'
		]);
	}

	private static function holds(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null && data.family == 'B') '${v.severity.label()} B ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
