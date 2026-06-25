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

	/**
	 * The binding-span `from` that the identifier `ident` resolves to — the key
	 * into a `TypeInfoProvider` declared-type / cast map. Null when `ident` is not
	 * an identifier node or its binding is unresolved.
	 */
	public static function identBindingFrom(ident: QueryNode, tree: QueryNode, shape: RefShape): Null<Int> {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null || ident.kind != identKind) return null;
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		return name == null || span == null ? null : resolveBindingFrom(name, span, tree, shape);
	}

	/**
	 * The SIMPLE declared type name of the identifier `ident` — resolves its
	 * binding via the scope resolver and reads `declaredTypes`. Null when `ident`
	 * is not an identifier node, its binding is unresolved, or the binding has no
	 * recovered nominal type (unannotated, parametric, or `Null<…>`-wrapped — all
	 * absent from `declaredTypes`).
	 */
	public static function identTypeName(ident: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>): Null<String> {
		final bindingFrom: Null<Int> = identBindingFrom(ident, tree, shape);
		return bindingFrom == null ? null : declaredTypes[bindingFrom];
	}

	/**
	 * The fully-qualified form of a SIMPLE type reference `typeSrc` (already
	 * whitespace-stripped): a qualified path (`a.b.X`) is its own FQN; a bare name
	 * (`X`) resolves via `importMap` (a plain `import a.b.X;`). Returns null for
	 * anything that is not a plain nominal reference — a generic / function / anon
	 * type (any char outside `[A-Za-z0-9_.]`), or a bare name with no matching import.
	 * Lets a check compare two type spellings by identity rather than by text.
	 */
	public static function canonicalTypeName(typeSrc: String, importMap: Map<String, String>): Null<String> {
		for (i in 0...typeSrc.length) {
			final c: Int = StringTools.fastCodeAt(typeSrc, i);
			final ok: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code)
				|| c == '_'.code || c == '.'.code;
			if (!ok) return null;
		}
		return typeSrc.indexOf('.') != -1 ? typeSrc : importMap[typeSrc];
	}

	/**
	 * Whether the declaration binding at `bindingFrom` is an optional parameter
	 * (a node of kind `optionalParamKind` whose span covers it) — its value is
	 * nullable even though `declaredTypes` recorded a nominal type for it.
	 */
	public static function bindingIsOptionalParam(tree: QueryNode, bindingFrom: Int, optionalParamKind: String): Bool {
		var found: Bool = false;
		function walk(n: QueryNode): Void {
			if (found) return;
			if (n.kind == optionalParamKind) {
				final s: Null<Span> = n.span;
				if (s != null && s.from <= bindingFrom && bindingFrom < s.to) {
					found = true;
					return;
				}
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/**
	 * True when the innermost type declaration enclosing `span` is annotated with
	 * the `metaName` meta (e.g. `@:nullSafety`), making any non-`Null<…>` nominal
	 * member of it provably non-null. The meta binds to a declaration when no OTHER
	 * type declaration sits between the meta and that declaration — tolerant of
	 * intervening modifier keywords (`final` / `public` / …) which are not type
	 * decls. A meta carrying `disableArg` (`@:nullSafety(Off)`) does not count.
	 *
	 * Only the enclosing TYPE declaration's meta is consulted; a member-level
	 * `@:nullSafety(Off)` inside a null-safe type is not modeled — a rare,
	 * documented limitation.
	 */
	public static function enclosingIsNullSafe(tree: QueryNode, span: Span, metaName: String, disableArg: Null<String>): Bool {
		final decl: Null<TypeDeclMatch> = innermostTypeDecl(tree, span);
		if (decl == null) return false;
		return enclosingMetaPresent(tree, decl.fullSpan, metaName, disableArg);
	}

	/**
	 * Whether `operand` is a plain identifier resolvable to a provably non-null
	 * type — a `RefShape.nonNullableTypeNames` value type (null-safety-independent),
	 * or any recovered nominal type while the enclosing declaration is null-checked
	 * (`RefShape.nullSafetyMetaName`). An operand bound to an optional parameter, to a
	 * `RefShape.nullableWrapperTypeNames` type (`Null<…>` / `Dynamic` / `Any`), or with
	 * no recovered nominal type keeps the conservative default and is NOT proven
	 * non-null. Shared by every null-aware check (`unnecessary-null-check`,
	 * `redundant-null-coalescing`).
	 */
	public static function isProvablyNonNull(operand: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>): Bool {
		final bindingFrom: Null<Int> = identBindingFrom(operand, root, shape);
		if (bindingFrom == null) return false;
		final optionalParamKind: Null<String> = shape.optionalParamKind;
		if (optionalParamKind != null && bindingIsOptionalParam(root, bindingFrom, optionalParamKind)) return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		final nonNullableTypeNames: Array<String> = shape.nonNullableTypeNames ?? [];
		if (nonNullableTypeNames.contains(typeName)) return true;
		final nullableWrapperTypeNames: Array<String> = shape.nullableWrapperTypeNames ?? [];
		if (nullableWrapperTypeNames.contains(typeName)) return false;
		final nullSafetyMetaName: Null<String> = shape.nullSafetyMetaName;
		final opSpan: Null<Span> = operand.span;
		return nullSafetyMetaName != null && opSpan != null
			&& enclosingIsNullSafe(root, opSpan, nullSafetyMetaName, shape.nullSafetyDisableArg);
	}

	/** The innermost type declaration whose span contains `faSpan`, or null. */
	private static function innermostTypeDecl(tree: QueryNode, faSpan: Span): Null<TypeDeclMatch> {
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
		return best;
	}

	/** The simple name of the innermost type declaration whose span contains `faSpan`, or null. */
	private static function enclosingTypeName(tree: QueryNode, faSpan: Span): Null<String> {
		final td: Null<TypeDeclMatch> = innermostTypeDecl(tree, faSpan);
		return td == null ? null : td.name;
	}

	/**
	 * Whether a meta node named `metaName` binds to the type declaration at
	 * `declSpan` — its span ends at or before `declSpan.from` with no other type
	 * declaration starting in between.
	 */
	private static function enclosingMetaPresent(tree: QueryNode, declSpan: Span, metaName: String, disableArg: Null<String>): Bool {
		final typeFroms: Array<Int> = [];
		final metaNodes: Array<QueryNode> = [];
		function walk(n: QueryNode): Void {
			final td: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(n);
			if (td != null) typeFroms.push(td.fullSpan.from);
			if (n.name == metaName && n.span != null) metaNodes.push(n);
			for (c in n.children) walk(c);
		}
		walk(tree);
		for (m in metaNodes) {
			final ms: Null<Span> = m.span;
			if (ms == null || ms.to > declSpan.from) continue;
			if (disableArg != null && subtreeHasName(m, disableArg)) continue;
			var blocked: Bool = false;
			for (tf in typeFroms) if (tf >= ms.to && tf < declSpan.from) {
				blocked = true;
				break;
			}
			if (!blocked) return true;
		}
		return false;
	}

	/** Whether `node` or any descendant carries the name `name`. */
	private static function subtreeHasName(node: QueryNode, name: String): Bool {
		if (node.name == name) return true;
		for (c in node.children) if (subtreeHasName(c, name)) return true;
		return false;
	}

}
