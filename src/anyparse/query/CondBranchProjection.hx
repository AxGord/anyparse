package anyparse.query;

import anyparse.query.CondDirectives.CondDirective;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.SameItems;
import anyparse.runtime.Span;

using Lambda;

/**
 * The conditional-compilation branch projection: the pure `(tree, source, seams) -> tree` rewrite
 * that regroups every statement-position `#if` region into one synthetic `CondBranch` statement
 * list per branch. Lives in the query layer next to the seams it reads (`RefShape`,
 * `ControlFlowSupport`) and the nodes it builds (`QueryNode`), so a grammar plugin can call it
 * without depending on the check layer; `CheckScan.parseBranchAwareOrNull` is the check-layer
 * entry point that consumes it. Pure static helpers, no state — an untouched subtree is SHARED
 * with the input rather than copied.
 */
@:nullSafety(Strict)
final class CondBranchProjection {

	/**
	 * The synthetic node kind `branchAwareTree` wraps one conditional-compilation branch's
	 * statement run in. A grammar opts into the projection by naming it in its
	 * `ControlFlowSupport.blockKinds()`; it must NOT join `emptyFlagKinds()` (an empty branch is
	 * not an empty block) nor `RefShape.scopeKinds` (a `#if` branch is not a scope: a declaration
	 * written inside `#if` is still visible after `#end`, and a scope kind would hide it from the
	 * enclosing frame's pre-collect).
	 *
	 * `Refs.walkMulti` nonetheless treats the kind as a resolution PREFERENCE — a reference
	 * inside a branch binds to that branch's own declaration before a same-name declaration of a
	 * mutually exclusive sibling branch — without making it a scope; see the comment there.
	 */
	public static inline final COND_BRANCH_KIND: String = 'CondBranch';

	/**
	 * The branch-aware rewrite of `tree`: every conditional-compilation region
	 * (`RefShape.conditionalMemberKind`) whose PARENT is a statement list
	 * (`ControlFlowSupport.blockKinds`) has its children regrouped into one synthetic
	 * `CondBranch` node per branch. Pure — the input tree is never mutated, and any subtree the
	 * rewrite does not touch is SHARED with it rather than copied.
	 *
	 * The parent gate is the whole safety mechanism: a member-position and a statement-position
	 * region share one kind, so kind alone cannot tell them apart. Requiring a block parent
	 * excludes, by construction, a member region (`ClassDecl > Conditional`, whose members
	 * `member-order` / `oversized-type` / `listener-symmetry` reach by descending one level), a
	 * region used as an un-braced `if` body (`IfStmt > Conditional`, whose statements are
	 * siblings of the `if`, not of each other) and a region in a switch body
	 * (`SwitchStmtBare > Conditional`, whose children are case branches). The expression-position
	 * `ConditionalExpr` and the `CondSplice*` straddling forms carry no recoverable statement run
	 * and never match the kind.
	 *
	 * A no-op unless the grammar exposes the conditional seams AND its `blockKinds()` already
	 * names `CondBranch`: wrapping a run in a node the grammar does not treat as a statement list
	 * would HIDE those statements from every check that walks one.
	 */
	public static function branchAwareTree(
		tree: QueryNode, source: String, shape: RefShape, support: Null<ControlFlowSupport>, regions: () -> Array<LexRegion>
	): QueryNode {
		final condKind: Null<String> = shape.conditionalMemberKind;
		final elseKeywords: Null<Array<String>> = shape.conditionalElseKeywords;
		if (condKind == null || elseKeywords == null || support == null) return tree;
		// No `#if` anywhere means no region to regroup, and the walk below allocates per node —
		// so the overwhelmingly common file skips it on one string scan. A false positive (the
		// keyword inside a string literal) only costs a walk that finds nothing.
		if (source.indexOf(shape.conditionalIfKeyword ?? '#if') == -1) return tree;
		final blockKinds: Array<String> = support.blockKinds();
		if (!blockKinds.contains(COND_BRANCH_KIND)) return tree;
		// Re-bound to non-null locals: strict null-safety narrowing does not reach into an
		// anonymous struct literal.
		final kind: String = condKind;
		final keywords: Array<String> = elseKeywords;
		return projectBranches(tree, {
			condKind: kind,
			elseKeywords: keywords,
			blockKinds: blockKinds,
			directives: CondDirectives.scan(source, shape, regions)
		});
	}

	/**
	 * The per-branch runs of a conditional region's children, in source order, or null when the
	 * region's shape cannot be modelled by gap arithmetic and must stay flat.
	 *
	 * Only the gaps BETWEEN children are scanned — each `[children[i].to, children[i + 1].from)` —
	 * never a child's interior, and never the head gap before the first child or the trailing gap
	 * after the last. That is the whole model: a branch can only OPEN between two statements, so a
	 * directive in the head or trailing gap can at most open a branch with no statements, which
	 * yields no run either way. It is also what makes a NESTED region free — it projects as ONE child
	 * whose span covers its whole `#if … #end`, so its inner directives are never seen and no depth
	 * counting is needed. A gap may hold several directives (`#elseif A` immediately followed by
	 * `#elseif B`); it still opens exactly one run, the statement-less branches between them
	 * contributing none.
	 *
	 * A gap's directives are read from `directives` — the file's `CondDirectives.scan` — so a
	 * `#else` inside a comment or a string literal cannot split a run, and one sharing its line with
	 * code (`#if A x(); #else y(); #end`) still does.
	 *
	 * Null when the region or any child carries no span, when a child span is empty, or when the
	 * child spans are not strictly increasing and non-overlapping inside the region — every shape
	 * the gaps cannot describe keeps its current projection rather than a guessed split.
	 */
	public static function conditionalBranchRuns(
		region: QueryNode, elseKeywords: Array<String>, directives: Array<CondDirective>
	): Null<Array<CondBranchRun>> {
		final span: Null<Span> = region.span;
		if (span == null) return null;
		final kids: Array<QueryNode> = region.children;
		final bounds: Null<Array<Span>> = monotonicChildSpans(kids, span);
		if (bounds == null) return null;
		final runs: Array<CondBranchRun> = [];
		var start: Int = 0;
		// Only the gaps BETWEEN children: a branch can open nowhere else. `start` therefore always
		// trails `i`, so no pushed run can come out empty.
		for (i in 1...kids.length) if (opensBranch(directives, bounds[i - 1].to, bounds[i].from, elseKeywords)) {
			runs.push({ nodes: kids.slice(start, i), span: new Span(bounds[start].from, bounds[i - 1].to) });
			start = i;
		}
		if (kids.length > start)
			runs.push({ nodes: kids.slice(start, kids.length), span: new Span(bounds[start].from, bounds[kids.length - 1].to) });
		return runs;
	}

	/**
	 * The branch-aware copy of `node`: children are projected first (so a region nested inside
	 * another region's branch is already rewritten by the time that branch is built), then — when
	 * `node` is itself a statement list — every direct conditional-region child is regrouped.
	 * Returns `node` unchanged when nothing under it moved, so an untouched subtree is shared.
	 */
	private static function projectBranches(node: QueryNode, seams: BranchSeams): QueryNode {
		final kids: Array<QueryNode> = node.children;
		if (kids.length == 0) return node;
		final projected: Array<QueryNode> = kids.map(projectBranches.bind(_, seams));
		final rebuilt: Array<QueryNode> = seams.blockKinds.contains(node.kind) ? splitBlockChildren(projected, seams) : projected;
		return SameItems.of(kids, rebuilt)
			? node
			: new QueryNode(node.kind, node.name, rebuilt, node.span, node.type, node.typeArgCount, node.target);
	}

	/**
	 * `kids` (already projected) with every conditional-region child replaced by its
	 * branch-grouped rewrite — the statement-list half of `projectBranches`, reused for a
	 * `CondBranch`'s own children so a region nested in a branch splits too. Returns `kids`
	 * itself when no child was a splittable region.
	 */
	private static function splitBlockChildren(kids: Array<QueryNode>, seams: BranchSeams): Array<QueryNode> {
		var changed: Bool = false;
		final out: Array<QueryNode> = [];
		for (k in kids) {
			final split: Null<QueryNode> = k.kind == seams.condKind ? splitRegion(k, seams) : null;
			if (split != null) changed = true;
			out.push(split ?? k);
		}
		return changed ? out : kids;
	}

	/**
	 * `region` with its children regrouped into one `CondBranch` per recovered branch, or null
	 * when the splitter refused the shape or the region holds no statement at all (an empty
	 * `#if A #else #end`) — both leave the region exactly as it was.
	 */
	private static function splitRegion(region: QueryNode, seams: BranchSeams): Null<QueryNode> {
		final runs: Null<Array<CondBranchRun>> = conditionalBranchRuns(region, seams.elseKeywords, seams.directives);
		if (runs == null || runs.length == 0) return null;
		final branches: Array<QueryNode> = runs.map(run ->
			new QueryNode(COND_BRANCH_KIND, null, splitBlockChildren(run.nodes, seams), run.span)
		);
		return new QueryNode(region.kind, region.name, branches, region.span);
	}

	/**
	 * The spans of `kids` when every one is present, non-empty, inside `region` and starts no
	 * earlier than its predecessor ends — the precondition `conditionalBranchRuns` needs to read
	 * the gaps BETWEEN children. Null when any of those fails.
	 */
	private static function monotonicChildSpans(kids: Array<QueryNode>, region: Span): Null<Array<Span>> {
		final out: Array<Span> = [];
		var prevTo: Int = region.from;
		for (k in kids) {
			final s: Null<Span> = k.span;
			if (s == null || s.from < prevTo || s.to <= s.from || s.to > region.to) return null;
			out.push(s);
			prevTo = s.to;
		}
		return out;
	}

	/**
	 * Whether a branch directive (`elseKeywords`, e.g. `#else` / `#elseif`) starts inside `[from, to)`
	 * — one gap between two consecutive children of a conditional region. The keyword is compared
	 * whole, as the directive reader recovered it, never as a text prefix.
	 */
	private static function opensBranch(directives: Array<CondDirective>, from: Int, to: Int, elseKeywords: Array<String>): Bool {
		return CondDirectives.startingIn(directives, from, to).exists(directive -> elseKeywords.contains(directive.keyword));
	}

}

/**
 * One branch of a conditional-compilation region recovered by
 * `CondBranchProjection.conditionalBranchRuns`: the consecutive child nodes that make it up, and
 * the exact span they occupy — from the first node's start to the last node's end, so it never
 * covers ITS OWN region's `#if` / `#elseif` / `#else` / `#end` directives.
 *
 * Only its own: a run whose statements include a NESTED region, or a `CondSplice*` node, has a
 * span that covers that construct's directives in full. The invariant is about where this
 * region's branch boundaries fall, not about the absence of `#` in the text.
 */
typedef CondBranchRun = { final nodes: Array<QueryNode>; final span: Span; };

/** The conditional / block seam kinds plus the file's directives `CondBranchProjection.branchAwareTree` threads through its walk. */
private typedef BranchSeams = {
	final condKind: String;
	final elseKeywords: Array<String>;
	final blockKinds: Array<String>;
	final directives: Array<CondDirective>;
};
