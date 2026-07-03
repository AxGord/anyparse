package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a dereference of a `map[key]` result — a `Null<V>` — with no null check,
 * a possible NPE. Slice 1 of the reference-nullable family (mechanism B, the
 * type-driven / point-wise sibling of the flow-sensitive `null-dereference`).
 * `Info`; report-only.
 *
 * ## Type-aware — the receiver type is load-bearing
 *
 * `m[k].field` (a `FieldAccess`), `m[k].method()` (its callee `FieldAccess`) and
 * `m[k]!.field` (a `ForceFieldAccess`) share an identical AST with `arr[i].field`;
 * only the index receiver's declared type tells them apart. A `Map` index yields
 * `Null<V>`, an `Array` / `String` index yields a non-null `T`. So the check flags
 * the deref only when the `IndexAccess` receiver is a plain identifier whose
 * declared type (`TypeResolver.identTypeName` → the outer nominal name) is one of
 * `RefShape.nullableIndexTypeNames` (the `Map` family). An `Array` / `String` /
 * unannotated / `Null<Map<…>>` (outer name `Null`) receiver is a safe miss.
 *
 * ## Point-wise, not flow-sensitive
 *
 * There is no narrowing: `if (m.exists(k)) m[k].field` and `m[k] = v; m[k].field`
 * are still flagged, since the guard is invisible without flow. That is why the
 * severity is `Info` (advisory), not the `Warning` the flow-sensitive engine
 * earns. `m.get(k)` (a `Call`, not `[]`) is a separate future sub-pattern.
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are not descended into.
 */
@:nullSafety(Strict)
final class PossibleNullDereference implements Check {

	public function new() {}

	public function id(): String {
		return 'possible-null-dereference';
	}

	public function description(): String {
		return 'a dereference of a map[key] result (a Null<V>) with no null check — a possible NPE';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final indexAccessKind: Null<String> = shape.indexAccessKind;
		final identKind: Null<String> = shape.identKind;
		final nullableIndexTypes: Array<String> = shape.nullableIndexTypeNames ?? [];
		final derefKinds: Array<String> = [for (k in [shape.fieldAccessKind, shape.forceFieldAccessKind]) if (k != null) k];
		if (indexAccessKind == null || identKind == null || nullableIndexTypes.length == 0 || derefKinds.length == 0) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final indexAccessKindValue: String = indexAccessKind;
		final identKindValue: String = identKind;
		final ctx: Ctx = {
			indexAccessKind: indexAccessKindValue,
			identKind: identKindValue,
			derefKinds: derefKinds,
			nullableIndexTypes: nullableIndexTypes,
			opaqueKinds: opaqueKinds,
			shape: shape
		};
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			walk(violations, entry.file, tree, tree, declaredTypes, ctx);
		}
		return violations;
	}

	/** No safe single edit — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`, flagging a deref whose receiver is a nullable-index access. */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, ctx: Ctx
	): Void {
		if (ctx.opaqueKinds.contains(node.kind)) return;
		if (ctx.derefKinds.contains(node.kind) && node.children.length >= 1) {
			final receiver: QueryNode = node.children[0];
			final span: Null<Span> = node.span;
			if (span != null && receiver.kind == ctx.indexAccessKind && receiver.children.length >= 1) {
				final mapIdent: QueryNode = receiver.children[0];
				if (mapIdent.kind == ctx.identKind) {
					final typeName: Null<String> = TypeResolver.identTypeName(mapIdent, root, ctx.shape, declaredTypes);
					if (typeName != null && ctx.nullableIndexTypes.contains(typeName)) out.push({
						file: file,
						span: span,
						rule: 'possible-null-dereference',
						severity: Severity.Info,
						message: 'map access $typeName[key] can be null; this dereference has no null check'
					});
				}
			}
		}
		for (c in node.children) walk(out, file, c, root, declaredTypes, ctx);
	}

}

/** Resolved per-run constants threaded through the recursive walk. */
private typedef Ctx = {
	var indexAccessKind: String;
	var identKind: String;
	var derefKinds: Array<String>;
	var nullableIndexTypes: Array<String>;
	var opaqueKinds: Array<String>;
	var shape: RefShape;
};
