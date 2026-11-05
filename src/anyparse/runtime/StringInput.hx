package anyparse.runtime;

import haxe.io.Bytes;

using StringTools;

/**
 * `Input` implementation backed by a Haxe `String`.
 *
 * First and simplest reference implementation. Used by the
 * macro-generated parsers operating on in-memory strings.
 */
@:nullSafety(Strict)
final class StringInput implements Input {

	public var length(get, never): Int;

	private final _source: String;

	public function new(source: String) {
		_source = source;
	}

	private inline function get_length(): Int {
		return _source.length;
	}

	public inline function charCodeAt(pos: Int): Int {
		// The bounds test makes the unchecked read safe; `String.charCodeAt` answers `Null<Int>`, a boxed value on
		// static targets, on every call.
		return pos < 0 || pos >= _source.length ? -1 : _source.fastCodeAt(pos);
	}

	public inline function substring(from: Int, to: Int): String {
		return _source.substring(from, to);
	}

	public inline function matchAt(re: EReg, pos: Int): Bool {
		return AnchoredRegex.matchIn(re, _source, pos);
	}

	public inline function bytes(from: Int, to: Int): Bytes {
		return Bytes.ofString(_source.substring(from, to));
	}

}
