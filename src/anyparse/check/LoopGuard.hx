package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.BooleanLogic.BooleanLogicSupport;

/**
 * Flags a loop (`for` / `while`) whose braced body OPENS with a bare
 * `if (c) continue;` guard — the user's rule: combine `for` + `if` into
 * `for (...) if (...) {`, preferred over a leading `if (!cond) continue;` that
 * inverts the condition and wastes a line. `Severity.Info`, with an autofix that
 * lifts the guard into the loop header:
 * `for (x in xs) { if (c) continue; REST }` → `for (x in xs) if (INV) { REST }`.
 *
 * ## The inversion — De Morgan when possible, sound over IEEE floats
 *
 * `INV` negates the guard condition `c` so the surviving iterations are the ones the
 * `continue` skipped. When the grammar exposes a `BooleanLogicSupport` and `c` is
 * comment-free, `CheckScan.negateConditionText` pushes De Morgan inward; otherwise (a
 * seam-less grammar, or a comment inside `c`) it falls back to the verbatim text engine.
 * Both agree on the leaf rules:
 *
 * - `!e` → `e` (strip the `!`, unwrapping a redundant paren so `!(a && b)` → `a && b`);
 * - `a == b` → `a != b`, `a != b` → `a == b` (NaN-safe: IEEE `NaN == x` is false and
 *   `NaN != x` true, so `!(a == b)` is `a != b` even with a NaN operand);
 * - an ordered comparison `<` / `<=` / `>` / `>=` is deliberately NOT flipped — `!(a < b)`
 *   and `a >= b` DIFFER when an operand is NaN — so it is kept wrapped `!(a < b)`;
 * - `&&` / `||` distribute by De Morgan (`a && b` → `!a || !b`) on the seam path, or the
 *   whole `c` wraps `!(c)` on the fallback path; a bare identifier / call / field access
 *   → `!c`.
 *
 * ## Gates
 *
 * The guard must be the loop body's FIRST statement, the body a braced block with at
 * least one statement AFTER the guard (a guard-only body is a no-op loop, left alone),
 * and the guard a bare `if` (no `else`) whose then-branch is exactly `continue;` (bare
 * or braced-single). A CASCADE — the statement right after the first guard is ANOTHER
 * `if`-continue — is deliberately NOT flagged: the user keeps sequential `continue`
 * guards, each introducing its own checks, rather than nesting them. A later `continue`
 * deeper in REST is fine (the wrapped body still continues the same loop) and does not
 * block the flag. A comment inside the guard, or between the loop-body brace and the guard, would be lost by the rewrite, so such a
 * guard is left unflagged.
 *
 * ## Grammar-agnostic
 *
 * Driven by `loopStatementKinds` (loops whose body is the last child),
 * `continueStatementKind`, `ifStatementKinds` and `blockStmtKind` (any unset → no-op),
 * plus `notKind` / `eqKind` / `notEqKind` / `parenKind` and the atomic-expression kinds
 * (`identKind` / `callKind` / `fieldAccessKind` / …) that shape the inversion, and
 * `opaqueKinds` to skip macro reification.
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
		return 'a loop whose body opens with an if-continue guard, liftable to a for/while … if header';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(tree, violations, entry.file, entry.source, seams);
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
		indexCandidates(tree, source, seams, byGuard);
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
			edits.push({ span: bodySpan, text: 'if (' + invert(m.cond, source, seams) + ') {' + rest + '}' });
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
		if (blockStmtKind == null) return null;
		final atomicKinds: Array<String> = [
			for (k in [
				(shape.identKind: Null<String>),
				shape.callKind,
				shape.fieldAccessKind,
				shape.forceFieldAccessKind,
				shape.nullSafeAccessKind,
				shape.indexAccessKind,
				shape.newExprKind,
				shape.parenKind,
				shape.boolLitKind
			]) if (k != null) k
		];
		return {
			loopKinds: loopKinds,
			continueKind: continueKind,
			ifKinds: ifKinds,
			blockStmtKind: blockStmtKind,
			notKind: shape.notKind,
			eqKind: shape.eqKind,
			notEqKind: shape.notEqKind,
			parenKind: shape.parenKind,
			atomicKinds: atomicKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			support: plugin.booleanLogicSupport()
		};
	}

	/** Walk `node`, flagging each loop whose body opens with a liftable `if`-continue guard. */
	private static function walk(node: QueryNode, out: Array<Violation>, file: String, source: String, s: Seams): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.loopKinds.contains(node.kind)) {
			final m: Null<Candidate> = match(node, source, s);
			if (m != null) {
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
		for (c in node.children) walk(c, out, file, source, s);
	}

	/** Index every liftable loop's candidate by its guard's `from:to` span key (for `fix` to re-find it). */
	private static function indexCandidates(node: QueryNode, source: String, s: Seams, out: Map<String, Candidate>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.loopKinds.contains(node.kind)) {
			final m: Null<Candidate> = match(node, source, s);
			if (m != null) {
				final span: Null<Span> = m.guard.span;
				if (span != null) out['${span.from}:${span.to}'] = m;
			}
		}
		for (c in node.children) indexCandidates(c, source, s, out);
	}

	/**
	 * If `loop`'s braced body opens with a bare `if (c) continue;` guard followed by at
	 * least one non-cascade statement, return the guard, the body block and the guard
	 * condition; else null. Bails when a comment sits in the dropped `[body-open, guard-end)`
	 * region (a leading comment before the guard, or one inside it, the rewrite would drop).
	 */
	private static function match(loop: QueryNode, source: String, s: Seams): Null<Candidate> {
		if (loop.children.length == 0) return null;
		final body: QueryNode = loop.children[loop.children.length - 1];
		if (body.kind != s.blockStmtKind || body.children.length < IF_NO_ELSE_CHILD_COUNT) return null;
		final guard: QueryNode = body.children[0];
		final cond: Null<QueryNode> = ifContinueCond(guard, s);
		if (cond == null) return null;
		if (ifContinueCond(body.children[1], s) != null) return null;
		final gs: Null<Span> = guard.span;
		final bs: Null<Span> = body.span;
		if (gs == null || bs == null) return null;
		final hasComment: Bool = gapHasComment(source, bs.from, gs.to);
		return hasComment ? null : { guard: guard, body: body, cond: cond };
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

	/** The inverted source of guard condition `cond` — the negation the lifted `if` header tests. */
	private static function invert(cond: QueryNode, source: String, s: Seams): String {
		return CheckScan.negateConditionText(cond, source, {
			notKind: s.notKind,
			parenKind: s.parenKind,
			eqKind: s.eqKind,
			notEqKind: s.notEqKind,
			atomicKinds: s.atomicKinds
		}, s.support);
	}

	/** Whether the `[from, to)` gap holds a `//` or `/*` comment opener (a region the rewrite would drop). */
	private static function gapHasComment(source: String, from: Int, to: Int): Bool {
		if (from >= to) return false;
		final gap: String = source.substring(from, to);
		return gap.indexOf('//') != -1 || gap.indexOf('/*') != -1;
	}

}

/** The `RefShape` kinds `LoopGuard` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var loopKinds: Array<String>;
	var continueKind: String;
	var ifKinds: Array<String>;
	var blockStmtKind: String;
	var notKind: Null<String>;
	var eqKind: Null<String>;
	var notEqKind: Null<String>;
	var parenKind: Null<String>;
	var atomicKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var support: Null<BooleanLogicSupport>;
}

/** A matched loop guard: the `if`-continue statement, the loop body block, and the guard condition. */
private typedef Candidate = {
	var guard: QueryNode;
	var body: QueryNode;
	var cond: QueryNode;
}
