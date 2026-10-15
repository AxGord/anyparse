package unit.query;

import anyparse.query.CallGraph;
import unit.QueryTestHelpers;
import utest.Assert;
import utest.Test;

/**
 * What the call graph reads a written name as on the shared binding layers (task B3, review L3 G2 / G5 / G6): a supertype
 * as its declaring file binds it, a container type as the file that wrote it binds it, and a bare name in module-level code
 * as the module and its imports bind it.
 */
class CallGraphBindingTest extends Test {

	/**
	 * A supertype is the type the declaration's own file binds the name it writes to (task B3): `class Mine extends
	 * sys.thread.Lock` beside a project `utils.Lock` extends the library's, so the project's `wait` is none of Mine's.
	 */
	@:pin('control') @:killer('M-SUPERS-BY-DECLARATION')
	public function testASupertypeIsTheTypeItsDeclaringFileBinds(): Void {
		final g: CallGraph = graphOf([
			'package utils; class Lock { public function new() {} public function wait():Bool return true; }',
			'package app; class Mine extends sys.thread.Lock { public function new() super(); }',
			'package app; class U { static function run(m:Mine):Void m.wait(); }'
		]);
		final out: Array<String> = [for (e in g.outEdges('U.run')) if (e.kind == Call) e.to];
		Assert.same(['Mine.wait'], out, 'a placeholder on the type, never the project namesake\'s method');
	}

	/**
	 * Review L3 G2 / G6 (`f2x/top-list(-rev)`, `proj-vec(-rev)`, `xfile-other`): a container is the std one only where the
	 * file that WROTE its type binds the name to the std's declaration — a project type at a std path (`haxe/ds/Vector.hx`,
	 * a root `List.hx`) shadows the std's on the class path (4.3.7, `hx/g2`), and a field type read in another file is what
	 * its declaring file's imports make it (`import lib.List;` there is no std list). A `Null<T>` parameter of a project
	 * type in a package is keyed as that type.
	 */
	@:pin('control') @:killer('M-TS-STD-CONTAINER-DECLARED') @:killer('M-TS-STD-CONTAINER-WHERE') @:killer('M-TS-NULLABLE-PATH-KEY')
	public function testAContainerIsTheStdOneOnlyWhereItsWritingFileBindsIt(): Void {
		#if (sys || nodejs)
		if (anyparse.query.StdResolver.stdDir() == null) {
			Assert.pass('no std on this machine');
			return;
		}
		final lock: String = 'package utils; class Lock { public function new() {} public function wait():Bool return true; }';
		function targets(g: CallGraph, from: String): Array<String> {
			final out: Array<String> = [for (e in g.outEdges(from)) if (e.kind == Call) e.to];
			out.sort(Reflect.compare);
			return out;
		}
		final list: CallGraph = graphOf([
			lock,
			'class List<T> { public function new() {} public function iterator():Iterator<utils.Lock> return null; }',
			'class C { static function top():Void { final l:List<sys.thread.Lock> = null; for (x in l) x.wait(); } }'
		]);
		Assert.same(['Lock.wait'], targets(list, 'C.top'), 'a root List.hx is the project\'s: its iterator() yields utils.Lock');
		final vector: CallGraph = graphOf([
			lock,
			'package haxe.ds; class Vector<T> { public function new(n:Int) {} public function iterator():Iterator<utils.Lock> return null; }',
			'import haxe.ds.Vector; class C { static function vec():Void { final v:Vector<sys.thread.Lock> = null; for (x in v) x.wait(); } }'
		]);
		Assert.same(['Lock.wait'], targets(vector, 'C.vec'), 'a project haxe/ds/Vector.hx shadows the std\'s');
		final crossFile: CallGraph = graphOf([
			lock,
			'package other; import lib.List; class Holder { public static var l:List<utils.Lock> = null; }',
			'import other.Holder; class C { static function read():Void for (x in Holder.l) x.wait(); }'
		]);
		Assert.same([], targets(crossFile, 'C.read'), 'a field type is what its declaring file binds: `lib.List` is no std list');
		final nullable: CallGraph = graphOf([
			lock,
			'package app; class Data { public function new() {} public function go():Void {} }',
			'package app; class U { static function run(d:Null<Data>):Void d.go(); }'
		]);
		Assert.same(['Data.go'], targets(nullable, 'U.run'), 'a Null<T> parameter of a project type in a package');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Review L3 G5 (`f7x/modfn-super`): a module-level function sees no class's members — not those of the main class whose
	 * name it shares with the module, nor that class's supertype statics — so its bare names are its module's and its
	 * imports' (Haxe 4.3.7: the main class's own static called bare there is `Unknown identifier`). A static an import binds,
	 * read there as a value, is the import's too.
	 */
	@:pin('control') @:killer('M-TS-MODULE-FN-CLASS-CHAIN') @:killer('M-TS-MODULE-FN-IMPORTED-REF')
	public function testAModuleLevelFunctionSeesItsModuleAndImportsNoClassChain(): Void {
		final g: CallGraph = graphOf([
			'package app; class A { public static function go():Void {} public static function only():Void {} }',
			'package app; class P { public static function go():Void {} public static function only():Void {} public function new() {} }',
			'package app; import app.A.*; class C extends P { static function inner():Void { go(); only(); } }'
			+ ' function helper():Void { go(); only(); } function take(f:()->Void):Void {} function hands():Void take(go);'
		]);
		function targets(from: String, kind: EdgeKind): Array<String> {
			final out: Array<String> = [for (e in g.outEdges(from)) if (e.kind == kind) e.to];
			out.sort(Reflect.compare);
			return out;
		}
		Assert.same(['A.go', 'A.only'], targets('C.helper', Call), 'a module function: the imports, never the main class chain');
		Assert.same(['A.go', 'A.only'], targets('C.inner', Call), 'inside the class: the supertype statics stay hidden');
		Assert.same(['A.go'], targets('C.hands', Ref), 'a static an import binds, handed on as a value');
	}

	/** A class extending a typedef alias of a type is a subtype of that type: a call on the type dispatches to its override. */
	@:pin('control') @:killer('M-TS-REACH-ALIAS-SUBTYPES')
	public function testAClassExtendingAnAliasIsASubtypeOfItsTarget(): Void {
		final g: CallGraph = graphOf([
			'package app; class T { public function new() {} public function m():Void {} }',
			'package app; typedef N = T;',
			'package app; class R extends N { override public function m():Void {} }',
			'package app; class U { static function run(t:T):Void t.m(); }'
		]);
		final out: Array<String> = [for (e in g.outEdges('U.run')) if (e.kind == Virtual) e.to];
		Assert.same(['R.m'], out, 'the override of a class extending the alias');
	}

	private inline function graphOf(sources: Array<String>): CallGraph {
		return QueryTestHelpers.graphOf(sources);
	}

}
