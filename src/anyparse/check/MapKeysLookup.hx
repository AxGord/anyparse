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
 * (dropping `.keys()`, binding a value name, replacing every `m[k]` / `m.get(k)` with
 * it, over a mutation-free body) is what the autofix applies.
 *
 * ## The shape it accepts
 *
 * A `for` whose iterable is EXACTLY `<recv>.keys()` — a no-argument `keys` call on a
 * PATH receiver: a bare identifier (`m`, `this`) or a chain of plain field accesses
 * over one (`this.files`, `session.files`, `o.a.b`). The path shape is restricted to
 * field links so every segment is a plain field read: a call, an index access or a
 * null-safe `?.` link anywhere in the chain projects as a different node kind and is
 * SKIPPED, keeping the receiver free of evaluation effects of its own. The body must
 * contain at least one lookup of that receiver by the loop's key variable: an index
 * access `m[k]` or a `m.get(k)` call, matched by the SAME path (compared segment by
 * segment, not by source text — whitespace or a comment inside the chain cannot split
 * two equal paths, and `a.b` never matches the differently-evaluated `a?.b`) and the
 * SAME key name, so `m[j]` / `n[k]` are not matches.
 *
 * ## Soundness gates (conservative — a miss over a wrong flag)
 *
 * - **No mutation, no re-binding of the iterable.** If the body writes the map in any
 *   form — `<path>[...] = …` (or a compound-assign / increment on it, via
 *   `RefShape.writeParentKinds`), or a `<path>.set(…)` / `.remove(…)` / `.clear(…)` call
 *   — the loop is SKIPPED: iterating `keys()` while mutating the map may be deliberate,
 *   and key-value iteration during mutation is not equivalent. An ASSIGNMENT to the path
 *   itself (`m = other`, `o.files = other`) or to one of its PREFIXES (`o = p`) skips it
 *   too: the original loop's later lookups would read the NEW map while the keys came
 *   from the old one, whereas key-value iteration binds every value from the map the
 *   loop started on. That relation is one-way — a write DEEPER than the path
 *   (`o.files.inner = …`) does not re-bind the iterable, and a deeper write that really
 *   mutates the iterated map takes one of the shapes above. Every comparison in this
 *   gate runs on SELF-NORMALISED paths, so `this.files` and a bare `files` — two
 *   spellings of one member — are recognised as the same storage in both directions.
 * - **No re-binding of the names.** If the path's ROOT name or the key name is re-bound
 *   anywhere in the body (a local declaration, a nested function parameter, or a nested
 *   loop variable of the same name), the inner binding shadows the loop's, so the lookup
 *   no longer refers to the iterated map / key — SKIPPED. Only the root matters for a
 *   path: `session.files` resolves `files` as a member of whatever `session` denotes,
 *   so a local named after an intermediate segment cannot shadow it.
 * - **Type, when known.** The receiver's declared type is resolved and the loop is
 *   SKIPPED when it comes out a concrete NON-map-family nominal (not one of
 *   `RefShape.nullableIndexTypeNames`, and not a `Null` / `Dynamic` / `Any` wrapper) —
 *   a custom `keys()`-bearing type is not a map, and rewriting it emits code that does
 *   not compile. A PATH is resolved the same way a bare identifier is: its ROOT through
 *   the binding declaration (or, for `this`, the enclosing type), then each field segment
 *   through the run's `SymbolIndex`, so `session.files` with `SessionData.files :
 *   Map<String, String>` reaches `Map` and `svc.registry` with a custom `Registry`
 *   reaches `Registry`. An UNRESOLVABLE receiver still flags — an anonymous-struct or
 *   un-annotated receiver would otherwise be lost wholesale — which is a deliberate
 *   false-positive tolerance, not a proof of map-ness; the residual is a custom
 *   `keys()`-bearing type no seam can resolve, identically for a path and for a bare
 *   identifier.
 *
 * ## Re-evaluating the receiver
 *
 * `<path>.keys()` plus N body lookups evaluates the path N+1 times; the rewrite
 * evaluates it once. That is observable only when a segment is a property whose getter
 * is not idempotent — and such a getter already makes the ORIGINAL loop incoherent, as
 * each lookup then reads a DIFFERENT map from the one whose keys are being iterated
 * (measured: a fresh-map getter turns `for (k in o.p.keys()) o.p.get(k)` into keys from
 * map #1 paired with values from maps #2, #3, …). The rewrite makes that loop coherent
 * rather than making correct code wrong, so it is not gated; the shape restriction above
 * already keeps calls and index accesses — which carry side effects of their own — out
 * of the path. A bare-identifier receiver has the same exposure (a plain `p` inside its
 * own class IS `this.p`), so this is not specific to paths.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape.forStmtKind` / `identKind` / `callKind` / `fieldAccessKind` /
 * `indexAccessKind` (any unset → no-op), plus `writeParentKinds` + `selfReferenceText`
 * for the mutation and iterable-re-binding gate, `localDeclKinds` / `paramKinds` for the
 * name-re-binding gate, `blockStmtKind` + `localDeclKinds` minus `mutableLocalDeclKinds`
 * + `nonNullableTypeNames` / `literalTypeNames` for the fix's value-name reuse,
 * `nullableIndexTypeNames` / `nullableWrapperTypeNames` for the type gate (only when
 * `plugin is TypeInfoProvider`), and `opaqueKinds` to skip macro reification. Resolving
 * a path's member types needs the whole file set, so the check is listed among the
 * `Cli` fixed-point loop's full-scope ids.
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
		// Cross-file member types are needed only by a loop that already cleared every structural
		// gate, which most runs never have — so the index is built at most once, on first demand.
		var symbols: Null<SymbolIndex> = null;
		var indexed: Bool = false;
		final resolveSymbols: () -> Null<SymbolIndex> = () -> {
			if (!indexed) {
				indexed = true;
				symbols = SymbolIndex.build(files, plugin);
			}
			return symbols;
		};
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final declaredTypes: Null<Map<Int, String>> = c.typed == null ? null : c.typed.declaredTypes(entry.source);
			walk(tree, tree, entry.file, declaredTypes, c, resolveSymbols, violations);
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
			blockKind: shape.blockStmtKind,
			selfRef: shape.selfReferenceText,
			writeParentKinds: shape.writeParentKinds,
			localDeclKinds: shape.localDeclKinds ?? [],
			immutableLocalDeclKinds: immutableLocalDeclKinds(shape),
			paramKinds: shape.paramKinds ?? [],
			mapFamily: shape.nullableIndexTypeNames ?? [],
			nullableWrappers: shape.nullableWrapperTypeNames ?? [],
			safeAnnotationTypes: safeAnnotationTypeNames(shape),
			opaqueKinds: shape.opaqueKinds ?? [],
			typed: typed
		};
	}

	/** The local-declaration kinds that cannot be reassigned — every `localDeclKinds` entry that is not a mutable one. */
	private static function immutableLocalDeclKinds(shape: RefShape): Array<String> {
		final mutable: Array<String> = shape.mutableLocalDeclKinds ?? [];
		return [for (k in shape.localDeclKinds ?? []) if (!mutable.contains(k)) k];
	}

	/**
	 * The nominals a value declaration may be annotated with that PROVABLY do not alias a
	 * nullable wrapper — the grammar's non-nullable basic types plus the types its literals
	 * denote. Both are builtins of the language, so neither can be a user `typedef` hiding a
	 * `Null<…>`; every other name (including a plain class, which is safe but indistinguishable
	 * from an alias without whole-program resolution) is treated as unsafe by the fix's
	 * value-name reuse. A whitelist, not a blacklist: an alias like `typedef MaybeInt = Null<Int>`
	 * is invisible to any check keyed on the written spelling.
	 */
	private static function safeAnnotationTypeNames(shape: RefShape): Array<String> {
		final names: Array<String> = (shape.nonNullableTypeNames ?? []).copy();
		final literals: Null<Map<String, String>> = shape.literalTypeNames;
		if (literals != null) for (t in literals) if (!names.contains(t)) names.push(t);
		return names;
	}

	/** Walk `node`, flagging each `for (k in m.keys())` loop that re-looks-up the same map by the same key. */
	private static function walk(
		node: QueryNode, root: QueryNode, file: String, declaredTypes: Null<Map<Int, String>>, cfg: Cfg, symbols: () -> Null<SymbolIndex>,
		out: Array<Violation>
	): Void {
		if (cfg.opaqueKinds.contains(node.kind)) return;
		if (node.kind == cfg.forKind) {
			final v: Null<Violation> = match(node, root, file, declaredTypes, cfg, symbols);
			if (v != null) out.push(v);
		}
		for (c in node.children) walk(c, root, file, declaredTypes, cfg, symbols, out);
	}

	/**
	 * If `loop` is a `for (k in <path>.keys())` whose body reads `<path>[k]` / `<path>.get(k)`
	 * with no mutation of, re-binding of, or shadowing over the map — and the receiver type is
	 * not a known non-map — return the finding spanned at the `.keys()` iterable; else null.
	 */
	private static function match(
		loop: QueryNode, root: QueryNode, file: String, declaredTypes: Null<Map<Int, String>>, cfg: Cfg, symbols: () -> Null<SymbolIndex>
	): Null<Violation> {
		final p = loopParts(loop, cfg);
		if (p == null) return null;
		if (rebinds(p.body, p.path[0], p.keyName, cfg)) return null;
		if (writesMap(p.body, stripSelf(p.path, cfg), cfg)) return null;
		if (!hasLookup(p.body, p.path, p.keyName, cfg)) return null;
		if (!receiverTypeAllows(p.recv, root, declaredTypes, cfg, symbols)) return null;
		final iterSpan: Null<Span> = p.iterable.span;
		final pathText: String = p.path.join('.');
		return iterSpan == null ? null : {
			file: file,
			span: iterSpan,
			rule: 'map-keys-lookup',
			severity: Severity.Info,
			message: 'iterate key-value instead of keys()-then-lookup — for (${p.keyName} => value in $pathText)'
		};
	}

	/**
	 * The reusable structural parts of a `for (k in <path>.keys())` loop — the key name, the
	 * iterable and body children, the receiver node and its dotted path — or null when the loop
	 * is not a `keys()` iteration over a path. Shared by `match` and `buildMapEdits`.
	 */
	private static function loopParts(loop: QueryNode, cfg: Cfg): Null<{
		keyName: String,
		iterable: QueryNode,
		body: QueryNode,
		recv: QueryNode,
		path: Array<String>
	}> {
		if (loop.children.length < MIN_BINARY_CHILD_COUNT) return null;
		final keyName: Null<String> = loop.name;
		if (keyName == null) return null;
		final iterable: QueryNode = loop.children[0];
		final body: QueryNode = loop.children[loop.children.length - 1];
		final recv: Null<QueryNode> = keysReceiver(iterable, cfg);
		if (recv == null) return null;
		final path: Null<Array<String>> = pathOf(recv, cfg);
		if (path == null) return null;
		final parts = {
			keyName: keyName,
			iterable: iterable,
			body: body,
			recv: recv,
			path: path
		};
		return parts;
	}

	/** The receiver node of a `<path>.keys()` no-argument call, else null. */
	private static function keysReceiver(iterable: QueryNode, cfg: Cfg): Null<QueryNode> {
		if (iterable.kind != cfg.callKind || iterable.children.length != 1) return null;
		final callee: QueryNode = iterable.children[0];
		if (callee.kind != cfg.fieldKind || callee.name != KEYS_METHOD || callee.children.length != 1) return null;
		final recv: QueryNode = callee.children[0];
		return pathOf(recv, cfg) == null ? null : recv;
	}

	/**
	 * The dotted segments of a PATH expression — a root identifier (or the self reference)
	 * followed by plain field accesses, so `session.files` yields `['session', 'files']` — or
	 * null when `node` is anything else. The accepted SHAPE is deliberately narrow: only
	 * `fieldKind` links over an `identKind` root. A call, an index access or a null-safe `?.`
	 * link anywhere in the chain projects as a different kind and yields null, keeping every
	 * segment a plain field read with no side effect of its own.
	 */
	private static function pathOf(node: QueryNode, cfg: Cfg): Null<Array<String>> {
		final name: Null<String> = node.name;
		if (name == null) return null;
		if (node.kind == cfg.identKind) return [name];
		if (node.kind != cfg.fieldKind || node.children.length != 1) return null;
		final base: Null<Array<String>> = pathOf(node.children[0], cfg);
		if (base == null) return null;
		base.push(name);
		return base;
	}

	/**
	 * Whether `node` is the SAME path as `path`, compared segment by segment rather than by
	 * source text: whitespace and comments inside the chain cannot make two equal paths differ,
	 * and the per-link kind check keeps `a.b` from matching the differently-evaluated `a?.b`.
	 */
	private static function isPath(node: QueryNode, path: Array<String>, cfg: Cfg): Bool {
		final other: Null<Array<String>> = pathOf(node, cfg);
		if (other == null || other.length != path.length) return false;
		for (i in 0...path.length) if (other[i] != path[i]) return false;
		return true;
	}

	/**
	 * Whether the path ROOT `rootName` or the key `keyName` is re-bound anywhere in `node` (a
	 * local, a nested param, or a nested loop var). Only the root matters for a path: a
	 * `session.files` read resolves `files` as a member of whatever `session` denotes, so a
	 * local named after an intermediate SEGMENT cannot shadow it — re-binding the root can.
	 */
	private static function rebinds(node: QueryNode, rootName: String, keyName: String, cfg: Cfg): Bool {
		if (cfg.opaqueKinds.contains(node.kind)) return false;
		final introducesBinding: Bool = cfg.localDeclKinds.contains(node.kind) || cfg.paramKinds.contains(node.kind)
			|| node.kind == cfg.forKind;
		if (introducesBinding && (node.name == rootName || node.name == keyName)) return true;
		for (c in node.children) if (rebinds(c, rootName, keyName, cfg)) return true;
		return false;
	}

	/**
	 * Whether `node`'s subtree invalidates the iterable whose SELF-NORMALISED path is
	 * `memberPath` — either by MUTATING the map (`<path>[...] = …`, a compound-assign /
	 * increment on it, or a `set` / `remove` / `clear` call) or by RE-BINDING what the path
	 * denotes (an assignment to the path itself or to one of its prefixes).
	 *
	 * Every comparison here runs on self-normalised paths, so `this.files` and a bare `files`
	 * — two spellings of ONE member — are recognised as the same storage in both directions.
	 * The lookup matcher deliberately does NOT normalise: widening a SKIP gate can only lose
	 * findings, whereas widening the MATCH gate would equate a local `files` with the member
	 * `this.files` and rewrite one into the other.
	 */
	private static function writesMap(node: QueryNode, memberPath: Array<String>, cfg: Cfg): Bool {
		if (cfg.opaqueKinds.contains(node.kind)) return false;
		if (cfg.writeParentKinds.contains(node.kind) && node.children.length >= 1) {
			final target: QueryNode = node.children[0];
			if (target.kind == cfg.indexKind && target.children.length >= 1 && isSameMemberPath(target.children[0], memberPath, cfg))
				return true;
			if (rebindsPath(target, memberPath, cfg)) return true;
		}
		if (node.kind == cfg.callKind && node.children.length >= 1) {
			final callee: QueryNode = node.children[0];
			if (
				callee.kind == cfg.fieldKind && callee.children.length == 1 && isSameMemberPath(callee.children[0], memberPath, cfg)
				&& isWriteMethod(callee.name)
			)
				return true;
		}
		for (c in node.children) if (writesMap(c, memberPath, cfg)) return true;
		return false;
	}

	/** `pathOf` with a leading self-reference segment dropped, so `this.files` and `files` denote one path. */
	private static function memberPathOf(node: QueryNode, cfg: Cfg): Null<Array<String>> {
		final p: Null<Array<String>> = pathOf(node, cfg);
		return p == null ? null : stripSelf(p, cfg);
	}

	/**
	 * `path` without a leading self-reference segment. Inside an `abstract`'s body `this.x` is
	 * the UNDERLYING value's member rather than an implicit-this field, so stripping there can
	 * equate two different storages — harmless, because every consumer is a SKIP gate and the
	 * result is at worst a missed finding.
	 */
	private static function stripSelf(path: Array<String>, cfg: Cfg): Array<String> {
		return path.length > 1 && path[0] == cfg.selfRef ? path.slice(1) : path;
	}

	/** Whether `node` is the same self-normalised path as `memberPath`. */
	private static function isSameMemberPath(node: QueryNode, memberPath: Array<String>, cfg: Cfg): Bool {
		final other: Null<Array<String>> = memberPathOf(node, cfg);
		return other != null && other.length == memberPath.length && segmentsMatch(other, memberPath);
	}

	/**
	 * Whether assigning to `node` re-binds what `memberPath` denotes — true when `node` is that
	 * path (`o.files = other`) or one of its PREFIXES (`o = p`), after which the loop's remaining
	 * lookups read a different map than the one the iteration started on.
	 *
	 * The relation is one-way on purpose. A write DEEPER than the path (`o.files.inner = …`, of
	 * which `memberPath` is the prefix) leaves `o.files` denoting the same object, so it does not
	 * invalidate the iterable; a deeper write that really does mutate the iterated map takes the
	 * index / `set` / `remove` / `clear` shapes, which the caller already rejects.
	 */
	private static function rebindsPath(node: QueryNode, memberPath: Array<String>, cfg: Cfg): Bool {
		final other: Null<Array<String>> = memberPathOf(node, cfg);
		return other != null && other.length <= memberPath.length && segmentsMatch(other, memberPath);
	}

	/** Whether every segment of `prefix` equals the segment at the same index of `path`. */
	private static function segmentsMatch(prefix: Array<String>, path: Array<String>): Bool {
		for (i in 0...prefix.length) if (prefix[i] != path[i]) return false;
		return true;
	}

	/** Whether `node`'s subtree contains a `<path>[key]` index access or a `<path>.get(key)` call. */
	private static function hasLookup(node: QueryNode, path: Array<String>, keyName: String, cfg: Cfg): Bool {
		if (cfg.opaqueKinds.contains(node.kind)) return false;
		if (isLookup(node, path, keyName, cfg)) return true;
		for (c in node.children) if (hasLookup(c, path, keyName, cfg)) return true;
		return false;
	}

	/** Whether `node` is exactly a `<path>[key]` index access or a `<path>.get(key)` call — one lookup, no descent. */
	private static function isLookup(node: QueryNode, path: Array<String>, keyName: String, cfg: Cfg): Bool {
		if (
			node.kind == cfg.indexKind && node.children.length >= MIN_BINARY_CHILD_COUNT && isPath(node.children[0], path, cfg)
			&& isIdentNamed(node.children[1], keyName, cfg)
		)
			return true;
		if (node.kind == cfg.callKind && node.children.length == GET_CALL_CHILD_COUNT) {
			final callee: QueryNode = node.children[0];
			if (
				callee.kind == cfg.fieldKind && callee.name == GET_METHOD && callee.children.length == 1
				&& isPath(callee.children[0], path, cfg) && isIdentNamed(node.children[1], keyName, cfg)
			)
				return true;
		}
		return false;
	}

	/**
	 * Whether the receiver's declared type does not RULE OUT a map — true (flag) when there is
	 * no type info or the type cannot be resolved, and when it resolves to a map-family nominal
	 * or a `Null` / `Dynamic` / `Any` wrapper; false (skip) when it resolves to a concrete
	 * non-map type, whose `keys()` is not a map's.
	 *
	 * Flagging an UNRESOLVABLE receiver is a deliberate false-positive tolerance, not a proof:
	 * `.keys()` plus a same-key lookup is overwhelmingly Map-shaped, and the alternative would
	 * drop every anonymous-struct and un-annotated receiver. The residual — a custom
	 * `keys()`-bearing type whose receiver type no seam can resolve — is the same for a path as
	 * for a bare identifier.
	 */
	private static function receiverTypeAllows(
		recv: QueryNode, root: QueryNode, declaredTypes: Null<Map<Int, String>>, cfg: Cfg, symbols: () -> Null<SymbolIndex>
	): Bool {
		if (declaredTypes == null) return true;
		final typeName: Null<String> = receiverTypeName(recv, root, declaredTypes, cfg, symbols);
		if (typeName == null) return true;
		if (cfg.mapFamily.contains(typeName)) return true;
		return cfg.nullableWrappers.contains(typeName);
	}

	/**
	 * The simple nominal the receiver's declared type resolves to, or null when any link cannot
	 * be resolved. A bare identifier resolves through its binding declaration; a PATH resolves
	 * its root the same way (or, for the self reference, to the enclosing type declaration) and
	 * then walks each field segment's member type through the run's `SymbolIndex`, so
	 * `session.files` with `SessionData.files : Map<String, String>` resolves to `Map` and
	 * `svc.registry` with a custom `Registry` resolves to `Registry`.
	 */
	private static function receiverTypeName(
		recv: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, cfg: Cfg, symbols: () -> Null<SymbolIndex>
	): Null<String> {
		final path: Null<Array<String>> = pathOf(recv, cfg);
		final rootType: Null<String> = path == null ? null : rootTypeName(recv, root, declaredTypes, cfg);
		if (path == null || rootType == null) return null;
		if (path.length == 1) return rootType;
		final index: Null<SymbolIndex> = symbols();
		if (index == null) return null;
		var current: String = rootType;
		for (i in 1...path.length) {
			final memberType: Null<String> = index.memberTypeSourceOf(current, path[i]);
			final nominal: Null<String> = memberType == null ? null : outerNominalOf(memberType);
			if (nominal == null) return null;
			current = nominal;
		}
		return current;
	}

	/** The declared type of a receiver path's ROOT — the enclosing type for the self reference, else the root identifier's annotation. */
	private static function rootTypeName(recv: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, cfg: Cfg): Null<String> {
		var node: QueryNode = recv;
		while (node.kind != cfg.identKind && node.children.length == 1) node = node.children[0];
		if (node.kind != cfg.identKind) return null;
		if (node.name == cfg.selfRef) {
			final span: Null<Span> = recv.span ?? node.span;
			return span == null ? null : TypeResolver.enclosingTypeName(root, span);
		}
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(node, root, cfg.shape);
		return bindingFrom == null ? null : declaredTypes[bindingFrom];
	}

	/** The simple outer nominal of a written type — `pkg.Map<String, Int>` → `Map` — or null when the text is not a nominal at all. */
	private static function outerNominalOf(typeSource: String): Null<String> {
		final lt: Int = typeSource.indexOf('<');
		final head: String = StringTools.trim(lt < 0 ? typeSource : typeSource.substring(0, lt));
		final dot: Int = head.lastIndexOf('.');
		final name: String = dot < 0 ? head : head.substring(dot + 1);
		return RefactorSupport.isIdentifier(name) ? name : null;
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
	 * The edits rewriting one `for (k in <path>.keys())` loop into `for (k => value in <path>)`
	 * with the body's `<path>[k]` / `<path>.get(k)` lookups replaced by the value variable — or
	 * null when the header cannot be located. When the body opens by binding the lookup to its
	 * own local, that local's name becomes the value binding and its declaration is dropped,
	 * instead of leaving a `final v = value;` alias behind.
	 */
	private static function buildMapEdits(loop: QueryNode, source: String, cfg: Cfg): Null<Array<{ span: Span, text: String }>> {
		final p = loopParts(loop, cfg);
		if (p == null) return null;
		final iterSpan: Null<Span> = p.iterable.span;
		final forSpan: Null<Span> = loop.span;
		final bodySpan: Null<Span> = p.body.span;
		final recvSpan: Null<Span> = p.recv.span;
		if (iterSpan == null || forSpan == null || bodySpan == null || recvSpan == null) return null;
		final open: Int = source.indexOf('(', forSpan.from);
		if (open < 0 || open >= iterSpan.from) return null;
		final keyStart: Int = skipSpace(source, open + 1, iterSpan.from);
		if (keyStart + p.keyName.length > source.length || source.substring(keyStart, keyStart + p.keyName.length) != p.keyName)
			return null;
		final reuse: Null<{ name: String, span: Span }> = reusableValueDecl(p.body, p.path, p.keyName, source, cfg);
		final valName: String = reuse == null ? freshValueName(source, bodySpan, p.path[0], p.keyName) : reuse.name;
		final edits: Array<{ span: Span, text: String }> = [
			{ span: new Span(keyStart, iterSpan.to), text: '${p.keyName} => $valName in ${source.substring(recvSpan.from, recvSpan.to)}' }
		];
		// The declaration's line span STRICTLY contains its initialiser's lookup span, so
		// `dropContainedEdits` drops that lookup edit whichever order the two are pushed in.
		if (reuse != null) edits.push({ span: RefactorSupport.lineExtendedSpan(source, reuse.span), text: '' });
		collectLookupEdits(p.body, p.path, p.keyName, cfg, valName, edits);
		return edits;
	}

	/**
	 * The body's leading `final <name> = <lookup>;` declaration whose name the rewrite can REUSE
	 * as the loop's value binding, dropping the declaration — or null when there is none.
	 *
	 * Three preconditions, each closing a way the reuse could change meaning: the declaration is
	 * the body's FIRST statement (a later one would hoist the binding above statements that read
	 * a same-named OUTER binding), it is IMMUTABLE (a reassignable one could hold a different
	 * value by the time a following lookup — which the rewrite replaces with the same name — is
	 * reached), and its type annotation is one the value type can PROVABLY replace. Key-value
	 * iteration binds the map's value type, which is narrower than the `Null<V>` a lookup
	 * returns, so an annotation that widened it is load-bearing: dropping `final v:Null<Int>`
	 * turns a following `v == null` into a compile error on static targets. The annotation is
	 * therefore accepted only against a WHITELIST of builtin nominals (`cfg.safeAnnotationTypes`)
	 * — a blacklist of wrapper spellings cannot see through `typedef MaybeInt = Null<Int>`.
	 */
	private static function reusableValueDecl(
		body: QueryNode, path: Array<String>, keyName: String, source: String, cfg: Cfg
	): Null<{ name: String, span: Span }> {
		if (body.kind != cfg.blockKind || body.children.length == 0) return null;
		final decl: QueryNode = body.children[0];
		if (!cfg.immutableLocalDeclKinds.contains(decl.kind) || decl.children.length != 1) return null;
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		final initSpan: Null<Span> = decl.children[0].span;
		if (name == null || declSpan == null || initSpan == null) return null;
		if (!isLookup(decl.children[0], path, keyName, cfg)) return null;
		final annotation: Null<String> = annotationBaseName(source, declSpan.from, initSpan.from);
		return annotation != null && !cfg.safeAnnotationTypes.contains(annotation) ? null : { name: name, span: declSpan };
	}

	/**
	 * The base name of the type annotation in the declaration head `source[from...to)` (the
	 * `Null` of `final v:Null<Int> = `), or null when the declaration carries none.
	 */
	private static function annotationBaseName(source: String, from: Int, to: Int): Null<String> {
		final colon: Int = source.indexOf(':', from);
		if (colon < 0 || colon >= to) return null;
		final start: Int = skipSpace(source, colon + 1, to);
		var i: Int = start;
		while (i < to && RefactorSupport.isIdentChar(StringTools.fastCodeAt(source, i))) i++;
		return i == start ? null : source.substring(start, i);
	}

	/** Push a `{span → value}` edit for every `<path>[key]` / `<path>.get(key)` lookup in `node`'s subtree. */
	private static function collectLookupEdits(
		node: QueryNode, path: Array<String>, keyName: String, cfg: Cfg, valName: String, out: Array<{ span: Span, text: String }>
	): Void {
		if (cfg.opaqueKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		if (span != null && isLookup(node, path, keyName, cfg)) {
			out.push({ span: span, text: valName });
			return;
		}
		for (c in node.children) collectLookupEdits(c, path, keyName, cfg, valName, out);
	}

	/** A value-variable name not already used in the loop body and distinct from the path root / key names — `value`, else `value1`, `value2`… */
	private static function freshValueName(source: String, bodySpan: Span, rootName: String, keyName: String): String {
		final base: String = 'value';
		var candidate: String = base;
		var n: Int = 1;
		while (
			candidate == rootName || candidate == keyName
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
	var blockKind: Null<String>;
	var selfRef: Null<String>;
	var writeParentKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var immutableLocalDeclKinds: Array<String>;
	var paramKinds: Array<String>;
	var mapFamily: Array<String>;
	var nullableWrappers: Array<String>;
	var safeAnnotationTypes: Array<String>;
	var opaqueKinds: Array<String>;
	var typed: Null<TypeInfoProvider>;
};
