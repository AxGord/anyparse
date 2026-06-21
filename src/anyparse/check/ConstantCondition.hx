package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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
 */
@:nullSafety(Strict)
final class ConstantCondition implements Check {

	/** An if node with an else branch has children [cond, then, else]. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	public function new() {}

	public function id(): String {
		return 'constant-condition';
	}

	public function description(): String {
		return 'a boolean literal as an if condition (if (true) / if (false))';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final boolLitKind: Null<String> = shape.boolLitKind;
		final branchKinds: Null<Array<String>> = shape.branchConditionKinds;
		if (boolLitKind == null || branchKinds == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, boolLitKind, branchKinds);
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
	 * nested flagged ifs are de-overlapped via `dropContainedEdits`.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final boolLitKind: Null<String> = shape.boolLitKind;
		final branchKinds: Null<Array<String>> = shape.branchConditionKinds;
		if (boolLitKind == null || branchKinds == null) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		// Statement-list kinds: a no-else `if (false)` is safe to DELETE only when
		// it is a direct child of one of these; elsewhere it is a branch body and
		// must be replaced with `{}` instead. Absent seam → never delete.
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final blockKinds: Array<String> = support != null ? support.blockKinds() : [];

		// The reported span is the CONDITION (children[0]); match a
		// suppression-filtered violation back to its branch by that span.
		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		collectBranchEdits(tree, null, source, boolLitKind, branchKinds, blockKinds, flagged, edits);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Walk `node`, flagging every branch whose condition is a boolean literal. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, boolLitKind: String, branchKinds: Array<String>
	): Void {
		if (branchKinds.contains(node.kind) && node.children.length > 0 && node.children[0].kind == boolLitKind) {
			final cond: QueryNode = node.children[0];
			final span: Null<Span> = cond.span;
			if (span != null) {
				final always: String = source.substring(span.from, span.to) == 'false' ? 'false' : 'true';
				out.push({
					file: file,
					span: span,
					rule: 'constant-condition',
					severity: Severity.Warning,
					message: 'condition is always $always'
				});
			}
		}
		for (c in node.children) walk(out, file, source, c, boolLitKind, branchKinds);
	}

	/** Walk `node` with its `parent`, collecting a fix edit for each flagged branch. */
	private static function collectBranchEdits(
		node: QueryNode, parent: Null<QueryNode>, source: String, boolLitKind: String, branchKinds: Array<String>,
		blockKinds: Array<String>, flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		if (branchKinds.contains(node.kind) && node.children.length > 0 && node.children[0].kind == boolLitKind) {
			final cond: QueryNode = node.children[0];
			final cspan: Null<Span> = cond.span;
			if (cspan != null && flagged.contains('${cspan.from}:${cspan.to}')) {
				final edit: Null<{ span: Span, text: String }> = branchEdit(node, parent, source, cspan, blockKinds);
				if (edit != null) edits.push(edit);
			}
		}
		for (c in node.children) collectBranchEdits(c, node, source, boolLitKind, branchKinds, blockKinds, flagged, edits);
	}

	/**
	 * The rewrite edit for a flagged branch `node` whose condition (`cspan`) is a
	 * boolean literal: replace the whole `if` with the always-taken branch's
	 * source; a no-else `if (false)` statement is deleted when it sits in a
	 * statement list (`parent` ∈ `blockKinds`) or replaced with `{}` when it is a
	 * branch body; null when no safe edit applies (a no-else `if (false)` in
	 * expression position).
	 */
	private static function branchEdit(
		node: QueryNode, parent: Null<QueryNode>, source: String, cspan: Span, blockKinds: Array<String>
	): Null<{ span: Span, text: String }> {
		final nspan: Null<Span> = node.span;
		if (nspan == null) return null;
		final isFalse: Bool = source.substring(cspan.from, cspan.to) == 'false';
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

}
