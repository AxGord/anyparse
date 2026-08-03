package anyparse.check;

import anyparse.query.GrammarPlugin.RefShape;
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
 *
 * Two hazards of EMITTING that ` else ` reach further than the chain shape does:
 * `prefer-if-expression-chain` rewrites a nested TERNARY rather than an `if` chain, yet
 * assembles the same text and so runs the same risks. `holdsElseLessConditional` (a branch
 * value that would ABSORB the emitted ` else `) and `tokenSpan` (a copied span that would
 * SWALLOW the trailing comment after its last token) therefore live here too, and all three
 * rules share them.
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
	public static function collect(head: QueryNode, ifKinds: Array<String>, blockStmtKind: String, ?minBranches: Int): Null<IfChain> {
		final min: Int = minBranches ?? MIN_CHAIN_BRANCHES;
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
				return branches.length >= min ? { branches: branches, terminal: terminal } : null;
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
		return '$prefix${buildValue(pairs, terminalValue)};';
	}

	/**
	 * Assemble `if (c1) v1 else if (c2) v2 … else vTerminal` (no prefix, no trailing `;`) — the
	 * if-EXPRESSION VALUE form used both as a statement's r-value (via `buildText`, which wraps it
	 * with a prefix and a terminating `;`) and, recursively, as the branch / arm value of an
	 * enclosing assignment-tree hoist.
	 */
	public static function buildValue(pairs: Array<{ cond: String, value: String }>, terminalValue: String): String {
		final buf: StringBuf = new StringBuf();
		for (i in 0...pairs.length) {
			if (i > 0) buf.add(' else ');
			buf.add('if (${pairs[i].cond}) ${pairs[i].value}');
		}
		buf.add(' else $terminalValue');
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


	/**
	 * Every `if` form the grammar has — the expression kinds and the statement kinds together.
	 * This is the set the else-less scan below must recognise, and it is deliberately BOTH: an
	 * else-less conditional of either kind absorbs a ` else ` emitted after it, and a rule that
	 * emits one cannot afford to know only the kind its own construct is written in (a
	 * statement-position `if` reaches an expression branch value through a block unwrap, and an
	 * if-EXPRESSION is a legal branch statement).
	 */
	public static function conditionalKinds(shape: RefShape): Array<String> {
		return (shape.ifExpressionKinds ?? []).concat(shape.ifStatementKinds ?? []);
	}

	/**
	 * Whether `node` ITSELF is a conditional with no else-slot (fewer children than the
	 * `[condition, then, else]` an `if`/`else` has). The one definition of "else-less"; the
	 * subtree scan below and the terminal gates in the statement-side rules both ask it, so they
	 * cannot drift apart on what counts.
	 */
	public static function isElseLessConditional(node: QueryNode, conditionalKinds: Array<String>): Bool {
		return conditionalKinds.contains(node.kind) && node.children.length < IF_ELSE_CHILD_COUNT;
	}

	/**
	 * Whether `node`'s subtree holds an else-less conditional anywhere. Such a construct ends an
	 * expression OPEN: the ` else ` the collapse rules emit after a NON-TERMINAL branch value
	 * re-parents onto it, turning the rest of the chain into that `if`'s else branch — a silent
	 * behaviour change whose output still PARSES, so the `--fix` re-parse gate would wave it
	 * through. (Verified on 4.3.7 with a `Void`-typed carrier, where the input is legal Haxe: the
	 * collapse changes what runs for every input combination and still compiles.)
	 *
	 * The whole subtree is scanned rather than only its right spine: an else-less `if` in a
	 * delimited interior (a call argument, a paren) is harmless, but proving WHICH is which
	 * costs more than the rare cleanup it buys, and the answer to any uncertainty is skip.
	 *
	 * The TERMINAL branch value is EXEMPT from THIS scan, and that is a fact about the PARSE
	 * rather than an omission: an `else` that could have followed the chain was already bound
	 * INTO the terminal, which would have made it one more link. The per-level exemption
	 * survives NESTING for one reason worth stating outright, because it is not obvious — at
	 * every OUTER level the caller scans the branch's WHOLE STATEMENT subtree, which SUBSUMES
	 * any nested chain's own exempted terminal. So a nested chain whose terminal ends in an
	 * else-less `if` is exempt where nothing follows it, and still refused by the level whose
	 * ` else ` would actually re-parent onto it.
	 *
	 * A terminal is exempt from RE-PARENTING only. The statement-side rules apply the ROOT-only
	 * `isElseLessConditional` to it separately, for the unrelated span reason documented there.
	 */
	public static function holdsElseLessConditional(node: QueryNode, conditionalKinds: Array<String>): Bool {
		if (isElseLessConditional(node, conditionalKinds)) return true;
		for (child in node.children) if (holdsElseLessConditional(child, conditionalKinds)) return true;
		return false;
	}

	/**
	 * `span` with its trailing TRIVIA cut off — an expression node's span runs on past its last
	 * token, through the whitespace and any comment that follows, up to the next construct's
	 * start. Two things depend on the tight end: the copied text (a trailing `// …` inside a raw
	 * slice would comment out whatever the rebuild welds after it, and even a block comment
	 * would arrive re-indented into a position the author did not write), and the replaced
	 * region, whose loose end would splice away spacing the author wrote.
	 *
	 * Cutting the comment out of the KEPT span is also what makes `droppedComment` see it: a
	 * token now outside every kept span is one the rebuild would drop, so the site is skipped
	 * instead of being emitted with the comment in a new place.
	 */
	public static function tokenSpan(span: Span, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Span {
		var end: Int = span.to;
		var shrunk: Bool = true;
		while (shrunk) {
			shrunk = false;
			while (end > span.from && isTrailingSpace(source, end - 1)) {
				end--;
				shrunk = true;
			}
			for (token in comments) if (token.to == end && token.from >= span.from) {
				end = token.from;
				shrunk = true;
				break;
			}
		}
		return new Span(span.from, end);
	}

	/** Whether `source[at]` is whitespace — the trivia `tokenSpan` walks back over. */
	private static inline function isTrailingSpace(source: String, at: Int): Bool {
		final c: Int = StringTools.fastCodeAt(source, at);
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

}
