package anyparse.core;

/**
 * A map keyed by the IDENTITY of its key: two keys are the same entry exactly when they are the same object. On js it is
 * the native `Map`, which keys by identity without writing an id onto the key (`ObjectMap` stores one in a `__id__` field
 * of every key it is handed, which changes the key's shape); elsewhere `ObjectMap`, whose `{}` key an enum does not unify
 * with — identity is what every target's `ObjectMap` compares.
 */
abstract IdentityMap<K, V>(#if js js.lib.Map<K, V> #else haxe.ds.ObjectMap<{}, V> #end) {

	public inline function new() {
		this = #if js new js.lib.Map() #else new haxe.ds.ObjectMap() #end;
	}

	@:arrayAccess
	public inline function get(k: K): Null<V> {
		return this.get(#if js k #else cast k #end);
	}

	public inline function set(k: K, v: V): Void {
		this.set(#if js k #else cast k #end, v);
	}

	/** `map[k] = v`: `set`, answering `v`. */
	@:arrayAccess
	public inline function write(k: K, v: V): V {
		set(k, v);
		return v;
	}

	public inline function exists(k: K): Bool {
		return #if js this.has(k) #else this.exists(cast k) #end;
	}

}
