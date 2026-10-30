package anyparse.query.cli;

/**
 * One token of a command's argv as its `CliFlags` reads it: a flag with the value it took, the `--` separator, or a
 * positional. A parser switches on `flag` and never decides for itself whether a flag takes a value.
 */
@:nullSafety(Strict)
final class CliArg {

	/** The flag as typed (`--limit`, `-h`, the `--` separator), or null for a positional. */
	public final flag: Null<String>;

	/** The token itself: the flag, or the positional's text. */
	public final token: String;

	/** Where `token` sits in argv. */
	public final index: Int;

	/** The tokens the flag took, in order: none for a switch, one for a valued flag, more for one its spec gives more. */
	private final _values: Array<String>;

	public function new(flag: Null<String>, token: String, index: Int, values: Array<String>) {
		this.flag = flag;
		this.token = token;
		this.index = index;
		_values = values;
	}

	/** Did the flag take a value: always for a valued flag, and for an optional-value one when its value followed. */
	public inline function hasValue(): Bool {
		return _values.length > 0;
	}

	/** The (first) value the flag took. A parser asking a switch for one has drifted from its spec: a bug, not a usage error. */
	public function value(): String {
		if (_values.length == 0) throw new Exception('$token takes no value in its command\'s CliFlags');
		return _values[0];
	}

	/** The value the flag took at `n`, counted from zero (`graph --diff <old> <new>`). */
	public function valueAt(n: Int): String {
		if (n >= _values.length) throw new Exception('$token takes no value $n in its command\'s CliFlags');
		return _values[n];
	}

	/** The value the flag took, or `fallback` when an optional-value flag stood alone. */
	public function valueOr(fallback: String): String {
		return _values.length > 0 ? _values[0] : fallback;
	}

}
