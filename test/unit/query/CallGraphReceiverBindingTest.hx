package unit.query;

import anyparse.query.CallGraph;
import anyparse.query.SymbolIndex;
import anyparse.util.Compare;

/**
 * The call graph dispatching a call on the type its receiver is BOUND to: a typedef alias resolved in its own file,
 * a name looked up in the packages of the file, a type parameter of the function itself, one type written two ways,
 * and a nullable receiver.
 */
class CallGraphReceiverBindingTest extends Test {

	@:pin('control')
	@:killer('M-TS-ALIAS-KEYED')
	@:killer('M-TS-ALIAS-AGREE')
	public function testATypedefAliasesWhatItsOwnFileBindsTheTargetTo(): Void {
		#if (sys || nodejs)
		if (anyparse.query.StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final g: CallGraph = CallGraph.build([
			{
				file: 'utils/Lock.hx',
				source: 'package utils; class Lock { public function new() {} public function wait():Bool return true; }'
			},
			{ file: 'pkg/Alias.hx', source: 'package pkg; import sys.thread.Lock; typedef MyLock = Lock;' },
			{ file: 'pkg/Sub.hx', source: 'package pkg; import sys.thread.Lock; typedef SubLock = Lock; class Sub {}' },
			{ file: 'pkg/Own.hx', source: 'package pkg; import utils.Lock; typedef OwnLock = Lock;' },
			{ file: 'one/Two.hx', source: 'package one; import sys.thread.Lock; typedef TwoLock = Lock;' },
			{ file: 'two/Two.hx', source: 'package two; import utils.Lock; typedef TwoLock = Lock;' },
			{
				file: 'app/A.hx',
				source: 'package app; import pkg.Alias; import pkg.Sub.SubLock; import pkg.Own; import utils.Lock; class A {'
				+ ' static function module(l:MyLock):Void l.wait(); static function sub(l:SubLock):Void l.wait();'
				+ ' static function own(l:OwnLock):Void l.wait(); static function two(l:TwoLock):Void l.wait(); }'
			},
			{
				file: 'app/Here.hx',
				source: 'package app; import sys.thread.Lock; typedef HereLock = Lock;'
				+ ' class Here { static function here(l:HereLock):Void l.wait(); }'
			}
		], new HaxeQueryPlugin());
		function targets(from: String): Array<String> {
			final out: Array<String> = [for (e in g.outEdges(from)) if (e.kind == Call) e.to];
			out.sort(Compare.compareString);
			return out;
		}
		Assert.same(['sys.thread.Lock.wait'], targets('A.module'), 'an alias of another module, imported by its module');
		Assert.same(['sys.thread.Lock.wait'], targets('A.sub'), 'an alias of another module, imported by name');
		Assert.same(['sys.thread.Lock.wait'], targets('Here.here'), 'an alias beside its use');
		Assert.same(['Lock.wait'], targets('A.own'), 'an alias of the project type');
		Assert.same(['Lock.wait'], targets('A.two'), 'two declarations keying the alias apart: the simple target');
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-TS-PACKAGE-LOOKUP')
	@:killer('M-TS-PACKAGE-ENCLOSING')
	@:killer('M-TS-PACKAGE-PROJECT-FIRST')
	public function testANameNoImportBindsIsLookedUpInTheFilesPackages(): Void {
		#if (sys || nodejs)
		if (anyparse.query.StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final g: CallGraph = graphOf([
			'package utils; class Lock { public function new() {} public function wait():Bool return true; }',
			'package sys.thread; class A { public static var lock:Lock = null; public static function make():Lock return null; }',
			'package sys.thread.deep; class B { public static var lock:Lock = null; }',
			'package sys.thread; import utils.*; class W { public static var lock:Lock = null; }',
			'package utils.inner; class U { public static var lock:Lock = null; }',
			'package sys.thread.mine; class Lock { public function new() {} public function wait():Bool return true; }',
			'package sys.thread.mine; class M { public static var lock:Lock = null; }',
			'package app; class C { static function own():Void A.lock.wait(); static function ret():Void A.make().wait();'
			+ ' static function deep():Void B.lock.wait(); static function wild():Void W.lock.wait();'
			+ ' static function proj():Void U.lock.wait(); static function mine():Void M.lock.wait(); }'
		]);
		function targets(from: String): Array<String> {
			final out: Array<String> = [for (e in g.outEdges(from)) if (e.kind == Call) e.to];
			out.sort(Compare.compareString);
			return out;
		}
		Assert.same(['sys.thread.Lock.wait'], targets('C.own'), 'a std type of the file\'s own package');
		Assert.same(['A.make', 'sys.thread.Lock.wait'], targets('C.ret'), 'a return type');
		Assert.same(['sys.thread.Lock.wait'], targets('C.deep'), 'a std type of an enclosing package');
		Assert.same(['Lock.wait'], targets('C.wild'), 'a wildcard import comes first');
		Assert.same(['Lock.wait'], targets('C.proj'), 'a project type of an enclosing package');
		Assert.same(['Lock.wait'], targets('C.mine'), 'a project type of the own package before a std one of an enclosing package');
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-GRAPH-FN-RETURN-PARAM')
	@:killer('M-TS-INFER-AGREE')
	@:killer('M-TS-INFER-REST')
	@:killer('M-TS-INFER-SHADOW')
	@:killer('M-TS-INFER-BARE')
	@:killer('M-TS-INFER-SHIFT')
	public function testAFunctionsOwnTypeParameterIsWhatItsArgumentsBind(): Void {
		#if (sys || nodejs)
		if (anyparse.query.StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final g: CallGraph = graphOf([
			'package utils; class Lock { public function new() {} public function wait():Bool return true; }',
			'package app; import utils.Lock; class A { public static function id<Lock>(x:Lock):Lock return x;'
			+ ' public static function two<Lock>(a:Lock, b:Lock):Lock return a; public static function pick<Lock>(...xs:Lock):Lock return '
			+ 'xs[0]; public static function head<Lock>(xs:Array<Lock>):Lock return xs[0];'
			+ ' public static function skip<Lock>(?n:Int, x:Lock, ?y:utils.Lock):Lock return x; }',
			'package app; class Box<T> { public function new() {} public function get<T>(x:T):T return x; }',
			'package app; class C { static function id(s:sys.thread.Lock):Void A.id(s).wait();'
			+ ' static function local(s:sys.thread.Lock):Void { final l = A.id(s); l.wait(); } static function same(s:sys.thread.Lock, '
			+ 't:sys.thread.Lock):Void A.two(s, t).wait(); static function apart(s:sys.thread.Lock, u:utils.Lock):Void A.two(s, u).wait();'
			+ ' static function rest(s:sys.thread.Lock, u:utils.Lock):Void A.pick(s, u).wait();'
			+ ' static function nested(xs:Array<sys.thread.Lock>):Void A.head(xs).wait(); static function shadow(b:Box<utils.Lock>, '
			+ 's:sys.thread.Lock):Void b.get(s).wait(); static function shifted(s:sys.thread.Lock, u:utils.Lock):Void A.skip(s, u).wait();'
			+ ' static function placed(s:sys.thread.Lock, u:utils.Lock):Void A.skip(0, s, u).wait(); }'
		]);
		function waits(from: String): Array<String> {
			final out: Array<String> = [
				for (e in g.outEdges(from)) if (e.kind == Call && e.to.indexOf('wait') >= 0) e.to
			];
			out.sort(Compare.compareString);
			return out;
		}
		final std: Array<String> = ['sys.thread.Lock.wait'];
		Assert.same(std, waits('C.id'), 'the argument binds the parameter');
		Assert.same(std, waits('C.local'), 'through a local');
		Assert.same(std, waits('C.same'), 'arguments that agree');
		Assert.same([], waits('C.apart'), 'arguments that disagree');
		Assert.same([], waits('C.rest'), 'rest arguments that disagree');
		Assert.same([], waits('C.nested'), 'a parameter nesting the type parameter');
		Assert.same([], waits('C.shadow'), 'a function type parameter shadowing its type\'s');
		Assert.same([], waits('C.shifted'), 'an argument a skipped optional parameter shifts (review L3 G3)');
		Assert.same(std, waits('C.placed'), 'every argument at its position');
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-TS-DECL-EACH-MEMBER')
	@:killer('M-TS-DECL-EACH-RETURN')
	@:killer('M-TS-DECL-EACH-UNTYPED')
	@:killer('M-TS-KEY-LINED')
	public function testDeclarationsWritingATypeDifferentlyDispatchOnEach(): Void {
		#if (sys || nodejs)
		if (anyparse.query.StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final g: CallGraph = graphOf([
			'package utils; class Lock { public function new() {} public function wait():Bool return true; }',
			'package utils; class Gate { public function new() {} public function wait():Bool return true; }',
			'package app; class A {\n#if sys\npublic static var lock:sys.thread.Lock = null;\n'
			+ 'public static function make():sys.thread.Lock return null;\npublic static function gate():sys.thread.Lock return null;\n'
			+ '#else\npublic static var lock:utils.Lock = null;\npublic static function make():utils.Lock return null;\n'
			+ 'public static function gate():utils.Gate return null;\n#end\n}',
			'package app; class B {\n#if sys\npublic static var lock:sys.thread.Lock = null;\n#else\n'
			+ 'public static var lock:Array<utils.Lock> = null;\n#end\n}',
			'package app; class D {\n#if sys\npublic static var lock:sys.thread.Lock = null;\n#else\npublic static var lock = null;\n'
			+ '#end\n}',
			'package app; class C { static function field():Void A.lock.wait(); static function call():Void A.make().wait();'
			+ ' static function named():Void A.gate().wait(); static function apart():Void B.lock.wait();'
			+ ' static function noType():Void D.lock.wait(); }'
		]);
		function waits(from: String): Array<String> {
			final out: Array<String> = [
				for (e in g.outEdges(from)) if (e.kind == Call && e.to.indexOf('wait') >= 0) e.to
			];
			out.sort(Compare.compareString);
			return out;
		}
		Assert.same(['Lock.wait', 'sys.thread.Lock.wait'], waits('C.field'), 'a field');
		Assert.same(['Lock.wait', 'sys.thread.Lock.wait'], waits('C.call'), 'a return');
		Assert.same(['Gate.wait', 'sys.thread.Lock.wait'], waits('C.named'), 'a return whose types differ in name');
		Assert.same([], waits('C.apart'), 'types that do not line up');
		Assert.same([], waits('C.noType'), 'a branch writing no type');
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-TS-RETURN-WRAPPER-BOUND')
	public function testACallReceiverBoundToANullableTypeDispatchesOnIt(): Void {
		#if (sys || nodejs)
		if (anyparse.query.StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final g: CallGraph = graphOf([
			'package app; class A { public static function id<T>(x:T):T return x;'
			+ ' public static function maybe():Null<sys.thread.Lock> return null; }',
			'package app; class C { static function bound():Void { final s:Null<sys.thread.Lock> = null; A.id(s).wait(); }'
			+ ' static function declared():Void A.maybe().wait(); }'
		]);
		function targets(from: String): Array<String> {
			final out: Array<String> = [for (e in g.outEdges(from)) if (e.kind == Call) e.to];
			out.sort(Compare.compareString);
			return out;
		}
		Assert.same(['A.id', 'Lock.wait'], targets('C.bound'), 'a type parameter bound to a nullable type');
		Assert.same(['A.maybe'], targets('C.declared'), 'a nullable return the declaration writes');
		#else
		Assert.pass('non-sys target');
		#end
	}

	private inline function graphOf(sources: Array<String>): CallGraph {
		return QueryTestHelpers.graphOf(sources);
	}

}
