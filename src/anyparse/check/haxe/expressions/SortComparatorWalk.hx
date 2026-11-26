package anyparse.check.haxe.expressions;

/** The node kinds that spell a `<receiver>.sort(...)` call and its callback parameters. */
typedef SortKinds = {
	final callKind: String;
	final fieldAccessKind: String;
	final lambdaKinds: Array<String>;
	final paramKinds: Array<String>;
}

/**
	The one answer to "where does a rule find the callbacks of `xs.sort(...)`, and what is the element type of its receiver":
	the walk over the arguments of every sort call, the test of a two-parameter callback, and the element resolver.
**/
final class SortComparatorWalk {

	/** A callback of this many parameters is a comparator. */
	public static inline final COMPARATOR_PARAMS: Int = 2;

	/** The method whose callback is read for its sign only. */
	private static final SORT: String = 'sort';

	/**
	 * Calls `visit(callee, arg)` for every argument of every `<receiver>.sort(...)`
	 * call under `tree`, a call's arguments before the calls inside them.
	 */
	public static function each(tree: QueryNode, kinds: SortKinds, visit: (callee: QueryNode, arg: QueryNode) -> Void): Void {
		final callee: Null<QueryNode> = tree.children[0];
		if (tree.kind == kinds.callKind && callee != null && callee.kind == kinds.fieldAccessKind && callee.name == SORT)
			for (arg in tree.children.slice(1)) visit(callee, arg);
		for (c in tree.children) each(c, kinds, visit);
	}

	/** Whether `node` is a function literal of exactly two parameters. */
	public static function isComparator(node: QueryNode, kinds: SortKinds): Bool {
		return kinds.lambdaKinds.contains(node.kind) && node.children.count(c -> kinds.paramKinds.contains(c.kind)) == COMPARATOR_PARAMS;
	}

	/** The bare type name of the elements of a receiver, as `written` answers its type: `Null<T>` elements answer `Null`, never `T`. */
	public static function elementResolver(
		written: (QueryNode) -> Null<String>, shape: RefShape, plugin: GrammarPlugin
	): (QueryNode) -> Null<String> {
		final params: Map<String, Int> = shape.indexedElementTypeParams ?? [];
		return receiver -> {
			final source: Null<String> = written(receiver);
			final element: Null<String> = source == null ? null : NominalTypes.elementTypeSourceOf(source, params, [], plugin.typeSyntax);
			return element == null ? null : NominalTypes.outerNominalOf(element, plugin.typeSyntax);
		};
	}

	/** The kinds a `<receiver>.sort(...)` walk reads, or null where the grammar names no call, field access, lambda or parameter. */
	public static function kindsOf(shape: RefShape): Null<SortKinds> {
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final lambdaKinds: Null<Array<String>> = shape.lambdaKinds;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		return callKind == null || fieldAccessKind == null || lambdaKinds == null || paramKinds == null ? null : {
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			lambdaKinds: lambdaKinds,
			paramKinds: paramKinds
		};
	}

}
