package anyparse.runtime;

/**
 * The byte-order mark a text file may open with. A generated parser skips it as whitespace, so no
 * AST holds it and no writer emits it: whoever turns a source into written text carries it over.
 */
@:nullSafety(Strict)
final class ByteOrderMark {

	/** The mark's code point. */
	public static inline final CODE: Int = 0xFEFF;

	/** True when `text` opens with the mark. */
	public static function opens(text: String): Bool {
		return text.length > 0 && text.charCodeAt(0) == CODE;
	}

	/** `written`, opened with the mark exactly when `source` opened with it — a write keeps the file's mark and never adds one. */
	public static function carry(source: String, written: String): String {
		return opens(source) && !opens(written) ? String.fromCharCode(CODE) + written : written;
	}

}
