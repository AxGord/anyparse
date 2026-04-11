package anyparse.grammar.json;

import anyparse.runtime.Input;
import anyparse.runtime.StringInput;
import anyparse.runtime.Parser;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;

/**
 * Hand-written recursive-descent JSON parser, refactored onto the new
 * runtime types (`Input`, `Parser`, `ParseError`, `Span`).
 *
 * The parsing logic is intentionally the same as the Phase 0 version:
 * this is a validation that the runtime API is usable, not a rewrite.
 * The only differences are where state lives (on the `Parser` context
 * rather than private fields) and the error type thrown on failure.
 *
 * Remains hand-written in Phase 1 as a regression baseline — Phase 2
 * generates an equivalent parser from `JValue`'s type definition via
 * the `@:build` macro.
 */
@:nullSafety(Strict)
class JsonParser {

	private final _ctx:Parser;

	private function new(input:Input) {
		_ctx = new Parser(input);
	}

	private function parseValue():JValue {
		skipWs();
		if (_ctx.pos >= _ctx.input.length) {
			throw errorAt('unexpected end of input');
		}
		final c:Int = _ctx.input.charCodeAt(_ctx.pos);
		return switch c {
			case '{'.code: parseObject();
			case '['.code: parseArray();
			case '"'.code: JString(parseStringLit());
			case 't'.code | 'f'.code: parseBool();
			case 'n'.code: parseNullLit();
			case '-'.code: parseNumber();
			case v if (v >= '0'.code && v <= '9'.code): parseNumber();
			case _: throw errorAt('unexpected character: ${String.fromCharCode(c)}');
		}
	}

	private function parseObject():JValue {
		expect('{'.code);
		final entries:Array<JEntry> = [];
		skipWs();
		if (peek() != '}'.code) {
			while (true) {
				skipWs();
				final key:String = parseStringLit();
				skipWs();
				expect(':'.code);
				final value:JValue = parseValue();
				entries.push({key: key, value: value});
				skipWs();
				if (peek() != ','.code) break;
				_ctx.pos++; // consume ','
			}
		}
		skipWs();
		expect('}'.code);
		return JObject(entries);
	}

	private function parseArray():JValue {
		expect('['.code);
		final items:Array<JValue> = [];
		skipWs();
		if (peek() != ']'.code) {
			while (true) {
				items.push(parseValue());
				skipWs();
				if (peek() != ','.code) break;
				_ctx.pos++; // consume ','
			}
		}
		skipWs();
		expect(']'.code);
		return JArray(items);
	}

	private function parseStringLit():String {
		expect('"'.code);
		final buf:StringBuf = new StringBuf();
		while (_ctx.pos < _ctx.input.length) {
			final c:Int = _ctx.input.charCodeAt(_ctx.pos);
			if (c == '"'.code) {
				_ctx.pos++;
				return buf.toString();
			}
			if (c == '\\'.code) {
				_ctx.pos++;
				if (_ctx.pos >= _ctx.input.length) {
					throw errorAt('unterminated escape');
				}
				final esc:Int = _ctx.input.charCodeAt(_ctx.pos);
				_ctx.pos++;
				switch esc {
					case '"'.code: buf.addChar('"'.code);
					case '\\'.code: buf.addChar('\\'.code);
					case '/'.code: buf.addChar('/'.code);
					case 'n'.code: buf.addChar('\n'.code);
					case 'r'.code: buf.addChar('\r'.code);
					case 't'.code: buf.addChar('\t'.code);
					case 'b'.code: buf.addChar(0x08);
					case 'f'.code: buf.addChar(0x0C);
					case 'u'.code:
						if (_ctx.pos + 4 > _ctx.input.length) {
							throw errorAt('incomplete unicode escape');
						}
						final hex:String = _ctx.input.substring(_ctx.pos, _ctx.pos + 4);
						_ctx.pos += 4;
						final code:Null<Int> = Std.parseInt('0x$hex');
						if (code == null) {
							throw errorAtPos(_ctx.pos - 4, 'invalid unicode escape: $hex');
						}
						buf.addChar(code);
					case _:
						throw errorAtPos(_ctx.pos - 1, 'invalid escape: \\${String.fromCharCode(esc)}');
				}
			} else {
				buf.addChar(c);
				_ctx.pos++;
			}
		}
		throw errorAt('unterminated string');
	}

	private function parseNumber():JValue {
		final start:Int = _ctx.pos;
		if (peek() == '-'.code) _ctx.pos++;
		// integer part
		while (_ctx.pos < _ctx.input.length) {
			final c:Int = _ctx.input.charCodeAt(_ctx.pos);
			if (c >= '0'.code && c <= '9'.code) _ctx.pos++;
			else break;
		}
		// fractional part
		if (peek() == '.'.code) {
			_ctx.pos++;
			while (_ctx.pos < _ctx.input.length) {
				final c:Int = _ctx.input.charCodeAt(_ctx.pos);
				if (c >= '0'.code && c <= '9'.code) _ctx.pos++;
				else break;
			}
		}
		// exponent
		final ec:Int = peek();
		if (ec == 'e'.code || ec == 'E'.code) {
			_ctx.pos++;
			final s:Int = peek();
			if (s == '+'.code || s == '-'.code) _ctx.pos++;
			while (_ctx.pos < _ctx.input.length) {
				final cc:Int = _ctx.input.charCodeAt(_ctx.pos);
				if (cc >= '0'.code && cc <= '9'.code) _ctx.pos++;
				else break;
			}
		}
		final str:String = _ctx.input.substring(start, _ctx.pos);
		final num:Float = Std.parseFloat(str);
		if (Math.isNaN(num)) {
			throw errorAtPos(start, 'invalid number: $str');
		}
		return JNumber(num);
	}

	private function parseBool():JValue {
		if (match('true')) return JBool(true);
		if (match('false')) return JBool(false);
		throw errorAt('expected boolean');
	}

	private function parseNullLit():JValue {
		if (match('null')) return JNull;
		throw errorAt('expected null');
	}

	private function match(s:String):Bool {
		final len:Int = s.length;
		if (_ctx.pos + len > _ctx.input.length) return false;
		if (_ctx.input.substring(_ctx.pos, _ctx.pos + len) != s) return false;
		_ctx.pos += len;
		return true;
	}

	private inline function peek():Int {
		return _ctx.pos < _ctx.input.length ? _ctx.input.charCodeAt(_ctx.pos) : -1;
	}

	private inline function expect(c:Int):Void {
		if (peek() != c) {
			throw errorAt('expected "${String.fromCharCode(c)}"');
		}
		_ctx.pos++;
	}

	private function skipWs():Void {
		while (_ctx.pos < _ctx.input.length) {
			final c:Int = _ctx.input.charCodeAt(_ctx.pos);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
				_ctx.pos++;
			} else {
				break;
			}
		}
	}

	private inline function errorAt(message:String):ParseError {
		return new ParseError(new Span(_ctx.pos, _ctx.pos), message);
	}

	private inline function errorAtPos(pos:Int, message:String):ParseError {
		return new ParseError(new Span(pos, pos), message);
	}

	/** Parse a UTF-8 string as a JSON document. */
	public static function parse(source:String):JValue {
		final p:JsonParser = new JsonParser(new StringInput(source));
		final v:JValue = p.parseValue();
		p.skipWs();
		if (p._ctx.pos != p._ctx.input.length) {
			throw p.errorAt('trailing data after value');
		}
		return v;
	}
}
