package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
 * receiver to `m[k]` would not compile. So the check flags only when the receiver is a plain
 * identifier whose declared outer-nominal type (via `TypeResolver.identTypeName`) is a
 * `RefShape.mapAbstractTypeNames` (`Map`), OR a `RefShape.nullableWrapperTypeNames` (`Null`)
 * whose verbatim `:Type` source (`TypeInfoProvider.declaredTypeSources`) unwraps to a
 * `mapAbstractTypeNames` nominal (`Null<Map<…>>`). An unresolvable receiver, a `StringMap` /
 * `IntMap` / other concrete-map or unrelated type, and a non-simple receiver
 * (`this.m.get(k)`, `obj.m.get(k)`) are all conservative misses.
 *
 * ## Arity + position
 *
 * A `get` call must have exactly one argument and a `set` call exactly two (`m.get(k, d)` /
 * `m.set(k)` are a foreign method or a nonexistent overload — not rewritten). The `set`
 * rewrite produces an ASSIGNMENT (`m[k] = v`), valid only in STATEMENT position, so `fix`
 * emits it only when the call is a direct child of an `exprStatementKind` (`ExprStmt`); a
 * `set` used as an expression is still flagged but left for a human. A `get` rewrite is an
 * expression and fixes anywhere (`m.get(k).foo`, `f(m.get(k))`). Nested matches
 * (`m.get(n.get(k))`) yield overlapping edits; `RefactorSupport.dropContainedEdits` keeps
 * the outer, the inner is caught on the next `--fix` pass.
 *
 * ## Grammar-agnostic
 *
 * Driven by `identKind`, `callKind`, `fieldAccessKind`, `exprStatementKind`,
 * `mapAbstractTypeNames`, and `nullableWrapperTypeNames` (any missing kind → no-op); all
 * type resolution requires `plugin is TypeInfoProvider`.
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
		final cfgValue: Cfg = cfg;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			final declaredTypes: Map<Int, String> = cfgValue.typed.declaredTypes(entry.source);
			final declaredTypeSources: Map<Int, String> = cfgValue.typed.declaredTypeSources(entry.source);
			collect(
				tree, tree, null, declaredTypes, declaredTypeSources, cfgValue, m -> violations.push({
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

	/** Rewrite each flagged `get` to `m[k]` and each statement-position `set` to `m[k] = v`. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final cfg: Null<Cfg> = config(plugin);
		if (cfg == null) return [];
		final cfgValue: Cfg = cfg;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final declaredTypes: Map<Int, String> = cfgValue.typed.declaredTypes(source);
		final declaredTypeSources: Map<Int, String> = cfgValue.typed.declaredTypeSources(source);
		final byKey: Map<String, Match> = [];
		collect(tree, tree, null, declaredTypes, declaredTypeSources, cfgValue, m -> byKey['${m.callSpan.from}:${m.callSpan.to}'] = m);
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
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/** Walk `node`, invoking `sink` for every `get` / `set` call on a `Map`-abstract receiver. */
	private static function collect(
		node: QueryNode, root: QueryNode, parentKind: Null<String>, declaredTypes: Map<Int, String>, declaredTypeSources: Map<Int, String>,
		cfg: Cfg, sink: Match -> Void
	): Void {
		if (cfg.opaqueKinds.contains(node.kind)) return;
		if (node.kind == cfg.callKind) {
			final m: Null<Match> = match(node, parentKind, root, declaredTypes, declaredTypeSources, cfg);
			if (m != null) sink(m);
		}
		for (c in node.children) collect(c, root, node.kind, declaredTypes, declaredTypeSources, cfg, sink);
	}

	/**
	 * If `call` is a `Map`-abstract `get(k)` / `set(k, v)` on a plain-identifier receiver,
	 * return the resolved match; else null. Enforces the exact arity and the receiver-type gate.
	 */
	private static function match(
		call: QueryNode, parentKind: Null<String>, root: QueryNode, declaredTypes: Map<Int, String>, declaredTypeSources: Map<Int, String>,
		cfg: Cfg
	): Null<Match> {
		if (call.children.length < 1) return null;
		final callee: QueryNode = call.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != cfg.fieldKind || method == null || callee.children.length != 1) return null;
		final recv: QueryNode = callee.children[0];
		if (recv.kind != cfg.identKind) return null;
		final isSet: Bool = if (method == GET_METHOD && call.children.length == GET_ARG_COUNT + 1)
			false;
		else if (method == SET_METHOD && call.children.length == SET_ARG_COUNT + 1)
			true;
		else
			return null;
		if (!receiverIsMap(recv, root, declaredTypes, declaredTypeSources, cfg)) return null;
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

	/** The rewrite text for `m`, or null when it is a `set` outside statement position (no safe expression form). */
	private static function editText(m: Match, source: String): Null<String> {
		final recvSpan: Null<Span> = m.recv.span;
		final keySpan: Null<Span> = m.key.span;
		if (recvSpan == null || keySpan == null) return null;
		final recvSrc: String = source.substring(recvSpan.from, recvSpan.to);
		final keySrc: String = source.substring(keySpan.from, keySpan.to);
		if (!m.isSet) return recvSrc + '[' + keySrc + ']';
		if (!m.isStatement) return null;
		final value: Null<QueryNode> = m.value;
		if (value == null) return null;
		final valSpan: Null<Span> = value.span;
		return valSpan == null ? null : recvSrc + '[' + keySrc + '] = ' + source.substring(valSpan.from, valSpan.to);
	}

	/**
	 * Whether `recv` is a plain identifier whose declared type resolves to a `Map`-abstract
	 * nominal — directly (`Map`), or a nullable wrapper unwrapping to one (`Null<Map<…>>`).
	 * An unresolved binding / type is a conservative miss.
	 */
	private static function receiverIsMap(
		recv: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, declaredTypeSources: Map<Int, String>, cfg: Cfg
	): Bool {
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(recv, root, cfg.shape);
		if (bindingFrom == null) return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		if (cfg.mapTypes.contains(typeName)) return true;
		if (!cfg.nullableWrappers.contains(typeName)) return false;
		final src: Null<String> = declaredTypeSources[bindingFrom];
		return src != null && nullWrapsMap(src, typeName, cfg.mapTypes);
	}

	/** Whether the verbatim type `source` is `wrapper<Nominal…>` whose inner nominal is a `mapTypes` name. */
	private static function nullWrapsMap(source: String, wrapper: String, mapTypes: Array<String>): Bool {
		final s: String = StringTools.trim(source);
		final prefix: String = wrapper + '<';
		if (!StringTools.startsWith(s, prefix) || !StringTools.endsWith(s, '>')) return false;
		final inner: String = s.substring(prefix.length, s.length - 1);
		final lt: Int = inner.indexOf('<');
		final head: String = lt == -1 ? inner : inner.substring(0, lt);
		final simple: Null<String> = TypeResolver.simpleNominalName(head);
		return simple != null && mapTypes.contains(simple);
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
};
