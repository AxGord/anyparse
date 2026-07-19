package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.ds.ObjectMap;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.BooleanLogic.BooleanLogicSupport;

/**
 * Shared scan helpers for the `run` / `fix` paths of the analysis checks.
 * A check parses INDEPENDENTLY in `run` and in `fix` — the platform's
 * thread-safety invariant forbids any shared mutable state or cache between
 * the two calls — so these are PURE static helpers taking the `(plugin,
 * source)` a check already holds. Not a base class (`Check` is an interface),
 * not a cache.
 */
@:nullSafety(Strict)
final class CheckScan {

	private function new() {}

	/**
	 * Parse `source` with `plugin`, or null on any parse failure — the tolerant
	 * parse every check's `run` / `fix` opens with (`Check` forbids throwing on
	 * unparseable input, so both failure modes collapse to null).
	 */
	public static function parseOrNull(plugin: GrammarPlugin, source: String): Null<QueryNode> {
		return try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
	}

	/**
	 * The autofix skeleton shared by every span-indexed `fix`: parse `source`,
	 * index its `indexKinds` nodes by `from:to`, then for each violation with a
	 * span re-find the flagged node and let `produce` build its edit (null to
	 * skip that one). Returns the batched edits (empty when `source` does not
	 * parse). `produce` closes over the check's own seams and `source`; the
	 * helper owns only the parse + span-lookup boilerplate.
	 */
	public static function applyBySpan(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>, indexKinds: Array<String>,
		produce: (node:QueryNode, span:Span) -> Null<{ span: Span, text: String }>
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(tree, indexKinds, byKey);
		return collectSpanEdits(violations, byKey, produce);
	}

	/**
	 * The null-comparison flavour of `simplifyConditionFixes`: `!=` is always-true,
	 * `==` always-false. Shared verbatim by `dead-null-guard` and
	 * `unnecessary-null-check`, whose `fix` differ only in how `run` proved the
	 * operand non-null — the rewrite is identical.
	 */
	public static function simplifyNullComparisonFixes(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final eq: Null<String> = shape.eqKind;
		final notEq: Null<String> = shape.notEqKind;
		if (eq == null || notEq == null) return [];
		final ne: String = notEq;
		return simplifyConditionFixes(plugin, source, violations, [eq, notEq], node -> node.kind == ne);
	}

	/**
	 * Rewrite each flagged provably-constant boolean comparison, dropping it where a
	 * safe span edit exists and refusing (leaving it a finding) everywhere else. The
	 * flagged node is recovered by span (its kind is in `flaggedKinds`); `alwaysTrueOf`
	 * gives its constant polarity (an `x != null` / `x is T` is always-true, an
	 * `x == null` always-false). Two rewrite shapes only:
	 *
	 *  - (a) the SOLE condition of a no-`else` `if` statement — an always-true one
	 *    unwraps the body, an always-false one deletes the whole `if` (both refuse
	 *    when a comment sits in the removed region, never silently dropping it);
	 *  - (b) a direct operand of a homogeneous same-operator logical chain — an
	 *    always-true conjunct is dropped from `&&`, an always-false disjunct from
	 *    `||` (both identities). A mixed `&&`/`||` nesting, a parenthesised operand,
	 *    a ternary / other expression position, or an `else`-bearing `if` all refuse.
	 *
	 * Edits are de-overlapped (two conjuncts flagged in one chain, or a dead `if`
	 * inside a dead `if`) so the batch applies cleanly; the deferred ones converge on
	 * a later `--fix` pass. The result is re-emitted through the canonical writer by
	 * the caller, which re-indents an unwrapped body and validates the splice.
	 */
	public static function simplifyConditionFixes(
		plugin: GrammarPlugin, source: String, violations: Array<Violation>, flaggedKinds: Array<String>, alwaysTrueOf: (QueryNode) -> Bool
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final shape: RefShape = plugin.refShape();
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		final seams: CondSimplifySeams = {
			ifKinds: shape.ifStatementKinds ?? [],
			andKind: shape.logicalAndKind ?? '',
			orKind: shape.logicalOrKind ?? '',
			parenKind: shape.parenKind ?? '',
			blockKinds: support != null ? support.blockKinds() : []
		};
		final parents: ObjectMap<QueryNode, QueryNode> = new ObjectMap();
		fillParents(root, parents);
		final byKey: Map<String, QueryNode> = [];
		RefactorSupport.indexNodesByKind(root, flaggedKinds, byKey);
		return nonOverlappingEdits(collectSpanEdits(
			violations, byKey, (node, _) -> conditionEdit(node, alwaysTrueOf(node), parents, source, seams)
		));
	}

	/**
	 * The source text of a negation of `cond`, comment-preserving — the shared
	 * condition-inverting engine of `loop-guard` and `guard-continue`.
	 *
	 * When a grammar `support` is passed AND the condition span holds no comment marker, the
	 * negation is delegated to `BooleanLogicSupport.negateCondition`: De Morgan pushed inward
	 * (`a && b` → `!a || !b`) NaN-safely — ordered comparisons stay wrapped `!(a < b)`, never
	 * flipped. The comment scan is STRING-LITERAL-BLIND: a `//` or `/*` inside a string operand
	 * conservatively forces the fallback (a verbatim `!(cond)` wrap — correct output, just not
	 * De-Morganed). With no `support`, or a comment in the condition span, the text engine below
	 * is used, in three shapes, in order:
	 *
	 *  - a leading logical-not is STRIPPED (`!e` → `e`), unwrapping one redundant paren
	 *    (`!(a && b)` → `a && b`, `!!x` → `!x`) — the inner source verbatim;
	 *  - an `==` / `!=` is FLIPPED (`a == b` → `a != b` and back), NaN-safe (IEEE
	 *    `NaN == x` is false and `NaN != x` true) — UNLESS a comment sits in the operator
	 *    gap, which the flip would drop, so it falls through to the verbatim wrap;
	 *  - everything else (ordered comparisons `< <= > >=`, `&& || ?? ?:`, a call, …) is
	 *    wrapped `!(<cond>)` VERBATIM — the only sound negation for `<` / `>=` (they DIFFER
	 *    from their flips under NaN) and comment-preserving for every shape. A bare atomic
	 *    (`atomicKinds`) drops the parens (`!cond`); the wrap is always fully parenthesised,
	 *    so a low-precedence body (`a ?? b`, `c ? t : e`) negates correctly.
	 *
	 * For every standard type and normal abstract this is exactly `!(cond)`. The flip and
	 * strip assume standard boolean algebra, so they are UNSOUND only for the pathological
	 * case of a Haxe abstract that overloads `==` / `!=` non-complementarily or `!`
	 * non-involutively (`@:op`) — where `a != b` need not be `!(a == b)`; the
	 * always-parenthesised wrap is the sound form there. This edge is shared with `loop-guard`.
	 */
	public static function negateConditionText(
		cond: QueryNode, source: String, seams: NegationSeams, ?support: BooleanLogicSupport
	): String {
		final cs: Null<Span> = cond.span;
		if (cs == null) return '';
		if (support != null && !hasCommentMarker(source, cs.from, cs.to)) return support.negateCondition(cond, source);
		final notKind: Null<String> = seams.notKind;
		if (notKind != null && cond.kind == notKind && cond.children.length >= 1) {
			var inner: QueryNode = cond.children[0];
			final parenKind: Null<String> = seams.parenKind;
			if (parenKind != null && inner.kind == parenKind && inner.children.length == 1) inner = inner.children[0];
			final innerSpan: Null<Span> = inner.span;
			if (innerSpan != null) return source.substring(innerSpan.from, innerSpan.to);
		}
		final eqKind: Null<String> = seams.eqKind;
		final notEqKind: Null<String> = seams.notEqKind;
		if (eqKind != null && notEqKind != null && (cond.kind == eqKind || cond.kind == notEqKind) && cond.children.length == 2) {
			final l: Null<Span> = cond.children[0].span;
			final r: Null<Span> = cond.children[1].span;
			if (l != null && r != null && !hasCommentMarker(source, l.to, r.from)) {
				final op: String = cond.kind == eqKind ? ' != ' : ' == ';
				return source.substring(l.from, l.to) + op + source.substring(r.from, r.to);
			}
		}
		final src: String = source.substring(cs.from, cs.to);
		return seams.atomicKinds.contains(cond.kind) ? '!$src' : '!($src)';
	}

	/**
	 * Whether `[from, to)` of `source` holds a `//` or `/*` comment marker — a
	 * conservative "don't delete a comment" guard (a marker inside a string only ever
	 * refuses a fix, never deletes code, the safe direction for an autofix).
	 */
	public static function hasCommentMarker(source: String, from: Int, to: Int): Bool {
		if (from >= to) return false;
		final s: String = source.substring(from, to);
		return s.indexOf('//') != -1 || s.indexOf('/*') != -1;
	}

	/**
	 * Iterate `violations`, recover each flagged node from `byKey` by its `from:to`
	 * span, and collect the non-null edits `produce` builds — the span-lookup loop
	 * shared by `applyBySpan` and `simplifyConditionFixes`.
	 */
	private static function collectSpanEdits(
		violations: Array<Violation>, byKey: Map<String, QueryNode>,
		produce: (node:QueryNode, span:Span) -> Null<{ span: Span, text: String }>
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final node: Null<QueryNode> = byKey['${span.from}:${span.to}'];
			if (node == null) continue;
			final edit: Null<{ span: Span, text: String }> = produce(node, span);
			if (edit != null) edits.push(edit);
		}
		return edits;
	}

	/**
	 * The edit for one flagged constant comparison `node`, or null (refuse). Shape (a)
	 * when `node` is the sole condition of a no-`else` `if`; shape (b) when it is a
	 * direct operand of the matching homogeneous logical chain (`&&` for always-true,
	 * `||` for always-false); refuse otherwise.
	 */
	private static function conditionEdit(
		node: QueryNode, alwaysTrue: Bool, parents: ObjectMap<QueryNode, QueryNode>, source: String, seams: CondSimplifySeams
	): Null<{ span: Span, text: String }> {
		final parent: Null<QueryNode> = parents.get(node);
		if (parent == null) return null;
		if (seams.ifKinds.contains(parent.kind) && parent.children.length == 2 && parent.children[0] == node)
			return ifShapeEdit(parent, alwaysTrue, parents, source, seams);
		final wantKind: String = alwaysTrue ? seams.andKind : seams.orKind;
		return wantKind != '' && parent.kind == wantKind && homogeneousChain(parent, wantKind, parents, seams)
			? dropOperandEdit(parent, node, source)
			: null;
	}

	/**
	 * Shape (a): `ifNode` is a no-`else` `if` whose sole condition is a proven
	 * constant. Always-true replaces the whole `if` with its body source (a bare
	 * block keeps its braces, preserving scope); always-false deletes the `if`
	 * (line-extended when it sits in a statement list, else `{}` so an enclosing
	 * branch is not orphaned). Refuses when a comment sits in any removed region.
	 */
	private static function ifShapeEdit(
		ifNode: QueryNode, alwaysTrue: Bool, parents: ObjectMap<QueryNode, QueryNode>, source: String, seams: CondSimplifySeams
	): Null<{ span: Span, text: String }> {
		final ns: Null<Span> = ifNode.span;
		final body: QueryNode = ifNode.children[1];
		final bs: Null<Span> = body.span;
		if (ns == null || bs == null) return null;
		// An always-true guard keeps only the body — refuse if a comment sits in the removed
		// `if (…)` header or trailing region (comments inside the body are preserved).
		if (alwaysTrue) return hasCommentMarker(source, ns.from, bs.from) || hasCommentMarker(source, bs.to, ns.to) ? null : {
			span: ns,
			text: source.substring(bs.from, bs.to)
		};
		if (hasCommentMarker(source, ns.from, ns.to)) return null;
		final ifParent: Null<QueryNode> = parents.get(ifNode);
		final inBlock: Bool = ifParent != null && seams.blockKinds.contains(ifParent.kind);
		return inBlock ? { span: RefactorSupport.lineExtendedSpan(source, ns), text: '' } : { span: ns, text: '{}' };
	}

	/**
	 * Shape (b): drop `operand` (one of the two children of the binary logical
	 * `chain` node) together with its adjacent operator — the right operand deletes
	 * `[left.to, right.to)` (` && x`), the left deletes `[left.from, right.from)`
	 * (`x && `). The surviving operand's source (its parentheses included) is
	 * untouched. Refuses when a comment sits in the removed operator / operand region.
	 */
	private static function dropOperandEdit(chain: QueryNode, operand: QueryNode, source: String): Null<{ span: Span, text: String }> {
		if (chain.children.length != 2) return null;
		final left: QueryNode = chain.children[0];
		final right: QueryNode = chain.children[1];
		final ls: Null<Span> = left.span;
		final rs: Null<Span> = right.span;
		if (ls == null || rs == null) return null;
		// Drop the operand together with its adjacent operator: the right operand deletes
		// `[left.to, right.to)` (` && x`), the left `[left.from, right.from)` (`x && `).
		final drop: Null<Span> = operand == right ? new Span(ls.to, rs.to) : operand == left ? new Span(ls.from, rs.from) : null;
		return drop == null || hasCommentMarker(source, drop.from, drop.to) ? null : { span: drop, text: '' };
	}

	/**
	 * Whether every logical ancestor of `node` up to the first non-logical boundary is
	 * the SAME operator as `wantKind` — a pure `&&` (or pure `||`) chain. A different
	 * logical operator (mixed `&&`/`||`) or a parenthesised wrap returns false, so the
	 * conservative drop fires only inside a homogeneous chain.
	 */
	private static function homogeneousChain(
		node: QueryNode, wantKind: String, parents: ObjectMap<QueryNode, QueryNode>, seams: CondSimplifySeams
	): Bool {
		var cur: QueryNode = node;
		while (true) {
			final p: Null<QueryNode> = parents.get(cur);
			if (p == null) return true;
			if (p.kind == seams.andKind || p.kind == seams.orKind) {
				if (p.kind != wantKind) return false;
				cur = p;
			} else
				return p.kind != seams.parenKind;
		}
	}

	/** Record each node's parent, so a flagged node can be classified by its enclosing context. */
	private static function fillParents(node: QueryNode, out: ObjectMap<QueryNode, QueryNode>): Void {
		for (c in node.children) {
			out.set(c, node);
			fillParents(c, out);
		}
	}

	/**
	 * Keep a maximal non-overlapping subset of `edits` (earliest span first) so the
	 * `RefactorSupport.applyEdits` no-overlap contract holds — two conjuncts flagged
	 * in one chain, or a dead `if` nested in a dead `if`, would otherwise splice
	 * overlapping deletions. The dropped edits converge on a later `--fix` pass.
	 */
	private static function nonOverlappingEdits(edits: Array<{ span: Span, text: String }>): Array<{ span: Span, text: String }> {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> a.span.from - b.span.from);
		final kept: Array<{ span: Span, text: String }> = [];
		var lastTo: Int = -1;
		for (e in sorted) if (e.span.from >= lastTo) {
			kept.push(e);
			lastTo = e.span.to;
		}
		return kept;
	}

}

/** The condition / logical / block seam kinds `simplifyConditionFixes` reads from the grammar. */
private typedef CondSimplifySeams = {
	final ifKinds: Array<String>;
	final andKind: String;
	final orKind: String;
	final parenKind: String;
	final blockKinds: Array<String>;
};

/**
 * The condition-kind seams `CheckScan.negateConditionText` reads to invert a condition:
 * the logical-not (`notKind`) it strips, the paren (`parenKind`) it unwraps, the
 * `==` / `!=` kinds (`eqKind` / `notEqKind`) it flips, and the atomic-expression kinds
 * (`atomicKinds`) that take a bare `!` rather than `!(…)`.
 */
typedef NegationSeams = {
	final notKind: Null<String>;
	final parenKind: Null<String>;
	final eqKind: Null<String>;
	final notEqKind: Null<String>;
	final atomicKinds: Array<String>;
};
