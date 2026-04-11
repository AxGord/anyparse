package anyparse.format.binary;

import anyparse.format.Format;

/**
 * Binary format interface stub. Phase 1 declares the shape so the
 * `Format` hierarchy is visible end-to-end; real binary format
 * implementations (MessagePack, CBOR, protobuf) land in later phases
 * alongside the `Binary` strategy and the corresponding CoreIR
 * primitives.
 */
interface BinaryFormat extends Format {
	var endianness(default, null):Endianness;
	var tagSize(default, null):Int;
	var magicBytes(default, null):Null<haxe.io.Bytes>;
	var lengthEncoding(default, null):LengthEncoding;
	var countEncoding(default, null):LengthEncoding;
}
