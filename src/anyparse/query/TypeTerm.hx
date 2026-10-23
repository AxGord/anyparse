package anyparse.query;

import anyparse.query.SymbolIndex.ResolvedType;

/**
 * A type as an inference reads it (`Monomorphs`, `InferencePolicy`): a written type taken apart into its head and its
 * type arguments, or a variable the inference binds. The heads are the cast graph's ends (`TypeEnd`), so a term and a
 * unification question speak one currency.
 */
enum TypeTerm {

	/** A variable of one inference (`Monomorphs`): a type parameter of the signature a call is typed against. */
	Mono(id: Int);

	/** The type `head` applied to `args` (none for a plain type), `text` its spelling where it is written. */
	Of(head: TypeEnd, args: Array<TypeTerm>, text: String);

	/**
	 * A type the term does not take apart — a function type, a structure, a type parameter of another scope —, spelled
	 * where it is written; `monos` the variables it mentions, which a unification through it cannot bind.
	 */
	Opaque(text: String, monos: Array<Int>);

}

/** One end of a unification question or of a cast edge, as the cast graph reads a type (`AbstractCasts`). */
enum TypeEnd {

	/** A declaration the index resolves — a class, an interface, an enum, an abstract — its plain aliases followed. */
	Declared(r: ResolvedType);

	/** A core value type (`RefShape.coreValueTypes`) by name, whether or not the index holds its declaration. */
	Core(name: String);

	/** The dynamic type written with no argument: every value unifies with it. */
	Dyn;

	/** A type the graph does not model: a type parameter, a type with arguments, a structure, a function, an unresolved name. */
	Open;

	/**
	 * A type parameter of the signature a call is matched against — `T` of `function f<T:Int>(x:T)` — which the call binds
	 * by unifying its arguments (`CallSelection`); every other reader takes it for `Open`.
	 */
	Param(name: String);

	/**
	 * A generic abstract applied to type arguments — `EitherType<String, Buffer>` — each an end the graph models: its
	 * clauses read with the arguments for its type parameters (`AbstractCasts.appliedGraph`, `apply_params`).
	 */
	Applied(r: ResolvedType, args: Array<TypeEnd>);

}
