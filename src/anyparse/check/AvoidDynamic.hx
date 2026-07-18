package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags a raw `Dynamic` in a DECLARED type position — a field type, a function
 * parameter or return type, a generic type argument (`Map<Dynamic, …>`), or a
 * local `var` / `final` with a type annotation. Raw `Dynamic` erases static
 * checking at that seam; the intent is to surface each one for a narrower type
 * or the sanctioned `Any` top type.
 *
 * ## Report-only — a detector, not a rewriter
 *
 * `fix` yields no edits: the replacement is a semantic decision (which concrete
 * type, or `Any`) that a mechanical rewrite cannot make. A usage-inference fix
 * is a separate future pass; to keep it possible, every violation's span points
 * at the EXACT `Dynamic` token (not the enclosing declaration), so that pass can
 * anchor a replacement precisely. `Severity.Info` by default.
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
final class AvoidDynamic implements Check implements ConfigAware {

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

	/** Report-only — a raw `Dynamic` has no mechanical replacement, so no edits. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
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
