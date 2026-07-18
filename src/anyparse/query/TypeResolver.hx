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
		return typeName != null && (index.isAnonStructType(typeName) || index.memberGetter(typeName, field) == false);
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
	public static function identTypeName(
		ident: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>
	): Null<String> {
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
			if (!isNominalChar(StringTools.fastCodeAt(typeSrc, i))) return null;
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
	 * Whether the declaration binding at `bindingFrom` is a parameter with a
	 * null-literal default value (`p: T = null`) — nullable per Haxe null-safety
	 * ("an argument with a default value of null is nullable"), so its value may be
	 * null even without the `?` sigil, despite `declaredTypes` recording a nominal
	 * type. A param node (kind in `paramKinds`) whose span covers `bindingFrom` and
	 * whose default-value child is a `nullLiteralKind` node.
	 */
	public static function bindingIsDefaultNullParam(
		tree: QueryNode, bindingFrom: Int, paramKinds: Array<String>, nullLiteralKind: String
	): Bool {
		var found: Bool = false;
		function walk(n: QueryNode): Void {
			if (found) return;
			if (paramKinds.contains(n.kind)) {
				final s: Null<Span> = n.span;
				if (s != null && s.from <= bindingFrom && bindingFrom < s.to) for (c in n.children) if (c.kind == nullLiteralKind) {
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
	 * Whether the declaration binding at `bindingFrom` is a LOCAL (a `localDeclKinds`
	 * node) or a PARAMETER (a `paramKinds` node) — as opposed to a field or other decl.
	 * Lets a check restrict a declared-type nullable source to locals / params, since a
	 * bare field never narrows and is out of the flow engine's scope.
	 */
	public static function bindingIsLocalOrParam(
		tree: QueryNode, bindingFrom: Int, localDeclKinds: Array<String>, paramKinds: Array<String>
	): Bool {
		var found: Bool = false;
		function walk(n: QueryNode): Void {
			if (found) return;
			if (localDeclKinds.contains(n.kind) || paramKinds.contains(n.kind)) {
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
	 * Whether null-safety is ACTIVE over `span`. A `@:nullSafety(disableArg)`
	 * (`@:nullSafety(Off)`) whose declaration scope — member (field / method), type
	 * (class), or module — covers `span` REFUSES (`false`): Haxe does not re-enable a
	 * disabled outer scope from an inner `Strict` (confirmed on 4.3.7), so a covering
	 * disable anywhere in the chain wins. Affirmation requires a covering non-`Off`
	 * `@:nullSafety` at TYPE / MODULE level (a class / module annotation); a
	 * member-level non-`Off` is NOT counted — that keeps the result strictly
	 * no-more-affirming than the class/module-only predicate this replaced, while a
	 * member-level `Off` can still refuse. A bare `@:nullSafety` (Haxe-default Loose)
	 * and every explicit mode (`Strict` / `StrictThreaded` / `Loose`) count as active —
	 * each rejects a null flowing into a nominally non-nullable binding, the sole
	 * guarantee `isProvablyNonNull` relies on.
	 */
	public static function enclosingIsNullSafe(tree: QueryNode, span: Span, metaName: String, disableArg: Null<String>): Bool {
		var active: Bool = false;
		for (s in collectNullSafetyScopes(tree, metaName, disableArg)) if (s.from <= span.from && span.to <= s.to) {
			if (s.disabled) return false;
			if (s.typeLevel) active = true;
		}
		return active;
	}

	/**
	 * Whether `operand` is a plain identifier resolvable to a provably non-null
	 * type — a `RefShape.nonNullableTypeNames` value type (null-safety-independent),
	 * or any recovered nominal type while null-safety is active. An operand bound to
	 * an optional parameter, to a default-null parameter (`p: T = null` — nullable per
	 * Haxe null-safety even for a value type, so the null default is checked BEFORE
	 * the nominal type), to a `RefShape.nullableWrapperTypeNames` type (`Null<…>` /
	 * `Dynamic` / `Any`), or with no recovered nominal type keeps the conservative
	 * default and is NOT proven non-null.
	 *
	 * The nominal-under-null-safety proof requires the enclosing `@:nullSafety` to be
	 * active at BOTH the operand's binding declaration and the read — the nearest
	 * annotation wins at each (member > type > module), so a member-level
	 * `@:nullSafety(Off)` on the field/local (Pony's `TouchableBase` timer fields) or
	 * on the reading method refuses, even inside a null-safe class. Bare `@:nullSafety`
	 * is Haxe-default Loose and is trusted here: Loose rejects a null flowing into a
	 * nominally non-nullable binding exactly as Strict does (its only relaxations are
	 * read-side narrowing of already-`Null<…>` values, which never reach this proof).
	 * Shared by every null-aware check (`unnecessary-null-check`,
	 * `redundant-null-coalescing`, …).
	 */
	public static function isProvablyNonNull(operand: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>): Bool {
		final bindingFrom: Null<Int> = operandBindingFrom(operand, root, shape);
		if (bindingFrom == null) return false;
		final optionalParamKind: Null<String> = shape.optionalParamKind;
		if (optionalParamKind != null && bindingIsOptionalParam(root, bindingFrom, optionalParamKind)) return false;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		final nullLiteralKind: Null<String> = shape.nullLiteralKind;
		if (paramKinds != null && nullLiteralKind != null && bindingIsDefaultNullParam(root, bindingFrom, paramKinds, nullLiteralKind))
			return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		final nonNullableTypeNames: Array<String> = shape.nonNullableTypeNames ?? [];
		if (nonNullableTypeNames.contains(typeName)) return true;
		final nullableWrapperTypeNames: Array<String> = shape.nullableWrapperTypeNames ?? [];
		if (nullableWrapperTypeNames.contains(typeName)) return false;
		final nullSafetyMetaName: Null<String> = shape.nullSafetyMetaName;
		final opSpan: Null<Span> = operand.span;
		if (nullSafetyMetaName == null || opSpan == null) return false;
		final disableArg: Null<String> = shape.nullSafetyDisableArg;
		return enclosingIsNullSafe(root, new Span(bindingFrom, bindingFrom), nullSafetyMetaName, disableArg)
			&& enclosingIsNullSafe(root, opSpan, nullSafetyMetaName, disableArg);
	}

	/**
	 * Whether two type SOURCES denote the same type. Exact (whitespace-insensitive)
	 * equality is the common case; when the spellings differ, both are canonicalized
	 * to an FQN via `canonicalTypeName` + the file's `importMap` and compared — so
	 * `Eof` (imported `haxe.io.Eof`) matches a qualified `haxe.io.Eof`, while
	 * `haxe.io.Eof` stays distinct from `sys.io.Eof`. A name that canonicalizes to
	 * null (a generic / function / anon type, or an unresolved bare name) yields no
	 * cross-spelling match — a safe miss. Sound within one file: an unqualified name
	 * binds to exactly one type, so equal FQNs are the same type.
	 *
	 * Whitespace is insignificant in a type EXCEPT inside a string-literal const type
	 * parameter (`Foo<"a b">`), so when either source carries a quote the comparison
	 * falls back to verbatim equality.
	 */
	public static function sameTypeSource(a: String, b: String, importMap: Map<String, String>): Bool {
		final quoted: Bool = a.indexOf('"') != -1 || a.indexOf("'") != -1 || b.indexOf('"') != -1 || b.indexOf("'") != -1;
		if (quoted) return a == b;
		final na: String = stripWs(a);
		final nb: String = stripWs(b);
		if (na == nb) return true;
		final ca: Null<String> = canonicalTypeName(na, importMap);
		final cb: Null<String> = canonicalTypeName(nb, importMap);
		return ca != null && cb != null && ca == cb;
	}

	/**
	 * The simple name of a plain nominal type SOURCE `typeSrc` — whitespace stripped, the
	 * last `.`-segment. Null when `typeSrc` is null or NOT a plain nominal (a generic /
	 * function / anonymous type — any char outside `[A-Za-z0-9_.]`). Lets a check key a
	 * `SymbolIndex` lookup (simple-name based) off a written type while rejecting shapes
	 * that can never name a single indexed class. Shared by `impossible-is-check` and
	 * `unreachable-catch`.
	 */
	public static function simpleNominalName(typeSrc: Null<String>): Null<String> {
		if (typeSrc == null) return null;
		final src: String = typeSrc;
		final buf: StringBuf = new StringBuf();
		for (i in 0...src.length) {
			final c: Int = StringTools.fastCodeAt(src, i);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) continue;
			if (!isNominalChar(c)) return null;
			buf.addChar(c);
		}
		final s: String = buf.toString();
		if (s == '') return null;
		final dot: Int = s.lastIndexOf('.');
		return dot == -1 ? s : s.substring(dot + 1);
	}

	/**
	 * The cast target type whose payload span key falls within `castSpan` — the earliest
	 * such key (the outermost payload of a nested cast). Shared by `redundant-cast` and
	 * `impossible-cast`.
	 */
	public static function castTargetWithin(castSpan: Span, castTargets: Map<Int, String>): Null<String> {
		var best: Null<String> = null;
		var bestKey: Int = -1;
		for (from => ty in castTargets) if (from >= castSpan.from && from < castSpan.to && (best == null || from < bestKey)) {
			best = ty;
			bestKey = from;
		}
		return best;
	}

	/**
	 * Whether ANY `@:nullSafety` scope is active over `span` — the member-affirming
	 * variant of `enclosingIsNullSafe`. A covering `@:nullSafety(Off)` anywhere in
	 * the chain refuses; otherwise ANY covering non-`Off` annotation — member,
	 * type, or module level — affirms. Used by the inference-fragility gate, where
	 * a member-level `@:nullSafety` on the enclosing method makes the rewrite
	 * hazard just as real as a class-level one (the affirmation asymmetry
	 * `enclosingIsNullSafe` keeps for `isProvablyNonNull` protects a PROOF of
	 * non-nullness; here the affirmative answer only makes a skip MORE
	 * conservative, so the member level is safe to count).
	 */
	public static function nullSafetyActiveAt(tree: QueryNode, span: Span, metaName: String, disableArg: Null<String>): Bool {
		var active: Bool = false;
		for (s in collectNullSafetyScopes(tree, metaName, disableArg)) if (s.from <= span.from && span.to <= s.to) {
			if (s.disabled) return false;
			active = true;
		}
		return active;
	}

	/**
	 * Whether `expr` is a field-access chain whose BASE identifier binds to a
	 * declaration with NO recoverable declared type — an INFERENCE-OPEN receiver.
	 * The paradigm case is a `for`-loop iterator over a custom `hasNext`/`next`
	 * iterator whose `next()` returns `Dynamic`: Haxe types the loop variable as
	 * an UNBOUND MONOMORPH (`Unknown<0>`), and each `base.field` access adds a
	 * structural constraint whose field TYPE is fixed by whatever context first
	 * unifies it. A rewrite that re-positions such an access between an
	 * expected-type context and a value-mode context can flip that constraint
	 * binding (`String` -> `Null<String>`) and retroactively change the type of
	 * EVERY use of the same field in the function. A base that is unresolved (a
	 * type name, `this`) or carries any declared-type entry (including a
	 * `Null<…>` / `Dynamic` wrapper — an annotated type is never a monomorph) is
	 * NOT open. Conservative over-approximation: an unannotated initialized local
	 * also reports open, though its type is fixed by its initializer.
	 */
	public static function isInferenceOpenFieldAccess(
		expr: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>
	): Bool {
		final faKind: Null<String> = shape.fieldAccessKind;
		if (faKind == null || expr.kind != faKind) return false;
		var base: QueryNode = expr;
		while (base.kind == faKind && base.children.length == 1) base = base.children[0];
		final bindingFrom: Null<Int> = identBindingFrom(base, root, shape);
		return bindingFrom != null && declaredTypes[bindingFrom] == null;
	}

	/**
	 * Whether rewriting a null guard whose FALLBACK operand is `fallback` between
	 * an expected-type context and a value-mode context is INFERENCE-FRAGILE at
	 * `site` — i.e. the rewrite may flip the fallback's inferred type from
	 * non-null to `Null<…>` and break compilation under active null-safety.
	 *
	 * The isolated mechanism (Haxe, verified 4.3.7): in an argument position
	 * (`m.get(x != null ? x : row.f)`) the ternary's branches are typed against
	 * the parameter's EXPECTED type, binding an inference-open `row.f`'s
	 * structural constraint NON-null (`row.f : String`). After the rewrite —
	 * `x ?? row.f` (operands typed against `Null<expected>`) or `m[…]` (the key
	 * typed in VALUE mode, where the null comparison creates a `Null<…>` and
	 * branch unification propagates it) — the same constraint binds NULLABLE
	 * (`row.f : Null<String>`), which retroactively poisons every later use of
	 * `row.f` in the function. Only that combination is fragile, so BOTH are
	 * required: an active `@:nullSafety` scope over `site` (member, type, or
	 * module level — without null-safety the flipped binding still compiles) AND
	 * an inference-open fallback (`isInferenceOpenFieldAccess`). The GUARDED
	 * operand needs no check: the null comparison itself binds it `Null<…>` in
	 * both the original and the rewritten form.
	 */
	public static function isInferenceFragileNullGuard(
		fallback: QueryNode, site: Span, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>
	): Bool {
		final metaName: Null<String> = shape.nullSafetyMetaName;
		if (metaName == null || !nullSafetyActiveAt(root, site, metaName, shape.nullSafetyDisableArg)) return false;
		return isInferenceOpenFieldAccess(fallback, root, shape, declaredTypes);
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

	/** Whether `node` or any descendant carries the name `name`. */
	private static function subtreeHasName(node: QueryNode, name: String): Bool {
		if (node.name == name) return true;
		for (c in node.children) if (subtreeHasName(c, name)) return true;
		return false;
	}

	/** `s` with every space / tab / newline removed (whitespace is insignificant in a type). */
	public static function stripWs(s: String): String {
		final buf: StringBuf = new StringBuf();
		for (i in 0...s.length) {
			final c: Int = StringTools.fastCodeAt(s, i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) buf.addChar(c);
		}
		return buf.toString();
	}

	/** Whether `c` is a character of a plain nominal type reference — `[A-Za-z0-9_.]`. */
	private static inline function isNominalChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code
			|| c == '.'.code;
	}

	/**
	 * Every `@:nullSafety` annotation in `tree` as a scope span — from the meta's
	 * start to the end of the member / type declaration it precedes (modifier and
	 * unrelated-meta siblings in between are skipped). `disabled` records whether the
	 * meta carries `disableArg` (`Off`). A meta not followed by a member / type
	 * declaration at its own level (a statement- or expression-level annotation) is
	 * dropped: it falls outside the member > type > module hierarchy this models.
	 */
	private static function collectNullSafetyScopes(tree: QueryNode, metaName: String, disableArg: Null<String>): Array<{
		from: Int,
		to: Int,
		disabled: Bool,
		typeLevel: Bool
	}> {
		final scopes: Array<{
			from: Int,
			to: Int,
			disabled: Bool,
			typeLevel: Bool
		}> = [];
		function walk(node: QueryNode): Void {
			var pending: Array<{ from: Int, disabled: Bool }> = [];
			for (c in node.children) {
				final cs: Null<Span> = c.span;
				if (cs != null && c.name == metaName)
					pending.push({ from: cs.from, disabled: metaDisabled(c, disableArg) });
				else if (cs != null && isDeclScope(c.kind)) {
					final typeLevel: Bool = isTypeDeclScope(c.kind);
					for (p in pending) scopes.push({
						from: p.from,
						to: cs.to,
						disabled: p.disabled,
						typeLevel: typeLevel
					});
					pending = [];
				}
				walk(c);
			}
		}
		walk(tree);
		return scopes;
	}


	/** Whether `kind` is a member or type declaration — a scope a `@:nullSafety` meta can annotate. */
	private static inline function isDeclScope(kind: String): Bool {
		return RefactorSupport.isFieldMemberKind(kind) || isTypeDeclScope(kind);
	}

	/** Whether a `@:nullSafety` meta node carries the disable argument (`Off`). */
	private static function metaDisabled(meta: QueryNode, disableArg: Null<String>): Bool {
		return disableArg != null && subtreeHasName(meta, disableArg);
	}

	/** Whether `kind` is a TYPE declaration (class / interface / enum / typedef / abstract) — the level a `@:nullSafety` may affirm at. */
	private static inline function isTypeDeclScope(kind: String): Bool {
		return RefactorSupport.TYPE_DECL_KINDS.contains(kind) || kind == 'FinalDecl';
	}


	/**
	 * The binding `operand` (an identifier) resolves to for nullability — the naive lexical
	 * binding, CORRECTED for self-shadowing. When `operand` sits inside the initializer of a
	 * same-named local `var` / `final`, the lexical resolver binds it to that just-declared
	 * local (declared type, non-null); but a var/final is NOT in scope in its own
	 * initializer, so its RHS must see the ENCLOSING binding (the shadowed param / outer
	 * local / field). Re-resolves to that enclosing binding. Null when `operand` is not an
	 * identifier, its binding is unresolved, or (self-shadow) no enclosing binding exists —
	 * the caller then keeps its conservative default.
	 */
	private static function operandBindingFrom(operand: QueryNode, root: QueryNode, shape: RefShape): Null<Int> {
		final naive: Null<Int> = identBindingFrom(operand, root, shape);
		if (naive == null) return null;
		final naiveFrom: Int = naive;
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final opSpan: Null<Span> = operand.span;
		final name: Null<String> = operand.name;
		if (localDeclKinds.length == 0 || opSpan == null || name == null) return naive;
		final selfLocal: Null<Span> = selfShadowLocalSpan(root, localDeclKinds, name, opSpan, naiveFrom);
		return selfLocal == null ? naive : enclosingBindingFrom(root, shape, name, selfLocal, opSpan);
	}


	/**
	 * The span of the local `var` / `final` declaration `operand` naively binds to WHEN that
	 * binding is the operand's own initializer — a `localDeclKinds` node named `name` that
	 * starts at `naiveFrom` and whose span contains `opSpan`. Null when the naive binding is
	 * not such a self-referential local initializer (a normal read positioned after the
	 * declaration, a param, or a field).
	 */
	private static function selfShadowLocalSpan(
		tree: QueryNode, localDeclKinds: Array<String>, name: String, opSpan: Span, naiveFrom: Int
	): Null<Span> {
		var found: Null<Span> = null;
		function walk(n: QueryNode): Void {
			if (found != null) return;
			final s: Null<Span> = n.span;
			if (
				s != null && s.from == naiveFrom && n.name == name && localDeclKinds.contains(n.kind) && s.from <= opSpan.from
				&& opSpan.to <= s.to
			) {
				found = s;
				return;
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return found;
	}


	/**
	 * The `from` of the binding of `name` visible in the scope ENCLOSING the self-shadowing
	 * local declared at `selfSpan` — the decl-host of `name` (a `declHostKinds` node other
	 * than the self-local, declared before it) in the INNERMOST enclosing scope that still
	 * covers `opSpan`. This is the binding the self-referential initializer actually reads
	 * (the shadowed param / outer local / field). Null when none exists.
	 */
	private static function enclosingBindingFrom(tree: QueryNode, shape: RefShape, name: String, selfSpan: Span, opSpan: Span): Null<Int> {
		final declHostKinds: Array<String> = shape.declHostKinds;
		final scopeKinds: Array<String> = shape.scopeKinds;
		var bestFrom: Null<Int> = null;
		var bestWidth: Int = 0;
		final scopeStack: Array<Span> = [];
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (s != null && n.name == name && s.from < selfSpan.from && declHostKinds.contains(n.kind) && scopeStack.length > 0) {
				final enc: Span = scopeStack[scopeStack.length - 1];
				if (enc.from <= opSpan.from && opSpan.to <= enc.to) {
					final width: Int = enc.to - enc.from;
					final prev: Null<Int> = bestFrom;
					if (prev == null || width < bestWidth || (width == bestWidth && s.from > prev)) {
						bestFrom = s.from;
						bestWidth = width;
					}
				}
			}
			final scopeSpan: Null<Span> = (s != null && scopeKinds.contains(n.kind)) ? s : null;
			if (scopeSpan != null) scopeStack.push(scopeSpan);
			for (c in n.children) walk(c);
			if (scopeSpan != null) scopeStack.pop();
		}
		walk(tree);
		return bestFrom;
	}

}
