package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.IfExpressionChain.IfChain;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `if / else if / … / else` CHAIN whose EVERY branch is a valued `return`,
 * collapsing the whole chain to one `return` of an if-expression:
 *
 * ```haxe
 * if (cond)   return a;
 * else if (d) return b;
 * else        return c;
 * // ->
 * return if (cond) a else if (d) b else c;
 * ```
 *
 * Purely structural, so it holds without a type-checker. `Info` -- the code is correct,
 * this is a readability simplification. The `return` sibling of
 * `prefer-if-expression-assignment`; see it and `IfExpressionChain` for the chain shape,
 * the single-statement rule, the dropped-comment guard and why no null-narrowing guard is
 * needed.
 *
 * ## Boundary with `prefer-ternary-return`
 *
 * Disjoint. `prefer-ternary-return` collapses an `if (c) return a; return b;` (an
 * if/return followed by a fall-through return) to a ternary. This rule collapses ONLY an
 * explicit `if / else if / … / else` chain (≥1 `else if`, terminating in a plain `else`)
 * of `return`s, to an if-expression.
 *
 * ## What is flagged
 *
 * A chain HEAD whose else-nesting terminates in a plain `else`, every branch AND the
 * terminal is exactly ONE valued `return` statement (a bare `return;` -- a distinct
 * node kind -- disqualifies). The reported span is the whole head `if`. Two further gates
 * guard the ` else ` this rule EMITS, and are shared with the sibling collapse rules
 * (`IfExpressionChain`):
 *
 * - **No else-less conditional in a NON-TERMINAL branch value.** The emitted ` else ` follows
 *   every returned value but the last, and an `if` without its own `else` ends an expression
 *   OPEN, so it ABSORBS it. `if (a) { return if (q) 1; } else if (b) return 2; else return 3;`
 *   would emit `return if (a) if (q) 1 else if (b) 2 else 3;`, where `else if (b) 2 else 3`
 *   has become the INNER `if`'s else branch and the outer condition has lost its else
 *   entirely. The braces are what let the source `else` bind outward in the first place, and
 *   the single-statement unwrap (`IfExpressionChain.singleStmt`) is what re-exposes the
 *   else-less tail; the output still re-parses, so the `--fix` re-parse gate would wave it
 *   through. The whole value subtree is scanned, not only its right spine -- proving which
 *   else-less `if` sits in a delimited interior costs more than the rare cleanup it buys. The
 *   TERMINAL value is EXEMPT from THIS scan: nothing follows it but the emitted `;`, so nothing
 *   can re-parent onto it.
 * - **No else-less conditional at the TERMINAL value's ROOT.** A separate, narrower refusal with
 *   a span cause rather than a re-parenting one: the parser folds a statement's own `;` INTO an
 *   else-less conditional, so the terminal of `else return if (q) 3;` spans `if (q) 3;` and the
 *   rebuild appends its own `;`, writing `return … else if (q) 3;;`. anyparse re-parses that, so
 *   the `--fix` gate passes it, but Haxe rejects it (`Expected }` on 4.3.7) -- and the input IS
 *   legal Haxe whenever the carrier is `Void`-typed, so the fix turns working code into code that
 *   does not compile. ROOT-only on purpose: a delimited-interior conditional (`return g(if (q) 3)`)
 *   cannot swallow the terminator, and stays claimable. `prefer-if-expression-chain` needs neither
 *   check on its terminal -- a ternary rung is an expression with no statement terminator to fold.
 * - **No comment in a dropped region.** The header keywords, the braces and every non-head
 *   `return ` go away, so a comment sitting there would be lost and the finding is skipped
 *   instead, per the family's fail-closed guard. Each copied span is first cut back to its
 *   last TOKEN (`IfExpressionChain.tokenSpan`) -- a node's span runs on through the trivia
 *   after it, so `return u + v // why` hands back a value span that SWALLOWS the comment.
 *   Trimming both moves the comment out of the copied text and makes the guard see it as
 *   dropped, which is the only reason it fires there at all.
 *
 * ## Autofix
 *
 * `fix` replaces the head `if` with `return if (c1) a else if (c2) b … else n;` -- the
 * `return ` prefix copied from the head, the conditions and returned values from their
 * spans, each cut back to its last token. `Match` carries those TRIMMED SPANS rather than
 * nodes, so the text `buildEdit` copies and the region `droppedComment` reports as kept
 * cannot drift apart. Needs `ifStatementKinds`, `returnStatementKind`, `blockStmtKind` (any
 * unset makes it a no-op).
 */
@:nullSafety(Strict)
final class PreferIfExpressionReturn implements Check {

	/** A valued `return` node has exactly one child: the returned expression. */
	private static inline final RETURN_VALUE_CHILD_COUNT: Int = 1;

	public function new() {}

	public function id(): String {
		return 'prefer-if-expression-return';
	}

	public function description(): String {
		return 'an if/else-if chain returning in every branch, collapsible to a single if-expression return';
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
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		if (ifKinds == null || ifKinds.length == 0) return null;
		final returnKind: Null<String> = shape.returnStatementKind;
		if (returnKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		return blockStmtKind == null ? null : {
			ifKinds: ifKinds,
			returnKind: returnKind,
			blockStmtKind: blockStmtKind,
			conditionalKinds: IfExpressionChain.conditionalKinds(shape)
		};
	}

	/** Walk `node`, flagging each chain HEAD whose branches all return a value. */
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
					rule: 'prefer-if-expression-return',
					severity: Severity.Info,
					message: 'this if/else-if return chain can be a single if-expression return'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, comments, s, node);
	}

	/**
	 * If `head` is a chain of single valued-`return` branches, no branch value would absorb the
	 * emitted ` else `, and no comment sits in a dropped region, return the match parts; else
	 * null. Every copied piece is cut back to its last token here, so `buildEdit` and
	 * `droppedComment` see the same spans.
	 */
	private static function match(
		head: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		final chain: Null<IfChain> = IfExpressionChain.collect(head, s.ifKinds, s.blockStmtKind);
		if (chain == null) return null;
		final headSpan: Null<Span> = head.span;
		final headReturnSpan: Null<Span> = chain.branches[0].stmt.span;
		if (headSpan == null || headReturnSpan == null) return null;
		final pairs: Array<{ cond: Span, value: Span }> = [];
		for (b in chain.branches) {
			final v: Null<QueryNode> = returnValue(b.stmt, s);
			if (v == null) return null;
			// The emitted ` else ` follows every NON-terminal value, and only an else-less
			// conditional can absorb it -- the rest of the chain would silently become that `if`'s
			// else branch, and the result re-parses, so the `--fix` gate would wave it through.
			if (IfExpressionChain.holdsElseLessConditional(v, s.conditionalKinds)) return null;
			final rawCond: Null<Span> = b.cond.span;
			final rawValue: Null<Span> = v.span;
			if (rawCond == null || rawValue == null) return null;
			pairs.push({
				cond: IfExpressionChain.tokenSpan(rawCond, source, comments),
				value: IfExpressionChain.tokenSpan(rawValue, source, comments)
			});
		}
		final terminal: Null<QueryNode> = returnValue(chain.terminal, s);
		if (terminal == null) return null;
		final rawTerminal: Null<Span> = terminal.span;
		if (rawTerminal == null) return null;
		// The terminal is exempt from RE-PARENTING (nothing the rebuild emits follows it but the
		// closing `;`), but not from the span: the parser folds a statement's own `;` INTO an
		// else-less conditional at the value's ROOT, so copying `if (q) 3;` and appending the
		// rebuild's `;` writes `…3;;` — which anyparse re-parses but Haxe rejects. Root-ONLY: a
		// delimited-interior one (`g(if (q) 3)`) cannot swallow the terminator and stays claimable.
		if (IfExpressionChain.isElseLessConditional(terminal, s.conditionalKinds)) return null;
		final m: Match = {
			prefix: new Span(headReturnSpan.from, pairs[0].value.from),
			pairs: pairs,
			terminalValue: IfExpressionChain.tokenSpan(rawTerminal, source, comments)
		};
		return droppedComment(headSpan, m, comments) ? null : m;
	}

	/** The returned expression of `stmt` when it is a valued `return`; null for a bare `return;` or any other statement. */
	private static function returnValue(stmt: QueryNode, s: Seams): Null<QueryNode> {
		return stmt.kind == s.returnKind && stmt.children.length == RETURN_VALUE_CHILD_COUNT ? stmt.children[0] : null;
	}

	/** Build the `return if (c1) a else if (c2) b … else n;` edit replacing the whole head-`if` span. */
	private static function buildEdit(m: Match, source: String, span: Span): { span: Span, text: String } {
		final built: Array<{ cond: String, value: String }> = [
			for (p in m.pairs) { cond: text(source, p.cond), value: text(source, p.value) }
		];
		return { span: span, text: IfExpressionChain.buildText(text(source, m.prefix), built, text(source, m.terminalValue)) };
	}

	/**
	 * Whether a comment sits in a region the collapse drops. The kept spans are exactly the
	 * TRIMMED ones `buildEdit` copies, which is what makes a comment the parser folded into a
	 * value's trailing trivia count as dropped and fail the site closed.
	 */
	private static function droppedComment(headSpan: Span, m: Match, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Bool {
		final kept: Array<Span> = [m.prefix, m.terminalValue];
		for (p in m.pairs) {
			kept.push(p.cond);
			kept.push(p.value);
		}
		return IfExpressionChain.droppedComment(headSpan, kept, comments);
	}

	/** The source text `span` covers. */
	private static inline function text(source: String, span: Span): String {
		return source.substring(span.from, span.to);
	}

}

/** The `RefShape` kinds `PreferIfExpressionReturn` reads. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var returnKind: String;
	var blockStmtKind: String;
	var conditionalKinds: Array<String>;
}

/**
 * A matched return chain, carried as SPANS rather than nodes so `buildEdit` and
 * `droppedComment` cannot diverge on what the rebuild keeps: the copied `return ` prefix,
 * each (condition, value) pair, and the terminal value. `prefix` runs from the head
 * `return`'s start to the RAW start of its value (a start offset is exact -- only ENDS carry
 * trivia); every other span is cut back to its last token by `IfExpressionChain.tokenSpan`.
 */
private typedef Match = {
	var prefix: Span;
	var pairs: Array<{ cond: Span, value: Span }>;
	var terminalValue: Span;
}
