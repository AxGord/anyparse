package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CallGraph;
import anyparse.query.SymbolIndex;
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

	/**
	 * Each body of a module-level function the module declares in several `#if` branches is a node of its own (`Main.f`, then
	 * `Main.f@2`), and a bare use binds the bodies the builds compiling it may run — the imported static in the builds declaring
	 * none — while a member of the enclosing chain and a local function still come first (Haxe 4.3.7 `v-N11-hx/p1`). A name
	 * nothing binds per build — an import naming the function, a query — runs every body.
	 */
	@:pin('control')
	@:killer('M-GRAPH-BODY-SPLIT') @:killer('M-GRAPH-BODY-EXPAND') @:killer('M-GRAPH-BODY-EXACT') @:killer('M-GRAPH-BODY-TARGETS')
	@:killer('M-GRAPH-BODY-COPY-IN') @:killer('M-GRAPH-BODY-PURGE') @:killer('M-GRAPH-MODULE-BINDING')
	@:killer('M-GRAPH-MODULE-BINDING-MEMBER') @:killer('M-GRAPH-MODULE-BINDING-LOCAL') @:killer('M-GRAPH-MODULE-BINDING-VALUE')
	@:killer('M-GRAPH-MODULE-BINDING-IMPORTS') @:killer('M-GRAPH-MODULE-REF') @:killer('M-GRAPH-MODULE-IDENT')
	public function testEachBodyOfAModuleLevelFunctionUnderIfIsANodeOfItsOwn(): Void {
		final files: Array<{ file: String, source: String }> = QueryTestHelpers.rootModules([
			'package utils; class Lock { public function new() {} public function wait():Bool return true; }',
			'package utils; class Other { public function new() {} public function wait():Bool return true; }',
			'package app; class B { public static function f():Void {} }',
			'package app; class Runner { public static function create(fn:() -> Void):Void {} }',
			'package app; import app.Main.f; class Elsewhere { static function call():Void f(); }',
			'package app; import app.B.*; class Main { static function call():Void f(); } #if a function f():Void new '
			+ 'utils.Lock().wait(); #elseif b function f():Void new utils.Other().wait(); #end function viaModule():Void f(); #if a class '
			+ 'InA { static function call():Void f(); } #else class NotA { static function call():Void f(); } #end class Shadow {'
			+ ' static function f():Void {} static function call():Void f(); } class Ref { static function call():Void Runner.create(f); }'
			+ ' function local():Void { function f():Void {} f(); } #if a function g():Void {} #else var g:() -> Void = null; #end '
			+ 'function viaG():Void g(); function make():utils.Lock return null; class Typed { static function call():Void make().wait(); }'
		]);
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final last: Int = files.length - 1;
		final g: CallGraph = CallGraph.build(files.slice(0, last), plugin, SymbolIndex.build(files, plugin));
		g.addFiles([files[last]]);
		function targets(from: String, kind: EdgeKind = Call): Array<String> {
			final out: Array<String> = [for (e in g.outEdges(from)) if (e.kind == kind) e.to];
			out.sort(Reflect.compare);
			return out;
		}
		Assert.same(['Lock.wait'], targets('Main.f'), 'the #if a body runs its own code');
		Assert.same(['Other.wait'], targets('Main.f@2'), 'the #elseif b body is a node of its own');
		Assert.same(['B.f', 'Main.f', 'Main.f@2'], targets('Main.viaModule'), 'module-level code: each body, and the import');
		Assert.same([], [for (u in g.unresolved) if (u.from == 'Main.viaModule') u.reason], 'nothing unresolved there');
		Assert.same(['B.f', 'Main.f', 'Main.f@2'], targets('Main.call'), 'the main class sees no member f: the module\'s');
		Assert.same(['Main.f'], targets('InA.call'), 'a use in #if a binds the #if a body');
		Assert.same(['B.f', 'Main.f@2'], targets('NotA.call'), 'its #else: the #elseif body, or the import');
		Assert.same(['Shadow.f'], targets('Shadow.call'), 'a static of the enclosing class comes first');
		Assert.same(['B.f', 'Main.f', 'Main.f@2'], targets('Ref.call', Ref), 'a read as a value binds the same bodies');
		Assert.same(['Main.local#f'], targets('Main.local'), 'a local function comes first');
		Assert.same(['Main.g'], targets('Main.viaG'), 'the build declaring a function runs its body');
		Assert.same(
			['FunctionValue(g)'],
			[for (u in g.unresolved) if (u.from == 'Main.viaG') Std.string(u.reason)],
			'the other runs the value its var holds'
		);
		Assert.same(['Lock.wait', 'Main.make'], targets('Typed.call'), 'a call of the one function a use binds is of its return type');
		Assert.same(['Main.f', 'Main.f@2'], targets('Elsewhere.call'), 'an import names the function: every body');
		Assert.same(['Main.f', 'Main.f@2'], [for (n in g.resolveTarget('Main.f')) n.id], 'so does a query');
		g.removeFile(files[last].file);
		g.addFiles([files[last]]);
		Assert.same(['Main.f', 'Main.f@2'], targets('Elsewhere.call'), 'read again, each body once');
	}

	private inline function graphOf(sources: Array<String>): CallGraph {
		return QueryTestHelpers.graphOf(sources);
	}

}
