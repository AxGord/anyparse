package anyparse.runtime;

using StringTools;

/**
 * The longest prefix two strings share, character for character. Lives in `anyparse.runtime` for the
 * reason `EditDistance` does: pure text arithmetic the check, format and query layers all reach down to.
 */
@:nullSafety(Strict)
final class CommonPrefix {

	public static function of(a: String, b: String): String {
		final limit: Int = a.length < b.length ? a.length : b.length;
		var i: Int = 0;
		while (i < limit && a.fastCodeAt(i) == b.fastCodeAt(i)) i++;
		return a.substr(0, i);
	}

}
