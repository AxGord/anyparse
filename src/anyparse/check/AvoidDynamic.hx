package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags a raw `Dynamic` in a DECLARED type position — a field type, a function
 * parameter or return type, a generic type argument (`Map<Dynamic, …>`), or a
 * local `var` / `final` with a type annotation. Raw `Dynamic` erases static
 * checking at that seam; the intent is to surface each one for a narrower type
 * or the sanctioned `Any` top type.
 *
 * ## Usage-inference autofix — LOCALS only, compiler-verified (`RiskyFix`)
 *
 * `fix` narrows a WHOLE-type `Dynamic` on a local `var` / `final` to the single
 * concrete named type the value PROVABLY ALWAYS HOLDS — every write source, the
 * initializer INCLUDED, being a typed identifier or `new T(…)` of one type. An
 * assignment INTO a typed target (`var y: Foo = x`, `sink = x`) or a param pass is
 * a WEAK obligation (a raw `Dynamic` assigns to ANY type), so it NEVER drives the
 * narrowing — it is only a consistency veto (a differing sink type leaves the local
 * alone). This is the "decide strictly" the weak-obligation rule demands, and it is
 * what makes the rewrite sound: because the writes pin the value's type, replacing
 * `Dynamic` re-states a type the value already has, never inventing one from a sink
 * a `Dynamic` would satisfy regardless.
 *
 * `T` must additionally resolve (via the `SymbolIndex`) to a provably PLAIN nominal —
 * a class / interface / enum, NOT an abstract or typedef: an abstract's implicit
 * `@:from` / `@:to` conversions fire on the STATIC type, so re-typing a binding from
 * `Dynamic` to an abstract compiles yet changes runtime dispatch (the adversarial
 * review's confirmed hole); a typedef may alias one. An unresolvable (stdlib /
 * out-of-scope) name is not provable and skips.
 *
 * EVERY other use DISQUALIFIES the whole declaration (a conservative skip): a member
 * access `x.f` / `x.m()` (a real instance member, a `using`-extension and a getter
 * property are indistinguishable here and each would change runtime dispatch), an `is`
 * test, a reflection call, a `cast`, an operator, `?.` / `!.` / index access, a null
 * comparison, an untyped or non-`T` sink — and ALSO every value-flow into a typed seam
 * of unknown expected type: a call argument, a `return`, a ternary branch. Those seams
 * may expect an abstract with an implicit `@:from` — under `Dynamic` the raw value
 * passes, under a narrowed `T` the conversion fires, both compile, runtime differs.
 * The only neutral use is a bare `x;` statement.
 *
 * The genuine JSON / `Reflect` boundary locals (`var v: Dynamic = Json.parse(…)`,
 * heterogeneous `.checks` / `.props`, `if (Std.isOfType(raw, Array))` guards) therefore
 * skip: their initializer is an untyped `Reflect` / `Json` result (the value is NOT
 * provably one type) and their uses carry member / `is` / reflection signals. This is
 * the correct behaviour — those values are `Dynamic` because they hold genuinely dynamic
 * runtime values, and use-inference cannot soundly narrow them.
 *
 * FIELDS, parameters, returns and type arguments are NOT rewritten: a field's
 * uses are cross-file (an external `is` / heterogeneous read compiles both ways
 * yet changes runtime dispatch — unsound even under an oracle), and a type
 * argument / parameter / return needs element-flow / call-site inference. Those
 * stay report-only. Every violation's span still points at the EXACT `Dynamic`
 * token so the local rewrite (and any future one) anchors precisely.
 *
 * The check is a `RiskyFix`: even the sound local narrowings apply ONLY under a
 * configured compiler oracle (`apqlint.json` `compilerOracle`), which typechecks
 * each candidate and reverts any that breaks the build — a stricter-than-required
 * belt over the by-construction soundness, and the first real `RiskyFix`
 * consumer. Without an oracle the `--fix` run is byte-identical to report-only.
 * `Severity.Info` by default.
 *
 * ## What is and is not flagged
 *
 *  - `haxe.DynamicAccess<…>` / a bare imported `DynamicAccess<…>` — a typed
 *    abstraction, NOT raw `Dynamic`. Excluded for free by the whole-word match
 *    (`Dynamic` there is immediately followed by `Access`, an identifier char).
 *  - `Any` — the sanctioned safe top type (an explicit cast is required to use
 *    it); it is a different name and never matched. It is the recommended fix.
 *  - `Null<Dynamic>` / `Array<Dynamic>` — the nested `Dynamic` is flagged as a
 *    type argument.
 *  - `Dynamic->Void` in a parameter position — the arrow's `Dynamic` sits at
 *    depth 0, so it is flagged at the parameter position.
 *
 * A transit / boundary local whose initializer is a `Reflect` / `Json` call is
 * flagged with a distinct "narrow where consumed" message (and separated in the
 * report), the raw value being an unavoidable API result rather than a chosen type.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.rawDynamicTypeName` is the type name to avoid; `fieldDeclKinds`,
 * `paramKinds`, `localDeclKinds`, and `functionBodyKinds` (for return types via
 * the child-before-the-body rule, mirroring `explicit-type`) locate the declared
 * type positions. An unset `rawDynamicTypeName` makes the check a no-op. Extern
 * types are skipped (interop legitimately uses `Dynamic`); `excludePaths` /
 * `excludeMeta` / `boundaryCalls` are read from `apqlint.json`.
 */
@:nullSafety(Strict)
final class AvoidDynamic implements Check implements ConfigAware implements RiskyFix {

	/** Call-path roots that mark a local as a Reflect/Json boundary transit — reported distinctly. */
	private static final DEFAULT_BOUNDARY_CALLS: Array<String> = ['Reflect', 'Json'];

	private static inline final RULE_ID: String = 'avoid-dynamic';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a raw Dynamic in a declared type position (field, parameter, return, type argument, or annotated local)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final dynName: Null<String> = shape.rawDynamicTypeName;
		if (dynName == null) return [];
		final ctx: DynCtx = buildCtx(shape, dynName);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final cfg: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final excludePaths: Array<String> = cfg.stringListOption(RULE_ID, 'excludePaths') ?? [];
			if (pathExcluded(entry.file, excludePaths)) continue;
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final excludeMeta: Array<String> = cfg.stringListOption(RULE_ID, 'excludeMeta') ?? [];
			final boundaryCalls: Array<String> = cfg.stringListOption(RULE_ID, 'boundaryCalls') ?? DEFAULT_BOUNDARY_CALLS;
			final found: Array<Violation> = [];
			walk(found, entry.file, entry.source, tree, null, false, ctx, excludeMeta, boundaryCalls);
			dedupInto(violations, found);
		}
		return violations;
	}

	/**
	 * Narrow each WHOLE-type `Dynamic` LOCAL among `violations` to a use-inferred
	 * named type, skipping every unsound shape. Field / parameter / return / type-
	 * argument violations yield no edit. `RiskyFix`: the caller applies these only
	 * under a compiler oracle (`FixVerifier`), so a bad inference is reverted, not shipped.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final dynName: Null<String> = shape.rawDynamicTypeName;
		final tree: Null<QueryNode> = dynName == null ? null : CheckScan.parseOrNull(plugin, source);
		if (dynName == null || tree == null) return [];
		final declaredTypes: Map<Int, String> = (plugin is TypeInfoProvider) ? (cast plugin: TypeInfoProvider).declaredTypes(source) : [];
		// The inferred type must resolve to a provably plain nominal — resolved against the
		// caller's cross-file index (FixVerifier), or this file alone when invoked directly.
		final symbols: SymbolIndex = index ?? SymbolIndex.build([{ file: '', source: source }], plugin);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) if (v.rule == RULE_ID) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final decl: Null<QueryNode> = wholeDynamicLocal(tree, source, span, shape, dynName);
			if (decl == null) continue;
			final narrowed: Null<String> = inferLocalNarrowType(decl, tree, shape, dynName, declaredTypes, symbols);
			if (narrowed != null) edits.push({ span: span, text: narrowed });
		}
		return edits;
	}

	/**
	 * The innermost local-decl node whose OWN type annotation is EXACTLY the `Dynamic`
	 * token at `span` — the char before the token (skipping whitespace) is a `:` and
	 * the char after is `=` / `;` / decl-end, so `Array<Dynamic>` / `Map<K, Dynamic>`
	 * / `Dynamic->Void` / `(e : Dynamic)` are all rejected. A span INSIDE any child of
	 * the decl is rejected too: a class-notation struct FIELD (`var o: {var x: Dynamic;
	 * …} = …`) passes the char test (`:` before, `;` after) yet lives in the projected
	 * anon-type child — a Field-position violation the local's inference must never
	 * rewrite (the adversarial review's confirmed mis-attribution). The local's own
	 * whole-type annotation region projects no child nodes, so child-containment
	 * exactly separates the two. Null when `span` is not a whole-type local `Dynamic`.
	 */
	private static function wholeDynamicLocal(
		tree: QueryNode, source: String, span: Span, shape: RefShape, dynName: String
	): Null<QueryNode> {
		final localKinds: Array<String> = shape.localDeclKinds ?? [];
		if (localKinds.length == 0) return null;
		if (span.to > source.length || source.substring(span.from, span.to) != dynName) return null;
		var i: Int = span.from - 1;
		while (i >= 0 && isSpaceCode(source.fastCodeAt(i))) i--;
		if (i < 0 || source.fastCodeAt(i) != ':'.code) return null;
		var j: Int = span.to;
		while (j < source.length && isSpaceCode(source.fastCodeAt(j))) j++;
		final after: Int = j < source.length ? source.fastCodeAt(j) : -1;
		if (after != '='.code && after != ';'.code && after != -1) return null;
		final decl: Null<QueryNode> = innermostContaining(tree, span, localKinds);
		if (decl == null) return null;
		for (c in decl.children) {
			final cs: Null<Span> = c.span;
			if (cs != null && cs.from <= span.from && span.to <= cs.to) return null;
		}
		return decl;
	}

	/** The smallest node whose kind is in `kinds` and whose span contains `span`, or null. */
	private static function innermostContaining(tree: QueryNode, span: Span, kinds: Array<String>): Null<QueryNode> {
		var best: Null<QueryNode> = null;
		var bestWidth: Int = 0;
		function walk(n: QueryNode): Void {
			final s: Null<Span> = n.span;
			if (s != null && kinds.contains(n.kind) && s.from <= span.from && span.to <= s.to) {
				final width: Int = s.to - s.from;
				if (best == null || width < bestWidth) {
					best = n;
					bestWidth = width;
				}
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * The sound narrowing type for the `Dynamic` local `decl`, or null to leave it
	 * report-only. Sound criteria (all required): a present, non-null, TYPED
	 * initializer; every reassignment source typed the SAME single type `T`; `T`
	 * resolves in the symbol index to a provably PLAIN nominal (class / interface /
	 * enum — not an abstract, whose implicit conversions change dispatch, and not a
	 * typedef, which may alias one); a USE corroborates `T`; every weak sink agrees;
	 * and no disqualifying use anywhere. See the class doc for the rationale.
	 */
	private static function inferLocalNarrowType(
		decl: QueryNode, tree: QueryNode, shape: RefShape, dynName: String, declaredTypes: Map<Int, String>, symbols: SymbolIndex
	): Null<String> {
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null) return null;
		final acc: NarrowAcc = gatherUses(name, declSpan.from, tree, shape, dynName, declaredTypes);
		if (acc.disqualified || acc.nullUse) return null;

		// STRONG obligation only: the value must provably ALWAYS hold a `T` — every write
		// source, the initializer INCLUDED, is a typed identifier / `new T(…)` of the one type.
		// An assignment INTO a typed target (`var y: Foo = x`) is a WEAK obligation (a raw
		// Dynamic assigns to ANY type), so it never DRIVES the narrowing — it serves only as a
		// consistency veto below. This is the task's "decide strictly".
		final init: InitInfo = initSourceInfo(decl, shape, tree, declaredTypes, dynName);
		if (!init.present || init.isNull) return null;
		final initType: Null<String> = init.type;
		if (initType == null || acc.reassignHasUntyped) return null;
		final initTyped: String = initType;
		final writeTypes: Array<String> = distinct([initTyped].concat(acc.reassignTypes));
		if (writeTypes.length != 1) return null;
		final t: String = writeTypes[0];
		if (t == dynName || t == 'Any' || !isNominalName(t)) return null;
		if (acc.useCount == 0) return null;
		// `T` must be a provably plain nominal: an abstract's implicit `@:from` / `@:to`
		// conversions fire on the STATIC type, so re-typing the local from `Dynamic` to an
		// abstract `T` compiles yet changes runtime dispatch at every seam (the adversarial
		// review's confirmed hole); a typedef may alias an abstract or `Dynamic`. Unresolvable
		// (stdlib / out-of-scope) names are not provable and skip.
		if (!symbols.resolvesToPlainNominal(t)) return null;
		// Consistency veto: a weak sink whose type differs from `T` signals a heterogeneous use —
		// leave it alone (an exact-name match is the only accepted sink shape).
		for (s in acc.sinkTypes) if (s != t) return null;
		// A USE must corroborate `T` — a typed sink (`var y: T = x`) or a typed reassignment
		// (`x = t`). A local justified by its initializer alone is not narrowed: the rewrite
		// must be driven by a use (the task's "from uses, not from the initializer").
		return acc.sinkTypes.length == 0 && acc.reassignTypes.length == 0 ? null : t;
	}

	/**
	 * Resolve every read/write occurrence of the local `name` (binding-`from` `bindFrom`)
	 * via `Refs.find`, then walk the tree classifying each into a fresh accumulator.
	 */
	private static function gatherUses(
		name: String, bindFrom: Int, tree: QueryNode, shape: RefShape, dynName: String, declaredTypes: Map<Int, String>
	): NarrowAcc {
		final targetKeys: Map<String, Bool> = [];
		for (h in Refs.find(name, tree, shape)) {
			final b: Null<Span> = h.bindingSpan;
			if (h.kind != RefKind.Decl && b != null && b.from == bindFrom) targetKeys['${h.span.from}:${h.span.to}'] = true;
		}
		final acc: NarrowAcc = {
			disqualified: false,
			nullUse: false,
			useCount: 0,
			reassignTypes: [],
			reassignHasUntyped: false,
			sinkTypes: []
		};
		classifyOccurrences(tree, tree, null, -1, name, shape, dynName, declaredTypes, targetKeys, acc);
		return acc;
	}

	/**
	 * Walk `tree` classifying every read/write occurrence of the local `name` (matched
	 * by resolved binding via `targetKeys`) into `acc`: member accesses, typed sinks,
	 * typed reassignment sources, and the disqualifying / null-using / neutral shapes.
	 */
	private static function classifyOccurrences(
		node: QueryNode, root: QueryNode, parent: Null<QueryNode>, childIndex: Int, name: String, shape: RefShape, dynName: String,
		declaredTypes: Map<Int, String>, targetKeys: Map<String, Bool>, acc: NarrowAcc
	): Void {
		final s: Null<Span> = node.span;
		if (node.kind == shape.identKind && node.name == name && s != null && targetKeys.exists('${s.from}:${s.to}'))
			classifyOne(node, parent, childIndex, shape, dynName, root, declaredTypes, acc);
		final kids: Array<QueryNode> = node.children;
		for (k in 0...kids.length) classifyOccurrences(kids[k], root, node, k, name, shape, dynName, declaredTypes, targetKeys, acc);
	}

	/**
	 * Classify one occurrence of the local (parent `p`, position `ci`): a write (`x = e`,
	 * simple assign at position 0) routes to `classifyWrite`, every other position to
	 * `classifyRead`. A null parent (a top-level orphan) disqualifies.
	 */
	private static function classifyOne(
		occ: QueryNode, p: Null<QueryNode>, ci: Int, shape: RefShape, dynName: String, root: QueryNode, declaredTypes: Map<Int, String>,
		acc: NarrowAcc
	): Void {
		if (p == null) {
			acc.disqualified = true;
			return;
		}
		if (shape.assignKind != null && p.kind == shape.assignKind && ci == 0)
			classifyWrite(p, shape, dynName, root, declaredTypes, acc);
		else
			classifyRead(p, ci, shape, dynName, root, declaredTypes, acc);
	}

	/**
	 * A write `x = e`: record the source's named type (a STRONG obligation — the value is
	 * that type after the write), flag an untyped source, or flag a null write (`x = null`,
	 * which would defeat a non-null narrowing).
	 */
	private static function classifyWrite(
		p: QueryNode, shape: RefShape, dynName: String, root: QueryNode, declaredTypes: Map<Int, String>, acc: NarrowAcc
	): Void {
		acc.useCount++;
		final rhs: Null<QueryNode> = p.children.length > 1 ? p.children[1] : null;
		if (rhs == null) {
			acc.disqualified = true;
			return;
		}
		if (shape.nullLiteralKind != null && rhs.kind == shape.nullLiteralKind) {
			acc.nullUse = true;
			return;
		}
		final st: Null<String> = sourceType(rhs, root, shape, dynName, declaredTypes);
		if (st == null)
			acc.reassignHasUntyped = true;
		else
			acc.reassignTypes.push(st);
	}

	/**
	 * Classify a READ occurrence (parent `p`, position `ci`): a typed sink of the SAME
	 * shape (`sink = x` / `var y: T = x`) is recorded as a WEAK consistency veto; a bare
	 * statement (`x;`) is the only neutral pass-through; EVERYTHING ELSE disqualifies.
	 * A member access is undecidable (instance member vs `using`-extension vs getter —
	 * each changes dispatch); a call argument, `return`, or ternary branch hands the
	 * value to a typed seam whose expected type may be an abstract with an implicit
	 * `@:from` — under `Dynamic` the raw value passes, under a narrowed `T` the
	 * conversion fires, both compile, runtime differs (the adversarial review's
	 * confirmed hole) — so value-flow into ANY typed seam other than an exact-`T`
	 * sink is out.
	 */
	private static function classifyRead(
		p: QueryNode, ci: Int, shape: RefShape, dynName: String, root: QueryNode, declaredTypes: Map<Int, String>, acc: NarrowAcc
	): Void {
		acc.useCount++;
		if (recordWeakSink(p, ci, p.kind, shape, dynName, root, declaredTypes, acc)) return;
		if (p.kind == shape.exprStatementKind) return; // a bare `x;` statement — a no-op
		acc.disqualified = true;
	}

	/**
	 * Record a WEAK typed sink the value flows into — `sink = x` (a simple assign, `x` at
	 * position 1) or `var y: T = x` (a local-decl parent) — as a consistency veto, and
	 * return true when `p` is a sink position (handled), false otherwise. A sink whose
	 * type cannot be resolved (an untyped `var y = x`, a `Null<…>`-wrapped or non-nominal
	 * annotation, a field / unresolved target) DISQUALIFIES: the target is a typed seam
	 * of unknown type, exactly the shape the abstract-`@:from` hole lives in.
	 */
	private static function recordWeakSink(
		p: QueryNode, ci: Int, pk: String, shape: RefShape, dynName: String, root: QueryNode, declaredTypes: Map<Int, String>,
		acc: NarrowAcc
	): Bool {
		var ty: Null<String>;
		if (shape.assignKind != null && pk == shape.assignKind && ci == 1) {
			final lhs: Null<QueryNode> = p.children.length > 0 ? p.children[0] : null;
			ty = lhs != null && lhs.kind == shape.identKind ? TypeResolver.identTypeName(lhs, root, shape, declaredTypes) : null;
		} else if ((shape.localDeclKinds ?? []).contains(pk)) {
			final ps: Null<Span> = p.span;
			ty = ps == null ? null : declaredTypes[ps.from];
		} else
			return false;
		if (ty != null && acceptableType(ty, dynName))
			acc.sinkTypes.push(ty);
		else
			acc.disqualified = true;
		return true;
	}

	/** Whether `ty` is a usable narrowing / sink type — a plain nominal name that is not the raw dynamic name or `Any`. */
	private static function acceptableType(ty: String, dynName: String): Bool {
		return ty != dynName && ty != 'Any' && isNominalName(ty);
	}

	/** The named type of a write / init source expression: a typed identifier or a `new T(…)`, else null (untyped). */
	private static function sourceType(
		expr: QueryNode, root: QueryNode, shape: RefShape, dynName: String, declaredTypes: Map<Int, String>
	): Null<String> {
		if (expr.kind == shape.identKind) {
			final ty: Null<String> = TypeResolver.identTypeName(expr, root, shape, declaredTypes);
			return ty != null && acceptableType(ty, dynName) ? ty : null;
		}
		if (shape.newExprKind != null && expr.kind == shape.newExprKind) {
			final nm: Null<String> = TypeResolver.simpleNominalName(expr.name);
			return nm != null && acceptableType(nm, dynName) ? nm : null;
		}
		return null;
	}

	/**
	 * The initializer info of `decl`: its first non-type child is the initializer.
	 * `present` false when there is none; `isNull` when it is a null literal; `type`
	 * the source's named type when typed, else null.
	 */
	private static function initSourceInfo(
		decl: QueryNode, shape: RefShape, root: QueryNode, declaredTypes: Map<Int, String>, dynName: String
	): InitInfo {
		final typeKinds: Array<String> = shape.declTypeChildKinds ?? [];
		final init: Null<QueryNode> = decl.children.find(c -> !typeKinds.contains(c.kind));

		if (init == null) return { present: false, isNull: false, type: null };
		final i: QueryNode = init;
		return shape.nullLiteralKind != null && i.kind == shape.nullLiteralKind
			? {
				present: true,
				isNull: true,
				type: null
			}
			: {
				present: true,
				isNull: false,
				type: sourceType(i, root, shape, dynName, declaredTypes)
			};
	}

	/** The distinct values of `xs`, order-preserving. */
	private static function distinct(xs: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (x in xs) if (!out.contains(x)) out.push(x);
		return out;
	}

	/** Whether `name` is a plain nominal simple/qualified name — no generics, arrows or other type syntax. */
	private static function isNominalName(name: String): Bool {
		if (name.length == 0) return false;
		for (k in 0...name.length) {
			final c: Int = name.fastCodeAt(k);
			if (!isWordChar(c) && c != '.'.code) return false;
		}
		return true;
	}

	private static inline function isSpaceCode(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/** The resolved kind sets threaded through the walk, built once per run. */
	private static function buildCtx(shape: RefShape, dynName: String): DynCtx {
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final localKinds: Array<String> = shape.localDeclKinds ?? [];
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		final prefixKinds: Array<String> = (shape.modifierOrderKinds ?? []).copy();
		final externName: Null<String> = shape.externModifierKind;
		if (externName != null) prefixKinds.push(externName);
		final macroMod: Null<String> = shape.macroModifierKind;
		if (macroMod != null) prefixKinds.push(macroMod);
		prefixKinds.push('Meta');
		return {
			dynName: dynName,
			fieldKinds: fieldKinds,
			paramKinds: paramKinds,
			localKinds: localKinds,
			bodyKinds: bodyKinds,
			prefixKinds: prefixKinds,
			externKind: externName,
			enumAbstractKind: shape.enumAbstractDeclKind,
			anonKind: 'Anon',
			varFieldKind: 'VarField',
			callKind: shape.callKind ?? '',
			fieldAccessKind: shape.fieldAccessKind ?? '',
			identKind: shape.identKind
		};
	}

	/**
	 * Walk `node`, inspecting it for declared `Dynamic` positions, then descend
	 * into its children. A preceding `extern` modifier (or a configured exclusion
	 * meta) marks the following declaration's whole subtree excluded — the pending
	 * flag survives intervening visibility modifiers and is consumed by the next
	 * real node.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, parentKind: Null<String>, excluded: Bool, ctx: DynCtx,
		excludeMeta: Array<String>, boundaryCalls: Array<String>
	): Void {
		if (!excluded) inspectNode(out, file, source, node, parentKind, ctx, boundaryCalls);
		final kids: Array<QueryNode> = node.children;
		var pendingExclude: Bool = false;
		for (child in kids) {
			if (ctx.prefixKinds.contains(child.kind)) {
				if (ctx.externKind != null && child.kind == ctx.externKind)
					pendingExclude = true;
				else if (child.kind == 'Meta') {
					final nm: Null<String> = child.name;
					if (nm != null && excludeMeta.contains(nm)) pendingExclude = true;
				}
				continue;
			}
			walk(out, file, source, child, node.kind, excluded || pendingExclude, ctx, excludeMeta, boundaryCalls);
			pendingExclude = false;
		}
	}

	/** Emit findings for `node` when it is a declared type position of one of the recognised shapes. */
	private static function inspectNode(
		out: Array<Violation>, file: String, source: String, node: QueryNode, parentKind: Null<String>, ctx: DynCtx,
		boundaryCalls: Array<String>
	): Void {
		final kind: String = node.kind;
		if (ctx.fieldKinds.contains(kind)) {
			if (parentKind != ctx.enumAbstractKind) scanDeclType(out, file, source, node, Field, ctx, false);
			return;
		}
		if (kind == ctx.varFieldKind) {
			scanDeclType(out, file, source, node, Field, ctx, false);
			return;
		}
		if (ctx.paramKinds.contains(kind)) {
			// A parameter node inside an anonymous structure is a struct field, not a real parameter.
			scanDeclType(out, file, source, node, parentKind == ctx.anonKind ? Field : Param, ctx, false);
			return;
		}
		if (ctx.localKinds.contains(kind)) {
			scanDeclType(out, file, source, node, Local, ctx, isBoundaryInit(node, ctx, boundaryCalls));
			return;
		}
		final ret: Null<QueryNode> = returnTypeNode(node, ctx);
		if (ret != null) scanNodeSpan(out, file, source, ret, Return, ctx, false);
	}

	/**
	 * Scan the type-annotation region of a field / parameter / local: the source
	 * between the first `:` after the name and the initializer / default (the first
	 * child's start) or the node's end. An anonymous-structure type is projected as
	 * the first child, so the region ends before it and its inner fields are walked
	 * independently — no double count.
	 */
	private static function scanDeclType(
		out: Array<Violation>, file: String, source: String, node: QueryNode, position: DynPos, ctx: DynCtx, boundary: Bool
	): Void {
		final span: Null<Span> = node.span;
		if (span == null) return;
		scanTypeAfterColon(out, file, source, span.from, declTypeCutoff(node, ctx, span.to), position, ctx, boundary);
	}

	/**
	 * The end of the type-annotation region: the initializer / default (the first
	 * child's start) for a field / parameter / local, a nested anonymous type for a
	 * `VarField` (whose own type sits inside a name-wrapping child), else the node
	 * end. An anonymous type's inner fields are walked independently — no double count.
	 */
	private static function declTypeCutoff(node: QueryNode, ctx: DynCtx, end: Int): Int {
		if (node.kind == ctx.varFieldKind) {
			for (c in node.children) if (c.kind == ctx.anonKind) {
				final cs: Null<Span> = c.span;
				if (cs != null) return cs.from;
			}
			return end;
		}
		if (node.children.length > 0) {
			final firstSpan: Null<Span> = node.children[0].span;
			if (firstSpan != null) return firstSpan.from;
		}
		return end;
	}

	/** Find the `:` after the name in `[spanFrom, cutoff)` and scan the type that follows it for the raw dynamic name. */
	private static function scanTypeAfterColon(
		out: Array<Violation>, file: String, source: String, spanFrom: Int, cutoff: Int, position: DynPos, ctx: DynCtx, boundary: Bool
	): Void {
		final colon: Int = source.substring(spanFrom, cutoff).indexOf(':');
		if (colon < 0) return;
		scanRange(out, file, source, spanFrom + colon + 1, cutoff, position, ctx, boundary);
	}

	/** Scan a projected type node (a function return type) over its whole span. */
	private static function scanNodeSpan(
		out: Array<Violation>, file: String, source: String, node: QueryNode, position: DynPos, ctx: DynCtx, boundary: Bool
	): Void {
		final span: Null<Span> = node.span;
		if (span == null) return;
		scanRange(out, file, source, span.from, span.to, position, ctx, boundary);
	}

	/**
	 * Scan `source[from...to)` for whole-word occurrences of the raw dynamic name,
	 * tracking generic-bracket depth so a nested `Dynamic` reports as a type
	 * argument. A `>` that is the tail of a `->` arrow is not a bracket close. A
	 * match preceded by an identifier char or `.` (a longer name / a qualified
	 * user type) or followed by an identifier char (`DynamicAccess`) is skipped.
	 */
	private static function scanRange(
		out: Array<Violation>, file: String, source: String, from: Int, to: Int, position: DynPos, ctx: DynCtx, boundary: Bool
	): Void {
		final dyn: String = ctx.dynName;
		final dynLen: Int = dyn.length;
		var depth: Int = 0;
		var i: Int = from;
		while (i < to) {
			final c: Int = source.fastCodeAt(i);
			if (c == '<'.code) {
				depth++;
				i++;
			} else if (c == '>'.code && (i == 0 || source.fastCodeAt(i - 1) != '-'.code)) {
				depth--;
				i++;
			} else if (matchesWordAt(source, i, dyn, dynLen)) {
				final prev: Int = i > 0 ? source.fastCodeAt(i - 1) : -1;
				if (!isWordChar(prev) && prev != '.'.code) {
					final pos: DynPos = depth > 0 ? TypeArg : position;
					push(out, file, i, i + dynLen, pos, boundary && pos == Local);
				}
				i += dynLen;
			} else
				i++;
		}
	}

	/** Whether `source` holds `dyn` at `i` as a whole word (not immediately followed by an identifier char). */
	private static function matchesWordAt(source: String, i: Int, dyn: String, dynLen: Int): Bool {
		if (i + dynLen > source.length) return false;
		for (k in 0...dynLen) if (source.fastCodeAt(i + k) != dyn.fastCodeAt(k)) return false;
		final after: Int = i + dynLen < source.length ? source.fastCodeAt(i + dynLen) : -1;
		return !isWordChar(after);
	}

	private static inline function isWordChar(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/**
	 * The return-type node of `node` when it is a function form (has a body-marker
	 * child): the child directly before the body, when that child is neither a
	 * parameter nor a body marker — mirroring `explicit-type`'s rule, which also
	 * separates a generic constraint (before the parameters) from the return type
	 * (immediately before the body). A constructor's before-body child is a
	 * parameter, so it yields no return type.
	 */
	private static function returnTypeNode(node: QueryNode, ctx: DynCtx): Null<QueryNode> {
		final kids: Array<QueryNode> = node.children;
		var bodyIndex: Int = -1;
		for (i in 0...kids.length) if (ctx.bodyKinds.contains(kids[i].kind)) bodyIndex = i;
		if (bodyIndex <= 0) return null;
		final before: QueryNode = kids[bodyIndex - 1];
		return ctx.paramKinds.contains(before.kind) || ctx.bodyKinds.contains(before.kind) ? null : before;
	}

	/** Whether the local's initializer (its last child) is a call whose callee path roots at a boundary segment. */
	private static function isBoundaryInit(node: QueryNode, ctx: DynCtx, boundaryCalls: Array<String>): Bool {
		final kids: Array<QueryNode> = node.children;
		if (kids.length == 0) return false;
		final last: QueryNode = kids[kids.length - 1];
		if (last.kind != ctx.callKind || last.children.length == 0) return false;
		for (seg in calleePath(last.children[0], ctx)) if (boundaryCalls.contains(seg)) return true;
		return false;
	}

	/** The dotted callee path (root first) of a call's callee expression, or an empty array for a shape it cannot read. */
	private static function calleePath(callee: QueryNode, ctx: DynCtx): Array<String> {
		if (callee.kind == ctx.fieldAccessKind) {
			final base: Array<String> = callee.children.length > 0 ? calleePath(callee.children[0], ctx) : [];
			final nm: Null<String> = callee.name;
			if (nm != null) base.push(nm);
			return base;
		}
		if (callee.kind == ctx.identKind) {
			final nm: Null<String> = callee.name;
			return nm != null ? [nm] : [];
		}
		return [];
	}

	/** Whether `file`'s path contains any of the configured exclusion substrings. */
	private static function pathExcluded(file: String, patterns: Array<String>): Bool {
		for (p in patterns) if (p.length > 0 && file.indexOf(p) >= 0) return true;
		return false;
	}

	/** Append findings from `found` into `into`, dropping duplicates at the same span (overlapping walk paths hit one token twice). */
	private static function dedupInto(into: Array<Violation>, found: Array<Violation>): Void {
		final seen: Map<String, Bool> = [];
		for (v in found) {
			final span: Null<Span> = v.span;
			final key: String = span == null ? '' : '${span.from}:${span.to}';
			if (!(span == null || !seen.exists(key))) continue;
			seen[key] = true;
			into.push(v);
		}
	}

	private static function push(out: Array<Violation>, file: String, from: Int, to: Int, position: DynPos, boundary: Bool): Void {
		out.push({
			file: file,
			span: new Span(from, to),
			rule: RULE_ID,
			severity: Severity.Info,
			message: messageFor(position, boundary)
		});
	}

	private static function messageFor(position: DynPos, boundary: Bool): String {
		return switch position {
			case Field: 'raw Dynamic field type — narrow it or use Any';
			case Param: 'raw Dynamic parameter type — narrow it or use Any';
			case Return: 'raw Dynamic return type — narrow it or use Any';
			case TypeArg: 'raw Dynamic type argument — narrow it or use Any';
			case Local: boundary
				? 'raw Dynamic boundary local (Reflect/Json result) — narrow the type where it is consumed'
				: 'raw Dynamic local variable type — narrow it or use Any';
		};
	}

}

/** The declared-type position a raw `Dynamic` was found in — drives the report taxonomy and message. */
private enum DynPos {
	Field;
	Param;
	Return;
	Local;
	TypeArg;
}

/** Mutable accumulator threaded through the local-narrowing use classifier. */
private typedef NarrowAcc = {
	/** A use where raw Dynamic is load-bearing was seen — skip the declaration. */
	var disqualified: Bool;

	/** The local is compared with / assigned null — narrowing to a non-null type would be unsound. */
	var nullUse: Bool;

	/** Count of real uses (reads + reassignments) — a declaration with none is not narrowed. */
	var useCount: Int;

	/** Named types of the typed reassignment sources (`x = foo`). */
	var reassignTypes: Array<String>;

	/** A reassignment whose source type is unresolved — the value is not provably always one type. */
	var reassignHasUntyped: Bool;

	/** Named types of the weak typed sinks the value flows into (`y = x` / `var y: T = x`) — a consistency veto only. */
	var sinkTypes: Array<String>;
};

/** The initializer shape of a `Dynamic` local: presence, null-literal, and resolved source type. */
private typedef InitInfo = {
	var present: Bool;
	var isNull: Bool;
	var type: Null<String>;
};

/** Resolved kind sets + config-independent names threaded through the walk, built once per run. */
private typedef DynCtx = {
	final dynName: String;
	final fieldKinds: Array<String>;
	final paramKinds: Array<String>;
	final localKinds: Array<String>;
	final bodyKinds: Array<String>;
	final prefixKinds: Array<String>;
	final externKind: Null<String>;
	final enumAbstractKind: Null<String>;
	final anonKind: String;
	final varFieldKind: String;
	final callKind: String;
	final fieldAccessKind: String;
	final identKind: String;
};
