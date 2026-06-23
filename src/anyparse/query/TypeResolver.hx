package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import anyparse.query.RefactorSupport.TypeDeclMatch;

/**
 * Minimal type-aware purity resolution for the analysis layer. Recovers a
 * `recv.field` receiver's declared type — via a `TypeInfoProvider`'s
 * decl-span→type-name map + the `SymbolIndex` — to decide whether the field
 * read is provably side-effect-free.
 *
 * MVP scope (getter-purity for `unused-local`): only an **anonymous-struct**
 * receiver is resolved — its fields can never be property getters, so the read
 * has no side effect. Every other receiver (`this`, a class/abstract value, an
 * un-annotated or parametric local, a complex expression) returns `false` —
 * the caller keeps its conservative default. The result is therefore strictly
 * additive: it can only newly classify a read as safe, never wrongly.
 */
@:nullSafety(Strict)
final class TypeResolver {

	private function new() {}

	/**
	 * True when `faNode` (a field-access node) is a provably side-effect-free read.
	 * Three resolved receivers: an anonymous-struct value (fields can't be getters);
	 * a local/param of a class/abstract type whose member `field` is a plain member;
	 * and `this`, against the enclosing type's members. Any unresolved receiver, a
	 * getter property, or a field that is not a known direct member returns false —
	 * the caller keeps its conservative default.
	 */
	public static function isPlainFieldRead(
		faNode: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: SymbolIndex
	): Bool {
		if (faNode.children.length != 1) return false;
		final field: Null<String> = faNode.name;
		if (field == null) return false;
		final recv: QueryNode = faNode.children[0];
		final identKind: Null<String> = shape.identKind;
		if (identKind == null || recv.kind != identKind) return false;
		final recvName: Null<String> = recv.name;
		final recvSpan: Null<Span> = recv.span;
		if (recvName == null || recvSpan == null) return false;
		if (recvName == shape.selfReferenceText) {
			final lookSpan: Span = faNode.span ?? recvSpan;
			final enclosing: Null<String> = enclosingTypeName(tree, lookSpan);
			return enclosing != null && index.memberGetter(enclosing, field) == false;
		}
		final bindingFrom: Null<Int> = resolveBindingFrom(recvName, recvSpan, tree, shape);
		if (bindingFrom == null) return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		if (index.isAnonStructType(typeName)) return true;
		return index.memberGetter(typeName, field) == false;
	}

	/** The simple name of the innermost type declaration whose span contains `faSpan`, or null. */
	private static function enclosingTypeName(tree: QueryNode, faSpan: Span): Null<String> {
		var best: Null<TypeDeclMatch> = null;
		function walk(n: QueryNode): Void {
			final td: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(n);
			if (td != null && td.fullSpan.from <= faSpan.from && faSpan.to <= td.fullSpan.to) {
				final width: Int = td.fullSpan.to - td.fullSpan.from;
				final b: Null<TypeDeclMatch> = best;
				if (b == null || width < b.fullSpan.to - b.fullSpan.from) best = td;
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		final b: Null<TypeDeclMatch> = best;
		return b == null ? null : b.name;
	}

	/**
	 * The binding-span `from` the receiver occurrence at `recvSpan` resolves to,
	 * via the scope resolver — the key into a `TypeInfoProvider` decl-type map.
	 */
	public static function resolveBindingFrom(name: String, recvSpan: Span, tree: QueryNode, shape: RefShape): Null<Int> {
		for (hit in Refs.find(name, tree, shape)) {
			final hs: Null<Span> = hit.span;
			if (hs != null && hs.from == recvSpan.from && hs.to == recvSpan.to) {
				final b: Null<Span> = hit.bindingSpan;
				return b == null ? null : b.from;
			}
		}
		return null;
	}

}
