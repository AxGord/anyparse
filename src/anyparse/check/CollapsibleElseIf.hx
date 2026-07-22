package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.ControlFlow.ControlFlowSupport;

/**
 * Flags an `else` whose body is a block holding exactly one statement, and that
 * statement is an `if` (`} else { if (b) p(); }`). The braces buy nothing — the
 * chain already reads as `else if (b) p();` — and where the check fires the collapse
 * is behaviour-preserving: the block scope holds no declaration that could widen (its
 * sole statement being an `if`), and the enclosing `if` sits in a position no trailing
 * `else` can follow. `Info` — the code is correct, this is a readability simplification
 * (mirroring the sibling `redundant-else-after-return`).
 *
 * ## What is flagged
 *
 * Two gates, both required. The SHAPE gate: the `else` branch is EXACTLY one block level
 * around EXACTLY one `if`. The POSITION gate: the `if` owning that `else` is a direct
 * child of a statement list (`ControlFlowSupport.blockKinds`), or the else branch of
 * another `if` that itself passes this gate — the `else if` chain case, which inherits its
 * head's position and is flagged.
 *
 * The position gate is the correctness gate, not a style choice. Collapsing rebinds a
 * trailing `else` when the flagged `if` is the brace-less body of an enclosing statement
 * that has one:
 *
 * ```haxe
 * if (x)
 *     if (a) p();
 *     else { if (b) q(); }   // collapsing hands the `else r()` below to `if (b)`
 * else r();
 * ```
 *
 * Here `r()` would go from running on `!x` to running on `x && !a && !b`. A direct child
 * of a statement list can never be followed by an `else` token (the next token is another
 * statement or `}`), so the gate rules the hazard out structurally rather than by
 * guessing. It costs the brace-less-body positions (a bare then-branch, a bare loop body),
 * plus `case`-body and `#if`-region-direct-child: deliberate, documented safe misses, not
 * reclaimed. A BRACED loop body is a statement list and stays flagged.
 *
 * The other deliberate safe misses, on the shape side: a block whose interior opens with a
 * COMMENT ahead of the `if` (the collapse would strand it between `else` and `if`, pushing
 * the `if` onto its own unindented line — worse than the block it replaced; a comment AFTER
 * the `if` is fine and stays flagged); a block with more than one statement; a block whose
 * sole child is a nested block (`unnecessary-block` owns that redundant layer, and
 * unwrapping several levels here would double-fix it); a block holding a
 * conditional-compilation region (`#if … #end` projects as its own node, so the
 * sole child is not an `if`); and an expression-position `if`, which
 * `RefShape.ifStatementKinds` excludes by construction. An `else` on the INNER `if` is
 * fine — it stays that `if`'s `else` after the collapse, exactly as written. The reported
 * span is the `else` branch — the block that goes away.
 *
 * ## Grammar-agnostic
 *
 * `if` kinds come from `RefShape.ifStatementKinds` (statement position only); the
 * else-branch block is recognized by `RefShape.blockStmtKind`; the position gate reads
 * `ControlFlowSupport.blockKinds` via `GrammarPlugin.controlFlowSupport`. Any of the three
 * unset makes the check a no-op, report and fix alike.
 *
 * ## Autofix
 *
 * `fix` emits ONE edit per finding: the else block's span replaced by its INTERIOR —
 * the braces stripped, everything between them kept except the leading / trailing
 * whitespace the braces carried, which is TRIMMED (the writer keeps that whitespace as
 * trivia, so an untrimmed interior would emit `else` and its `if` on separate lines plus
 * a stray blank line). Stripping only the braces is what preserves an interior comment: a
 * comment is trivia, never an AST child, so rebuilding the text from the inner `if`'s span
 * would drop it.
 *
 * Brace symmetry on the collapsed chain is the WRITER's job, not this edit's: under a
 * `singleStatementBraces: remove` policy, `SingleStmtBraces`'s chain scan
 * (`chainForcesBraces`) forces braces on every bare branch of a chain in which any branch
 * keeps them, so the canonicalizing round-trip below restores the symmetry. The chain link
 * this check PRODUCES — an `if` in else position — is exempt from that wrap by design: were
 * it wrapped, gate 7 would rebuild the very `else { if … }` the collapse just removed. What
 * gains braces is the collapsed `if`'s own body.
 *
 * The caller re-emits through the canonical writer (`RefactorSupport.canonicalize`), which
 * lays out and re-indents the collapsed chain. A finding nested inside another's block is
 * dropped as contained (`RefactorSupport.dropContainedEdits`) so edits never overlap; it
 * converges on a later `--fix` pass.
 */
@:nullSafety(Strict)
final class CollapsibleElseIf implements Check {

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	/** The else branch is the third child of an if node — `[cond, then, else]`. */
	private static inline final ELSE_BRANCH_INDEX: Int = 2;

	public function new() {}

	public function id(): String {
		return 'collapsible-else-if';
	}

	public function description(): String {
		return 'an else whose sole statement is an if — collapses to else if';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) for (span in collectElseBlockSpans(tree, entry.source, seams)) violations.push({
				file: entry.file,
				span: span,
				rule: 'collapsible-else-if',
				severity: Severity.Info,
				message: 'this else block wraps a single if — collapse it to else if'
			});
		}
		return violations;
	}

	/**
	 * Strip the braces of each flagged else block, leaving its interior. The candidate
	 * set is re-derived from the tree, so a reported span that no longer names a
	 * collapsible else block (a stale or foreign violation) produces no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, Span> = [];
		for (span in collectElseBlockSpans(tree, source, seams)) byKey['${span.from}:${span.to}'] = span;

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final block: Null<Span> = byKey['${vspan.from}:${vspan.to}'];
			if (block != null) edits.push({ span: block, text: interiorText(source, block) });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * The replacement for a flagged else block: everything BETWEEN its braces, trimmed of the
	 * leading / trailing whitespace the braces used to carry (the writer keeps that whitespace
	 * as trivia, so an untrimmed interior would emit `else` and its `if` on separate lines plus
	 * a stray blank line). Only whitespace goes — an interior comment is part of the text and
	 * survives verbatim. A separating space is prepended when the source has none before the
	 * `{`, so a non-canonical `else{ … }` cannot fuse into `elseif`.
	 */
	private static function interiorText(source: String, block: Span): String {
		final inner: String = StringTools.trim(source.substring(block.from + 1, block.to - 1));
		return StringTools.isSpace(source.charAt(block.from - 1), 0) ? inner : ' $inner';
	}

	/**
	 * The spans of every else branch that is a block wrapping exactly one `if`, in document
	 * order — the candidate set `run` reports and `fix` re-validates against. `source` is
	 * threaded in because one gate is textual (a leading comment inside the braces), so report
	 * and fix necessarily apply the identical test.
	 */
	private static function collectElseBlockSpans(root: QueryNode, source: String, seams: Seams): Array<Span> {
		final out: Array<Span> = [];
		walk(root, source, seams, false, out);
		return out;
	}

	/**
	 * Walk `node`, collecting each collapsible else-branch block whose enclosing `if` sits in
	 * a SAFE position — `safe` threads that down the tree. A statement that is a direct child
	 * of a statement list (`blockKinds`) can never be followed by an `else` token, so nothing
	 * can re-bind to the de-braced inner `if`; an `if`'s else branch inherits its chain head's
	 * position, which keeps the common `else if` chain flaggable. Every other descent (a
	 * condition, a then-branch, a loop / `case` body, a `#if` region, …) resets `safe` to
	 * false: there the flagged `if` may be a brace-less body whose enclosing statement carries
	 * a trailing `else`, and collapsing would hand that `else` to the inner `if`.
	 *
	 * The whole tree is walked, a flagged block's own subtree included — an `else { if … }`
	 * nested inside one is an independent finding (its edit is dropped as contained and
	 * converges on a later pass).
	 */
	private static function walk(node: QueryNode, source: String, seams: Seams, safe: Bool, out: Array<Span>): Void {
		final isIf: Bool = seams.ifKinds.contains(node.kind);
		if (safe && isIf && node.children.length == IF_WITH_ELSE_CHILD_COUNT) {
			final elseBranch: QueryNode = node.children[ELSE_BRANCH_INDEX];
			final span: Null<Span> = elseBranch.span;
			if (span != null && isSingleIfBlock(elseBranch, span, source, seams)) out.push(span);
		}
		final childrenAreStatements: Bool = seams.blockKinds.contains(node.kind);
		for (i in 0...node.children.length)
			walk(node.children[i], source, seams, childrenAreStatements || (safe && isIf && i == ELSE_BRANCH_INDEX), out);
	}

	/**
	 * Whether `node` is a block whose one and only statement is an `if` that nothing but
	 * whitespace precedes. A LEADING comment inside the braces disqualifies it: the collapse
	 * would strand the comment between `else` and `if`, pushing the `if` onto its own
	 * unindented line — worse than the block it replaced. The gate is textual because a
	 * comment is trivia, never an AST child. A comment AFTER the `if` is unaffected: it simply
	 * trails the collapsed statement.
	 */
	private static function isSingleIfBlock(node: QueryNode, blockSpan: Span, source: String, seams: Seams): Bool {
		if (node.kind != seams.blockStmtKind || node.children.length != 1) return false;
		final inner: QueryNode = node.children[0];
		final innerSpan: Null<Span> = inner.span;
		return innerSpan != null && seams.ifKinds.contains(inner.kind)
			&& StringTools.trim(source.substring(blockSpan.from + 1, innerSpan.from)) == '';
	}

	/**
	 * Resolve the `if` kinds, the block-statement kind and the statement-list kinds
	 * (`ControlFlowSupport.blockKinds`, the same seam `redundant-else-after-return`
	 * calls its correctness gate), or null when any of the three is unset.
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return ifKinds.length == 0 || blockStmtKind == null || support == null ? null : {
			ifKinds: ifKinds,
			blockStmtKind: blockStmtKind,
			blockKinds: support.blockKinds()
		};
	}

}

/** The seam kinds `CollapsibleElseIf` reads: the statement-position `if` kinds and the block kind. */
private typedef Seams = {
	final ifKinds: Array<String>;
	final blockStmtKind: String;
	final blockKinds: Array<String>;
};
