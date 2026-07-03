package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.check.NullableSource.NullableSourceCfg;

/**
 * Flags a dereference of a provably-nullable expression with no null check — a
 * possible NPE. Three nullable sources so far: a `Map`-family index `m[k]` (a
 * `Null<V>`), an `Array` / `List` `pop` / `shift` call (a `Null<T>`), and a call
 * to a function whose declared return type is `Null<T>`. Slice 1 of the
 * reference-nullable family (mechanism B, the type-driven / point-wise sibling of
 * the flow-sensitive `null-dereference`). `Info`; report-only.
 *
 * ## Type-aware — the receiver type is load-bearing
 *
 * `m[k].field` shares an identical AST with `arr[i].field`, `arr.pop().field` with
 * a `pop()` call on any type, and `findUser().field` with any call — only the
 * receiver's declared type / the callee's declared return type tells them apart. A
 * `Map` index yields `Null<V>` (an `Array` / `String` index a non-null `T`),
 * `Array.pop` / `Array.shift` / `List.pop` yield `Null<T>` (a same-named method on
 * an unrelated type does not), and a `Null<T>`-returning function yields a nullable
 * result. So the deref flags only when the receiver is a `nullableIndexTypeNames`
 * index or a `nullableInstanceReturnCalls` call on a plain identifier of matching
 * declared type (`TypeResolver.identTypeName`), or a call whose plain-identifier
 * callee binds to a function whose `TypeInfoProvider.returnTypes` outer nominal is
 * a `nullableReturnMarkerTypes` (`Null`). All resolution requires
 * `plugin is TypeInfoProvider`. An `Array` / `String` / unannotated / `Null<Map<…>>`
 * receiver, an unrelated-type method, a non-`Null<…>` (or unannotated) return, and
 * a qualified `this.f()` / `obj.f()` callee are safe misses.
 *
 * ## Point-wise, not flow-sensitive
 *
 * There is no narrowing: `if (m.exists(k)) m[k].field`, `if (arr.length > 0)
 * arr.pop().f` and a guarded `findUser().f` are still flagged, since the guard is
 * invisible without flow. That is why the severity is `Info` (advisory), not the
 * `Warning` the flow-sensitive engine earns. A cross-file return is a future sub-pattern. Macro-reification subtrees
 * (`RefShape.opaqueKinds`) are not descended into.
 */
@:nullSafety(Strict)
final class PossibleNullDereference implements Check {

	public function new() {}

	public function id(): String {
		return 'possible-null-dereference';
	}

	public function description(): String {
		return
			'a dereference of a nullable result (map[key], Array/List pop/shift, Null<T>-returning call) with no null check — a possible NPE';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final identKind: Null<String> = shape.identKind;
		final derefKinds: Array<String> = [for (k in [shape.fieldAccessKind, shape.forceFieldAccessKind]) if (k != null) k];
		final cfg: Null<NullableSourceCfg> = NullableSource.build(shape);
		if (identKind == null || derefKinds.length == 0 || cfg == null) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final cfgValue: NullableSourceCfg = cfg;
		final ctx: Ctx = {
			derefKinds: derefKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			cfg: cfgValue
		};
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			final returnTypes: Map<Int, String> = typed.returnTypes(entry.source);
			walk(violations, entry.file, tree, tree, declaredTypes, returnTypes, ctx);
		}
		return violations;
	}

	/** No safe single edit — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`, flagging a deref whose receiver is a nullable source. */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>,
		returnTypes: Map<Int, String>, ctx: Ctx
	): Void {
		if (ctx.opaqueKinds.contains(node.kind)) return;
		if (ctx.derefKinds.contains(node.kind) && node.children.length >= 1) {
			final span: Null<Span> = node.span;
			if (span != null) {
				final source: Null<String> = NullableSource.describe(node.children[0], root, declaredTypes, returnTypes, ctx.cfg);
				if (source != null) out.push({
					file: file,
					span: span,
					rule: 'possible-null-dereference',
					severity: Severity.Info,
					message: '$source can be null; this dereference has no null check'
				});
			}
		}
		for (c in node.children) walk(out, file, c, root, declaredTypes, returnTypes, ctx);
	}

}

/** Resolved per-run constants threaded through the recursive walk. */
private typedef Ctx = {
	var derefKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var cfg: NullableSourceCfg;
};
