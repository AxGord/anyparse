package anyparse.check.scan;

/**
 * The one answer to "what number does a numeric literal's text spell": decimal and float spellings through
 * `Std.parseFloat`, a hexadecimal one through `Std.parseInt` (which `Std.parseFloat` would read as zero), `_`
 * separators ignored. Null for text that spells no number.
 */
@:nullSafety(Strict)
final class NumericLiteral {

	public static function valueOf(text: String): Null<Float> {
		final clean: String = text.replace('_', '');
		if (clean.startsWith('0x') || clean.startsWith('0X')) return (Std.parseInt(clean): Null<Int>);
		final f: Float = Std.parseFloat(clean);
		return Math.isNaN(f) ? null : f;
	}

}
