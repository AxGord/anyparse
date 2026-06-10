package anyparse.query;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.runtime.Span;

/**
 * Type-reference walker for `apq uses`.
 *
 * Sister of `Refs` for the type-position axis: `Refs` resolves value /
 * identifier bindings (reads/writes/decls with lexical scope); `Uses`
 * resolves *type* occurrences — a field/var type annotation, an
 * enum-constructor parameter type, a type parameter. A type reference
 * has no shadowing semantics, so this walker is deliberately flat: a
 * pre-order traversal collecting every node whose `kind` is in
 * `TypeRefShape.typeRefKinds` and whose `name` slot equals the target.
 *
 * Only meaningful on a tree produced by
 * `GrammarPlugin.parseFileTypeRefs` — the default `parseFile` tree drops
 * type-position nodes by construction (so `ast`/`search`/`refs`/`meta`
 * stay byte-identical), and this walker would then find nothing.
 *
 * Nodes carrying a null `span` are skipped — without source coordinates
 * the result is not addressable (same rule as `Refs`).
 */
@:nullSafety(Strict)
final class Uses {

	/**
	 * Walk `tree` and return every type reference to `name` per
	 * `shape`. Hits are returned in pre-order traversal.
	 */
	public static function find(name: String, tree: QueryNode, shape: TypeRefShape): Array<UsesHit> {
		final out: Array<UsesHit> = [];
		walk(name, tree, shape, out);
		return out;
	}

	private static function walk(target: String, node: QueryNode, shape: TypeRefShape, out: Array<UsesHit>): Void {
		if (node.name == target && shape.typeRefKinds.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) out.push(new UsesHit(target, span));
		}
		for (c in node.children) walk(target, c, shape, out);
	}

}

/**
 * One type-reference site discovered by `Uses.find`. `name` is
 * redundant with the query target (the walker only emits matching
 * nodes) but is kept on the hit so renderers are driven by the hit
 * alone — mirrors `RefHit`.
 */
@:nullSafety(Strict)
final class UsesHit {

	public final name: String;
	public final span: Span;

	public function new(name: String, span: Span) {
		this.name = name;
		this.span = span;
	}

}
