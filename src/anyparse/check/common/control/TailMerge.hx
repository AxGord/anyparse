package anyparse.check.common.control;

import anyparse.check.scan.TailScan;
import anyparse.query.CanonicalEdit;
import anyparse.query.SymbolIndex;

/**
 * Flags a branch of an `if` chain that ENDS with the very statements that follow the
 * chain — a duplicated tail. Control leaving the branch normally would run the shared
 * copy anyway, so the branch's own copy can be deleted and the branch left to fall
 * through onto it. Purely structural (no type information), so it holds without a
 * type-checker. `Info` — the code is correct, this is a de-duplication.
 *
 * ```haxe
 * if (cond1) {
 *     if (c2) {
 *         work();
 *         helper(v);   // ← duplicated tail
 *         return v;    // ←
 *     } else if (c3) {
 *         work2();
 *         helper(v);   // ← duplicated tail
 *         return v;    // ←
 *     }
 * }
 * helper(v);           // the shared fall-through run
 * return v;
 * ```
 *
 * ## The fall-through run
 *
 * The walk threads a `Fall` descriptor — the statements that execute once the construct
 * it is visiting completes. A block hands each of its statements the run that follows it
 * within the block, and its LAST statement the run it inherited from its own parent; an
 * `if` hands the same run to every branch, an `else if` chain included (all of them
 * complete into the same place). EVERY other node — a loop, a `switch`, a `try`, a
 * function declaration, an expression — resets the run to empty for its children, which
 * is what makes loop bodies, `switch` cases, `catch` bodies and lambdas fail CLOSED: a
 * `break`-less loop body does not complete into the code after the loop (it iterates),
 * and a `case` body's trailing statements are the ARM'S VALUE wherever the switch
 * stands in expression position, which this walk has no seam to tell from a statement
 * one. So those are silently out of scope by construction rather than by a special
 * case. A macro-reification subtree (`RefShape.opaqueKinds`) is not walked at all — its
 * statements may be spliced into a scope this walk never sees, so the run it appears to
 * complete into is not the run it will complete into.
 *
 * ## What this rule is not
 *
 * A duplicated tail on a SWITCH ARM is out of scope by that same reset, and that is the
 * contract rather than a gap. The ADJACENT-arm shape — two arms carrying the same body —
 * belongs to `redundant-case-body`; the run after the whole switch belongs to no rule,
 * because deleting an arm's copy of it is only sound while the switch stands in statement
 * position, and nothing here distinguishes the two. So a control built from two identical
 * arm bodies fires `redundant-case-body` and NOT this rule, and the silence is the
 * contract answering, not a miss — `testSwitchArmTailNotFlaggedWhileTheIfShapeIs` pins it
 * against the same fixture's `if` twin.
 *
 * ## Gates
 *
 * A branch's trailing run is flagged only when ALL hold:
 *
 *  - TERMINAL — the fall-through run ENDS in a `return` or a `throw`
 *    (`RefShape.valueReturnKinds` + `throwKinds` + `voidReturnKind`). `break` and
 *    `continue` are DELIBERATELY excluded (hence the explicit kind set rather than
 *    `controlExitKinds`): a loop-exit tail is not worth the extra reasoning, and leaving it
 *    out costs only a missed finding.
 *  - IDENTITY — the branch's trailing statements and the fall-through run are
 *    token-identical, by `sameStatement`: `MemberKinds.structurallyEqual` AND
 *    whitespace-normalized source equality. Neither alone suffices — shape equality
 *    cannot see a comment sitting INSIDE a statement's span, and normalized source alone
 *    collapses whitespace inside string literals, equating `f("a  b")` with `f("a b")`.
 *    Together they are exactly token identity, refusing whatever they cannot prove.
 *  - FULL COVERAGE — the matched suffix covers the ENTIRE fall-through run, not a
 *    trailing part of it. A branch ending in `r(); return v;` where the shared run is
 *    `q(); r(); return v;` must keep its copy: falling through would additionally run
 *    `q()`.
 *  - NON-EMPTY REMAINDER — at least one statement survives in the branch. A branch whose
 *    whole body IS the tail would be emptied; the useful edit there is deleting the
 *    branch (and possibly inverting the condition), which this rule does not do.
 *  - NO CONDITIONAL COMPILATION — neither the removed region nor the kept run contains
 *    `#if` / `#elseif` / `#else` / `#end`. A plain text scan, so a directive-looking
 *    string literal also refuses — conservative in the safe direction.
 *  - NO SHADOWING — no name bound between the fall-through run's scope and the branch
 *    (the branch's own locals and local functions, plus any block scope entered on the
 *    way) is referenced in the removed tail. `var t = c(); helper(t); return t;` inside a
 *    branch is token-identical to an outer `helper(t); return t;` yet means something else
 *    — the branch's `t`, not the outer one; a local `function helper()`, `inline` or not,
 *    hides an outer `helper` the same way, and a declaration behind metadata
 *    (`@:meta var t = …`) binds exactly as one written bare. A declaration whose bound
 *    names the projection cannot enumerate — a multi-declarator `var a = 1, t = 2;`, of
 *    which only `a` is named — would make this gate blind, so its presence anywhere on the
 *    way refuses outright (`hasOpaqueDecl`). The tail's OWN declarations are exempt: the
 *    shared copy declares the same names, so falling through re-binds them identically.
 *    This is a HARD gate: no finding at all, since the duplication is only apparent.
 *
 * ## Autofix
 *
 * `fix` deletes the branch's trailing run together with the trivia before it
 * (`[prevStatement.to, lastTail.to)`), leaving the branch to fall through. Two extra
 * COMMENT gates apply to the fix only — the finding is still reported, it just yields no
 * edit: every comment in the removed region must also appear before the kept run (an
 * explanatory comment duplicated alongside the code is fine to drop; a unique one would
 * be lost), and no comment may sit between the last removed statement and the branch's
 * closing brace (a trailing `// …` there would be stranded). Nested findings are passed
 * through `CanonicalEdit.dropContainedEdits` so no two deletions overlap.
 */
@:nullSafety(Strict)
final class TailMerge extends RuleBase {

	private static inline final RULE_ID: String = 'tail-merge';

	/**
	 * No fall-through at all — what every non-block, non-if node hands its children. Shared
	 * across every `run` / `fix` on every thread, so its arrays are READ-ONLY: a `Fall` is
	 * only ever widened by `concat` into a fresh array, never mutated in place.
	 */
	private static final EMPTY_FALL: Fall = {
		stmts: [],
		prevEnd: 0,
		shadow: [],
		opaqueDecl: false
	};

	public function new() {
		super(
			RULE_ID, 'a conditional branch ending with the same statements that follow the if — removable, control falls through to them',
			RuleCategory.Control
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, TailScan.resolveSeams(plugin), (entry, tree, seams, violations) -> {
			for (c in scan(tree, entry.source, seams)) violations.push({
				file: entry.file,
				span: c.tailSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: message(c.count)
			});
		});
	}

	/**
	 * Delete each flagged — and comment-clean — duplicated tail. Re-runs the SAME walk as
	 * `run` (checks parse independently in `run` and `fix`) and keeps the candidates whose
	 * reported span is among `violations`. `dropContainedEdits` keeps the batch
	 * non-overlapping when one flagged branch sits inside another's removed region.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {

		return RunScan.editsWith(plugin, source, TailScan.resolveSeams(plugin), (tree, seams) -> {
			final flagged: Array<String> = RunScan.spanKeys(violations);
			final edits: Array<{ span: Span, text: String }> = [
				for (c in scan(
					tree, source, seams
				)) if (c.fixable && flagged.contains('${c.tailSpan.from}:${c.tailSpan.to}')) { span: c.removeSpan, text: '' }
			];
			return CanonicalEdit.dropContainedEdits(edits);
		});
	}

	/** The reported wording; `count` is at least 1. */
	private static inline function message(count: Int): String {
		return count == 1
			? 'this statement repeats the tail that follows the if — drop it and fall through'
			: 'these $count statements repeat the tail that follows the if — drop them and fall through';
	}

	/** Every duplicated-tail candidate in `tree`, in document order — the one walk `run` and `fix` share. */
	private static function scan(tree: QueryNode, source: String, seams: Seams): Array<Candidate> {
		final out: Array<Candidate> = [];
		visit(tree, EMPTY_FALL, source, seams, out);
		return out;
	}

	/**
	 * Walk `node` carrying the run that executes after it completes. Blocks and `if`s
	 * propagate that run (`visitBlock` / `visitIf`); every other node resets it to
	 * `EMPTY_FALL` for its children — the structural reason loop bodies, `switch` cases,
	 * `try` / `catch` bodies and nested functions are out of scope. A macro-reification
	 * subtree (`RefShape.opaqueKinds`) is not descended into at all: its statements may be
	 * spliced into a scope this walk never sees, so the run it appears to complete into is
	 * not the run it will complete into.
	 */
	private static function visit(node: QueryNode, fall: Fall, source: String, seams: Seams, out: Array<Candidate>): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		if (seams.blockKinds.contains(node.kind))
			visitBlock(node, fall, source, seams, out);
		else if (seams.ifKinds.contains(node.kind))
			visitIf(node, fall, source, seams, out);
		else
			for (c in node.children) visit(c, EMPTY_FALL, source, seams, out);
	}

	/**
	 * Walk a statement list: each statement's fall-through is what follows it in this
	 * block, the last one's is the block's own inherited fall — widened by the names this
	 * block binds, which now stand between that fall's scope and anything nested deeper.
	 */
	private static function visitBlock(block: QueryNode, fall: Fall, source: String, seams: Seams, out: Array<Candidate>): Void {
		final kids: Array<QueryNode> = block.children;
		final inherited: Fall = {
			stmts: fall.stmts,
			prevEnd: fall.prevEnd,
			shadow: fall.shadow.concat(TailScan.localDeclNames(kids, seams)),
			opaqueDecl: fall.opaqueDecl || TailScan.hasOpaqueDecl(kids, seams)
		};
		for (i in 0...kids.length) visit(kids[i], restFall(kids, i, inherited), source, seams, out);
	}

	/**
	 * The fall-through for `kids[i]`: the block's remaining statements when any follow
	 * (nothing is bound between them and `kids[i]`, so neither shadowing nor an
	 * unenumerable declaration accrues), `inherited` for the last statement, and no fall at
	 * all when the preceding statement carries no span — a deletion has nothing to anchor
	 * to there.
	 */
	private static function restFall(kids: Array<QueryNode>, i: Int, inherited: Fall): Fall {
		if (i + 1 >= kids.length) return inherited;
		final prev: Null<Span> = kids[i].span;
		return prev == null ? EMPTY_FALL : {
			stmts: kids.slice(i + 1),
			prevEnd: prev.to,
			shadow: [],
			opaqueDecl: false
		};
	}

	/**
	 * Walk an `if`: the condition sees no fall (it may hold lambdas), each braced branch is
	 * a flag candidate, and an `else if` inherits the same fall — every arm of the chain
	 * completes into the same place.
	 */
	private static function visitIf(ifNode: QueryNode, fall: Fall, source: String, seams: Seams, out: Array<Candidate>): Void {
		final kids: Array<QueryNode> = ifNode.children;
		if (kids.length <= BranchChain.THEN_BRANCH_INDEX) return;
		visit(BranchChain.condOf(ifNode), EMPTY_FALL, source, seams, out);
		branch(BranchChain.thenOf(ifNode), fall, source, seams, out);
		if (!BranchChain.hasElse(ifNode)) return;
		final elseNode: QueryNode = BranchChain.elseBranch(ifNode);
		if (seams.ifKinds.contains(elseNode.kind))
			visit(elseNode, fall, source, seams, out);
		else
			branch(elseNode, fall, source, seams, out);
	}

	/**
	 * One branch of an `if`. A braced branch is tested for a duplicated tail before being
	 * walked; a brace-less one is only walked (a bare `if` there forwards `fall` correctly,
	 * a bare statement has no trailing run to drop).
	 */
	private static function branch(node: QueryNode, fall: Fall, source: String, seams: Seams, out: Array<Candidate>): Void {
		if (seams.blockKinds.contains(node.kind)) {
			final candidate: Null<Candidate> = tryFlag(node, fall, source, seams);
			if (candidate != null) out.push(candidate);
		}
		visit(node, fall, source, seams, out);
	}

	/**
	 * The candidate for `branchBlock` against its fall-through run, or null when any gate
	 * refuses (see the class doc). A null span anywhere refuses too — every offset the
	 * report and the edit need must be known.
	 */
	private static function tryFlag(branchBlock: QueryNode, fall: Fall, source: String, seams: Seams): Null<Candidate> {
		final fallStmts: Array<QueryNode> = fall.stmts;
		if (fallStmts.length == 0) return null;
		final fallLastStmt: QueryNode = fallStmts[fallStmts.length - 1];
		if (!seams.terminalKinds.contains(fallLastStmt.kind)) return null;

		final stmts: Array<QueryNode> = branchBlock.children;
		final count: Int = commonSuffix(stmts, fallStmts, source);
		if (count < 1 || count != fallStmts.length || stmts.length - count < 1) return null;

		final tail: Array<QueryNode> = stmts.slice(stmts.length - count);
		final kept: Array<QueryNode> = stmts.slice(0, stmts.length - count);
		final prevSpan: Null<Span> = kept[kept.length - 1].span;
		final tailFirst: Null<Span> = tail[0].span;
		final tailLast: Null<Span> = tail[tail.length - 1].span;
		final fallLast: Null<Span> = fallLastStmt.span;
		final blockSpan: Null<Span> = branchBlock.span;
		return if (prevSpan == null || tailFirst == null || tailLast == null || fallLast == null || blockSpan == null)
			null
		else if (TailScan.hasConditionalCompilation(source, prevSpan.to, tailLast.to))
			null
		else if (TailScan.hasConditionalCompilation(source, fall.prevEnd, fallLast.to))
			null
		else if (fall.opaqueDecl || TailScan.hasOpaqueDecl(kept, seams))
			null
		else if (TailScan.referencesAny(tail, fall.shadow.concat(TailScan.localDeclNames(kept, seams)), seams.identKinds))
			null
		else
			{
				tailSpan: new Span(tailFirst.from, tailLast.to),
				removeSpan: new Span(prevSpan.to, tailLast.to),
				count: count,
				fixable: commentsAllowFix(source, tail, fallStmts, prevSpan.to, fall.prevEnd, blockSpan.to)
			};
	}

	/** Length of the longest common suffix of `stmts` and `fallStmts` under `sameStatement`. */
	private static function commonSuffix(stmts: Array<QueryNode>, fallStmts: Array<QueryNode>, source: String): Int {
		var k: Int = 0;
		while (
			k < stmts.length
			&& k < fallStmts.length
			&& TailScan.sameStatement(stmts[stmts.length - 1 - k], fallStmts[fallStmts.length - 1 - k], source)
		)
			k++;
		return k;
	}

	/**
	 * Whether the comments let the deletion proceed: every comment in the removed region
	 * must also stand before the kept run (a duplicated explanation goes with its
	 * duplicated code; a unique one would be LOST), and nothing may comment the space
	 * between the last removed statement and the branch's closing brace (a trailing `// …`
	 * there would be stranded on an empty line).
	 */
	private static function commentsAllowFix(
		source: String, tail: Array<QueryNode>, fallStmts: Array<QueryNode>, tailPrevEnd: Int, fallPrevEnd: Int, blockEnd: Int
	): Bool {
		final removedComments: Array<String> = TailScan.runComments(source, tail, tailPrevEnd);
		final fallComments: Array<String> = TailScan.runComments(source, fallStmts, fallPrevEnd);
		for (c in removedComments) if (!fallComments.contains(c)) return false;
		final lastTail: Null<Span> = tail[tail.length - 1].span;
		return lastTail != null && !CheckScan.hasCommentMarker(source, lastTail.to, blockEnd);
	}

}

/**
 * The run of statements that executes after the construct being visited completes:
 * `stmts` themselves, `prevEnd` the offset just past the statement preceding them (0 when
 * `stmts` is empty), `shadow` the local names bound BETWEEN that run's scope and the
 * current position (the names a duplicated tail must not reference), and `opaqueDecl`
 * whether some declaration on the way binds names `shadow` could not enumerate, which
 * refuses every candidate below it.
 */
private typedef Fall = {
	final stmts: Array<QueryNode>;
	final prevEnd: Int;
	final shadow: Array<String>;
	final opaqueDecl: Bool;
};

/**
 * One duplicated tail: `tailSpan` is what the finding reports (the duplicated statements),
 * `removeSpan` what the fix deletes (the same run plus the trivia before it), `count` how
 * many statements it holds, and `fixable` whether the comment gates let the fix run.
 */
private typedef Candidate = {
	final tailSpan: Span;
	final removeSpan: Span;
	final count: Int;
	final fixable: Bool;
};

/** The grammar seams `TailMerge` resolves once per `run` / `fix` — the shared statement-run seams, `TailScan.TailSeams`. */
private typedef Seams = TailSeams;
