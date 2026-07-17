package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;

/**
 * Flags a null-guarding ternary that the null-coalescing operator `??` replaces —
 * `x != null ? x : y` / `null != x ? x : y` / `x == null ? y : x` / `null == x ? y : x`
 * all collapse to `x ?? y`. `Severity.Info` (a modernization cleanup), with an autofix.
 *
 * Two safety constraints:
 *
 * - The guarded value is evaluated TWICE by the ternary but only ONCE by `??`, so a
 *   guarded value whose subtree mutates a binding — a call (`RefShape.callKind`) or an
 *   assignment / increment (`RefShape.writeParentKinds`) — is left alone; collapsing the
 *   two evaluations to one could be observable (`f() ?? y`, `i++ ?? y`).
 * - `??` binds tighter than `?:`, so a fallback that is itself a bare ternary
 *   (`RefShape.ternaryKind`) is parenthesized in the rewrite; every other operand binds
 *   tighter than `??` and needs no parens.
 *
 * ## Grammar-agnostic
 *
 * Driven by four optional `RefShape` kinds — `ternaryKind`, `nullLiteralKind`, `eqKind`,
 * `notEqKind` (any unset → no-op) — plus the always-present `writeParentKinds` and optional
 * `callKind` for the mutation guard. The operator must be known exactly (`==` vs `!=`) to
 * tell which branch holds the guarded value, so the equality kinds are read individually
 * rather than as the `equalityKinds` set. The outermost matching ternary is flagged and not
 * descended into; a nested one is caught on the next `--fix` pass (which iterates to a fixed
 * point).
 */
@:nullSafety(Strict)
final class PreferNullCoalescing implements Check {

	/** A complete ternary node has children [cond, then, else]. */
	private static inline final TERNARY_CHILD_COUNT: Int = 3;

	public function new() {}

	public function id(): String {
		return 'prefer-null-coalescing';
	}

	public function description(): String {
		return 'a null-guard ternary (x != null ? x : y) replaceable with the null-coalescing operator (x ?? y)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final shape: RefShape = plugin.refShape();
		final typed: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final declaredTypes: Null<Map<Int, String>> = typed == null ? null : typed.declaredTypes(entry.source);
			walk(violations, entry.file, entry.source, tree, tree, shape, declaredTypes, seams);
		}
		return violations;
	}

	/** Rewrite each flagged null-guard ternary to `<guarded> ?? <fallback>`. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final shape: RefShape = plugin.refShape();
		final typed: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final root: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (root == null) return [];
		final rootNode: QueryNode = root;
		final declaredTypes: Null<Map<Int, String>> = typed == null ? null : typed.declaredTypes(source);
		return CheckScan.applyBySpan(plugin, source, violations, [seams.ternaryKind], (node, span) -> {
			final m: Null<{ guarded: QueryNode, fallback: QueryNode }> = match(node, source, rootNode, shape, declaredTypes, seams);
			if (m == null) return null;
			final guardedSpan: Null<Span> = m.guarded.span;
			final fallbackSpan: Null<Span> = m.fallback.span;
			if (guardedSpan == null || fallbackSpan == null) return null;
			final guardedSrc: String = source.substring(guardedSpan.from, guardedSpan.to);
			final fallbackSrc: String = source.substring(fallbackSpan.from, fallbackSpan.to);
			final fallbackText: String = m.fallback.kind == seams.ternaryKind ? '(' + fallbackSrc + ')' : fallbackSrc;
			return { span: span, text: guardedSrc + ' ?? ' + fallbackText };
		});
	}

	/** The node kinds whose presence in a guarded value makes the once-vs-twice rewrite unsafe: every binding-write plus the call kind. */
	private static function mutationKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = shape.writeParentKinds.copy();
		final callKind: Null<String> = shape.callKind;
		if (callKind != null) kinds.push(callKind);
		return kinds;
	}

	/**
	 * Walk `node`; flag the outermost null-guard ternary and STOP — a nested one inside it
	 * would yield an overlapping fix, and is caught on the next `--fix` iteration once the
	 * outer rewrite has re-parsed.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, root: QueryNode, shape: RefShape,
		declaredTypes: Null<Map<Int, String>>, seams: Seams
	): Void {
		if (node.kind == seams.ternaryKind) {
			final span: Null<Span> = node.span;
			if (span != null && match(node, source, root, shape, declaredTypes, seams) != null) {
				out.push({
					file: file,
					span: span,
					rule: 'prefer-null-coalescing',
					severity: Severity.Info,
					message: 'this null-guard ternary can be the null-coalescing operator (??)'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, source, c, root, shape, declaredTypes, seams);
	}

	/**
	 * If `ternary` is a null guard that `??` replaces, return its guarded value and fallback
	 * branch; else null. Matches all four shapes (`x != null ? x : y`, `null != x ? x : y`,
	 * `x == null ? y : x`, `null == x ? y : x`); rejects a guarded value that mutates a binding,
	 * and (when the grammar exposes declared types) an INFERENCE-FRAGILE guard — one whose
	 * fallback is a field access on an inference-open receiver inside an active `@:nullSafety`
	 * scope, where the `??` rewrite would flip the fallback's inferred constraint to `Null<…>`
	 * and break null-safety downstream (`TypeResolver.isInferenceFragileNullGuard`).
	 */
	private static function match(
		ternary: QueryNode, source: String, root: QueryNode, shape: RefShape, declaredTypes: Null<Map<Int, String>>, seams: Seams
	): Null<{ guarded: QueryNode, fallback: QueryNode }> {
		if (ternary.children.length != TERNARY_CHILD_COUNT) return null;
		final cond: QueryNode = ternary.children[0];
		final thenBranch: QueryNode = ternary.children[1];
		final elseBranch: QueryNode = ternary.children[2];
		if (cond.children.length != 2) return null;
		final left: QueryNode = cond.children[0];
		final right: QueryNode = cond.children[1];
		final guarded: Null<QueryNode> = if (left.kind == seams.nullKind && right.kind != seams.nullKind)
			right;
		else if (right.kind == seams.nullKind && left.kind != seams.nullKind)
			left;
		else
			null;
		if (guarded == null) return null;
		if (subtreeMutates(guarded, seams.unsafeKinds)) return null;
		final res: Null<{ guarded: QueryNode, fallback: QueryNode }> = if (
			cond.kind == seams.notEqKind && RefactorSupport.sameSource(guarded, thenBranch, source)
		)
			{ guarded: guarded, fallback: elseBranch };
		else if (cond.kind == seams.eqKind && RefactorSupport.sameSource(guarded, elseBranch, source))
			{ guarded: guarded, fallback: thenBranch };
		else
			null;
		if (res == null) return null;
		final span: Null<Span> = ternary.span;
		if (
			declaredTypes != null && span != null
			&& TypeResolver.isInferenceFragileNullGuard(res.fallback, span, root, shape, declaredTypes)
		)
			return null;
		return res;
	}

	/** Whether `node`'s subtree contains any of `unsafeKinds` (a binding-write or a call). */
	private static function subtreeMutates(node: QueryNode, unsafeKinds: Array<String>): Bool {
		for (k in unsafeKinds) if (RefactorSupport.subtreeContainsKind(node, k)) return true;
		return false;
	}

	/**
	 * Resolve the ternary / equality / null seam kinds plus the mutation-unsafe kinds, or null when any required kind is unset.
	 *
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ternaryKind: Null<String> = shape.ternaryKind;
		if (ternaryKind == null) return null;
		final eqKind: Null<String> = shape.eqKind;
		if (eqKind == null) return null;
		final notEqKind: Null<String> = shape.notEqKind;
		if (notEqKind == null) return null;
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind == null) return null;
		final unsafeKinds: Array<String> = mutationKinds(shape);
		return {
			ternaryKind: ternaryKind,
			eqKind: eqKind,
			notEqKind: notEqKind,
			nullKind: nullKind,
			unsafeKinds: unsafeKinds
		};
	}

}

/** The resolved seams `PreferNullCoalescing` reads in both `run` and `fix`. */
private typedef Seams = {
	final ternaryKind: String;
	final eqKind: String;
	final notEqKind: String;
	final nullKind: String;
	final unsafeKinds: Array<String>;
};
