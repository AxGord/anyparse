package anyparse.runtime;

/**
 * `Input` implementation backed by `haxe.io.Bytes`.
 *
 * Used by macro-generated parsers for binary formats (ar, MessagePack,
 * protobuf, etc.). ASCII-range header fields work through `charCodeAt`
 * and `substring` (UTF-8 decode is identity for bytes 0–127). Raw
 * binary payloads use `bytes` which returns a zero-copy sub-slice.
 */
@:nullSafety(Strict)
final class BytesInput implements Input {

	public var length(get, never):Int;

	private final _source:haxe.io.Bytes;

	public function new(source:haxe.io.Bytes) {
		_source = source;
	}

	private inline function get_length():Int {
		return _source.length;
	}

	public inline function charCodeAt(pos:Int):Int {
		return pos < 0 || pos >= _source.length ? -1 : _source.get(pos);
	}

	public inline function substring(from:Int, to:Int):String {
		return _source.getString(from, to - from);
	}

	public inline function bytes(from:Int, to:Int):haxe.io.Bytes {
		return _source.sub(from, to - from);
	}
}
