package anyparse.grammar.haxe.glue;

using Lambda;

/**
 * The one answer to "how many items of a delimited list declare a type that carries type parameters" — the count the
 * `typeParamItemCount >= n` wrap condition compares against (`WrapListOptions.typeParamItemCount`).
 *
 * An item counts when a type reference with a `<…>` argument list sits anywhere in the type it declares: `Array<Int>`,
 * `Null<String>`, `Int->Array<Int>`, a nested anonymous type one of whose fields does, a `>Base<T>` extension. A function
 * type without one (`Int->Void`) does not, and neither does a `#if` group of items. Only declared types are read — a
 * default value, an initializer, a metadata argument or a method body is never walked, so `x:Int = new Map<K, V>()`
 * counts nothing.
 *
 * Reached from the writer lowering as the `typeParamItemCount` predicate (`HxAstPredLowering.typeParamItemCountField`).
 * Untyped input for the same reason as `HxComplexItems`: the plain and the trivia-synth node types both arrive here, the
 * latter with each Star element in its `{node: …}` wrapper, so the walk goes by constructor and field names.
 */
final class HxTypeParamItems {

	/** Depth ceiling of both walks; past it an item answers "no type parameters", the layout-preserving direction. */
	private static inline final MAX_DEPTH: Int = 64;

	/** How many of `elements` declare a type carrying type parameters. */
	public static function count(elements: Array<Any>): Int {
		return elements.count(element -> declares(element, 0));
	}

	/**
	 * Does the declaration `v` — a list element, an anonymous-type member, a parameter, a variable or a method signature —
	 * declare a type carrying type parameters. A struct is read through its `type`, `returnType` and `params` slots only.
	 */
	private static function declares(v: Null<Any>, depth: Int): Bool {
		if (v == null || depth > MAX_DEPTH) return false;
		if (Reflect.isEnumValue(v)) {
			final params: Array<Any> = Type.enumParameters(v);
			return switch Type.enumConstructor(v) {
				case 'Conditional': false;
				case 'ExtendsField': refHasParams(params[0]);
				case _: params.exists(param -> declares(param, depth + 1));
			};
		}
		if (Std.isOfType(v, String) || !Reflect.isObject(v)) return false;
		final node: Null<Any> = Reflect.field(v, 'node');
		if (node != null) return declares(node, depth + 1);
		final field: Null<Any> = Reflect.field(v, 'field');
		if (field != null) return declares(field, depth + 1);
		final sigParams: Null<Any> = Reflect.field(v, 'params');
		return carries(Reflect.field(v, 'type'), depth + 1)
			|| carries(Reflect.field(v, 'returnType'), depth + 1)
			|| (Std.isOfType(sigParams, Array) && (cast sigParams: Array<Any>).exists(param -> declares(param, depth + 1)));
	}

	/**
	 * Does the type `v` carry type parameters anywhere: a `Named` reference with a non-empty `<…>` list, at any depth of
	 * a function type, parentheses, an optional argument or a `#if` type. An anonymous type's members are declarations
	 * and go back through `declares`; an expression list type holds no type.
	 */
	private static function carries(v: Null<Any>, depth: Int): Bool {
		if (v == null || depth > MAX_DEPTH) return false;
		if (!Reflect.isEnumValue(v))
			return Std.isOfType(v, Array)
				? (cast v: Array<Any>).exists(item -> carries(item, depth + 1))
				: !Std.isOfType(v, String)
					&& Reflect.isObject(v)
					&& Reflect.fields(v).exists(name -> carries(Reflect.field(v, name), depth + 1));
		final params: Array<Any> = Type.enumParameters(v);
		return switch Type.enumConstructor(v) {
			case 'Named': refHasParams(params[0]);
			case 'Anon': (cast params[0]: Array<Any>).exists(member -> declares(member, depth + 1));
			case 'BracketExprListType': false;
			case _: params.exists(param -> carries(param, depth + 1));
		};
	}

	/** Does a type reference carry a non-empty `<…>` argument list. */
	private static function refHasParams(ref: Null<Any>): Bool {
		final args: Null<Any> = ref == null ? null : Reflect.field(ref, 'params');
		return Std.isOfType(args, Array) && (cast args: Array<Any>).length > 0;
	}

}
