package unit.grammar;

import haxe.Json;

/**
 * A structural dump of a Mermaid AST value — enum ctors with their arguments, struct fields in name
 * order, arrays, strings JSON-quoted — so two ASTs compare by value at any depth. A struct field
 * holding null is left out, so an absent optional field and an explicit null compare equal.
 */
@:nullSafety(Strict)
final class MermaidAst {

	/** The dump of `value`. */
	public static function dump(value: Any): String {
		if (value == null) return 'null';
		return switch Type.typeof(value) {
			case TEnum(_):
				final params: Array<String> = Type.enumParameters(value).map(dump);
				Type.enumConstructor(value) + (params.length == 0 ? '' : '(' + params.join(', ') + ')');
			case TObject:
				final fields: Array<String> = Reflect.fields(value).filter(field -> Reflect.field(value, field) != null);
				fields.sort(Reflect.compare);
				'{' + fields.map(field -> '$field: ${dump(Reflect.field(value, field))}').join(', ') + '}';
			case TClass(String): Json.stringify(value);
			case TClass(Array): '[' + (value: Array<Any>).map(dump).join(', ') + ']';
			case _: Std.string(value);
		};
	}

}
