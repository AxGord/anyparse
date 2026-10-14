package unit.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import utest.Assert;
import utest.Test;

/**
 * Receiver flow from `new` (`AllocationSets`): a dispatch on a field every value of which is a `new` the project writes,
 * on the object a `new` builds, or on the running object handed down such a call, runs only the overrides those classes
 * resolve to — TM's `APIRequest2.doRequest` builds its `urlLoader` as a thread or simple loader, never the blocking one.
 */
class ThreadSafetyAllocationTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],'
		+ '"spawns":["Runner.create"],"lockPairs":["Mutex.acquire/release"],"closedWorld":true}}}';

	private static inline final LOADERS: String = 'class Base { public function new(?now:Bool) { if (now == true) load(); }'
		+ ' public function load():Void go(); function go():Void {} }'
		+ ' class Blocking extends Base { override function go():Void Sys.sleep(1); }'
		+ ' class Async extends Base { override function go():Void {} }';

	/** A field only ever assigned `new Async()`: its `load` never runs `Blocking.go`. */
	@:pin('control') @:killer('M-TS-ALLOC-OFF')
	public function testASealedFieldRunsOnlyItsClassesOverrides(): Void {
		#if (sys || nodejs)
		Assert.same([], holds(run('var loader:Base;', 'loader = new Async();', 'loader.load();')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One write of anything but a `new` and the field's classes are unknown: every override may run. */
	@:pin('control') @:killer('M-TS-ALLOC-ANY-WRITE')
	public function testAnyOtherWriteMakesTheFieldUnknown(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B C.work | C._m'],
			holds(run('var loader:Base; public function set(l:Base):Void loader = l;', 'loader = new Async();', 'loader.load();'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A declared value counts as a write: `= new Blocking()` puts the blocking override back. */
	@:pin('control') @:killer('M-TS-ALLOC-DECLARED')
	public function testTheDeclaredValueCounts(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B C.work | C._m'], holds(run('var loader:Base = new Blocking();', 'loader = new Async();', 'loader.load();'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The object a `new` builds is of that class: its constructor's `load` dispatches on it alone. */
	@:pin('control') @:killer('M-TS-ALLOC-NEW')
	public function testAConstructionRunsOnItsOwnClass(): Void {
		#if (sys || nodejs)
		Assert.same([], holds(run('', '', 'new Async(true);')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A library class the index does not hold never runs a project override (it cannot extend a project type). */
	@:pin('control') @:killer('M-TS-ALLOC-LIBRARY')
	public function testALibraryClassRunsNoProjectOverride(): Void {
		#if (sys || nodejs)
		Assert.same([], holds(run('var loader:Base;', 'loader = flag ? new Async() : new lib.Loader();', 'loader.load();')));
		Assert.same(
			[], holds(run('var loader:Base;', 'loader = flag ? new Async() : new Loader();', 'loader.load();', 'import lib.Loader;')),
			'imported'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A name the run declares nowhere is a library class only when the file writes it by a path or imports it: an import
	 * alias (`as`, `in`) or a type parameter may name a project class, so it runs every override.
	 */
	@:pin('control') @:killer('M-TS-ALLOC-LIBRARY-PATH')
	public function testAnUndeclaredNameNoImportNamesRunsEveryOverride(): Void {
		#if (sys || nodejs)
		for (alias in ['import Blocking as Blk;', 'import Blocking in Blk;'])
			Assert.same(['warning B C.work | C._m'], holds(run('var loader:Base;', 'loader = new Blk();', 'loader.load();', alias)), alias);
		final generic: Array<Violation> = ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			LOADERS,
			'@:generic class C<T:Base> { public final _m:Mutex = new Mutex(); var loader:Base;'
			+ ' public function new() {} public function prepare():Void { loader = new T(); }'
			+ ' public function work():Void { _m.acquire(); loader.load(); _m.release(); } }',
			'class M { public static function main():Void { final c:C<Blocking> = new C<Blocking>(); c.prepare();'
			+ ' Runner.create(() -> c.work()); c._m.acquire(); c._m.release(); } }'
		]);
		Assert.same(['warning B C.work | C._m'], holds(generic), 'type parameter');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An alias spelled as a project class's name names whatever it aliases, not that class. */
	@:pin('control') @:killer('M-TS-ALLOC-ALIAS')
	public function testAnAliasNamedAsAProjectClassNamesWhatItAliases(): Void {
		#if (sys || nodejs)
		Assert.same(
			['warning B C.work | C._m'],
			holds(run('var loader:Base;', 'loader = new Async();', 'loader.load();', 'import Blocking as Async;'))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A run that leaves out a file of the project writing the field sees not every value of it: its classes are unknown. */
	@:pin('control') @:killer('M-TS-ALLOC-COMPLETE')
	public function testARunOverPartOfTheProjectSealsNoField(): Void {
		#if (sys || nodejs)
		final plugin: { name: String, source: String } = {
			name: 'Plugin.hx',
			source: 'class Plugin { public static function install(c:C):Void c.loader = new Blocking(); }'
		};
		Assert.same(
			['warning B C.work | C._m'], holds(run('public var loader:Base;', 'loader = new Async();', 'loader.load();', '', [plugin]))
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A reflective write whose name is computed may store anything in any field of its target's class, and in a field of
	 * any class when its target's type places it on none (`Dynamic`): the field's classes are unknown. One on a value of an
	 * unrelated class leaves the field sealed.
	 */
	@:pin('control') @:killer('M-TS-REFLECT-COMPUTED') @:killer('M-TS-REFLECT-MAYWRITE') @:killer('M-TS-REFLECT-HANDED-CALLEE')
	public function testAComputedReflectiveWriteMakesTheFieldUnknown(): Void {
		#if (sys || nodejs)
		inline function poked(poke: String): Array<String> {
			return holds(run('var loader:Base; $poke', 'loader = new Async();', 'loader.load();'));
		}
		// on its own class the write may also store another lock in `_m`, which then names no lock (`LockSites`, review F3)
		Assert.same(
			['warning B C.work | Mutex.acquire'],
			poked('public function set(k:String, l:Base):Void Reflect.setField(this, k, l);'), 'its own class'
		);
		// placed on no class, the write may also store a lock in any lock member: `_m` names no lock (review N2)
		Assert.same(
			['warning B C.work | Mutex.acquire'],
			poked('public static function poke(o:Dynamic, k:String):Void Reflect.setField(o, k, null);'), 'a Dynamic value'
		);
		Assert.same(
			[], poked('public static function poke(o:Blocking, k:String):Void Reflect.setField(o, k, null);'), 'an unrelated class'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Every way to write a field by a name chosen at run time is a reflective write (review F11): `DynamicAccess.set`, a
	 * `Reflect.setField` handed on as a value and called later, an index write into an `untyped` or a cast-to-`Dynamic`
	 * value — any index write into a value not proven an array, a map or a buffer. An index write into an array is none.
	 */
	@:pin('control') @:killer('M-TS-REFLECT-DYNACC') @:killer('M-TS-REFLECT-HANDED') @:killer('M-TS-REFLECT-INDEX-ANY')
	@:killer('M-TS-REFLECT-INDEX-ELEMENT')
	public function testEveryReflectiveEscapeMakesTheFieldUnknown(): Void {
		#if (sys || nodejs)
		inline function poked(poke: String): Array<String> {
			return holds(run('var loader:Base; final _bases:Array<Base> = []; $poke', 'loader = new Async();', 'loader.load();'));
		}
		// each is placed on no class, so it may also store a lock in any lock member: `_m` names no lock (review N2)
		final unknown: Array<String> = ['warning B C.work | Mutex.acquire'];
		Assert.same(
			unknown,
			poked('public static function poke(o:C, k:String):Void { final d:haxe.DynamicAccess<Dynamic> = cast o;' + ' d.set(k, null); }'),
			'DynamicAccess.set'
		);
		Assert.same(
			unknown, poked('public static function poke(o:C, k:String):Void { final set = Reflect.setField; set(o, k, null); }'),
			'a handed Reflect.setField'
		);
		Assert.same(
			['warning B C.work | Mutex.acquire'],
			poked('public static function poke(o:C, k:String):Void untyped o[k] = null;'),
			'an untyped index on its class, which may also write the lock member'
		);
		Assert.same(unknown, poked('public static function poke(o:C, k:String):Void (cast o : Dynamic)[k] = null;'), 'a cast index');
		Assert.same([], poked('public function poke(i:Int, b:Base):Void _bases[i] = b;'), 'an array element');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * `C` declaring `field`, assigning it by `assign` in `prepare`, and on a worker holding `_m` across `held`, its file
	 * headed by `imports`; `beside` on disk next to the run.
	 */
	private static function run(
		field: String, assign: String, held: String, imports: String = '', ?beside: Array<{ name: String, source: String }>
	): Array<Violation> {
		return ThreadSafetyCheckTest.violations(CONFIG, [
			ThreadSafetyCheckTest.MUTEX,
			'class Runner { public static function create(fn:()->Void):Void {} }',
			LOADERS,
			'$imports class C { final _m:Mutex = new Mutex(); var flag:Bool = false; $field public function new() {}'
			+ ' public function prepare():Void { $assign } public function work():Void { _m.acquire(); $held _m.release(); }'
			+ ' public function blocked():Void { final b:Blocking = new Blocking(); b.load(); }'
			+ ' public static function main():Void { final c:C = new C(); c.prepare(); Runner.create(() -> { c.work(); c.blocked(); });'
			+ ' c._m.acquire(); c._m.release(); } }'
		], beside);
	}

	/** The hold findings (b) of `found` as `<severity> B <member> | <lock>`, sorted. */
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
