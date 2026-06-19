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
 * carries no meaning to the compiler — so `Info`, report-only.
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
		final order: Array<String> = shape.modifierOrderKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		if (order.length == 0 || members.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, order, members);
		}
		return violations;
	}

	/** Modifier-order has no autofix — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
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

}
