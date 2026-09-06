package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Recognises whether an expression is a **provably-nullable source** — the shared
 * type-driven predicate behind the point-wise `possible-null-dereference` check and
 * the flow-sensitive `unguarded-nullable-deref` seed. Four sources: a `Map`-family
 * index (`m[k]`, a `Null<V>`), an `Array` / `List` / `Map` nullable-returning call
 * (a `Null<T>` / `Null<V>`), a same-file plain-identifier call whose declared return
 * is `Null<T>`, and — given a `SymbolIndex` — a cross-file `Type.static()` /
 * `obj.method()` whose resolved return nominal is `Null` (conservative under a
 * simple-name collision).
 *
 * ## The receiver type is load-bearing, and is asked in two steps
 *
 * `m[k]` and `arr[i]` share an AST — only the receiver's type tells them apart. The
 * first question is its own written annotation (`TypeResolver.identTypeName` over
 * `declaredTypes`), which reaches a plain identifier and nothing else. Everything
 * past that is `nominalOf`, the optional chain resolver
 * (`CheckScan.typeNominalResolver` over `NominalTypes`): it answers a field path
 * (`o.cache[k]`), a call receiver (`g().pop()`), a `using` extension, and a binding
 * the annotation map has no entry for. It is a FALLBACK — an answer the annotation
 * already gives never moves, and a caller that passes no resolver keeps exactly the
 * annotation-only behaviour.
 *
 * One place the annotation is asked and then DISCARDED: `declaredTypes` records
 * `Null<Map<K, V>>` as its bare outer name `Null`, a member-transparent wrapper that
 * names no member set of its own. That string is a loss, not an answer, so it falls
 * through to the resolver, which reads the written source and peels the wrapper.
 *
 * ## The cross-file arc asks the RESOLUTION index, and owes the exclusion list for it
 *
 * `Array.pop`, `List.first`, a library's `find` — every member this arc is about is declared
 * OUTSIDE the files under report, so a report-scoped index answers "unknown" for all of them by
 * construction. The caller therefore hands in the RESOLUTION index (report scope + declared roots
 * + libs + std); measured on the Pony fork, that moves the method-call arc from 48 resolved
 * questions of 421 to 194.
 *
 * Which is what makes `excludedCalls` load-bearing HERE and nowhere else in this class. The
 * exclusion is applied to `instanceSigs` when the config is BUILT, and this arc reaches the same
 * call by an index lookup that never sees that filter — so a wide enough index hands
 * `Array.pop()` straight back, and the exclusion reads as honoured while being void.
 *
 * An `Array` / `String` index, a same-named method on an unrelated type, and a
 * non-`Null<…>` (or unannotated and unresolvable) return are all safe misses.
 *
 * Pure, stateless class (mirrors `TypeResolver`).
 */
@:nullSafety(Strict)
final class NullableSource {

	/** A ternary's child count — condition, then-arm, else-arm. */
	private static inline final TERNARY_ARITY: Int = 3;

	/**
	 * Resolve the recognition config from a grammar's `RefShape`, or null when the
	 * grammar has no identifier kind or declares no nullable source at all (index
	 * types, instance-return calls, and return markers all empty) — a caller then
	 * skips the file.
	 *
	 * `exclude` is carried into the config as `excludedCalls`, not just applied to `instanceSigs`
	 * here: the cross-file arc reaches the same `Type.method` through an index lookup that this
	 * filter never touches, so it has to re-apply it itself.
	 */
	public static function build(shape: RefShape, ?exclude: Array<String>): Null<NullableSourceCfg> {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return null;
		final nullableIndexTypes: Array<String> = shape.nullableIndexTypeNames ?? [];
		final returnMarkers: Array<String> = shape.nullableReturnMarkerTypes ?? [];
		final excluded: Array<String> = exclude ?? [];
		final instanceSigs: Array<{ type: String, method: String }> = [
			for (s in parseInstanceSigs(shape.nullableInstanceReturnCalls ?? [])) if (!excluded.contains('${s.type}.${s.method}')) s
		];
		return nullableIndexTypes.length == 0 && instanceSigs.length == 0 && returnMarkers.length == 0 ? null : {
			identKind: identKind,
			shape: shape,
			indexAccessKind: shape.indexAccessKind,
			nullableIndexTypes: nullableIndexTypes,
			callKind: shape.callKind,
			fieldAccessKind: shape.fieldAccessKind,
			instanceSigs: instanceSigs,
			excludedCalls: excluded,
			returnMarkers: returnMarkers
		};
	}

	/**
	 * The nullable-source description of `receiver` — a `Map`-family index
	 * (`'map access T[key]'`), an `Array` / `List` `pop` / `shift` call (`'T.method()'`),
	 * or a `Null<T>`-returning plain-identifier call (`'name()'`) — else null. `root`
	 * is the file tree (for scope resolution); `declaredTypes` / `returnTypes` are the
	 * file's `TypeInfoProvider` maps; `nominalOf` is the optional chain resolver asked
	 * wherever the annotation lookup has no answer.
	 */
	public static function describe(
		receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, returnTypes: Map<Int, String>, cfg: NullableSourceCfg,
		?index: SymbolIndex, ?nominalOf: (QueryNode) -> Null<String>
	): Null<String> {
		return mapIndexSource(receiver, root, declaredTypes, cfg, nominalOf) ?? instanceCallSource(
			receiver, root, declaredTypes, cfg, nominalOf
		) ?? returnCallSource(receiver, root, returnTypes, cfg) ?? crossFileReturnCallSource(
			receiver, root, declaredTypes, cfg, index, nominalOf
		);
	}

	/**
	 * Whether `decl` — a local `var` / `final` declaration — is DECLARED with an explicitly nullable
	 * wrapper (`Null<T>`, `cfg.returnMarkers`). The declaration-side nullable source: no initializer is
	 * read and no type is inferred, only the annotation the author wrote, looked up in `declaredTypes`
	 * under the declaration's own `span.from` (the binding offset that map is keyed by).
	 *
	 * Point-wise this predicate is nearly all noise — measured on the Pony fork, 346 dereferences of a
	 * `Null<T>`-declared bare identifier, of which 209 of the 259 a flow can reach are already narrowed
	 * by a guard. It is usable only as a `NullFlow` SEED, where the engine narrows those away; `NullFlow`
	 * also decides WHICH declarations it asks about (locals, never parameters — see its `analyze` doc).
	 *
	 * `Dynamic` / `Any` are excluded by construction: `cfg.returnMarkers` holds the explicit wrapper
	 * alone, and a deref of an untyped value is not a clear NPE.
	 */
	public static function declaredNullable(decl: QueryNode, declaredTypes: Map<Int, String>, cfg: NullableSourceCfg): Bool {
		final span: Null<Span> = decl.span;
		if (span == null || cfg.returnMarkers.length == 0) return false;
		final declared: Null<String> = declaredTypes[span.from];
		return declared != null && cfg.returnMarkers.contains(declared);
	}

	/**
	 * Whether `init` — a declaration's initializer — has a RESOLVED type that is not the nullable
	 * wrapper. The one state the declaration seed above must not read as silence.
	 *
	 * That seed exists because an initializer the resolver cannot type leaves the written `Null<T>`
	 * as the whole evidence (`final e: Null<Char> = t.getChar(1)`). `NullFlow` reaches it whenever
	 * the initializer named no nullable SOURCE — which collapses two different states: "the resolver
	 * typed this and it is `Foo`" and "the resolver has no idea" both arrive as silence, so the
	 * annotation gets seeded over a value that cannot be null. The annotation is then merely
	 * redundant, and the warning is about a dereference no path can fault.
	 *
	 * `valueNominalOf` MUST be a resolver built in VALUE mode. The receiver-mode arc peels the
	 * `Null<>` wrapper by design — `tmp.trim()` on a `tmp: Null<String>` has to find `trim` on
	 * `String` — so it answers `T` for a field declared `Null<T>`, which is the exact opposite of
	 * what this predicate asks. Passing the receiver-mode resolver silently drops real seeds, and
	 * only a fixture over a `Null<T>`-declared FIELD tells the two apart.
	 *
	 * Three answers, in order. A TERNARY is answered branch-wise, because the chain resolver does
	 * not type one: it is non-null when every value arm is, recursing through a nested ternary.
	 * A node whose KIND can never produce null answers itself — the resolver says nothing about a
	 * bare literal, and a literal arm is what a redundant `Null<T>` over a ternary usually holds.
	 * Everything else is asked of the resolver, and an unresolved answer stays silence — the safe
	 * direction, since it only leaves today's seed standing.
	 *
	 * Residual: a nominal of `Any` reads as proof, since only the raw dynamic name is excluded by
	 * name. Unmeasured — no tree in the corpus writes `final p: Null<T> = <an Any>`.
	 */
	public static function initTypeIsNonNull(
		init: Null<QueryNode>, cfg: NullableSourceCfg, valueNominalOf: Null<(QueryNode) -> Null<String>>
	): Bool {
		if (init == null || valueNominalOf == null) return false;
		final ternaryKind: Null<String> = cfg.shape.ternaryKind;
		if (ternaryKind != null && init.kind == ternaryKind && init.children.length == TERNARY_ARITY)
			return initTypeIsNonNull(init.children[1], cfg, valueNominalOf) && initTypeIsNonNull(init.children[2], cfg, valueNominalOf);
		if (NullFlow.NON_NULL_RHS_KINDS.contains(init.kind)) return true;
		final nominal: Null<String> = valueNominalOf(init);
		return nominal != null && !cfg.returnMarkers.contains(nominal) && nominal != cfg.shape.rawDynamicTypeName;
	}

	/**
	 * The receiver's type nominal: its own declared annotation when it is a plain identifier
	 * carrying one, else `nominalOf` — the chain resolver, which reads field paths, method
	 * return types and `using` extensions the annotation lookup cannot see. Fallback ONLY, so
	 * an answer the annotation already gives never moves; a caller with no resolver keeps
	 * exactly today's behaviour.
	 */
	private static function receiverTypeName(
		node: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, cfg: NullableSourceCfg,
		nominalOf: Null<(QueryNode) -> Null<String>>
	): Null<String> {
		final declared: Null<String> = node.kind == cfg.identKind ? TypeResolver.identTypeName(node, root, cfg.shape, declaredTypes) : null;
		// A member-transparent wrapper is what `declaredTypes` DEGRADES to: `Null<Map<K, V>>` is
		// recorded as its bare outer name `Null`, which names no member set of its own. That is a
		// LOSS, not an answer — hand it on, and the resolver reads the written SOURCE and peels the
		// wrapper. No arc's type list holds `Null`, so this can only ever fill an unknown.
		final lossy: Bool = declared == null || (cfg.shape.memberTransparentWrapperTypeNames ?? []).contains(declared);
		return if (lossy)
			nominalOf == null ? null : nominalOf(node);
		else
			declared;
	}

	/** `'map access T[key]'` when `receiver` is a `nullableIndexTypes` index, else null. */
	private static function mapIndexSource(
		receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, cfg: NullableSourceCfg,
		nominalOf: Null<(QueryNode) -> Null<String>>
	): Null<String> {
		if (
			cfg.indexAccessKind == null || cfg.nullableIndexTypes.length == 0 || receiver.kind != cfg.indexAccessKind
			|| receiver.children.length < 1
		)
			return null;
		final typeName: Null<String> = receiverTypeName(receiver.children[0], root, declaredTypes, cfg, nominalOf);
		return typeName != null && cfg.nullableIndexTypes.contains(typeName) ? 'map access ${typeName}[key]' : null;
	}

	/** `'T.method()'` when `receiver` is a `nullableInstanceReturnCalls` call, else null. */
	private static function instanceCallSource(
		receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, cfg: NullableSourceCfg,
		nominalOf: Null<(QueryNode) -> Null<String>>
	): Null<String> {
		if (cfg.instanceSigs.length == 0) return null;
		final parts: Null<{ recv: QueryNode, method: String }> = methodCallParts(receiver, cfg);
		if (parts == null) return null;
		final typeName: Null<String> = receiverTypeName(parts.recv, root, declaredTypes, cfg, nominalOf);
		if (typeName == null) return null;
		for (sig in cfg.instanceSigs) if (sig.type == typeName && sig.method == parts.method) return '${typeName}.${parts.method}()';
		return null;
	}

	/** `'name()'` when `receiver` is a call to a plain-identifier function with a `nullableReturnMarkerTypes` return, else null. */
	private static function returnCallSource(
		receiver: QueryNode, root: QueryNode, returnTypes: Map<Int, String>, cfg: NullableSourceCfg
	): Null<String> {
		if (cfg.callKind == null || cfg.returnMarkers.length == 0 || receiver.kind != cfg.callKind || receiver.children.length < 1)
			return null;
		final callee: QueryNode = receiver.children[0];
		final calleeName: Null<String> = callee.name;
		if (callee.kind != cfg.identKind || calleeName == null) return null;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(callee, root, cfg.shape);
		final retType: Null<String> = bindingFrom == null ? null : returnTypes[bindingFrom];
		return retType != null && cfg.returnMarkers.contains(retType) ? '${calleeName}()' : null;
	}

	/**
	 * `'recv.method()'` when `receiver` is a call `recv.method()` whose resolved return OUTER
	 * nominal is a `returnMarkers` (`Null`) — the CROSS-FILE `Null<T>`-return source. `recv`
	 * resolves as an instance (its declared type via `TypeResolver.identTypeName`) or, failing
	 * that, as a static receiver (its own name as a type); `index.returnNominalOf` supplies the
	 * cross-file member nominal, conservative under a simple-name collision. Null when there is
	 * no index, `recv` is not a plain identifier, the `Type.method` is one of `cfg.excludedCalls`, or
	 * the lookup is unresolved / ambiguous — so
	 * `this.f()` and an external-typed receiver are safe misses.
	 */
	private static function crossFileReturnCallSource(
		receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, cfg: NullableSourceCfg, index: Null<SymbolIndex>,
		nominalOf: Null<(QueryNode) -> Null<String>>
	): Null<String> {
		if (index == null || cfg.returnMarkers.length == 0) return null;
		final parts: Null<{ recv: QueryNode, method: String }> = methodCallParts(receiver, cfg);
		if (parts == null) return null;
		final recv: QueryNode = parts.recv;
		final idx: SymbolIndex = index;
		// A BOUND local / param resolves via its DECLARED type first, so an inferred-type variable
		// name is never reinterpreted as a same-named class by the ANNOTATION lookup. An UNBOUND
		// name is a static / type receiver, looked up by its own name. Only when neither answers
		// does `receiverTypeName` ask the chain resolver, which re-resolves the binding itself.
		final recvName: Null<String> = recv.kind == cfg.identKind ? recv.name : null;
		final bound: Bool = recvName != null && TypeResolver.identBindingFrom(recv, root, cfg.shape) != null;
		final lookupType: Null<String> = (bound ? null : recvName) ?? receiverTypeName(recv, root, declaredTypes, cfg, nominalOf);
		if (lookupType == null) return null;
		// The EXCLUSION list is applied to `instanceSigs` at build time, and this arc reaches the
		// same call by a different route — an index lookup that never sees that filter. Without
		// this line an `Array.pop()` a caller asked to be excluded comes back through the index
		// the moment the index is wide enough to hold `Array` (measured: `LangTable:42`,
		// `TablePrepare:100-101`, `Renderer.hx` x20 on the Pony fork), and the exclusion reads as
		// honoured while being silently void.
		if (cfg.excludedCalls.contains('${lookupType}.${parts.method}')) return null;
		final retNominal: Null<String> = idx.members.returnNominalOf(lookupType, parts.method);
		return retNominal != null && cfg.returnMarkers.contains(retNominal) ? '${recvName ?? lookupType}.${parts.method}()' : null;
	}

	/** Split each dotted `Type.method` signature into its parts, dropping malformed entries. */
	private static function parseInstanceSigs(raw: Array<String>): Array<{ type: String, method: String }> {
		final sigs: Array<{ type: String, method: String }> = [];
		for (s in raw) {
			final dot: Int = s.lastIndexOf('.');
			if (dot > 0 && dot < s.length - 1) sigs.push({ type: s.substring(0, dot), method: s.substring(dot + 1) });
		}
		return sigs;
	}


	/**
	 * Destructure a method-call receiver `recv.method(...)` into its receiver node and
	 * method name — the shared guard behind `instanceCallSource` and
	 * `crossFileReturnCallSource` — or null when `receiver` is not a field-access call.
	 */
	private static function methodCallParts(receiver: QueryNode, cfg: NullableSourceCfg): Null<{ recv: QueryNode, method: String }> {
		if (cfg.callKind == null || cfg.fieldAccessKind == null || receiver.kind != cfg.callKind || receiver.children.length < 1)
			return null;
		final callee: QueryNode = receiver.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != cfg.fieldAccessKind || method == null || callee.children.length != 1) return null;
		final recv: QueryNode = callee.children[0];
		return { recv: recv, method: method };
	}

}

/** Resolved nullable-source recognition config — the seams `NullableSource` reads, built once per grammar. */
typedef NullableSourceCfg = {
	var identKind: String;
	var shape: RefShape;
	var indexAccessKind: Null<String>;
	var nullableIndexTypes: Array<String>;
	var callKind: Null<String>;
	var fieldAccessKind: Null<String>;
	var instanceSigs: Array<{ type: String, method: String }>;
	var excludedCalls: Array<String>;
	var returnMarkers: Array<String>;
};
