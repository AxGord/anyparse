package devkit;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonFormat;

/**
 * The one answer to "how does a developer tool print a raw JSON document and read a key of one as plain Haxe values":
 * `print` spells a `JValue` the way `JSON.stringify` does — a whole number without a fraction, which `JValueWriter`
 * does not do and a typed reader of the document needs — and `string`, `text`, `strings` and `items` read a part of
 * it. A document of a known shape is a schema typedef instead (`docs/formats.md`).
 */
final class RawJson {

	/** `value` as text: on one line when `indent` is null, else one entry per line, each level `indent` deeper. */
	public static function print(value: JValue, ?indent: String): String {
		final out: StringBuf = new StringBuf();
		put(out, value, indent, '');
		return out.toString();
	}

	/** The string `value` is, null for any other value. */
	public static function string(value: Null<JValue>): Null<String> {
		return switch value {
			case JString(v): v;
			case _: null;
		}
	}

	/** The string, number or boolean `value` is as text, null for any other value. */
	public static function text(value: Null<JValue>): Null<String> {
		return switch value {
			case JString(v): v;
			case JNumber(v): Std.string(v);
			case JBool(v): Std.string(v);
			case _: null;
		}
	}

	/** The scalar `value` is as a one-item list, a list's scalar items as text, null for an absent `value`. */
	public static function strings(value: Null<JValue>): Null<Array<String>> {
		return switch value {
			case null: null;
			case JNull: null;
			case JArray(held): [for (item in held) text(item) ?? ''];
			case scalar: [text(scalar) ?? ''];
		}
	}

	/** The items of the array `value` is, none for any other value. */
	public static function items(value: Null<JValue>): Array<JValue> {
		return switch value {
			case JArray(held): held;
			case _: [];
		}
	}

	/** The string at `key` of `value`, null when it holds none. */
	public static function stringAt(value: Null<JValue>, key: String): Null<String> {
		return string(JValueTools.field(value, key));
	}

	/** Whether `value` is the boolean `true`. */
	public static function isTrue(value: Null<JValue>): Bool {
		return switch value {
			case JBool(v): v;
			case _: false;
		}
	}

	private static inline function lineBreak(out: StringBuf, indent: Null<String>, at: String): Void {
		if (indent != null) out.add('\n$at');
	}

	private static function put(out: StringBuf, value: JValue, indent: Null<String>, here: String): Void {
		switch value {
			case JNull:
				out.add('null');
			case JBool(v):
				out.add(v ? 'true' : 'false');
			case JNumber(v):
				out.add(Std.string(v));
			case JString(v):
				out.add(JsonFormat.instance.quote(v));
			case JArray(held):
				if (held.length == 0) {
					out.add('[]');
					return;
				}
				final inner: String = here + (indent ?? '');
				out.add('[');
				for (i => item in held) {
					out.add(i == 0 ? '' : ',');
					lineBreak(out, indent, inner);
					put(out, item, indent, inner);
				}
				lineBreak(out, indent, here);
				out.add(']');
			case JObject(entries):
				if (entries.length == 0) {
					out.add('{}');
					return;
				}
				final inner: String = here + (indent ?? '');
				out.add('{');
				for (i => entry in entries) {
					out.add(i == 0 ? '' : ',');
					lineBreak(out, indent, inner);
					out.add(JsonFormat.instance.quote(entry.key));
					out.add(indent == null ? ':' : ': ');
					put(out, entry.value, indent, inner);
				}
				lineBreak(out, indent, here);
				out.add('}');
		}
	}

}
