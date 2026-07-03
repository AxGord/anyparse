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
		final nullableIndexTypes: Array<String> = shape.nullableIndexTypeNames ?? [];
		final returnMarkers: Array<String> = shape.nullableReturnMarkerTypes ?? [];
		final instanceSigs: Array<{ type: String, method: String }> = parseInstanceSigs(shape.nullableInstanceReturnCalls ?? []);
		final noSource: Bool = nullableIndexTypes.length == 0 && instanceSigs.length == 0 && returnMarkers.length == 0;
		if (identKind == null || derefKinds.length == 0 || noSource) return [];
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
			instanceSigs: instanceSigs,
			returnMarkers: returnMarkers
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

	/** Walk `node`, flagging a deref whose receiver is a nullable-index access. */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>,
		returnTypes: Map<Int, String>, ctx: Ctx
	): Void {
		if (ctx.opaqueKinds.contains(node.kind)) return;
		if (ctx.derefKinds.contains(node.kind) && node.children.length >= 1) {
			final span: Null<Span> = node.span;
			if (span != null) {
				final source: Null<String> = nullableSource(node.children[0], root, declaredTypes, returnTypes, ctx);
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

	/**
	 * The nullable-source description of `receiver` when it is a provably-nullable
	 * expression — a `Map`-family index (`m[k]`) or an `Array` / `List` `pop` /
	 * `shift` call — else null. The receiver's declared type is resolved through
	 * `TypeResolver.identTypeName`, so an `Array` index or a same-named method on
	 * an unrelated type is a safe miss.
	 */
	private static function nullableSource(
		receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, returnTypes: Map<Int, String>, ctx: Ctx
	): Null<String> {
		return
			mapIndexSource(receiver, root, declaredTypes, ctx) ?? instanceCallSource(receiver, root, declaredTypes, ctx) ?? returnCallSource(
				receiver, root, returnTypes, ctx
			);
	}

	/** `'map access T[key]'` when `receiver` is a `nullableIndexTypes` index, else null. */
	private static function mapIndexSource(receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, ctx: Ctx): Null<String> {
		if (
			ctx.indexAccessKind == null || ctx.nullableIndexTypes.length == 0 || receiver.kind != ctx.indexAccessKind
			|| receiver.children.length < 1
		)
			return null;
		final ident: QueryNode = receiver.children[0];
		if (ident.kind != ctx.identKind) return null;
		final typeName: Null<String> = TypeResolver.identTypeName(ident, root, ctx.shape, declaredTypes);
		return typeName != null && ctx.nullableIndexTypes.contains(typeName) ? 'map access ${typeName}[key]' : null;
	}

	/** `'T.method()'` when `receiver` is a `nullableInstanceReturnCalls` call, else null. */
	private static function instanceCallSource(
		receiver: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, ctx: Ctx
	): Null<String> {
		if (
			ctx.callKind == null || ctx.fieldAccessKind == null || ctx.instanceSigs.length == 0 || receiver.kind != ctx.callKind
			|| receiver.children.length < 1
		)
			return null;
		final callee: QueryNode = receiver.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != ctx.fieldAccessKind || method == null || callee.children.length != 1) return null;
		final recvIdent: QueryNode = callee.children[0];
		if (recvIdent.kind != ctx.identKind) return null;
		final typeName: Null<String> = TypeResolver.identTypeName(recvIdent, root, ctx.shape, declaredTypes);
		if (typeName == null) return null;
		for (sig in ctx.instanceSigs) if (sig.type == typeName && sig.method == method) return '${typeName}.${method}()';
		return null;
	}

	/** `'name()'` when `receiver` is a call to a plain-identifier function with a `nullableReturnMarkerTypes` return, else null. */
	private static function returnCallSource(receiver: QueryNode, root: QueryNode, returnTypes: Map<Int, String>, ctx: Ctx): Null<String> {
		if (ctx.callKind == null || ctx.returnMarkers.length == 0 || receiver.kind != ctx.callKind || receiver.children.length < 1)
			return null;
		final callee: QueryNode = receiver.children[0];
		final calleeName: Null<String> = callee.name;
		if (callee.kind != ctx.identKind || calleeName == null) return null;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(callee, root, ctx.shape);
		final retType: Null<String> = bindingFrom == null ? null : returnTypes[bindingFrom];
		return retType != null && ctx.returnMarkers.contains(retType) ? '${calleeName}()' : null;
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
	var returnMarkers: Array<String>;
};
