package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a member whose modifier keywords are not in the canonical order
 * `override → public / private → static → inline`. Purely cosmetic — the order
 * carries no meaning to the compiler — so `Info`; `--fix` reorders the run into
 * canonical order.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.modifierOrderKinds` is the canonical order: a modifier's rank is its
 * index there. The check collects each member's run of ranked modifier siblings
 * (resetting at a `RefShape.memberDeclKinds` boundary) and flags a run whose ranks
 * are not non-decreasing. Modifiers absent from the list (extern, dynamic, macro,
 * …) carry no documented order and are ignored. Either field unset → no-op.
 */
@:nullSafety(Strict)
final class ModifierOrder implements Check {

	public function new() {}

	public function id(): String {
		return 'modifier-order';
	}

	public function description(): String {
		return 'member modifiers not in canonical order (override -> public/private -> static -> inline)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final defaultOrder: Array<String> = shape.modifierOrderKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		if (members.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			// A project checkstyle `ModifierOrder.modifiers` overrides the grammar's default ranking.
			final order: Array<String> = plugin.checkOverrides(entry.file)?.modifierOrder ?? defaultOrder;
			if (order.length == 0) continue;
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, order, members);
		}
		return violations;
	}

	/**
	 * Reorder each flagged member's ranked-modifier run into canonical order. The
	 * run's ranked siblings (kind in `modifierOrderKinds`) are sorted by rank and
	 * written back into their own source slots — each slot takes the keyword whose
	 * rank now belongs there — so unranked modifiers (extern, dynamic, …) and
	 * `@:meta` keep their physical positions and only the ranked keywords move.
	 * Re-parses `source`, and emits edits only for a run whose start offset matches
	 * a passed violation (so a config-filtered finding is not silently fixed).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final order: Array<String> = shape.modifierOrderKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		if (order.length == 0 || members.length == 0) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		reorderWalk(edits, source, tree, order, members, flagged);
		return edits;
	}

	/** Walk `node`, checking each node's direct children for an out-of-order modifier run. */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, order: Array<String>, members: Array<String>): Void {
		flagChildren(out, file, node, order, members);
		for (c in node.children) walk(out, file, c, order, members);
	}

	/**
	 * Scan `node`'s direct children, tracking the run of ranked modifier siblings
	 * leading up to each member. A modifier whose rank falls below an earlier one in
	 * the same run is out of order; one violation per run, spanning the run. The run
	 * resets at each member-host boundary; a non-modifier non-member child (meta, an
	 * unranked modifier) keeps it open.
	 */
	private static function flagChildren(
		out: Array<Violation>, file: String, node: QueryNode, order: Array<String>, members: Array<String>
	): Void {
		var runStart: Null<Span> = null;
		var maxRank: Int = -1;
		var flagged: Bool = false;
		for (child in node.children) {
			final rank: Int = order.indexOf(child.kind);
			if (rank >= 0) {
				final span: Null<Span> = child.span;
				if (runStart == null) runStart = span;
				if (rank < maxRank && !flagged && runStart != null && span != null) {
					out.push({
						file: file,
						span: new Span(runStart.from, span.to),
						rule: 'modifier-order',
						severity: Severity.Info,
						message: 'modifiers are not in canonical order (override -> public/private -> static -> inline)'
					});
					flagged = true;
				}
				if (rank > maxRank) maxRank = rank;
			} else if (members.contains(child.kind)) {
				runStart = null;
				maxRank = -1;
				flagged = false;
			}
		}
	}

	/**
	 * Walk `node`; for each container child's ranked-modifier run that ends at a
	 * member boundary, reorder it (`emitReorder`). The run is the ranked-modifier
	 * siblings (kind in `order`) leading up to a member host (`members`); an
	 * unranked modifier or `@:meta` neither joins the run nor resets it, exactly as
	 * `flagChildren` tracks it.
	 */
	private static function reorderWalk(
		edits: Array<{ span: Span, text: String }>, source: String, node: QueryNode, order: Array<String>, members: Array<String>,
		flagged: Array<Int>
	): Void {
		var run: Array<QueryNode> = [];
		for (child in node.children) {
			if (order.indexOf(child.kind) >= 0)
				run.push(child);
			else if (members.contains(child.kind)) {
				emitReorder(edits, source, run, order, flagged);
				run = [];
			}
		}
		for (c in node.children) reorderWalk(edits, source, c, order, members, flagged);
	}

	/**
	 * Emit the reorder edits for one ranked-modifier `run` whose start offset is in
	 * `flagged`: collect each node's `(rank, keyword text)`, sort the texts by rank,
	 * and replace each slot (in source order) with the text now ranked for it. Bails
	 * on a run already in order, shorter than two, unmatched, or missing a span.
	 */
	private static function emitReorder(
		edits: Array<{ span: Span, text: String }>, source: String, run: Array<QueryNode>, order: Array<String>, flagged: Array<Int>
	): Void {
		if (run.length < 2) return;
		final first: Null<Span> = run[0].span;
		if (first == null || !flagged.contains(first.from)) return;
		final slots: Array<Span> = [];
		final ranked: Array<{ rank: Int, text: String }> = [];
		for (n in run) {
			final span: Null<Span> = n.span;
			if (span == null) return;
			slots.push(span);
			ranked.push({ rank: order.indexOf(n.kind), text: source.substring(span.from, span.to) });
		}
		ranked.sort((a, b) -> a.rank - b.rank);
		for (i in 0...slots.length) edits.push({ span: slots[i], text: ranked[i].text });
	}

}
