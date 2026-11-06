package anyparse.check.common.control;

import anyparse.check.Check.FixEdit;
import anyparse.check.scan.HeadScan;
import anyparse.check.scan.TailScan;
import anyparse.query.IndexScope;
import anyparse.query.SymbolIndex;

/**
 * Flags a statement-position `if` / `else if` / … / `else` chain whose EVERY branch opens with the same statements, and
 * moves them before the chain:
 *
 * ```haxe
 * if (ready) { log(id); start(); } else { log(id); stop(); }
 * // -> log(id); if (ready) start(); else stop();
 * ```
 *
 * `hoist-common-branch-tail` is the sibling question about the END of the branches; each rule moves its own part, so a chain
 * sharing both ends reaches a fixed point in one fix run of both. A chain whose branches are nothing but the shared run is
 * left to the tail rule, which reports it whole.
 *
 * ## Gates
 *
 *  - FINAL ELSE — an `if` without one never matches, and every `else if` arm counts as a branch.
 *  - PREFIX — the longest run of statements token-identical in ALL branches (`HeadScan.commonPrefix`), shortened from its end
 *    until `HeadScan.mayPrecede` admits it: the run jumps over every condition of the chain, so it may not exit, change
 *    a local a condition reads (`UnchangedLocal`), or declare a name a condition or the code after the chain reads; a condition
 *    reading anything but such locals admits only a run with no uncleared call (`PurityScan`) and no write `WriteSites` could
 *    match; a condition `PurityScan` does not clear (a call, an assignment, a property getter) admits only constant local
 *    declarations.
 *  - NO CONDITIONAL COMPILATION anywhere in the `if`.
 *
 * ## Report-only
 *
 * An edit is refused when a branch other than the final `else` would be left empty (it would need an inverted condition),
 * or when a comment sits in a removed region.
 */
@:nullSafety(Strict)
final class HoistCommonBranchHead extends RuleBase {

	private static inline final RULE_ID: String = 'hoist-common-branch-head';

	public function new() {
		super(
			RULE_ID, 'every branch of an if chain opens with the same statements — they can run once before the if', RuleCategory.Control
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, TailScan.resolveSeams(plugin), (entry, tree, seams, violations) -> {
			for (c in scan(tree, entry.source, seams, HeadScan.lazyContext(plugin, entry.source, tree, symbols))) violations.push({
				file: entry.file,
				span: c.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: message(c)
			});
		});
	}

	/**
	 * Move each flagged — and comment-clean — common head. Re-runs the SAME walk as `run` and keeps the candidates whose
	 * reported span is among `violations`. A chain nested inside another chain that is being rewritten waits for the next
	 * pass: the outer rewrite deletes or copies the very text the inner edits address.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {

		if (violations.length == 0) return [];
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex([{ file: violations[0].file, source: source }], plugin, index);
		return RunScan.editsWith(plugin, source, TailScan.resolveSeams(plugin), (tree, seams) -> {
			return TailScan.flaggedEdits(scan(tree, source, seams, HeadScan.lazyContext(plugin, source, tree, symbols)), violations);
		});
	}

	/** The reported wording. */
	private static inline function message(c: Candidate): String {
		return c.count == 1
			? 'every branch of this if opens with the same statement — move it before the if'
			: 'every branch of this if opens with the same ${c.count} statements — move them before the if';
	}

	/** Every common-head candidate in `tree`, in document order — the one walk `run` and `fix` share. */
	private static function scan(tree: QueryNode, source: String, seams: TailSeams, context: () -> Null<HeadCtx>): Array<Candidate> {
		return TailScan.candidatesIn(tree, seams, site -> tryChain(site, source, seams, context));
	}

	/** The candidate for the chain at `site`, or null when any gate refuses (see the class doc). */
	private static function tryChain(site: ChainSite, source: String, seams: TailSeams, context: () -> Null<HeadCtx>): Null<Candidate> {
		final chain: QueryNode = site.head;
		final branches: Null<Array<QueryNode>> = BranchChain.branchesOf(chain, seams.ifKinds);
		if (branches == null) return null;
		final chainSpan: Null<Span> = chain.span;
		if (chainSpan == null) return null;
		if (TailScan.hasConditionalCompilation(source, chainSpan.from, chainSpan.to)) return null;
		final lists: Array<Array<QueryNode>> = [for (b in branches) TailScan.statementsOf(b, seams)];
		final conds: Array<QueryNode> = [for (link in BranchChain.linksFrom(chain, seams.ifKinds)) link.children[0]];
		final count: Int = HeadScan.admissibleLength(lists, conds, site.following, source, seams, context);
		if (count < 1 || lists.foreach(l -> l.length == count)) return null;
		final firsts: Array<Span> = [];
		final lasts: Array<Span> = [];
		for (l in lists) {
			final first: Null<Span> = l[0].span;
			final last: Null<Span> = l[count - 1].span;
			if (first == null || last == null) return null;
			firsts.push(first);
			lasts.push(last);
		}
		return {
			chain: chain,
			span: new Span(firsts[0].from, lasts[0].to),
			count: count,
			edits: fixEdits(branches, lists, firsts, lasts, count, chainSpan, source)
		};
	}

	/**
	 * The edits that move the head, or none when the layout or a comment forbids it: each branch loses its head with the
	 * trivia after it, one copy is written before the chain, and a final `else` left with nothing is dropped. Only the final
	 * `else` may end up empty.
	 */
	private static function fixEdits(
		branches: Array<QueryNode>, lists: Array<Array<QueryNode>>, firsts: Array<Span>, lasts: Array<Span>, count: Int, chainSpan: Span,
		source: String
	): Array<FixEdit> {

		final ends: Null<ElseEnds> = TailScan.elseEnds(branches);
		if (ends == null) return [];
		final edits: Array<FixEdit> = [];
		for (i in 0...branches.length) {
			if (lists[i].length == count) {
				if (i != ends.last || CheckScan.hasCommentMarker(source, ends.beforeElse.to, ends.chainEnd.to)) return [];
				edits.push({ span: new Span(ends.beforeElse.to, ends.chainEnd.to), text: '' });
				continue;
			}
			final next: Null<Span> = lists[i][count].span;
			if (next == null || CheckScan.hasCommentMarker(source, firsts[i].from, next.from)) return [];
			edits.push({ span: new Span(firsts[i].from, next.from), text: '' });
		}
		edits.push({ span: new Span(chainSpan.from, chainSpan.from), text: '${source.substring(firsts[0].from, lasts[0].to)}\n' });
		return edits;
	}

}

/**
 * One common head: `span` is what the finding reports (the FIRST branch's head), `count` how many statements it holds,
 * and `edits` the rewrite (empty when the finding is report-only).
 */
private typedef Candidate = {
	final chain: QueryNode;
	final span: Span;
	final count: Int;
	final edits: Array<FixEdit>;
};
