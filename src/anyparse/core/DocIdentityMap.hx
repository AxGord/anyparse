package anyparse.core;

/**
 * A map keyed by the IDENTITY of a Doc node — the key a walk over a Doc needs,
 * because a Doc is a DAG: a two-branch ctor's branches share their operands,
 * and those operands nest, so a walk that revisits a shared node pays
 * `2^depth`. On js it is the native `Map`, which keys by identity without
 * writing an id onto the node; elsewhere `ObjectMap`, whose `{}` key an enum
 * does not unify with — identity is what every target's `ObjectMap` compares.
 */
abstract DocIdentityMap<V>(#if js js.lib.Map<Doc, V> #else haxe.ds.ObjectMap<{}, V> #end) {

	public inline function new() {
		this = #if js new js.lib.Map() #else new haxe.ds.ObjectMap() #end;
	}

	public inline function get(d: Doc): Null<V> {
		return this.get(#if js d #else cast d #end);
	}

	public inline function set(d: Doc, v: V): Void {
		this.set(#if js d #else cast d #end, v);
	}

	public inline function exists(d: Doc): Bool {
		return #if js this.has(d) #else this.exists(cast d) #end;
	}

}
