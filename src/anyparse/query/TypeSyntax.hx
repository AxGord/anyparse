package anyparse.query;

import anyparse.runtime.Span;

using Lambda;

/**
 * A written type as its grammar reads it (`GrammarPlugin.typeSyntax`): the parts an analysis
 * asks of type text, with the verbatim slice and the offsets of every part, so a consumer can hand
 * a part on as text or edit the source at it. Grammar-neutral — the plugin decides what its syntax
 * means, a consumer only reads the answer.
 *
 * Redundant parentheses are transparent: `(Int)` answers the shape of `Int`, with the span and
 * text of the whole parenthesised spelling.
 */
@:nullSafety(Strict)
final class TypeSyntax {

	/** Where this type stands in the text that was read. */
	public final span: Span;

	/** The verbatim slice `span` covers. */
	public final text: String;

	public final shape: TypeShape;

	public function new(span: Span, text: String, shape: TypeShape) {
		this.span = span;
		this.text = text;
		this.shape = shape;
	}

	/**
	 * The verbatim type arguments of a named type — `Map<String, Array<Int>>` → `String`,
	 * `Array<Int>` — or null for any other shape. A named type written without arguments answers
	 * the empty list.
	 */
	public function argumentTexts(): Null<Array<String>> {
		return switch shape {
			case Nominal(_, args): [for (a in args) a.text];
			case _: null;
		};
	}

	/** This type and every type written inside it — arguments, parameters, results, field types — outermost first. */
	public function descendants(): Array<TypeSyntax> {
		final inner: Array<TypeSyntax> = switch shape {
			case Nominal(_, args): args;
			case Function(params, ret, _): [for (p in params) p.type].concat([ret]);
			case Structure(fields): [for (f in fields) f.type];
			case Other: [];
		};
		return [this].concat([for (t in inner) for (d in t.descendants()) d]);
	}

	/** Whether this type is a function type or holds one anywhere inside it (`Array<Int -> Void>`). */
	public function holdsFunction(): Bool {
		return switch shape {
			case Function(_, _, _): true;
			case Nominal(_, args): args.exists(a -> a.holdsFunction());
			case Structure(fields): fields.exists(f -> f.type.holdsFunction());
			case Other: false;
		};
	}

	/**
	 * The one argument of a named type whose path is one of `wrappers` (`Null<T>` → `T`), or null
	 * when this is not such a wrapper of exactly one argument.
	 */
	public function wrapped(wrappers: Array<String>): Null<TypeSyntax> {
		return switch shape {
			case Nominal(path, [arg]) if (wrappers.contains(path)): arg;
			case _: null;
		};
	}

}

/** `GrammarPlugin.typeSyntax` as a value — how code that holds no plugin reads a written type. */
typedef TypeSyntaxReader = String -> Null<TypeSyntax>;

/** What a `TypeSyntax` is. */
enum TypeShape {

	/** A named type: its `path` as written (`pkg.Map`) and its type arguments in order. */
	Nominal(path: String, args: Array<TypeSyntax>);

	/**
	 * A function type: its parameters, its result, and whether it was spelled in the curried arrow
	 * form (`A -> B -> R`, every arrow of the chain one parameter) rather than with a parenthesised
	 * parameter list (`(a: A, B) -> R`). The curried form lists what it spells — `Void -> R` has the
	 * one parameter `Void` — and leaves its meaning to the consumer.
	 */
	Function(params: Array<TypeParam>, ret: TypeSyntax, curried: Bool);

	/** An anonymous structure type, its typed fields in order. */
	Structure(fields: Array<TypeField>);

	/** A type this model does not break down: a macro splice, a conditional region, a constant, an intersection. */
	Other;

}

/** One parameter of a function type: its name when it has one, whether it is optional, and its type. */
typedef TypeParam = {
	var name: Null<String>;
	var optional: Bool;
	var type: TypeSyntax;
}

/** One typed field of a structure type. */
typedef TypeField = {
	var name: String;
	var optional: Bool;
	var type: TypeSyntax;
}
