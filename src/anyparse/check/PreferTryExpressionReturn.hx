package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.TryExpressionShape.TryParts;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a statement-position `try` / `catch` whose body AND every catch clause is a single
 * valued `return`, collapsing it to one `return` of a try-EXPRESSION:
 *
 * ```haxe
 * try {
 *     return parse(text);
 * } catch (e:String) {
 *     return fallback;
 * }
 * // ->
 * return try parse(text) catch (e:String) fallback;
 * ```
 *
 * Purely structural (no type information). `Info` -- the code is correct, this is a
 * readability simplification. The `return` sibling of `prefer-try-expression-assignment`, and
 * the `try` member of the expression-collapse family that already has `if`
 * (`prefer-if-expression-return`) and `switch` (`prefer-switch-expression-assignment`) rules.
 *
 * ## What is flagged
 *
 * A `tryStatementKinds` node (both grammar forms: braced bodies and the bare
 * `try e catch (…) e;` shape) where:
 *
 * - the try body is exactly ONE statement -- bare, or a `{ … }` wrapping exactly one -- and
 *   that statement is a VALUED `return` (`valueReturnKinds`). A value-less `return;` is a
 *   distinct kind and never matches: the collapsed expression needs a value on every path;
 * - EVERY catch clause body is likewise a single valued `return`. One clause that rethrows,
 *   logs, falls through, or is EMPTY refuses the whole `try` -- after the collapse that path
 *   would have to produce a value it does not have;
 * - no comment sits in a region the rebuild drops. The `try` keyword, the braces and each
 *   `return` keyword all go away; each `catch (…)` header and each returned expression are
 *   copied verbatim, so only a comment OUTSIDE those survives the guard, and a `try` holding
 *   one is left unflagged rather than silently losing it.
 *
 * The reported span is the whole `try` statement. Unlike the assignment sibling this check
 * needs no statement-list walk: a `return`-collapse rewrites the `try` node alone, with no
 * neighbouring declaration to pair with, so it reaches a `try` in ANY position -- including
 * inside a `#if` region and as the un-braced body of an enclosing statement.
 *
 * ## Autofix
 *
 * `fix` replaces the whole `try` statement with
 * `return try <value> catch (…) <value> …;`. Each `catch (…)` header is sliced verbatim from
 * the source (so the exception variable's type annotation, which the default projection folds
 * into trivia, survives exactly as written) and each returned expression from its span; the
 * `try` keyword is emitted. Needs `tryStatementKinds`, `catchClauseKind` and
 * `valueReturnKinds` (any unset makes the check a no-op); `blockStmtKind` is optional --
 * without it only bare (unbraced) bodies are recognised.
 */
@:nullSafety(Strict)
final class PreferTryExpressionReturn implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-try-expression-return';
	}

	public function description(): String {
		return 'a try/catch returning a value in the body and every catch clause, collapsible to a single try-expression return';
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
			CheckScan.applyBySpan(plugin, source, violations, seams.tryKinds, (node, span) -> {
				final parts: Null<TryParts> = match(node, source, comments, seams);
				if (parts == null) return null;
				final value: Null<String> = TryExpressionShape.buildValue(parts, source);
				return value == null ? null : { span: span, text: 'return $value;' };
			});
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final tryKinds: Null<Array<String>> = shape.tryStatementKinds;
		if (tryKinds == null || tryKinds.length == 0) return null;
		final catchKind: Null<String> = shape.catchClauseKind;
		if (catchKind == null) return null;
		final returnKinds: Null<Array<String>> = shape.valueReturnKinds;
		return returnKinds == null || returnKinds.length == 0 ? null : {
			tryKinds: tryKinds,
			catchKind: catchKind,
			returnKinds: returnKinds,
			blockStmtKind: shape.blockStmtKind
		};
	}

	/** Walk `node`, flagging every collapsible `try` statement. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams
	): Void {
		if (s.tryKinds.contains(node.kind) && match(node, source, comments, s) != null) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'prefer-try-expression-return',
				severity: Severity.Info,
				message: 'this try/catch returning in every path can be a single try-expression return'
			});
		}
		for (c in node.children) walk(c, out, file, source, comments, s);
	}

	/** The decomposed `try` when body and every catch clause is a single valued `return` and no comment is dropped; else null. */
	private static function match(
		tryNode: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<TryParts> {
		final span: Null<Span> = tryNode.span;
		if (span == null) return null;
		final parts: Null<TryParts> = TryExpressionShape.decompose(
			tryNode, source, s.catchKind, s.blockStmtKind, node -> returnValue(node, s)
		);
		return parts == null || IfExpressionChain.droppedComment(span, TryExpressionShape.keptSpans(parts), comments) ? null : parts;
	}

	/** The value of a body that is a single VALUED `return`; null for a value-less `return;` or any other statement. */
	private static function returnValue(body: QueryNode, s: Seams): Null<QueryNode> {
		return s.returnKinds.contains(body.kind) && body.children.length >= 1 ? body.children[0] : null;
	}

}

/** The kinds `PreferTryExpressionReturn` reads. */
private typedef Seams = {
	var tryKinds: Array<String>;
	var catchKind: String;
	var returnKinds: Array<String>;
	var blockStmtKind: Null<String>;
}
