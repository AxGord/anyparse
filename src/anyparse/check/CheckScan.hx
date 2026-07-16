package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Shared scan helpers for the `run` / `fix` paths of the analysis checks.
 * A check parses INDEPENDENTLY in `run` and in `fix` — the platform's
 * thread-safety invariant forbids any shared mutable state or cache between
 * the two calls — so these are PURE static helpers taking the `(plugin,
 * source)` a check already holds. Not a base class (`Check` is an interface),
 * not a cache.
 */
@:nullSafety(Strict)
final class CheckScan {

	private function new() {}

	/**
	 * Parse `source` with `plugin`, or null on any parse failure — the tolerant
	 * parse every check's `run` / `fix` opens with (`Check` forbids throwing on
	 * unparseable input, so both failure modes collapse to null).
	 */
	public static function parseOrNull(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
	}

	/**
	 * The autofix skeleton shared by every span-indexed `fix`: parse `source`,
	 * index its `indexKinds` nodes by `from:to`, then for each violation with a
	 * span re-find the flagged node and let `produce` build its edit (null to
	 * skip that one). Returns the batched edits (empty when `source` does not
	 * parse). `produce` closes over the check's own seams and `source`; the
	 * helper owns only the parse + span-lookup boilerplate.
	 */
	public static function applyBySpan(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>, indexKinds: Array<String>,
		produce: (node:QueryNode, span:Span) -> Null<{ span: Span, text: String }>
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, indexKinds, byKey);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null) continue;
			final edit: Null<{ span: Span, text: String }> = produce(node, span);
			if (edit != null) edits.push(edit);
		}
		return edits;
	}

}
