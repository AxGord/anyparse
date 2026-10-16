package anyparse.check;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/** The trailing `if` a guard rewrite inverts: the statement, its condition and its braced then-branch. */
typedef GuardedIf = {
	final ifNode: QueryNode;
	final cond: QueryNode;
	final thenBlock: QueryNode;
};

/** The seams every guard rewrite needs: the grammar's shape, its `if` statement kinds and its control-flow support. */
typedef GuardSeams = {
	final shape: RefShape;
	final ifKinds: Array<String>;
	final flow: ControlFlowSupport;
};

/**
 * What a guard rewrite of a `GuardedIf` splices: the `if`'s span, where the then-branch's inner text starts, that text
 * (its braces off, untrimmed), and the inverted condition.
 */
typedef GuardSplice = {
	final ifSpan: Span;
	final innerFrom: Int;
	final inner: String;
	final neg: String;
};

/**
 * The core the guard rewrites share — `guard-continue` (a loop body's trailing `if` → `if (!cond) continue;`) and
 * `guard-return` (a block's trailing `if` + `return` → `if (!cond) return …;`): the `if` shape both invert, the glue
 * comment that refuses either, the report gate on a clean inversion and the fix that re-finds each reported `if`.
 *
 * Each rule keeps what tells it apart — where the `if` may sit, what follows it, what it emits; what both decide the
 * same way is decided here once, because the two copies were edited in step commit after commit.
 */
@:nullSafety(Strict)
final class GuardScan {

	/** A guard `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** The seams of `plugin` every guard rewrite needs, or null when the grammar names no `if` statement or no control flow. */
	public static function seamsOf(plugin: GrammarPlugin): Null<GuardSeams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final flow: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return ifKinds.length == 0 || flow == null ? null : { shape: shape, ifKinds: ifKinds, flow: flow };
	}

	/**
	 * `ifNode` as the `if` a guard inverts: one of `ifKinds` with no `else`, whose then-branch is one of `blockKinds`
	 * holding at least `minThen` statements; null otherwise.
	 */
	public static function guardedIf(ifNode: QueryNode, ifKinds: Array<String>, blockKinds: Array<String>, minThen: Int): Null<GuardedIf> {
		if (!ifKinds.contains(ifNode.kind) || ifNode.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final thenBlock: QueryNode = ifNode.children[1];
		return blockKinds.contains(thenBlock.kind) && thenBlock.children.length >= minThen
			? { ifNode: ifNode, cond: ifNode.children[0], thenBlock: thenBlock }
			: null;
	}

	/**
	 * Whether a comment sits in the `if (` or `) {` glue of `g`, which the rewrite drops (a comment in the condition or
	 * the then-branch rides along); true when a span is unknown, so an unplaceable site is refused.
	 */
	public static function headerHasComment(source: String, g: GuardedIf): Bool {
		final ifSpan: Null<Span> = g.ifNode.span;
		final condSpan: Null<Span> = g.cond.span;
		final thenSpan: Null<Span> = g.thenBlock.span;
		if (ifSpan == null || condSpan == null || thenSpan == null) return true;
		final headerGap: Bool = CheckScan.hasCommentMarker(source, ifSpan.from, condSpan.from);
		return headerGap || CheckScan.hasCommentMarker(source, condSpan.to, thenSpan.from);
	}

	/**
	 * Report `g` on its `if` as `rule` with `message` — unless its condition cannot invert without a `!( … )` wrap, which
	 * reads worse than the nesting the guard removes, so the site is left alone.
	 */
	public static function report(
		out: Array<Violation>, file: String, source: String, g: GuardedIf, logic: Null<BooleanLogicSupport>,
		types: Null<(QueryNode) -> Null<String>>, rule: String, message: String
	): Void {
		final span: Null<Span> = g.ifNode.span;
		if (span != null && NegationScan.negationIsClean(g.cond, source, logic, types)) out.push({
			file: file,
			span: span,
			rule: rule,
			severity: Severity.Info,
			message: message
		});
	}

	/**
	 * The splice of `g` in `source`: its `if`'s span, its then-branch's inner text and its condition inverted under
	 * `negation` / `logic` / `types`; null when a span is unknown.
	 */
	public static function splice(
		g: GuardedIf, source: String, negation: NegationSeams, logic: Null<BooleanLogicSupport>, types: Null<(QueryNode) -> Null<String>>
	): Null<GuardSplice> {
		final ifSpan: Null<Span> = g.ifNode.span;
		final thenSpan: Null<Span> = g.thenBlock.span;
		if (ifSpan == null || thenSpan == null) return null;
		final innerFrom: Int = thenSpan.from + 1;
		return {
			ifSpan: ifSpan,
			innerFrom: innerFrom,
			inner: source.substring(innerFrom, thenSpan.to - 1),
			neg: NegationScan.negateConditionText(g.cond, source, negation, logic, types)
		};
	}

	/** Index `g` under the key `CheckScan.collectSpanEdits` re-finds a reported `if` by. */
	public static function index<C:GuardedIf>(byIf: Map<String, C>, g: C): Void {
		final span: Null<Span> = g.ifNode.span;
		if (span != null) byIf['${span.from}:${span.to}'] = g;
	}

	/**
	 * The edits for `violations` over `tree` of `source`: each reported `if` re-found in `byIf` and rewritten by `edit`,
	 * which is handed the type resolver the inversion reads (built from the first finding's file and `index`, none when
	 * nothing was reported), the edits one contains dropped.
	 */
	public static function edits<C:GuardedIf>(
		plugin: GrammarPlugin, source: String, tree: QueryNode, violations: Array<Violation>, index: Null<SymbolIndex>,
		byIf: Map<String, C>, edit: (candidate:C, types:Null<(QueryNode) -> Null<String>>) -> Null<FixEdit>
	): Array<FixEdit> {
		final types: Null<(QueryNode) -> Null<String>> = violations.length == 0
			? null
			: CheckScan.typeNominalResolver(source, plugin, tree, violations[0].file, index);
		return CanonicalEdit.dropContainedEdits(CheckScan.collectSpanEdits(violations, byIf, (m, _) -> edit(m, types)));
	}

}
