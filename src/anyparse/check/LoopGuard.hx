package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.check.IfExpressionChain.ShieldSeams;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.BooleanLogic.BooleanLogicSupport;

/**
 * Flags a loop (`for` / `while`) that opens with a bare `if (g) continue;` guard — the
 * user's rule: combine `for` + `if` into `for (...) if (...) {`, preferred over a leading
 * `if (!cond) continue;` that inverts the condition and wastes a line. `Severity.Info`,
 * with an autofix in TWO arms.
 *
 * ## The two arms
 *
 * LIFT — the loop body IS the braced block, and the inverted guard becomes the header the
 * loop did not have:
 * `for (x in xs) { if (g) continue; REST }` → `for (x in xs) if (INV(g)) { REST }`.
 *
 * MERGE — the loop body is ALREADY a lifted header `if (c) { … }` whose braced block opens
 * with the guard, so the inversion joins that header with `&&` rather than creating a second
 * one:
 * `for (x in xs) if (c) { if (g) continue; REST }` → `for (x in xs) if (c && INV(g)) { REST }`.
 *
 * Both arms rest on the same equivalence — a `continue` in that FIRST position is exactly
 * "do not enter the body" — and both run every gate below. The merge arm additionally
 * parenthesises whichever operand binds looser than `&&`: the KEPT header condition through
 * `RefShape.andLowerPrecedenceKinds` (the same list `collapsible-if` merges with), and a De
 * Morgan `||` negation through the `slotKind` argument `CheckScan.negateConditionText` /
 * `BooleanLogicSupport.negateCondition` take — the merge slot is synthetic, so it is
 * addressed by KIND where `simplify-negated-compound` passes a parent node.
 *
 * ## The inversion — De Morgan when possible, sound over NaN and null
 *
 * `INV` negates the guard condition `g` so the surviving iterations are the ones the
 * `continue` skipped. When the grammar exposes a `BooleanLogicSupport` and `g` is
 * comment-free, `CheckScan.negateConditionText` pushes De Morgan inward; otherwise (a
 * seam-less grammar, a comment inside `g`, or a condition whose flattened `||` chain would
 * STRAND a null-safety narrowing — `CheckScan.narrowingStranded`) it falls back to the
 * verbatim text engine. Both agree on the leaf rules:
 *
 * - `!e` → `e` (strip the `!`, unwrapping a redundant paren so `!(a && b)` → `a && b`);
 * - `a == b` → `a != b`, `a != b` → `a == b` (NaN-safe: IEEE `NaN == x` is false and
 *   `NaN != x` true, so `!(a == b)` is `a != b` even with a NaN operand);
 * - an ordered comparison `<` / `<=` / `>` / `>=` flips only where the operand types license it:
 *   `!(a < b)` and `a >= b` DIFFER when an operand is a NaN or a `null`, so it stays wrapped;
 * - `&&` / `||` distribute by De Morgan (`a && b` → `!a || !b`) on the seam path, or the
 *   whole `g` wraps `!(g)` on the fallback path; a bare identifier / call / field access
 *   → `!g`.
 *
 * ## Gates
 *
 * The guard must be the FIRST statement of a braced block with at least one statement AFTER
 * it (a guard-only body is a no-op loop, left alone) — the loop body itself on the lift arm,
 * the header-if's then-branch on the merge arm — and the guard a bare `if` (no `else`) whose
 * then-branch is exactly `continue;` (bare or braced-single). A CASCADE — the statement right
 * after the first guard is ANOTHER `if`-continue — is deliberately NOT flagged: the user keeps
 * sequential `continue` guards, each introducing its own checks, rather than nesting them. A
 * later `continue` deeper in REST is fine (the wrapped body still continues the same loop) and
 * does not block the flag. A comment inside the guard, or between the block brace and the
 * guard, would be lost by the rewrite, so such a guard is left unflagged.
 *
 * The merge arm adds two of its own. The header `if` must carry NO `else`: that branch fires
 * on `!c` today and would fire on `!c || g` after the merge. And it needs
 * `RefShape.andOperatorText` — unset, only the lift arm runs.
 *
 * The LIFT arm adds one more, and it is about POSITION rather than shape: the header it emits
 * carries no `else`, so wherever the loop sits somewhere an `else` CAN follow, that trailing
 * `else` rebinds to the emitted header. Measured, not assumed — `hxq lint --fix --rule
 * loop-guard` on `if (p) for (x in xs) { if (x == 0) continue; trace(x); } else trace(0);`
 * produced `if (p) for (x in xs) if (x != 0) { trace(x); } else trace(0);`, the writer even
 * re-indenting the `else` under the inner `if`; on 4.3.7 `--interp` with `trace('ELSE')` in the
 * else-branch, `p == false` printed ELSE once BEFORE and nothing AFTER, while
 * `p == true, xs == [0, 0]` printed nothing BEFORE and ELSE TWICE AFTER — once per skipped
 * element. So the arm runs only in a SHIELDED position. `IfExpressionChain.childShielded`
 * carries one boolean down the walk, seeded true at the module root (nothing follows a
 * top-level declaration but another one) and re-derived per child against
 * `IfExpressionChain.shieldSeams`; it is false only in the then-branch of an else-carrying
 * conditional, and wherever a chain of brace-less bodies inherits that exposure — so
 * `if (p) while (ok) for (…) { … } else …` is refused too. The gate sits INSIDE `match`, so
 * both `run`'s report and `fix`'s re-index read it from one place. That is belt and braces
 * rather than an enforced invariant: `fix` only emits edits for spans `run` already
 * reported, so no test flips if the gate moves into `walk` alone.
 *
 * The MERGE arm needs no such gate, and not by luck: position is irrelevant to it BY
 * CONSTRUCTION. It rewrites an `if` that ALREADY exists — it edits that header's condition
 * span and the body span, emits no new `if`, and so changes no else-binding anywhere. The
 * tempting shape argument — that in an unshielded position the trailing `else` has ALREADY
 * bound to the loop body's header `if`, leaving it three children where `match` accepts only
 * the else-less two — describes the common non-`#if` case and is NOT an invariant.
 * Counterexample, confirmed to FIRE:
 * `if (p) #if X for (x in xs) if (c) { if (g) continue; trace(x); } #else trace(1); #end
 * else trace(0);` parses as `IfStmt(p, Conditional(…), else)` — the `else` binds to
 * `if (p)`, the header `if (c)` keeps TWO children, and the `Conditional` passes the
 * unshielded flag through `RefactorSupport.isConditionalKind`. The arm fires there and
 * rewrites the header to `if (c && !g)`, which is exactly right.
 *
 * ## Grammar-agnostic
 *
 * Driven by `loopStatementKinds` (loops whose body is the last child),
 * `continueStatementKind`, `ifStatementKinds` and `blockStmtKind` (any unset → no-op),
 * plus `notKind` / `eqKind` / `notEqKind` / `parenKind` and the atomic-expression kinds
 * (`identKind` / `callKind` / `fieldAccessKind` / …) that shape the inversion,
 * `andOperatorText` / `andLowerPrecedenceKinds` / `logicalAndKind` that shape the merge, and
 * `opaqueKinds` to skip macro reification. The dangling-else gate adds
 * `ControlFlowSupport.blockKinds()` plus the delimited-host kinds
 * `IfExpressionChain.shieldSeams` folds in, and `ifExpressionKinds` alongside
 * `ifStatementKinds` for the conditional set. The two halves fail in OPPOSITE directions.
 * Dropping a SHIELD entry only downgrades a TAIL child from proved-safe to inherited, so the
 * LIFT arm then refuses MORE — the conservative direction. Dropping a CONDITIONAL entry does
 * the reverse: `childShielded` ends with
 * `!(index == THEN_BRANCH_INDEX && conditionalKinds.contains(parent.kind))`, so an EMPTY
 * conditional set answers "shielded" for every non-tail child, the gate never fires and the
 * arm refuses FEWER sites. `ifStatementKinds` is a hard `readSeams` requirement, which is
 * what keeps Haxe safe; `ifExpressionKinds` is independently optional and is the ONE seam
 * whose absence LOOSENS this gate — a genuine under-refusal risk for a future grammar with
 * an if-expression form.
 */
@:nullSafety(Strict)
final class LoopGuard implements Check {

	/** A guard `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'loop-guard';
	}

	public function description(): String {
		return 'a loop whose body opens with an if-continue guard, liftable into — or mergeable with — a for/while … if header';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			// The module root is shielded: nothing follows a top-level declaration but another
			// one, so no `else` can reach a loop that inherits its exposure from there.
			if (tree != null)
				walk(
					tree, violations, entry.file, entry.source, seams, true,
					CheckScan.typeNominalResolver(entry.source, plugin, tree, entry.file)
				);
		}
		return violations;
	}

	/** Lift each flagged loop's leading guard into an inverted `if` header, replacing the body block. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byGuard: Map<String, Candidate> = [];
		indexCandidates(tree, source, seams, byGuard, true);
		final types: Null<(QueryNode) -> Null<String>> = violations.length == 0
			? null
			: CheckScan.typeNominalResolver(source, plugin, tree, violations[0].file, index);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final m: Null<Candidate> = byGuard['${span.from}:${span.to}'];
			if (m == null) continue;
			final bodySpan: Null<Span> = m.body.span;
			final guardSpan: Null<Span> = m.guard.span;
			if (bodySpan == null || guardSpan == null) continue;
			final rest: String = source.substring(guardSpan.to, bodySpan.to - 1);
			final headerCond: Null<QueryNode> = m.headerCond;
			if (headerCond == null) {
				edits.push({ span: bodySpan, text: 'if (${invert(m.cond, source, seams, types)}) {$rest}' });
				continue;
			}
			final headerSpan: Null<Span> = headerCond.span;
			final andOp: Null<String> = seams.andOperatorText;
			if (headerSpan == null || andOp == null) continue;
			final kept: String = source.substring(headerSpan.from, headerSpan.to);
			final lhs: String = seams.negation.andLowerPrecedenceKinds.contains(headerCond.kind) ? '($kept)' : kept;
			edits.push({
				span: headerSpan,
				text: '$lhs $andOp ${invert(m.cond, source, seams, types, seams.negation.andKind)}'
			});
			edits.push({ span: bodySpan, text: '{$rest}' });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final loopKinds: Null<Array<String>> = shape.loopStatementKinds;
		if (loopKinds == null || loopKinds.length == 0) return null;
		final continueKind: Null<String> = shape.continueStatementKind;
		if (continueKind == null) return null;
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		if (ifKinds == null || ifKinds.length == 0) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		return blockStmtKind == null ? null : {
			loopKinds: loopKinds,
			continueKind: continueKind,
			ifKinds: ifKinds,
			blockStmtKind: blockStmtKind,
			negation: CheckScan.negationSeams(shape),
			opaqueKinds: shape.opaqueKinds ?? [],
			support: plugin.booleanLogicSupport(),
			andOperatorText: shape.andOperatorText,
			shield: IfExpressionChain.shieldSeams(shape, plugin.controlFlowSupport()?.blockKinds() ?? [])
		};
	}

	/** Walk `node`, flagging each loop whose body opens with a liftable `if`-continue guard. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, s: Seams, shielded: Bool, ?types: (QueryNode) -> Null<String>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.loopKinds.contains(node.kind)) {
			final m: Null<Candidate> = match(node, source, s, shielded);
			// The lifted header tests the INVERTED guard condition; if that inversion cannot
			// shed its `!( … )` wrap, the header reads worse than the `continue` it replaces.
			if (m != null && CheckScan.negationIsClean(m.cond, source, s.negation, s.support, types)) {
				final span: Null<Span> = m.guard.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'loop-guard',
					severity: Severity.Info,
					message: 'this leading if-continue guard can move to the loop header (for/while … if)'
				});
			}
		}
		for (i => c in node.children) walk(c, out, file, source, s, IfExpressionChain.childShielded(node, i, s.shield, shielded), types);
	}

	/** Index every liftable loop's candidate by its guard's `from:to` span key (for `fix` to re-find it). */
	private static function indexCandidates(node: QueryNode, source: String, s: Seams, out: Map<String, Candidate>, shielded: Bool): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.loopKinds.contains(node.kind)) {
			final m: Null<Candidate> = match(node, source, s, shielded);
			if (m != null) {
				final span: Null<Span> = m.guard.span;
				if (span != null) out['${span.from}:${span.to}'] = m;
			}
		}
		for (i => c in node.children) indexCandidates(c, source, s, out, IfExpressionChain.childShielded(node, i, s.shield, shielded));
	}

	/**
	 * The candidate for `loop`, or null when neither arm applies. A braced loop body goes to
	 * `matchBlock` as the LIFT arm (no header to merge with); a loop body that is itself a
	 * header `if (c) { … }` goes there as the MERGE arm, carrying that header's CONDITION, and
	 * must additionally have no `else`, a braced then-branch, and the two `&&` seams the merge
	 * emits (`andOperatorText` for the joiner, `logicalAndKind` for the slot the inversion is
	 * parenthesised against).
	 */
	private static function match(loop: QueryNode, source: String, s: Seams, shielded: Bool): Null<Candidate> {
		if (loop.children.length == 0) return null;
		final body: QueryNode = loop.children[loop.children.length - 1];
		// The LIFT arm creates an `if` header with NO `else`, so in a position an `else` can
		// reach, that trailing `else` rebinds to the emitted header. Refuse there. The MERGE arm
		// below needs none: it edits an EXISTING header's condition instead of emitting an `if`,
		// so it changes no else-binding at all. See the dangling-else gate in the class doc.
		if (body.kind == s.blockStmtKind) return shielded ? matchBlock(body, source, s, null) : null;
		// The MERGE arm: the loop body is already a lifted header `if (c) { … }`, so the guard
		// joins that header with `&&` instead of creating one. An `else` disqualifies the site —
		// it fires on `!c` today and would fire on `!c || g` after the merge.
		// `andKind` gates too: it is the slot the inversion is parenthesised against, and without it a
		// De Morgan `||` result would land bare after the `&&` and silently re-associate.
		if (s.andOperatorText == null || s.negation.andKind == null) return null;
		if (!s.ifKinds.contains(body.kind) || body.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final thenBranch: QueryNode = body.children[1];
		return thenBranch.kind == s.blockStmtKind ? matchBlock(thenBranch, source, s, body.children[0]) : null;
	}

	/**
	 * If braced block `body` opens with a bare `if (c) continue;` guard followed by at least one
	 * non-cascade statement, the candidate; else null. Bails when a comment sits in the dropped
	 * `[body-open, guard-end)` region (a leading comment before the guard, or one inside it, the
	 * rewrite would drop). `header` is the lifted header-if's condition on the merge arm, null
	 * when the loop's own body is this block.
	 */
	private static function matchBlock(body: QueryNode, source: String, s: Seams, headerCond: Null<QueryNode>): Null<Candidate> {
		if (body.children.length < IF_NO_ELSE_CHILD_COUNT) return null;
		final guard: QueryNode = body.children[0];
		final cond: Null<QueryNode> = ifContinueCond(guard, s);
		if (cond == null) return null;
		if (ifContinueCond(body.children[1], s) != null) return null;
		final gs: Null<Span> = guard.span;
		final bs: Null<Span> = body.span;
		if (gs == null || bs == null) return null;
		final hasComment: Bool = CheckScan.hasCommentMarker(source, bs.from, gs.to);
		return hasComment ? null : {
			guard: guard,
			body: body,
			cond: cond,
			headerCond: headerCond
		};
	}

	/** The condition of a bare `if (c) continue;` (no `else`, then-branch exactly `continue`, braced-single allowed), else null. */
	private static function ifContinueCond(stmt: QueryNode, s: Seams): Null<QueryNode> {
		return s.ifKinds.contains(stmt.kind) && stmt.children.length == IF_NO_ELSE_CHILD_COUNT && isContinue(stmt.children[1], s)
			? stmt.children[0]
			: null;
	}

	/** Whether `node` is a `continue` statement — bare, or a single-statement block wrapping one. */
	private static function isContinue(node: QueryNode, s: Seams): Bool {
		return node.kind == s.continueKind
			|| (node.kind == s.blockStmtKind && node.children.length == 1 && node.children[0].kind == s.continueKind);
	}

	/**
	 * The inverted source of guard condition `cond` — the negation the lifted `if` header tests.
	 * `slotKind` is set on the merge arm, where the negation becomes the right operand of the
	 * header's `&&` and a De Morgan `||` result must carry a parenthesis pair.
	 */
	private static function invert(
		cond: QueryNode, source: String, s: Seams, ?types: (QueryNode) -> Null<String>, ?slotKind: String
	): String {
		return CheckScan.negateConditionText(cond, source, s.negation, s.support, types, slotKind);
	}

}

/** The `RefShape` kinds `LoopGuard` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var loopKinds: Array<String>;
	var continueKind: String;
	var ifKinds: Array<String>;
	var blockStmtKind: String;
	var negation: NegationSeams;
	var opaqueKinds: Array<String>;
	var support: Null<BooleanLogicSupport>;
	var andOperatorText: Null<String>;

	/**
	 * The dangling-`else` gate's inputs: the parents that close every child with a delimiter,
	 * and every `if` form a lifted header's missing `else` could be absorbed by.
	 */
	var shield: ShieldSeams;
}

/**
 * A matched loop guard: the `if`-continue statement, the block whose span the rewrite replaces, the guard condition to invert, and — on the MERGE arm only — the CONDITION of the header `if` the inversion joins with `&&` (null on the LIFT arm, which creates that header instead).
 */
private typedef Candidate = {
	var guard: QueryNode;
	var body: QueryNode;
	var cond: QueryNode;
	var headerCond: Null<QueryNode>;
}
