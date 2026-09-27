package anyparse.query;

/**
 * What a `CallGraph` reads off the declarations of the functions and abstracts it holds, keyed by function
 * node id or type name: the facts a receiver, an argument or a literal is typed with.
 */
@:nullSafety(Strict)
final class DeclarationFacts {

	/** Function node id -> the SIMPLE name of its DECLARED return type, for a receiver that is a call. */
	public final returns: Map<String, String> = [];

	/** Function node id -> the WRITTEN source of its declared return type (`Array<T>`), for an element of a call's result. */
	public final returnSources: Map<String, String> = [];

	/** Abstract type name -> the simple nominal of its underlying type, which `this` denotes inside it (null when unreadable). */
	public final abstracts: Map<String, Null<String>> = [];

	/** Function node id -> the type parameters the function itself declares, which name no indexed type. */
	public final typeParams: Map<String, Array<String>> = [];

	/** Function node id -> type parameter -> the written sources of its bounds (`<U:A & B>` -> `U` -> `['A', 'B']`). */
	public final typeParamBounds: Map<String, Map<String, Array<String>>> = [];

	/** Type name -> type parameter -> the written sources of its bounds, as the type's declaration in the graph writes them. */
	public final typeBounds: Map<String, Map<String, Array<String>>> = [];

	/** Function node id -> its parameters' written types, `null` where one carries none. */
	public final paramTypes: Map<String, Array<Null<String>>> = [];

	/** The function node ids whose last parameter is a rest parameter, which takes every argument from its position on. */
	public final restParams: Map<String, Bool> = [];

	public function new() {}

	/** Drop every fact about the function node `id`, whose declaration left the graph. */
	public function forget(id: String): Void {
		returns.remove(id);
		returnSources.remove(id);
		typeParams.remove(id);
		typeParamBounds.remove(id);
		paramTypes.remove(id);
		restParams.remove(id);
	}

}
