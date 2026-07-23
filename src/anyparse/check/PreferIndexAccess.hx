package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a `Map` read / write spelled as a method call where index access is idiomatic —
 * `m.get(k)` → `m[k]`, `m.set(k, v)` → `m[k] = v` — per the user preference "access values
 * with `map[key]`, set with `map[key] = value`". `Severity.Info` (a modernization cleanup),
 * with an autofix.
 *
 * ## The receiver type is load-bearing — Map ABSTRACT only
 *
 * `m.get(k)` / `m.set(k, v)` share their AST with a call to any `get` / `set` method on any
 * type, and index access `x[k]` / `x[k] = v` is valid ONLY on Haxe's `Map` abstract (its
 * `@:arrayAccess` operators). The concrete `haxe.ds.StringMap` / `IntMap` / `ObjectMap`
 * classes carry `.get` / `.set` but NO array access, so rewriting a `StringMap`-typed
 * receiver to `m[k]` would not compile. So the check flags only when the receiver's declared
 * outer-nominal type is a `RefShape.mapAbstractTypeNames` (`Map`), OR a
 * `RefShape.nullableWrapperTypeNames` (`Null`) whose verbatim `:Type` source unwraps to a
 * `mapAbstractTypeNames` nominal (`Null<Map<…>>`). The receiver may be a bare identifier
 * (resolved via `TypeResolver.identBindingFrom` + `TypeInfoProvider.declaredTypes`) OR a PATH
 * — a chain of plain field accesses over an identifier or `this` (`this.m`, `obj.m`, `a.b.c`),
 * whose root resolves the same way and whose field segments resolve cross-file through a
 * `SymbolIndex` (`RefactorSupport.pathRootTypeName` / `pathFinalMemberTypeSource`). An
 * unresolvable receiver, a `StringMap` / `IntMap` / other concrete-map or unrelated type, and
 * a receiver with a call / index access / `?.` link anywhere in its path are all conservative
 * misses — the rule never flags without positive Map proof, since rewriting a non-Map to `[]`
 * is a compile error.
 *
 * ## Arity + position
 *
 * A `get` call must have exactly one argument and a `set` call exactly two (`m.get(k, d)` /
 * `m.set(k)` are a foreign method or a nonexistent overload — not rewritten). The `set`
 * rewrite produces an ASSIGNMENT (`m[k] = v` / `obj.m[k] = v`), valid only in STATEMENT
 * position, so `fix` emits it only when the call is a direct child of an `exprStatementKind`
 * (`ExprStmt`); a `set` used as an expression is still flagged but left for a human. An
 * unbraced control-flow branch body (`if (c) m.set(k, v);`) is still an `ExprStmt` — statement
 * position — so the `set` fix DOES fire there, producing `if (c) m[k] = v;`. A `get` rewrite
 * is an expression and fixes anywhere (`m.get(k).foo`, `f(m.get(k))`). Nested matches
 * (`m.get(n.get(k))`) yield overlapping edits; `RefactorSupport.dropContainedEdits` keeps the
 * outer, the inner is caught on the next `--fix` pass.
 *
 * ## Cross-file scope
 *
 * A path receiver's member types resolve through a `SymbolIndex` over the file set `run` is
 * given, so on a changed-files SUBSET a type declared elsewhere reads as unresolvable and the
 * finding is re-skipped. To keep nested cross-file lookups exposed by an earlier `--fix` pass
 * converging, the check is listed among the `Cli` fixed-point loop's full-scope ids. `fix`
 * itself needs no index: it re-extracts each call's structural shape and keeps only the spans
 * `run` already validated.
 *
 * ## Grammar-agnostic
 *
 * Driven by `identKind`, `callKind`, `fieldAccessKind`, `exprStatementKind`,
 * `mapAbstractTypeNames`, and `nullableWrapperTypeNames` (any missing kind → no-op); all type
 * resolution requires `plugin is TypeInfoProvider`.
 */
@:nullSafety(Strict)
final class PreferIndexAccess implements Check {

	private static inline final GET_METHOD: String = 'get';
	private static inline final SET_METHOD: String = 'set';
	private static inline final GET_ARG_COUNT: Int = 1;
	private static inline final SET_ARG_COUNT: Int = 2;
	private static inline final GET_MESSAGE: String = 'read a map value with map[key] instead of map.get(key)';
	private static inline final SET_MESSAGE: String = 'set a map value with map[key] = value instead of map.set(key, value)';

	public function new() {}

	public function id(): String {
		return 'prefer-index-access';
	}

	public function description(): String {
		return 'a Map get/set call (m.get(k) / m.set(k, v)) replaceable with index access (m[k] / m[k] = v)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final cfg: Null<Cfg> = config(plugin);
		if (cfg == null) return [];
		final c: Cfg = cfg;
		final violations: Array<Violation> = [];
		// A path receiver's member types resolve cross-file; the index is built at most once, on
		// first demand, because most runs never reach a path receiver that cleared every other gate.
		final resolveSymbols: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = c.typed.declaredTypes(entry.source);
			final declaredTypeSources: Map<Int, String> = c.typed.declaredTypeSources(entry.source);
			final matcher: (
				QueryNode, Null<String>
			) -> Null<Match> = (call, parentKind) ->
				match(call, parentKind, root, declaredTypes, declaredTypeSources, c, resolveSymbols, entry.file);
			collect(
				root, null, c, matcher, m -> violations.push({
					file: entry.file,
					span: m.callSpan,
					rule: 'prefer-index-access',
					severity: Severity.Info,
					message: m.isSet ? SET_MESSAGE : GET_MESSAGE
				})
			);
		}
		return violations;
	}

	/** Rewrite each flagged `get` to `m[k]` and each statement-position `set` to `m[k] = v`, trusting `run`'s validated spans. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final cfg: Null<Cfg> = config(plugin);
		if (cfg == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, Match> = [];
		collect(
			tree, null, cfg, (call, parentKind) -> structuralMatch(call, parentKind, cfg),
			m -> byKey['${m.callSpan.from}:${m.callSpan.to}'] = m
		);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final m: Null<Match> = byKey['${span.from}:${span.to}'];
			if (m == null) continue;
			final text: Null<String> = editText(m, source);
			if (text != null) edits.push({ span: m.callSpan, text: text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Resolve the per-grammar seams + type provider, or null when the grammar lacks a needed kind / type info. */
	private static function config(plugin: GrammarPlugin): Null<Cfg> {
		final shape: RefShape = plugin.refShape();
		final identKind: Null<String> = shape.identKind;
		final callKind: Null<String> = shape.callKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final mapTypes: Array<String> = shape.mapAbstractTypeNames ?? [];
		if (identKind == null || callKind == null || fieldKind == null || exprStmtKind == null || mapTypes.length == 0) return null;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return null;
		final typed: TypeInfoProvider = provider;
		return {
			shape: shape,
			typed: typed,
			identKind: identKind,
			callKind: callKind,
			fieldKind: fieldKind,
			exprStmtKind: exprStmtKind,
			mapTypes: mapTypes,
			nullableWrappers: shape.nullableWrapperTypeNames ?? [],
			opaqueKinds: shape.opaqueKinds ?? [],
			ternaryKind: shape.ternaryKind,
			nullCoalKind: shape.nullCoalesceKind,
			eqKind: shape.eqKind,
			notEqKind: shape.notEqKind,
			nullLitKind: shape.nullLiteralKind
		};
	}

	/** Walk `node`, invoking `sink` for every `get` / `set` call on a `Map`-abstract receiver. */
	private static function collect(
		node: QueryNode, parentKind: Null<String>, cfg: Cfg, matcher: (QueryNode, Null<String>) -> Null<Match>, sink: Match -> Void
	): Void {
		if (cfg.opaqueKinds.contains(node.kind)) return;
		if (node.kind == cfg.callKind) {
			final m: Null<Match> = matcher(node, parentKind);
			if (m != null) sink(m);
		}
		for (c in node.children) collect(c, node.kind, cfg, matcher, sink);
	}

	/**
	 * If `call` is a `Map`-abstract `get(k)` / `set(k, v)` on an identifier or path receiver,
	 * return the resolved match; else null. Layers the receiver-type gate and the
	 * INFERENCE-FRAGILITY gate onto the structural shape from `structuralMatch`: a key (or set
	 * value) whose subtree contains a null guard — a null-comparison ternary or `??` — with an
	 * inference-open fallback is a conservative miss, because dropping the method-argument context
	 * (`m[k]` types the key in VALUE mode) would flip that fallback's inferred constraint to
	 * `Null<…>` and break an active `@:nullSafety` scope downstream
	 * (`TypeResolver.isInferenceFragileNullGuard`).
	 */
	private static function match(
		call: QueryNode, parentKind: Null<String>, root: QueryNode, declaredTypes: Map<Int, String>, declaredTypeSources: Map<Int, String>,
		cfg: Cfg, symbols: () -> Null<SymbolIndex>, file: String
	): Null<Match> {
		final m: Null<Match> = structuralMatch(call, parentKind, cfg);
		if (m == null) return null;
		final matched: Match = m;
		if (!receiverIsMap(matched.recv, root, declaredTypes, declaredTypeSources, cfg, symbols, file)) return null;
		for (i in 1...call.children.length) {
			if (containsFragileNullGuard(call.children[i], matched.callSpan, root, declaredTypes, cfg)) return null;
		}
		return matched;
	}

	/** The rewrite text for `m`, or null when it is a `set` outside statement position (no safe expression form). */
	private static function editText(m: Match, source: String): Null<String> {
		final recvSpan: Null<Span> = m.recv.span;
		final keySpan: Null<Span> = m.key.span;
		if (recvSpan == null || keySpan == null) return null;
		final recvSrc: String = source.substring(recvSpan.from, recvSpan.to);
		final keySrc: String = source.substring(keySpan.from, keySpan.to);
		if (!m.isSet) return '$recvSrc[$keySrc]';
		if (!m.isStatement) return null;
		final value: Null<QueryNode> = m.value;
		if (value == null) return null;
		final valSpan: Null<Span> = value.span;
		return valSpan == null ? null : '$recvSrc[$keySrc] = ${source.substring(valSpan.from, valSpan.to)}';
	}

	/**
	 * Whether `recv` is an identifier or path whose declared type resolves to a `Map`-abstract
	 * nominal — directly (`Map`), or a nullable wrapper unwrapping to one (`Null<Map<…>>`). A bare
	 * identifier resolves through its binding annotation; a path resolves its root the same way
	 * (or, for `this`, the enclosing type; or, for a static TYPE-name root, the unique type it
	 * names in scope) and walks each field segment's member type cross-file through `symbols`. An
	 * unresolved binding / path / type is a conservative miss — index access `[]` compiles only on
	 * the abstract, so this gate never flags without positive Map proof.
	 */
	private static function receiverIsMap(
		recv: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, declaredTypeSources: Map<Int, String>, cfg: Cfg,
		symbols: () -> Null<SymbolIndex>, file: String
	): Bool {
		final path: Null<Array<String>> = RefactorSupport.pathOf(recv, cfg.identKind, cfg.fieldKind);
		if (path == null) return false;
		if (path.length == 1) {
			final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(recv, root, cfg.shape);
			if (bindingFrom == null) return false;
			final typeName: Null<String> = declaredTypes[bindingFrom];
			return typeName != null && nominalIsMap(typeName, declaredTypeSources[bindingFrom], cfg);
		}
		final index: Null<SymbolIndex> = symbols();
		if (index == null) return false;
		// A value / this root resolves through the simple-name segment walk; a static TYPE-name
		// root (no value binding) resolves import-aware from the reference file's scope.
		final rootType: Null<String> = RefactorSupport.pathRootTypeName(recv, root, declaredTypes, cfg.shape);
		final src: Null<String> = RefactorSupport.pathReceiverMemberTypeSource(path, rootType, index, file);
		if (src == null) return false;
		final nominal: Null<String> = RefactorSupport.outerNominalOf(src);
		return nominal != null && nominalIsMap(nominal, src, cfg);
	}

	/** Whether the verbatim type `source` is `wrapper<Nominal…>` whose inner nominal is a `mapTypes` name. */
	private static function nullWrapsMap(source: String, wrapper: String, mapTypes: Array<String>): Bool {
		final s: String = StringTools.trim(source);
		final prefix: String = '$wrapper<';
		if (!StringTools.startsWith(s, prefix) || !StringTools.endsWith(s, '>')) return false;
		final inner: String = s.substring(prefix.length, s.length - 1);
		final lt: Int = inner.indexOf('<');
		final head: String = lt == -1 ? inner : inner.substring(0, lt);
		final simple: Null<String> = TypeResolver.simpleNominalName(head);
		return simple != null && mapTypes.contains(simple);
	}


	/**
	 * Whether `node`'s subtree contains a null guard — a ternary whose condition compares
	 * against the null literal, or a `??` — whose FALLBACK operand (the branch taken when the
	 * guarded value IS null: the else-branch of `!=`, the then-branch of `==`, the right
	 * operand of `??`) is inference-fragile at `site`. For the ternary the identity shape is
	 * NOT required: any null-comparison ternary re-typed in value mode lets the comparison's
	 * `Null<…>` reach branch unification, so only the fallback's openness matters.
	 */
	private static function containsFragileNullGuard(
		node: QueryNode, site: Span, root: QueryNode, declaredTypes: Map<Int, String>, cfg: Cfg
	): Bool {
		if (node.kind == cfg.ternaryKind && node.children.length == 3) {
			final cond: QueryNode = node.children[0];
			final eq: Bool = cond.kind == cfg.eqKind;
			if (
				(eq || cond.kind == cfg.notEqKind) && cond.children.length == 2 && cfg.nullLitKind != null
				&& (cond.children[0].kind == cfg.nullLitKind || cond.children[1].kind == cfg.nullLitKind)
			) {
				final fallback: QueryNode = eq ? node.children[1] : node.children[2];
				if (TypeResolver.isInferenceFragileNullGuard(fallback, site, root, cfg.shape, declaredTypes)) return true;
			}
		}
		if (
			node.kind == cfg.nullCoalKind && node.children.length == 2
			&& TypeResolver.isInferenceFragileNullGuard(node.children[1], site, root, cfg.shape, declaredTypes)
		)
			return true;
		for (c in node.children) if (containsFragileNullGuard(c, site, root, declaredTypes, cfg)) return true;
		return false;
	}


	/**
	 * The structural shape of a `get(k)` / `set(k, v)` call on an identifier or path receiver —
	 * the arity check, the receiver as a plain path, and the key / value / statement-position
	 * extraction — WITHOUT the type gate. `run` layers the type + null-guard gates on top; `fix`
	 * uses it alone and keeps only the spans `run` already flagged, so the fix trusts detection
	 * and needs no cross-file index of its own.
	 */
	private static function structuralMatch(call: QueryNode, parentKind: Null<String>, cfg: Cfg): Null<Match> {
		if (call.children.length < 1) return null;
		final callee: QueryNode = call.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != cfg.fieldKind || method == null || callee.children.length != 1) return null;
		final recv: QueryNode = callee.children[0];
		if (RefactorSupport.pathOf(recv, cfg.identKind, cfg.fieldKind) == null) return null;
		final isSet: Bool = if (method == GET_METHOD && call.children.length == GET_ARG_COUNT + 1)
			false;
		else if (method == SET_METHOD && call.children.length == SET_ARG_COUNT + 1)
			true;
		else
			return null;
		final callSpan: Null<Span> = call.span;
		return callSpan == null ? null : {
			callSpan: callSpan,
			recv: recv,
			key: call.children[1],
			value: isSet ? call.children[2] : null,
			isSet: isSet,
			isStatement: parentKind == cfg.exprStmtKind
		};
	}

	/** Whether `nominal` (with optional verbatim `source`) is a `Map`-abstract name, or a nullable wrapper whose inner nominal is one. */
	private static function nominalIsMap(nominal: String, source: Null<String>, cfg: Cfg): Bool {
		return cfg.mapTypes.contains(nominal)
			|| (source != null && cfg.nullableWrappers.contains(nominal) && nullWrapsMap(source, nominal, cfg.mapTypes));
	}

}

/** A resolved `Map`-abstract `get` / `set` call site. */
private typedef Match = {
	var callSpan: Span;
	var recv: QueryNode;
	var key: QueryNode;
	var value: Null<QueryNode>;
	var isSet: Bool;
	var isStatement: Bool;
};

/** Per-run resolved seams + type provider. */
private typedef Cfg = {
	var shape: RefShape;
	var typed: TypeInfoProvider;
	var identKind: String;
	var callKind: String;
	var fieldKind: String;
	var exprStmtKind: String;
	var mapTypes: Array<String>;
	var nullableWrappers: Array<String>;
	var opaqueKinds: Array<String>;
	var ternaryKind: Null<String>;
	var nullCoalKind: Null<String>;
	var eqKind: Null<String>;
	var notEqKind: Null<String>;
	var nullLitKind: Null<String>;
};
