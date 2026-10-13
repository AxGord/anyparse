package unit.check;

import utest.Assert;
import utest.Test;

/**
 * Reflective writes against the lock names (`FieldWrites.reflectivelyWritten`, review N2 / F3): a write of a computed name
 * on a value the run places on no class may store any lock in any lock member, so it unseals every one — the sound
 * default. What keeps a lock member sealed is a POSITIVE exclusion that bounds what the value is (`FieldWrites.placeOf`):
 * a `final` local bound to a fresh structure or object, a `case` capture typed by its enum constructor, a type parameter
 * bounded by its constraint or by every instantiation of its class.
 */
class ThreadSafetyReflectiveSealTest extends Test {

	#if (sys || nodejs)
	private static inline final RULE: String = '"thread-safety":{"sinks":["Mutex.acquire","Sys.sleep"],"spawns":["Runner.create"],'
		+ '"lockPairs":["Mutex.acquire/release"]';

	/** The rule over a closed project that declares no class made from a computed name (`reflectiveClasses`). */
	private static inline final CLOSED: String = '{"reflectiveClasses":["nothing.*"],"rules":{$RULE,"closedWorld":true}}}';
	#end

	/**
	 * A computed name on a value the typer cannot place — a library container's element, an array element, an
	 * un-annotated local of a library call, `Dynamic` — unseals `_l`, so the main thread's take of it stays reported, and
	 * the run names the writer; a `case` capture is typed by its enum constructor's parameter (`D`, which declares `_l`),
	 * a capture of a `Map` parameter is an element write, not a reflective one, and a constructor name two enums declare
	 * types no capture.
	 */
	@:pin('control') @:killer('M-TS-SEAL-REFLECT-UNPLACED') @:killer('M-TS-SEAL-UNPLACED-NOTICE') @:killer('M-TS-BINDER-TYPE')
	@:killer('M-TS-BINDER-UNIQUE')
	public function testAValueTheRunCannotPlaceUnsealsEveryLock(): Void {
		#if (sys || nodejs)
		Assert.equals(1, quickTakes('Reflect.setField(owners.first(), k, _m);'), 'a library container element');
		Assert.equals(1, quickTakes('Reflect.setField(arr[0], k, _m);'), 'an array element');
		Assert.equals(1, quickTakes('final o = owners.first(); Reflect.setField(o, k, _m);'), 'an un-annotated local');
		Assert.equals(1, quickTakes('final o:Dynamic = owners.first(); Reflect.setField(o, k, _m);'), 'a Dynamic local');
		Assert.equals(1, quickTakes('final o:D = owners.first(); Reflect.setField(o, k, _m);'), 'a local of its class');
		Assert.equals(1, quickTakes('switch box { case Holder(v): Reflect.setField(v, k, _m); case _: }'), 'a capture of class D');
		Assert.equals(1, quickTakes('switch box { case Pack(v): Reflect.setField(v, k, _m); case _: }'), 'an ambiguous capture');
		Assert.equals(0, quickTakes('switch box { case Bag(m): m[k] = new Mutex(); case _: }'), 'a capture of a Map');
		Assert.equals(
			1, found('Reflect.setField(arr[0], k, _m);').filter(f -> f.indexOf('so no lock is named by its member: D.alias') != -1).length,
			'the run names the writer'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `final` local bound to a fresh structure writes into that structure, whatever it escapes to, and one bound to
	 * `new Other()` into an `Other`: neither class declares `_l`, which stays sealed, and the run says which exclusion
	 * held. A fresh `D` declares it; a `var` may be bound again.
	 */
	@:pin('control') @:killer('M-TS-PLACE-FRESH-STRUCT') @:killer('M-TS-PLACE-FRESH-NEW') @:killer('M-TS-PLACE-FRESH-MUTABLE')
	public function testAFreshObjectReceiverKeepsTheLockNames(): Void {
		#if (sys || nodejs)
		Assert.equals(0, quickTakes('final y:Dynamic = {}; Reflect.setField(y, k, _m);'), 'a fresh structure');
		Assert.equals(0, quickTakes('final y:Dynamic = new Other(); Reflect.setField(y, k, _m);'), 'a fresh Other');
		Assert.equals(1, quickTakes('final y:Dynamic = new D(); Reflect.setField(y, k, _m);'), 'a fresh D');
		Assert.equals(1, quickTakes('var y:Dynamic = {}; Reflect.setField(y, k, _m);'), 'a var');
		Assert.equals(
			1,
			found('final y:Dynamic = {}; Reflect.setField(y, k, _m);').filter(f -> f.indexOf('D.alias (a fresh structure)') != -1).length,
			'the run says which exclusion held'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `Node<T>`'s `targetObject:T` written by a computed name: every subclass binds `T` — to `Void`, which holds no value, to
	 * a parameter its constraint bounds by `Other` (a `final` class's `extends` included) — and `Node` itself is never made,
	 * so `_l` stays sealed (a static call on `Node` makes none). Each unbounded instantiation unseals it: a `new Node`, the
	 * class read as a value, a link through an alias that writes no argument, a free subclass that is made, a run that
	 * does not cover a closed project, a project declaring no `reflectiveClasses` or declaring one that names `Node`. A
	 * method's own type parameter is bounded by its constraint alone.
	 */
	@:pin('control') @:killer('M-TS-PLACE-INSTANTIATIONS') @:killer('M-TS-PLACE-COMPLETE') @:killer('M-TS-PLACE-RAW-LINK')
	@:killer('M-TS-PLACE-FREE-SUB') @:killer('M-TS-PLACE-NEVER-MADE') @:killer('M-TS-PLACE-UNDECLARED')
	@:killer('M-TS-PLACE-GLOB-MATCH') @:killer('M-TS-PLACE-MAKES-NEW') @:killer('M-TS-PLACE-MAKES-VALUE')
	@:killer('M-TS-PLACE-MAKES-RECEIVER') @:killer('M-TS-PLACE-VOID') @:killer('M-TS-PLACE-FORWARDED-BOUND')
	@:killer('M-TS-PLACE-PARAM-CONSTRAINT') @:killer('M-TS-PLACE-PARAM-OWNER') @:killer('M-TS-FINAL-SUPERS-WRITTEN')
	@:killer('M-TS-REACH-ALIAS-SUBTYPES')
	public function testATypeParameterReceiverIsBoundedByItsInstantiations(): Void {
		#if (sys || nodejs)
		final use: String = 'new V().toTarget("_l", d._m);';
		Assert.equals(0, nodeTakes(CLOSED, '', use), 'bounded by its instantiations');
		Assert.equals(
			1,
			nodeFindings(CLOSED, '', use)
				.filter(f -> f.indexOf('Node.toTarget (type parameter T of Node, bounded by its instantiations)') != -1)
				.length,
			'the run says which exclusion held'
		);
		Assert.equals(
			1, nodeTakes(CLOSED, '', 'final n:Node<D> = new Node<D>(); n.targetObject = d; n.toTarget("_l", d._m);'), 'a new Node'
		);
		Assert.equals(
			1, nodeTakes(CLOSED, '', 'final n:Node<D> = Type.createInstance(Node, []); n.toTarget("_l", d._m);'), 'a class value'
		);
		Assert.equals(1, nodeTakes(CLOSED, 'typedef N = Node<D>; class R extends N {}', use), 'an alias link');
		Assert.equals(1, nodeTakes(CLOSED, 'class G<Y> extends Node<Y> {}', 'new G<D>().toTarget("_l", d._m);'), 'a free subclass made');
		Assert.equals(1, nodeTakes('{"reflectiveClasses":["nothing.*"],"rules":{$RULE}}}', '', use), 'no closed project');
		Assert.equals(1, nodeTakes('{"rules":{$RULE,"closedWorld":true}}}', '', use), 'no reflectiveClasses');
		Assert.equals(1, nodeTakes('{"reflectiveClasses":["Node"],"rules":{$RULE,"closedWorld":true}}}', '', use), 'Node declared');
		Assert.equals(
			1,
			nodeTakes(
				CLOSED, '', 'new V().put(d, "_l", d._m);', 'public function put<T>(o:T, k:String, m:Mutex):Void Reflect.setField(o, k, m);'
			),
			"a method's own type parameter"
		);
		Assert.equals(0, nodeTakes(CLOSED, '', 'Node.poke(new Other(), "_l", d._m);'), "a method's bounded type parameter");
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** How many findings of `found(alias)` report the main thread's take of `_l` in `D.quick`. */
	private static function quickTakes(alias: String): Int {
		return found(alias).filter(f -> f.indexOf('D.quick -> Mutex.acquire') != -1).length;
	}

	/**
	 * The findings of a run in which `D.alias(k)` runs `alias` on the main thread while a worker holds `_m` across a
	 * sleep and the main thread takes `_l`.
	 */
	private static function found(alias: String): Array<String> {
		return [
			for (v in ThreadSafetyCheckTest.violations('{"rules":{$RULE}}}', [
				ThreadSafetyCheckTest.MUTEX,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class Other { public function new() {} }',
				'enum Crate { Pack(o:Other); }',
				'enum Box { Holder(d:D); Bag(m:Map<String, Mutex>); Pack(d:D); }',
				'class D { var _l:Mutex = new Mutex(); final _m:Mutex = new Mutex();'
				+ ' public static final owners:haxe.ds.List<D> = new haxe.ds.List<D>(); public static final arr:Array<D> = [];'
				+ ' public static var box:Box = null; public function new() {}'
				+ ' public function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); }'
				+ ' public function alias(k:String):Void { $alias }' + ' public function quick():Void { _l.acquire(); _l.release(); }'
				+ ' public static function main():Void { final d:D = new D(); owners.add(d); arr.push(d);'
				+ ' Runner.create(() -> d.work()); d.alias("_l"); d.quick(); } }'
			])) v.message
		];
	}

	/** How many findings of `nodeFindings` report the main thread's take of `_l` in `D.quick`. */
	private static function nodeTakes(config: String, classes: String, use: String, members: String = ''): Int {
		return nodeFindings(config, classes, use, members).filter(f -> f.indexOf('D.quick -> Mutex.acquire') != -1).length;
	}

	/**
	 * The findings of a run under `config` over `Node<T>`, whose `toTarget` writes `targetObject` by a computed name, its
	 * subclasses `V` (`Void`, a `final` class) and `P<X:Other>`, `classes` beside them, `members` among its own, and `D`
	 * running `use` on the main thread while a worker holds `_m` across a sleep and the main thread takes `_l`.
	 */
	private static function nodeFindings(config: String, classes: String, use: String, members: String = ''): Array<String> {
		return [
			for (v in ThreadSafetyCheckTest.violations(config, [
				ThreadSafetyCheckTest.MUTEX,
				'class Runner { public static function create(fn:()->Void):Void {} }',
				'class Other { public function new() {} }',
				'class Node<T> { public var targetObject:T = null; public function new() {}'
				+ ' public function toTarget(k:String, m:Mutex):Void Reflect.setField(targetObject, k, m);'
				+ ' public static function poke<X:Other>(o:X, k:String, m:Mutex):Void Reflect.setField(o, k, m); $members }',
				'final class V extends Node<Void> {} class P<X:Other> extends Node<X> {} $classes',
				'class D { var _l:Mutex = new Mutex(); final _m:Mutex = new Mutex(); public function new() {}'
				+ ' public function work():Void { _m.acquire(); Sys.sleep(1); _m.release(); }'
				+ ' public function quick():Void { _l.acquire(); _l.release(); }'
				+ ' public static function main():Void { final d:D = new D(); Runner.create(() -> d.work()); Node.poke(new Other(), "x", null);'
				+ ' $use d.quick(); } }'
			])) v.message
		];
	}
	#end

}
