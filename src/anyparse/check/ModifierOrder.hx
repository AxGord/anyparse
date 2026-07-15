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
 * `override → public / private → static → inline → final`. Purely cosmetic — the
 * order carries no meaning to the compiler — so `Info`; `--fix` reorders the run
 * into canonical order.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.modifierOrderKinds` is the canonical order: a modifier's rank is its
 * index there. The check collects each member's run of ranked modifier siblings
 * (resetting at a `RefShape.memberDeclKinds` boundary) and flags a run whose ranks
 * are not non-decreasing. A method's `final` is folded into the
 * `RefShape.finalModifierMemberKind` wrapper rather than a sibling node, so the run
 * injects it (ranked by `RefShape.finalModifierRankKind`) with the modifiers nested
 * after it — enforcing `final` last. Modifiers absent from the list (extern,
 * dynamic, macro, …) carry no documented order and are ignored. Either field unset
 * → no-op.
 */
@:nullSafety(Strict)
final class ModifierOrder implements Check {

	/** The `final` keyword the grammar folds into a `finalModifierMemberKind` wrapper — a fixed 5-char token at the wrapper's start. */
	private static inline final FINAL_KEYWORD: String = 'final';

	public function new() {}

	public function id(): String {
		return 'modifier-order';
	}

	public function description(): String {
		return 'member modifiers not in canonical order (override -> public/private -> static -> inline -> final)';
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
			if (tree != null) walk(violations, entry.file, tree, ranking(shape, order, members));
		}
		return violations;
	}

	/**
	 * Reorder each flagged member's ranked-modifier run into canonical order. The
	 * run's ranked elements — the modifier siblings (kind in `modifierOrderKinds`)
	 * plus, for a `final` method, its `final` keyword and the modifiers nested after
	 * it — are sorted by rank and written back into their own source slots, each slot
	 * taking the keyword whose rank now belongs there. Unranked modifiers (extern,
	 * dynamic, …) and `@:meta` keep their physical positions; only ranked keywords
	 * move. Re-parses `source`, and emits edits only for a run whose start offset
	 * matches a passed violation (so a config-filtered finding is not silently fixed).
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
		reorderWalk(edits, source, tree, ranking(shape, order, members), flagged);
		return edits;
	}

	/** Bundle the grammar's modifier-order config, resolving the `final`-keyword rank against the active `order`. */
	private static function ranking(shape: RefShape, order: Array<String>, members: Array<String>): Ranking {
		final rankKind: Null<String> = shape.finalModifierRankKind;
		return {
			order: order,
			members: members,
			finalMemberKind: shape.finalModifierMemberKind,
			finalRank: rankKind != null ? order.indexOf(rankKind) : -1
		};
	}

	/** Walk `node`, flagging each of its direct children's ranked-modifier runs that break canonical order. */
	private static function walk(out: Array<Violation>, file: String, node: QueryNode, r: Ranking): Void {
		for (run in collectRuns(node, r)) flagRun(out, file, run);
		for (c in node.children) walk(out, file, c, r);
	}

	/**
	 * Flag `run` when its ranks (in source order) are not non-decreasing — one
	 * violation spanning the run start to the first out-of-order modifier.
	 */
	private static function flagRun(out: Array<Violation>, file: String, run: Array<{ rank: Int, span: Span }>): Void {
		var maxRank: Int = -1;
		for (el in run) {
			if (el.rank < maxRank) {
				out.push({
					file: file,
					span: new Span(run[0].span.from, el.span.to),
					rule: 'modifier-order',
					severity: Severity.Info,
					message: 'modifiers are not in canonical order (override -> public/private -> static -> inline -> final)'
				});
				return;
			}
			if (el.rank > maxRank) maxRank = el.rank;
		}
	}

	/**
	 * Collect the ranked-modifier runs among `node`'s direct children. A run is the
	 * ranked-modifier siblings (kind in `r.order`) leading up to a member host (kind
	 * in `r.members`), in source order; a `finalModifierMemberKind` host also gains
	 * that method's `final` keyword and the modifiers nested after it (see
	 * `appendFinalModifier`). An unranked modifier or `@:meta` neither joins nor
	 * closes a run. Only runs a member host closes are returned.
	 */
	private static function collectRuns(node: QueryNode, r: Ranking): Array<Array<{ rank: Int, span: Span }>> {
		final runs: Array<Array<{ rank: Int, span: Span }>> = [];
		var run: Array<{ rank: Int, span: Span }> = [];
		for (child in node.children) {
			final rank: Int = r.order.indexOf(child.kind);
			if (rank >= 0) {
				final span: Null<Span> = child.span;
				if (span != null) run.push({ rank: rank, span: span });
			} else if (r.members.contains(child.kind)) {
				appendFinalModifier(run, child, r);
				if (run.length > 0) runs.push(run);
				run = [];
			}
		}
		return runs;
	}

	/**
	 * When `member` is the `final`-modified method wrapper, extend the open `run`
	 * with its leading `final` keyword (ranked `r.finalRank`, spanning the 5-char
	 * `final` token at the wrapper's start) and one element per ranked modifier
	 * nested after it — so `final`'s position relative to the other modifiers is
	 * ranked. A non-`final` member, or a grammar that ranks no `final`, is a no-op.
	 */
	private static function appendFinalModifier(run: Array<{ rank: Int, span: Span }>, member: QueryNode, r: Ranking): Void {
		if (r.finalMemberKind == null || member.kind != r.finalMemberKind || r.finalRank < 0) return;
		final span: Null<Span> = member.span;
		if (span == null) return;
		run.push({ rank: r.finalRank, span: new Span(span.from, span.from + FINAL_KEYWORD.length) });
		for (child in member.children) {
			final rank: Int = r.order.indexOf(child.kind);
			final childSpan: Null<Span> = child.span;
			if (rank >= 0 && childSpan != null) run.push({ rank: rank, span: childSpan });
		}
	}

	/** Walk `node`, reordering each flagged ranked-modifier run its direct children form. */
	private static function reorderWalk(
		edits: Array<{ span: Span, text: String }>, source: String, node: QueryNode, r: Ranking, flagged: Array<Int>
	): Void {
		for (run in collectRuns(node, r)) emitReorder(edits, source, run, flagged);
		for (c in node.children) reorderWalk(edits, source, c, r, flagged);
	}

	/**
	 * Emit the reorder edits for one flagged `run`: read each slot's source text,
	 * sort the texts by rank, and write each back into the source-order slot now
	 * ranked for it. Bails on a run shorter than two or whose start offset is not a
	 * flagged violation (so a config-filtered finding is not silently fixed).
	 */
	private static function emitReorder(
		edits: Array<{ span: Span, text: String }>, source: String, run: Array<{ rank: Int, span: Span }>, flagged: Array<Int>
	): Void {
		if (run.length < 2 || !flagged.contains(run[0].span.from)) return;
		final ranked: Array<{ rank: Int, text: String }> = [
			for (el in run) { rank: el.rank, text: source.substring(el.span.from, el.span.to) }
		];
		ranked.sort((a, b) -> a.rank - b.rank);
		for (i in 0...run.length) edits.push({ span: run[i].span, text: ranked[i].text });
	}

}

/**
 * The modifier-ranking config the `modifier-order` walk reads from a grammar's
 * `RefShape`: the canonical `order`, the member-host `members` a run attaches to,
 * the `final`-modified method wrapper kind (or null), and the rank a method's
 * `final` keyword occupies in `order` (`-1` when the grammar ranks no `final`).
 */
private typedef Ranking = {
	var order: Array<String>;
	var members: Array<String>;
	var finalMemberKind: Null<String>;
	var finalRank: Int;
}
