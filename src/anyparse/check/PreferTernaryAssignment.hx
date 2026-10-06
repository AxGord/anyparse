package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.DeclFallbackChain.DeclSeams;
import anyparse.query.BoolExprShape;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.ParenGuard;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `if (cond) lhs = a; else lhs = b;` whose two branches assign the SAME
 * l-value with a plain `=`, collapsing the pair to a single
 * `lhs = cond ? a : b;`. Purely structural (no type information), so it holds
 * without a type-checker. `Info` -- the code is correct, this is a readability
 * simplification (the sibling of `prefer-ternary-return`, for assignment rather
 * than `return`).
 *
 * ## Boundary with `prefer-if-expression-assignment`
 *
 * A flat 2-branch whose TERMINAL r-value is ALREADY a ternary belongs to that rule, whose one
 * edit unrolls the spine into rungs. Collapsing onto such a value writes `x = c ? a : p ? q : r`
 * -- a three-rung chain `prefer-if-expression-chain` then reports, on text this fix just wrote.
 * The deferral ASKS that rule (`PreferIfExpressionAssignment.claims`), gates and all, rather than
 * mirroring its shape: a site it refuses -- a comment in a folded region, an else-less conditional
 * in a rung -- keeps its finding here instead of falling through to nobody.
 *
 * ## The decl arm
 *
 * `var x:T = init;` followed IMMEDIATELY by an else-less `if (c) x = a;` collapses to
 * `var x:T = c ? a : init;` -- the declaration supplies the value of the missing `else`. It is the
 * two-value case of the decl arm `prefer-if-expression-assignment` has for longer else-less chains,
 * and both ask ONE predicate, `DeclFallbackChain` (an explicit `:T`, a relocatable literal `init`,
 * adjacency, no other occurrence of `x` in the `if`); its `ownedByTernary` gives this rule the
 * sites whose single branch is a plain assignment. The finding is keyed on the declaration; the
 * narrowing-guard and dropped-comment refusals are the ordinary arm's. The `var` is kept;
 * `prefer-final` upgrades it.
 *
 * ## What is flagged
 *
 * An `if` STATEMENT with an `else` (exactly `[condition, then, else]`) whose:
 *
 * - else branch is NOT itself an `if` -- an else-if chain is `prefer-switch`
 *   territory and is left alone;
 * - both branches are exactly ONE statement -- a bare `lhs = e;` expression
 *   statement or a braced `{ lhs = e; }` wrapping exactly one (a multi-statement
 *   block is deliberately grouped and never matched);
 * - both statements are PLAIN `=` assignments (`assignKind`, an l-value and an
 *   r-value). Compound operators are deliberately EXCLUDED: a short-circuit `??=`
 *   would change behaviour (its r-value -- now the ternary holding the condition --
 *   is skipped when the l-value is non-null, so the condition stops being
 *   evaluated), and an ordinary compound (`+=`, …) whose two r-values do not unify
 *   to one type (`s += anInt` vs `s += "text"`) compiles per-branch but not as one
 *   ternary. Plain `=` flows the l-value's type into both branches, sidestepping
 *   both (`++` / `--`, being single-operand, never match either);
 * - the two l-values are TEXTUALLY IDENTICAL (whitespace-normalized source).
 *
 * A null-narrowing guard condition (`x != null && x.f`) is refused ONLY when an r-value is a bool
 * literal -- that collapse hands off to
 * `simplify-boolean-ternary`, whose boolean flattening would lose the
 * in-condition narrowing under `@:nullSafety(Strict)`; a VALUE collapse keeps
 * the narrowing (the ternary condition types exactly like the if) and is
 * allowed. The reported span is the whole `if` statement.
 *
 * ## Autofix
 *
 * `fix` replaces the whole `if`/`else` with `lhs op cond ? thenRhs : elseRhs;`.
 * The l-value and operator are copied verbatim from the then-branch, the two
 * r-values and the condition verbatim from their spans, so the one surviving
 * l-value evaluation (down from two textual occurrences -- the safe direction)
 * matches the original exactly. The condition is a `ParenGuard` hole: it gains parentheses exactly where it
 * would bind across `?` bare (a ternary, an assignment, an arrow lambda, `in`); every other condition is emitted
 * bare, per the no-redundant-parens preference. A comment inside a DROPPED region of the collapsed `if` (the
 * header, the else l-value, the braces) would be lost, so such an `if` is left
 * unflagged -- following `prefer-safe-nav`'s comment guard. Needs
 * `ifStatementKinds`, `exprStatementKind`, `blockStmtKind` (any unset makes the
 * check a no-op).
 */
@:nullSafety(Strict)
final class PreferTernaryAssignment implements Check {

	/** An `if` with an `else` has exactly [condition, then-branch, else-branch] children. */
	private static inline final IF_ELSE_CHILD_COUNT: Int = 3;

	/** A binary assignment node has exactly [l-value, r-value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** The finding message for the decl arm (a declaration and the one-branch `if` after it). */
	private static inline final DECL_MESSAGE: String =
		'this declaration and the else-less if assignment after it can be a single ternary initializer';

	public function new() {}

	public function id(): String {
		return 'prefer-ternary-assignment';
	}

	public function description(): String {
		return 'an if/else assigning the same l-value in both branches, collapsible to a single ternary assignment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final decl: Null<DeclSeams> = DeclFallbackChain.readSeams(plugin, AssignmentTreeHoist.readTreeSeams(plugin.refShape()));
		return RunScan.collectWith(files, plugin, readSeams(plugin.refShape()), (entry, tree, seams, violations) -> {
			final comments: Array<{ from: Int, to: Int, isLine: Bool }> =
				SourceComments.collectCommentTokens(plugin.lexicalRegions(entry.source));
			walk(tree, violations, entry.file, entry.source, comments, seams);
			if (decl != null) for (e in declEdits(tree, entry.source, comments, decl)) violations.push({
				file: entry.file,
				span: e.key,
				rule: 'prefer-ternary-assignment',
				severity: Severity.Info,
				message: DECL_MESSAGE
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin.refShape());
		if (seams == null) return [];
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		final guarded: Array<GuardedEdit> = [];
		final plain: Array<{ span: Span, text: String }> =
			CheckScan.applyBySpan(plugin, source, violations, seams.ifKinds, (node, span) -> {
				final m: Null<Match> = match(node, source, comments, seams);
				final edit: Null<GuardedEdit> = m == null ? null : buildEdit(m, source, span, seams.shape);
				if (edit != null) guarded.push(edit);
				return edit;
			});
		final decl: Null<DeclSeams> = DeclFallbackChain.readSeams(plugin, AssignmentTreeHoist.readTreeSeams(plugin.refShape()));
		final tree: Null<QueryNode> = decl == null ? null : CheckScan.parseOrNull(plugin, source);
		if (decl != null && tree != null) {
			final byKey: Map<String, GuardedEdit> = [];
			for (e in declEdits(tree, source, comments, decl)) byKey['${e.key.from}:${e.key.to}'] = e.edit;
			for (v in violations) {
				final edit: Null<GuardedEdit> = v.span == null ? null : byKey['${v.span.from}:${v.span.to}'];
				if (edit == null) continue;
				guarded.push(edit);
				plain.push(edit);
			}
		}
		// `plain` and `guarded` hold the same edits in the same order, so a containment index of one is the other's.
		return ParenGuard.guard(source, [
			for (i in 0...guarded.length) if (!CanonicalEdit.isContainedEdit(plain, i)) guarded[i]
		], plugin);
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final ifKinds: Null<Array<String>> = shape.ifStatementKinds;
		if (ifKinds == null || ifKinds.length == 0) return null;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		if (exprStmtKind == null) return null;
		final blockStmtKind: Null<String> = shape.blockStmtKind;
		if (blockStmtKind == null) return null;
		final assignKind: Null<String> = shape.assignKind;
		return assignKind == null ? null : {
			ifKinds: ifKinds,
			exprStmtKind: exprStmtKind,
			blockStmtKind: blockStmtKind,
			assignKind: assignKind,
			shape: shape
		};
	}

	/** Walk `node`, flagging each `if`/`else` whose two branches assign the same l-value with the same operator. */
	private static function walk(
		node: QueryNode, out: Array<Violation>, file: String, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, ?parent: QueryNode
	): Void {
		if (s.ifKinds.contains(node.kind) && !isElseIfLink(node, parent, s)) {
			final m: Null<Match> = match(node, source, comments, s);
			if (m != null) {
				final span: Null<Span> = node.span;
				if (span != null) out.push({
					file: file,
					span: span,
					rule: 'prefer-ternary-assignment',
					severity: Severity.Info,
					message: 'this if/else assignment can be a single ternary assignment'
				});
			}
		}
		for (c in node.children) walk(c, out, file, source, comments, s, node);
	}

	/**
	 * If `ifNode` is an `if`/`else` (no else-if) whose two branches are each a single
	 * binary assignment to a textually identical l-value with the same operator, and
	 * neither the condition carries a null-narrowing guard nor a comment sits in a
	 * dropped region, return the match parts; else null.
	 */
	private static function match(
		ifNode: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams
	): Null<Match> {
		if (ifNode.children.length != IF_ELSE_CHILD_COUNT) return null;
		final condition: QueryNode = ifNode.children[0];
		final elseBranch: QueryNode = ifNode.children[2];
		if (s.ifKinds.contains(elseBranch.kind)) return null;
		final thenRaw: Null<QueryNode> = assignmentIn(ifNode.children[1], s);
		final elseRaw: Null<QueryNode> = assignmentIn(elseBranch, s);
		if (thenRaw == null || elseRaw == null) return null;
		final thenAssign: QueryNode = thenRaw;
		final elseAssign: QueryNode = elseRaw;
		if (thenAssign.kind != elseAssign.kind) return null;
		if (!sameLvalue(thenAssign.children[0], elseAssign.children[0], source)) return null;
		final m: Match = {
			condition: condition,
			thenAssign: thenAssign,
			thenRhs: thenAssign.children[1],
			elseRhs: elseAssign.children[1]
		};
		// The narrowing-guard refusal fires only for a bool-literal collapse (see
		// RefactorSupport.refusesNullNarrowingBoolCollapse).
		// The r-value spine's third leaf belongs to `prefer-if-expression-assignment`: collapsing onto
		// a value that is ALREADY a ternary writes the three-rung `x = c ? a : p ? q : r`, which
		// `prefer-if-expression-chain` then reports — on code this fix just wrote. Asked of that rule
		// directly, gates and all, so a shape it refuses keeps its finding here.
		return BoolExprShape.refusesNullNarrowingBoolCollapse(m.thenRhs, m.elseRhs, condition, s.shape)
			|| droppedComment(ifNode, m, comments) || PreferIfExpressionAssignment.claims(ifNode, source, comments, s.shape)
			? null
			: m;
	}

	/**
	 * The lone plain-`=` assignment (two children: l-value, r-value) that is the single
	 * statement of `branch` -- a bare `x = e;` expression statement or a braced
	 * `{ x = e; }` wrapping exactly one. Null when `branch` is not a single plain
	 * assignment (a compound `+=` / `??=`, or an increment / decrement, is excluded).
	 */
	private static function assignmentIn(branch: QueryNode, s: Seams): Null<QueryNode> {
		final stmt: QueryNode = branch.kind == s.blockStmtKind && branch.children.length == 1 ? branch.children[0] : branch;
		if (stmt.kind != s.exprStmtKind || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		return assign.kind == s.assignKind && assign.children.length == ASSIGN_CHILD_COUNT ? assign : null;
	}

	/**
	 * Whether two l-value subtrees are the SAME l-value — identical whitespace-normalized
	 * source AND identical projected shape.
	 *
	 * Both halves are needed, and the normalisation alone is the unsafe one: it collapses
	 * whitespace runs INSIDE a string literal, so `m["a  b"]` and `m["a b"]` normalise
	 * equal and the fix collapsed the two branches onto the FIRST key — a silent change of
	 * which map entry is written. `structurallyEqual` compares literal content and closes
	 * that; the normalized text stays because shape equality cannot see a comment sitting
	 * inside an l-value's span. Same pairing, same reason, as `tail-merge`'s
	 * `sameStatement` and `redundant-case-body`'s `sameBody`.
	 */
	private static function sameLvalue(a: QueryNode, b: QueryNode, source: String): Bool {
		final aSpan: Null<Span> = a.span;
		final bSpan: Null<Span> = b.span;
		return aSpan != null && bSpan != null && MemberKinds.structurallyEqual(a, b)
			&& normalize(source.substring(aSpan.from, aSpan.to)) == normalize(source.substring(bSpan.from, bSpan.to));
	}

	/** Collapse whitespace runs to a single space and trim -- the l-value equality key. */
	private static function normalize(s: String): String {
		return StringTools.trim((~/\s+/g).replace(s, ' '));
	}

	/**
	 * Build the `lhs op cond ? thenRhs : elseRhs;` edit replacing the whole `if`/`else` span, the condition a `ParenGuard` hole.
	 * A ternary that only passes a nullable value through (`x != null ? x : null`) is written as that value.
	 */
	private static function buildEdit(m: Match, source: String, span: Span, shape: RefShape): Null<GuardedEdit> {
		final thenSpan: Null<Span> = m.thenAssign.span;
		final thenRhsSpan: Null<Span> = m.thenRhs.span;
		final condSpan: Null<Span> = m.condition.span;
		final elseRhsSpan: Null<Span> = m.elseRhs.span;
		if (thenSpan == null || thenRhsSpan == null || condSpan == null || elseRhsSpan == null) return null;
		final prefix: String = source.substring(thenSpan.from, thenRhsSpan.from);
		final thenRhs: String = source.substring(thenRhsSpan.from, thenRhsSpan.to);
		final elseRhs: String = source.substring(elseRhsSpan.from, elseRhsSpan.to);
		final passed: Null<GuardedEdit> = passThroughEdit(span, prefix, m.condition, m.thenRhs, m.elseRhs, source, shape);
		return passed ?? ParenGuard.ternaryEdit(span, prefix, source.substring(condSpan.from, condSpan.to), thenRhs, elseRhs, ';');
	}

	/**
	 * The decl arm's edits under `tree`, keyed by the declaration's span (the finding's): each pair
	 * `DeclFallbackChain` matches and hands to this rule (`ownedByTernary` — one plain-assignment
	 * branch), rebuilt as `var x:T = c ? a : init;` with the condition a `ParenGuard` hole. The same two
	 * refusals as the ordinary arm: a null-narrowing condition when a value is a bool literal, and a
	 * comment anywhere in the replaced region outside the copied prefix, condition, value and
	 * initializer.
	 */
	private static function declEdits(
		tree: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, d: DeclSeams
	): Array<{ key: Span, edit: GuardedEdit }> {
		final out: Array<{ key: Span, edit: GuardedEdit }> = [];
		for (m in DeclFallbackChain.collect(tree, source, comments, d)) if (DeclFallbackChain.ownedByTernary(m, d)) {
			final cond: QueryNode = m.branches[0].cond;
			final assign: Null<QueryNode> = AssignmentTreeHoist.plainAssign(m.branches[0].stmt, d.tree);
			final value: Null<QueryNode> = assign?.children[1];
			final condSpan: Null<Span> = cond.span;
			final valueSpan: Null<Span> = value?.span;
			final initSpan: Null<Span> = m.init.span;
			if (value == null || condSpan == null || valueSpan == null || initSpan == null) continue;
			if (BoolExprShape.refusesNullNarrowingBoolCollapse(value, m.init, cond, d.shape)) continue;
			final kept: Array<Span> = [new Span(m.declSpan.from, m.prefix.keptTo), condSpan, valueSpan, initSpan];
			if (IfExpressionChain.droppedComment(m.region, kept, comments)) continue;
			final head: String = '${m.prefix.text} = ';
			out.push({
				key: m.declSpan,
				edit: passThroughEdit(m.region, head, cond, value, m.init, source, d.shape) ?? ParenGuard.ternaryEdit(
					m.region, head, source.substring(condSpan.from, condSpan.to), source.substring(valueSpan.from, valueSpan.to),
					source.substring(initSpan.from, initSpan.to), ';'
				)
			});
		}
		return out;
	}

	/**
	 * Whether a comment sits inside the collapsed `if` region `[ifSpan.from, ifSpan.to)`
	 * but outside every verbatim-copied span (`kept`: the condition, the then-assignment,
	 * the else r-value). Such a comment would be dropped by the rebuild, so the finding is
	 * skipped rather than silently losing it.
	 */
	private static function droppedComment(ifNode: QueryNode, m: Match, comments: Array<{ from: Int, to: Int, isLine: Bool }>): Bool {
		final ifSpan: Null<Span> = ifNode.span;
		final condSpan: Null<Span> = m.condition.span;
		final thenSpan: Null<Span> = m.thenAssign.span;
		final elseRhsSpan: Null<Span> = m.elseRhs.span;
		if (ifSpan == null || condSpan == null || thenSpan == null || elseRhsSpan == null) return false;
		final kept: Array<Span> = [condSpan, thenSpan, elseRhsSpan];
		for (tok in comments) if (tok.from >= ifSpan.from && tok.to <= ifSpan.to) {
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
	 * Whether `node` is an `else if` link -- the else-branch (children[2]) of a
	 * parent `if`. Such a link belongs to a chain that is prefer-switch territory,
	 * so it is left unflagged (collapsing it would unravel the chain into nested
	 * ternaries rather than a switch).
	 */
	private static function isElseIfLink(node: QueryNode, parent: Null<QueryNode>, s: Seams): Bool {
		return parent != null && s.ifKinds.contains(parent.kind) && parent.children.length == IF_ELSE_CHILD_COUNT
			&& parent.children[2] == node;
	}

	/**
	 * The `<head><value>;` edit for a collapse whose ternary would only pass a nullable value through —
	 * `x != null ? x : null` and its three other spellings (`PreferNullCoalescing.nullPassThrough`) —
	 * or null for any other collapse. Writing the ternary there hands `prefer-null-coalescing` a
	 * `x ?? null` to make of it. The value takes the l-value's (or the declared) type exactly as the
	 * ternary's branch did, so dropping the guard cannot change what compiles.
	 */
	private static function passThroughEdit(
		span: Span, head: String, cond: QueryNode, thenValue: QueryNode, elseValue: QueryNode, source: String, shape: RefShape
	): Null<GuardedEdit> {
		final value: Null<QueryNode> = PreferNullCoalescing.nullPassThrough(cond, thenValue, elseValue, source, shape);
		final valueSpan: Null<Span> = value?.span;
		if (valueSpan == null) return null;
		final text: String = source.substring(valueSpan.from, valueSpan.to);
		return { span: span, text: '$head$text;', holes: [new Span(head.length, head.length + text.length)] };
	}

}

/** The `RefShape` kinds `PreferTernaryAssignment` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var ifKinds: Array<String>;
	var exprStmtKind: String;
	var blockStmtKind: String;
	var assignKind: String;
	var shape: RefShape;
}

/** A matched if/else: the condition, the then-branch assignment, and the two r-values. */
private typedef Match = {
	var condition: QueryNode;
	var thenAssign: QueryNode;
	var thenRhs: QueryNode;
	var elseRhs: QueryNode;
}
