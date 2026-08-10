package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
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
 * An `ifExpressionKinds` node -- expression BY KIND, so it always yields a value -- with:
 *
 * - exactly `[condition, then, else]` children. A no-`else` `if`-expression yields no value
 *   on the missing path and never matches;
 * - both branches drawn from `ternaryConditionUnwrapKinds`, the grammar's own whitelist of
 *   kinds that bind STRICTLY TIGHTER than `?:` -- the same set `redundant-parens` trusts to
 *   survive unwrapping into a ternary CONDITION, which is exactly the property an operand slot
 *   needs. Being a whitelist it is fail-closed by CONSTRUCTION rather than by enumeration: a
 *   bodied construct (a block, a nested `if` / `switch` / `try`), a control exit
 *   (`return` / `throw`), a `macro` / `untyped` quotation, an assignment, an arrow lambda and
 *   a nested ternary are all absent from it, so none can reach a ternary arm and none had to
 *   be thought of. It is also what keeps this check off `prefer-if-expression-*` output: a
 *   chain HEAD's `else` is another `if`-expression, absent from the whitelist;
 * - a SLOT that accepts a bare `?:` (`slotAcceptsTernary`). This is the gate an
 *   "if-expressions are value position by kind, so no position analysis is needed" reading
 *   misses, and it is a correctness gate, not a taste one: the `if`-expression it replaces is
 *   self-delimiting, a ternary is the loosest-binding operator above assignment, so
 *   `var v = a || if (c) x else y;` (which groups as `a || (…)`) would become
 *   `var v = a || c ? x : y;` -- which groups as `(a || c) ? x : y`, compiles, and returns a
 *   different value. The accepted slots come from the grammar: `delimitedAllChildKinds`,
 *   `delimitedTailChildKinds` for any child after the head, and a plain paren. A chain LINK is
 *   refused by the same gate for free -- its parent is the head `if`-expression, which is no host's delimited slot. That subsumption is what replaced an explicit `else if` link check, and it holds only while no `ifExpressionKinds` entry is ALSO a delimited host. The slots the gate is conservative about are known and cost only a missed cleanup: an arrow-lambda body, a `throw` operand, a cast or `(e : T)` check, an index, and a comprehension or map-literal element would all be safe;
 * - no comment in a region the rebuild drops (the `if (` / `)` / `else` glue and the braces
 *   all go away), following the family's fail-closed comment guard.
 *
 * A reification subtree (`RefShape.opaqueKinds`, Haxe's `macro { … }`) is skipped wholesale,
 * matching `double-negation` / `comparison-to-boolean`: its interior is spliced code a
 * consumer may pattern-match on, not source a human reads.
 *
 * The reported span is the whole `if`-expression.
 *
 * ## Autofix
 *
 * `fix` replaces the `if`-expression with `cond ? then : else` -- no trailing `;`, the node
 * being an expression, so the enclosing statement's terminator is untouched. The three pieces
 * are copied verbatim from their spans. The condition is wrapped in parentheses only when it
 * binds no tighter than `?:` (a ternary or an assignment), per the user's no-redundant-parens
 * preference; the branches are copied bare, which the branch whitelist is what makes safe.
 *
 * The replaced region stops at the ELSE-BRANCH's end, not at the node's own: an
 * `if`-expression span runs on through the trivia after its last token, and splicing that
 * away welds the ternary's tail onto whatever follows (`q` + `else` -> the identifier
 * `qelse`) -- which still PARSES, so the `--fix` re-parse gate would wave it through.
 *
 * `run` and `fix` share one `collect`, so neither can encode a gate the other misses.
 *
 * Needs `ifExpressionKinds` and `ternaryConditionUnwrapKinds`; either unset makes the check a
 * no-op. `delimitedAllChildKinds` / `delimitedTailChildKinds` / `parenKind` are optional --
 * with none of them set NO slot is accepted and the check is inert, which is the safe
 * direction.
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
		return seams == null ? [] : [
			for (entry in files) for (m in collect(plugin, entry.source, seams))
				{
					file: entry.file,
					span: m.span,
					rule: 'prefer-ternary-expression',
					severity: Severity.Info,
					message: 'this two-branch if-expression can be a ternary'
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
		return RefactorSupport.dropContainedEdits(
			CheckScan.collectSpanEdits(violations, byKey, (m, _) -> ({ span: m.editSpan, text: m.text }))
		);
	}

	/**
	 * Every rewritable 2-branch value `if` in `source` (empty when it does not parse).
	 * `run` and `fix` both go through it, so neither can encode a gate the other misses.
	 */
	private static function collect(plugin: GrammarPlugin, source: String, s: Seams): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final out: Array<Match> = [];
		walk(tree, source, RefactorSupport.collectCommentTokens(source), s, out, null, 0);
		return out;
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifExprKinds: Null<Array<String>> = shape.ifExpressionKinds;
		if (ifExprKinds == null || ifExprKinds.length == 0) return null;
		// A branch is ACCEPTED only from the grammar's own whitelist of kinds that bind
		// strictly tighter than `?:` — the same set `redundant-parens` trusts to survive
		// unwrapping into a ternary CONDITION, which is exactly the property an operand
		// slot needs. Fail-closed by construction: a bodied construct (block / `if` /
		// `switch` / `try`), a control exit, a `macro` / `untyped` quotation, an
		// assignment, an arrow lambda and a nested ternary are all absent from it, so
		// none of them can reach a ternary arm without anyone having to enumerate them.
		final branchKinds: Null<Array<String>> = shape.ternaryConditionUnwrapKinds;
		if (branchKinds == null || branchKinds.length == 0) return null;
		// The slots a bare `?:` may LAND in: a host that delimits every child, plus one
		// that delimits every child after its head (a call argument, an assignment
		// r-value) and a plain paren. Anywhere else an operator outside would bind into
		// the emitted ternary — `a || if (c) x else y` is `a || (…)`, but
		// `a || c ? x : y` is `(a || c) ? x : y`.
		final parenKind: Null<String> = shape.parenKind;
		return {
			ifExprKinds: ifExprKinds,
			branchKinds: branchKinds,
			delimitedAllKinds: (shape.delimitedAllChildKinds ?? []).concat(parenKind == null ? [] : [parenKind]),
			delimitedTailKinds: shape.delimitedTailChildKinds ?? [],
			opaqueKinds: shape.opaqueKinds ?? [],
			shape: shape
		};
	}

	/**
	 * Walk `node`, collecting every value `if` that is rewritable IN ITS SLOT. `parent` /
	 * `childIndex` carry the slot the node occupies, which the emitted ternary — unlike the
	 * self-delimiting `if`-expression it replaces — is sensitive to. A reification subtree
	 * (`opaqueKinds`) is skipped wholesale, as the sibling rewrite rules do: its interior is
	 * spliced code a consumer may pattern-match, not source anyone reads.
	 */
	private static function walk(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, out: Array<Match>,
		parent: Null<QueryNode>, childIndex: Int
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.ifExprKinds.contains(node.kind) && slotAcceptsTernary(parent, childIndex, s)) {
			final m: Null<Match> = match(node, source, comments, s);
			if (m != null) out.push(m);
		}
		for (i in 0...node.children.length) walk(node.children[i], source, comments, s, out, node, i);
	}

	/**
	 * Whether a bare `?:` may occupy the slot `parent`.`childIndex` — the slot delimits every
	 * child, or delimits every child after its head and this is not the head. Everywhere else
	 * an operator outside would bind INTO the emitted ternary: `a || if (c) x else y` groups
	 * as `a || (…)`, while `a || c ? x : y` groups as `(a || c) ? x : y` — same tokens,
	 * different program, no compile error. A chain LINK is refused here for free: its parent
	 * is the head `if`-expression, which is no host's delimited slot.
	 */
	private static function slotAcceptsTernary(parent: Null<QueryNode>, childIndex: Int, s: Seams): Bool {
		return parent != null
			&& (s.delimitedAllKinds.contains(parent.kind) || (childIndex > 0 && s.delimitedTailKinds.contains(parent.kind)));
	}

	/**
	 * The rewrite of `node` when it is a 2-branch value `if` both of whose branches are plain
	 * values and whose rebuild drops no comment; else null (see the class doc for every gate).
	 *
	 * The edit stops at the else-branch rather than at the node's own end: an `if`-expression
	 * span runs on through the trivia that follows its last token, and splicing that away
	 * welds the ternary's tail onto whatever comes next (`q` + `else` -> `qelse`, which still
	 * PARSES, so the `--fix` validation gate would pass it).
	 */
	private static function match(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		if (node.children.length != IF_ELSE_CHILD_COUNT) return null;
		final condition: QueryNode = node.children[0];
		final thenBranch: QueryNode = node.children[1];
		final elseBranch: QueryNode = node.children[2];
		if (!s.branchKinds.contains(thenBranch.kind) || !s.branchKinds.contains(elseBranch.kind)) return null;
		final span: Null<Span> = node.span;
		final condSpan: Null<Span> = condition.span;
		final thenSpan: Null<Span> = thenBranch.span;
		final elseSpan: Null<Span> = elseBranch.span;
		if (span == null || condSpan == null || thenSpan == null || elseSpan == null) return null;
		if (IfExpressionChain.droppedComment(span, [condSpan, thenSpan, elseSpan], comments)) return null;
		final cond: String = wrapCondition(source.substring(condSpan.from, condSpan.to), condition.kind, s.shape);
		final thenSource: String = source.substring(thenSpan.from, thenSpan.to);
		final elseSource: String = source.substring(elseSpan.from, elseSpan.to);
		return {
			span: span,
			editSpan: new Span(span.from, elseSpan.to),
			text: '$cond ? $thenSource : $elseSource'
		};
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
	var branchKinds: Array<String>;
	var delimitedAllKinds: Array<String>;
	var delimitedTailKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var shape: RefShape;
}

/** A rewritable `if`-expression: the finding key span, the (trivia-trimmed) replaced span, and the ternary text. */
private typedef Match = {
	var span: Span;
	var editSpan: Span;
	var text: String;
}
