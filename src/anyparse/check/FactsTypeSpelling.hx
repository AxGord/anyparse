package anyparse.check;

import anyparse.check.Check.OracleType;

using StringTools;

/** The type parameters a spelled type may name: those of the type `owner` (an id) and of the method `method`. */
typedef TypeScope = {
	final owner: Null<String>;
	final method: Null<String>;
}

/**
 * A type in the facts type grammar (`TypedFactsProbe`) spelled as Haxe source: a recursive-descent reader of one type
 * string, `_failure` saying why it stopped. `spell` is the entry.
 */
@:nullSafety(Strict)
final class FactsTypeSpelling {

	private var _pos: Int = 0;
	private var _failure: Null<String> = null;

	private final _text: String;
	private final _scope: TypeScope;

	private function new(text: String, scope: TypeScope) {
		_text = text;
		_scope = scope;
	}

	/**
	 * `type` spelled as Haxe source — `(Int,?String)->Bool` as `(Int, ?String) -> Bool`, a type parameter `$pack.Box.T`
	 * as `pack.Box.T` — or `Declined` when no source can write it: an unknown anywhere in it, a type parameter `scope`
	 * does not hold (`inScope`), an abstract's statics (`Abstract<…>`) or implementation class.
	 */
	public static function spell(type: String, scope: TypeScope): OracleType {
		final reader: FactsTypeSpelling = new FactsTypeSpelling(type, scope);
		final spelled: Null<String> = reader.type();
		final failure: Null<String> = reader._failure;
		return if (failure != null)
			Declined(failure)
		else if (spelled == null || reader._pos != type.length)
			Declined(FactsTypeOracle.DECLINE_NO_FACT)
		else
			Typed(spelled);
	}

	/** Whether the type parameter `path` (`<owner>.<name>`) is one `scope` holds: its owner is the scope's type or method. */
	public static function inScope(path: String, scope: TypeScope): Bool {
		final dot: Int = path.lastIndexOf('.');
		final owner: String = dot < 0 ? '' : path.substr(0, dot);
		return owner != '' && (owner == scope.owner || owner == scope.method);
	}

	/** The type at `_pos`, spelled; null once `_failure` is set or the text is malformed. */
	public function type(): Null<String> {
		if (_failure != null || _pos >= _text.length) return null;
		return switch _text.fastCodeAt(_pos) {
			case '?'.code: fail(FactsTypeOracle.DECLINE_UNKNOWN);
			case '('.code: functionType();
			case '{'.code: structure();
			case '$'.code:
				_pos++;
				typeParameter(path());
			case _: nominal();
		};
	}

	private function functionType(): Null<String> {
		_pos++;
		final args: Array<String> = [];
		while (_failure == null && peek() != ')'.code) {
			var optional: String = '';
			if (peek() == '?'.code) {
				_pos++;
				// an optional argument prints `?T`; a lone `?` before a separator is an unknown argument
				if (peek() == ','.code || peek() == ')'.code) return fail(FactsTypeOracle.DECLINE_UNKNOWN);
				optional = '?';
			}
			final arg: Null<String> = type();
			if (arg == null) return null;
			args.push(optional + arg);
			if (peek() == ','.code) _pos++;
		}
		if (!take(')') || !take('->')) return null;
		final result: Null<String> = type();
		return result == null ? null : '(${args.join(', ')}) -> $result';
	}

	private function structure(): Null<String> {
		_pos++;
		final fields: Array<String> = [];
		while (_failure == null && peek() != '}'.code) {
			final optional: String = peek() == '?'.code ? '?' : '';
			_pos += optional.length;
			final name: String = path();
			if (name == '' || !take(':')) return null;
			final field: Null<String> = type();
			if (field == null) return null;
			fields.push('$optional$name:$field');
			if (peek() == ','.code) _pos++;
		}
		return take('}') ? '{${fields.join(', ')}}' : null;
	}

	private function typeParameter(path: String): Null<String> {
		return inScope(path, _scope) ? path : fail('its type names the type parameter `$path`, which is not in scope at the declaration');
	}

	private function nominal(): Null<String> {
		final name: String = path();
		if (name == '') return null;
		if (name == 'Abstract' || name.indexOf('_Impl_') >= 0) return fail(FactsTypeOracle.DECLINE_UNSPELLABLE);
		if (peek() != '<'.code) return name;
		_pos++;
		final args: Array<String> = [];
		while (_failure == null && peek() != '>'.code) {
			final arg: Null<String> = type();
			if (arg == null) return null;
			args.push(arg);
			if (peek() == ','.code) _pos++;
		}
		return take('>') ? '$name<${args.join(', ')}>' : null;
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

	private function take(token: String): Bool {
		if (_text.substr(_pos, token.length) != token) return false;
		_pos += token.length;
		return true;
	}

	private function peek(): Int {
		return _pos < _text.length ? _text.fastCodeAt(_pos) : -1;
	}

	private function fail(reason: String): Null<String> {
		if (_failure == null) _failure = reason;
		return null;
	}

}
