package anyparse.util;

/**
 * The one answer to "how is a value added to a group": a map of keys to arrays of values, or an array kept free of
 * repeats. Each helper is marked `@:preferHelper`, so the `prefer-helper` rule finds every inlined copy of its body and
 * offers this call instead. This package imports nothing from `anyparse.*`, and it holds no state.
 */
@:nullSafety(Strict)
final class Groups {

	/** Append `v` to the group `m` keeps under `k`, starting the group when `k` has none. */
	@:preferHelper
	public static inline function push<K, V>(m: Map<K, Array<V>>, k: K, v: V): Void {
		final xs: Array<V> = m[k] ?? [];
		xs.push(v);
		m[k] = xs;
	}

	/** Append `x` to `xs` unless `xs` already contains it; `contains` decides, so a reference type compares by identity. */
	@:preferHelper
	public static inline function pushUnique<T>(xs: Array<T>, x: T): Void {
		if (!xs.contains(x)) xs.push(x);
	}

}
