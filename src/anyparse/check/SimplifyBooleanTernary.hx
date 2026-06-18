package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a ternary whose then- or else-branch is a boolean literal — a
 * `cond ? false : x` / `cond ? x : true` style expression that reduces to plain
 * boolean logic (`!cond && x` / `!cond || x`). `Severity.Info` with an autofix.
 *
 * Composes with `prefer-ternary-return` through the `--fix` fixed-point loop: that
 * check turns an `if (cond) return false; return x;` guard into
 * `return cond ? false : x;`, and this one then reduces it to
 * `return !cond && x;` — so a boolean-returning guard chain collapses all the way
 * to a single flat boolean `return`, with no `if` and no ternary left.
 *
 * ## Grammar-agnostic
 *
 * Locates ternary nodes via `RefShape.ternaryKind` and delegates the rewrite to
 * `BooleanLogicSupport.simplifyBooleanTernary` (the seam owning the
 * language-specific De Morgan negation, precedence, and parenthesisation). A
 * grammar without the kind or the seam makes the check a no-op. A real-valued
 * ternary (neither branch a boolean literal) yields null from the seam and is
 * left alone.
 */
@:nullSafety(Strict)
final class SimplifyBooleanTernary implements Check {

	public function new() {}

	public function id(): String {
		return 'simplify-boolean-ternary';
	}

	public function description(): String {
		return 'a ternary with a boolean-literal branch that reduces to a boolean expression';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final ternaryKind: Null<String> = plugin.refShape().ternaryKind;
		final support: Null<BooleanLogicSupport> = plugin.booleanLogicSupport();
		if (ternaryKind == null || support == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, ternaryKind, support);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final ternaryKind: Null<String> = plugin.refShape().ternaryKind;
		final support: Null<BooleanLogicSupport> = plugin.booleanLogicSupport();
		if (ternaryKind == null || support == null) return [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];

		final nodeBySpan: Map<String, QueryNode> = [];
		indexTernaries(tree, ternaryKind, nodeBySpan);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = nodeBySpan['${span.from}:${span.to}'];
			if (node == null) continue;
			final replacement: Null<String> = support.simplifyBooleanTernary(node, source);
			if (replacement == null) continue;
			edits.push({ span: span, text: replacement });
		}
		return edits;
	}

	/** Walk `node`, flagging each ternary the seam can reduce to a boolean expression. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, ternaryKind: String, support: BooleanLogicSupport
	): Void {
		if (node.kind == ternaryKind && support.simplifyBooleanTernary(node, source) != null) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'simplify-boolean-ternary',
				severity: Severity.Info,
				message: 'this ternary can be a boolean expression'
			});
		}
		for (c in node.children) walk(out, file, source, c, ternaryKind, support);
	}

	/** Index every ternary node by its `from:to` span key (for `fix` to re-find a flagged node). */
	private static function indexTernaries(node: QueryNode, ternaryKind: String, out: Map<String, QueryNode>): Void {
		if (node.kind == ternaryKind) {
			final span: Null<Span> = node.span;
			if (span != null) out['${span.from}:${span.to}'] = node;
		}
		for (c in node.children) indexTernaries(c, ternaryKind, out);
	}

}
