package anyparse.util;

/**
 * The one answer to "which first value does a projection give over a sequence": the descent that tries each element and
 * stops at the first one the projection answers. Each helper is marked `@:preferHelper`, so the `prefer-helper` rule
 * finds every inlined copy of its body and offers this call instead. This package imports nothing from `anyparse.*`, and
 * it holds no state.
 */
@:nullSafety(Strict)
final class Arrays {

	/** The first non-null `f(x)` over `xs` in iteration order, or null when `f` answers none; `f` runs no further. */
	@:preferHelper
	public static function findMap<T, R>(xs: Iterable<T>, f: T -> Null<R>): Null<R> {
		for (x in xs) {
			final y: Null<R> = f(x);
			if (y != null) return y;
		}
		return null;
	}

}
