package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags the function-tail shape `if (cond) x = e; return x;` -- a single-branch `if`
 * whose body is exactly one plain assignment to a LOCAL, immediately followed by a
 * `return` of that same local -- and collapses the pair to `return cond ? e : x;`.
 * `Info` -- the code is correct, this is a readability simplification. The
 * conditional-reassignment sibling of `join-return` (which joins an UNCONDITIONAL
 * `x = e; return x;`) and of `prefer-ternary-assignment` (which needs an `else`).
 *
 * ```haxe
 * if (errorMessages.length == 0) errorMessages = unknownErrorMessage(localize);
 * return errorMessages;
 * // ->
 * return errorMessages.length == 0 ? unknownErrorMessage(localize) : errorMessages;
 * ```
 *
 * ## What is flagged
 *
 * Two CONSECUTIVE statements of one statement list (`ControlFlowSupport.blockKinds`),
 * every gate failing closed:
 *
 * - the first is an `if` STATEMENT with NO `else` (exactly `[condition, then]`) whose
 *   then-branch is ONE statement -- a bare `x = e;` expression statement, or a
 *   `{ x = e; }` wrapping exactly one;
 * - that statement is a PLAIN `=` assignment (`assignKind`) whose l-value is the BARE
 *   identifier `x`. A compound (`+=`, `??=`) is a distinct node kind and never matches;
 *   a member path (`o.x = e`) never matches either, since only a bare identifier can
 *   resolve to a binding;
 * - the second statement is `return x;` -- the SAME name, with nothing in between and
 *   at the same nesting level (they are siblings of one block);
 * - `x` resolves to a LOCAL or PARAM (`TypeResolver.mayBeLocalOrParam`), NEVER a
 *   field: a bare field write can run a property setter, whose side effect the collapse
 *   would drop;
 * - NO reference to `x`'s binding is CAPTURED by a NESTED FUNCTION -- a lambda, a named
 *   `function g() {}` or an `inline function` (`lambdaKinds` + `localFunctionKinds` +
 *   `inlineFunctionKinds`). Captured means the reference sits inside a nested function that
 *   does NOT enclose the declaration: such a closure could observe the dropped store after
 *   the return. A reference in the nested function that OWNS the binding is not a capture, so
 *   a pair entirely local to a lambda still fires;
 * - the ONLY write to `x` inside the collapsed region is the l-value itself. The r-value
 *   may READ `x` (`x = x + 1` -- it evaluates before the conceptual write, exactly as the
 *   ternary's then-branch does), but a write to `x` in the CONDITION or inside `e` makes
 *   the ordering argument non-obvious and is refused;
 * - the enclosing function declares an EXPLICIT RETURN TYPE
 *   (`TypeResolver.functionReturnTypeSource`). In `x = e` the r-value is typed with `x`'s
 *   declared type as the EXPECTED type; in the ternary that expected type comes from the
 *   `return` position instead, so an INFERRED return type loses it -- and
 *   `var x:Map<String, Int> = null; if (c) x = [];` would emit a `return c ? [] : x;` that
 *   does NOT typecheck. A local `function` / lambda without a return annotation is the
 *   common case, so this gate also keeps the rule out of most closure bodies.
 *
 * An R-VALUE that already spans LINES -- an object or array literal -- is NOT flagged at all:
 * it keeps its own brace layout inside the ternary and pushes the `: x` else-tail past the
 * closing `}`, where it reads worse than the `if` it would replace. A single-line r-value that
 * merely overflows the line budget is fine, and a multi-line CONDITION is not refused either:
 * the writer re-lays the whole ternary, and the merge is exactly what un-uglifies a condition
 * the `if` header had to wrap mid-argument-list.
 *
 * The reported span is the `if` statement.
 *
 * ## Autofix
 *
 * `fix` replaces the `if`-statement-through-`return` span with `return cond ? e : x;`,
 * copying the condition, the r-value and the returned identifier verbatim from their
 * spans. The condition is wrapped in parentheses only when it binds no tighter than `?:`
 * (a ternary, or an assignment) so precedence is preserved; every tighter-binding
 * condition is emitted bare, per the no-redundant-parens preference. The replacement is
 * emitted on ONE line and the WRITER lays it out -- an over-long merge wraps into the
 * project's ternary layout through the same `RefactorSupport.canonicalize` every fix
 * goes through, so this check owns no wrapping policy.
 *
 * A comment inside the collapsed region but OUTSIDE the three verbatim-copied spans
 * (i.e. on the `if (` / `) ` glue, on `x =`, on the `;`, between the two statements, or
 * on the `return` keyword) would be dropped by the rebuild. Such a site stays
 * REPORT-ONLY: the finding is still reported -- with a message saying so -- but `fix`
 * produces no edit for it. A comment INSIDE the condition, the r-value or the returned
 * identifier rides along verbatim and does not block the fix.
 *
 * ## Default OFF -- opt-in
 *
 * A `DefaultOff` marker: dropped from the default set and from a bare `lint ... --all`
 * report unless a project opts in via `apqlint.json`
 * (`"rules": { "return-reassign-ternary": { "enabled": true } }`), or an explicit
 * `--rule return-reassign-ternary` selects it.
 *
 * ## Composition -- each rule does its own job
 *
 * The merge is NOT chained with anything inside this check. After it lands, `x`'s only
 * remaining write may be its initializer, and the existing `prefer-final` then converts
 * `var x = init;` to `final x = init;` on a LATER pass of the `--fix` fixed-point loop.
 * The counter-case is an accumulator (the shape this rule was written from, TM
 * `src/api/API.hx`): a `+=` in a preceding loop keeps `x` a `var`, so only the tail
 * merges and `prefer-final` correctly does not follow.
 *
 * Needs `ifStatementKinds`, `returnStatementKind`, `exprStatementKind`, `assignKind`,
 * `functionBodyKinds` and
 * `controlFlowSupport` (any unset makes the check a no-op); the braced-body form
 * additionally reads `blockStmtKind`; the local/param gate reads `localDeclKinds` /
 * `paramKinds`; the capture gate reads `lambdaKinds` / `localFunctionKinds` /
 * `inlineFunctionKinds`; and the return-type gate reads `functionKinds` / `lambdaKinds`.
 */
@:nullSafety(Strict)
final class ReturnReassignTernary implements Check implements DefaultOff {

	/** The rule's stable identifier -- the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'return-reassign-ternary';

	/** The finding message when the pair collapses cleanly. */
	private static inline final MSG_FIXABLE: String =
		'this conditional reassignment and its next-line return can be a single ternary return';

	/** The finding message when a comment in a dropped region keeps the site report-only. */
	private static inline final MSG_COMMENT: String = MSG_FIXABLE + ' (a comment blocks the autofix)';

	/** A no-else `if` projects exactly [condition, then-branch]. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** A valued `return` node has exactly one child: the returned expression. */
	private static inline final RETURN_VALUE_CHILD_COUNT: Int = 1;

	/** An expression statement wraps exactly one expression (here, the assignment). */
	private static inline final EXPR_STMT_CHILD_COUNT: Int = 1;

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a single-branch if-reassignment of a local immediately followed by a return of it, collapsible to a ternary return';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		return seams == null ? [] : [
			for (entry in files) for (m in matchesIn(entry.source, plugin, seams))
				{
					file: entry.file,
					span: m.ifSpan,
					rule: RULE_ID,
					severity: Severity.Info,
					message: m.text == null ? MSG_COMMENT : MSG_FIXABLE
				}
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final byKey: Map<String, Match> = [];
		for (m in matchesIn(source, plugin, seams)) byKey['${m.ifSpan.from}:${m.ifSpan.to}'] = m;

		return RefactorSupport.dropContainedEdits(CheckScan.collectSpanEdits(violations, byKey, (m, _) -> {
			final text: Null<String> = m.text;
			// A dropped comment leaves the finding report-only: no edit for this site.
			return text == null ? null : { span: m.editSpan, text: text };
		}));
	}

	/** Every collapsible pair in `source` -- the one traversal `run` and `fix` share. */
	private static function matchesIn(source: String, plugin: GrammarPlugin, s: Seams): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final nestedFnSpans: Array<Span> = [];
		collectNestedFnSpans(root, s.nestedFnKinds, nestedFnSpans);
		final out: Array<Match> = [];
		collectMatches(root, source, comments, s, root, nestedFnSpans, false, out);
		return out;
	}

	/** Bundle the required `RefShape` / control-flow kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.length == 0) return null;
		final returnKind: Null<String> = shape.returnStatementKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		if (returnKind == null || exprStmtKind == null || assignKind == null) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? null : {
			ifKinds: ifKinds,
			returnKind: returnKind,
			exprStmtKind: exprStmtKind,
			assignKind: assignKind,
			identKind: shape.identKind,
			blockStmtKind: shape.blockStmtKind,
			localDeclKinds: shape.localDeclKinds ?? [],
			paramKinds: shape.paramKinds ?? [],
			bodyKinds: shape.functionBodyKinds ?? [],
			// EVERY nested-function kind, not just the arrow lambdas: a named `function g() {}`
			// (`localFunctionKinds`) and an `inline function` (`inlineFunctionKinds`) capture a
			// binding exactly as a lambda does, and omitting them opens the capture gate.
			nestedFnKinds: (shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []),
			fnKinds: (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []),
			blockKinds: support.blockKinds(),
			shape: shape
		};
	}

	/** Walk `node`; at each statement list collect the collapsible `if`/`return` pairs. */
	private static function collectMatches(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, tree: QueryNode,
		nestedFnSpans: Array<Span>, retTyped: Bool, out: Array<Match>
	): Void {
		if (retTyped && s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length - 1) {
				final m: Null<Match> = matchPair(kids[i], kids[i + 1], source, comments, s, tree, nestedFnSpans);
				if (m != null) out.push(m);
			}
		}
		final childRetTyped: Bool = s.fnKinds.contains(node.kind)
			? TypeResolver.functionReturnTypeSource(node, source, s.bodyKinds, s.paramKinds) != null
			: retTyped;
		for (c in node.children) collectMatches(c, source, comments, s, tree, nestedFnSpans, childRetTyped, out);
	}

	/**
	 * The collapse match for a no-else `if` reassigning a local immediately followed by a
	 * `return` of it, or null when any gate refuses (see the class doc). `text` is null when
	 * a comment would be dropped -- the site is then reported but not fixed.
	 */
	private static function matchPair(
		ifNode: QueryNode, ret: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams,
		tree: QueryNode, lambdaSpans: Array<Span>
	): Null<Match> {
		if (!s.ifKinds.contains(ifNode.kind) || ifNode.children.length != IF_NO_ELSE_CHILD_COUNT) return null;
		final assign: Null<QueryNode> = assignmentIn(ifNode.children[1], s);
		if (assign == null) return null;
		final lhs: QueryNode = assign.children[0];
		final name: Null<String> = lhs.name;
		if (lhs.kind != s.identKind || name == null) return null;

		if (ret.kind != s.returnKind || ret.children.length != RETURN_VALUE_CHILD_COUNT) return null;
		final retIdent: QueryNode = ret.children[0];
		if (retIdent.kind != s.identKind || retIdent.name != name) return null;

		final condition: QueryNode = ifNode.children[0];
		final rhs: QueryNode = assign.children[1];
		final ifSpan: Null<Span> = ifNode.span;
		final condSpan: Null<Span> = condition.span;
		final rhsSpan: Null<Span> = rhs.span;
		final lhsSpan: Null<Span> = lhs.span;
		final retSpan: Null<Span> = ret.span;
		final retIdentSpan: Null<Span> = retIdent.span;
		if (ifSpan == null || condSpan == null || rhsSpan == null || lhsSpan == null || retSpan == null || retIdentSpan == null)
			return null;

		// An r-value that already spans lines (an object / array literal) keeps its own
		// brace layout inside the ternary and strands the `: x` tail after the closing `}`
		// -- the merge then reads WORSE than the guard it replaces, so refuse it. A
		// multi-line CONDITION is not refused: the writer re-lays the whole ternary, and
		// the merge is exactly what un-uglifies a condition the `if` header had to wrap.
		if (spansLines(source, rhsSpan)) return null;
		if (!bindingIsSafeLocal(name, lhsSpan, ifSpan, retSpan, tree, s, lambdaSpans)) return null;

		final kept: Array<Span> = [condSpan, rhsSpan, retIdentSpan];
		final blocked: Bool = droppedComment(ifSpan.from, retSpan.to, kept, comments);
		final merged: String = 'return ${wrapCondition(source.substring(condSpan.from, condSpan.to), condition.kind, s.shape)} ? '
			+ '${source.substring(rhsSpan.from, rhsSpan.to)} : ${source.substring(retIdentSpan.from, retIdentSpan.to)};';
		return {
			ifSpan: ifSpan,
			editSpan: new Span(ifSpan.from, retSpan.to),
			text: blocked ? null : merged
		};
	}

	/**
	 * The lone plain-`=` assignment (two children: l-value, r-value) that is the single
	 * statement of `branch` -- a bare `x = e;` expression statement or a `{ x = e; }`
	 * wrapping exactly one. Null when `branch` is anything else (a compound `+=` / `??=`,
	 * an increment, a call, or a multi-statement block).
	 */
	private static function assignmentIn(branch: QueryNode, s: Seams): Null<QueryNode> {
		final blockStmtKind: Null<String> = s.blockStmtKind;
		final stmt: QueryNode = blockStmtKind != null && branch.kind == blockStmtKind && branch.children.length == 1
			? branch.children[0]
			: branch;
		if (stmt.kind != s.exprStmtKind || stmt.children.length != EXPR_STMT_CHILD_COUNT) return null;
		final assign: QueryNode = stmt.children[0];
		return assign.kind == s.assignKind && assign.children.length == ASSIGN_CHILD_COUNT ? assign : null;
	}

	/**
	 * Whether the l-value at `lhsSpan` resolves to a LOCAL or PARAM binding that no lambda
	 * captures and that the collapsed region `[ifFrom, retTo)` writes ONLY through that very
	 * l-value. Every failure direction returns false -- a field target, an unresolved binding,
	 * a capture, or a second write (in the condition or inside the r-value) all refuse.
	 */
	private static function bindingIsSafeLocal(
		name: String, lhsSpan: Span, ifSpan: Span, retSpan: Span, tree: QueryNode, s: Seams, nestedFnSpans: Array<Span>
	): Bool {
		final hits: Array<RefHit> = Refs.find(name, tree, s.shape);
		var binding: Null<Span> = null;
		for (h in hits) if (h.kind == RefKind.Write && h.span.from == lhsSpan.from && h.span.to == lhsSpan.to) {
			binding = h.bindingSpan;
			break;
		}
		if (binding == null) return false;
		final b: Span = binding;
		if (!TypeResolver.mayBeLocalOrParam(tree, b.from, s.localDeclKinds, s.paramKinds)) return false;
		for (h in hits) {
			final bs: Null<Span> = h.bindingSpan;
			if (bs == null || bs.from != b.from || bs.to != b.to) continue;
			if (h.kind != RefKind.Decl && capturedByNestedFn(h.span, b, nestedFnSpans)) return false;
			if (h.kind != RefKind.Write) continue;
			final isLvalue: Bool = h.span.from == lhsSpan.from && h.span.to == lhsSpan.to;
			if (!isLvalue && h.span.from >= ifSpan.from && h.span.to <= retSpan.to) return false;
		}
		return true;
	}

	/** Parenthesise the condition iff it binds no tighter than `?:` (a ternary or an assignment); else emit it bare. */
	private static function wrapCondition(source: String, kind: String, shape: RefShape): String {
		final ternaryKind: Null<String> = shape.ternaryKind;
		final needsParens: Bool = (ternaryKind != null && kind == ternaryKind) || shape.writeParentKinds.contains(kind);
		return needsParens ? '($source)' : source;
	}

	/**
	 * Whether a comment sits inside the collapsed region `[from, to)` but outside every
	 * verbatim-copied span in `kept` (the condition, the r-value, the returned identifier).
	 * Such a comment would be lost by the rebuild, so the site degrades to report-only.
	 */
	private static function droppedComment(
		from: Int, to: Int, kept: Array<Span>, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Bool {
		for (tok in comments) if (tok.from >= from && tok.to <= to) {
			var inside: Bool = false;
			for (k in kept) if (tok.from >= k.from && tok.to <= k.to) {
				inside = true;
				break;
			}
			if (!inside) return true;
		}
		return false;
	}

	/**
	 * Whether the source text of `span` covers more than one line -- the r-value gate. A
	 * multi-line r-value (an object or array literal) keeps its own brace layout inside the
	 * ternary, pushing the `: x` else-tail past the closing `}` where it reads worse than the
	 * `if` it replaces -- such a site is not flagged at all. A multi-line CONDITION is fine: the
	 * writer re-lays the whole ternary around it.
	 */
	private static function spansLines(source: String, span: Span): Bool {
		return source.substring(span.from, span.to).indexOf('\n') >= 0;
	}

	/** Whether `span` is nested inside any lambda span in `lambdaSpans` -- i.e. a captured reference. */
	private static function capturedByNestedFn(span: Span, binding: Span, fnSpans: Array<Span>): Bool {
		for (fs in fnSpans) if (fs.from <= span.from && span.to <= fs.to && (fs.from > binding.from || binding.to > fs.to)) return true;
		return false;
	}

	/** Collect the span of every lambda (`RefShape.lambdaKinds`) reachable under `node`. */
	private static function collectNestedFnSpans(node: QueryNode, fnKinds: Array<String>, out: Array<Span>): Void {
		if (fnKinds.contains(node.kind)) {
			final sp: Null<Span> = node.span;
			if (sp != null) out.push(sp);
		}
		for (c in node.children) collectNestedFnSpans(c, fnKinds, out);
	}

}

/** The kinds `ReturnReassignTernary` reads. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var returnKind: String;
	var exprStmtKind: String;
	var assignKind: String;
	var identKind: String;
	var blockStmtKind: Null<String>;
	var localDeclKinds: Array<String>;
	var paramKinds: Array<String>;
	var bodyKinds: Array<String>;
	var nestedFnKinds: Array<String>;
	var fnKinds: Array<String>;
	var blockKinds: Array<String>;
	var shape: RefShape;
}

/** A collapsible pair: the `if` span (finding key), the replaced span, and the merged text (null = report-only). */
private typedef Match = {
	var ifSpan: Span;
	var editSpan: Span;
	var text: Null<String>;
}
