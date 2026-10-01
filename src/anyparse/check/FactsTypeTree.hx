package anyparse.check;

using StringTools;

/**
 * A type in the facts type grammar (`TypedFactsProbe`), read into its parts: the one reader of that spelling, behind
 * every consumer that needs more than its text — the source it spells (`FactsTypeSpelling`), the values it holds
 * (`FactsEscapes`).
 */
enum FactsType {

	/** `?`: an unbound monomorph, or a type nested deeper than the probe's bound. */
	Unknown;

	/** `$path`: a type parameter, `path` being its owner's id and its name (`pack.Box.T`). */
	Parameter(path: String);

	/**
	 * A class, enum, typedef or abstract by its id — `Dynamic`, `Null`, `Class`, `Enum` and `Abstract` among them — and its
	 * arguments.
	 */
	Named(path: String, args: Array<FactsType>);

	/** A function type: its arguments and its result. */
	Function(args: Array<FactsArgument>, result: FactsType);

	/** A structure: its fields, sorted by name. */
	Structure(fields: Array<FactsField>);

}

/** An argument of a facts function type: whether it may be left out, and its type. */
typedef FactsArgument = {
	final optional: Bool;
	final type: FactsType;
}

/** A field of a facts structure type: whether it may be absent, its name, and its type. */
typedef FactsField = {
	final optional: Bool;
	final name: String;
	final type: FactsType;
}

/** A recursive-descent reader of one type string of the facts type grammar into a `FactsType`. */
@:nullSafety(Strict)
final class FactsTypeTree {

	private var _pos: Int = 0;

	private final _text: String;

	private function new(text: String) {
		_text = text;
	}

	/** `text` read whole, or null when it is not one type of the grammar. */
	public static function read(text: String): Null<FactsType> {
		final reader: FactsTypeTree = new FactsTypeTree(text);
		final type: Null<FactsType> = reader.type();
		return reader._pos == text.length ? type : null;
	}

	/** The type at `_pos`; null when the text is malformed. */
	private function type(): Null<FactsType> {
		if (_pos >= _text.length) return null;
		return switch _text.fastCodeAt(_pos) {
			case '?'.code:
				_pos++;
				Unknown;
			case '('.code: functionType();
			case '{'.code: structure();
			case '$'.code:
				_pos++;
				final path: String = path();
				path == '' ? null : Parameter(path);
			case _: named();
		};
	}

	private function functionType(): Null<FactsType> {
		_pos++;
		final args: Array<FactsArgument> = [];
		while (peek() != ')'.code) {
			// an optional argument prints `?T`; a lone `?` before a separator is an unknown argument
			final optional: Bool = peek() == '?'.code && !separatorAt(_pos + 1);
			if (optional) _pos++;
			final read: Null<FactsType> = type();
			if (read == null) return null;
			final arg: FactsType = read;
			args.push({ optional: optional, type: arg });
			if (peek() == ','.code) _pos++;
		}
		if (!take(')') || !take('->')) return null;
		final result: Null<FactsType> = type();
		return result == null ? null : Function(args, result);
	}

	private function structure(): Null<FactsType> {
		_pos++;
		final fields: Array<FactsField> = [];
		while (peek() != '}'.code) {
			final optional: Bool = peek() == '?'.code;
			if (optional) _pos++;
			final name: String = path();
			if (name == '' || !take(':')) return null;
			final read: Null<FactsType> = type();
			if (read == null) return null;
			final field: FactsType = read;
			fields.push({ optional: optional, name: name, type: field });
			if (peek() == ','.code) _pos++;
		}
		return take('}') ? Structure(fields) : null;
	}

	private function named(): Null<FactsType> {
		final name: String = path();
		if (name == '') return null;
		final args: Array<FactsType> = [];
		if (peek() != '<'.code) return Named(name, args);
		_pos++;
		while (peek() != '>'.code) {
			final arg: Null<FactsType> = type();
			if (arg == null) return null;
			args.push(arg);
			if (peek() == ','.code) _pos++;
		}
		return take('>') ? Named(name, args) : null;
	}

	/** The dotted identifier run at `_pos`, consumed. */
	private function path(): String {
		final start: Int = _pos;
		while (_pos < _text.length) {
			final c: Int = _text.fastCodeAt(_pos);
			if (
				!(
					c == '.'.code || c == '_'.code || (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code)
					|| (c >= '0'.code && c <= '9'.code)
				)
			)
				break;
			_pos++;
		}
		return _text.substring(start, _pos);
	}

	/** Whether the character at `at` ends an argument: a separator, the closing parenthesis, or the end. */
	private function separatorAt(at: Int): Bool {
		final c: Int = at < _text.length ? _text.fastCodeAt(at) : -1;
		return c == ','.code || c == ')'.code || c == -1;
	}

	private function take(token: String): Bool {
		if (_text.substr(_pos, token.length) != token) return false;
		_pos += token.length;
		return true;
	}

	private function peek(): Int {
		return _pos < _text.length ? _text.fastCodeAt(_pos) : -1;
	}

}
