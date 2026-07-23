package anyparse.check;

import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * A recognised `if / else if / … / else` CHAIN of single-statement branches: the
 * per-branch `(condition, statement)` pairs and the terminal `else`'s statement. The
 * chain is what the two if-expression collapse rules
 * (`prefer-if-expression-assignment` / `prefer-if-expression-return`) rewrite; this
 * shape is what they SHARE. `branches` holds the head `if` and every `else if` (so
 * `branches.length >= 2` for a real chain — a 2-branch `if`/`else` is not one, and is
 * left to the ternary rules), `terminal` is the final `else`'s statement.
 */
typedef IfChain = {
	var branches: Array<{ cond: QueryNode, stmt: QueryNode }>;
	var terminal: QueryNode;
}

/**
 * Machinery shared by `prefer-if-expression-assignment` and
 * `prefer-if-expression-return`: recognising an `if`-chain of single-statement branches
 * and assembling the collapsed `if (c1) v1 else if (c2) v2 … else vN` text. The rules
 * differ only in what each branch's statement must be (an assignment to the same l-value
 * vs a valued `return`) and in the copied prefix (`lhs op ` vs `return `); everything
 * structural lives here.
 *
 * Unlike the ternary siblings, no null-narrowing guard is needed: the collapsed form is
 * an `if`-EXPRESSION whose conditions are the verbatim `if (…)` conditions, so a branch
 * runs under EXACTLY the narrowing it had as a statement — the transformation is
 * null-safety-preserving by construction.
 */
@:nullSafety(Strict)
final class IfExpressionChain {

	/** An `if` with an `else` has exactly [condition, then-branch, else-branch] children. */
	private static inline final IF_ELSE_CHILD_COUNT: Int = 3;

	/** A real chain is a head plus at least one `else if` — a 2-branch `if`/`else` (one branch) is left to the ternary rules. */
	private static inline final MIN_CHAIN_BRANCHES: Int = 2;

	/**
	 * Recognise the chain rooted at `head`: follow the else-nesting (`children[2]` being
	 * another `if`) to the terminal plain `else`, collecting each branch's single
	 * statement. Returns null unless it IS a chain (≥1 `else if`) that TERMINATES in a
	 * plain `else` and every branch plus the terminal is a single statement — a chain
	 * with no final `else` yields no if-expression value on the missing path and is
	 * rejected. Rule-agnostic: the branch statements are returned raw, not inspected.
	 */
	public static function collect(head: QueryNode, ifKinds: Array<String>, blockStmtKind: String): Null<IfChain> {
		final branches: Array<{ cond: QueryNode, stmt: QueryNode }> = [];
		var current: QueryNode = head;
		while (true) {
			if (current.children.length != IF_ELSE_CHILD_COUNT) return null; // no `else` -> not collapsible
			final thenStmt: Null<QueryNode> = singleStmt(current.children[1], blockStmtKind);
			if (thenStmt == null) return null;
			branches.push({ cond: current.children[0], stmt: thenStmt });
			final elseBranch: QueryNode = current.children[2];
			if (ifKinds.contains(elseBranch.kind)) {
				current = elseBranch; // `else if` -> continue the chain
			} else {
				final terminal: Null<QueryNode> = singleStmt(elseBranch, blockStmtKind);
				if (terminal == null) return null;
				return branches.length >= MIN_CHAIN_BRANCHES ? { branches: branches, terminal: terminal } : null;
			}
		}
	}

	/**
	 * The one statement a branch holds — a bare statement, or the sole child of a
	 * `{ … }` wrapping EXACTLY one. Null when the branch is a block of zero or several
	 * statements (a deliberately grouped body is never collapsed).
	 */
	private static function singleStmt(branch: QueryNode, blockStmtKind: String): Null<QueryNode> {
		if (branch.kind == blockStmtKind) return branch.children.length == 1 ? branch.children[0] : null;
		return branch;
	}

	/**
	 * Whether `node` is an `else if` LINK — the else-branch (`children[2]`) of a parent
	 * `if`. Only a chain HEAD is flagged; a link is part of the head's chain and is
	 * skipped when the walk reaches it on its own.
	 */
	public static function isElseIfLink(node: QueryNode, parent: Null<QueryNode>, ifKinds: Array<String>): Bool {
		return parent != null && ifKinds.contains(parent.kind) && parent.children.length == IF_ELSE_CHILD_COUNT && parent.children[2]
			== node;
	}

	/** Whether two subtrees have identical whitespace-normalized source — the l-value equality key. */
	public static function sameSource(a: QueryNode, b: QueryNode, source: String): Bool {
		final aSpan: Null<Span> = a.span;
		final bSpan: Null<Span> = b.span;
		return aSpan != null && bSpan != null
			&& normalize(source.substring(aSpan.from, aSpan.to)) == normalize(source.substring(bSpan.from, bSpan.to));
	}

	/** Collapse whitespace runs to a single space and trim. */
	private static function normalize(s: String): String {
		return StringTools.trim((~/\s+/g).replace(s, ' '));
	}

	/**
	 * Assemble `${prefix}if (c1) v1 else if (c2) v2 … else vTerminal;` from verbatim
	 * condition / value source slices. No condition parentheses are added — the
	 * `if (…)` syntax already delimits each condition.
	 */
	public static function buildText(prefix: String, pairs: Array<{ cond: String, value: String }>, terminalValue: String): String {
		final buf: StringBuf = new StringBuf();
		buf.add(prefix);
		for (i in 0...pairs.length) {
			if (i > 0) buf.add(' else ');
			buf.add('if (${pairs[i].cond}) ${pairs[i].value}');
		}
		buf.add(' else $terminalValue;');
		return buf.toString();
	}

	/**
	 * Whether a comment sits inside the collapsed `if` region `[headSpan.from, headSpan.to)`
	 * but outside every verbatim-copied span (`kept`: the head prefix, each condition, each
	 * value). Such a comment would be dropped by the rebuild — the header keywords, the
	 * braces and the non-head l-values / `return`s all go away — so the finding is skipped
	 * rather than silently losing it.
	 */
	public static function droppedComment(headSpan: Span, kept: Array<Span>, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Bool {
		for (tok in comments) if (tok.from >= headSpan.from && tok.to <= headSpan.to) {
			var inside: Bool = false;
			for (k in kept) if (tok.from >= k.from && tok.to <= k.to) {
				inside = true;
				break;
			}
			if (!inside) return true;
		}
		return false;
	}

}
