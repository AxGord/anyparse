package unit.core;

import anyparse.core.ContentHash;
import haxe.crypto.Md5;
import haxe.io.Bytes;

/** `ContentHash.md5`: the lowercase hex digest of a text's UTF-8 bytes, the same on every target. */
@:nullSafety(Strict)
class ContentHashTest extends Test {

	/** The digest is the standard md5 of the UTF-8 encoding: empty text, ASCII, and a multi-byte character each. */
	@:pin('control') @:killer('M-CONTENT-HASH-UTF8')
	public function testTheDigestIsTheMd5OfTheUtf8Bytes(): Void {
		Assert.equals('d41d8cd98f00b204e9800998ecf8427e', ContentHash.md5(''));
		Assert.equals('900150983cd24fb0d6963f7d28e17f72', ContentHash.md5('abc'));
		Assert.equals(Md5.make(Bytes.ofString('café')).toHex(), ContentHash.md5('café'));
	}

	/** The digest of raw bytes is the standard md5 of exactly those bytes, whatever they hold: empty, text, and non-text values. */
	@:pin('control') @:killer('M-CONTENT-HASH-BYTES-WHOLE')
	public function testTheBytesDigestCoversEveryByte(): Void {
		Assert.equals('d41d8cd98f00b204e9800998ecf8427e', ContentHash.md5Bytes(Bytes.alloc(0)));
		Assert.equals('900150983cd24fb0d6963f7d28e17f72', ContentHash.md5Bytes(Bytes.ofString('abc')));
		final raw: Bytes = Bytes.ofHex('00ff80');
		Assert.equals(Md5.make(raw).toHex(), ContentHash.md5Bytes(raw));
	}

}
