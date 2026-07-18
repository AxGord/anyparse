package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.BooleanLogic.BooleanLogicSupport;

/**
 * Flags a loop (`for` / `while` / `do … while`) whose braced body's LAST statement is
 * a bare `if (cond) { … }` (no `else`) preceded by at least one other statement, and
 * de-nests it into an early-`continue` guard so the body sheds an indentation level:
 * `for (…) { pre; if (cond) { BODY } }` → `for (…) { pre; if (!cond) continue; BODY }`.
 * The user's rule (preferences-haxe): sequential null checks each introducing their own
 * variable read better as flat `continue` guards than as growing nesting. Runs to a
 * fixpoint, so a two-level `if (a) { … if (b) { … } }` chain flattens over two `--fix`
 * passes. `Severity.Info`.
 *
 * ## The `if (!cond)` inversion — De Morgan when possible, NaN-safe
 *
 * `cond` is negated by `CheckScan.negateConditionText`, two-tier. When the grammar exposes
 * a `BooleanLogicSupport` and the condition span is comment-free, the negation is pushed
 * inward by De Morgan (`a && b` → `!a || !b`, `!(a || b)` → `a && b`, `==` / `!=` flipped),
 * with the ordered comparisons `< <= > >=` deliberately KEPT wrapped `!(a < b)` (never
 * flipped — `!(a < b)` and `a >= b` differ under NaN). Falling back — a seam-less grammar, or
 * a comment in the condition the De Morgan rewrite would drop — the old text engine wraps
 * `!(cond)` VERBATIM (`!` strip, NaN-safe `==` / `!=` flip, everything else
 * parenthesised-wrapped), preserving the comment. Either tier is sound and compiles.
 *
 * ## Gates — every one is a correctness gate; a violated gate is a semantic bug
 *
 * The `if` must be the loop body's EXACT last statement (no code after it, so the guard
 * skips nothing when `cond` is false), preceded by ≥1 statement (a SOLE-`if` body is the
 * positive `for (…) if (cond) …` combine form — a different, non-`continue` shape this
 * check leaves to `loop-guard` and does not fight), with NO `else` (an `else` branch the
 * `continue` form would lose), and a braced, non-empty then-branch. It must be a DIRECT
 * child of the loop's own body block — an `if` nested in an inner loop / `switch` / `try`
 * targets a different `continue` or `finally` and is never reached. Additionally refused:
 *
 *  - a then-branch that (outside a nested function) reaches a `break` / `continue` /
 *    `return` — its flow equivalence after de-nesting is not re-derived here, so the
 *    conservative direction is to skip (a nested function's own jumps do not count);
 *  - a then-branch top-level local whose name collides with a preceding sibling local or
 *    the loop iterator — de-nesting would widen it into the loop scope and same-scope
 *    re-declare it (a `-D no-shadowing` hazard), so it is refused;
 *  - a comment in the `if (` or `) {` glue the rewrite drops (comments in the condition or
 *    the then-body are preserved).
 *
 * ## Grammar-agnostic
 *
 * Driven by `loopStatementKinds` (body = last child) and `doWhileLoopKinds` (body = first
 * child), `ifStatementKinds`, `continueStatementKind`, and `ControlFlowSupport.blockKinds`
 * (any of which unset → no-op), plus `localDeclKinds` (collision gate), the break/continue/
 * return kinds (flow gate), the function / lambda kinds (nested-scope stop), `opaqueKinds`
 * (skip macro reification), and the `notKind` / `eqKind` / `notEqKind` / `parenKind` /
 * atomic kinds that shape the inversion.
 */
@:nullSafety(Strict)
final class GuardContinue implements Check {

	/** A guard `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return 'guard-continue';
	}

	public function description(): String {
		return 'a trailing if in a loop body, de-nestable to an if (!cond) continue; guard';
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

	/** De-nest each flagged trailing `if` into an `if (!cond) continue;` guard, replacing the `if` statement. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byIf: Map<String, Candidate> = [];
		indexCandidates(tree, source, seams, byIf);
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final m: Null<Candidate> = byIf['${span.from}:${span.to}'];
			if (m == null) continue;
			final edit: Null<{ span: Span, text: String }> = editFor(m, source, seams);
			if (edit != null) edits.push(edit);
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.length == 0) return null;
		if (shape.continueStatementKind == null) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final loopKinds: Array<String> = shape.loopStatementKinds ?? [];
		final doWhileKinds: Array<String> = shape.doWhileLoopKinds ?? [];
		if (loopKinds.length == 0 && doWhileKinds.length == 0) return null;
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
			doWhileKinds: doWhileKinds,
			ifKinds: ifKinds,
			blockKinds: support.blockKinds(),
			localDeclKinds: shape.localDeclKinds ?? [],
			flowExitKinds: flowExitKinds(shape),
			nestedScopeKinds: nestedScopeKinds(shape),
			opaqueKinds: shape.opaqueKinds ?? [],
			negation: {
				notKind: shape.notKind,
				parenKind: shape.parenKind,
				eqKind: shape.eqKind,
				notEqKind: shape.notEqKind,
				atomicKinds: atomicKinds
			},
			support: plugin.booleanLogicSupport()
		};
	}

	/** The break / continue / return kinds (statement and expression forms) whose presence in a then-branch refuses the de-nest — throws are excluded (always safe). */
	private static function flowExitKinds(shape: RefShape): Array<String> {
		final throwKinds: Array<String> = shape.throwKinds ?? [];
		final out: Array<String> = [];
		for (k in [
			shape.continueStatementKind,
			shape.breakStatementKind,
			shape.returnStatementKind,
			shape.voidReturnKind
		]) if (k != null && !out.contains(k)) out.push(k);
		for (k in (shape.valueReturnKinds ?? [])) if (!out.contains(k)) out.push(k);
		for (k in (shape.controlExitKinds ?? [])) if (!throwKinds.contains(k) && !out.contains(k)) out.push(k);
		return out;
	}

	/** Function / lambda kinds whose subtree the flow scan does NOT descend — a nested function's own jumps and returns are unrelated to this loop. */
	private static function nestedScopeKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (grp in [
			shape.functionKinds ?? [],
			shape.lambdaKinds ?? [],
			shape.localFunctionKinds ?? []
		]) for (k in grp) if (!out.contains(k)) out.push(k);
		return out;
	}

	/** Walk `node`, flagging each loop whose body ends in a de-nestable trailing `if`. */
	private static function walk(node: QueryNode, out: Array<Violation>, file: String, source: String, s: Seams): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (isLoop(node, s)) {
			final m: Null<Candidate> = match(node, source, s);
			if (m != null) {
				final span: Null<Span> = m.ifNode.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'guard-continue',
					severity: Severity.Info,
					message: 'this trailing if can de-nest to an if (!cond) continue; guard'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, s);
	}

	/** Index every de-nestable loop's candidate by its `if`'s `from:to` span key (for `fix` to re-find it). */
	private static function indexCandidates(node: QueryNode, source: String, s: Seams, out: Map<String, Candidate>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (isLoop(node, s)) {
			final m: Null<Candidate> = match(node, source, s);
			if (m != null) {
				final span: Null<Span> = m.ifNode.span;
				if (span != null) out['${span.from}:${span.to}'] = m;
			}
		}
		for (c in node.children) indexCandidates(c, source, s, out);
	}

	private static function isLoop(node: QueryNode, s: Seams): Bool {
		return s.loopKinds.contains(node.kind) || s.doWhileKinds.contains(node.kind);
	}

	/**
	 * If `loop`'s braced body's last statement is a de-nestable bare `if (c) { … }` (no
	 * `else`, non-empty braced then-branch) preceded by ≥1 statement, and every gate holds
	 * (flow, name-collision, glue-comment), return that `if`, its then-branch and its
	 * condition; else null.
	 */
	private static function match(loop: QueryNode, source: String, s: Seams): Null<Candidate> {
		final body: Null<QueryNode> = loopBody(loop, s);
		if (body == null || !s.blockKinds.contains(body.kind)) return null;
		final stmts: Array<QueryNode> = body.children;
		if (stmts.length < IF_NO_ELSE_CHILD_COUNT) return null;
		final ifNode: QueryNode = stmts[stmts.length - 1];
		if (!s.ifKinds.contains(ifNode.kind) || ifNode.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final cond: QueryNode = ifNode.children[0];
		final thenBlock: QueryNode = ifNode.children[1];
		return !s.blockKinds.contains(thenBlock.kind) || thenBlock.children.length == 0 || bodyHasFlowExit(thenBlock, s)
			|| hasNameCollision(loop, body, ifNode, thenBlock, s) || headerHasComment(source, ifNode, cond, thenBlock)
			? null
			: {
				ifNode: ifNode,
				thenBlock: thenBlock,
				cond: cond
			};
	}

	/** The loop's body block: the LAST child for a body-last loop (`for` / `while`), the FIRST for a body-first `do … while`. */
	private static function loopBody(loop: QueryNode, s: Seams): Null<QueryNode> {
		final kids: Array<QueryNode> = loop.children;
		return kids.length == 0 ? null : s.doWhileKinds.contains(loop.kind) ? kids[0] : kids[kids.length - 1];
	}

	/** Whether `node`'s subtree reaches a flow-exit (break / continue / return) OUTSIDE any nested function scope — the conservative flow gate. */
	private static function bodyHasFlowExit(node: QueryNode, s: Seams): Bool {
		if (s.nestedScopeKinds.contains(node.kind)) return false;
		if (s.flowExitKinds.contains(node.kind)) return true;
		for (c in node.children) if (bodyHasFlowExit(c, s)) return true;
		return false;
	}

	/**
	 * Whether a then-branch top-level local name collides with a name already bound in the
	 * loop body scope at the `if` — a preceding sibling local or the loop iterator — which
	 * de-nesting would same-scope re-declare.
	 */
	private static function hasNameCollision(loop: QueryNode, body: QueryNode, ifNode: QueryNode, thenBlock: QueryNode, s: Seams): Bool {
		final scopeNames: Map<String, Bool> = [];
		final iter: Null<String> = loop.name;
		if (iter != null && iter != '') scopeNames[iter] = true;
		for (stmt in body.children) {
			if (stmt == ifNode) break;
			if (!s.localDeclKinds.contains(stmt.kind)) continue;
			final n: Null<String> = stmt.name;
			if (n != null) scopeNames[n] = true;
		}
		for (stmt in thenBlock.children) if (s.localDeclKinds.contains(stmt.kind)) {
			final n: Null<String> = stmt.name;
			if (n != null && scopeNames.exists(n)) return true;
		}
		return false;
	}

	/** Whether a comment sits in the dropped `if (` or `) {` glue (a comment in the condition or the then-body is preserved and does NOT refuse). */
	private static function headerHasComment(source: String, ifNode: QueryNode, cond: QueryNode, thenBlock: QueryNode): Bool {
		final ifSpan: Null<Span> = ifNode.span;
		final condSpan: Null<Span> = cond.span;
		final thenSpan: Null<Span> = thenBlock.span;
		if (ifSpan == null || condSpan == null || thenSpan == null) return true;
		final headerGap: Bool = gapComment(source, ifSpan.from, condSpan.from);
		return headerGap || gapComment(source, condSpan.to, thenSpan.from);
	}

	/** Whether `[from, to)` of `source` holds a `//` or `/*` comment marker. */
	private static function gapComment(source: String, from: Int, to: Int): Bool {
		if (from >= to) return false;
		final gap: String = source.substring(from, to);
		return gap.indexOf('//') != -1 || gap.indexOf('/*') != -1;
	}

	/** Replace the flagged `if` statement with `if (!cond) continue;` followed by the then-branch's inner statements (the writer re-indents the de-nested run). */
	private static function editFor(m: Candidate, source: String, s: Seams): Null<{ span: Span, text: String }> {
		final ifSpan: Null<Span> = m.ifNode.span;
		final thenSpan: Null<Span> = m.thenBlock.span;
		if (ifSpan == null || thenSpan == null) return null;
		final neg: String = CheckScan.negateConditionText(m.cond, source, s.negation, s.support);
		final inner: String = StringTools.rtrim(source.substring(thenSpan.from + 1, thenSpan.to - 1));
		return { span: ifSpan, text: 'if (' + neg + ') continue;' + inner };
	}

}

/** The `RefShape` kinds `GuardContinue` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var loopKinds: Array<String>;
	var doWhileKinds: Array<String>;
	var ifKinds: Array<String>;
	var blockKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var flowExitKinds: Array<String>;
	var nestedScopeKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var negation: NegationSeams;
	var support: Null<BooleanLogicSupport>;
}

/** A matched loop guard: the trailing `if` statement, its braced then-branch, and its condition. */
private typedef Candidate = {
	var ifNode: QueryNode;
	var thenBlock: QueryNode;
	var cond: QueryNode;
}
