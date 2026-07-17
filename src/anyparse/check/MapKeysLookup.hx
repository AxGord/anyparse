package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import anyparse.query.RefactorSupport;

/**
 * Flags a `for (k in m.keys())` loop whose body reads the SAME map by the SAME key
 * (`m[k]` or `m.get(k)`) — the keys-then-lookup anti-pattern that re-looks-up every
 * value. Haxe's key-value iteration `for (k => v in m)` binds the value once, with no
 * second lookup and a guaranteed non-null `v`. `Info`, with an autofix: the rewrite
 * (dropping `.keys()`, inventing a value name, replacing every `m[k]` / `m.get(k)` with
 * it, over a mutation-free body) is what the autofix applies.
 *
 * ## The shape it accepts
 *
 * A `for` whose iterable is EXACTLY `<recv>.keys()` — a no-argument `keys` call on a
 * BARE identifier receiver (a chained `a.b.keys()` is skipped, its receiver being a
 * field access, not an identifier) — and whose body contains at least one lookup of
 * that receiver by the loop's key variable: an index access `m[k]` or a `m.get(k)`
 * call, matched by SOURCE-IDENTICAL identifiers (same receiver name AND same key name;
 * `m[j]` / `n[k]` are not matches, so a different key or a different map is not flagged).
 *
 * ## Soundness gates (conservative — a miss over a wrong flag)
 *
 * - **No mutation.** If the body writes the map in any form — `m[...] = …` (or a
 *   compound-assign / increment on `m[...]`, via `RefShape.writeParentKinds`), or a
 *   `m.set(…)` / `m.remove(…)` / `m.clear(…)` call — the loop is SKIPPED: iterating
 *   `keys()` while mutating the map may be deliberate, and key-value iteration during
 *   mutation is not equivalent.
 * - **No re-binding.** If either the receiver name or the key name is re-bound anywhere
 *   in the body (a local declaration, a nested function parameter, or a nested loop
 *   variable of the same name), the inner binding shadows the loop's, so the lookup no
 *   longer refers to the iterated map / key — SKIPPED.
 * - **Type, when known.** When the plugin provides type info and the receiver's declared
 *   type RESOLVES to a concrete NON-map-family nominal (not one of
 *   `RefShape.nullableIndexTypeNames`, and not a `Null` / `Dynamic` / `Any` wrapper), the
 *   loop is SKIPPED — a custom `keys()`-bearing type is not a map. An unresolvable
 *   receiver, or a plugin without type info, still flags: `.keys()` plus `m[k]` / `m.get(k)`
 *   is Map-shaped by construction.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape.forStmtKind` / `identKind` / `callKind` / `fieldAccessKind` /
 * `indexAccessKind` (any unset → no-op), plus `writeParentKinds` for the mutation gate,
 * `localDeclKinds` / `paramKinds` for the re-binding gate, `nullableIndexTypeNames` /
 * `nullableWrapperTypeNames` for the type gate (only when `plugin is TypeInfoProvider`),
 * and `opaqueKinds` to skip macro reification.
 */
@:nullSafety(Strict)
final class MapKeysLookup implements Check {

	private static inline final KEYS_METHOD: String = 'keys';
	private static inline final GET_METHOD: String = 'get';
	private static inline final SET_METHOD: String = 'set';
	private static inline final REMOVE_METHOD: String = 'remove';
	private static inline final CLEAR_METHOD: String = 'clear';

	/** A `get(k)` call has exactly [callee, key-argument] children. */
	private static inline final GET_CALL_CHILD_COUNT: Int = 2;

	/** An index access `m[k]` and a for-loop both have at least [receiver/iterable, key/body]. */
	private static inline final MIN_BINARY_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'map-keys-lookup';
	}

	public function description(): String {
		return 'a for-in over map.keys() that re-looks-up each value, replaceable with key-value iteration (for (k => v in m))';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final cfg: Null<Cfg> = readCfg(plugin);
		if (cfg == null) return [];
		final c: Cfg = cfg;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final declaredTypes: Null<Map<Int, String>> = c.typed == null ? null : c.typed.declaredTypes(entry.source);
			walk(tree, tree, entry.file, declaredTypes, c, violations);
		}
		return violations;
	}

	/**
	 * Rewrite each flagged `for (k in m.keys())` into `for (k => value in m)` — dropping
	 * `.keys()` from the iterable, binding a fresh value variable in the header, and
	 * replacing every `m[k]` / `m.get(k)` lookup in the body with that variable. The value
	 * name is `value`, or `value1`, `value2`… when `value` is already used in the body.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final cfg: Null<Cfg> = readCfg(plugin);
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (cfg == null || tree == null) return [];
		final c: Cfg = cfg;
		final wanted: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) wanted.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		fixWalk(tree, source, c, wanted, edits);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Resolve the required + optional `RefShape` seams and the type provider, or null when a required kind is unset. */
	private static function readCfg(plugin: GrammarPlugin): Null<Cfg> {
		final shape: RefShape = plugin.refShape();
		final forKind: Null<String> = shape.forStmtKind;
		final identKind: Null<String> = shape.identKind;
		final callKind: Null<String> = shape.callKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		final indexKind: Null<String> = shape.indexAccessKind;
		if (forKind == null || identKind == null || callKind == null || fieldKind == null || indexKind == null) return null;
		final typed: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		return {
			shape: shape,
			forKind: forKind,
			identKind: identKind,
			callKind: callKind,
			fieldKind: fieldKind,
			indexKind: indexKind,
			writeParentKinds: shape.writeParentKinds,
			localDeclKinds: shape.localDeclKinds ?? [],
			paramKinds: shape.paramKinds ?? [],
			mapFamily: shape.nullableIndexTypeNames ?? [],
			nullableWrappers: shape.nullableWrapperTypeNames ?? [],
			opaqueKinds: shape.opaqueKinds ?? [],
			typed: typed
		};
	}

	/** Walk `node`, flagging each `for (k in m.keys())` loop that re-looks-up the same map by the same key. */
	private static function walk(
		node: QueryNode, root: QueryNode, file: String, declaredTypes: Null<Map<Int, String>>, cfg: Cfg, out: Array<Violation>
	): Void {
		if (cfg.opaqueKinds.contains(node.kind)) return;
		if (node.kind == cfg.forKind) {
			final v: Null<Violation> = match(node, root, file, declaredTypes, cfg);
			if (v != null) out.push(v);
		}
		for (c in node.children) walk(c, root, file, declaredTypes, cfg, out);
	}

	/**
	 * If `loop` is a `for (k in <recv>.keys())` whose body reads `recv[k]` / `recv.get(k)`
	 * with no mutation of, or re-binding shadowing, the map — and the receiver type is not a
	 * known non-map — return the finding spanned at the `.keys()` iterable; else null.
	 */
	private static function match(
		loop: QueryNode, root: QueryNode, file: String, declaredTypes: Null<Map<Int, String>>, cfg: Cfg
	): Null<Violation> {
		final p = loopParts(loop, cfg);
		if (p == null) return null;
		if (rebinds(p.body, p.recvName, p.keyName, cfg)) return null;
		if (writesMap(p.body, p.recvName, cfg)) return null;
		if (!hasLookup(p.body, p.recvName, p.keyName, cfg)) return null;
		if (!receiverTypeAllows(p.recv, root, declaredTypes, cfg)) return null;
		final iterSpan: Null<Span> = p.iterable.span;
		return iterSpan == null ? null : {
			file: file,
			span: iterSpan,
			rule: 'map-keys-lookup',
			severity: Severity.Info,
			message: 'iterate key-value instead of keys()-then-lookup — for (${p.keyName} => value in ${p.recvName})'
		};
	}

	/**
	 * The reusable structural parts of a `for (k in <recv>.keys())` loop — the key name, the
	 * iterable and body children, the receiver node and its name — or null when the loop is
	 * not a `keys()` iteration over a bare identifier. Shared by `match` and `buildMapEdits`.
	 */
	private static function loopParts(loop: QueryNode, cfg: Cfg): Null<{
		keyName: String,
		iterable: QueryNode,
		body: QueryNode,
		recv: QueryNode,
		recvName: String
	}> {
		if (loop.children.length < MIN_BINARY_CHILD_COUNT) return null;
		final keyName: Null<String> = loop.name;
		if (keyName == null) return null;
		final iterable: QueryNode = loop.children[0];
		final body: QueryNode = loop.children[loop.children.length - 1];
		final recv: Null<QueryNode> = keysReceiver(iterable, cfg);
		if (recv == null) return null;
		final recvName: Null<String> = recv.name;
		if (recvName == null) return null;
		final parts = {
			keyName: keyName,
			iterable: iterable,
			body: body,
			recv: recv,
			recvName: recvName
		};
		return parts;
	}

	/** The receiver identifier node of an `<ident>.keys()` no-argument call, else null. */
	private static function keysReceiver(iterable: QueryNode, cfg: Cfg): Null<QueryNode> {
		if (iterable.kind != cfg.callKind || iterable.children.length != 1) return null;
		final callee: QueryNode = iterable.children[0];
		if (callee.kind != cfg.fieldKind || callee.name != KEYS_METHOD || callee.children.length != 1) return null;
		final recv: QueryNode = callee.children[0];
		return recv.kind == cfg.identKind ? recv : null;
	}

	/** Whether `recvName` or `keyName` is re-bound anywhere in `node` (a local, a nested param, or a nested loop var). */
	private static function rebinds(node: QueryNode, recvName: String, keyName: String, cfg: Cfg): Bool {
		if (cfg.opaqueKinds.contains(node.kind)) return false;
		final introducesBinding: Bool = cfg.localDeclKinds.contains(node.kind) || cfg.paramKinds.contains(node.kind)
			|| node.kind == cfg.forKind;
		if (introducesBinding && (node.name == recvName || node.name == keyName)) return true;
		for (c in node.children) if (rebinds(c, recvName, keyName, cfg)) return true;
		return false;
	}

	/** Whether `node`'s subtree writes the map `recvName` — `recv[...] = …` (or compound / incr) or a `set`/`remove`/`clear` call. */
	private static function writesMap(node: QueryNode, recvName: String, cfg: Cfg): Bool {
		if (cfg.opaqueKinds.contains(node.kind)) return false;
		if (cfg.writeParentKinds.contains(node.kind) && node.children.length >= 1) {
			final target: QueryNode = node.children[0];
			if (target.kind == cfg.indexKind && target.children.length >= 1 && isIdentNamed(target.children[0], recvName, cfg)) return true;
		}
		if (node.kind == cfg.callKind && node.children.length >= 1) {
			final callee: QueryNode = node.children[0];
			if (
				callee.kind == cfg.fieldKind && callee.children.length == 1 && isIdentNamed(callee.children[0], recvName, cfg)
				&& isWriteMethod(callee.name)
			)
				return true;
		}
		for (c in node.children) if (writesMap(c, recvName, cfg)) return true;
		return false;
	}

	/** Whether `node`'s subtree contains a `recv[key]` index access or a `recv.get(key)` call by matching names. */
	private static function hasLookup(node: QueryNode, recvName: String, keyName: String, cfg: Cfg): Bool {
		if (cfg.opaqueKinds.contains(node.kind)) return false;
		if (isLookup(node, recvName, keyName, cfg)) return true;
		for (c in node.children) if (hasLookup(c, recvName, keyName, cfg)) return true;
		return false;
	}

	/** Whether `node` is exactly a `recv[key]` index access or a `recv.get(key)` call — one lookup, no descent. */
	private static function isLookup(node: QueryNode, recvName: String, keyName: String, cfg: Cfg): Bool {
		if (
			node.kind == cfg.indexKind && node.children.length >= MIN_BINARY_CHILD_COUNT && isIdentNamed(node.children[0], recvName, cfg)
			&& isIdentNamed(node.children[1], keyName, cfg)
		)
			return true;
		if (node.kind == cfg.callKind && node.children.length == GET_CALL_CHILD_COUNT) {
			final callee: QueryNode = node.children[0];
			if (
				callee.kind == cfg.fieldKind && callee.name == GET_METHOD && callee.children.length == 1
				&& isIdentNamed(callee.children[0], recvName, cfg) && isIdentNamed(node.children[1], keyName, cfg)
			)
				return true;
		}
		return false;
	}

	/**
	 * Whether the receiver's declared type does not RULE OUT a map — true (flag) when there is
	 * no type info, the binding / type is unresolvable, the type is a map-family nominal, or a
	 * `Null` / `Dynamic` / `Any` wrapper; false (skip) only when it resolves to a concrete non-map type.
	 */
	private static function receiverTypeAllows(recv: QueryNode, root: QueryNode, declaredTypes: Null<Map<Int, String>>, cfg: Cfg): Bool {
		if (declaredTypes == null) return true;
		final dt: Map<Int, String> = declaredTypes;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(recv, root, cfg.shape);
		if (bindingFrom == null) return true;
		final typeName: Null<String> = dt[bindingFrom];
		if (typeName == null) return true;
		if (cfg.mapFamily.contains(typeName)) return true;
		return cfg.nullableWrappers.contains(typeName);
	}

	private static function isIdentNamed(node: QueryNode, name: String, cfg: Cfg): Bool {
		return node.kind == cfg.identKind && node.name == name;
	}

	private static function isWriteMethod(name: Null<String>): Bool {
		return name == SET_METHOD || name == REMOVE_METHOD || name == CLEAR_METHOD;
	}


	/** Mirror of `walk` for the fix path: emit the key-value rewrite for each wanted loop. */
	private static function fixWalk(
		node: QueryNode, source: String, cfg: Cfg, wanted: Array<String>, out: Array<{ span: Span, text: String }>
	): Void {
		if (cfg.opaqueKinds.contains(node.kind)) return;
		if (node.kind == cfg.forKind && node.children.length >= MIN_BINARY_CHILD_COUNT) {
			final iterSpan: Null<Span> = node.children[0].span;
			if (iterSpan != null && wanted.contains('${iterSpan.from}:${iterSpan.to}')) {
				final e: Null<Array<{ span: Span, text: String }>> = buildMapEdits(node, source, cfg);
				if (e != null) for (edit in e) out.push(edit);
			}
		}
		for (c in node.children) fixWalk(c, source, cfg, wanted, out);
	}

	/**
	 * The edits rewriting one `for (k in m.keys())` loop into `for (k => value in m)` with the
	 * body's `m[k]` / `m.get(k)` lookups replaced by the value variable — or null when the header
	 * cannot be located.
	 */
	private static function buildMapEdits(loop: QueryNode, source: String, cfg: Cfg): Null<Array<{ span: Span, text: String }>> {
		final p = loopParts(loop, cfg);
		if (p == null) return null;
		final iterSpan: Null<Span> = p.iterable.span;
		final forSpan: Null<Span> = loop.span;
		final bodySpan: Null<Span> = p.body.span;
		if (iterSpan == null || forSpan == null || bodySpan == null) return null;
		final open: Int = source.indexOf('(', forSpan.from);
		if (open < 0 || open >= iterSpan.from) return null;
		final keyStart: Int = skipSpace(source, open + 1, iterSpan.from);
		if (keyStart + p.keyName.length > source.length || source.substring(keyStart, keyStart + p.keyName.length) != p.keyName)
			return null;
		final valName: String = freshValueName(source, bodySpan, p.recvName, p.keyName);
		final edits: Array<{ span: Span, text: String }> = [
			{ span: new Span(keyStart, iterSpan.to), text: '${p.keyName} => $valName in ${p.recvName}' }
		];
		collectLookupEdits(p.body, p.recvName, p.keyName, cfg, valName, edits);
		return edits;
	}

	/** Push a `{span → value}` edit for every `recv[key]` / `recv.get(key)` lookup in `node`'s subtree. */
	private static function collectLookupEdits(
		node: QueryNode, recvName: String, keyName: String, cfg: Cfg, valName: String, out: Array<{ span: Span, text: String }>
	): Void {
		if (cfg.opaqueKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		if (span != null && isLookup(node, recvName, keyName, cfg)) {
			out.push({ span: span, text: valName });
			return;
		}
		for (c in node.children) collectLookupEdits(c, recvName, keyName, cfg, valName, out);
	}

	/** A value-variable name not already used in the loop body and distinct from the map / key names — `value`, else `value1`, `value2`… */
	private static function freshValueName(source: String, bodySpan: Span, recvName: String, keyName: String): String {
		final base: String = 'value';
		var candidate: String = base;
		var n: Int = 1;
		while (
			candidate == recvName || candidate == keyName
			|| RefactorSupport.referencedInRange(source, candidate, bodySpan.from, bodySpan.to, [])
		) {
			candidate = base + n;
			n++;
		}
		return candidate;
	}

	/** First index at or after `from` (bounded by `stop`) that is not ASCII whitespace. */
	private static function skipSpace(source: String, from: Int, stop: Int): Int {
		var i: Int = from;
		while (i < stop) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c != ' '.code && c != '\t'.code && c != '\n'.code && c != '\r'.code) break;
			i++;
		}
		return i;
	}

}

/** Per-run resolved `RefShape` seams and the optional type provider. */
private typedef Cfg = {
	var shape: RefShape;
	var forKind: String;
	var identKind: String;
	var callKind: String;
	var fieldKind: String;
	var indexKind: String;
	var writeParentKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var paramKinds: Array<String>;
	var mapFamily: Array<String>;
	var nullableWrappers: Array<String>;
	var opaqueKinds: Array<String>;
	var typed: Null<TypeInfoProvider>;
};
