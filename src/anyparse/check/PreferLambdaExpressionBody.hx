package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an ARROW lambda whose `{ … }` body holds exactly one statement, and collapses the
 * block to a bare expression body:
 *
 * ```haxe
 * moves.sort((a:Item, b:Item) -> {
 *     return a.path < b.path ? -1 : 1;
 * });
 * // ->
 * moves.sort((a:Item, b:Item) -> a.path < b.path ? -1 : 1);
 * ```
 *
 * Purely structural (no type information). `Info` — the code is correct, this is the
 * canon-convergence half of the arrow-lambda family: `prefer-arrow-callback` turns a
 * `function` literal into an arrow, this check then drops the braces the literal needed.
 *
 * ## What is flagged
 *
 * A node of one of the ARROW lambda kinds — every `lambdaKinds` entry EXCEPT `fnExprKind`
 * — whose LAST child (the body; a lambda's other children are its parameters) is a block
 * (`ControlFlowSupport.blockKinds()`) holding exactly one statement, and that statement is
 * either
 *
 * - a VALUE `return` (`valueReturnKinds`) with exactly one child — the returned
 *   expression becomes the body. A value-less `return;` is a distinct kind and is absent
 *   from the set, so it never matches: `(…) -> return;` is not an expression body; or
 * - a single expression statement (`exprStatementKind`) with exactly one child — the
 *   expression becomes the body.
 *
 * Anything else — a local declaration, a loop, an `if`, a `throw`, a `break`, two
 * statements, an empty body — is left alone. A `#if` region does NOT match either: a
 * conditional projects as ONE `Conditional` child of the block, which is neither of the
 * two accepted statement kinds, so a body whose single "statement" is branch-dependent
 * fails closed. That is why this check reads the PLAIN tree rather than the branch-aware
 * one: the branch-aware projection would split the region into `CondBranch` statement
 * lists and could present a one-statement branch as if it were the whole body.
 *
 * The `function` literal (`fnExprKind`) is deliberately NOT matched. `prefer-arrow-callback`
 * owns that node in call-argument position and normalises it INTO one of the arrow kinds;
 * this check then fires on the result in the next fixed-point pass. Matching both here would
 * double-report one site, and collapsing a `function` literal's block in place would emit
 * `function(v) return e`, a shape the canon does not want.
 *
 * ## Why the collapse is type-preserving
 *
 * A Haxe block IS an expression whose value is its last expression, so
 * `(v) -> { push(v); }` already has type `(v : Int) -> Int`, not `-> Void` — verified on
 * 4.3.7 for both the `return` and the bare-expression shape, standalone and in a generic
 * argument position (`array.map`). This check therefore carries none of the
 * expected-type machinery `prefer-arrow-callback` needs: THAT rewrite changes a
 * `function` literal's Void-by-default return into an inferred one, while dropping braces
 * around a single statement changes nothing.
 *
 * A comment anywhere inside the block but outside the copied expression is dropped by the
 * rebuild (the braces, the `return` keyword and the `;` all go away), so the finding is
 * skipped rather than silently losing it — the family's fail-closed comment guard. A
 * comment INSIDE the expression rides along and the site still fires.
 *
 * A reification subtree (`RefShape.opaqueKinds`, Haxe's `macro { … }`) is skipped wholesale,
 * matching the sibling rewrite rules: its interior is spliced code a consumer may
 * pattern-match on, not source a human reads.
 *
 * ## Autofix
 *
 * `fix` replaces the BLOCK's span — braces included, nothing outside them — with the
 * expression's verbatim source. Trailing trivia is outside the block's span, so the
 * emitted body cannot weld onto what follows. Nested lambdas both match; the outer edit
 * contains the inner one and `RefactorSupport.dropContainedEdits` keeps the outer, the
 * inner surfacing on the next pass.
 *
 * `run` and `fix` share one `collect`, so neither can encode a gate the other misses.
 *
 * ## Grammar-agnostic
 *
 * `lambdaKinds` minus `fnExprKind` are the matched kinds, `ControlFlowSupport.blockKinds()`
 * the block bodies, `valueReturnKinds` / `exprStatementKind` the two collapsible statements
 * and `opaqueKinds` the subtrees to skip. No `lambdaKinds` beyond the function literal, no
 * block kinds, or NEITHER accepted statement kind → the check is a no-op.
 */
@:nullSafety(Strict)
final class PreferLambdaExpressionBody implements Check {

	/** A collapsible body block holds exactly one statement. */
	private static inline final SINGLE_STATEMENT: Int = 1;

	/** A collapsible statement carries exactly one child — the value the body becomes. */
	private static inline final SINGLE_VALUE_CHILD: Int = 1;

	public function new() {}

	public function id(): String {
		return 'prefer-lambda-expression-body';
	}

	public function description(): String {
		return 'an arrow lambda whose block body is a single return or expression statement, collapsible to an expression body';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		return [
			for (entry in files) for (m in collect(plugin, entry.source, seams))
				{
					file: entry.file,
					span: m.span,
					rule: 'prefer-lambda-expression-body',
					severity: Severity.Info,
					message: 'this single-statement lambda body can be an expression body'
				}
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final byKey: Map<String, Match> = [];
		for (m in collect(plugin, source, seams)) byKey['${m.span.from}:${m.span.to}'] = m;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final m: Null<Match> = byKey['${vspan.from}:${vspan.to}'];
			if (m != null) edits.push({ span: m.span, text: m.text });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Every collapsible lambda body in `source` (empty when it does not parse). `run` and
	 * `fix` both go through it, so neither can encode a gate the other misses.
	 */
	private static function collect(plugin: GrammarPlugin, source: String, s: Seams): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final out: Array<Match> = [];
		walk(tree, source, RefactorSupport.collectCommentTokens(source), s, out);
		return out;
	}

	/**
	 * Bundle the kinds this check reads, or null when the grammar leaves the check nothing to
	 * match: no anonymous-function-literal kind (see the body — without it the exclusion that
	 * keeps this check off `prefer-arrow-callback`'s node cannot be made), no arrow lambda
	 * kind, no block kind, or neither collapsible statement kind.
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		// The ARROW forms are every lambda kind that is not the anonymous-function literal:
		// `prefer-arrow-callback` owns that one and normalises it into one of these, so
		// excluding it is what keeps a single site from being reported by both checks. With
		// the seam UNSET nothing would be excluded and this check would collapse a
		// `function` literal's block to `function(v) e`, which does not even compile — so an
		// unset seam is a no-op, not a wider match. `prefer-arrow-callback` is inert without
		// it too, so nothing is lost that this check could compose with.
		final fnExprKind: Null<String> = shape.fnExprKind;
		if (fnExprKind == null) return null;
		final arrowKinds: Array<String> = (shape.lambdaKinds ?? []).filter(k -> k != fnExprKind);
		final blockKinds: Array<String> = support.blockKinds();
		final valueReturnKinds: Array<String> = shape.valueReturnKinds ?? [];
		final exprStatementKind: Null<String> = shape.exprStatementKind;
		if (arrowKinds.length == 0 || blockKinds.length == 0) return null;
		if (valueReturnKinds.length == 0 && exprStatementKind == null) return null;
		return {
			arrowKinds: arrowKinds,
			blockKinds: blockKinds,
			valueReturnKinds: valueReturnKinds,
			exprStatementKind: exprStatementKind,
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

	/** Walk `node`, collecting every collapsible lambda body; a reification subtree is skipped whole. */
	private static function walk(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, out: Array<Match>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.arrowKinds.contains(node.kind)) {
			final m: Null<Match> = match(node, source, comments, s);
			if (m != null) out.push(m);
		}
		for (child in node.children) walk(child, source, comments, s, out);
	}

	/**
	 * The collapse of `node`'s body when it is a one-statement block whose statement is a
	 * value `return` or a bare expression, and whose rebuild drops no comment; else null.
	 * The body is the LAST child — a lambda's earlier children are its parameters.
	 */
	private static function match(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		if (node.children.length == 0) return null;
		final body: QueryNode = node.children[node.children.length - 1];
		if (!s.blockKinds.contains(body.kind) || body.children.length != SINGLE_STATEMENT) return null;
		// A block that is NOT the lambda's tail cannot be its body: `->` parses its body
		// greedily, so `v -> { return 1; } != null` projects as `ThinArrow(v, NotEq(…))` and
		// the block is a grandchild. That greediness is what spares this check the slot
		// analysis `prefer-ternary-expression` needs — nothing outside can bind INTO an
		// emitted body that the braces were not already shielding.
		final value: Null<QueryNode> = collapsibleValue(body.children[0], s);
		if (value == null) return null;
		final bodySpan: Null<Span> = body.span;
		final valueSpan: Null<Span> = value.span;
		if (bodySpan == null || valueSpan == null) return null;
		if (IfExpressionChain.droppedComment(bodySpan, [valueSpan], comments)) return null;
		return { span: bodySpan, text: source.substring(valueSpan.from, valueSpan.to) };
	}

	/**
	 * The expression a one-statement block collapses to: the value of a value `return`, or a
	 * bare expression statement's expression. Null for every other statement — a value-less
	 * `return;`, a declaration, a loop, a control exit, or a `#if` region (one `Conditional`
	 * child, which is neither accepted kind).
	 */
	private static function collapsibleValue(stmt: QueryNode, s: Seams): Null<QueryNode> {
		if (stmt.children.length != SINGLE_VALUE_CHILD) return null;
		final collapsible: Bool = s.valueReturnKinds.contains(stmt.kind) || stmt.kind == s.exprStatementKind;
		return collapsible ? stmt.children[0] : null;
	}

}

/** The kinds `PreferLambdaExpressionBody` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var arrowKinds: Array<String>;
	var blockKinds: Array<String>;
	var valueReturnKinds: Array<String>;
	var exprStatementKind: Null<String>;
	var opaqueKinds: Array<String>;
}

/** A collapsible lambda body: the block's span (the finding key AND the replaced region) and the expression text. */
private typedef Match = {
	var span: Span;
	var text: String;
}
