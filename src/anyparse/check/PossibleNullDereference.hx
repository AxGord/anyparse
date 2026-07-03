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
 * Flags a dereference of a provably-nullable expression with no null check — a
 * possible NPE. Two nullable sources so far: a `Map`-family index `m[k]` (a
 * `Null<V>`) and an `Array` / `List` `pop` / `shift` call (a `Null<T>`). Slice 1
 * of the reference-nullable family (mechanism B, the type-driven / point-wise
 * sibling of the flow-sensitive `null-dereference`). `Info`; report-only.
 *
 * ## Type-aware — the receiver type is load-bearing
 *
 * `m[k].field` shares an identical AST with `arr[i].field`, and `arr.pop().field`
 * with a `pop()` call on any type; only the receiver's declared type tells them
 * apart. A `Map` index yields `Null<V>` (an `Array` / `String` index a non-null
 * `T`), and `Array.pop` / `Array.shift` / `List.pop` yield `Null<T>` (a same-named
 * method on an unrelated type does not). So the deref flags only when the
 * receiver is a `RefShape.nullableIndexTypeNames` index, or a
 * `RefShape.nullableInstanceReturnCalls` call, on a plain identifier whose
 * declared outer-nominal type (`TypeResolver.identTypeName`) matches. An `Array` /
 * `String` / unannotated / `Null<Map<…>>` (outer name `Null`) receiver is a safe
 * miss.
 *
 * ## Point-wise, not flow-sensitive
 *
 * There is no narrowing: `if (m.exists(k)) m[k].field` and `if (arr.length > 0)
 * arr.pop().f` are still flagged, since the guard is invisible without flow. That
 * is why the severity is `Info` (advisory), not the `Warning` the flow-sensitive
 * engine earns. `m.get(k)` (a `Call`, not `[]`) and a `Null<T>`-returning free
 * function are future sub-patterns. Macro-reification subtrees
 * (`RefShape.opaqueKinds`) are not descended into.
 */
@:nullSafety(Strict)
final class PossibleNullDereference implements Check {

	public function new() {}

	public function id(): String {
		return 'possible-null-dereference';
	}

	public function description(): String {
		return 'a dereference of a nullable result (map[key], Array/List pop/shift) with no null check — a possible NPE';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final identKind: Null<String> = shape.identKind;
		final derefKinds: Array<String> = [for (k in [shape.fieldAccessKind, shape.forceFieldAccessKind]) if (k != null) k];
		final nullableIndexTypes: Array<String> = shape.nullableIndexTypeNames ?? [];
		final instanceSigs: Array<{ type: String, method: String }> = [];
		for (s in shape.nullableInstanceReturnCalls ?? []) {
			final dot: Int = s.lastIndexOf('.');
			if (dot > 0 && dot < s.length - 1) instanceSigs.push({ type: s.substring(0, dot), method: s.substring(dot + 1) });
		}
		if (identKind == null || derefKinds.length == 0 || (nullableIndexTypes.length == 0 && instanceSigs.length == 0)) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final identKindValue: String = identKind;
		final ctx: Ctx = {
			identKind: identKindValue,
			derefKinds: derefKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			shape: shape,
			indexAccessKind: shape.indexAccessKind,
			nullableIndexTypes: nullableIndexTypes,
			callKind: shape.callKind,
			fieldAccessKind: shape.fieldAccessKind,
			instanceSigs: instanceSigs
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
			final span: Null<Span> = node.span;
			if (span != null) {
				final source: Null<String> = nullableSource(node.children[0], root, declaredTypes, ctx);
				if (source != null) out.push({
					file: file,
					span: span,
					rule: 'possible-null-dereference',
					severity: Severity.Info,
					message: '$source can be null; this dereference has no null check'
				});
			}
		}
		for (c in node.children) walk(out, file, c, root, declaredTypes, ctx);
	}

	/**
	 * The nullable-source description of `receiver` when it is a provably-nullable
	 * expression — a `Map`-family index (`m[k]`) or an `Array` / `List` `pop` /
	 * `shift` call — else null. The receiver's declared type is resolved through
	 * `TypeResolver.identTypeName`, so an `Array` index or a same-named method on
	 * an unrelated type is a safe miss.
	 */
	private static function nullableSource(receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, ctx: Ctx): Null<String> {
		if (
			ctx.indexAccessKind != null && ctx.nullableIndexTypes.length > 0 && receiver.kind == ctx.indexAccessKind
			&& receiver.children.length >= 1
		) {
			final ident: QueryNode = receiver.children[0];
			if (ident.kind == ctx.identKind) {
				final typeName: Null<String> = TypeResolver.identTypeName(ident, root, ctx.shape, declaredTypes);
				if (typeName != null && ctx.nullableIndexTypes.contains(typeName)) return 'map access ${typeName}[key]';
			}
		}
		if (
			ctx.callKind != null && ctx.fieldAccessKind != null && ctx.instanceSigs.length > 0 && receiver.kind == ctx.callKind
			&& receiver.children.length >= 1
		) {
			final callee: QueryNode = receiver.children[0];
			final method: Null<String> = callee.name;
			if (callee.kind == ctx.fieldAccessKind && method != null && callee.children.length == 1) {
				final recvIdent: QueryNode = callee.children[0];
				if (recvIdent.kind == ctx.identKind) {
					final typeName: Null<String> = TypeResolver.identTypeName(recvIdent, root, ctx.shape, declaredTypes);
					if (typeName != null) for (sig in ctx.instanceSigs) if (sig.type == typeName && sig.method == method)
						return '${typeName}.${method}()';
				}
			}
		}
		return null;
	}

}

/** Resolved per-run constants threaded through the recursive walk. */
private typedef Ctx = {
	var identKind: String;
	var derefKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var shape: RefShape;
	var indexAccessKind: Null<String>;
	var nullableIndexTypes: Array<String>;
	var callKind: Null<String>;
	var fieldAccessKind: Null<String>;
	var instanceSigs: Array<{ type: String, method: String }>;
};
