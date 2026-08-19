package anyparse.check;

import anyparse.check.AvoidDynamic.DynCtx;
import anyparse.check.Check.TypeOracle;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.TreePath;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The string-keyed BAG arm of `avoid-dynamic`: a `Dynamic` declaration whose every use is a
 * `Reflect` field operation is not a typing hole to report and leave alone — it is a map
 * written in the wrong type, and `DynamicAccess<T>` is the same program with the type back.
 *
 * The whole arm lives here: proving a declaration is used EXCLUSIVELY as a bag, unifying its
 * written values into one element type `T`, rewriting each `Reflect` call into map syntax, and
 * re-messaging the report so a bag reads as a convertible / typeless / heterogeneous /
 * unresolved one rather than a plain raw-`Dynamic` finding.
 *
 * Split out of `AvoidDynamic`, which keeps the primary rule — finding raw `Dynamic` in a
 * declared type position — and the unrelated local-narrowing autofix.
 */
@:access(anyparse.check.AvoidDynamic)
@:nullSafety(Strict)
final class DynamicBag {

	/** Max inferred-type text length before an oracle-named anon struct is rejected as over-verbose (mirrors explicit-local-type). */
	private static inline final BAG_MAX_ANON: Int = 80;

	/**
	 * Child index of the stored VALUE in a `setField` call: child 3 in a direct
	 * `Reflect.setField(bag, key, value)` (callee, bag, key, value), child 2 in a `using`
	 * extension `bag.setField(key, value)` (callee, key, value).
	 */
	private static inline final DIRECT_VALUE_INDEX: Int = 3;

	private static inline final USING_VALUE_INDEX: Int = 2;

	/** Child index of the KEY: child 2 (direct `Reflect.<m>(bag, key)`) / child 1 (`using` extension `bag.<m>(key)`). */
	private static inline final DIRECT_KEY_INDEX: Int = 2;

	private static inline final USING_KEY_INDEX: Int = 1;

	/**
	 * Reflect operations that form a string-keyed BAG, each mapping to a `DynamicAccess`
	 * map operation: `setField` -> `bag[k] = v`, `field` -> `bag[k]`, `hasField` ->
	 * `bag.exists(k)`, `deleteField` -> `bag.remove(k)`, `fields` -> `bag.keys()`. Any
	 * OTHER reflect call (`getProperty` / `callMethod` / …) is not plain string-keyed
	 * storage, so it is NOT a bag op and DISQUALIFIES the declaration.
	 */
	private static final BAG_METHODS: Array<String> = ['setField', 'field', 'hasField', 'deleteField', 'fields'];

	/** The DynamicAccess bag edits for `violations`; `oracle` (optional) resolves the value-type inference tail. */
	@:access(anyparse.check.AvoidDynamic)
	public static function bagEdits(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?oracle: TypeOracle
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final dynName: Null<String> = shape.rawDynamicTypeName;
		final tree: Null<QueryNode> = dynName == null ? null : CheckScan.parseOrNull(plugin, source);
		if (dynName == null || tree == null) return [];
		final ctx: DynCtx = AvoidDynamic.buildCtx(shape, dynName);
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(source) : [];
		final imports: Map<String, String> = provider != null ? provider.importMap(source) : [];
		final usingReflect: Bool = hasUsingReflect(tree);
		final edits: Array<{ span: Span, text: String }> = [];
		var importAdded: Bool = false;
		for (v in violations) if (v.rule == AvoidDynamic.RULE_ID) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final decl: Null<QueryNode> = fixableBagDecl(tree, source, span, shape, ctx, dynName);
			if (decl == null) continue;
			final bag: Null<BagUses> = bagUsesOf(decl, tree, source, shape, ctx, usingReflect, dynName);
			if (bag == null) continue;
			switch unifyBagValues(bag.writes, tree, shape, dynName, declaredTypes, imports, oracle, v.file) {
				case Real(t):
					edits.push({ span: span, text: 'DynamicAccess<$t>' });
					for (op in bag.ops) edits.push({ span: op.call.span ?? span, text: bagOpText(op, source) });
					if (!importAdded) {
						final ie: Null<{ span: Span, text: String }> = importEdit(tree);
						if (ie != null) {
							edits.push(ie);
							importAdded = true;
						}
					}
				case _:
			}
		}
		return edits;
	}

	/** Whether the module has a top-level `using Reflect;` — required for a `bag.<method>(…)` extension call to be a reflect op. */
	public static function hasUsingReflect(tree: QueryNode): Bool {
		return tree.children.exists(c -> c.kind == 'UsingDecl' && c.name == 'Reflect');
	}

	/**
	 * Re-message every whole-type `Dynamic` LOCAL / FIELD finding in `found` that is a
	 * string-keyed bag, so the REPORT distinguishes a convertible bag (`Real`), a typeless
	 * one (`Typeless`), a heterogeneous one, and an unresolved one — structural resolution
	 * only (the report has no oracle). All positions and visibilities are re-messaged; the
	 * blast-radius gate applies only to the FIX.
	 */
	@:access(anyparse.check.AvoidDynamic)
	public static function annotateBags(
		found: Array<Violation>, source: String, tree: QueryNode, shape: RefShape, ctx: DynCtx, dynName: String,
		declaredTypes: Map<Int, String>, imports: Map<String, String>, usingReflect: Bool
	): Void {
		final declKinds: Array<String> = ctx.localKinds.concat(ctx.fieldKinds);
		for (v in found) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final decl: Null<QueryNode> = AvoidDynamic.wholeDynamicDecl(tree, source, span, shape, dynName, declKinds);
			if (decl == null) continue;
			final bag: Null<BagUses> = bagUsesOf(decl, tree, source, shape, ctx, usingReflect, dynName);
			if (bag == null) continue;
			v.message = bagMessage(unifyBagValues(bag.writes, tree, shape, dynName, declaredTypes, imports, null, v.file));
		}
	}

	/**
	 * The whole-type `Dynamic` declaration node at `span` that the bag FIX may rewrite — a
	 * LOCAL, or a PRIVATE plain FIELD (not public, not a property with accessors). A public
	 * field, a property, or any non-decl position returns null (report-only): rewriting a
	 * public field's type is an API change, and a property's accessor signatures would need
	 * to change too. Reuses `wholeDynamicDecl` for the char / child-containment test.
	 */
	@:access(anyparse.check.AvoidDynamic)
	private static function fixableBagDecl(
		tree: QueryNode, source: String, span: Span, shape: RefShape, ctx: DynCtx, dynName: String
	): Null<QueryNode> {
		final local: Null<QueryNode> = AvoidDynamic.wholeDynamicDecl(tree, source, span, shape, dynName, ctx.localKinds);
		if (local != null) return local;
		final field: Null<QueryNode> = AvoidDynamic.wholeDynamicDecl(tree, source, span, shape, dynName, ctx.fieldKinds);
		if (field == null) return null;
		final fs: Null<Span> = field.span;
		return fs == null || isProperty(source, fs, span) || isPublicMember(tree, field, ctx) ? null : field;
	}

	/** Whether the member `field` (span `fs`, Dynamic token at `dynSpan`) is a property — a `(` accessor clause between the name and the type `:`. */
	private static function isProperty(source: String, fs: Span, dynSpan: Span): Bool {
		var i: Int = fs.from;
		while (i < dynSpan.from && i < source.length) {
			final c: Int = source.fastCodeAt(i);
			if (c == '('.code) return true;
			if (c == ':'.code) return false;
			i++;
		}
		return false;
	}

	/** Whether `member` is preceded (before the previous sibling) by a `Public` visibility modifier — an explicitly public member. */
	private static function isPublicMember(tree: QueryNode, member: QueryNode, ctx: DynCtx): Bool {
		final parent: Null<QueryNode> = TreePath.parentOf(tree, member);
		if (parent == null) return false;
		final kids: Array<QueryNode> = parent.children;
		var idx: Int = -1;
		for (i in 0...kids.length) if (kids[i] == member) idx = i;
		if (idx < 0) return false;
		var j: Int = idx - 1;
		while (j >= 0) {
			final k: String = kids[j].kind;
			if (k == 'Public') return true;
			if (!ctx.prefixKinds.contains(k)) break;
			j--;
		}
		return false;
	}


	/**
	 * The bag's reflect operations and written values when `decl` is used EXCLUSIVELY as a
	 * string-keyed bag, else null. Every non-decl reference to the binding must sit in a
	 * reflect op — the bag arg of a direct `Reflect.<m>(bag, …)` call, or the receiver of a
	 * `using Reflect` extension call `bag.<m>(…)`; ANY other use (a member access, a value
	 * position, an operator, a non-reflect call) disqualifies. `ops` are the reflect calls
	 * to rewrite; `writes` are the `setField` value expressions whose types unify to `T`.
	 */
	private static function bagUsesOf(
		decl: QueryNode, tree: QueryNode, source: String, shape: RefShape, ctx: DynCtx, usingReflect: Bool, dynName: String
	): Null<BagUses> {
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null) return null;
		final isField: Bool = ctx.fieldKinds.contains(decl.kind);
		final allowReturn: Bool = !isField && enclosingFnReturnsDynamic(tree, declSpan.from, shape, ctx, source, dynName);
		final refKeys: Map<String, Bool> = bagRefKeys(name, declSpan.from, tree, shape, isField, ctx);
		final acc: BagUses = { ops: [], writes: [], ok: true };
		classifyBagRefs(tree, null, -1, null, name, shape, ctx, usingReflect, allowReturn, refKeys, acc);
		return acc.ok && acc.ops.length > 0 ? acc : null;
	}

	/**
	 * The span keys of every reference to the bag binding: bare identifiers resolved to the
	 * declaration (via `Refs`), plus — for a FIELD — every `this.<name>` field access inside
	 * the declaring type (which `Refs` does not resolve). The decl occurrence itself is
	 * excluded.
	 */
	private static function bagRefKeys(
		name: String, declFrom: Int, tree: QueryNode, shape: RefShape, isField: Bool, ctx: DynCtx
	): Map<String, Bool> {
		final keys: Map<String, Bool> = [];
		for (h in Refs.find(name, tree, shape)) {
			final b: Null<Span> = h.bindingSpan;
			if (h.kind != RefKind.Decl && b != null && b.from == declFrom) keys['${h.span.from}:${h.span.to}'] = true;
		}
		if (isField) {
			final typeSpan: Null<Span> = enclosingTypeSpan(tree, declFrom, ctx);
			if (typeSpan != null) collectThisFieldKeys(tree, name, shape, ctx, typeSpan, keys);
		}
		return keys;
	}

	/** Add the span key of every `this.<name>` field access within `typeSpan` to `keys`. */
	private static function collectThisFieldKeys(
		node: QueryNode, name: String, shape: RefShape, ctx: DynCtx, typeSpan: Span, keys: Map<String, Bool>
	): Void {
		final s: Null<Span> = node.span;
		if (
			node.kind == ctx.fieldAccessKind && node.name == name && node.children.length == 1 && node.children[0].kind == shape.identKind
			&& node.children[0].name == ctx.selfText && s != null && typeSpan.from <= s.from && s.to <= typeSpan.to
		)
			keys['${s.from}:${s.to}'] = true;
		for (c in node.children) collectThisFieldKeys(c, name, shape, ctx, typeSpan, keys);
	}

	/** The span of the innermost type declaration whose span covers `declFrom`, or null. */
	private static function enclosingTypeSpan(tree: QueryNode, declFrom: Int, ctx: DynCtx): Null<Span> {
		var best: Null<Span> = null;
		var bestWidth: Int = 0;
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (s != null && ctx.typeDeclKinds.contains(n.kind) && s.from <= declFrom && declFrom < s.to) {
				final width: Int = s.to - s.from;
				if (best == null || width < bestWidth) {
					best = s;
					bestWidth = width;
				}
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * Walk `node` classifying every bag reference (matched by span key) into `acc`: a bag
	 * arg of a direct `Reflect.<m>(bag, …)` call or the receiver of a `using Reflect`
	 * extension call `bag.<m>(…)` records a reflect op; anything else sets `acc.ok = false`.
	 */
	private static function classifyBagRefs(
		node: QueryNode, parent: Null<QueryNode>, ci: Int, grand: Null<QueryNode>, name: String, shape: RefShape, ctx: DynCtx,
		usingReflect: Bool, allowReturn: Bool, refKeys: Map<String, Bool>, acc: BagUses
	): Void {
		final s: Null<Span> = node.span;
		if (s != null && refKeys.exists('${s.from}:${s.to}'))
			classifyBagRef(node, parent, ci, grand, shape, ctx, usingReflect, allowReturn, acc);
		final kids: Array<QueryNode> = node.children;
		for (k in 0...kids.length) classifyBagRefs(kids[k], node, k, parent, name, shape, ctx, usingReflect, allowReturn, refKeys, acc);
	}

	/** Classify one bag reference (`occ`, parent `p` at index `ci`, grandparent `g`): a reflect op or a disqualifying use. */
	private static function classifyBagRef(
		occ: QueryNode, p: Null<QueryNode>, ci: Int, g: Null<QueryNode>, shape: RefShape, ctx: DynCtx, usingReflect: Bool,
		allowReturn: Bool, acc: BagUses
	): Void {
		if (p == null) {
			acc.ok = false;
			return;
		}
		final parent: QueryNode = p;
		// A bag arg (child 1) of a call MUST be a direct `Reflect.<m>` op, else it is a value use.
		if (parent.kind == ctx.callKind && ci == 1) {
			final op: Null<BagOp> = directBagOp(parent, occ, shape, ctx);
			if (op == null)
				acc.ok = false;
			else
				recordBagOp(op, DIRECT_VALUE_INDEX, acc);
			return;
		}
		final uop: Null<BagOp> = usingBagOp(occ, parent, ci, g, ctx, usingReflect);
		if (uop != null) {
			recordBagOp(uop, USING_VALUE_INDEX, acc);
			return;
		}
		// Neutral: a bare `bag;` statement, or `return bag;` when the bag flows out as Dynamic (@:to Dynamic is total).
		if (shape.exprStatementKind != null && parent.kind == shape.exprStatementKind) return;
		final returnKinds: Array<String> = shape.valueReturnKinds ?? [];
		if (allowReturn && ci == 0 && returnKinds.contains(parent.kind)) return;
		acc.ok = false;
	}

	/**
	 * The DynamicAccess map-syntax replacement for one reflect op: `setField` -> `bag[k] = v`,
	 * `field` -> `bag[k]`, `hasField` -> `bag.exists(k)`, `deleteField` -> `bag.remove(k)`,
	 * `fields` -> `bag.keys()`. `bag` / `k` / `v` are the verbatim source of the operand nodes.
	 */
	private static function bagOpText(op: BagOp, source: String): String {
		final call: QueryNode = op.call;
		final bagSrc: String = nodeSource(op.bag, source);
		final keyIdx: Int = op.direct ? DIRECT_KEY_INDEX : USING_KEY_INDEX;
		final valIdx: Int = op.direct ? DIRECT_VALUE_INDEX : USING_VALUE_INDEX;
		final key: String = call.children.length > keyIdx ? nodeSource(call.children[keyIdx], source) : '';
		return switch op.method {
			case 'setField': '$bagSrc[$key] = ${call.children.length > valIdx ? nodeSource(call.children[valIdx], source) : ''}';
			case 'field': '$bagSrc[$key]';
			case 'hasField': '$bagSrc.exists($key)';
			case 'deleteField': '$bagSrc.remove($key)';
			case 'fields': '$bagSrc.keys()';
			case _: nodeSource(call, source);
		};
	}

	/** The verbatim source of `node`'s span, or an empty string when it has none. */
	private static function nodeSource(node: QueryNode, source: String): String {
		final s: Null<Span> = node.span;
		return s == null ? '' : source.substring(s.from, s.to);
	}

	/**
	 * The value-type unification verdict for the bag's `writes`: `Real(T)` when every written
	 * value resolves to the SAME real type; `Typeless` when any value is itself `Dynamic` /
	 * `Any` (the common type is `Dynamic` — `DynamicAccess<Dynamic>` adds nothing, the owner
	 * rejected it); `Heterogeneous` when two distinct real types appear; `Undetermined` when a
	 * value's type does not resolve (a compiler oracle is needed) or there are no writes.
	 * Structural resolution first (literal / typed identifier / `new T()`); the `oracle`
	 * (when present) names the unresolved tail.
	 */
	private static function unifyBagValues(
		writes: Array<QueryNode>, tree: QueryNode, shape: RefShape, dynName: String, declaredTypes: Map<Int, String>,
		imports: Map<String, String>, oracle: Null<TypeOracle>, file: String
	): BagVerdict {
		final types: Array<String> = [];
		var hasDynamic: Bool = false;
		var hasUnresolved: Bool = false;
		for (w in writes) {
			var t: Null<String> = bagValueType(w, tree, shape, declaredTypes);
			if (t == null && oracle != null) {
				final ws: Null<Span> = w.span;
				final raw: Null<String> = ws == null ? null : oracle.typeAt(file, ws.to - 1);
				t = raw == null ? null : ExplicitLocalType.normalizeInferredType(raw, imports, BAG_MAX_ANON);
			}
			if (t == null) {
				hasUnresolved = true;
				continue;
			}
			final ty: String = t;
			if (ty == dynName || ty == 'Any' || ty.indexOf(dynName) != -1) {
				hasDynamic = true;
				continue;
			}
			if (!types.contains(ty)) types.push(ty);
		}
		return if (hasDynamic)
			Typeless
		else if (types.length >= 2)
			Heterogeneous
		else if (hasUnresolved)
			Undetermined
		else if (types.length == 1)
			Real(types[0])
		else
			Undetermined;
	}

	/** The structural named type of a written bag value: a literal, a typed identifier, or a `new T(…)`; null when unresolved. */
	private static function bagValueType(w: QueryNode, tree: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>): Null<String> {
		final literalTypes: Map<String, String> = shape.literalTypeNames ?? [];
		return if (literalTypes.exists(w.kind))
			literalTypes[w.kind]
		else if (w.kind == shape.identKind)
			TypeResolver.identTypeName(w, tree, shape, declaredTypes)
		else if (shape.newExprKind != null && w.kind == shape.newExprKind)
			TypeResolver.simpleNominalName(w.name)
		else
			null;
	}

	/** The `import haxe.DynamicAccess;` insertion edit, or null when already imported. Mirrors `AddImport`'s site selection. */
	private static function importEdit(tree: QueryNode): Null<{ span: Span, text: String }> {
		var lastImportTo: Int = -1;
		var packageTo: Int = -1;
		for (c in tree.children) switch c.kind {
			case 'ImportDecl', 'UsingDecl', 'ImportWildDecl', 'ImportAliasDecl', 'ImportAliasInDecl':
				final s: Null<Span> = c.span;
				if (s != null) lastImportTo = s.to;
				if (c.kind == 'ImportDecl' && (c.name == 'haxe.DynamicAccess' || c.name == 'DynamicAccess')) return null;
			case 'PackageDecl':
				final s: Null<Span> = c.span;
				if (s != null) packageTo = s.to;
			case _:
		}
		final stmt: String = 'import haxe.DynamicAccess;';
		return if (lastImportTo >= 0)
			{ span: new Span(lastImportTo, lastImportTo), text: '\n$stmt' }
		else if (packageTo >= 0)
			{ span: new Span(packageTo, packageTo), text: '\n$stmt' }
		else
			{ span: new Span(0, 0), text: '$stmt\n' };
	}

	/** The report message for a bag verdict — the `Typeless` variant encodes the owner's DynamicAccess<Dynamic> rejection. */
	private static function bagMessage(verdict: BagVerdict): String {
		return switch verdict {
			case Real(t): 'raw Dynamic used only as a string-keyed bag — convert it to DynamicAccess<$t>';
			case Typeless: 'raw Dynamic used only as a string-keyed bag whose values are themselves Dynamic — '
				+ 'DynamicAccess<Dynamic> adds nothing over Dynamic, so it stays raw Dynamic';
			case Heterogeneous: 'raw Dynamic used only as a string-keyed bag with mixed value types — no single DynamicAccess element type';
			case Undetermined: 'raw Dynamic used only as a string-keyed bag whose value type does not resolve to a single real type — '
				+ 'it stays raw Dynamic (a compiler oracle may narrow the value; DynamicAccess<Dynamic> is the rejected typeless shape)';
		};
	}

	/** Whether the innermost function containing `declFrom` has an explicit `Dynamic` return type — a bag returned there flows out as Dynamic (safe). */
	@:access(anyparse.check.AvoidDynamic)
	private static function enclosingFnReturnsDynamic(
		tree: QueryNode, declFrom: Int, shape: RefShape, ctx: DynCtx, source: String, dynName: String
	): Bool {
		final fnKinds: Array<String> = shape.functionKinds ?? [];
		if (fnKinds.length == 0) return false;
		var best: Null<QueryNode> = null;
		var bestWidth: Int = 0;
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (s != null && fnKinds.contains(n.kind) && s.from <= declFrom && declFrom < s.to) {
				final w: Int = s.to - s.from;
				if (best == null || w < bestWidth) {
					best = n;
					bestWidth = w;
				}
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		final fn: Null<QueryNode> = best;
		if (fn == null) return false;
		final ret: Null<QueryNode> = AvoidDynamic.returnTypeNode(fn, ctx);
		final rs: Null<Span> = ret?.span;
		return rs != null && source.substring(rs.from, rs.to).trim() == dynName;
	}

	/**
	 * The bag op when `parent` is a direct `Reflect.<m>(bag, …)` call and `occ` (its arg 1)
	 * is the bag — the callee is a `Reflect.<bagMethod>` field access — else null.
	 */
	private static function directBagOp(parent: QueryNode, occ: QueryNode, shape: RefShape, ctx: DynCtx): Null<BagOp> {
		if (parent.children.length == 0) return null;
		final callee: QueryNode = parent.children[0];
		final m: Null<String> = callee.name;
		if (
			callee.kind != ctx.fieldAccessKind || (
				m == null || !BAG_METHODS.contains(m) || callee.children.length != 1 || callee.children[0].kind != shape.identKind
				|| callee.children[0].name != 'Reflect'
			)
		)
			return null;
		final method: String = m;
		return {
			call: parent,
			method: method,
			direct: true,
			bag: occ
		};
	}

	/**
	 * The bag op when `occ` is the receiver (child 0) of a `using Reflect` extension call
	 * `bag.<m>(…)` — `parent` the callee field access, `g` the enclosing call — else null.
	 */
	private static function usingBagOp(
		occ: QueryNode, parent: QueryNode, ci: Int, g: Null<QueryNode>, ctx: DynCtx, usingReflect: Bool
	): Null<BagOp> {
		final m: Null<String> = parent.name;
		if (
			!usingReflect || parent.kind != ctx.fieldAccessKind || ci != 0 || (
				m == null || !BAG_METHODS.contains(m)
				|| (g == null || g.kind != ctx.callKind || g.children.length <= 0 || g.children[0] != parent)
			)
		)
			return null;
		final method: String = m;
		final call: QueryNode = g;
		return {
			call: call,
			method: method,
			direct: false,
			bag: occ
		};
	}

	/** Record `op` and, when it is a `setField`, its stored value (child `valueIndex`) into `acc`. */
	private static function recordBagOp(op: BagOp, valueIndex: Int, acc: BagUses): Void {
		acc.ops.push(op);
		if (op.method == 'setField' && op.call.children.length > valueIndex) acc.writes.push(op.call.children[valueIndex]);
	}

}

/**
 * The value-type unification verdict for a string-keyed `Dynamic` bag: `Real(T)` when every
 * written value shares one real type; `Typeless` when the values are themselves `Dynamic` /
 * `Any` (their common type is `Dynamic`, and the owner rejected `DynamicAccess<Dynamic>` — it
 * adds nothing over raw `Dynamic`); `Heterogeneous` for two distinct real types; `Undetermined`
 * when a value's type does not resolve (a compiler oracle is needed) or there are no writes.
 */
private enum BagVerdict {
	Real(t: String);
	Typeless;
	Heterogeneous;
	Undetermined;
}

/** One reflect operation on a bag: the call node, the reflect method, whether it is a direct `Reflect.<m>` call, and the bag operand node. */
private typedef BagOp = {
	var call: QueryNode;
	var method: String;
	var direct: Bool;
	var bag: QueryNode;
};

/** A bag's classified uses: the reflect operations to rewrite, the `setField` value expressions, and whether every use was a bag op. */
private typedef BagUses = {
	var ops: Array<BagOp>;
	var writes: Array<QueryNode>;
	var ok: Bool;
};
