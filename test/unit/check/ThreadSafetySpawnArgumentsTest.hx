package unit.check;

import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * A `spawns` entry written as an object (`{"call": "FileIO.readAndProcess", "main": [2]}`) runs the function values
 * handed to the call on another thread, as a plain entry does, but those at the argument positions `main` lists, which
 * it runs on the main thread later, as a `marshals` call does: TM's `FileIO.readAndProcess(path, process, onDone)` runs
 * `process` on the I/O worker and `onDone` on the main thread. A position counts only where the call is proven to bind
 * that parameter; anywhere else the value runs as the plain entry says (N49).
 */
class ThreadSafetySpawnArgumentsTest extends Test {

	/** The call under test: `process` on a worker, `onDone` back on the main thread. */
	private static inline final IO: String = 'class FileIO { public static function readAndProcess(path:String, process:String->String,'
		+ ' onDone:String->Void):Void {} public static function run(?tag:String, work:String->String, onDone:String->Void):Void {} }';

	/** `decode` and `done` each call the sink once. */
	private static inline final MEMBERS: String = 'static function decode(s:String):String { FileSystem.stat(s); return s; }'
		+ ' static function done(s:String):Void FileSystem.stat(s);';

	@:pin('control') @:killer('M-TS-SPAWN-MAIN-ARG') @:killer('M-TS-SPAWN-MAIN-CONTEXT') @:killer('M-TS-SPAWN-ARG-POSITION')
	public function testAMainArgumentRunsOnTheMainThread(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning A A.done | FileSystem.stat'],
			ThreadSafetyRegistersTest.graded(run(
				'{"call":"FileIO.readAndProcess","main":[2]}',
				'public static function main():Void FileIO.readAndProcess("p", decode, done);'
			))
		);
		// no `MEMBERS` beside the lambdas: a member nothing references is assumed main and would warn on its own
		Assert.same(
			['warning A A.main | FileSystem.stat'],
			ThreadSafetyRegistersTest.graded(ThreadSafetyCheckTest.violations(config('{"call":"FileIO.readAndProcess","main":[2]}'), [
				IO,
				'class A { public static function main():Void'
				+ ' FileIO.readAndProcess("p", s -> { FileSystem.stat(s); s; }, s -> FileSystem.stat(s)); }'
			])),
			'lambdas'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The plain entry it refines runs every function argument on a worker. */
	public function testAPlainEntryRunsEveryArgumentOnAWorker(): Void {
		#if (sys || nodejs)
		Assert.same(
			[],
			ThreadSafetyRegistersTest.graded(
				run('"FileIO.readAndProcess"', 'public static function main():Void FileIO.readAndProcess("p", decode, done);')
			)
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `run(?tag, work, onDone)` called with two arguments: the language may skip `tag`, so the argument written second
	 * may bind `onDone` — the position proves nothing, and the value runs on a worker as the plain entry says.
	 */
	@:pin('control') @:killer('M-TS-SPAWN-MAIN-SHIFT')
	public function testAPositionAnOptionalMayShiftRunsAsThePlainEntry(): Void {
		#if (sys || nodejs)
		Assert.same(
			[],
			ThreadSafetyRegistersTest.graded(
				run('{"call":"FileIO.run","main":[1]}', 'public static function main():Void FileIO.run(decode, done);')
			)
		);
		Assert.same(
			['warning A A.decode | FileSystem.stat'],
			ThreadSafetyRegistersTest.graded(
				run('{"call":"FileIO.run","main":[1]}', 'public static function main():Void FileIO.run("t", decode, done);')
			),
			'every argument written'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A call two signatures may answer (`@:overload`) proves no position: the value runs as the plain entry says. */
	@:pin('control') @:killer('M-TS-SPAWN-MAIN-SIGNATURE')
	public function testAnOverloadedCallRunsAsThePlainEntry(): Void {
		#if (sys || nodejs)
		Assert.same([], ThreadSafetyRegistersTest.graded(ThreadSafetyCheckTest.violations(config('{"call":"Io.load","main":[2]}'), [
			'class Io { @:overload(function(a:String, b:String->Void, c:String->String):Void {})'
			+ ' public static function load(path:String, process:String->String, onDone:String->Void):Void {} }',
			'class A { $MEMBERS public static function main():Void Io.load("p", decode, done); }'
		])));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A value run on the main thread at a `main` position runs once per post, as a `marshals` call's value does: a
	 * worker's loop of 1000 reads runs the short sink in `done` 1000 times on the main thread.
	 */
	@:pin('control') @:killer('M-TS-SPAWN-MAIN-REPEAT')
	public function testAMainArgumentRepeatsPerPost(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A A.done | FileSystem.stat', 'warning A A.main | for (i in 0...1000)'],
			ThreadSafetyRegistersTest.graded(ThreadSafetyCheckTest.violations(
				config('"Runner.create",{"call":"FileIO.readAndProcess","main":[2]}', '"shortSinks":["FileSystem.stat"],'), [
					IO,
					'class Runner { public static function create(fn:()->Void):Void {} }',
					'class A { $MEMBERS public static function main():Void'
					+ ' Runner.create(() -> { for (i in 0...1000) FileIO.readAndProcess("p", decode, done); }); }'
				]
			))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * An object entry the read cannot keep whole is said: one naming its call stays a plain entry — what the call meant
	 * before the form existed — and one naming none is dropped.
	 */
	@:pin('control') @:killer('M-TS-OPT-SPAWN-OBJECT')
	public function testAMalformedObjectEntryIsSaid(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(
			'{"call":"FileIO.readAndProcess","main":["2"]},{"main":[1]},{"call":"FileIO.run","main":[1.5],"why":"x"},7',
			'public static function main():Void FileIO.readAndProcess("p", decode, done);'
		);
		final said: Array<String> = [for (v in found) if (v.file == '') v.message];
		said.sort(Reflect.compare);
		Assert.same([
			'option "spawns" ignored 1 value(s) that are not strings or objects',
			'spawns[0] "FileIO.readAndProcess": "main" is not an array of argument positions — kept as a plain entry',
			'spawns[1] dropped: it names no "call"',
			'spawns[2] "FileIO.run": "main" is not an array of argument positions, unknown key "why" — kept as a plain entry'
		], said);
		Assert.same([], ThreadSafetyRegistersTest.graded(found), 'kept plain: every argument on a worker');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A well-formed object entry, its `evidence` read by people only, says nothing. */
	public function testAWellFormedObjectEntrySaysNothing(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = run(
			'"FileIO.run",{"call":"FileIO.readAndProcess","main":[2],"evidence":"onDone is posted to the main thread"}',
			'public static function main():Void FileIO.readAndProcess("p", decode, done);'
		);
		Assert.same([], [for (v in found) if (v.file == '') v.message]);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A run of `A` (with `MEMBERS` and `members`) beside `IO` under the `spawns` items `spawns`. */
	private static function run(spawns: String, members: String): Array<Violation> {
		return ThreadSafetyCheckTest.violations(config(spawns), [IO, 'class A { $MEMBERS $members }']);
	}

	/** A config whose one sink is `FileSystem.stat`, with the `spawns` items `spawns` and the options `extra` before them. */
	private static function config(spawns: String, extra: String = ''): String {
		return '{"rules":{"thread-safety":{"sinks":["FileSystem.stat"],$extra"spawns":[$spawns]}}}';
	}
	#end

}
