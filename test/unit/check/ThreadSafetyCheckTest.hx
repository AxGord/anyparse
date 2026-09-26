package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.ThreadSafety;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * The `thread-safety` check: MAIN/BG context propagation over the call graph
 * (spawn callbacks go BG, marshal callbacks come back MAIN), finding (a) —
 * a main-context function directly calling a configured sink, finding (b) —
 * a lock held across a call that transitively reaches a sink. The rule is
 * config-driven and inert without a `thread-safety` entry in `apqlint.json`.
 */
class ThreadSafetyCheckTest extends Test {

	#if (sys || nodejs)
	private static final MUTEX: String =
		'class Mutex { public function new() {} public function acquire():Void {} public function release():Void {} }\n';
	#end

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
			'class Runner { public static function create(fn:()->Void):Void {} }'
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
				'class Ui { public static function marshal(fn:()->Void):Void {} }'
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
				'class Mut { public function lock():Void {} public function unlock():Void {} }'
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
				'class Mut { public function lock():Void {} public function unlock():Void {} }'
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

	public function testNestedSameTypeLockReacquireFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Mut.lock"],"lockPairs":["Mut.lock/unlock"]}}}', [
			'class A { private final _a:Mut; private final _b:Mut; function w():Void { _a.lock(); _b.lock(); _a.unlock(); _b.unlock(); } }',
			'class Mut { public function lock():Void {} public function unlock():Void {} }'
		]);
		Assert.equals(1, [for (v in vs) if (v.message.indexOf('holds') != -1) v].length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-TS-ACCESSOR-TAINT')
	public function testLockHeldAcrossABlockingGetterFlagged(): Void {
		// Reading `_p.v` runs `get_v`, and that getter sleeps: the property read is a call like any other.
		#if (sys || nodejs)
		final vs: Array<Violation> =
			violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep","Mut.lock"],"lockPairs":["Mut.lock/unlock"]}}}', [
				'class A { private final _m:Mut; private final _p:P; function w():Void { _m.lock(); trace(_p.v); _m.unlock(); } }',
				'class P { public var v(get, never):Int; function get_v():Int { Sys.sleep(1); return 1; } }',
				'class Mut { public function lock():Void {} public function unlock():Void {} }'
			]);
		Assert.equals(1, [
			for (v in vs) if (v.message.indexOf('holds') != -1 && v.message.indexOf('P.get_v') != -1) v
		].length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTernarySpawnCallbackNotFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["Runner.create"]}}}', [
			'class A { var flag:Bool; function boot():Void Runner.create(flag ? work1 : work2); function work1():Void Sys.sleep(1); '
			+ 'function work2():Void Sys.sleep(1); }',
			'class Runner { public static function create(fn:()->Void):Void {} }'
		]);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMarshalBodySinkNotFlagged(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations('{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"marshals":["Ui.marshal"]}}}', [
			'class A { function boot():Void Ui.marshal(doWork); function doWork():Void {} }',
			'class Ui { public static function marshal(fn:()->Void):Void { Sys.sleep(0.01); } }'
		]);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testExcludedPathNotScanned(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"exclude":["F0.hx"]}}}', ['class A { function boot():Void Sys.sleep(1); }']
		);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testNonMatchingExcludeStillScanned(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"],"exclude":["elsewhere"]}}}',
			['class A { function boot():Void Sys.sleep(1); }']
		);
		Assert.equals(1, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testMacroFunctionBodyNotRuntime(): Void {
		#if (sys || nodejs)
		final vs: Array<Violation> = violations(
			'{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}', ['class A { macro public static function gen():Void Sys.sleep(1); }']
		);
		Assert.equals(0, vs.length);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Two config chains naming different sinks, one graph: each call site is judged by the chain of its own
	 * file, whichever file the run lists first, and the main-thread chain still crosses from one chain into the other.
	 */
	@:pin('control') @:killer('M-TS-FIRST-FILE-LISTS')
	public function testEachCallSiteJudgedByItsOwnChain(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'apqlint.json', source: '{"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}' },
			{ name: 'a/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Gate.block"]}}}' },
			{ name: 'a/A.hx', source: 'class A { static function main():Void { Sys.sleep(1); Gate.block(); B.f(); } }' },
			{ name: 'a/Gate.hx', source: 'class Gate { public static function block():Void {} }' },
			{ name: 'b/B.hx', source: 'class B { public static function f():Void { Sys.sleep(2); Gate.block(); } }' }
		];
		for (order in [['a/A.hx', 'a/Gate.hx', 'b/B.hx'], ['b/B.hx', 'a/Gate.hx', 'a/A.hx']]) Assert.same([
			'a/A.hx: main thread reaches blocking "Gate.block": A.main -> Gate.block',
			'b/B.hx: main thread reaches blocking "Sys.sleep": A.main -> B.f -> Sys.sleep'
		], chainFindings(tree, order));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A node one chain names a sink is a plain function in a chain that does not: there it is tainted by the sink it
	 * calls, so a lock held across a call to it is reported, whichever file the run lists first.
	 */
	@:pin('control') @:killer('M-TS-TAINT-UNION-SINK')
	public function testASinkOfOneChainIsAPlainCallInAnother(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'x/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["A.n"]}}}' },
			{
				name: 'y/apqlint.json',
				source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Sys.sleep"],"lockPairs":["Mutex.acquire/release"]}}}'
			},
			{ name: 'x/X.hx', source: 'class X { static function main():Void { A.n(); } }' },
			{ name: 'y/A.hx', source: 'class A { public static function n():Void { Sys.sleep(1); } }' },
			{
				name: 'y/B.hx',
				source: MUTEX
					+ 'class B { static var m:Mutex = new Mutex(); public static function f():Void { m.acquire(); A.n(); m.release(); } }'
			}
		];
		for (order in [['x/X.hx', 'y/A.hx', 'y/B.hx'], ['y/A.hx', 'y/B.hx', 'x/X.hx']])
			Assert.contains(
				'y/B.hx: "B.f" holds "Mutex.acquire" across a call that can block: A.n -> Sys.sleep', chainFindings(tree, order)
			);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A file whose chain names no sinks reports nothing but stays in the graph: its `spawns` registration still sends
	 * the callback to a background thread, so the sink call inside it is not a main-thread finding.
	 */
	@:pin('control') @:killer('M-TS-GRAPH-CUT')
	public function testAFileWithoutSinksStillShapesTheGraph(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'x/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Sys.sleep"],"spawns":["W.run"]}}}' },
			{ name: 'y/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"spawns":["W.run"]}}}' },
			{
				name: 'x/X.hx',
				source: 'class W { public static function run(f:()->Void):Void {} } class X { public static function work():Void {'
					+ ' Sys.sleep(1); } }'
			},
			{ name: 'y/Reg.hx', source: 'class Reg { static function main():Void { W.run(X.work); } }' }
		];
		for (order in [['x/X.hx', 'y/Reg.hx'], ['y/Reg.hx', 'x/X.hx']]) Assert.same([], chainFindings(tree, order));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A file whose chain names no sinks is scanned for the graph and never reported in — `skipReason` is the report gate. */
	@:pin('control') @:killer('M-TS-REPORT-UNGATED')
	public function testNoFindingInAFileWhoseChainNamesNoSinks(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'x/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Sys.sleep"]}}}' },
			{ name: 'y/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"lockPairs":["Mutex.acquire/release"]}}}' },
			{ name: 'x/X.hx', source: 'class X { public static function work():Void { Sys.sleep(1); } }' },
			{
				name: 'y/Y.hx',
				source: '${MUTEX}class Y { static var m:Mutex = new Mutex(); public static function f():Void {'
					+ ' m.acquire(); X.work(); m.release(); } }'
			}
		];
		for (order in [['x/X.hx', 'y/Y.hx'], ['y/Y.hx', 'x/X.hx']])
			Assert.same(['x/X.hx: main thread reaches blocking "Sys.sleep": Y.f -> X.work -> Sys.sleep'], chainFindings(tree, order));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A malformed `lockPairs` entry of a chain that names no sinks is not reported: that chain reports nothing at all. */
	@:pin('control') @:killer('M-TS-MALFORMED-UNGATED')
	public function testAMalformedOptionOfANonReportingChainIsSilent(): Void {
		#if (sys || nodejs)
		final tree: Array<{ name: String, source: String }> = [
			{ name: 'x/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"sinks":["Sys.sleep"],"lockPairs":["bad2"]}}}' },
			{ name: 'y/apqlint.json', source: '{"inherit":false,"rules":{"thread-safety":{"lockPairs":["bad"]}}}' },
			{ name: 'x/X.hx', source: 'class X { public static function work():Void { Sys.sleep(1); } }' },
			{ name: 'y/Y.hx', source: 'class Y { static function main():Void { X.work(); } }' }
		];
		for (order in [['x/X.hx', 'y/Y.hx'], ['y/Y.hx', 'x/X.hx']])
			Assert.same(
				[': malformed lockPairs entry "bad2" — expected "<lock pattern>/<unlock member>"'],
				chainFindings(tree, order).filter(f -> f.indexOf('malformed') != -1)
			);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** Every finding over `tree` with the run's files listed in `order`, as sorted `<relative path>: <message>` lines. */
	private function chainFindings(tree: Array<{ name: String, source: String }>, order: Array<String>): Array<String> {
		final root: String = CliFixture.writeTree('threadsafetychains', tree);
		final files: Array<{ file: String, source: String }> = [
			for (name in order) { file: '$root/$name', source: tree.find(t -> t.name == name)?.source ?? '' }
		];
		final vs: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), [new ThreadSafety()]);
		final found: Array<String> = [for (v in vs) '${v.file.substring(root.length + 1)}: ${v.message}'];
		found.sort(Reflect.compare);
		CliFixture.removeDir(root);
		return found;
	}

	private function violations(config: String, sources: Array<String>): Array<Violation> {
		final dir: String = CliFixture.writeDir('threadsafety', [{ name: 'apqlint.json', source: config }]);
		final files: Array<{ file: String, source: String }> = [
			for (i in 0...sources.length) { file: '$dir/F$i.hx', source: sources[i] }
		];
		// Through `Linter.run`, not `run`: the `sinks` / `exclude` gate is `FileGated`, applied where findings enter the tool.
		final result: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), [new ThreadSafety()]);
		CliFixture.removeDir(dir);
		return result;
	}
	#end

}
