package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.Check.DefaultOff;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a local `var` / `final` declared WITHOUT an explicit `:Type` annotation —
 * statement-position locals only (`RefShape.localDeclKinds`, Haxe `VarStmt` /
 * `FinalStmt`). Fields, parameters and return types are covered by the sibling
 * `explicit-type` check; this one closes the last omission, so every binding states
 * its type. The rule is ALL-mode: no trivial / non-trivial heuristic — in Haxe a
 * bare literal is not self-evident (`5` may be `Int` / `UInt` / `Float` / a domain
 * abstract via `@:from Int`), so uniformity and an explicit written type win over
 * apparent obviousness.
 *
 * ## Default OFF — opt-in
 *
 * The check is a `DefaultOff` marker: it is dropped from the default set and from a
 * bare `lint … --all` report unless a project opts in via `apqlint.json`
 * (`"rules": { "explicit-local-type": { "enabled": true } }`), or an explicit
 * `--rule explicit-local-type` selects it (which bypasses enablement). This keeps it
 * a per-project style preference, not a codebase-wide default.
 *
 * ## Autofix — the compiler's OWN inferred type, structurally certain
 *
 * `fix` annotates a flagged local ONLY when the initializer STRUCTURALLY pins the
 * type, so writing it re-states what the compiler already infers — a sound rewrite
 * by construction (the value's static type is UNCHANGED, unlike a `Dynamic`
 * narrowing whose implicit-conversion dispatch would shift). Handled shapes, via the
 * shared `LiteralInfer` (identical to `explicit-type`) plus two local extensions:
 *
 *  - a literal — `String` / `Int` / `Float` / `Bool` (negatives included);
 *  - `new T<...>()` with WRITTEN type parameters → `T<...>` verbatim;
 *  - a typed cast / check-type `(x : T)` → `T`;
 *  - a NON-EMPTY, HOMOGENEOUS array literal of one KNOWN literal element type →
 *    `Array<T>` (a non-empty literal pins the element type — `[1, 2, 3]` is
 *    `Array<Int>`, a later `push(1.5)` already errors — so the annotation never
 *    introduces a fresh error); an empty `[]`, a heterogeneous or non-literal-
 *    element array yields nothing (the element type is inference-resolved);
 *  - a method call `recv.method(args)` whose return type is fixed for a String
 *    receiver (`split` → `Array<String>`, `substr` → `String`, `indexOf` → `Int`,
 *    via `RefShape.stringLiteralMethodReturns`) AND whose receiver is provably a
 *    `String` — either a string LITERAL (`'a,b'.split(',')`) or a VARIABLE whose
 *    declared type resolves to `String`. The variable's type is recovered with no
 *    compiler: the scope resolver (`TypeResolver.resolveBindingFrom`) plus the
 *    `TypeInfoProvider.declaredTypeSources` map, unwrapping one `Null<…>` layer (a
 *    `Null<String>` narrowed in a guard is a `String` at the call — calling a String
 *    method on it proves so). A receiver whose type does not resolve, resolves to a
 *    non-`String` type, or a method absent from the table (a generic `.map()` /
 *    `.filter()`, or nullable-return `charCodeAt`) stays report-only.
 *
 * A `new T<...>()` whose type name is a user nominal resolves through the written
 * generics, so no symbol lookup is needed; the built-in `String` / `Int` / `Float` /
 * `Bool` / `Array` always resolve. Everything the initializer does NOT structurally
 * pin — a bare `new T()` (possibly generic), a bare `new Map()`, `= null`, a
 * `.map()` / `.filter()` or any other call whose return depends on generics /
 * inference, a field read, a ternary, an identifier — is left report-only. The
 * conservative skip is deliberate: coverage never trumps soundness, so an
 * uninferable local keeps its finding and no edit.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.localDeclKinds` are the hosts, `opaqueKinds` the reification subtrees to
 * skip (a spliced local's form is not literal source). The autofix reads
 * `literalTypeNames`, `numericLiteralKinds`, `negationKind`, `newExprKind`,
 * `typedCastKinds` (shared with `explicit-type`) plus `arrayLiteralKind` for the
 * array shape, and `stringLiteralMethodReturns` / `callKind` / `fieldAccessKind` /
 * `identKind` / `stringLiteralKinds` / `nullableWrapperTypeNames` (+ the optional
 * `TypeInfoProvider`) for the method-call shape. Any unset seam degrades that shape
 * to report-only.
 */
@:nullSafety(Strict)
final class ExplicitLocalType implements Check implements DefaultOff {

	private static inline final RULE_ID: String = 'explicit-local-type';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a local var/final declared without an explicit type annotation';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final locals: Array<String> = shape.localDeclKinds ?? [];
		if (locals.length == 0) return [];
		final opaque: Array<String> = shape.opaqueKinds ?? [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, locals, opaque);
		}
		return violations;
	}

	/**
	 * Annotate each flagged local whose initializer structurally pins its type,
	 * re-stating the compiler's own inference (a sound, dispatch-neutral rewrite).
	 * A local whose type the initializer does not pin yields no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final locals: Array<String> = shape.localDeclKinds ?? [];
		final tree: Null<QueryNode> = locals.length == 0 ? null : CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, locals, byKey);
		// A cast target lookup costs a second full parse (`castTargetSources`), so compute
		// it lazily and cache it — a run whose locals are never casts never pays for it.
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		var castTargetsCache: Null<Map<Int, String>> = null;
		function castTargets(): Map<Int, String> {
			final existing: Null<Map<Int, String>> = castTargetsCache;
			if (existing != null) return existing;
			final p: Null<TypeInfoProvider> = provider;
			final computed: Map<Int, String> = p != null ? p.castTargetSources(source) : [];
			castTargetsCache = computed;
			return computed;
		}
		// A variable-receiver method call needs the receiver's declared type SOURCE (verbatim,
		// so `Null<String>` survives — `declaredTypes` would collapse it to the outer `Null`),
		// resolved lazily and cached like the cast targets above.
		var declaredTypeSourcesCache: Null<Map<Int, String>> = null;
		function declaredTypeSources(): Map<Int, String> {
			final existing: Null<Map<Int, String>> = declaredTypeSourcesCache;
			if (existing != null) return existing;
			final p: Null<TypeInfoProvider> = provider;
			final computed: Map<Int, String> = p != null ? p.declaredTypeSources(source) : [];
			declaredTypeSourcesCache = computed;
			return computed;
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null || node.children.length == 0) continue;
			final init: QueryNode = node.children[0];
			final typeSource: Null<String> = inferLocalType(init, source, shape, tree, castTargets, declaredTypeSources);
			if (typeSource == null) continue;
			final at: Int = LiteralInfer.insertPoint(node, init, source);
			if (at >= 0) edits.push({ span: new Span(at, at), text: ':$typeSource' });
		}
		return edits;
	}

	/**
	 * Walk `node`, appending a finding for every local declaration with no `:Type`
	 * annotation. A reification (`opaqueKinds`) subtree is skipped wholesale — a
	 * splice-injected local is not a real source declaration.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, locals: Array<String>, opaque: Array<String>
	): Void {
		if (opaque.contains(node.kind)) return;
		if (locals.contains(node.kind) && !LiteralInfer.hasTypeBeforeInit(node, source)) push(out, file, node.span);
		for (c in node.children) walk(out, file, source, c, locals, opaque);
	}

	private static function push(out: Array<Violation>, file: String, span: Null<Span>): Void {
		if (span != null) out.push({
			file: file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Warning,
			message: 'local var/final declared without an explicit type'
		});
	}

	/**
	 * The structurally-certain type of a local's `init`: the shared `LiteralInfer`
	 * shapes first (literal / neg-numeric / written-generic `new` / cast), then a
	 * homogeneous array literal, then a fixed-return method call on a provable-String
	 * receiver. Null when none pins the type.
	 */
	private static function inferLocalType(
		init: QueryNode, source: String, shape: RefShape, tree: QueryNode, castTargets: () -> Map<Int, String>,
		declaredTypeSources: () -> Map<Int, String>
	): Null<String> {
		return LiteralInfer.inferType(init, source, shape, castTargets) ?? arrayType(init, shape) ?? methodReturnType(
			init, shape, tree, declaredTypeSources
		);
	}

	/**
	 * The fixed return type of a method call `recv.method(...)` whose receiver is
	 * PROVABLY a `String`, when `method` is in `shape.stringLiteralMethodReturns`
	 * (`split` → `Array<String>`, `indexOf` → `Int`, …). A method absent from the
	 * table — a generic / inference-dependent return (`map` / `filter`) or a nullable
	 * one (`charCodeAt`) — yields null and stays report-only. Null too when the
	 * receiver is not a provable `String`, the shape lacks the call / field-access /
	 * table seams, or the call is not the `recv.method(...)` shape.
	 */
	private static function methodReturnType(
		init: QueryNode, shape: RefShape, tree: QueryNode, declaredTypeSources: () -> Map<Int, String>
	): Null<String> {
		final table: Null<Map<String, String>> = shape.stringLiteralMethodReturns;
		final callKind: Null<String> = shape.callKind;
		final faKind: Null<String> = shape.fieldAccessKind;
		if (table == null || callKind == null || faKind == null) return null;
		if (init.kind != callKind || init.children.length == 0) return null;
		final callee: QueryNode = init.children[0];
		if (callee.kind != faKind || callee.children.length != 1) return null;
		final method: Null<String> = callee.name;
		if (method == null) return null;
		final ret: Null<String> = table[method];
		if (ret == null) return null;
		return receiverIsString(callee.children[0], shape, tree, declaredTypeSources) ? ret : null;
	}

	/**
	 * Whether `recv` is provably a `String`: a string-literal node, or an identifier
	 * whose declared-type source resolves (scope resolver + `TypeInfoProvider`) to the
	 * grammar's string type — a single `Null<…>` wrapper unwrapped, since a
	 * `Null<String>` receiver on which a String method is called IS a String at that
	 * point. An unresolved receiver, one of any other type, or a name RE-SHADOWED in a
	 * visible scope (where the first-wins resolver diverges from Haxe's binding) yields
	 * false.
	 */
	private static function receiverIsString(
		recv: QueryNode, shape: RefShape, tree: QueryNode, declaredTypeSources: () -> Map<Int, String>
	): Bool {
		final stringKinds: Array<String> = shape.stringLiteralKinds ?? [];
		if (stringKinds.contains(recv.kind)) return true;
		final stringType: Null<String> = stringTypeName(shape);
		final identKind: Null<String> = shape.identKind;
		final name: Null<String> = recv.name;
		final span: Null<Span> = recv.span;
		if (stringType == null || identKind == null || recv.kind != identKind || name == null || span == null) return false;
		// The scope resolver is first-wins per scope, but Haxe binds to the nearest-preceding
		// declaration; the two diverge only when a name is re-shadowed in a scope visible at the
		// use (`var s:String; var s:Foo; s.split(...)`). More than one visible declaration ->
		// the resolved type is untrustworthy, so bail to report-only.
		if (visibleDeclCount(tree, shape, name, span) > 1) return false;
		final bindingFrom: Null<Int> = TypeResolver.resolveBindingFrom(name, span, tree, shape);
		if (bindingFrom == null) return false;
		final typeSrc: Null<String> = declaredTypeSources()[bindingFrom];
		return typeSrc != null && unwrapNullable(TypeResolver.stripWs(typeSrc), shape) == stringType;
	}

	/**
	 * The number of declarations of `name` VISIBLE at `useSpan` — a `declHostKinds`
	 * node named `name` whose innermost enclosing `scopeKinds` scope also contains
	 * `useSpan`. More than one means the name is re-shadowed in a visible scope, where
	 * the first-wins scope resolver cannot be trusted to match Haxe's binding.
	 */
	private static function visibleDeclCount(tree: QueryNode, shape: RefShape, name: String, useSpan: Span): Int {
		final declHostKinds: Array<String> = shape.declHostKinds;
		final scopeKinds: Array<String> = shape.scopeKinds;
		var count: Int = 0;
		final scopeStack: Array<Span> = [];
		function walk(node: QueryNode): Void {
			final s: Null<Span> = node.span;
			if (s != null && node.name == name && declHostKinds.contains(node.kind) && scopeStack.length > 0) {
				final enc: Span = scopeStack[scopeStack.length - 1];
				if (enc.from <= useSpan.from && useSpan.to <= enc.to) count++;
			}
			final scopeSpan: Null<Span> = (s != null && scopeKinds.contains(node.kind)) ? s : null;
			if (scopeSpan != null) scopeStack.push(scopeSpan);
			for (c in node.children) walk(c);
			if (scopeSpan != null) scopeStack.pop();
		}
		walk(tree);
		return count;
	}

	/**
	 * The grammar's string type name (`String`) — the type a string literal denotes,
	 * read off `literalTypeNames` via a `stringLiteralKinds` kind rather than hardcoded.
	 * Null when either seam is unset.
	 */
	private static function stringTypeName(shape: RefShape): Null<String> {
		final literalTypes: Map<String, String> = shape.literalTypeNames ?? [];
		for (k in shape.stringLiteralKinds ?? []) {
			final t: Null<String> = literalTypes[k];
			if (t != null) return t;
		}
		return null;
	}

	/**
	 * `T` from a single nullable-wrapper application `Null<T>` (the outer name must be
	 * a `shape.nullableWrapperTypeNames` entry), else `t` unchanged. Input is expected
	 * whitespace-stripped.
	 */
	private static function unwrapNullable(t: String, shape: RefShape): String {
		final lt: Int = t.indexOf('<');
		if (lt <= 0 || !StringTools.endsWith(t, '>')) return t;
		final outer: String = t.substring(0, lt);
		final wrappers: Array<String> = shape.nullableWrapperTypeNames ?? [];
		return wrappers.contains(outer) ? t.substring(lt + 1, t.length - 1) : t;
	}

	/**
	 * `Array<T>` when `init` is a non-empty array literal whose every element is a
	 * literal of the SAME known type `T` (a non-empty literal pins the element type,
	 * so the annotation re-states it). An empty `[]`, a heterogeneous array, or any
	 * non-literal element (whose type needs inference) yields null.
	 */
	private static function arrayType(init: QueryNode, shape: RefShape): Null<String> {
		final arrKind: Null<String> = shape.arrayLiteralKind;
		if (arrKind == null || init.kind != arrKind) return null;
		final literalTypes: Map<String, String> = shape.literalTypeNames ?? [];
		final kids: Array<QueryNode> = init.children;
		if (kids.length == 0) return null;
		var elem: Null<String> = null;
		for (k in kids) {
			final t: Null<String> = literalTypes[k.kind];
			if (t == null) return null;
			if (elem == null)
				elem = t;
			else if (elem != t)
				return null;
		}
		return elem == null ? null : 'Array<$elem>';
	}

}
