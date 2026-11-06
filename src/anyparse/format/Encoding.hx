package anyparse.format;

/**
 * Character/byte encoding of a format. Text formats typically use
 * `UTF8`; binary formats use `Binary`, meaning raw bytes with no
 * interpretation as text.
 */
enum abstract Encoding(Int) {
	final UTF8 = 0;
	final UTF16LE = 1;
	final UTF16BE = 2;
	final ASCII = 3;
	final Binary = 4;
}
