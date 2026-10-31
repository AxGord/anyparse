package anyparse.check.common.control;

using StringTools;

/**
 * The grammar seams the brace rules share: the chain's `if` kinds, and what `BranchChain.selfTerminated` reads to
 * decide whether a statement closes on a terminator of its own.
 */
typedef ChainSeams = {
	/** `RefShape.ifStatementKinds`: statement-position `if`s, the links of a chain. */
	final ifKinds: Array<String>;

	/** `RefShape.statementTerminator`; unset, nothing reads as terminated by text. */
	final terminator: Null<String>;

	/** `RefShape.blockStmtKind`: a block closes on its own `}`. */
	final blockStmtKind: String;

	/** Statements closed by a brace of their own whatever their content: `RefShape.switchStatementKinds`. */
	final braceClosedKinds: Array<String>;

	/** Statements that close the way their LAST child does: the `if`, loop, `try` and `catch` kinds. */
	final lastChildClosedKinds: Array<String>;
};

/**
 * The if / else-if CHAIN and the statement-closing question the brace rules share. `asymmetric-branch-braces` braces
 * a chain's bare branches and `redundant-braces` strips a chain's braces; both read the chain's links and whether a
 * branch statement closes on its own here, so the two never disagree about one chain.
 */
@:nullSafety(Strict)
final class BranchChain {

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	/** The else branch is the third child of an if node - `[cond, then, else]`. */
	private static inline final ELSE_BRANCH_INDEX: Int = 2;

	/** The else branch of `node` when it is an `if` (one of `ifKinds`) with one, else null. */
	public static function elseOf(node: QueryNode, ifKinds: Array<String>): Null<QueryNode> {
		return ifKinds.contains(node.kind) && node.children.length == IF_WITH_ELSE_CHILD_COUNT ? node.children[ELSE_BRANCH_INDEX] : null;
	}

	/** The links of the chain `head` starts: `head`, then every `if` down its else-if spine. */
	public static function linksFrom(head: QueryNode, ifKinds: Array<String>): Array<QueryNode> {
		final links: Array<QueryNode> = [head];
		var next: Null<QueryNode> = elseOf(head, ifKinds);
		while (next != null && ifKinds.contains(next.kind)) {
			links.push(next);
			next = elseOf(next, ifKinds);
		}
		return links;
	}

	/**
	 * Whether `node` closes on a terminator of its own, so it parses as one statement wherever it stands: its text ends
	 * in the grammar's statement terminator, or it is a block or a `switch` statement (closed by its own `}`), or an
	 * `if` / loop / `try` / `catch` whose LAST child closes so in turn - `for (c in s) { … }` does, `for (c in s) p()`
	 * does not. Anything else - an expression that merely ends in a brace, a conditional-compilation region - answers
	 * false.
	 */
	public static function selfTerminated(node: QueryNode, source: String, seams: ChainSeams): Bool {
		final span: Null<Span> = node.span;
		final terminator: Null<String> = seams.terminator;
		if (span == null || terminator == null) return false;
		if (source.substring(span.from, span.to).rtrim().endsWith(terminator)) return true;
		if (node.kind == seams.blockStmtKind || seams.braceClosedKinds.contains(node.kind)) return true;
		final last: Null<QueryNode> = node.children.length == 0 ? null : node.children[node.children.length - 1];
		return last != null && seams.lastChildClosedKinds.contains(node.kind) && selfTerminated(last, source, seams);
	}

	/** The `ChainSeams` of `shape`, or null when it names no statement-position `if` kind or no block-statement kind. */
	public static function chainSeams(shape: RefShape): Null<ChainSeams> {
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final catchKind: Null<String> = shape.catchClauseKind;
		return ifKinds.length == 0 || blockStmtKind == null ? null : {
			ifKinds: ifKinds,
			terminator: shape.statementTerminator,
			blockStmtKind: blockStmtKind,
			braceClosedKinds: shape.switchStatementKinds ?? [],
			lastChildClosedKinds: ifKinds.concat(shape.loopStatementKinds ?? [])
				.concat(shape.tryStatementKinds ?? [])
				.concat(catchKind == null ? [] : [catchKind])
		};
	}

}
