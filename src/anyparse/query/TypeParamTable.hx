package anyparse.query;

import anyparse.query.SymbolIndex.TypeDeclInfo;

/**
 * The type parameters every indexed type declares, and the type arguments its `extends` / `implements`
 * clauses pass to its supertypes' parameters — what a `CallGraph` needs to see a member declared with a
 * parameter as the type a particular value holds.
 */
@:nullSafety(Strict)
final class TypeParamTable {

	/** Type name -> the type parameters its declarations declare. */
	private final _typeParams: Map<String, Array<String>> = [];

	/** Type name -> its `extends` / `implements` targets as written, type arguments included. */
	private final _supersWritten: Map<String, Array<String>> = [];

	public function new() {}

	/** Whether `typeName` declares the type parameter `name`. */
	public inline function declaresTypeParam(typeName: String, name: String): Bool {
		return (_typeParams[typeName] ?? []).contains(name);
	}

	/** The type parameters `typeName` declares, in order. */
	public inline function typeParamsOf(typeName: String): Array<String> {
		return _typeParams[typeName] ?? [];
	}

	/**
	 * The type arguments `viewType`'s `extends` / `implements` chain passes to `owner`'s parameters, written in
	 * `viewType`'s own terms (`class D extends B<W>` passes `W`, `class M<X> extends B<X>` passes `X`), or null
	 * when `owner` is not on the chain or a link writes no arguments.
	 */
	public function argumentsFor(owner: String, viewType: String, typeSyntax: String -> Null<TypeSyntax>): Null<Array<String>> {
		return argumentsVia(owner, viewType, [], typeSyntax);
	}

	/** Fold the parameters and the written supertypes of one declaration — a later one of the same name unions. */
	public function record(t: TypeDeclInfo): Void {
		CallGraphTypes.unionInto(_typeParams, t.name, t.typeParamNames);
		CallGraphTypes.unionInto(_supersWritten, t.name, t.supertypesWritten);
	}

	private function argumentsVia(
		owner: String, typeName: String, seen: Array<String>, typeSyntax: String -> Null<TypeSyntax>
	): Null<Array<String>> {
		if (seen.contains(typeName)) return null;
		seen.push(typeName);
		for (written in _supersWritten[typeName] ?? []) {
			final outer: Null<String> = NominalTypes.outerNominalOf(written);
			final args: Array<String> = NominalTypes.typeArgumentSourcesOf(written, typeSyntax) ?? [];
			if (outer == owner) return args;
			final up: Null<Array<String>> = outer == null ? null : argumentsVia(owner, outer, seen, typeSyntax);
			final params: Array<String> = outer == null ? [] : typeParamsOf(outer);
			if (up != null && args.length >= params.length) return [for (a in up) CallGraphNames.substituteTypeParams(a, params, args)];
		}
		return null;
	}

}
