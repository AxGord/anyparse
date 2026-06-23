package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

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
	 * True when `faNode` (a field-access node) reads a field of an
	 * anonymous-struct-typed receiver — a provably side-effect-free access.
	 * `tree` is the file's parse tree, `shape` the grammar's RefShape,
	 * `declaredTypes` the decl-span→type-name map, `index` the symbol index.
	 */
	public static function isAnonStructFieldAccess(
		faNode: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: SymbolIndex
	): Bool {
		if (faNode.children.length != 1) return false;
		final recv: QueryNode = faNode.children[0];
		final identKind: Null<String> = shape.identKind;
		if (identKind == null || recv.kind != identKind) return false;
		final recvName: Null<String> = recv.name;
		final recvSpan: Null<Span> = recv.span;
		if (recvName == null || recvSpan == null) return false;
		// `this` (and any non-local receiver) is out of MVP scope.
		if (recvName == shape.selfReferenceText) return false;
		final bindingFrom: Null<Int> = resolveBindingFrom(recvName, recvSpan, tree, shape);
		if (bindingFrom == null) return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		return index.isAnonStructType(typeName);
	}

	/**
	 * The binding-span `from` the receiver occurrence at `recvSpan` resolves to,
	 * via the scope resolver — the key into a `TypeInfoProvider` decl-type map.
	 */
	private static function resolveBindingFrom(name: String, recvSpan: Span, tree: QueryNode, shape: RefShape): Null<Int> {
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
