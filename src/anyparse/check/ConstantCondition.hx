package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a boolean literal used as the condition of an `if` — `if (true) ...` /
 * `if (false) ...` (SonarLint S1145): the branch is always or never taken, so
 * either the condition or a whole branch is dead. Purely structural (no type
 * information needed), so it holds even without a type-checker. Autofixable —
 * `--fix` replaces the `if` with the source of the taken branch the constant
 * always selects; the lone report-only case is a no-else `if (false)` in
 * expression position.
 *
 * ## Grammar-agnostic
 *
 * The boolean-literal kind comes from `RefShape.boolLitKind` and the
 * condition-bearing kinds from `RefShape.branchConditionKinds` (the condition is
 * `children[0]`); either unset makes the check a no-op. Loops are deliberately
 * NOT among the branch kinds: `while (true)` is an idiomatic infinite loop, not
 * a smell.
 *
 * ## Non-trivial dead branch: report-only
 *
 * The autofix deletes the NOT-taken branch's source along with the `if` —
 * safe only when that branch is genuinely empty (an empty block or a bare
 * `;`). A dead branch can otherwise encode unimplemented intent: a real
 * regression had `final hasSelection:Bool = true;` immediately followed by
 * `if (hasSelection) ... else <real logic>` — the dead `else` was the ONLY
 * trace of a feature whose flag got hardcoded before the feature landed.
 * Deleting it on sight would have destroyed that trace. So whenever the
 * eliminated branch contains any statement beyond an empty block / bare `;`,
 * `fix` withholds the edit for that site — the violation still reports (same
 * severity), with a human-review note appended to the message. Only the
 * empty/trivial case keeps the automatic rewrite. (This check still only
 * fires on a LITERAL `if (true)` / `if (false)`; it does not trace a
 * `final`-bound boolean like `hasSelection` back to its literal — that
 * const-propagation shape is a separate, not-yet-built detector.)
 */
@:nullSafety(Strict)
final class ConstantCondition implements Check {

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	/** ASCII-only note appended when a non-trivial dead branch withholds the autofix. */
	private static inline final DEAD_BRANCH_NOTE: String = ' (dead branch - verify intent before deleting)';

	public function new() {}

	public function id(): String {
		return 'constant-condition';
	}

	public function description(): String {
		return 'a boolean literal as an if condition (if (true) / if (false))';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null)
				walk(
					violations, entry.file, entry.source, tree, seams.boolLitKind, seams.branchKinds, seams.blockKinds, seams.emptyStmtKind
				);
		}
		return violations;
	}

	/**
	 * Rewrite each flagged `if` to the source of the taken branch — the one the
	 * constant condition always selects: `if (true) A [else B]` becomes `A`,
	 * `if (false) A else B` becomes `B`, and a no-else `if (false) A` statement
	 * is deleted (or replaced with `{}` when it is itself a single-statement
	 * branch body, where a bare deletion would orphan the enclosing branch). The
	 * lone report-only case is a no-else `if (false)` in EXPRESSION position
	 * (`var x = if (false) 1;`), whose value slot cannot be emptied. A block
	 * branch keeps its braces (a valid bare block), preserving `var` scoping;
	 * nested flagged ifs are de-overlapped via `dropContainedEdits`. A site whose
	 * eliminated (not-taken) branch is non-trivial — see the class doc — collects
	 * no edit at all; only the empty/trivial case is auto-rewritten.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		// The reported span is the CONDITION (children[0]); match a
		// suppression-filtered violation back to its branch by that span.
		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		collectBranchEdits(tree, null, source, seams.boolLitKind, seams.branchKinds, seams.blockKinds, seams.emptyStmtKind, flagged, edits);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Walk `node`, flagging every branch whose condition is a boolean literal. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, boolLitKind: String, branchKinds: Array<String>,
		blockKinds: Array<String>, emptyStmtKind: Null<String>
	): Void {
		if (branchKinds.contains(node.kind) && node.children.length > 0 && node.children[0].kind == boolLitKind) {
			final cond: QueryNode = node.children[0];
			final span: Null<Span> = cond.span;
			if (span != null) {
				final isFalse: Bool = source.substring(span.from, span.to) == 'false';
				final always: String = isFalse ? 'false' : 'true';
				final trivial: Bool = isTrivialEliminated(eliminatedBranch(node, isFalse), source, blockKinds, emptyStmtKind);
				out.push({
					file: file,
					span: span,
					rule: 'constant-condition',
					severity: Severity.Warning,
					message: trivial ? 'condition is always $always' : 'condition is always $always$DEAD_BRANCH_NOTE'
				});
			}
		}
		for (c in node.children) walk(out, file, source, c, boolLitKind, branchKinds, blockKinds, emptyStmtKind);
	}

	/** Walk `node` with its `parent`, collecting a fix edit for each flagged branch. */
	private static function collectBranchEdits(
		node: QueryNode, parent: Null<QueryNode>, source: String, boolLitKind: String, branchKinds: Array<String>,
		blockKinds: Array<String>, emptyStmtKind: Null<String>, flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		if (branchKinds.contains(node.kind) && node.children.length > 0 && node.children[0].kind == boolLitKind) {
			final cond: QueryNode = node.children[0];
			final cspan: Null<Span> = cond.span;
			if (cspan != null && flagged.contains('${cspan.from}:${cspan.to}')) {
				final edit: Null<{ span: Span, text: String }> = branchEdit(node, parent, source, cspan, blockKinds, emptyStmtKind);
				if (edit != null) edits.push(edit);
			}
		}
		for (c in node.children) collectBranchEdits(c, node, source, boolLitKind, branchKinds, blockKinds, emptyStmtKind, flagged, edits);
	}

	/**
	 * The rewrite edit for a flagged branch `node` whose condition (`cspan`) is a
	 * boolean literal: replace the whole `if` with the always-taken branch's
	 * source; a no-else `if (false)` statement is deleted when it sits in a
	 * statement list (`parent` ∈ `blockKinds`) or replaced with `{}` when it is a
	 * branch body; null when no safe edit applies — a no-else `if (false)` in
	 * expression position, or a NON-TRIVIAL eliminated branch (see the class doc:
	 * the violation still reports, just without an edit here).
	 */
	private static function branchEdit(
		node: QueryNode, parent: Null<QueryNode>, source: String, cspan: Span, blockKinds: Array<String>, emptyStmtKind: Null<String>
	): Null<{ span: Span, text: String }> {
		final nspan: Null<Span> = node.span;
		if (nspan == null) return null;
		final isFalse: Bool = source.substring(cspan.from, cspan.to) == 'false';
		if (!isTrivialEliminated(eliminatedBranch(node, isFalse), source, blockKinds, emptyStmtKind)) return null;
		final hasElse: Bool = node.children.length >= IF_WITH_ELSE_CHILD_COUNT;
		// Taken branch: then (children[1]) when true, else (children[2]) when false.
		final taken: Null<QueryNode> = isFalse ? (hasElse ? node.children[2] : null) : node.children[1];
		if (taken == null) {
			// A no-else `if (false)`: only a STATEMENT-position if is fixable (an
			// expression-position one sits in a value slot, so it stays report-only).
			if (node.kind != 'IfStmt') return null;
			final inBlock: Bool = parent != null && blockKinds.contains(parent.kind);
			return inBlock
				? {
					span: RefactorSupport.lineExtendedSpan(source, nspan),
					text: ''
				}
				: {
					span: nspan,
					text: '{}'
				};
		}
		final tspan: Null<Span> = taken.span;
		return tspan == null ? null : { span: nspan, text: source.substring(tspan.from, tspan.to) };
	}

	/**
	 * The branch NEVER taken by `node` (an `if` whose condition is the boolean
	 * literal `isFalse` selects) — the else branch (`children[2]`) when the
	 * condition is `true` and one exists, the then branch (`children[1]`) when
	 * it is `false`, or null when the condition is `true` and there is no else
	 * (nothing is eliminated: the `if` is unwrapped to its then branch, no code
	 * is lost).
	 */
	private static function eliminatedBranch(node: QueryNode, isFalse: Bool): Null<QueryNode> {
		return isFalse
			? (node.children.length > 1 ? node.children[1] : null)
			: (node.children.length >= IF_WITH_ELSE_CHILD_COUNT ? node.children[2] : null);
	}

	/**
	 * Whether the code an autofix would ELIMINATE — `eliminated`, or nothing — is
	 * safe to delete silently: empty (`eliminated == null`), a bare `;`
	 * (`emptyStmtKind`), or an empty block (`blockKinds`, zero STATEMENT
	 * children AND — via the shared `RefactorSupport.isBlankSpan`, the same
	 * check `empty-block` uses — no comment sitting between the braces either:
	 * a comment is not a statement, but it is source a fix must not silently
	 * discard). Anything else — a real statement, a comment, or a non-block
	 * expression value — may encode unimplemented intent (see the class doc)
	 * and must not be auto-deleted; the check still reports it, with a
	 * human-review note.
	 */
	private static function isTrivialEliminated(
		eliminated: Null<QueryNode>, source: String, blockKinds: Array<String>, emptyStmtKind: Null<String>
	): Bool {
		if (eliminated == null) return true;
		if (emptyStmtKind != null && eliminated.kind == emptyStmtKind) return true;
		if (!blockKinds.contains(eliminated.kind) || eliminated.children.length != 0) return false;
		final espan: Null<Span> = eliminated.span;
		return espan != null && RefactorSupport.isBlankSpan(espan, source);
	}

	/**
	 * Resolve the boolean-literal / branch-condition seam kinds plus the statement-list
	 * kinds a no-else `if (false)` may be safely deleted from, or null when either
	 * required kind is unset.
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (boolLitKind == null) return null;
		final branchKinds: Null<Array<String>> = shape.branchConditionKinds;
		if (branchKinds == null) return null;
		// Statement-list kinds: a no-else `if (false)` is safe to DELETE only when
		// it is a direct child of one of these; elsewhere it is a branch body and
		// must be replaced with `{}` instead. Absent seam → never delete.
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final blockKinds: Array<String> = support != null ? support.blockKinds() : [];
		return {
			boolLitKind: boolLitKind,
			branchKinds: branchKinds,
			blockKinds: blockKinds,
			emptyStmtKind: shape.emptyStmtKind
		};
	}

}

/** The resolved seams `ConstantCondition` reads in both `run` and `fix`. */
private typedef Seams = {
	final boolLitKind: String;
	final branchKinds: Array<String>;
	final blockKinds: Array<String>;
	final emptyStmtKind: Null<String>;
};
