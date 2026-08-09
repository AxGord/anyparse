package anyparse.query;

import anyparse.query.CondBranchProjection;
import anyparse.query.GrammarPlugin.RefShape;

using Lambda;

import anyparse.runtime.Span;

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
		visit: (member:QueryNode, run:Array<QueryNode>, runIsCertain:Bool) -> Void
	): Void {
		fold(seams, container.children, freshRun(), (run, child) -> {
			if (!isMember(child)) return { nodes: run.nodes.concat([child]), certain: run.certain };
			visit(child, run.nodes, run.certain);
			return freshRun();
		}, joinRuns);
	}

	/**
	 * The span of the conditional BRANCH that declares `member`, or null when no region under
	 * `container` holds it — either because it is a direct child (so it compiles in every build) or
	 * because it is not under `container` at all. A caller that reads null as "unguarded, safe" must
	 * therefore pass a `member` it knows belongs to `container`.
	 *
	 * The unit a multi-member rewrite has to stay inside. Two members of the same region but of
	 * DIFFERENT branches never compile together, so an edit reaching from one to the other is as wrong
	 * as one reaching out of the region entirely — a collapse that renames a backing field declared in
	 * `#if cpp` cannot rewrite a reader written in `#else`. A region whose boundaries the splitter
	 * refuses answers with the whole region's span, the tightest bound still available.
	 */
	public static function branchSpanOf(seams: MemberBranchSeams, container: QueryNode, member: QueryNode): Null<Span> {
		for (child in container.children) if (isRegion(seams, child)) {
			final hit: Null<Span> = branchSpanIn(seams, child, member);
			if (hit != null) return hit;
		}
		return null;
	}

	/**
	 * The subset of `deleting` a fix may actually remove: every member whose deletion would leave a
	 * conditional REGION with no member declaration at all is dropped, together with the rest of that
	 * region's members.
	 *
	 * The grammar models an empty BRANCH (`#if cpp #else var b; #end` parses) but not a region emptied
	 * of members, so such a splice is rejected by the re-parse gate — and with it EVERY other edit the
	 * same `--fix` pass had for that file. Withholding these edits keeps the findings and lets the rest
	 * of the file's fixes land.
	 *
	 * The question is per EDIT SET, not per member: two orphan members that are together all of a
	 * region's members each look non-sole on their own. A member of a NESTED region counts toward its
	 * outer region too, so emptying the inner one empties the outer with it.
	 */
	public static function survivingDeletions(
		seams: MemberBranchSeams, container: QueryNode, deleting: Array<QueryNode>, isMember: QueryNode -> Bool
	): Array<QueryNode> {
		final refused: Array<QueryNode> = [];
		eachRegion(seams, container, region -> {
			final members: Array<QueryNode> = [];
			RefactorSupport.eachMemberHost(region, host -> for (c in host.children) if (isMember(c)) members.push(c));
			if (members.length == 0 || members.exists(m -> !deleting.contains(m))) return;
			for (m in members) if (!refused.contains(m))
				refused.push(m);
		});
		return deleting.filter(m -> !refused.contains(m));
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
		if (runs == null || runs.length == 0) return join(fold(seams, region.children, incoming, step, join), incoming);
		var out: S = fold(seams, runs[0].nodes, incoming, step, join);
		for (i in 1...runs.length) out = join(out, fold(seams, runs[i].nodes, incoming, step, join));
		// The IMPLICIT branch: a `#if A … #end` contributes nothing when A is false, so `incoming`
		// reaches the member after `#end` untouched — a run no written branch represents. Joining it
		// unconditionally over-approximates a region closed by a plain `#else` (where some branch
		// always compiles), which is the fail-closed direction for every caller: it can only widen
		// what the next member's run might hold, never narrow it.
		return join(out, incoming);
	}

	/**
	 * Whether `node` is a member-position conditional-compilation region under `seams` — the test
	 * `fold` itself applies.
	 */
	private static inline function isRegion(seams: MemberBranchSeams, node: QueryNode): Bool {
		return seams.condKind != null && node.kind == seams.condKind;
	}

	/**
	 * The branch span of `member` inside `region`, or null when the region does not hold it. A region
	 * nested in a branch answers with its OWN branch span — tighter, and still inside the outer one.
	 */
	private static function branchSpanIn(seams: MemberBranchSeams, region: QueryNode, member: QueryNode): Null<Span> {
		final runs: Null<Array<CondBranchRun>> = CondBranchProjection.conditionalBranchRuns(
			region, seams.source, seams.elseKeywords, seams.comments
		);
		if (runs == null || runs.length == 0)
			return region.children.contains(member) ? region.span : nestedSpan(seams, region.children, member);
		for (run in runs) {
			if (run.nodes.contains(member)) return run.span;
			final nested: Null<Span> = nestedSpan(seams, run.nodes, member);
			if (nested != null) return nested;
		}
		return null;
	}

	/** The branch span of `member` inside any region among `nodes` — the nested-region arm of `branchSpanIn`. */
	private static function nestedSpan(seams: MemberBranchSeams, nodes: Array<QueryNode>, member: QueryNode): Null<Span> {
		for (node in nodes) if (isRegion(seams, node)) {
			final hit: Null<Span> = branchSpanIn(seams, node, member);
			if (hit != null) return hit;
		}
		return null;
	}

	/** A member run that has seen nothing yet — every modifier it goes on to collect is certain. */
	private static inline function freshRun(): MemberRun {
		return { nodes: [], certain: true };
	}

	/**
	 * Merge two branches' leftover modifier runs. The node set is the UNION — a gate that any build's
	 * modifiers would trip has to trip — but the merge also records that the branches DISAGREED, and
	 * that flag is what a caller whose gate is ENABLING must read.
	 *
	 * The union alone is fail-closed only for a SUPPRESSING gate (`@:keep`, `override`, `inline`:
	 * seeing a modifier one build does not have costs a finding). For an enabling one it is
	 * fail-OPEN: `#if cpp static #end function get_x()` would make the accessor read as static in
	 * every build and stop pairing with its instance property — a finding whose fix deletes a live
	 * accessor. Disagreement therefore makes the run UNCERTAIN, and `eachMember`'s callers refuse the
	 * member rather than judge it on modifiers only some builds have.
	 */
	private static function joinRuns(a: MemberRun, b: MemberRun): MemberRun {
		return {
			nodes: a.nodes.concat([for (n in b.nodes) if (!a.nodes.contains(n)) n]),
			certain: a.certain && b.certain && a.nodes.length == b.nodes.length && !a.nodes.exists(n -> !b.nodes.contains(n))
		};
	}

	/** Visit every conditional region under `container`, nested ones included, outermost first. */
	private static function eachRegion(seams: MemberBranchSeams, container: QueryNode, visit: QueryNode -> Void): Void {
		for (child in container.children) {
			if (isRegion(seams, child)) visit(child);
			if (!RefactorSupport.isMemberDeclKind(child.kind)) eachRegion(seams, child, visit);
		}
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

/**
 * One member run as `MemberBranchScan.eachMember` folds it: the modifier / annotation siblings
 * collected since the last member, and whether EVERY build that reaches the next member sees
 * exactly those. `certain` goes false only where conditional branches leave different runs
 * behind — the shape an enabling gate cannot judge.
 */
private typedef MemberRun = {
	final nodes: Array<QueryNode>;
	final certain: Bool;
};
