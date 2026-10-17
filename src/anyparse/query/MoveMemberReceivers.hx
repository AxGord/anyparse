package anyparse.query;

import anyparse.check.CheckScan;
import anyparse.query.MoveMember.MovePrep;
import anyparse.query.MoveMember.MovedMember;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * The receiver-qualified callers of the instance members a `move-member` moves (`g.x()`, `this.x`), each classified
 * by its receiver's type: routed through the field of the source that holds the destination, left alone as another
 * type's member, or refused as unprovable (`collectReceiverHits`).
 */
@:nullSafety(Strict)
final class MoveMemberReceivers {

	/** `receiverVerdict`: the access is the moved member's and goes through the via field. */
	private static inline final ROUTE: String = 'route';

	/** `receiverVerdict`: the access is provably another member's, or a static one. */
	private static inline final LEAVE: String = 'leave';

	/**
	 * Every receiver-qualified access to a moved INSTANCE member across the scope — `g.x()` where `g` holds the source
	 * type — or the refusal naming the first one it cannot classify. The bare callers inside the source are rewired
	 * through the via field; these were left alone ("they fail the next compile loudly"), which left a split with a
	 * nested object (`_g.x()` -> `_g.library.x()`) to be finished by hand, call site by call site.
	 *
	 * Positive and fail-closed, per access: a receiver typed (`NominalTypes.expressionTypeNominal`) as the source type —
	 * declared once in scope — or a subtype of it, which inherits the via field, is routed through it; one provably
	 * unrelated (an in-scope CLASS or INTERFACE outside the source's subtree, or a standard-library type declaring a
	 * member of that name) is someone else's member and is left alone; a type-namespace receiver is a static access and
	 * not this member's; anything else — an untyped receiver, `Dynamic`, a type parameter, a structure (a `G` unifies
	 * with one declaring its members), an abstract or `enum abstract` (whose `@:forward` reaches the source's members),
	 * `super`, a null-safe access — refuses the move.
	 */
	public static function collectReceiverHits(prep: MovePrep, plugin: GrammarPlugin): { error: Null<String>, hits: Array<ReceiverHit> } {
		final instance: Array<MovedMember> = prep.moved.filter(m -> !m.isStatic);
		final hits: Array<ReceiverHit> = [];
		if (instance.length == 0) return { error: null, hits: hits };

		final srcUnique: Bool = [
			for (fi in prep.index.allFiles()) for (t in fi.types) if (t.name == prep.srcTypeName) t
		].length
			== 1;
		final accessKinds: Array<String> = ShapeVocab.memberAccessKinds(prep.shape);
		for (file => tree in prep.trees) {
			final source: String = prep.sourceOf[file] ?? '';
			if (!instance.exists(m -> source.indexOf(m.name) >= 0)) continue;
			// The checks' own typing door, over the move's scope index: a construction, a call chain's return and a `using`
			// extension type a receiver as they do for every rule.
			final typeOf: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(
				source, plugin, tree, file, prep.index, true, false
			);
			if (typeOf == null)
				return { error: 'the grammar types no receiver, so a receiver-qualified caller cannot be routed', hits: [] };
			final error: Null<String> = receiverHitsIn(prep, plugin, file, tree, source, typeOf, instance, accessKinds, srcUnique, hits);
			if (error != null) return { error: error, hits: [] };
		}
		return { error: null, hits: hits };
	}

	/** `collectReceiverHits` over one scope file: fills `hits`, or returns the refusal for the first unclassifiable access. */
	@:access(anyparse.query.MoveMember)
	private static function receiverHitsIn(
		prep: MovePrep, plugin: GrammarPlugin, file: String, tree: QueryNode, source: String, typeOf: (QueryNode) -> Null<String>,
		instance: Array<MovedMember>, accessKinds: Array<String>, srcUnique: Bool, hits: Array<ReceiverHit>
	): Null<String> {
		final inSource: Bool = file == prep.srcFile;
		function walk(node: QueryNode): Null<String> {
			final span: Null<Span> = node.span;
			final m: Null<MovedMember> = instance.find(mm -> mm.name == node.name);
			if (m != null && span != null && accessKinds.contains(node.kind) && node.children.length > 0) {
				final verdict: Null<String> = receiverVerdict(prep, plugin, tree, node, typeOf, srcUnique);
				if (verdict == ROUTE) {
					final srcSpan: Span = prep.srcDecl.fullSpan;
					// Re-bound: Strict does not carry a narrowed local into an anonymous struct literal.
					final mNN: MovedMember = m;
					hits.push({
						m: mNN,
						file: file,
						at: span.to - m.name.length,
						outsideType: !inSource || span.from < srcSpan.from || span.from >= srcSpan.to,
						inCut: inSource && MoveMember.insideAnyCut(prep, span.from)
					});
				} else if (verdict != LEAVE) {
					final at: Position = span.lineCol(source);
					return 'cannot route `${source.substring(span.from, span.to)}` at $file:${at.line}:${at.col} through the via field: '
						+ verdict;
				}
			}
			for (c in node.children) {
				final error: Null<String> = walk(c);
				if (error != null) return error;
			}
			return null;
		}
		return walk(tree);
	}

	/**
	 * What one member access `node` named like a moved instance member is (`collectReceiverHits`): `ROUTE`, `LEAVE`, or
	 * the reason it cannot be told.
	 */
	private static function receiverVerdict(
		prep: MovePrep, plugin: GrammarPlugin, tree: QueryNode, node: QueryNode, typeOf: (QueryNode) -> Null<String>, srcUnique: Bool
	): String {
		final recv: QueryNode = node.children[0];
		if (node.kind != MemberKinds.FIELD_ACCESS_KIND) return 'a null-safe or other non-plain access';
		if (recv.kind == MemberKinds.IDENT_EXPR_KIND && recv.name == 'super') return '`super` names no field that holds the via field';
		final path: Null<Array<String>> = NominalTypes.pathOf(recv, MemberKinds.IDENT_EXPR_KIND, MemberKinds.FIELD_ACCESS_KIND);
		final root: Null<QueryNode> = rootOf(recv);
		if (
			path != null && root != null && root.name != 'this' && SourceText.isUpperInitial(path[path.length - 1])
			&& TypeResolver.identBindingFrom(root, tree, prep.shape) == null
		)
			return LEAVE;
		final type: Null<String> = try typeOf(recv) catch (exception: Exception) null;
		if (type == null) return 'its receiver\'s type is not known';
		if (type == prep.srcTypeName || prep.index.subtypes.isSubtype(type, prep.srcTypeName))
			return srcUnique ? ROUTE : 'more than one type in scope is named "${prep.srcTypeName}"';
		if (classOrInterface(prep, type) && prep.index.subtypes.provablyNotSubtype(type, prep.srcTypeName)) return LEAVE;
		if (StdTypes.memberOf(plugin, type, node.name ?? '') != null) return LEAVE;
		return 'its receiver is a "$type", which is not provably unrelated to "${prep.srcTypeName}"';
	}

	/** The leftmost node of a receiver chain — the identifier a path starts from. */
	private static function rootOf(node: QueryNode): Null<QueryNode> {
		var at: QueryNode = node;
		while (at.kind == MemberKinds.FIELD_ACCESS_KIND && at.children.length > 0) at = at.children[0];
		return at.kind == MemberKinds.IDENT_EXPR_KIND ? at : null;
	}

	/**
	 * Whether `type` names exactly one class or interface of the scope: the only kinds whose members are their own, so that
	 * a provably unrelated one cannot be reaching the source's member. An abstract (`@:forward`, `@:to`) and an `enum
	 * abstract` reach another type's members, and a structure is unified with any class declaring its fields — a `G` value
	 * can be held in either, and a `G` member read through it.
	 */
	private static function classOrInterface(prep: MovePrep, type: String): Bool {
		final kinds: Array<String> = (prep.shape.classDeclKinds ?? []).concat(prep.shape.interfaceDeclKinds ?? []);
		final decls: Array<TypeDeclInfo> = prep.index.refs.declsNamed(type);
		return decls.length == 1 && kinds.contains(decls[0].kind);
	}

}

/**
 * One RECEIVER-qualified access to a moved INSTANCE member (`g.x()`, `this.x`) whose receiver is provably the source
 * type: `at` is where the member name starts — the via field's `via.` goes there — and `outsideType` says whether the
 * access sits outside the source type, where the via field must be public to be reached. `inCut`: the access is inside a
 * moved body, so its edit travels with the moved text.
 */
typedef ReceiverHit = {
	var m: MovedMember;
	var file: String;
	var at: Int;
	var outsideType: Bool;
	var inCut: Bool;
}
