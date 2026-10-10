package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.check.PositiveSinks;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * The sinks are POSITIVE: the runtime library's blocking calls (`ExecutionShape.blockingLibraryCalls`) and the project's
 * own natives (`ProjectNatives`) block wherever the rule runs, `sinks` adds to them and `nonBlocking` waives one only on
 * evidence. Before, a blocking call a project forgot to list was silently invisible — TM lacked `FileSystem.exists`,
 * `isDirectory`, `nativeSetTimestamp` and `Sys.command` until they were added by hand.
 */
class ThreadSafetyPositiveSinksTest extends Test {

	/** Natives of every shape `ProjectNatives` reads, each called from a root of its own, and an interface call that is none. */
	private static final NATIVES: Array<String> = [
		'@:native("std::mutex") extern class StdM { function new(); function lock():Void; }',
		'interface I { function f():Void; } class Impl implements I { public function new() {} public function f():Void {} }',
		'class N { static var prim:Dynamic = cpp.Lib.load("ext", "prim", 1);'
			+ ' static var cb:cpp.Callable<Int->Void> = cpp.Prime.load("ext", "p2", "iv", false); @:native("cfun") static function '
			+ 'cfun(x:Int):Int return 0; static function viaExtern():Void { final m:StdM = new StdM(); m.lock(); } static function '
			+ 'viaMeta():Void cfun(1); static function viaLoader():Void prim(1); static function viaCallable():Void cb.call(2); static '
			+ 'function viaCode():Void untyped __cpp__("usleep(1)"); static function viaGlobal():Void untyped __global__.thing(4); static '
			+ 'function viaSyntax():Void cpp.Syntax.code("x"); static function viaInterface():Void { final i:I = new Impl(); i.f(); } }'
	];

	/**
	 * A chain writing no `sinks` reports the runtime's blocking calls, a wait for another thread among them; a project
	 * function named like one is read through its body.
	 */
	@:pin('control') @:killer('M-TS-BUILTIN-NEEDS-SINKS') @:killer('M-TS-BUILTIN-OFF') @:killer('M-TS-BUILTIN-ANY-NODE')
	public function testTheBuiltinAppliesWithNoSinks(): Void {
		#if (sys || nodejs)
		Assert.same(
			[
				'info A A.main | Lock.wait',
				'info A A.main | Sys.sleep',
				'warning A A.main | File.getContent'
			],
			graded(ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"closedWorld":false}}}', [
				'import sys.io.File; import sys.thread.Lock;'
				+ ' class A { static function main():Void { File.getContent("x"); Sys.sleep(1); final l:Lock = new Lock(); l.wait(); } }'
			]))
		);
		Assert.same([], graded(ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"closedWorld":false}}}', [
			'class File { public static function getContent(p:String):String return p; }'
			+ ' class B { static function main():Void File.getContent("x"); }'
		])), 'a project namesake');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `sinks` adds to the builtin set; it never replaces it. */
	public function testSinksAddToTheBuiltin(): Void {
		#if (sys || nodejs)
		Assert.same(
			['info A A.main | Gate.block', 'warning A A.main | Sys.sleep'],
			graded(ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"sinks":["Gate.block"]}}}', [
				'class Gate { public static function block():Void {} } class A { static function main():Void {'
				+ ' Sys.sleep(1); Gate.block(); } }'
			]))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `nonBlocking` entry waives a builtin sink or a native on the evidence it gives; one giving none is dropped and
	 * said, one waiving nothing is said, and a call `sinks` lists stays a sink.
	 */
	@:pin('control') @:killer('M-TS-WAIVE-OFF') @:killer('M-TS-WAIVE-SAYS-NOTHING') @:killer('M-TS-WAIVE-SINKS-WIN')
	@:killer('M-TS-OPT-NONBLOCKING-EVIDENCE')
	public function testNonBlockingWaivesOnEvidence(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> =
			ThreadSafetyCheckTest.violations(
				'{"rules":{"thread-safety":{"sinks":["Sys.command"],"nonBlocking":["Sys.sleep  the fixture sleeps zero seconds",'
				+ '"File.getContent","Nope.never it is not there","Sys.command it is listed in sinks too"]}}}',
				[
					'import sys.io.File;'
					+ ' class A { static function main():Void { Sys.sleep(0); File.getContent("x"); Sys.command("ls"); } }'
				]
			);
		Assert.same(['info A A.main | Sys.command', 'warning A A.main | File.getContent'], graded(found));
		Assert.same([
			'nonBlocking entry "File.getContent" dropped: it gives no evidence — write "<pattern> <why it never blocks>"',
			'nonBlocking entry "Nope.never" waives no builtin sink or project native of the run',
			'nonBlocking entry "Sys.command" names a call "sinks" lists too, which keeps it'
		], said(found));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A function the project declares runs native code — an extern member with no body, its constructor, a `@:native`
	 * member whatever its body, a member a native loader initialised, `untyped __cpp__`, `untyped __global__.f`,
	 * `cpp.Syntax.code` — and blocks; an interface member dispatches and is none. `nonBlocking` waives one.
	 */
	@:pin('control') @:killer('M-TS-NATIVE-EXTERN') @:killer('M-TS-NATIVE-EXTERN-ANY-BODYLESS') @:killer('M-TS-NATIVE-META')
	@:killer('M-TS-NATIVE-LOADER') @:killer('M-TS-NATIVE-AFFIX') @:killer('M-TS-NATIVE-CALLEE-SPAN')
	@:killer('M-TS-NATIVE-CODE-CALLS') @:killer('M-TS-NATIVE-LOADED-MEMBER')
	public function testProjectNativesBlock(): Void {
		#if (sys || nodejs)
		final config: String = '{"rules":{"thread-safety":{"closedWorld":false}}}';
		Assert.same([
			'info A N.viaExtern | StdM.lock',
			'warning A N.viaCallable | N.cb',
			'warning A N.viaCode | untyped.__cpp__',
			'warning A N.viaExtern | StdM.new',
			'warning A N.viaGlobal | __global__.thing',
			'warning A N.viaLoader | N.prim',
			'warning A N.viaMeta | N.cfun',
			'warning A N.viaSyntax | Syntax.code'
		], graded(ThreadSafetyCheckTest.violations(config, NATIVES)));
		final waived: String =
			'{"rules":{"thread-safety":{"nonBlocking":["untyped.__cpp__ a fixture usleep","N.cfun returns a status and never waits"]}}}';
		final kept: Array<String> = graded(ThreadSafetyCheckTest.violations(waived, NATIVES));
		Assert.isFalse(kept.exists(g -> g.indexOf('untyped.__cpp__') >= 0 || g.indexOf('N.cfun') >= 0), 'waived');
		Assert.isTrue(kept.contains('warning A N.viaGlobal | __global__.thing'), 'the rest stays');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A reporting run says once which builtin sinks applied: how many the runtime has, how many it calls, and its natives. */
	@:pin('control') @:killer('M-TS-BUILTIN-NOTICE-OFF')
	public function testTheRunSaysWhichBuiltinsApplied(): Void {
		#if (sys || nodejs)
		final found: Array<Violation> = ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"closedWorld":false}}}', [
			'import sys.io.File; class A { static function main():Void { File.getContent("x"); Sys.sleep(1); untyped __cpp__("x"); } }'
		], null, true);
		Assert.same(
			[
				'builtin sinks applied: 57 blocking calls of the runtime library (2 of them called in this run) and 1 project native(s)'
				+ ' — "sinks" adds to them, "nonBlocking" removes from them'
			],
			[
				for (v in found) if (v.file == '' && StringTools.startsWith(v.message, PositiveSinks.NOTICE)) v.message
			]
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
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

	/** The config lines of `found`, sorted. */
	private static function said(found: Array<Violation>): Array<String> {
		final out: Array<String> = [for (v in found) if (v.file == '') v.message];
		out.sort(Reflect.compare);
		return out;
	}
	#end

}
