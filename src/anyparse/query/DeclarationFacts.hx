package anyparse.query;

using Lambda;

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

	/** File + type name (`boundsKey`) -> type parameter -> the written sources of its bounds, as that declaration writes them. */
	public final typeBounds: Map<String, Map<String, Array<String>>> = [];

	/** Function node id -> its parameters' written types, `null` where one carries none. */
	public final paramTypes: Map<String, Array<Null<String>>> = [];

	/** The function node ids whose last parameter is a rest parameter, which takes every argument from its position on. */
	public final restParams: Map<String, Bool> = [];

	/**
	 * Function node id -> the position of its first parameter a call may skip (an optional one, or one with a default value) —
	 * every parameter of an external one, whose declaration does not say — and how many parameters it declares; absent when
	 * it declares none a call may skip (`CallGraphKeys.mayShift`).
	 */
	public final skippable: Map<String, { from: Int, count: Int }> = [];

	/**
	 * The function node ids a declaration of which offers other signatures (`@:overload`) whose RETURN type differs from its
	 * own, and those whose PARAMETERS differ: a call may select any of them, so the declared one types neither (review R5 F6).
	 */
	public final overloadedReturns: Map<String, Bool> = [];

	public final overloadedParams: Map<String, Bool> = [];

	public function new() {}

	/** Drop every fact about the function node `id`, whose declaration left the graph. */
	public function forget(id: String): Void {
		returns.remove(id);
		returnSources.remove(id);
		typeParams.remove(id);
		typeParamBounds.remove(id);
		paramTypes.remove(id);
		restParams.remove(id);
		skippable.remove(id);
		overloadedReturns.remove(id);
		overloadedParams.remove(id);
	}

	/** The key of `typeName`'s parameter bounds as the declaration in `file` writes them — two types may share a simple name. */
	public static inline function boundsKey(file: String, typeName: String): String {
		return '${CallGraphNames.normalizePath(file)}#$typeName';
	}

	/**
	 * Keep `value` as the fact `facts` holds for the node `id` when `first` — its first declaration — and, for a further
	 * declaration, only while that spells the same: a fact two declarations of one node disagree on is none.
	 */
	public static function settle(facts: Map<String, String>, id: String, value: Null<String>, first: Bool): Void {
		if (first) {
			if (value != null) facts[id] = value;
		} else if (facts[id] != value) {
			facts.remove(id);
		}
	}

	/** Whether two declarations bound their type parameters alike: the same parameters, each with the same written bounds. */
	public static function sameBounds(a: Null<Map<String, Array<String>>>, b: Null<Map<String, Array<String>>>): Bool {
		if (a == null || b == null) return a == b;
		for (name => written in a) if (!b.exists(name) || (b[name] ?? []).join('\n') != written.join('\n')) return false;
		for (name in b.keys()) if (!a.exists(name)) return false;
		return true;
	}

}
