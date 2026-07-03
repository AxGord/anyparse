package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.TypeResolver;

/**
 * Recognises whether an expression is a **provably-nullable source** — the shared
 * type-driven predicate behind the point-wise `possible-null-dereference` check and
 * the flow-sensitive `unguarded-nullable-deref` seed. Three sources: a `Map`-family
 * index (`m[k]`, a `Null<V>`), an `Array` / `List` `pop` / `shift` call (a `Null<T>`),
 * and a call to a plain-identifier function whose declared return type is `Null<T>`.
 *
 * The receiver type is load-bearing: `m[k]` and `arr[i]` share an AST — only the
 * declared type tells them apart (`TypeResolver.identTypeName` / `identBindingFrom`
 * over the `declaredTypes` / `returnTypes` maps). An `Array` / `String` index, a
 * same-named method on an unrelated type, and a non-`Null<…>` (or unannotated) return
 * are all safe misses.
 *
 * Pure, stateless class (mirrors `TypeResolver`).
 */
@:nullSafety(Strict)
final class NullableSource {

	private function new() {}

	/**
	 * Resolve the recognition config from a grammar's `RefShape`, or null when the
	 * grammar has no identifier kind or declares no nullable source at all (index
	 * types, instance-return calls, and return markers all empty) — a caller then
	 * skips the file.
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
		return nullableIndexTypes.length == 0 && instanceSigs.length == 0 && returnMarkers.length == 0
			? null
			: {
				identKind: identKind,
				shape: shape,
				indexAccessKind: shape.indexAccessKind,
				nullableIndexTypes: nullableIndexTypes,
				callKind: shape.callKind,
				fieldAccessKind: shape.fieldAccessKind,
				instanceSigs: instanceSigs,
				returnMarkers: returnMarkers
			};
	}

	/**
	 * The nullable-source description of `receiver` — a `Map`-family index
	 * (`'map access T[key]'`), an `Array` / `List` `pop` / `shift` call (`'T.method()'`),
	 * or a `Null<T>`-returning plain-identifier call (`'name()'`) — else null. `root`
	 * is the file tree (for scope resolution); `declaredTypes` / `returnTypes` are the
	 * file's `TypeInfoProvider` maps.
	 */
	public static function describe(
		receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, returnTypes: Map<Int, String>, cfg: NullableSourceCfg
	): Null<String> {
		return
			mapIndexSource(receiver, root, declaredTypes, cfg) ?? instanceCallSource(receiver, root, declaredTypes, cfg) ?? returnCallSource(
				receiver, root, returnTypes, cfg
			);
	}

	/** `'map access T[key]'` when `receiver` is a `nullableIndexTypes` index, else null. */
	private static function mapIndexSource(
		receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, cfg: NullableSourceCfg
	): Null<String> {
		if (
			cfg.indexAccessKind == null || cfg.nullableIndexTypes.length == 0 || receiver.kind != cfg.indexAccessKind
			|| receiver.children.length < 1
		)
			return null;
		final ident: QueryNode = receiver.children[0];
		if (ident.kind != cfg.identKind) return null;
		final typeName: Null<String> = TypeResolver.identTypeName(ident, root, cfg.shape, declaredTypes);
		return typeName != null && cfg.nullableIndexTypes.contains(typeName) ? 'map access ${typeName}[key]' : null;
	}

	/** `'T.method()'` when `receiver` is a `nullableInstanceReturnCalls` call, else null. */
	private static function instanceCallSource(
		receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, cfg: NullableSourceCfg
	): Null<String> {
		if (
			cfg.callKind == null || cfg.fieldAccessKind == null || cfg.instanceSigs.length == 0 || receiver.kind != cfg.callKind
			|| receiver.children.length < 1
		)
			return null;
		final callee: QueryNode = receiver.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != cfg.fieldAccessKind || method == null || callee.children.length != 1) return null;
		final recvIdent: QueryNode = callee.children[0];
		if (recvIdent.kind != cfg.identKind) return null;
		final typeName: Null<String> = TypeResolver.identTypeName(recvIdent, root, cfg.shape, declaredTypes);
		if (typeName == null) return null;
		for (sig in cfg.instanceSigs) if (sig.type == typeName && sig.method == method) return '${typeName}.${method}()';
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

	/** Split each dotted `Type.method` signature into its parts, dropping malformed entries. */
	private static function parseInstanceSigs(raw: Array<String>): Array<{ type: String, method: String }> {
		final sigs: Array<{ type: String, method: String }> = [];
		for (s in raw) {
			final dot: Int = s.lastIndexOf('.');
			if (dot > 0 && dot < s.length - 1) sigs.push({ type: s.substring(0, dot), method: s.substring(dot + 1) });
		}
		return sigs;
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
	var returnMarkers: Array<String>;
};
