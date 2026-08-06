package anyparse.query;

import anyparse.query.CondBranchProjection;
import anyparse.query.GrammarPlugin.RefShape;

/**
 * The branch-aware member-run fold: how a member-scanning check reads a container's children
 * when one of them is a member-position conditional-compilation region.
 *
 * A `#if … #else … #end` written in MEMBER position is ONE node
 * (`RefShape.conditionalMemberKind`) holding every branch's members flattened as siblings, so a
 * container's direct children do not include them — a scan of those children alone silently
 * exempts every guarded member. `fold` descends into the region and recovers the branch
 * boundaries from the directive text between child spans
 * (`CondBranchProjection.conditionalBranchRuns`, the same recovery `member-order` and
 * `missing-visibility` use), folding each branch as its own modifier run.
 *
 * The projection's own entry point (`CondBranchProjection.branchAwareTree`) gates deliberately on
 * a STATEMENT-list parent and so never rewrites a member region; calling the run recovery
 * directly is the sanctioned route for member position.
 *
 * ## Every branch's members are present SIMULTANEOUSLY
 *
 * Per-branch is a statement about the MODIFIER RUN only — which keyword modifies which
 * declaration. It is never a statement about which members exist: a check whose verdict depends
 * on other members (a write scan, a reference scan, an accessor pairing) must read every branch
 * at once, because the fix it emits lands in source that all builds compile. Those proofs run off
 * whole-file text scans and the `SymbolIndex`, both of which are branch-blind already; `join` is
 * the one place this fold could lose it, so a caller's `join` must be the FAIL-CLOSED merge of its
 * own state — a carry any branch produces has to survive it.
 */
@:nullSafety(Strict)
final class MemberBranchScan {

	private function new() {}

	/**
	 * The seams `fold` reads over one file — resolved once per file rather than per container.
	 * Comment tokens (needed only to mask a `#else` written inside a comment out of the
	 * branch-boundary scan) are collected only when the grammar HAS a conditional member kind AND
	 * the source holds the `#if` keyword at all, so the overwhelmingly common file pays one string
	 * scan. A grammar without the seam yields a `condKind` of null, which makes `fold` a plain
	 * left fold over the children — exactly the unaware scan.
	 */
	public static function seamsOf(shape: RefShape, source: String): MemberBranchSeams {
		final condKind: Null<String> = shape.conditionalMemberKind;
		final present: Bool = condKind != null && source.indexOf(shape.conditionalIfKeyword ?? '#if') >= 0;
		return {
			source: source,
			condKind: present ? condKind : null,
			elseKeywords: shape.conditionalElseKeywords ?? [],
			comments: present ? RefactorSupport.collectCommentTokens(source) : []
		};
	}

	/**
	 * Fold one member run — `kids`, the direct children of a member host — through `step` in
	 * source order, descending into every member-position conditional-compilation region among
	 * them branch by branch. Returns the modifier-run state the run leaves behind, so a caller
	 * can chain runs.
	 *
	 * Each branch is folded from the state that reached the `#if` — a modifier written before the
	 * region modifies whichever branch compiles — and the state leaving the region is `join` over
	 * every branch's outgoing state. A branch ENDING on a modifier carries it out: a region
	 * holding nothing but `public` is a modifier for the member after `#end`, not a region of
	 * members of its own.
	 *
	 * A region whose branch boundaries cannot be recovered — a shape the splitter refuses — folds
	 * its children as ONE flat run instead, `incoming` included. That loses only the two
	 * straddling shapes above; it still sees every member in the region, which the unaware scan
	 * did not.
	 */
	public static function fold<S>(
		seams: MemberBranchSeams, kids: Array<QueryNode>, incoming: S, step: (S, QueryNode) -> S, join: (S, S) -> S
	): S {
		final condKind: Null<String> = seams.condKind;
		var state: S = incoming;
		for (child in kids)
			state = condKind != null && child.kind == condKind ? foldRegion(seams, child, state, step, join) : step(state, child);
		return state;
	}

	/**
	 * Fold one conditional region branch by branch and merge the outgoing states with `join`.
	 * Every branch is scanned — not `exists`-style short-circuited — because each holds its own
	 * members and each must reach `step`.
	 */
	private static function foldRegion<S>(
		seams: MemberBranchSeams, region: QueryNode, incoming: S, step: (S, QueryNode) -> S, join: (S, S) -> S
	): S {
		final runs: Null<Array<CondBranchRun>> = CondBranchProjection.conditionalBranchRuns(
			region, seams.source, seams.elseKeywords, seams.comments
		);
		if (runs == null || runs.length == 0) return fold(seams, region.children, incoming, step, join);
		var out: S = fold(seams, runs[0].nodes, incoming, step, join);
		for (i in 1...runs.length) out = join(out, fold(seams, runs[i].nodes, incoming, step, join));
		return out;
	}

	/**
	 * Whether `region` is a member-position conditional-compilation region under `seams` — the
	 * test `fold` itself applies, exposed for a caller that recognises the kind outside a fold
	 * (a walk that recurses into containers itself).
	 */
	public static inline function isRegion(seams: MemberBranchSeams, node: QueryNode): Bool {
		return seams.condKind != null && node.kind == seams.condKind;
	}


	/**
	 * Visit every member declaration of `container` in source order — descending into every
	 * member-position conditional-compilation region branch by branch — with the modifier and
	 * annotation siblings that precede it in its OWN run. `isMember` names what counts as a
	 * declaration; everything else accumulates into the run and is handed to `visit` with the
	 * member it modifies.
	 *
	 * The ergonomic form of `fold` for the many checks whose state is exactly "the modifier siblings
	 * since the last member". Its join is concatenation — the run a member sees is the union of what
	 * every branch carried out, which is the fail-closed reading for a modifier: a gate that any
	 * build's modifiers would trip, trips.
	 */
	public static function eachMember(
		seams: MemberBranchSeams, container: QueryNode, isMember: QueryNode -> Bool,
		visit: (member:QueryNode, run:Array<QueryNode>) -> Void
	): Void {
		fold(seams, container.children, [], (run, child) -> {
			if (!isMember(child)) return run.concat([child]);
			visit(child, run);
			return [];
		}, (a, b) -> a.concat(b));
	}

}

/**
 * The per-file seams a `MemberBranchScan.fold` reads: the source the branch boundaries are
 * recovered from, the conditional region kind (null = no descent), the branch-opening directives
 * and the comment tokens that mask a directive written inside a comment.
 */
typedef MemberBranchSeams = {
	final source: String;

	/** The member-position conditional region kind; null makes `fold` a plain left fold. */
	final condKind: Null<String>;

	/** The branch-opening directives (`#else` / `#elseif`); empty makes a region one flat run. */
	final elseKeywords: Array<String>;

	final comments: Array<{ from: Int, to: Int, isLine: Bool }>;
};
