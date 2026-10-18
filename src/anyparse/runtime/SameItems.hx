package anyparse.runtime;

/**
 * Whether two arrays hold the same items in the same order, each pair compared with `==` — identity for objects, value
 * for numbers and strings. Lives in `anyparse.runtime` for the reason `CommonPrefix` does: the check and query layers
 * both reach down to it.
 */
@:nullSafety(Strict)
final class SameItems {

	public static function of<T>(a: Array<T>, b: Array<T>): Bool {
		if (a.length != b.length) return false;
		for (i => item in a) if (item != b[i]) return false;
		return true;
	}

}
