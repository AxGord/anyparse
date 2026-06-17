package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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

	public function new() {}

	public function id(): String {
		return 'prefer-null-coalescing';
	}

	public function description(): String {
		return 'a null-guard ternary (x != null ? x : y) replaceable with the null-coalescing operator (x ?? y)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final ternaryKind: Null<String> = shape.ternaryKind;
		if (ternaryKind == null) return [];
		final eqKind: Null<String> = shape.eqKind;
		if (eqKind == null) return [];
		final notEqKind: Null<String> = shape.notEqKind;
		if (notEqKind == null) return [];
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind == null) return [];
		final unsafeKinds: Array<String> = mutationKinds(shape);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, ternaryKind, eqKind, notEqKind, nullKind, unsafeKinds);
		}
		return violations;
	}

	/** Rewrite each flagged null-guard ternary to `<guarded> ?? <fallback>`. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final ternaryKind: Null<String> = shape.ternaryKind;
		if (ternaryKind == null) return [];
		final eqKind: Null<String> = shape.eqKind;
		if (eqKind == null) return [];
		final notEqKind: Null<String> = shape.notEqKind;
		if (notEqKind == null) return [];
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind == null) return [];
		final unsafeKinds: Array<String> = mutationKinds(shape);
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final nodeByKey: Map<String, QueryNode> = [];
		indexTernaries(tree, ternaryKind, nodeByKey);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeByKey['${span.from}:${span.to}'];
			if (node == null) continue;
			final m: Null<{ guarded: QueryNode, fallback: QueryNode }> = match(node, source, eqKind, notEqKind, nullKind, unsafeKinds);
			if (m == null) continue;
			final guardedSpan: Null<Span> = m.guarded.span;
			final fallbackSpan: Null<Span> = m.fallback.span;
			if (guardedSpan == null || fallbackSpan == null) continue;
			final guardedSrc: String = source.substring(guardedSpan.from, guardedSpan.to);
			final fallbackSrc: String = source.substring(fallbackSpan.from, fallbackSpan.to);
			final fallbackText: String = m.fallback.kind == ternaryKind ? '(' + fallbackSrc + ')' : fallbackSrc;
			edits.push({ span: span, text: guardedSrc + ' ?? ' + fallbackText });
		}
		return edits;
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
		out: Array<Violation>, file: String, source: String, node: QueryNode, ternaryKind: String, eqKind: String, notEqKind: String,
		nullKind: String, unsafeKinds: Array<String>
	): Void {
		if (node.kind == ternaryKind) {
			final span: Null<Span> = node.span;
			if (span != null && match(node, source, eqKind, notEqKind, nullKind, unsafeKinds) != null) {
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
		for (c in node.children) walk(out, file, source, c, ternaryKind, eqKind, notEqKind, nullKind, unsafeKinds);
	}

	/**
	 * If `ternary` is a null guard that `??` replaces, return its guarded value and fallback
	 * branch; else null. Matches all four shapes (`x != null ? x : y`, `null != x ? x : y`,
	 * `x == null ? y : x`, `null == x ? y : x`); rejects a guarded value that mutates a binding.
	 */
	private static function match(
		ternary: QueryNode, source: String, eqKind: String, notEqKind: String, nullKind: String, unsafeKinds: Array<String>
	): Null<{ guarded: QueryNode, fallback: QueryNode }> {
		if (ternary.children.length != 3) return null;
		final cond: QueryNode = ternary.children[0];
		final thenBranch: QueryNode = ternary.children[1];
		final elseBranch: QueryNode = ternary.children[2];
		if (cond.children.length != 2) return null;
		final left: QueryNode = cond.children[0];
		final right: QueryNode = cond.children[1];
		final guarded: Null<QueryNode> = if (left.kind == nullKind && right.kind != nullKind)
			right;
		else if (right.kind == nullKind && left.kind != nullKind)
			left;
		else
			null;
		if (guarded == null) return null;
		if (subtreeMutates(guarded, unsafeKinds)) return null;
		if (cond.kind == notEqKind) {
			if (RefactorSupport.sameSource(guarded, thenBranch, source)) return { guarded: guarded, fallback: elseBranch };
		} else if (cond.kind == eqKind) {
			if (RefactorSupport.sameSource(guarded, elseBranch, source)) return { guarded: guarded, fallback: thenBranch };
		}
		return null;
	}

	/** Whether `node`'s subtree contains any of `unsafeKinds` (a binding-write or a call). */
	private static function subtreeMutates(node: QueryNode, unsafeKinds: Array<String>): Bool {
		for (k in unsafeKinds) if (RefactorSupport.subtreeContainsKind(node, k)) return true;
		return false;
	}

	/** Index every ternary node by its `from:to` span key (for `fix` to re-find a flagged node). */
	private static function indexTernaries(node: QueryNode, ternaryKind: String, out: Map<String, QueryNode>): Void {
		if (node.kind == ternaryKind) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexTernaries(c, ternaryKind, out);
	}

}
