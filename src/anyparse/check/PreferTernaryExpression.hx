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
 * Flags a 2-branch `if`-EXPRESSION already written in value position, rewriting it to a
 * ternary:
 *
 * ```haxe
 * final start:Int = if (lastIndex > 1 || !path.startsWith(':'))
 *     lastIndex
 * else
 *     1;
 * // ->
 * final start:Int = lastIndex > 1 || !path.startsWith(':') ? lastIndex : 1;
 * ```
 *
 * Purely structural (no type information). `Info` -- the code is correct, this is a
 * readability simplification matching the user's documented preference for a ternary over a
 * two-branch `if`.
 *
 * ## The coverage gap this closes
 *
 * The rest of the family matches a SHAPE AROUND the `if`: `prefer-ternary-assignment` /
 * `prefer-ternary-return` take an `if`/`else` STATEMENT whose branches assign or return, and
 * `prefer-if-expression-assignment` / `-return` take a CHAIN (>= 1 `else if`) of such
 * statements. An `if`-expression the author already wrote as a value (`var x = if (c) a else
 * b`, `return if (c) a else b`, `f(if (c) a else b)`) is a statement to nobody, so none of
 * them see it. This check owns exactly that node.
 *
 * ## What is flagged
 *
 * An `ifExpressionKinds` node -- value position BY KIND, so the rewrite needs no position
 * analysis and works uniformly in initializer / `return` / argument / nested-operand
 * positions -- with:
 *
 * - exactly `[condition, then, else]` children. A no-`else` `if`-expression yields no value
 *   on the missing path and never matches;
 * - an `else` branch that is NOT itself an `if`-expression, AND the node itself not the
 *   `else if` LINK of another (`IfExpressionChain.isElseIfLink`). BOTH halves are load-bearing
 *   and the second was found only on a real tree: with the head gate alone a chain's INNERMOST
 *   link is a legal 2-branch `if`-expression, so it converted first, its parent's `else` stopped
 *   being an `if`-expression, and the next `--fix` pass unravelled the chain one level per pass
 *   into a nested ternary -- silently undoing `prefer-if-expression-*`, whose output this check
 *   must never touch. Refusing the link keeps every chain whole;
 * - both branches a plain VALUE: not a bodied construct (a block, a nested `if` / `switch` /
 *   `try`) and not a control EXIT (`return` / `throw` / `break` / `continue`). Neither is a
 *   safety gate -- Haxe parses both verbatim in a ternary operand slot (checked against the
 *   compiler) -- both are BENEFIT gates. A ternary operand carrying its own body reads worse
 *   than the `if`-expression it replaced, and `final t:Float = a ? x : b ? y : return;` (a real
 *   TM site, produced before the exit gate existed) disguises control flow as a value. The
 *   construct half doubles as the disjointness gate against
 *   `prefer-if-expression-assignment`'s 2-branch arm, whose output is a 2-branch
 *   `if`-expression with a nested `switch` / `if`-chain branch;
 * - no comment in a region the rebuild drops (the `if (` / `)` / `else` glue and the braces
 *   all go away), following the family's fail-closed comment guard.
 *
 * The reported span is the whole `if`-expression.
 *
 * ## Autofix
 *
 * `fix` replaces the `if`-expression node with `cond ? then : else` -- no trailing `;`, the
 * node being an expression, so the enclosing statement's terminator is untouched. The three
 * pieces are copied verbatim from their spans. The condition is wrapped in parentheses only
 * when it binds no tighter than `?:` (a ternary or an assignment), per the user's
 * no-redundant-parens preference; the branches are copied bare, as the ternary siblings do
 * (every operand a surviving branch can hold binds tighter than `?:` in Haxe).
 *
 * Needs `ifExpressionKinds` and `controlFlowSupport`; either unset makes the check a no-op.
 * `switchKinds` / `tryExpressionKinds` / `tryStatementKinds` / `controlExitKinds` are optional
 * -- an unset one merely drops its constructs from the branch refusal set.
 */
@:nullSafety(Strict)
final class PreferTernaryExpression implements Check {

	/** An `if`-expression has exactly [condition, then-branch, else-branch] children -- its `else` is mandatory. */
	private static inline final IF_ELSE_CHILD_COUNT: Int = 3;

	public function new() {}

	public function id(): String {
		return 'prefer-ternary-expression';
	}

	public function description(): String {
		return 'a two-branch if-expression in value position, rewritable as a ternary';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(entry.source);
			walk(tree, violations, entry.file, comments, seams);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final edits: Array<{ span: Span, text: String }> =
			CheckScan.applyBySpan(plugin, source, violations, seams.ifExprKinds, (node, span) -> {
				return matches(node, comments, seams) ? buildEdit(node, source, span, seams.shape) : null;
			});
		return RefactorSupport.dropContainedEdits(edits);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifExprKinds: Null<Array<String>> = shape.ifExpressionKinds;
		if (ifExprKinds == null || ifExprKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		// The bodied constructs a ternary operand must not hold: every statement-list node,
		// plus the branching / handling constructs that carry one. Assembled from the
		// grammar's own seams so no kind is spelled here.
		final construct: Array<String> = support.blockKinds()
			.concat(ifExprKinds)
			.concat(shape.switchKinds ?? [])
			.concat(shape.tryExpressionKinds ?? [])
			.concat(shape.tryStatementKinds ?? [])
			.concat(shape.controlExitKinds ?? []);
		return { ifExprKinds: ifExprKinds, constructKinds: construct, shape: shape };
	}

	/** Walk `node`, flagging every 2-branch value `if` whose branches are plain values. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		?parent: QueryNode
	): Void {
		if (
			s.ifExprKinds.contains(node.kind) && !IfExpressionChain.isElseIfLink(node, parent, s.ifExprKinds) && matches(node, comments, s)
		) {
			final span: Null<Span> = node.span;
			if (span != null) out.push({
				file: file,
				span: span,
				rule: 'prefer-ternary-expression',
				severity: Severity.Info,
				message: 'this two-branch if-expression can be a ternary'
			});
		}
		for (c in node.children) walk(c, out, file, comments, s, node);
	}

	/**
	 * Whether `node` is a 2-branch value `if` both of whose branches are plain values and
	 * whose rebuild drops no comment (see the class doc for every gate).
	 */
	private static function matches(node: QueryNode, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams): Bool {
		if (node.children.length != IF_ELSE_CHILD_COUNT) return false;
		final span: Null<Span> = node.span;
		final condSpan: Null<Span> = node.children[0].span;
		final thenBranch: QueryNode = node.children[1];
		final elseBranch: QueryNode = node.children[2];
		if (s.constructKinds.contains(thenBranch.kind) || s.constructKinds.contains(elseBranch.kind)) return false;
		final thenSpan: Null<Span> = thenBranch.span;
		final elseSpan: Null<Span> = elseBranch.span;
		if (span == null || condSpan == null || thenSpan == null || elseSpan == null) return false;
		return !IfExpressionChain.droppedComment(span, [condSpan, thenSpan, elseSpan], comments);
	}

	/** Build the `cond ? then : else` edit replacing the whole `if`-expression span (no terminator -- it is an expression). */
	private static function buildEdit(node: QueryNode, source: String, span: Span, shape: RefShape): Null<{ span: Span, text: String }> {
		final condSpan: Null<Span> = node.children[0].span;
		final thenSpan: Null<Span> = node.children[1].span;
		final elseSpan: Null<Span> = node.children[2].span;
		if (condSpan == null || thenSpan == null || elseSpan == null) return null;
		final condition: String = wrapCondition(source.substring(condSpan.from, condSpan.to), node.children[0].kind, shape);
		final thenSource: String = source.substring(thenSpan.from, thenSpan.to);
		final elseSource: String = source.substring(elseSpan.from, elseSpan.to);
		return { span: span, text: '$condition ? $thenSource : $elseSource' };
	}

	/** Parenthesise the condition iff it binds no tighter than `?:` (a ternary or an assignment); else emit it bare. */
	private static function wrapCondition(source: String, kind: String, shape: RefShape): String {
		final ternaryKind: Null<String> = shape.ternaryKind;
		final needsParens: Bool = (ternaryKind != null && kind == ternaryKind) || shape.writeParentKinds.contains(kind);
		return needsParens ? '($source)' : source;
	}

}

/** The kinds `PreferTernaryExpression` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var ifExprKinds: Array<String>;
	var constructKinds: Array<String>;
	var shape: RefShape;
}
