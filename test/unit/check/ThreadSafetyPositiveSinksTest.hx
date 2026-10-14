package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.check.PositiveSinks;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.StdResolver;
import anyparse.query.StdTypes;
import unit.cli.CliFixture;
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
		// a project type declared AT the library path (a classpath override) is the project's: its body is read
		Assert.same([], graded(ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"closedWorld":false}}}', [
			'package sys.io; class File { public static function getContent(p:String):String return p; }',
			'class B { static function main():Void sys.io.File.getContent("x"); }'
		])), 'a project override of the library path');
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
				'builtin sinks applied: 63 blocking calls of the runtime library (2 of them called in this run) and 1 project native(s)'
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

	/**
	 * A library type written with its package, imported, or reached through a member or a return type written with one,
	 * is not the project's type of its simple name: a call of `sys.thread.Lock.wait` is the runtime's wait whatever project
	 * native shares the name `Lock` (keyed by its path), and a waiver of that native keeps it — the library call may still
	 * reach it where nothing says which `Lock` a value holds.
	 */
	@:pin('control') @:killer('M-TS-PATH-FOREIGN') @:killer('M-TS-PATH-IMPORT') @:killer('M-TS-PATH-RECEIVER-STATIC')
	@:killer('M-TS-PATH-NEW') @:killer('M-TS-PATH-MATCH') @:killer('M-TS-SHADOWING-KEPT') @:killer('M-TS-PATH-DECLARED-PACKAGE')
	@:killer('M-TS-PATH-NOMINAL') @:killer('M-TS-PATH-RETURN') @:killer('M-TS-PATH-NULLABLE-KEYED') @:killer('M-TS-ALIAS-TYPE')
	public function testALibraryTypeIsNotItsProjectNamesake(): Void {
		#if (sys || nodejs)
		final native: String = 'package utils; extern class Lock { public function new():Void; public function wait():Bool; }'
			+ ' class File { public static function getContent(p:String):String return p; }';
		final app: String = 'package app; import sys.thread.Mutex as M;'
			+ ' class Holder { public static var lock:sys.thread.Lock; static function make():sys.thread.Lock return null; }'
			+ ' class A { static function written(l:sys.thread.Lock):Void l.wait(); static function made():Void { final l = new'
			+ ' sys.thread.Lock(); l.wait(); } static function own(l:utils.Lock):Void l.wait(); static function aliased(m:M):Void'
			+ ' m.acquire(); static function staticPath():Void sys.io.File.getContent("x"); static function field():Void'
			+ ' Holder.lock.wait(); static function returned():Void @:privateAccess Holder.make().wait(); static function'
			+ ' nullable(m:Null<sys.thread.Mutex>):Void m.acquire(); static function main():Void { written(null); made(); own(null);'
			+ ' aliased(null); staticPath(); field(); returned(); nullable(null); } }';
		final config: String = '{"rules":{"thread-safety":{"closedWorld":false}}}';
		Assert.same([
			'warning A A.aliased | Mutex.acquire',
			'warning A A.field | sys.thread.Lock.wait',
			'warning A A.made | sys.thread.Lock.wait',
			'warning A A.nullable | Mutex.acquire',
			'warning A A.own | Lock.wait',
			'warning A A.returned | sys.thread.Lock.wait',
			'warning A A.staticPath | sys.io.File.getContent',
			'warning A A.written | sys.thread.Lock.wait'
		], graded(ThreadSafetyCheckTest.violations(config, [native, app])));
		final imported: String =
			'package app; import sys.thread.Lock; class B { static function main():Void { final l:Lock = null; l.wait(); } }';
		Assert.same(['warning A B.main | sys.thread.Lock.wait'], graded(ThreadSafetyCheckTest.violations(config, [native, imported])));
		// a project type at the path the import names stays the project's
		final declared: String =
			'package app; import utils.Lock; class B { static function main():Void { final l:Lock = null; l.wait(); } }';
		Assert.same(['warning A B.main | Lock.wait'], graded(ThreadSafetyCheckTest.violations(config, [native, declared])));
		final waiving: String =
			'{"rules":{"thread-safety":{"closedWorld":false,"nonBlocking":["utils.Lock.wait our try-lock never waits"]}}}';
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(waiving, [native, app]);
		Assert.isTrue(graded(found).contains('warning A A.own | Lock.wait'), 'the native named like a library call is kept');
		Assert.isTrue(graded(found).contains('warning A A.written | sys.thread.Lock.wait'), 'the library call is never waived with it');
		// a pattern naming the type by its simple name names the library type keyed by its path too
		final bySimpleName: Array<String> = graded(ThreadSafetyCheckTest.violations(
			'{"rules":{"thread-safety":{"closedWorld":false,"nonBlocking":["Lock.wait the fixture never waits"]}}}', [native, app]
		));
		Assert.isFalse(bySimpleName.contains('warning A A.written | sys.thread.Lock.wait'), 'waived by its simple name');
		Assert.same([
			'nonBlocking entry "utils.Lock.wait" names the project native "Lock.wait", which bears the name of a blocking library call'
			+ ' — kept: a call of the library one the graph cannot tell apart from it resolves there'
		], said(found));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A name a wildcard import of a std package supplies is that std type — the language looks in the wildcards before the
	 * file's package — unless the file's own module or an explicit import binds it; a name an `#if`-guarded import binds
	 * may be either type, so a call of it runs both members. Before, both resolved to the project's `Lock`, whose `wait`
	 * never blocks: the runtime's wait went silent.
	 */
	@:pin('control') @:killer('M-TS-WILD-PACKAGES') @:killer('M-TS-WILD-OWN-MODULE') @:killer('M-TS-WILD-EXPLICIT-FIRST')
	@:killer('M-TS-WILD-STD') @:killer('M-TS-GUARDED-IMPORT') @:killer('M-TS-ALTERNATE-CALL')
	public function testAWildcardOrGuardedImportOfALibraryTypeIsNotItsProjectNamesake(): Void {
		#if (sys || nodejs)
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final own: String = 'package utils; class Lock { public function new() {} public function wait():Bool return true; }';
		final config: String = '{"rules":{"thread-safety":{"closedWorld":false}}}';
		final wild: String =
			'package utils; import sys.thread.*; class W { static function main():Void { final l:Lock = null; l.wait(); } }';
		Assert.same(['warning A W.main | sys.thread.Lock.wait'], graded(ThreadSafetyCheckTest.violations(config, [own, wild])), 'wildcard');
		final guarded: String = 'package app; #if sys import sys.thread.Lock; #end'
			+ ' class G { static function main():Void { final l:Lock = null; l.wait(); } }';
		Assert.same(
			['warning A G.main | sys.thread.Lock.wait'], graded(ThreadSafetyCheckTest.violations(config, [own, guarded])), 'guarded'
		);
		// an explicit import, or the file's own module, binds the name before any wildcard: the project's type, which never waits
		final explicit: String = 'package app; import utils.Lock; import sys.thread.*;'
			+ ' class E { static function main():Void { final l:Lock = null; l.wait(); } }';
		Assert.same([], graded(ThreadSafetyCheckTest.violations(config, [own, explicit])), 'explicit import');
		final local: String = 'package app; import sys.thread.*; class Lock { public function new() {} public function wait():Bool'
			+ ' return true; } class M { static function main():Void { final l:Lock = null; l.wait(); } }';
		Assert.same([], graded(ThreadSafetyCheckTest.violations(config, [local])), 'own module');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `nonBlocking` pattern written with a package names the type declared at that path only: `sys.thread.Lock.*` waives
	 * nothing of a project native `utils.Lock`, and says so. Before, a dotted pattern matched every type of its simple name.
	 */
	@:pin('control') @:killer('M-TS-DOTTED-WILDCARD')
	public function testADottedWaiverNamesOnlyTheTypeAtThatPath(): Void {
		#if (sys || nodejs)
		final native: String = 'package utils; extern class Lock { public function new():Void; public function spin():Void; }';
		final app: String = 'package app; class C { static function main():Void { final l:utils.Lock = null; l.spin(); } }';
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(
			'{"rules":{"thread-safety":{"closedWorld":false,"nonBlocking":["sys.thread.Lock.* the std lock is only ever tried here"]}}}',
			[native, app]
		);
		Assert.same(['warning A C.main | Lock.spin'], graded(found));
		Assert.same([
			'nonBlocking entry "sys.thread.Lock.*" waives no builtin sink or project native of the run'
		], said(found));
		final waived: Array<Violation> = ThreadSafetyCheckTest.violations(
			'{"rules":{"thread-safety":{"closedWorld":false,"nonBlocking":["utils.Lock.spin our spin returns at once"]}}}', [native, app]
		);
		Assert.same([], graded(waived), 'the path the native is declared at waives it');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A local written with no type and initialised by a call holds what the call returns, as a call's receiver does: a std
	 * function's return type (`Sys.stdin()`), a project function's declared one. Before, such a local was untyped.
	 */
	@:pin('control') @:killer('M-TS-LOCAL-CALL-INIT') @:killer('M-TS-LOCAL-CALL-READ')
	public function testALocalOfACallResultIsTypedByWhatTheCallReturns(): Void {
		#if (sys || nodejs)
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final source: String = 'class C { static function makeLock():sys.thread.Lock return null;'
			+ ' static function stdin():Void { final i = Sys.stdin(); i.readLine(); }'
			+ ' static function made():Void { var l = makeLock(); l.wait(); }' + ' static function main():Void { stdin(); made(); } }';
		Assert.same(
			['warning A C.made | Lock.wait', 'warning A C.stdin | Input.readLine'],
			graded(ThreadSafetyCheckTest.violations('{"rules":{"thread-safety":{"closedWorld":false}}}', [source]))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * What a std call returns or a std field holds types the receiver of the next call (`StdTypes`), an import alias is the
	 * type it names, an unannotated local is the type its `new` makes, and a std property read runs its getter — whether or
	 * not a project type declares a property of that name: each reaches a blocking library call, among them the event loop,
	 * a datagram read and a result set's `length`.
	 */
	@:pin('control') @:killer('M-TS-STD-RETURN') @:killer('M-TS-STD-FIELD') @:killer('M-TS-STD-GETTER') @:killer('M-TS-STD-GETTER-LOCAL')
	@:killer('M-TS-STD-GETTER-TYPED') @:killer('M-TS-NEW-LOCAL') @:killer('M-TS-ALIAS-TYPE') @:killer('M-TS-STD-PLACEHOLDER')
	@:killer('M-TS-BUILTIN-EVENTS')
	public function testStdResultsTypeTheirReceivers(): Void {
		#if (sys || nodejs)
		if (anyparse.query.StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final source: String = 'import sys.io.File as Disk; import sys.db.ResultSet;'
			+ ' class C { static function alias():Void Disk.getContent("x"); static function stdin():Void Sys.stdin().readLine();'
			+ ' static function socket():Void { final s = new sys.net.Socket(); s.input.readLine(); }'
			+ ' static function ssl(s:sys.ssl.Socket):Void s.input.readLine();'
			+ ' static function loop():Void sys.thread.Thread.current().events.loop();'
			+ ' static function idle(e:sys.thread.EventLoop):Void e.wait(1); static function job():Void sys.thread.Thread.runWithEventLoop(() -> {});'
			+ ' static function datagram(u:sys.net.UdpSocket):Void u.readFrom(null, 0, 4, null);'
			+ ' static function rows(r:ResultSet):Int return r.length;'
			+ ' static function main():Void { alias(); stdin(); socket(); ssl(null); loop(); idle(null); job(); datagram(null); rows(null); } }';
		final config: String = '{"rules":{"thread-safety":{"closedWorld":false}}}';
		Assert.same([
			'warning A C.alias | File.getContent',
			'warning A C.datagram | UdpSocket.readFrom',
			'warning A C.idle | EventLoop.wait',
			'warning A C.job | Thread.runWithEventLoop',
			'warning A C.loop | EventLoop.loop',
			'warning A C.rows | ResultSet.get_length',
			'warning A C.socket | Input.readLine',
			'warning A C.ssl | Input.readLine',
			'warning A C.stdin | Input.readLine'
		], graded(ThreadSafetyCheckTest.violations(config, [source])));
		// a project property of the same name: the std one is still read off a value of the std type
		final namesake: String = 'class P { public var length(get, never):Int; function get_length():Int return 0; }';
		Assert.isTrue(
			graded(ThreadSafetyCheckTest.violations(config, [source, namesake])).contains('warning A C.rows | ResultSet.get_length'),
			'beside a project property named length'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A std member stands only where every std type of its name that declares it agrees, through supertypes, its type
	 * resolved in the module that writes it (`StdTypes`); one with a getter says so even when its type does not resolve.
	 */
	@:pin('control') @:killer('M-TS-STD-AGREE') @:killer('M-TS-STD-SUPER') @:killer('M-TS-STD-SIBLING')
	public function testAStdMemberStandsWhereEveryNamesakeAgrees(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('stdtypes', [
			{ name: 'Std.hx', source: 'class Std {}' },
			{ name: 'haxe/a/Pipe.hx', source: 'package haxe.a; class Pipe { public function read():haxe.io.Bytes return null; }' },
			{ name: 'sys/b/Pipe.hx', source: 'package sys.b; class Pipe { public function read():String return null; }' },
			{ name: 'sys/c/Out.hx', source: 'package sys.c; class Out {}' },
			{
				name: 'sys/c/Base.hx',
				source: 'package sys.c; class Base { public var input(default, null):Out; public var size(get, never):Int;'
				+ ' function get_size():Int return 0; }'
			},
			{ name: 'sys/c/Derived.hx', source: 'package sys.c; class Derived extends Base {}' }
		]);
		final saved: Null<String> = Sys.getEnv('HAXE_STD_PATH');
		Sys.putEnv('HAXE_STD_PATH', dir);
		StdResolver.resetCache();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final disagree: Null<StdMember> = StdTypes.memberOf(plugin, 'Pipe', 'read');
		final one: Null<StdMember> = StdTypes.memberOf(plugin, 'haxe.a.Pipe', 'read');
		final inherited: Null<StdMember> = StdTypes.memberOf(plugin, 'Derived', 'input');
		final getter: Null<StdMember> = StdTypes.memberOf(plugin, 'Derived', 'size');
		// removed when it was unset: an empty value is a std path a spawned compiler reads as none
		Sys.putEnv('HAXE_STD_PATH', saved);
		StdResolver.resetCache();
		CliFixture.removeDir(dir);
		Assert.isNull(disagree, 'two std types of one name disagree');
		Assert.equals('haxe.io.Bytes', one?.type, 'a path names one type');
		Assert.equals('sys.c.Out', inherited?.type, 'through the superclass, resolved in its package');
		Assert.isTrue(getter?.hasGetter == true && getter?.type == null, 'a getter whose type does not resolve');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The notice counts what the run's `nonBlocking` entries removed: the sinks, and the entries that removed one. */
	@:pin('control') @:killer('M-TS-NOTICE-WAIVED')
	public function testTheNoticeCountsWhatNonBlockingRemoved(): Void {
		#if (sys || nodejs)
		final source: String = 'import sys.thread.Mutex; class A { static function main():Void { Sys.sleep(1); final m:Mutex = null;'
			+ ' m.acquire(); m.tryAcquire(); Sys.command("ls"); } }';
		final found: Array<Violation> = ThreadSafetyCheckTest.violations(
			'{"rules":{"thread-safety":{"nonBlocking":["Mutex.* the fixture mutex is never held","Sys.sleep it sleeps zero"]}}}', [source],
			null, true
		);
		final notice: Null<String> = found.find(v -> v.file == '' && StringTools.startsWith(v.message, PositiveSinks.NOTICE))?.message;
		Assert.isTrue(StringTools.endsWith(notice ?? '', '"nonBlocking" removes from them (here 2 sink(s) by 2 entries)'), notice);
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
