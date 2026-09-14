package anyparse.format.binary;

import anyparse.format.Format;

/**
 * Binary format interface: the format-wide conventions of a binary
 * layout — endianness, the tag space, the length encodings. `ArFormat`
 * (the `ar` archive grammar) is the shipped implementation; per-field
 * layout is grammar metadata read by the `Bin` strategy, not a field
 * here. MessagePack, CBOR and protobuf descriptors come with their
 * grammars.
 */
interface BinaryFormat extends Format {

	var endianness(default, null): Endianness;
	var tagSize(default, null): Int;
	var magicBytes(default, null): Null<haxe.io.Bytes>;
	var lengthEncoding(default, null): LengthEncoding;
	var countEncoding(default, null): LengthEncoding;

}
