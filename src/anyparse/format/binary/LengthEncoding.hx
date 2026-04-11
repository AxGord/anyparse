package anyparse.format.binary;

/**
 * How lengths and counts are encoded in a binary format.
 *
 * - `Varint` — LEB128-style variable-length unsigned integer.
 * - `U8`/`U16`/`U32`/`U64` — fixed-width unsigned length prefix in the
 *   format's declared endianness.
 */
enum abstract LengthEncoding(Int) {
	final Varint = 0;
	final U8 = 1;
	final U16 = 2;
	final U32 = 3;
	final U64 = 4;
}
