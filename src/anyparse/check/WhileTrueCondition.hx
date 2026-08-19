package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.CheckScan.NegationSeams;
import anyparse.check.LoopScan.LoopJumpSeams;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a `while (true)` whose ONLY exit is a `break` that dominates the top of the body, and
 * lifts that exit condition into the loop header — the loop then says where it stops instead of
 * hiding it one level in. `Severity.Info` and `DefaultOff` (a readability rewrite, not a defect),
 * with a `--fix`. Grammar-agnostic over `RefShape`.
 *
 * ## Three forms of ONE rewrite
 *
 * The rewrite is always the same move — the guard `if`'s condition becomes the loop condition, the
 * non-exiting branch becomes the loop body, and whatever the exiting branch did BEFORE its `break`
 * moves after the loop. The three forms are just where the pieces sit:
 *
 *  - (a) `while (true) { if (C) break; A }` → `while (!C) { A }`. Generalised: the `if` may carry a
 *    braced then-branch `{ B; break; }`, and then `B` lands after the loop.
 *  - (b) `while (true) if (C) { A } else { B; break; }` → `while (C) { A }` plus `B` after the loop.
 *  - (c) the mirror, `while (true) if (C) { B; break; } else { A }` → `while (!C) { A }` plus `B`.
 *
 * ## Why it is equivalence-preserving — the gates, all syntactic
 *
 *  1. The loop condition is the literal `true`, and the guard `if` either IS the whole body or is
 *     its FIRST statement. That position is what makes the lift legal at all: the header evaluates
 *     `C` in the ENCLOSING scope, so nothing the body binds may be visible to it — and with the
 *     `if` first, the body has bound nothing yet. It is also the gate that refuses the
 *     LOOP-AND-A-HALF idiom, where the condition is COMPUTED in the body before the break
 *     (`while (true) { final x = next(); if (x == null) break; use(x); }`): there the `if` is not
 *     first, `C` reads a body-local, and no header could evaluate it.
 *  2. The exiting branch's LAST statement is a `break` bound to THIS loop, and the branch holds no
 *     OTHER `break` / `continue` of it — a second jump would reach a different place once the
 *     branch is outside the loop.
 *  3. The KEPT branch must hold no `break` of this loop. In the original such a `break` skips `B`;
 *     after the rewrite `B` runs. A `continue` is fine and is deliberately NOT refused: originally
 *     it goes to the top, re-evaluates `true`, then `C`; afterwards it goes straight to `C` — the
 *     same order. A `return` / `throw` is fine too: it leaves the function, and `B` runs on neither
 *     side.
 *  4. Side effects in `C` need no gate at all. It is evaluated once per iteration before the kept
 *     branch, both before and after — same count, same order.
 *  5. An `else if` chain in the exiting position FAILS CLOSED: its node is an `if`, not a block
 *     ending in `break`, so it is never accepted as the exiting branch.
 *
 * The one non-obvious language fact behind gates 2 and 3 lives in `LoopScan.escapesIteration`: a
 * `break` inside a `switch` inside a loop breaks the LOOP (measured on `--interp` — the C / JS
 * habit is wrong here), so the scan descends into switch bodies; a `break` inside a nested loop
 * binds to that loop, so it does not descend there.
 *
 * ## What the fix re-emits, and when it withholds
 *
 * Exactly three source slices are re-emitted: the condition (verbatim, or through
 * `NegationScan.negateConditionText` when the form negates), the kept branch VERBATIM including
 * its braces, and the exiting branch's first-to-last statement run. So the body's comments,
 * `#if` regions and nested loops ride along untouched — but a comment in a slot none of those
 * slices covers (the `if (` / `) {` glue, the `else` glue, an outer body block that held only the
 * `if`) would be DELETED, and the finding is then report-only with a note saying so.
 *
 * The ONE exception is a trailing comment on the dropped `break` itself (`break; // done`, which
 * is how both live sites in the measured corpus are written): it is hoisted onto the last lifted
 * statement. That needs a statement to land on and a clean rest-of-line after the loop, so a line
 * comment can never swallow following code; failing either, the site stays report-only.
 *
 * ## Grammar-agnostic
 *
 * `readSeams` names the required kinds — `whileStmtKind`, `ifStatementKinds`,
 * `breakStatementKind`, `boolLitKind` and `ControlFlowSupport.blockKinds()` — and returns null
 * when any is unset, making the check a no-op. `continueStatementKind`, `loopStatementKinds` /
 * `doWhileLoopKinds` (which loops shield an inner jump), `opaqueKinds` (skip macro reification)
 * and the negation seams shape the scans; the `while (…)` header itself is a literal, as in
 * `prefer-range-loop` and `prefer-for-in`.
 */
@:nullSafety(Strict)
final class WhileTrueCondition implements Check implements DefaultOff {

	/** A `while` node has exactly [condition, body] children. */
	private static inline final WHILE_CHILD_COUNT: Int = 2;

	/** A guard `if` with no `else` has exactly [condition, then-branch] children. */
	private static inline final IF_NO_ELSE_CHILD_COUNT: Int = 2;

	/** An `if` with an `else` has exactly [condition, then-branch, else-branch] children. */
	private static inline final IF_WITH_ELSE_CHILD_COUNT: Int = 3;

	/** The only boolean literal an always-true loop header can be written as. */
	private static inline final TRUE_LITERAL: String = 'true';

	private static inline final MESSAGE: String = 'this while (true) can lift its break condition into the loop header';

	/** ASCII-only note appended when a comment the rewrite would delete keeps the finding report-only. */
	private static inline final COMMENT_NOTE: String = ' (comment in the dropped glue - lift by hand)';

	public function new() {}

	public function id(): String {
		return 'while-true-condition';
	}

	public function description(): String {
		return 'a while (true) whose only exit is a break at the top of the body, liftable into the header';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (m in collectMatches(tree, entry.source, seams, plugin, entry.file, null)) violations.push({
				file: entry.file,
				span: m.span,
				rule: 'while-true-condition',
				severity: Severity.Info,
				message: m.text == null ? MESSAGE + COMMENT_NOTE : MESSAGE
			});
		}
		return violations;
	}

	/** Replace each flagged loop with the header-condition form plus, where the exiting branch had one, its lifted run. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		final file: String = violations.length == 0 ? '' : violations[0].file;
		return CheckScan.applyTextMatches(
			plugin, source, violations,
			(tree, src) -> [
				for (m in collectMatches(tree, src, s, plugin, file, index)) {
					final text: Null<String> = m.text;
					if (text != null) ({ span: m.span, text: text });
				}
			]
		);
	}

	/** Bundle the `RefShape` kinds this check reads, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final whileKind: Null<String> = shape.whileStmtKind;
		if (whileKind == null) return null;
		final breakKind: Null<String> = shape.breakStatementKind;
		if (breakKind == null) return null;
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (boolLitKind == null) return null;
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final base: LoopJumpSeams = {
			loopKinds: shape.loopStatementKinds ?? [],
			doWhileKinds: shape.doWhileLoopKinds ?? [],
			opaqueKinds: shape.opaqueKinds ?? [],
			nestedScopeKinds: LoopScan.nestedScopeKinds(shape),
			// A `return` / `throw` leaves the function on BOTH sides of the rewrite, so it is never
			// an escape this rule cares about: the only question is which loop a jump binds to.
			hardExitKinds: [],
			loopJumpKinds: [breakKind]
		};
		final continueKind: Null<String> = shape.continueStatementKind;
		return {
			whileKind: whileKind,
			breakKind: breakKind,
			boolLitKind: boolLitKind,
			ifKinds: ifKinds,
			blockKinds: support.blockKinds(),
			opaqueKinds: shape.opaqueKinds ?? [],
			breaks: base,
			// The exiting branch is held to the STRICTER question — a `continue` there would jump
			// somewhere else once the branch sits outside the loop — so it asks about both jumps.
			jumps: continueKind == null ? base : {
				loopKinds: base.loopKinds,
				doWhileKinds: base.doWhileKinds,
				opaqueKinds: base.opaqueKinds,
				nestedScopeKinds: base.nestedScopeKinds,
				hardExitKinds: base.hardExitKinds,
				loopJumpKinds: [breakKind, continueKind]
			},
			negation: NegationScan.negationSeams(shape),
			support: plugin.booleanLogicSupport()
		};
	}

	/** Walk `tree` and return every qualifying loop, each with its replacement span and text (null text = report-only). */
	private static function collectMatches(
		tree: QueryNode, source: String, s: Seams, plugin: GrammarPlugin, file: String, index: Null<SymbolIndex>
	): Array<Match> {
		final ctx: Ctx = {
			source: source,
			seams: s,
			comments: RefactorSupport.collectCommentTokens(source),
			types: CheckScan.typeNominalResolver(source, plugin, tree, file, index)
		};
		final out: Array<Match> = [];
		walk(tree, ctx, out);
		return out;
	}

	/** Descend `node`, testing every loop; a reification subtree (`opaqueKinds`) is skipped wholesale. */
	private static function walk(node: QueryNode, ctx: Ctx, out: Array<Match>): Void {
		if (ctx.seams.opaqueKinds.contains(node.kind)) return;
		final m: Null<Match> = tryMatch(node, ctx);
		if (m != null) out.push(m);
		for (c in node.children) walk(c, ctx, out);
	}

	/**
	 * Whether `loop` is a `while (true)` whose only exit is a dominating `break`; returns the
	 * whole-loop span and its replacement text when so (null text when a comment the rewrite
	 * cannot carry keeps the finding report-only), else null.
	 */
	private static function tryMatch(loop: QueryNode, ctx: Ctx): Null<Match> {
		final s: Seams = ctx.seams;
		if (loop.kind != s.whileKind || loop.children.length != WHILE_CHILD_COUNT) return null;
		final loopSpan: Null<Span> = loop.span;
		if (loopSpan == null || !isTrueLiteral(loop.children[0], ctx.source, s)) return null;
		final body: QueryNode = loop.children[1];
		final bodyBlock: Null<QueryNode> = s.blockKinds.contains(body.kind) ? body : null;
		final ifNode: QueryNode = bodyBlock == null || bodyBlock.children.length == 0 ? body : bodyBlock.children[0];
		if (!s.ifKinds.contains(ifNode.kind) || ifNode.children.length < IF_NO_ELSE_CHILD_COUNT) return null;
		final rest: Array<QueryNode> = bodyBlock == null ? [] : bodyBlock.children.slice(1);
		final arms: Null<Arms> = classify(ifNode, rest, s);
		if (arms == null) return null;
		final keep: Null<QueryNode> = arms.keep;
		final kepts: Array<QueryNode> = keep == null ? rest : [keep];
		for (n in kepts) if (LoopScan.escapesIteration(n, s.breaks, false)) return null;
		final kept: Null<Kept> = keptText(keep, ifNode, bodyBlock, ctx);
		final cond: QueryNode = ifNode.children[0];
		final condSpan: Null<Span> = cond.span;
		if (kept == null || condSpan == null) return null;
		final condText: String = arms.negate
			? NegationScan.negateConditionText(cond, ctx.source, s.negation, s.support, ctx.types)
			: spanText(ctx.source, condSpan);
		final lift: Null<String> = liftedText(arms, [condSpan, kept.region], loopSpan, ctx);
		final head: String = 'while ($condText) ${kept.text}';
		return {
			span: loopSpan,
			text: lift == null ? null : lift == '' ? head : '$head\n$lift'
		};
	}

	/**
	 * Which branch stays in the loop, which statements lift out after it, and whether the header
	 * condition is the guard's own or its negation — or null when the shape is not one of the
	 * three forms. Exactly ONE branch may be the exiting one: with none the loop has no lift-able
	 * exit, with both it never iterates at all.
	 */
	private static function classify(ifNode: QueryNode, rest: Array<QueryNode>, s: Seams): Null<Arms> {
		if (ifNode.children.length == IF_NO_ELSE_CHILD_COUNT) {
			final term: Null<Terminator> = exitBranch(ifNode.children[1], s);
			return term == null ? null : {
				keep: null,
				lift: term.head,
				breakNode: term.breakNode,
				negate: true
			};
		}
		// Forms (b) and (c) consume the WHOLE body: a statement after the `if` would have to join
		// the kept branch, and the two runs are not contiguous in the source.
		if (ifNode.children.length != IF_WITH_ELSE_CHILD_COUNT || rest.length != 0) return null;
		final thenTerm: Null<Terminator> = exitBranch(ifNode.children[1], s);
		final elseTerm: Null<Terminator> = exitBranch(ifNode.children[2], s);
		return if (elseTerm != null && thenTerm == null)
			{
				keep: ifNode.children[1],
				lift: elseTerm.head,
				breakNode: elseTerm.breakNode,
				negate: false
			};
		else if (thenTerm != null && elseTerm == null)
			{
				keep: ifNode.children[2],
				lift: thenTerm.head,
				breakNode: thenTerm.breakNode,
				negate: true
			};
		else
			null;
	}

	/**
	 * `branch` read as the EXITING branch: a bare `break`, or a block whose LAST statement is a
	 * `break` and whose preceding statements hold no other jump of this loop. Null when it is
	 * neither — which is also what fails an `else if` chain closed, its node being an `if`.
	 */
	private static function exitBranch(branch: QueryNode, s: Seams): Null<Terminator> {
		if (branch.kind == s.breakKind) return { head: [], breakNode: branch };
		final kids: Array<QueryNode> = branch.children;
		if (!s.blockKinds.contains(branch.kind) || kids.length == 0) return null;
		final breakNode: QueryNode = kids[kids.length - 1];
		if (breakNode.kind != s.breakKind) return null;
		final head: Array<QueryNode> = kids.slice(0, kids.length - 1);
		for (h in head) if (LoopScan.escapesIteration(h, s.jumps, false)) return null;
		return { head: head, breakNode: breakNode };
	}

	/**
	 * The loop's new body text: the kept branch VERBATIM (braces and all) for forms (b) and (c),
	 * and for form (a) the original body block with its leading guard `if` cut away. A form (a)
	 * whose body was the bare `if` keeps nothing, and becomes an empty body.
	 */
	private static function keptText(keep: Null<QueryNode>, ifNode: QueryNode, bodyBlock: Null<QueryNode>, ctx: Ctx): Null<Kept> {
		if (keep != null) {
			final span: Null<Span> = keep.span;
			return span == null ? null : { text: spanText(ctx.source, span), region: span };
		}
		if (bodyBlock == null) return { text: '{}', region: null };
		final ifSpan: Null<Span> = ifNode.span;
		final bodySpan: Null<Span> = bodyBlock.span;
		if (ifSpan == null || bodySpan == null) return null;
		final region: Span = new Span(ifSpan.to, bodySpan.to);
		return { text: '{${spanText(ctx.source, region)}', region: region };
	}

	/**
	 * The text that lands after the loop — the exiting branch's first-to-last statement run,
	 * verbatim, plus a hoisted trailing comment from the dropped `break` — or '' when the branch
	 * was a bare `break`. Null when a comment the rewrite cannot carry would be deleted, which
	 * leaves the finding report-only.
	 */
	private static function liftedText(arms: Arms, emitted: Array<Null<Span>>, loopSpan: Span, ctx: Ctx): Null<String> {
		final breakSpan: Null<Span> = arms.breakNode.span;
		if (breakSpan == null) return null;
		final runFrom: Null<Span> = arms.lift.length == 0 ? null : arms.lift[0].span;
		final kept: Array<Span> = [for (span in emitted) if (span != null) span];
		if (runFrom != null) kept.push(new Span(runFrom.from, breakSpan.from));
		final hoisted: Null<Span> = runFrom == null ? null : hoistableComment(breakSpan, loopSpan, ctx);
		if (hoisted != null) kept.push(hoisted);
		for (c in ctx.comments) if (c.from >= loopSpan.from && c.to <= loopSpan.to && !containedIn(c.from, c.to, kept)) return null;
		// No run to emit: an exiting branch that was a bare `break` lifts nothing (''), while a
		// non-empty one whose first statement has no span cannot be transcribed at all (null).
		if (runFrom == null) return arms.lift.length == 0 ? '' : null;
		final run: String = ctx.source.substring(runFrom.from, breakSpan.from).rtrim();
		return hoisted == null ? run : '$run ${spanText(ctx.source, hoisted)}';
	}

	/**
	 * The span of a comment written on the dropped `break`'s own line (`break; // done`), which the
	 * lift carries onto its last statement instead of deleting. Null when there is none, when
	 * anything but the `;` and whitespace separates them, or — for a LINE comment — when the loop's
	 * own line does not end after it, where re-emitting the comment would swallow following code.
	 */
	private static function hoistableComment(breakSpan: Span, loopSpan: Span, ctx: Ctx): Null<Span> {
		for (c in ctx.comments) {
			if (c.from < breakSpan.to) continue;
			final gap: String = ctx.source.substring(breakSpan.to, c.from);
			final sameLine: Bool = gap.indexOf('\n') == -1 && gap.ltrim().replace(';', '') == '';
			final tailIsClear: Bool = !c.isLine || tailOfLineIsBlank(ctx.source, loopSpan.to);
			return sameLine && tailIsClear ? new Span(c.from, c.to) : null;
		}
		return null;
	}

	/** Whether nothing but whitespace follows `at` on its physical line — the end of file counts as blank. */
	private static function tailOfLineIsBlank(source: String, at: Int): Bool {
		final nl: Int = source.indexOf('\n', at);
		return source.substring(at, nl == -1 ? source.length : nl).trim() == '';
	}

	/** Whether `[from, to)` sits inside one of `spans`. */
	private static function containedIn(from: Int, to: Int, spans: Array<Span>): Bool {
		return spans.exists(span -> from >= span.from && to <= span.to);
	}

	/** Whether `node` is the boolean literal `true` — the only header an always-true loop can be written with. */
	private static function isTrueLiteral(node: QueryNode, source: String, s: Seams): Bool {
		return node.kind == s.boolLitKind && spanText(source, node.span) == TRUE_LITERAL;
	}

	/** `span`'s verbatim source, or '' when the grammar left it unset. */
	private static function spanText(source: String, span: Null<Span>): String {
		return span == null ? '' : source.substring(span.from, span.to);
	}

}

/** The `RefShape` kinds `WhileTrueCondition` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var whileKind: String;
	var breakKind: String;
	var boolLitKind: String;
	var ifKinds: Array<String>;
	var blockKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var breaks: LoopJumpSeams;
	var jumps: LoopJumpSeams;
	var negation: NegationSeams;
	var support: Null<BooleanLogicSupport>;
}

/** Per-file inputs the walkers share: the source, the resolved seams, the comment tokens and the type resolver. */
private typedef Ctx = {
	var source: String;
	var seams: Seams;
	var comments: Array<{ from: Int, to: Int, isLine: Bool }>;
	var types: Null<(QueryNode) -> Null<String>>;
}

/**
 * A matched loop's parts: the branch that stays inside (null for form (a), whose kept run is the
 * body block after the guard), the exiting branch's statements before its `break`, that `break`
 * node, and whether the header condition is the guard's own or its negation.
 */
private typedef Arms = {
	var keep: Null<QueryNode>;
	var lift: Array<QueryNode>;
	var breakNode: QueryNode;
	var negate: Bool;
}

/** An exiting branch read apart: the statements before its `break`, and the `break` itself. */
private typedef Terminator = {
	var head: Array<QueryNode>;
	var breakNode: QueryNode;
}

/** The loop's new body: its text, and the source region that text was taken from (null when it is synthesised). */
private typedef Kept = {
	var text: String;
	var region: Null<Span>;
}

/** A flagged loop: the whole-loop span, and its replacement text (null when a dropped comment withholds the fix). */
private typedef Match = {
	var span: Span;
	var text: Null<String>;
}
