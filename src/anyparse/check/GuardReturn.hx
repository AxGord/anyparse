package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a block whose LAST TWO statements are a bare `if (cond) { BLOCK }` (no `else`)
 * and a lone trailing `return TAIL;`, and INVERTS the pair into an early-return guard so
 * the bulk of the work sheds an indentation level:
 * `if (cond) { BLOCK } return TAIL;` -> `if (!cond) return TAIL; BLOCK`.
 * The user's rule (preferences): a guard clause reads better than a positive branch
 * wrapping the whole body. `Severity.Info`, with an autofix. Runs to a fixpoint, so a
 * two-level `if (p) { if (q) { … return 1; } return 2; } return 3;` flattens over two
 * `--fix` passes.
 *
 * ## The `if (!cond)` inversion - De Morgan when possible, NaN-safe
 *
 * `cond` is negated by `CheckScan.negateConditionText`, the engine `loop-guard` and
 * `guard-continue` share, two-tier. When the grammar exposes a `BooleanLogicSupport` and
 * the condition span is comment-free, the negation is pushed inward by De Morgan
 * (`a && b` -> `!a || !b`, `!(a || b)` -> `a && b`, `==` / `!=` flipped NaN-safely), with the
 * ordered comparisons `< <= > >=` deliberately KEPT wrapped `!(a < b)` - never flipped,
 * since `!(a < b)` and `a >= b` differ under NaN. Falling back - a seam-less grammar, a
 * comment in the condition the De Morgan rewrite would drop, or the stranded-narrowing
 * gate below - the text engine wraps `!(cond)` VERBATIM. Either tier is sound and compiles.
 *
 * ### The stranded-narrowing gate on the De Morgan path
 *
 * De Morgan turns an `&&` chain into an `||` chain, and Haxe's strict null-safety carries a
 * narrowing fact into a later `||` operand from the chain's FIRST operand ONLY. So
 * `a != null && b != null && p(a.length, b.length)` (which compiles) becomes
 * `a == null || b == null || p(a.length, b.length)` (which does NOT - `b` is no longer
 * narrowed). Measured on the compiler: the fact of operand 1 reaches operand 3, the fact of
 * operand 2 does not; a two-operand chain is always safe, and a right-nested
 * `x || (y || z)` is safe. Rather than emit a right-nested disjunction, this check DECLINES
 * the De Morgan tier for such a condition and falls back to the verbatim `!(cond)` wrap,
 * whose interior is the original `&&` chain and so narrows exactly as before (verified: the
 * de-nested body still narrows after the wrapped guard). The gate is syntactic and
 * conservative - no type information: a negated `&&` chain is flagged when an operand at
 * index 3 or later shares a plain identifier with an operand at index 2 or later that
 * precedes it. A condition that ALREADY spans lines takes NO fix on this path at all: the
 * verbatim wrap re-emits it as-is, so a nested multi-line `!( … )` would read worse than
 * the branch it replaces (a De-Morganed multi-line condition still de-nests). `loop-guard` negates in the opposite direction (a skip condition into a keep
 * condition) and `guard-continue` shares the hazard; the gate lives HERE rather than in
 * `CheckScan` so the shared engine's other consumers keep their exact output.
 *
 * ## Gates
 *
 * The two statements must be the block's last two, in that order - a statement BETWEEN the
 * `if` and the `return` means the `return` is not the `if`'s fall-through, and the
 * inversion would reorder it. The `if` must be statement-position (`ifStatementKinds`
 * excludes an expression-position `if`) with NO `else` (an `else` branch the guard form
 * would lose) and a BRACED then-branch that
 *
 *  - is TERMINAL - its last statement unconditionally exits the block
 *    (`ControlFlowSupport.isTerminal`: `return` / `throw` / `break` / `continue`). Without
 *    it, falling off the end of the then-branch reached the trailing `return` in the
 *    original and would fall out of the enclosing block after the de-nest. A `break` /
 *    `continue` is sound too: de-nesting out of an `if` crosses no loop or `switch`
 *    boundary, so the jump keeps its target;
 *  - holds at least TWO statements. A one-statement then-branch
 *    (`if (c) { return a; } return b;`) is `prefer-ternary-return`'s shape - a turf split,
 *    not a correctness gate - and this check does not fight it.
 *
 * Additionally refused:
 *
 *  - a conditional-compilation region (`RefactorSupport.isConditionalKind`) anywhere in the
 *    rewritten span, or a `#` directive in the gap between the `if` and the `return`: the
 *    de-nested run changes indentation level, and a `#if` interior is preserved raw;
 *  - a comment in the dropped `if (` or `) {` glue, or in the gap between the `if` and the
 *    trailing `return`, or trailing the `return` on its own line - each would move away
 *    from what it documents. A comment INSIDE the condition, INSIDE the then-branch or
 *    INSIDE the returned expression rides along verbatim and does NOT refuse;
 *  - a top-level then-branch local whose name a PRECEDING sibling of the `if` already
 *    declares: de-nesting would turn a nested shadow into a same-scope re-declaration (a
 *    `-D no-shadowing` hazard). Unlike `guard-continue` this check refuses rather than
 *    auto-renaming - the shape has no tail to hoist and the collision is rare here.
 *
 * Every OTHER binding stays where it was: the de-nested statements land at the END of the
 * enclosing block, so nothing after them can bind to a widened local, and the moved
 * `return TAIL` sits AHEAD of every then-branch declaration, so it still reads the outer
 * binding it read before.
 *
 * ## Grammar-agnostic
 *
 * Driven by `ifStatementKinds`, the return kinds (`returnStatementKind` /
 * `valueReturnKinds` / `voidReturnKind`) and `ControlFlowSupport` (any unset -> no-op),
 * plus `localDeclKinds` / `localDeclExprKinds` and `MetaShape.metaKinds` (the collision
 * gate), `opaqueKinds` (skip macro reification), `logicalAndKind` / `logicalOrKind` (the
 * stranded-narrowing gate), and the `notKind` / `eqKind` / `notEqKind` / `parenKind` and
 * atomic-expression kinds that shape the inversion.
 */
@:nullSafety(Strict)
final class GuardReturn implements Check {

	/** A guard `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/**
	 * The fewest statements a de-nestable then-branch may hold. A ONE-statement branch is
	 * `prefer-ternary-return`'s shape (`if (c) return a;` + `return b;` → `return c ? a : b;`),
	 * left to that check.
	 */
	private static inline final MIN_THEN_STATEMENTS: Int = 2;

	/** The enclosing block must hold at least the flagged `if` and the trailing `return`. */
	private static inline final MIN_BLOCK_STATEMENTS: Int = 2;

	/** A binary logical node has exactly [left, right] children. */
	private static inline final BINARY_CHILD_COUNT: Int = 2;

	/** The shortest disjunction that can strand a narrowing: with two operands the first operand's fact always reaches the second. */
	private static inline final STRANDABLE_CHAIN_LENGTH: Int = 3;

	public function new() {}

	public function id(): String {
		return 'guard-return';
	}

	public function description(): String {
		return 'a trailing if whose terminal braced branch precedes a lone return, invertible to an early-return guard';
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

	/** Invert each flagged trailing `if` into an `if (!cond) return TAIL;` guard, de-nesting its then-branch. */
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
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (flow == null) return null;
		final returnKinds: Array<String> = [];
		for (k in [
			(shape.returnStatementKind: Null<String>),
			shape.voidReturnKind
		]) if (k != null && !returnKinds.contains(k)) returnKinds.push(k);
		for (k in shape.valueReturnKinds ?? []) if (!returnKinds.contains(k)) returnKinds.push(k);
		if (returnKinds.length == 0) return null;
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
			ifKinds: ifKinds,
			returnKinds: returnKinds,
			blockKinds: flow.blockKinds(),
			flow: flow,
			localDeclKinds: shape.localDeclKinds ?? [],
			localDeclExprKinds: shape.localDeclExprKinds ?? [],
			metaKinds: plugin.metaShape().metaKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			andKind: shape.logicalAndKind,
			orKind: shape.logicalOrKind,
			identKind: shape.identKind,
			negation: {
				notKind: shape.notKind,
				parenKind: shape.parenKind,
				eqKind: shape.eqKind,
				notEqKind: shape.notEqKind,
				atomicKinds: atomicKinds
			},
			logic: plugin.booleanLogicSupport()
		};
	}

	/** Walk `node`, flagging each block whose trailing `if` + `return` pair inverts into a guard. */
	private static function walk(node: QueryNode, out: Array<Violation>, file: String, source: String, s: Seams): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.blockKinds.contains(node.kind)) {
			final m: Null<Candidate> = match(node, source, s);
			if (m != null) {
				final span: Null<Span> = m.ifNode.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'guard-return',
					severity: Severity.Info,
					message: 'this trailing if can invert into an early-return guard'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, s);
	}

	/** Index every invertible block's candidate by its `if`'s `from:to` span key (for `fix` to re-find it). */
	private static function indexCandidates(node: QueryNode, source: String, s: Seams, out: Map<String, Candidate>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.blockKinds.contains(node.kind)) {
			final m: Null<Candidate> = match(node, source, s);
			if (m != null) {
				final span: Null<Span> = m.ifNode.span;
				if (span != null) out['${span.from}:${span.to}'] = m;
			}
		}
		for (c in node.children) indexCandidates(c, source, s, out);
	}

	/**
	 * If `block`'s last two statements are a bare `if (c) { … }` (no `else`, braced,
	 * terminal, ≥2 statements) and a lone trailing `return`, and every gate holds
	 * (conditional-compilation, comment, collision), return the pair; else null.
	 */
	private static function match(block: QueryNode, source: String, s: Seams): Null<Candidate> {
		final stmts: Array<QueryNode> = block.children;
		if (stmts.length < MIN_BLOCK_STATEMENTS) return null;
		final tail: QueryNode = stmts[stmts.length - 1];
		if (!s.returnKinds.contains(tail.kind)) return null;
		final ifNode: QueryNode = stmts[stmts.length - 2];
		if (!s.ifKinds.contains(ifNode.kind) || ifNode.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final cond: QueryNode = ifNode.children[0];
		final thenBlock: QueryNode = ifNode.children[1];
		if (!s.blockKinds.contains(thenBlock.kind) || thenBlock.children.length < MIN_THEN_STATEMENTS) return null;
		if (!s.flow.isTerminal(thenBlock.children[thenBlock.children.length - 1])) return null;
		if (hasConditionalRegion(ifNode) || hasConditionalRegion(tail)) return null;
		// The stranded-narrowing fallback re-emits `cond` VERBATIM, so a condition that
		// already spans lines becomes a nested multi-line `!( … )` wrap — worse to read
		// than the branch it would replace. Only that path is affected; a De-Morganed
		// multi-line condition still de-nests.
		if (narrowingStranded(cond, s) && spansLines(source, cond)) return null;
		final blocked: Bool = spanCommentBlocked(source, ifNode, cond, thenBlock, tail) || redeclaresSibling(block, ifNode, thenBlock, s);
		return blocked ? null : {
			ifNode: ifNode,
			thenBlock: thenBlock,
			cond: cond,
			tail: tail
		};
	}

	/** Whether `node`'s subtree holds a `#if … #end` region, whose raw-preserved interior the re-indenting de-nest must not move. */
	private static function hasConditionalRegion(node: QueryNode): Bool {
		if (RefactorSupport.isConditionalKind(node.kind)) return true;
		for (c in node.children) if (hasConditionalRegion(c)) return true;
		return false;
	}

	/**
	 * Whether a comment (or a `#` directive) sits anywhere the rewrite would move it away
	 * from what it documents: the dropped `if (` / `) {` glue, the gap between the `if` and
	 * the trailing `return`, or the rest of the `return`'s own line. Comments INSIDE the
	 * condition, the then-branch or the returned expression ride along verbatim.
	 */
	private static function spanCommentBlocked(
		source: String, ifNode: QueryNode, cond: QueryNode, thenBlock: QueryNode, tail: QueryNode
	): Bool {
		final ifSpan: Null<Span> = ifNode.span;
		final condSpan: Null<Span> = cond.span;
		final thenSpan: Null<Span> = thenBlock.span;
		final tailSpan: Null<Span> = tail.span;
		if (ifSpan == null || condSpan == null || thenSpan == null || tailSpan == null) return true;
		if (CheckScan.hasCommentMarker(source, ifSpan.from, condSpan.from)) return true;
		if (CheckScan.hasCommentMarker(source, condSpan.to, thenSpan.from)) return true;
		final gap: String = source.substring(ifSpan.to, tailSpan.from);
		if (gap.indexOf('#') != -1 || CheckScan.hasCommentMarker(source, ifSpan.to, tailSpan.from)) return true;
		final lineEnd: Int = source.indexOf('\n', tailSpan.to);
		return CheckScan.hasCommentMarker(source, tailSpan.to, lineEnd == -1 ? source.length : lineEnd);
	}

	/**
	 * Whether a top-level then-branch local re-declares a name a PRECEDING sibling of the
	 * `if` already binds in the enclosing block — de-nesting would widen the nested shadow
	 * into a same-scope re-declaration. Both sides resolve through `declaredNode`, so an
	 * expression-position declaration under a metadata wrapper counts too.
	 */
	private static function redeclaresSibling(block: QueryNode, ifNode: QueryNode, thenBlock: QueryNode, s: Seams): Bool {
		final scopeNames: Array<String> = [];
		for (stmt in block.children) {
			if (stmt == ifNode) break;
			final n: Null<String> = declaredNode(stmt, s)?.name;
			if (n != null && n != '') scopeNames.push(n);
		}
		if (scopeNames.length == 0) return false;
		for (stmt in thenBlock.children) {
			final n: Null<String> = declaredNode(stmt, s)?.name;
			if (n != null && scopeNames.contains(n)) return true;
		}
		return false;
	}

	/** The local declaration node a top-level statement holds, or null — see `RefactorSupport.topLevelDeclaredNode`. */
	private static function declaredNode(stmt: QueryNode, s: Seams): Null<QueryNode> {
		return RefactorSupport.topLevelDeclaredNode(stmt, s.localDeclKinds, s.localDeclExprKinds, s.metaKinds);
	}

	/**
	 * Replace the flagged `if` and the trailing `return` with an `if (!cond) return TAIL;`
	 * guard followed by the then-branch's inner statements (the writer re-indents the
	 * de-nested run).
	 */
	private static function editFor(m: Candidate, source: String, s: Seams): Null<{ span: Span, text: String }> {
		final ifSpan: Null<Span> = m.ifNode.span;
		final thenSpan: Null<Span> = m.thenBlock.span;
		final tailSpan: Null<Span> = m.tail.span;
		if (ifSpan == null || thenSpan == null || tailSpan == null) return null;
		// De Morgan strands a null-safety narrowing established in a NON-FIRST operand of the
		// resulting `||` chain, so such a condition takes the verbatim `!( … )` wrap instead.
		final logic: Null<BooleanLogicSupport> = narrowingStranded(m.cond, s) ? null : s.logic;
		final neg: String = CheckScan.negateConditionText(m.cond, source, s.negation, logic);
		final inner: String = StringTools.rtrim(source.substring(thenSpan.from + 1, thenSpan.to - 1));
		final tailSource: String = source.substring(tailSpan.from, tailSpan.to);
		return { span: new Span(ifSpan.from, tailSpan.to), text: 'if ($neg) $tailSource$inner' };
	}


	/**
	 * Whether De-Morganing `cond` would strand a Haxe null-safety narrowing. An `&&`
	 * chain negates into a flat left-associative `||` chain, and Haxe carries a
	 * narrowing fact into a later `||` operand from the chain's FIRST operand ONLY
	 * (measured on the compiler: in `a == null || b == null || p(a.length, b.length)`
	 * the `b` narrowing does not reach operand 3, while the `a` one does). The scan is
	 * syntactic and conservative - no type information: a negated `&&` chain strands
	 * when an operand at index 2 or later (0-based) shares a plain identifier with a
	 * preceding operand OTHER than the first. A `!` node is not descended: negating it
	 * STRIPS the `!` and re-emits its operand verbatim, restructuring nothing.
	 */
	private static function narrowingStranded(cond: QueryNode, s: Seams): Bool {
		final andKind: Null<String> = s.andKind;
		if (andKind == null) return false;
		if (cond.kind == s.negation.parenKind) return cond.children.length == 1 && narrowingStranded(cond.children[0], s);
		if (cond.kind == s.negation.notKind) return false;
		if (cond.kind != andKind && cond.kind != s.orKind) return false;
		final operands: Array<QueryNode> = [];
		flattenChain(cond, cond.kind, operands);
		if (cond.kind == andKind && chainStrands(operands, s)) return true;
		for (operand in operands) if (narrowingStranded(operand, s)) return true;
		return false;
	}

	/** Append the left-associative `kind` chain under `node` as a flat operand list. */
	private static function flattenChain(node: QueryNode, kind: String, out: Array<QueryNode>): Void {
		if (node.kind != kind || node.children.length != BINARY_CHILD_COUNT) {
			out.push(node);
			return;
		}
		flattenChain(node.children[0], kind, out);
		flattenChain(node.children[1], kind, out);
	}

	/**
	 * Whether the disjunction `operands` negates into would strand a narrowing: some
	 * operand at index 2 or later shares an identifier with a preceding operand that is
	 * not the first (whose fact alone survives the `||` chain).
	 */
	private static function chainStrands(operands: Array<QueryNode>, s: Seams): Bool {
		if (operands.length < STRANDABLE_CHAIN_LENGTH) return false;
		final names: Array<Array<String>> = [for (operand in operands) identNames(operand, s, [])];
		for (i in 2...operands.length) for (j in 1...i) for (name in names[i]) if (names[j].contains(name)) return true;
		return false;
	}

	/** Append every plain-identifier name in `node`'s subtree to `out` and return it. */
	private static function identNames(node: QueryNode, s: Seams, out: Array<String>): Array<String> {
		final name: Null<String> = node.name;
		if (node.kind == s.identKind && name != null && name != '' && !out.contains(name)) out.push(name);
		for (child in node.children) identNames(child, s, out);
		return out;
	}


	/** Whether `node`'s source spans more than one line. */
	private static function spansLines(source: String, node: QueryNode): Bool {
		final span: Null<Span> = node.span;
		return span != null && source.substring(span.from, span.to).indexOf('\n') != -1;
	}

}

/** The `RefShape` kinds `GuardReturn` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var returnKinds: Array<String>;
	var blockKinds: Array<String>;
	var flow: ControlFlowSupport;
	var localDeclKinds: Array<String>;
	var localDeclExprKinds: Array<String>;
	var metaKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var andKind: Null<String>;
	var orKind: Null<String>;
	var identKind: String;
	var negation: NegationSeams;
	var logic: Null<BooleanLogicSupport>;
}

/**
 * A matched guard pair: the trailing `if` statement, its braced terminal then-branch, its
 * condition, and the lone `return` that follows it.
 */
private typedef Candidate = {
	var ifNode: QueryNode;
	var thenBlock: QueryNode;
	var cond: QueryNode;
	var tail: QueryNode;
}
