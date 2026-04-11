package anyparse.runtime;

/**
 * `Input` implementation backed by a Haxe `String`.
 *
 * First and simplest reference implementation. Used by both the
 * hand-written JSON parser and, in later phases, by macro-generated
 * parsers operating on in-memory strings.
 */
@:nullSafety(Strict)
final class StringInput implements Input {

	public var length(get, never):Int;

	private final _source:String;

	public function new(source:String) {
		_source = source;
	}

	private inline function get_length():Int {
		return _source.length;
	}

	public inline function charCodeAt(pos:Int):Int {
		if (pos < 0 || pos >= _source.length) return -1;
		final c:Null<Int> = _source.charCodeAt(pos);
		return c == null ? -1 : c;
	}

	public inline function substring(from:Int, to:Int):String {
		return _source.substring(from, to);
	}
}
