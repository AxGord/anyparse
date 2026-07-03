package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.ThreadSafety;
import anyparse.grammar.haxe.HaxeQueryPlugin;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * The `thread-safety` check: MAIN/BG context propagation over the call graph
 * (spawn callbacks go BG, marshal callbacks come back MAIN), finding (a) —
 * a main-context function directly calling a configured sink, finding (b) —
 * a lock held across a call that transitively reaches a sink. The rule is
 * config-driven and inert without a `thread-safety` entry in `apqlint.json`.
 */
class ThreadSafetyCheckTest extends Test {

	public function testMainDirectSinkFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}', ['class A { function boot():Void Sys.sleep(1); }']
		);
		Assert.equals(1, vs.length);
		Assert.equals('thread-safety', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('Sys.sleep') != -1);
		Assert.isTrue(vs[0].message.indexOf('A.boot') != -1);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSpawnedCallbackNotFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["Runner.create"]}}}', [
			'class A { function boot():Void Runner.create(() -> Sys.sleep(1)); }',
			'class Runner { public static function create(fn:()->Void):Void {} }',
		]);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMarshalCallbackFlaggedAgain(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> =
			violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["Runner.create"],"marshals":["Ui.marshal"]}}}', [
				'class A { function boot():Void Runner.create(() -> Ui.marshal(() -> Sys.sleep(1))); }',
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class Ui { public static function marshal(fn:()->Void):Void {} }',
			]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Sys.sleep') != -1);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testLockHeldAcrossBlockingCall(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> =
			violations('{"rules":{"thread-safety":{"sinks":["File.saveContent"],"lockPairs":["Mut.lock/unlock"]}}}', [
				'class A { private final _m:Mut; function work():Void { _m.lock(); File.saveContent(1, 2); _m.unlock(); } }',
				'class Mut { public function lock():Void {} public function unlock():Void {} }',
			]);
		final held: Array<Violation> = [for (v in vs) if (v.message.indexOf('holds') != -1) v];
		Assert.equals(1, held.length);
		Assert.isTrue(held[0].message.indexOf('Mut.lock') != -1);
		Assert.isTrue(held[0].message.indexOf('File.saveContent') != -1);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCallAfterUnlockNotFlaggedAsHeld(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> =
			violations('{"rules":{"thread-safety":{"sinks":["File.saveContent"],"lockPairs":["Mut.lock/unlock"]}}}', [
				'class A { private final _m:Mut; function work():Void { _m.lock(); _m.unlock(); File.saveContent(1, 2); } }',
				'class Mut { public function lock():Void {} public function unlock():Void {} }',
			]);
		Assert.equals(0, [for (v in vs) if (v.message.indexOf('holds') != -1) v].length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testInertWithoutConfig(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{}', ['class A { function boot():Void Sys.sleep(1); }']);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('thread-safety'));
	}

	public function testSkipParseNoCrash(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}', ['class A { function broken( { ']);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function violations(config: String, sources: Array<String>): Array<Violation> {
		final dir: String = CliFixture.writeDir('threadsafety', [{ name: 'apqlint.json', source: config }]);
		final files: Array<{ file: String, source: String }> = [
			for (i in 0...sources.length) { file: '$dir/F$i.hx', source: sources[i] }
		];
		final result: Array<Violation> = new ThreadSafety().run(files, new HaxeQueryPlugin());
		if (FileSystem.exists('$dir/apqlint.json')) FileSystem.deleteFile('$dir/apqlint.json');
		if (FileSystem.exists(dir)) FileSystem.deleteDirectory(dir);
		return result;
	}
	#end

	public function testNestedSameTypeLockReacquireFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Mut.lock"],"lockPairs":["Mut.lock/unlock"]}}}', [
			'class A { private final _a:Mut; private final _b:Mut; function w():Void { _a.lock(); _b.lock(); _a.unlock(); _b.unlock(); } }',
			'class Mut { public function lock():Void {} public function unlock():Void {} }',
		]);
		Assert.equals(1, [for (v in vs) if (v.message.indexOf('holds') != -1) v].length);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
