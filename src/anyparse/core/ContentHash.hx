package anyparse.core;

/**
 * The one answer to "what is the md5 of this content": a lowercase hex digest, through node's native digest where the
 * target has one and the portable `haxe.crypto.Md5` elsewhere, so a text and the bytes it encodes to hash alike.
 */
@:nullSafety(Strict)
final class ContentHash {

	/**
	 * md5 of `data`. Node's native digest is orders of magnitude faster than the pure-Haxe
	 * implementation, and that difference is what keeps hashing every source from dominating
	 * the very typecheck this cache exists to avoid.
	 */
	public static function md5(data: String): String {
		return #if nodejs js.node.Crypto.createHash('md5').update(data, 'utf8').digest('hex') #else haxe.crypto.Md5.encode(data) #end;
	}

}
