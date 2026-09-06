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
 * `TypeRefShape.typeRefKinds` and whose `name` slot answers the target — exactly,
 * or (opt-in, `includeQualified`) through the last segment of a dotted spelling.
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
	 *
	 * `includeQualified` widens the match to a QUALIFIED spelling of the same
	 * simple name. `pkg.Mod.T` reaches the tree as ONE node whose `name` is the
	 * whole dotted string, so an exact compare never sees it — and a deadness
	 * census built on that answer calls a live sub-module type dead (measured:
	 * eleven of them, deleted, `Type not found` in six modules). Report walkers
	 * (`uses` / `mentions` / `blast`) pass `true`.
	 *
	 * REWRITERS MUST NOT. Renaming `T` has to splice the last segment of
	 * `Mod.T`, never the whole path, and it must first prove the path resolves
	 * to THIS `T` rather than a same-named type elsewhere; `CrossRename` owns
	 * both (`RefactorSupport.qualifiedPaths` / `lastSegmentOffset`) and reads
	 * this walker for the plain-name arm only.
	 *
	 * A dotted `name` stays an exact compare either way — a query for `Mod.T`
	 * must not answer `Other.T`.
	 */
	public static function find(name: String, tree: QueryNode, shape: TypeRefShape, includeQualified: Bool = false): Array<UsesHit> {
		final out: Array<UsesHit> = [];
		walk(name, tree, shape, includeQualified, out);
		return out;
	}

	/**
	 * Whether a type-reference node spelled `nodeName` answers a query for
	 * `target`: exact always, the qualified tail only when the caller asked for
	 * it AND the query is itself a simple name.
	 */
	private static inline function matches(nodeName: String, target: String, includeQualified: Bool): Bool {
		return nodeName == target || (includeQualified && target.indexOf('.') < 0 && SourceText.lastSegment(nodeName) == target);
	}

	private static function walk(target: String, node: QueryNode, shape: TypeRefShape, includeQualified: Bool, out: Array<UsesHit>): Void {
		final name: Null<String> = node.name;
		if (name != null && matches(name, target, includeQualified) && shape.typeRefKinds.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) out.push(new UsesHit(name, span));
		}
		for (c in node.children) walk(target, c, shape, includeQualified, out);
	}

}

/**
 * One type-reference site discovered by `Uses.find`. `name` is the node's OWN
 * spelling, which equals the query target for a plain-name match and carries the
 * whole dotted path for a qualified one — so a renderer driven by the hit alone
 * (mirrors `RefHit`) shows the reader WHICH spelling was found.
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
