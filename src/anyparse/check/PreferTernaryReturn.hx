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
 * Flags an `if (cond) return a;` whose immediately-following sibling is a
 * `return b;`, collapsing the pair to a single `return cond ? a : b;`. Purely
 * structural (no type information), so it holds without a type-checker. `Info` —
 * the code is correct, this is a readability simplification matching the user's
 * documented preference for a ternary `return` over an `if`-return followed by a
 * `return` (mirroring the sibling `redundant-else-after-return`).
 *
 * ## What is flagged
 *
 * Only an `if` STATEMENT that is a DIRECT child of a block, has NO `else`, whose
 * then-branch is a value-returning `return` (or a `{ … }` wrapping exactly one),
 * and whose immediately-following block sibling is also a value-returning
 * `return`. A value-less `return;` is a distinct kind and never matches (a
 * ternary needs two values). The direct-block-child restriction is the
 * correctness gate: the two statements must be real siblings in one statement
 * list — an inline `if (outer) if (a) return 1;` (the inner `if` being the
 * un-braced body of another statement) is not flagged, since the trailing
 * `return` is then a sibling of the OUTER statement, not the inner `if`. A
 * statement between the `if` and the `return` also blocks the match (the
 * collapse would reorder it). The reported span is the `if` statement.
 *
 * ## Autofix
 *
 * `fix` replaces the `if`-statement-through-trailing-`return` span with
 * `return cond ? a : b;`. The condition is wrapped in parentheses only when it
 * binds no tighter than `?:` (a ternary, or an assignment) so precedence is
 * preserved; every tighter-binding condition (comparison, `&&` / `||`, `??`,
 * call, identifier) is emitted bare, per the user's no-redundant-parens
 * preference. The return values are copied verbatim. Like the relocating
 * `redundant-else-after-return` fix, a comment sitting between the two
 * statements is dropped — the replacement is rebuilt from expression spans only.
 * `RefactorSupport.dropContainedEdits` keeps edits non-overlapping. Needs
 * `ControlFlowSupport` and `RefShape.returnStatementKind`; either unset makes
 * the check report-only / a no-op.
 */
@:nullSafety(Strict)
final class PreferTernaryReturn implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-ternary-return';
	}

	public function description(): String {
		return 'an if/return followed by a return that collapses to a single ternary return';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final returnKind: Null<String> = shape.returnStatementKind;
		if (ifKinds.length == 0 || returnKind == null) return [];
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, support, shape, ifKinds, returnKind);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final returnKind: Null<String> = shape.returnStatementKind;
		if (ifKinds.length == 0 || returnKind == null) return [];
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<{ span: Span, text: String }> = [];
		collectFixes(tree, source, support, shape, ifKinds, returnKind, flagged, edits);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Walk `node`; at each block flag the direct-child `if`/`return` pairs. */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, support: ControlFlowSupport, shape: RefShape, ifKinds: Array<String>,
		returnKind: String
	): Void {
		if (support.blockKinds().contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final match: Null<TernaryMatch> = pairAt(kids, i, support, shape, ifKinds, returnKind);
				if (match != null) {
					final span: Null<Span> = match.ifNode.span;
					if (span != null) out.push({
						file: file,
						span: span,
						rule: 'prefer-ternary-return',
						severity: Severity.Info,
						message: 'this if/return pair can be a single ternary return'
					});
				}
			}
		}
		for (c in node.children) walk(out, file, c, support, shape, ifKinds, returnKind);
	}

	/** Mirror `walk`: collect one replacement edit per flagged `if`/`return` pair. */
	private static function collectFixes(
		node: QueryNode, source: String, support: ControlFlowSupport, shape: RefShape, ifKinds: Array<String>, returnKind: String,
		flagged: Array<String>, edits: Array<{ span: Span, text: String }>
	): Void {
		if (support.blockKinds().contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final match: Null<TernaryMatch> = pairAt(kids, i, support, shape, ifKinds, returnKind);
				if (match != null) {
					final ifSpan: Null<Span> = match.ifNode.span;
					if (ifSpan != null && flagged.contains('${ifSpan.from}:${ifSpan.to}')) {
						final edit: Null<{ span: Span, text: String }> = buildEdit(match, source, shape);
						if (edit != null) edits.push(edit);
					}
				}
			}
		}
		for (c in node.children) collectFixes(c, source, support, shape, ifKinds, returnKind, flagged, edits);
	}

	/**
	 * If `kids[i]` is a no-else `if` whose then-branch value-returns and `kids[i+1]`
	 * is a value-returning `return`, return the match parts; otherwise null.
	 */
	private static function pairAt(
		kids: Array<QueryNode>, i: Int, support: ControlFlowSupport, shape: RefShape, ifKinds: Array<String>, returnKind: String
	): Null<TernaryMatch> {
		final ifNode: QueryNode = kids[i];
		if (!ifKinds.contains(ifNode.kind) || ifNode.children.length != 2) return null;
		if (RefactorSupport.hasNullNarrowingGuard(ifNode.children[0], shape)) return null;
		final thenValue: Null<QueryNode> = thenReturnValue(ifNode.children[1], shape, returnKind);
		if (thenValue == null) return null;
		if (i + 1 >= kids.length) return null;
		final next: QueryNode = kids[i + 1];
		if (next.kind != returnKind || next.children.length < 1) return null;
		final elseValue: QueryNode = next.children[0];
		// A bool-literal-vs-non-provably-Bool pair collapses to a "stuck" boolean ternary
		// (`cond ? true : g()`) that simplify-boolean-ternary cannot reduce without a typer
		// — uglier than the guard. Leave it: a fully-reducible boolean guard chain is
		// `simplify-boolean-return-chain`'s job; a value ternary still collapses here.
		return isStuckBooleanCollapse(thenValue, elseValue, shape)
			? null
			: {
				ifNode: ifNode,
				condition: ifNode.children[0],
				thenValue: thenValue,
				elseValue: elseValue,
				nextReturn: next
			};
	}

	/**
	 * The value of a then-branch that is a single value-returning `return` —
	 * un-braced (`return e;`) or a `{ … }` wrapping exactly one. Null otherwise.
	 */
	private static function thenReturnValue(then: QueryNode, shape: RefShape, returnKind: String): Null<QueryNode> {
		if (then.kind == returnKind && then.children.length >= 1) return then.children[0];
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind != null && then.kind == blockStmtKind && then.children.length == 1) {
			final only: QueryNode = then.children[0];
			if (only.kind == returnKind && only.children.length >= 1) return only.children[0];
		}
		return null;
	}

	/** Build the `return cond ? a : b;` edit spanning the `if` through the trailing `return`. */
	private static function buildEdit(match: TernaryMatch, source: String, shape: RefShape): Null<{ span: Span, text: String }> {
		final ifSpan: Null<Span> = match.ifNode.span;
		final condSpan: Null<Span> = match.condition.span;
		final thenSpan: Null<Span> = match.thenValue.span;
		final elseSpan: Null<Span> = match.elseValue.span;
		final nextSpan: Null<Span> = match.nextReturn.span;
		if (ifSpan == null || condSpan == null || thenSpan == null || elseSpan == null || nextSpan == null) return null;
		final condition: String = wrapCondition(source.substring(condSpan.from, condSpan.to), match.condition.kind, shape);
		final thenSource: String = source.substring(thenSpan.from, thenSpan.to);
		final elseSource: String = source.substring(elseSpan.from, elseSpan.to);
		final text: String = 'return ' + condition + ' ? ' + thenSource + ' : ' + elseSource + ';';
		return { span: new Span(ifSpan.from, nextSpan.to), text: text };
	}

	/**
	 * Parenthesise the condition iff it binds no tighter than `?:` — a ternary or
	 * an assignment — so `cond ? a : b` keeps the original meaning. Every other
	 * condition binds tighter and is emitted bare.
	 */
	private static function wrapCondition(source: String, kind: String, shape: RefShape): String {
		final ternaryKind: Null<String> = shape.ternaryKind;
		final needsParens: Bool = (ternaryKind != null && kind == ternaryKind) || shape.writeParentKinds.contains(kind);
		return needsParens ? '(' + source + ')' : source;
	}

	/**
	 * Whether collapsing `if (c) return a; return b;` would produce a "stuck" boolean
	 * ternary — exactly one of `a` / `b` is a boolean literal and the other is not a
	 * provably non-null `Bool`. `cond ? true : <Call>` then cannot be reduced to
	 * `cond || …` without a typer, so the ternary is uglier than the guard and is left
	 * alone. Both-literal (`? true : false` -> `cond`) and provably-Bool other side
	 * (reduces cleanly) and neither-literal (a value ternary) all collapse as before.
	 */
	private static function isStuckBooleanCollapse(a: QueryNode, b: QueryNode, shape: RefShape): Bool {
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (boolLitKind == null) return false;
		final aBool: Bool = a.kind == boolLitKind;
		final bBool: Bool = b.kind == boolLitKind;
		if (aBool == bBool) return false;
		final notKind: Null<String> = shape.notKind;
		final boolOpKinds: Array<String> = (shape.comparisonKinds ?? []).concat(notKind != null ? [notKind] : []);
		return !RefactorSupport.provablyBoolOperand(aBool ? b : a, boolOpKinds, shape.parenKind);
	}

}

private typedef TernaryMatch = {
	var ifNode: QueryNode;
	var condition: QueryNode;
	var thenValue: QueryNode;
	var elseValue: QueryNode;
	var nextReturn: QueryNode;
};
