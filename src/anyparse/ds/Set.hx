package anyparse.ds;

#if js
private typedef Store<K> = js.lib.Set<K>;
#else
private typedef Store<K> = haxe.Constraints.IMap<K, Bool>;
#end

/**
 * An unordered collection of distinct keys — the one answer to "a set of keys" for the project, where the standard library
 * only offers `Map<K, Bool>` and its meaningless `true`. The native `js.lib.Set` on js, a `Map` of the key's kind elsewhere.
 *
 * Like `Map`, the store is chosen from the key type written at each `new Set<K>()`: a `String`, an `Int` or an object (by
 * identity). An enum value is REFUSED at compile time: `Map` compares it structurally while a native set compares it by
 * identity, so one program would mean two things on two targets. Iteration visits every key once, in no promised order.
 * This package imports nothing from `anyparse.*`, and generated code does not depend on it.
 */
@:multiType(K)
abstract Set<K>(Store<K>) {

	public function new();

	/** Put `key` in; a key already present stays. */
	public inline function add(key: K): Void {
		#if js
		this.add(key);
		#else
		this.set(key, true);
		#end
	}

	/** Whether `key` is in the set. */
	public inline function has(key: K): Bool {
		return #if js this.has(key) #else this.exists(key) #end;
	}

	/** Take `key` out; whether it was there. */
	public inline function remove(key: K): Bool {
		return #if js this.delete(key) #else this.remove(key) #end;
	}

	public inline function clear(): Void {
		this.clear();
	}

	/** Every key, once. */
	public inline function iterator(): Iterator<K> {
		return #if js this.iterator() #else this.keys() #end;
	}

	/** A set of the same keys that no longer shares storage with this one. */
	public inline function copy(): Set<K> {
		return #if js cast new js.lib.Set<K>(this) #else cast this.copy() #end;
	}

	#if js
	@:to private static inline function toJsStringSet<K:String>(store: Store<K>): js.lib.Set<K> {
		return new js.lib.Set<K>();
	}

	@:to private static inline function toJsIntSet<K:Int>(store: Store<K>): js.lib.Set<K> {
		return new js.lib.Set<K>();
	}

	@:to private static inline function toJsObjectSet<K:{}>(store: Store<K>): js.lib.Set<K> {
		return new js.lib.Set<K>();
	}
	#else
	@:to private static inline function toStringSet<K:String>(store: Store<K>): haxe.ds.StringMap<Bool> {
		return new haxe.ds.StringMap<Bool>();
	}

	@:to private static inline function toIntSet<K:Int>(store: Store<K>): haxe.ds.IntMap<Bool> {
		return new haxe.ds.IntMap<Bool>();
	}

	@:to private static inline function toObjectSet<K:{}>(store: Store<K>): haxe.ds.ObjectMap<K, Bool> {
		return new haxe.ds.ObjectMap<K, Bool>();
	}
	#end

}
