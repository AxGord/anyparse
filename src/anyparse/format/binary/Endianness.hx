package anyparse.format.binary;

/**
 * Byte order for multi-byte binary primitives. `Big` is network order
 * and the default for MessagePack and many wire protocols; `Little` is
 * x86 native order and the default for CBOR length-encoded ints.
 */
enum abstract Endianness(Int) {
	final Big = 0;
	final Little = 1;
}
