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
import anyparse.check.Check.OracleAssisted;
import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.TypeOracle;
import anyparse.check.LintConfig;

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
 * shared `LiteralInfer` (identical to `explicit-type`) plus four local extensions:
 *
 *  - a literal — `String` / `Int` / `Float` / `Bool` (negatives included);
 *  - `new T<...>()` with WRITTEN type parameters → `T<...>` verbatim;
 *  - a bare `new T(...)` whose `T` is PROVABLY non-generic → the written `T`
 *    verbatim: every indexed declaration of the simple name agrees on zero type
 *    parameters (`SymbolIndex.typeParamArityOf`), or - when the index declares
 *    no such name - `T` is a whitelisted always-in-scope non-generic constructor
 *    type (`StringBuf`, `EReg`, ...). A generic, ambiguous-arity or unknown `T`
 *    stays report-only (a bare `:T` would be a compile error or an inference
 *    change);
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
 *  - a plain identifier read `= ident` whose binding (a local, a parameter or an
 *    own-class field) carries a WRITTEN type → that type VERBATIM, copied unchanged
 *    (a `Null<…>` field read stays `Null<…>` — a transcription of an existing
 *    annotation, not an inference). An identifier whose binding does not resolve (an
 *    inference-typed source, a cross-file inherited field), is re-shadowed in a visible
 *    scope, or is an OPTIONAL parameter with no default (whose body type `Null<T>`
 *    differs from its written source `T`, so a verbatim copy would drop the
 *    nullability) stays report-only.
 *  - a cross-class STATIC field read `= Type.field` whose type is another class in the
 *    lint scope: the field's WRITTEN type SOURCE, copied VERBATIM (`Null<…>` preserved)
 *    from the cross-file `SymbolIndex` (`memberTypeSourceOf`) threaded into `fix`, but ONLY
 *    when every component of that source is an always-in-scope builtin (String / Int /
 *    Array / Null / …) — the source is spelled in the field's DECLARING file, so a
 *    non-builtin name (a user type) might not resolve in the consumer's import scope and
 *    stays report-only. The receiver must be an upper-initial TYPE reference (a value-bound
 *    / lower-initial receiver is an INSTANCE access, left report-only) named unambiguously
 *    in the index, with a member of a single written type (a `#if`/`#else` pair of
 *    differing types, an inference-typed member, or a simple-name type collision →
 *    report-only). Without a threaded index — the receiver is cross-file — this shape stays
 *    report-only.
 *
 * A `new T<...>()` whose type name is a user nominal resolves through the written
 * generics, so no symbol lookup is needed; the built-in `String` / `Int` / `Float` /
 * `Bool` / `Array` always resolve. Everything the initializer does NOT structurally
 * pin — a bare `new T()` (possibly generic), a bare `new Map()`, `= null`, a
 * `.map()` / `.filter()` or any other call whose return depends on generics /
 * inference, a ternary, an identifier whose binding carries no written type — is left
 * report-only. The conservative skip is deliberate: coverage never trumps soundness,
 * so an uninferable local keeps its finding and no edit.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.localDeclKinds` are the hosts, `opaqueKinds` the reification subtrees to
 * skip (a spliced local's form is not literal source). The autofix reads
 * `literalTypeNames`, `numericLiteralKinds`, `negationKind`, `newExprKind`,
 * `typedCastKinds` (shared with `explicit-type`) plus `arrayLiteralKind` for the
 * array shape, and `stringLiteralMethodReturns` / `callKind` / `fieldAccessKind` /
 * `identKind` / `stringLiteralKinds` / `nullableWrapperTypeNames` (+ the optional
 * `TypeInfoProvider`) for the method-call shape; `identKind` + `optionalParamKind` +
 * the `TypeInfoProvider` also drive the identifier-read shape; `fieldAccessKind` +
 * `identKind` + the cross-file `SymbolIndex` drive the static-field-read shape.
 * `parenKind` peels the initializer's parentheses BEFORE any of them runs, so a
 * wrapped `(-1)` infers exactly as a bare `-1` does — `LiteralInfer` peels for its own
 * shared arms too, which is what keeps a field, a parameter and a local in agreement.
 * Any unset seam (or absent index) degrades that shape to report-only; an unset
 * `parenKind` simply means no unwrapping.
 */
@:nullSafety(Strict)
final class ExplicitLocalType implements Check implements DefaultOff implements OracleAssisted implements ConfigAware {

	private static inline final RULE_ID: String = 'explicit-local-type';

	/**
	 * Builtin type names available in EVERY Haxe file without an import — the only types a
	 * cross-file static-field source may be copied verbatim as (a non-builtin name might not
	 * resolve in, or could bind differently in, the consumer's import scope). Drives
	 * `allComponentsAlwaysInScope`.
	 */
	private static final ALWAYS_IN_SCOPE: Array<String> = [
		'Int',
		'UInt',
		'Float',
		'Bool',
		'String',
		'Void',
		'Dynamic',
		'Any',
		'Null',
		'Array',
		'Map'
	];

	/**
	 * Always-in-scope constructor types with NO type parameters — a bare `new T()`'s
	 * written name is provably its complete type. Consulted only when the project
	 * index declares no same-named type (an indexed declaration's arity wins).
	 */
	private static final NON_GENERIC_NEW_TYPES: Array<String> = [
		'StringBuf',
		'EReg',
		'Date',
		'StringInput',
		'BytesBuffer',
		'BytesInput',
		'BytesOutput',
		'Http'
	];

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
		final declaredTypeSources: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, source);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null || node.children.length == 0) continue;
			final init: QueryNode = node.children[0];
			final typeSource: Null<String> = inferLocalType(init, source, shape, tree, castTargets, declaredTypeSources, index);
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
	 * The structurally-certain type of a local's `init`, with every enclosing parenthesis
	 * layer peeled off FIRST (`RefactorSupport.unwrapParens` via the grammar's `parenKind`
	 * seam) — `(-1)` is the same `Int` as `-1`, and every arm dispatches on the node KIND,
	 * so a wrapped initializer would otherwise miss all of them. The arms: the shared
	 * `LiteralInfer` shapes (literal / neg-numeric / written-generic `new` / cast), then a
	 * bare non-generic `new T()`, a homogeneous array literal, a fixed-return method call on
	 * a provable-String receiver, a cross-class `Type.staticField` read (via `index`), and a
	 * plain identifier read whose binding carries a written type. Null when none pins the
	 * type.
	 *
	 * There are TWO peels and they overlap. `LiteralInfer.inferType` peels for itself, so a
	 * field and a parameter agree with a local on the shared shapes; on those shapes either
	 * peel alone would do, the second landing on an already-peeled node as a no-op. Each is
	 * still load-bearing for what only it reaches — this one for the local-only arms listed
	 * above, `LiteralInfer`'s for `explicit-type`'s fields and parameters, which never pass
	 * through here.
	 *
	 * Unwrapping NARROWS the node, so every span-reading arm (the cast lookup, the `new`
	 * type scan, the resolver's scope + shadow guards) sees the real expression's own
	 * position rather than the wrapper's — the same view it would have without the parens;
	 * `insertPoint` still takes the ORIGINAL initializer.
	 */
	private static function inferLocalType(
		rawInit: QueryNode, source: String, shape: RefShape, tree: QueryNode, castTargets: () -> Map<Int, String>,
		declaredTypeSources: () -> Map<Int, String>, index: Null<SymbolIndex>
	): Null<String> {
		final init: QueryNode = RefactorSupport.unwrapParens(rawInit, shape.parenKind);
		return
			LiteralInfer.inferType(init, source, shape, castTargets) ?? bareNewType(init, source, shape, index) ?? arrayType(init, shape) ?? methodReturnType(
				init, shape, tree, declaredTypeSources
			) ?? staticFieldType(init, shape, tree, index) ?? TypeResolver.identDeclaredTypeSource(
				init, shape, tree, declaredTypeSources, true
			);
	}

	/**
	 * The written type of a bare (parameterless) `new T(...)` initializer, when `T`
	 * is provably non-generic: a name every indexed declaration agrees has zero type
	 * parameters, or — when the index declares no such name — a whitelisted
	 * always-in-scope constructor type. A generic, ambiguous-arity or unknown `T`
	 * stays report-only (a bare `:T` annotation would be a compile error or an
	 * inference change), as does a written-generic `new` (`newTypeSource`'s arm).
	 */
	private static function bareNewType(init: QueryNode, source: String, shape: RefShape, index: Null<SymbolIndex>): Null<String> {
		final newKind: Null<String> = shape.newExprKind;
		if (newKind == null || init.kind != newKind) return null;
		final written: Null<String> = LiteralInfer.bareNewTypeName(init, source);
		if (written == null) return null;
		final simple: String = written.substring(written.lastIndexOf('.') + 1);
		if (index != null && index.declaringFiles(simple).length > 0)
			// Declared in the index: provably non-generic ONLY when every declaration agrees on zero type
			// parameters. A unanimous non-zero arity, or an ambiguous one (declarations disagree, so
			// typeParamArityOf returns null), both fail `== 0` and stay report-only — ambiguity must never
			// prove non-genericity.
			return index.typeParamArityOf(simple) == 0 ? written : null;
		// Undeclared anywhere in the index: the whitelist of always-in-scope non-generic stdlib
		// constructors is the only remaining signal.
		return NON_GENERIC_NEW_TYPES.contains(simple) ? written : null;
	}

	/**
	 * The verbatim declared type SOURCE of a cross-class static field read `Type.field` —
	 * a `fieldAccessKind` init whose single receiver child is an upper-initial `identKind`
	 * TYPE reference (not a value binding) — looked up in the cross-file `index`
	 * (`memberTypeSourceOf`, `Null<…>` preserved). Returned ONLY when EVERY nominal
	 * component of that source is an ALWAYS-IN-SCOPE builtin (`ALWAYS_IN_SCOPE`): the
	 * source is spelled in the field's DECLARING file, so a non-builtin name may not
	 * resolve in the consumer's import scope (a copied `Foo` needs an `import` the consumer
	 * may lack, or could bind to a different `Foo`) — a builtin is unambiguously in scope
	 * everywhere. A qualified receiver (`pkg.Type.field`, whose receiver is itself a field
	 * access), a lower-initial or value-bound receiver (an INSTANCE access, left
	 * report-only), an absent / ambiguous type or member, a member with no written type, or
	 * a non-builtin-typed member all yield null. Null too when no `index` is threaded (the
	 * receiver is cross-file, so the single-source resolver cannot reach it).
	 */
	private static function staticFieldType(init: QueryNode, shape: RefShape, tree: QueryNode, index: Null<SymbolIndex>): Null<String> {
		if (index == null) return null;
		final faKind: Null<String> = shape.fieldAccessKind;
		final identKind: Null<String> = shape.identKind;
		if (faKind == null || identKind == null) return null;
		if (init.kind != faKind || init.children.length != 1) return null;
		final member: Null<String> = init.name;
		if (member == null) return null;
		final recv: QueryNode = init.children[0];
		final typeName: Null<String> = recv.name;
		final span: Null<Span> = recv.span;
		if (recv.kind != identKind || typeName == null || span == null || !RefactorSupport.isUpperInitial(typeName)) return null;
		// A receiver that resolves to a local / parameter / field binding is a value — an
		// INSTANCE field access, a distinct (cross-type instance) case not handled here.
		// A genuine type reference resolves to no value binding.
		if (TypeResolver.resolveBindingFrom(typeName, span, tree, shape) != null) return null;
		final typeSrc: Null<String> = index.memberTypeSourceOf(typeName, member);
		// The source is spelled in the DECLARING file; copy it into the consumer only when
		// every component is a builtin guaranteed in scope there (see the doc).
		return typeSrc != null && allComponentsAlwaysInScope(typeSrc) ? typeSrc : null;
	}

	/**
	 * Whether every nominal (identifier) component of the type source `typeSrc` is an
	 * `ALWAYS_IN_SCOPE` builtin — so the source resolves in ANY file without an import.
	 * Scans maximal identifier runs (splitting on `<`, `>`, `,`, `.`, whitespace); a
	 * dotted / generic component whose every segment is builtin still passes, while any
	 * user-type segment (an unqualified `Foo`, a package segment) fails.
	 */
	private static function allComponentsAlwaysInScope(typeSrc: String): Bool {
		final n: Int = typeSrc.length;
		var i: Int = 0;
		while (i < n) {
			if (!RefactorSupport.isIdentStartChar(StringTools.fastCodeAt(typeSrc, i))) {
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n && RefactorSupport.isIdentChar(StringTools.fastCodeAt(typeSrc, i))) i++;
			if (!ALWAYS_IN_SCOPE.contains(typeSrc.substring(start, i))) return false;
		}
		return true;
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
		return ret == null ? null : receiverIsString(callee.children[0], shape, tree, declaredTypeSources) ? ret : null;
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
		if (stringType == null) return false;
		// A String method on a `Null<String>` / optional-param receiver still returns the tabled
		// type (`split` -> `Array<String>` regardless), so this path wants the DECLARED type and
		// must NOT drop optional params (`skipNullableOptionalParam = false`).
		final typeSrc: Null<String> = TypeResolver.identDeclaredTypeSource(recv, shape, tree, declaredTypeSources, false);
		return typeSrc != null && unwrapNullable(typeSrc, shape) == stringType;
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


	/**
	 * The compiler-oracle TAIL of the autofix: for each finding the structural arm left
	 * report-only, ask the `TypeOracle` for the compiler's OWN inferred type at the
	 * local's name token, reject the ones no sound annotation can restate
	 * (`normalizeInferredType`), and emit `:Type` for the rest. Entered only when the
	 * project configures a `compilerOracle` — `Cli.applyLintFixes` verifies each edited
	 * file still typechecks and reverts it otherwise, so an over-eager annotation is
	 * caught rather than shipped. The query byte position is `insertPoint - 1` (the name
	 * token's last char, a position the display protocol resolves; the char AFTER the
	 * name is not a completion point); the SAME `insertPoint` is the edit anchor.
	 */
	public function fixWithOracle(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, oracle: TypeOracle
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final locals: Array<String> = shape.localDeclKinds ?? [];
		final tree: Null<QueryNode> = locals.length == 0 ? null : CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, locals, byKey);
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final importMap: Map<String, String> = provider != null ? provider.importMap(source) : [];
		final maxAnon: Int = maxAnonLen(violations);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null || node.children.length == 0) continue;
			final at: Int = LiteralInfer.insertPoint(node, node.children[0], source);
			if (at <= 0) continue;
			final raw: Null<String> = oracle.typeAt(v.file, at - 1);
			if (raw == null) continue;
			final norm: Null<String> = normalizeInferredType(raw, importMap, maxAnon);
			if (norm != null) edits.push({ span: new Span(at, at), text: ':$norm' });
		}
		return edits;
	}

	/** Inject the linter's per-file config resolver (for `maxInferredTypeLength`), or null to fall back to `discover`. */
	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_configResolver = resolve;
	}

	/**
	 * The `maxInferredTypeLength` cap (chars) for an anonymous-structure annotation,
	 * read from the file's `apqlint.json` via the injected resolver (or discovered), or
	 * `DEFAULT_MAX_ANON_LEN` when unset. Resolved off the first violation's file — the
	 * oracle pass groups a `fixWithOracle` call per file.
	 */
	private function maxAnonLen(violations: Array<Violation>): Int {
		if (violations.length == 0) return DEFAULT_MAX_ANON_LEN;
		final cfg: LintConfig = LintConfig.resolveWith(_configResolver, violations[0].file);
		return cfg.intOption(RULE_ID, 'maxInferredTypeLength') ?? DEFAULT_MAX_ANON_LEN;
	}

	/**
	 * Normalise a compiler-inferred type text to a sound, short annotation, or null when
	 * no annotation should be written. REJECTS: a monomorph / inference hole (`Unknown<`
	 * — the compiler could not pin it either), an anonymous structure longer than
	 * `maxAnonLen` (annotatable but noisy), and a bare `_` type-param placeholder (not a
	 * nameable type; a clean function type or a small anon struct is kept). Otherwise
	 * shortens qualified nominals to the file's short form where provably in scope
	 * (`shortenType`), leaving anything else fully qualified (which always resolves).
	 * PURE: unit-testable with a plain `importMap` and no compiler.
	 */
	public static function normalizeInferredType(raw: String, importMap: Map<String, String>, maxAnonLen: Int): Null<String> {
		final t: String = StringTools.trim(raw);
		if (t == '') return null;
		if (t.indexOf('Unknown<') != -1) return null;
		if (t.indexOf('{') != -1 && t.length > maxAnonLen) return null;
		if (hasBareUnderscore(t)) return null;
		return shortenType(t, importMap);
	}

	/** Whether `t` contains a standalone `_` identifier run — an unnameable type-param placeholder. */
	private static function hasBareUnderscore(t: String): Bool {
		final n: Int = t.length;
		var i: Int = 0;
		while (i < n) {
			if (!RefactorSupport.isIdentChar(StringTools.fastCodeAt(t, i))) {
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n && RefactorSupport.isIdentChar(StringTools.fastCodeAt(t, i))) i++;
			if (t.substring(start, i) == '_') return true;
		}
		return false;
	}

	/**
	 * Rewrite every maximal qualified-nominal run (`[A-Za-z0-9_.]+`) of `t` to its short
	 * form where that is provably in scope, copying generic punctuation / spaces / field
	 * names verbatim. A dotted run shortens to its simple name when the simple name is an
	 * always-in-scope builtin (`haxe.ds.Map` -> `Map`) or the file imports EXACTLY that
	 * FQN (`importMap[simple] == run`); otherwise the run stays fully qualified — which
	 * resolves in any file — so the result never fails to compile for want of an import.
	 */
	private static function shortenType(t: String, importMap: Map<String, String>): String {
		final buf: StringBuf = new StringBuf();
		final n: Int = t.length;
		var i: Int = 0;
		while (i < n) {
			final c: Int = StringTools.fastCodeAt(t, i);
			if (!RefactorSupport.isIdentChar(c) && c != '.'.code) {
				buf.addChar(c);
				i++;
				continue;
			}
			final start: Int = i;
			while (i < n) {
				final cc: Int = StringTools.fastCodeAt(t, i);
				if (!RefactorSupport.isIdentChar(cc) && cc != '.'.code) break;
				i++;
			}
			buf.add(shortenComponent(t.substring(start, i), importMap));
		}
		return buf.toString();
	}

	/** Short form of ONE nominal run when provably in scope (builtin or exact-FQN import), else the run verbatim (fully qualified always resolves). */
	private static function shortenComponent(run: String, importMap: Map<String, String>): String {
		final dot: Int = run.lastIndexOf('.');
		if (dot < 0) return run;
		final simple: String = run.substring(dot + 1);
		if (ALWAYS_IN_SCOPE.contains(simple)) return simple;
		final imported: Null<String> = importMap.get(simple);
		return imported != null && imported == run ? simple : run;
	}

	/** The per-file config resolver injected by the linter (`ConfigAware`), or null to fall back to `LintConfig.discover`. */
	private var _configResolver: Null<(String) -> LintConfig> = null;

	/** Default `maxInferredTypeLength`: an anonymous-structure annotation longer than this stays report-only. */
	private static inline final DEFAULT_MAX_ANON_LEN: Int = 80;

}
