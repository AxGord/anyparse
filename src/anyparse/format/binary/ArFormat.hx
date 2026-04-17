package anyparse.format.binary;

import anyparse.format.Encoding;

/**
 * Binary format descriptor for Unix ar archives (.a, .deb, .ipk).
 *
 * The ar format uses fixed-width ASCII headers with binary data
 * payloads. Endianness is irrelevant — all numeric fields are ASCII
 * decimal/octal text, not binary integers.
 *
 * Singleton: pure configuration, no per-parse state.
 */
@:nullSafety(Strict)
final class ArFormat implements BinaryFormat {

	public static final instance:ArFormat = new ArFormat();

	public var name(default, null):String = 'ar';
	public var version(default, null):String = '1.0';
	public var encoding(default, null):Encoding = Encoding.Binary;

	public var endianness(default, null):Endianness = Endianness.Big;
	public var tagSize(default, null):Int = 0;
	public var magicBytes(default, null):Null<haxe.io.Bytes> = null;
	public var lengthEncoding(default, null):LengthEncoding = LengthEncoding.U32;
	public var countEncoding(default, null):LengthEncoding = LengthEncoding.U32;

	/** Whitespace string for FormatReader compatibility (binary has none). */
	public var whitespace(default, null):String = '';

	private function new() {}
}
