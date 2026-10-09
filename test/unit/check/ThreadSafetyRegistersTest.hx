package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A callback handed to a `registers` call (`addEventListener`) runs later, as a run of its own, once per event however
 * often it was registered: a loop around the registration repeats nothing, nor does anything up the way to it.
 */
class ThreadSafetyRegistersTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","FileSystem.stat"],'
		+ '"shortSinks":["FileSystem.stat"],"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],'
		+ '"registers":["addEventListener"]}}}';

	private static inline final DISPATCHER: String = 'class D { public function new() {}'
		+ ' public function addEventListener(type:String, fn:String->Void):Void {} }';

	/**
	 * TM's `FileListOperations.listenContent`: one rename handler registered on every list item renames once per event,
	 * not once per item.
	 */
	@:pin('control') @:killer('M-TS-REGISTER-OWNER')
	public function testARegistrationInALoopRepeatsNothing(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A A.handler | FileSystem.stat'],
			graded(run(
				'public static function main():Void { final ds:Array<D> = [new D(), new D()]; for (d in ds) d.addEventListener("x", handler); }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Without the entry the same registration repeats its callback, and the loop warns. */
	public function testWithoutTheEntryTheLoopWarns(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A A.handler | FileSystem.stat', 'warning A A.main | A.handler'],
			graded(run(
				'public static function main():Void { final ds:Array<D> = [new D(), new D()]; for (d in ds) d.addEventListener("x", handler); }',
				StringTools.replace(CONFIG, '"addEventListener"', '"other"')
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A registering function a loop calls repeats the registration, never the callback. */
	@:pin('control') @:killer('M-TS-REGISTER-OWNER')
	public function testALoopAboveTheRegistrarRepeatsNothing(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A A.handler | FileSystem.stat'],
			graded(run(
				'static function wire():Void new D().addEventListener("x", handler);'
				+ ' public static function main():Void for (i in 0...3) wire();'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The repeating caller that owns a short call is found on the ways that run it, never up its registration. */
	@:pin('control') @:killer('M-TS-REGISTER-OWNER')
	public function testTheOwnerIsNeverUpARegistration(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A A.handler | FileSystem.stat', 'warning A A.main | A.a'],
			graded(run(
				'static function wire():Void new D().addEventListener("x", handler); static function setup():Void for (i in 0...3) wire();'
				+ ' static function b():Void handler("y"); static function a():Void b();'
				+ ' public static function main():Void { setup(); for (i in 0...3) a(); }'
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A class `A` whose `handler` calls a short sink once, with `members`, beside a dispatcher `D`. */
	private static function run(members: String, ?config: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(config ?? CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			DISPATCHER,
			'class A { static function handler(e:String):Void FileSystem.stat(e); $members }'
		]);
	}

	/** The findings of `found` with data as `<severity> <family> <member> | <subject>`, sorted. */
	private static function graded(found: Array<Violation>): Array<String> {
		final out: Array<String> = [
			for (v in found) {
				final data: Null<FindingData> = v.data;
				if (data != null) '${v.severity.label()} ${data.family} ${data.member} | ${data.subject}';
			}
		];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
