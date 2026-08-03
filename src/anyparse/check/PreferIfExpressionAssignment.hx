package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.IfExpressionChain.IfChain;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.check.AssignmentTreeHoist.TreeSeams;
import anyparse.check.AssignmentTreeHoist.LvalueRef;
import anyparse.check.AssignmentTreeHoist.UnitValue;
import anyparse.check.IfExpressionChain.Carried;

/**
 * Flags an `if / else if / … / else` CHAIN, or a 2-branch `if`/`else` carrying a nested
 * construct, whose EVERY branch assigns the SAME l-value with a plain `=`, collapsing it to
 * one assignment of an if-expression:
 *
 * ```haxe
 * if (cond)   button.x = a;
 * else if (d) button.x = b;
 * else        button.x = c;
 * // ->
 * button.x = if (cond) a else if (d) b else c;
 * ```
 *
 * Branches nest RECURSIVELY: a branch that is itself a `switch` / `if`-chain (all assigning
 * the same l-value) becomes that branch's VALUE, so
 * `if (c) x = a; else switch s { case p: x = b; case _: x = c; }` collapses to
 * `x = if (c) a else switch s { case p: b; case _: c; };` (see `AssignmentTreeHoist`).
 *
 * Purely structural (no type information), so it holds without a type-checker. `Info` --
 * the code is correct, this is a readability simplification.
 *
 * ## Boundary with `prefer-ternary-assignment`
 *
 * `prefer-ternary-assignment` handles a FLAT 2-branch `if`/`else` (its `else` is NOT an `if`,
 * both branches a plain assignment) and emits a ternary. This rule handles the CHAIN (≥1
 * `else if`, terminating in a plain `else`) AND a 2-branch `if`/`else` whose branches are not
 * both plain assignments -- one is a nested `switch` / `if`-chain construct a ternary cannot
 * express. So a flat 2-branch stays the ternary rule's; a 2-branch carrying a nested construct
 * is this rule's. A given `if` matches at most one of the two.
 *
 * ## What is flagged
 *
 * A chain HEAD (an `if` that is not itself the `else if` link of another) whose:
 *
 * - else-nesting terminates in a plain `else` (no final `else` yields no value on the missing
 *   path and is skipped -- `IfExpressionChain.collect`);
 * - every branch AND the terminal is a single HOISTABLE UNIT (`AssignmentTreeHoist`) -- either
 *   a bare `lhs = e;` / braced `{ lhs = e; }` PLAIN `=` assignment, or (RECURSIVELY) a nested
 *   `switch` (every arm a hoistable unit, a source default arm) / `if`-chain (a final `else`,
 *   every branch a hoistable unit) whose value becomes that branch's value. A multi-statement
 *   block is deliberately grouped and never a unit;
 * - the assignments are PLAIN `=` (`assignKind`). Compound operators are deliberately EXCLUDED:
 *   a short-circuit `??=` would change behaviour (its r-value, now holding the conditions, is
 *   skipped when the l-value is non-null, so the conditions stop being evaluated), and an
 *   ordinary compound (`+=`, …) whose branch values do not unify to one type (`s += anInt` vs
 *   `s += "text"`) compiles per-branch but not as one if-expression. Plain `=` flows the
 *   l-value's type into every branch, sidestepping both;
 * - all l-values are TEXTUALLY IDENTICAL (whitespace-normalized source);
 * - no NON-TERMINAL branch holds an else-less conditional. The collapse emits a ` else ` after
 *   every branch value but the last, and an `if` without its own `else` ends an expression OPEN,
 *   so it ABSORBS that ` else ` and the rest of the chain silently becomes its else branch --
 *   output that still parses, so the `--fix` re-parse gate would wave it through. The gate lives
 *   in `AssignmentTreeHoist.ifChainValue` (the single ` else `-emitting point, so it covers the
 *   top-level chain, every nested chain, and the switch rule's nested chains too) and scans via
 *   the shared `IfExpressionChain.holdsElseLessConditional`. It scans the branch STATEMENT, which
 *   subsumes every value the recursion copies; the TERMINAL branch is EXEMPT from THAT scan, since
 *   nothing the rebuild emits follows it;
 * - no leaf r-value is an else-less conditional at its ROOT. A narrower refusal with a span cause
 *   rather than a re-parenting one, and it applies to the terminal and to a nested switch arm too:
 *   the parser folds a statement's own `;` INTO such a conditional, so copying `x = if (q) 2;`'s
 *   r-value into a chain terminal or a ` case h: <v>;` arm writes `…;;` -- which anyparse re-parses
 *   but Haxe rejects. It lives in `AssignmentTreeHoist.unitValue`, the single point a leaf r-value
 *   becomes emitted text, so it covers this rule and `prefer-switch-expression-assignment` at once.
 *   ROOT-only: `x = g(if (q) 2)` cannot swallow the terminator and stays claimable.
 *
 * ## Comments
 *
 * A comment between a branch's condition and its r-value, or after that r-value with nothing
 * but the branch's own `;` / `}` in between, rides that branch's slot in the rebuilt chain and
 * keeps its position (`IfExpressionChain.carriedComments`; the seats come from
 * `AssignmentTreeHoist.ifChainValue`, so a NESTED chain's branches open slots too). Every other
 * comment inside the folded region -- past the `else` that opens the next branch, a header
 * keyword, the braces, a non-head l-value, or the interior of a branch whose value is a nested
 * `switch` / `if` construct rather than one copied r-value -- still leaves the chain unflagged,
 * because there is no slot that would keep it saying what it said.
 *
 * Unlike the ternary sibling NO null-narrowing guard is needed -- the collapsed `if (…)`
 * conditions are verbatim, so each branch keeps exactly the narrowing it had (see
 * `IfExpressionChain`). The reported span is the whole head `if`.
 *
 * ## Autofix
 *
 * `fix` replaces the head `if` with `lhs = if (c1) v1 else if (c2) v2 … else vN;`, each value
 * the recursive hoist of its branch (a plain r-value, or a nested switch- / if-expression). The
 * l-value is copied from the leftmost leaf and the conditions / values from their spans, so the
 * one surviving l-value evaluation (down from N textual occurrences -- the safe direction)
 * matches the original exactly. The hoist runs TWICE: the first pass reports which spans are
 * copied and where the comment slots sit, the second re-emits with the classified comments
 * welded in -- pure text assembly over the same tree, byte-identical to the first when nothing
 * is carried. Needs `ifStatementKinds`, `exprStatementKind`, `blockStmtKind`, `assignKind` and
 * the switch-machinery kinds (`AssignmentTreeHoist`; any unset makes it a no-op or disables
 * that nesting).
 */
@:nullSafety(Strict)
final class PreferIfExpressionAssignment implements Check {

	/** A real chain is a head plus at least one `else if` -- a 2-branch `if`/`else` (one branch) is `prefer-ternary-assignment`'s. */
	private static inline final MIN_CHAIN_BRANCHES: Int = 2;

	public function new() {}

	public function id(): String {
		return 'prefer-if-expression-assignment';
	}

	public function description(): String {
		return 'an if/else-if chain assigning the same l-value in every branch, collapsible to a single if-expression assignment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(entry.source);
			walk(tree, violations, entry.file, entry.source, comments, seams);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final edits: Array<{ span: Span, text: String }> =
			CheckScan.applyBySpan(plugin, source, violations, seams.ifKinds, (node, span) -> {
				final m: Null<Match> = match(node, source, comments, seams);
				return m == null ? null : buildEdit(m, source, span);
			});
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final tree: Null<TreeSeams> = AssignmentTreeHoist.readTreeSeams(shape);
		if (tree == null) return null;
		final ifKinds: Null<Array<String>> = tree.ifKinds;
		return ifKinds == null || ifKinds.length == 0 ? null : { ifKinds: ifKinds, tree: tree };
	}

	/** Walk `node`, flagging each chain HEAD whose branches all assign the same l-value with the same operator. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, ?parent: QueryNode
	): Void {
		if (s.ifKinds.contains(node.kind) && !IfExpressionChain.isElseIfLink(node, parent, s.ifKinds)) {
			final m: Null<Match> = match(node, source, comments, s);
			if (m != null) {
				final span: Null<Span> = node.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'prefer-if-expression-assignment',
					severity: Severity.Info,
					message: 'this if/else-if assignment chain can be a single if-expression assignment'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, comments, s, node);
	}

	/**
	 * If `head` is a chain of same-l-value / same-operator single-assignment branches and no
	 * comment sits in a dropped region, return the match parts; else null.
	 */
	private static function match(
		head: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final chain: Null<IfChain> = IfExpressionChain.collect(head, s.ifKinds, s.tree.blockStmtKind, 1);
		if (chain == null) return null;
		// Disjointness with `prefer-ternary-assignment`: a FLAT 2-branch `if`/`else` (both plain-assign
		// leaves) is the ternary rule's; claim a 2-branch only when a branch is a nested construct.
		if (chain.branches.length < MIN_CHAIN_BRANCHES && !AssignmentTreeHoist.chainHasConstruct(chain, s.tree)) return null;
		final ref: LvalueRef = { lvalue: null };
		final probe: Null<UnitValue> = AssignmentTreeHoist.ifChainValue(chain, ref, source, s.tree);
		if (probe == null) return null;
		final lvalue: Null<QueryNode> = ref.lvalue;
		final headSpan: Null<Span> = head.span;
		if (lvalue == null || headSpan == null) return null;
		final kept: Array<Span> = probe.kept.copy();
		final lvalueSpan: Null<Span> = lvalue.span;
		if (lvalueSpan != null) kept.push(lvalueSpan);
		// Two passes over the SAME chain: the first reports which spans the rebuild copies and
		// where its comment slots sit, the second re-emits with the classified comments welded in.
		// The recursion is pure text assembly over one tree, so the second pass cannot see a
		// different chain -- and with an empty carry the two are byte-identical.
		final carried: Null<Carried> = IfExpressionChain.carriedComments(headSpan, kept, probe.gaps, source, comments);
		if (carried == null) return null;
		final unit: Null<UnitValue> = AssignmentTreeHoist.ifChainValue(chain, ref, source, s.tree, carried);
		return unit == null ? null : { lvalue: lvalue, value: unit.text };
	}


	/** Build the `lhs op if (c1) rhs1 else if (c2) rhs2 … else rhsN;` edit replacing the whole head-`if` span. */
	private static function buildEdit(m: Match, source: String, span: Span): Null<{ span: Span, text: String }> {
		final lvalueSrc: Null<String> = AssignmentTreeHoist.slice(source, m.lvalue);
		return lvalueSrc == null ? null : { span: span, text: '$lvalueSrc = ${m.value};' };
	}

}

/** The `RefShape` kinds `PreferIfExpressionAssignment` reads. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var tree: TreeSeams;
}

/** A matched assignment chain: the head assignment (for the prefix), the (condition, r-value) pairs, the terminal r-value. */
private typedef Match = {
	var lvalue: QueryNode;
	var value: String;
}
