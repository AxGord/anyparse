package anyparse.grammar.json;

/**
	Helper operations on `JValue`.

	In particular, a deep structural equality function that test code uses
	for round-trip assertions. Haxe's `==` on enums with array arguments
	does not recurse into arrays, so we provide an explicit walker.
**/
class JValueTools {

	/** One entry of an object. */
	public static inline function entry(key: String, value: JValue): JEntry {
		return { key: key, value: value };
	}

	/**
	 * The value at `key` of `value`: null for anything but an object, for a key it does not hold and for a key holding
	 * `null`, which reads as an absent one everywhere a document is read (`docs/formats.md`). A key given twice reads as
	 * its last.
	 */
	public static function field(value: Null<JValue>, key: String): Null<JValue> {
		return switch value {
			case JObject(entries):
				var found: Null<JValue> = null;
				for (entry in entries) if (entry.key == key) found = switch entry.value {
					case JNull: null;
					case held: held;
				};
				found;
			case _: null;
		}
	}

	/**
	 * The value at the dotted `path` of `value`: each segment a key of an object, read as `field` reads it, or the decimal
	 * index of an array element; null where a step finds nothing, and for a `null` element as for a `null` key. An empty path
	 * names `value` itself; a key holding a dot is read with `field`.
	 */
	public static function at(value: Null<JValue>, path: String): Null<JValue> {
		if (path == '') return value;
		var here: Null<JValue> = value;
		for (segment in path.split('.')) {
			here = switch here {
				case JArray(items):
					final index: Null<Int> = Std.parseInt(segment);
					index == null || '$index' != segment || index < 0 || index >= items.length
						? null
						: switch items[index] {
							case JNull: null;
							case held: held;
						};
				case _: field(here, segment);
			}
			if (here == null) return null;
		}
		return here;
	}

	/** Deep structural equality of two `JValue`s. **/
	public static function equals(a: JValue, b: JValue): Bool {
		return switch [a, b] {
			case [JNull, JNull]: true;
			case [JBool(x), JBool(y)]: x == y;
			case [JNumber(x), JNumber(y)]:
				// NaN handling: NaN != NaN is fine for JSON; a JNumber round-trip
				// should never produce NaN because the writer maps it to null.
				x == y;
			case [JString(x), JString(y)]: x == y;
			case [JArray(xs), JArray(ys)]:
				if (xs.length != ys.length) {
					false;
				} else {
					var eq: Bool = true;
					for (i in 0...xs.length) {
						if (!equals(xs[i], ys[i])) {
							eq = false;
							break;
						}
					}
					eq;
				}
			case [JObject(xs), JObject(ys)]:
				if (xs.length != ys.length) {
					false;
				} else {
					var eq: Bool = true;
					for (i in 0...xs.length) {
						if (xs[i].key != ys[i].key || !equals(xs[i].value, ys[i].value)) {
							eq = false;
							break;
						}
					}
					eq;
				}
			case _: false;
		}
	}

}
