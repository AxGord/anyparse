package anyparse.grammar.json;

import anyparse.format.WriteOptions;

/**
 * The native door `JsonFormat` declares: what a generated parser and writer call to read and write a document through the
 * engine's own JSON, where the format's `nativeTargets` names the target. A plain class, reached only by name from
 * `JsonFormat.nativeDoor`: the macro generates the calls, core names no JSON.
 *
 * A native parse hands back an untyped value, so `parse` is a claim until the generated shape check has walked it. A key
 * no object holds can still read as something of the object's prototype on js; such a value fails its check, and the
 * document goes to the byte-level parser, which is right.
 */
@:nullSafety(Strict)
final class JsonNative {

	/** A JSON document as raw values (an object, an array, a scalar, `null`); throws on anything else. */
	public static inline function parse(text: String): Any {
		return #if js js.Syntax.code('JSON.parse({0})', text) #else haxe.format.JsonParser.parse(text) #end;
	}

	public static inline function isObject(raw: Any): Bool {
		return #if js js.Syntax.code(
			'({0} !== null && typeof {0} == "object" && !Array.isArray({0}))', raw
		) #else raw != null && Reflect.isObject(raw) && !(raw is String) && !(raw is Array) #end;
	}

	public static inline function isArray(raw: Any): Bool {
		return #if js js.Syntax.code('Array.isArray({0})', raw) #else raw is Array #end;
	}

	public static inline function isString(raw: Any): Bool {
		return #if js js.Syntax.code('(typeof {0} == "string")', raw) #else raw is String #end;
	}

	public static inline function isBool(raw: Any): Bool {
		return #if js js.Syntax.code('(typeof {0} == "boolean")', raw) #else raw is Bool #end;
	}

	public static inline function isFloat(raw: Any): Bool {
		return #if js js.Syntax.code('(typeof {0} == "number")', raw) #else raw is Float #end;
	}

	/** Whether `raw` is a whole number in the 32-bit range; one outside it takes the byte-level parser's reading. */
	public static inline function isInt(raw: Any): Bool {
		return #if js js.Syntax.code('(({0} | 0) === {0})', raw) #else raw is Int #end;
	}

	/** The value of `key` on the object `raw`; null, or on js undefined, when it holds none. */
	public static inline function field(raw: Any, key: String): Null<Any> {
		return #if js js.Syntax.code('{0}[{1}]', raw, key) #else Reflect.field(raw, key) #end;
	}

	/** Whether the object `raw` holds `key`, a held `null` included. */
	public static inline function has(raw: Any, key: String): Bool {
		return #if js js.Syntax.code('({0}[{1}] !== undefined)', raw, key) #else Reflect.hasField(raw, key) #end;
	}

	public static inline function set(raw: Any, key: String, value: Any): Void {
		#if js
		js.Syntax.code('{0}[{1}] = {2}', raw, key, value);
		#else
		Reflect.setField(raw, key, value);
		#end
	}

	public static inline function keys(raw: Any): Array<String> {
		return #if js js.Syntax.code('Object.keys({0})', raw) #else Reflect.fields(raw) #end;
	}

	/** One JSON string, in `JsonText`'s bytes. */
	public static inline function quote(text: String): String {
		return JsonText.quote(text);
	}

	/** The compact text of a value a generated writer made for it: its keys as they stand, a key holding `absent` left out. */
	public static inline function stringify(value: Any): String {
		return #if js js.Syntax.code('JSON.stringify({0})', value) #else haxe.format.JsonPrinter.print(value) #end;
	}

	/** What a generated writer's value holds under a key the document leaves out. */
	public static inline function absent(): Null<Any> {
		return #if js js.Syntax.code('undefined') #else null #end;
	}

	/** Whether `options` asks for the compact document (`JsonFormat.compactWriteOptions`), not merely one at that width. */
	public static inline function isCompact(options: Null<WriteOptions>): Bool {
		return options == JsonFormat.instance.compactWriteOptions;
	}

	/** The string one JSON string literal spells, quotes included; throws on anything else. */
	public static function unquote(literal: String): String {
		final raw: Any = parse(literal);
		if (!isString(raw)) throw new haxe.Exception('not a JSON string: $literal');
		return raw;
	}

	/**
	 * `raw` as the format's universal value; null when it holds an object, whose key order and duplicate keys only the
	 * document's text still knows: the document then goes to the byte-level parser. A raw part that is a scalar or an array
	 * loses nothing.
	 */
	public static function value(raw: Any): Null<JValue> {
		if (raw == null) return JNull;
		if (isString(raw)) return JString((raw: String));
		if (isFloat(raw)) return JNumber((raw: Float));
		if (isBool(raw)) return JBool((raw: Bool));
		if (!isArray(raw)) return null;
		final items: Array<JValue> = [];
		final raws: Array<Any> = raw;
		for (item in raws) {
			final read: Null<JValue> = value(item);
			if (read == null) return null;
			items.push(read);
		}
		return JArray(items);
	}

	/**
	 * The string the object `text` holds under `key`; null when `text` is
	 * no object or `key` holds no string. Throws on text that is no JSON.
	 */
	public static function stringField(text: String, key: String): Null<String> {
		final raw: Any = parse(text);
		if (!isObject(raw)) return null;
		final held: Null<Any> = field(raw, key);
		return held != null && isString(held) ? (held: String) : null;
	}

}
