package anyparse.check;

import anyparse.check.Check.CarryingEdit;
import anyparse.check.Check.CarryingFix;
import anyparse.check.Check.Violation;
import anyparse.query.BoolExprShape;
import anyparse.query.CanonicalEdit;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

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
 * A pair that CLOSES a cascade `prefer-if-expression-return` claims is DEFERRED to that rule, which
 * rewrites the whole run in one edit; collapsing that pair alone writes the three-rung ternary
 * `prefer-if-expression-chain` then condemns. The question is put to that rule directly, not
 * mirrored here.
 *
 * Only an `if` STATEMENT that is a DIRECT child of a block, has NO `else`, whose then-branch is a
 * value-returning `return` (or a `{ … }` wrapping exactly one),
 * and whose immediately-following block sibling is also a value-returning
 * `return`. A value-less `return;` is a distinct kind and never matches (a
 * ternary needs two values). The direct-block-child restriction is the
 * correctness gate: the two statements must be real siblings in one statement
 * list — an inline `if (outer) if (a) return 1;` (the inner `if` being the
 * un-braced body of another statement) is not flagged, since the trailing
 * `return` is then a sibling of the OUTER statement, not the inner `if`. A
 * statement between the `if` and the `return` also blocks the match (the
 * collapse would reorder it). A null-narrowing guard condition refuses ONLY a
 * bool-literal collapse (see `RefactorSupport.refusesNullNarrowingBoolCollapse`)
 * — a value ternary keeps the in-condition narrowing and is allowed. The
 * reported span is the `if` statement.
 *
 * ## Autofix
 *
 * `fix` replaces the `if`-statement-through-trailing-`return` span with
 * `return cond ? a : b;`. The condition is wrapped in parentheses only when it
 * binds no tighter than `?:` (a ternary, or an assignment) so precedence is
 * preserved; every tighter-binding condition (comparison, `&&` / `||`, `??`,
 * call, identifier) is emitted bare, per the user's no-redundant-parens
 * preference. The return values are copied verbatim.
 * `RefactorSupport.dropContainedEdits` keeps edits non-overlapping. Needs
 * `ControlFlowSupport` and `RefShape.returnStatementKind`; either unset makes
 * the check report-only / a no-op.
 *
 * ## Comments
 *
 * The replacement is rebuilt from expression spans, so every comment in the
 * folded region has to be re-placed explicitly — and WHERE decides what it now
 * says. `preservedComments` splits them by position: a comment still on the
 * guard's own line rides that guard's value into the rebuilt ternary's
 * then-branch (`? a // still about a`), everything else is hoisted as a leading
 * block above the merged `return`. Nothing is dropped. This differs from the
 * fail-closed siblings (`redundant-else`, `prefer-ternary-assignment`,
 * `prefer-if-expression-return`, `join-return`) which REFUSE to fire rather than
 * re-place a comment; this rule folds a fixed two-statement shape whose comment
 * positions are enumerable, so it can carry them instead of bailing.
 */
@:nullSafety(Strict)
final class PreferTernaryReturn implements Check implements CarryingFix {

	public function new() {}

	public function id(): String {
		return 'prefer-ternary-return';
	}

	public function description(): String {
		return 'an if/return followed by a return that collapses to a single ternary return';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, entry.source);
			if (tree != null)
				walk(
					violations, entry.file, entry.source, tree, seams, null,
					SourceComments.collectCommentTokens(plugin.lexicalRegions(entry.source))
				);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [
			for (edit in fixCarrying(source, violations, plugin, index)) { span: edit.span, text: edit.text }
		];
	}

	/**
	 * The `CarryingFix` half, and the one that does the work — `fix` is its pure projection, per
	 * that interface's contract.
	 *
	 * What this rule carries is the whole reason the declaration exists. Every replacement it
	 * emits is `return <condition> ? <then> : <else>;` built out of three ranges copied byte for
	 * byte, with everything else that stood in the region — the comments — stacked in front. That
	 * stacking is invisible to a gate reading the two texts, because the bytes it changes are the
	 * bytes any in-place rewrite changes; declaring the three ranges is what lets
	 * `CommentOwnerGuard.hoistedComment` see that a comment which stood BETWEEN two of them now
	 * stands above both.
	 */
	public function fixCarrying(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<CarryingEdit> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) return [];

		final flagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		final edits: Array<CarryingEdit> = [];
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		collectFixes(tree, source, seams, null, flagged, edits, SourceComments.collectCommentTokens(regions), regions);
		final kept: Array<{ span: Span, text: String }> = CanonicalEdit.dropContainedEdits([
			for (edit in edits)
				{
					span: edit.span,
					text: edit.text
				}
		]);
		return edits.filter(edit -> kept.exists(alive -> alive.span.from == edit.span.from && alive.span.to == edit.span.to));
	}

	/** `TypeResolver.childReturnTypeSource` with this check's seams unpacked from `Seams`. */
	private static inline function childReturnType(node: QueryNode, source: String, s: Seams, retType: Null<String>): Null<String> {
		return TypeResolver.childReturnTypeSource(node, source, retType, s.functionKinds, s.lambdaKinds, s.bodyKinds, s.paramKinds);
	}

	/**
	 * Walk `node`; at each block flag the direct-child `if`/`return` pairs. `retType` is the
	 * source of the nearest enclosing function's explicit return type (null when it declares
	 * none), rebound on entry to every function so a pair is judged against ITS OWN function —
	 * an inner lambda never inherits the outer method's declared `Bool`.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, s: Seams, retType: Null<String>,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Void {
		final childRetType: Null<String> = childReturnType(node, source, s, retType);
		if (s.support.blockKinds().contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final match: Null<TernaryMatch> = pairAt(kids, i, s, retType, source, comments);
				if (match == null) continue;
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
		for (c in node.children) walk(out, file, source, c, s, childRetType, comments);
	}

	/** Mirror `walk` — including its `retType` rebinding: collect one replacement edit per flagged `if`/`return` pair. */
	private static function collectFixes(
		node: QueryNode, source: String, s: Seams, retType: Null<String>, flagged: Array<String>, edits: Array<CarryingEdit>,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, regions: Array<LexRegion>
	): Void {
		final childRetType: Null<String> = childReturnType(node, source, s, retType);
		if (s.support.blockKinds().contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length) {
				final match: Null<TernaryMatch> = pairAt(kids, i, s, retType, source, comments);
				if (match == null) continue;
				final ifSpan: Null<Span> = match.ifNode.span;
				if (!(ifSpan != null && flagged.contains('${ifSpan.from}:${ifSpan.to}'))) continue;
				final edit: Null<CarryingEdit> = buildEdit(match, source, s.shape, regions);
				if (edit != null) edits.push(edit);
			}
		}
		for (c in node.children) collectFixes(c, source, s, childRetType, flagged, edits, comments, regions);
	}

	/**
	 * If `kids[i]` is a no-else `if` whose then-branch value-returns and `kids[i+1]`
	 * is a value-returning `return`, return the match parts; otherwise null.
	 */
	private static function pairAt(
		kids: Array<QueryNode>, i: Int, s: Seams, retType: Null<String>, source: String,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Null<TernaryMatch> {
		final shape: RefShape = s.shape;
		final returnKind: String = s.returnKind;
		final ifNode: QueryNode = kids[i];
		if (!s.ifKinds.contains(ifNode.kind) || ifNode.children.length != 2) return null;
		final thenValue: Null<QueryNode> = thenReturnValue(ifNode.children[1], shape, returnKind);
		if (thenValue == null) return null;
		if (i + 1 >= kids.length) return null;
		final next: QueryNode = kids[i + 1];
		if (next.kind != returnKind || next.children.length < 1) return null;
		final elseValue: QueryNode = next.children[0];
		// A pair that is the TAIL of a cascade `prefer-if-expression-return` claims belongs to that
		// rewrite whole. Collapsing it alone writes the three-rung ternary chain
		// `prefer-if-expression-chain` then condemns — the reader is shown one finding, applies it, and
		// the next run reports something the first run never mentioned.
		//
		// The head is walked back to, because the claim covers the WHOLE run and the pair sits at its
		// end. The question is put to that rule rather than mirrored here: gating on the SHAPE would
		// silence this rule wherever that one refuses on a comment, and S45 measured what that costs —
		// 14 findings of 69 with no replacement anywhere.
		// The head comes FROM that rule, not from a walk-back mirrored here: a no-`else` `if` that does
		// not return is a rung by shape and not one it collects, so a local walk-back runs past it and
		// asks about an index the claiming rule never uses — answering `false` on a cascade it claims
		// one index later, and both rules then report the same control flow.
		final head: Int = PreferIfExpressionReturn.returnRunHead(kids, i, shape);
		// EITHER value being a ternary MID-REDUCTION blocks the pair, whatever the collapse would
		// be. `simplify-boolean-ternary` is about to flatten such a ternary into `&&` / `||`, and
		// this collapse would bury it one level deeper, where it stops being the function's direct
		// returned value and loses its licence for good — `dropContainedEdits` keeps the OUTER edit
		// of two that overlap, so the inner reduction is dropped, not deferred. The gate is
		// deliberately OUTSIDE isStuckBooleanCollapse: a VALUE ternary collapse (neither value a
		// bool literal) buries the tail just as thoroughly, and that arm never consults the stuck
		// check at all. Measured on anyparse's own `MagicNumber.childPositionCtx` and
		// `PurityScan.isPure`, which came out as nested ternary chains until this moved out.
		// A STATEMENT-LIKE value (an `if` used as a value, a `switch`, a `try`, a `throw`, a block)
		// blocks the pair for the same reason the boolean arm already refuses one: a ternary whose
		// branch is a four-line `if` / `else if` / `else` chain is not more readable than the two
		// statements it replaced. Measured on anyparse's own `PurityScan.isPure`.
		// A bool-literal-vs-non-provably-Bool pair collapses to a "stuck" boolean ternary
		// (`cond ? true : g()`) that simplify-boolean-ternary cannot reduce without a typer
		// — uglier than the guard. Leave it: a fully-reducible boolean guard chain is
		// `simplify-boolean-return-chain`'s job; a value ternary still collapses here.
		// The narrowing-guard refusal fires only for a bool-literal collapse (see
		// RefactorSupport.refusesNullNarrowingBoolCollapse).
		return BoolExprShape.refusesNullNarrowingBoolCollapse(thenValue, elseValue, ifNode.children[0], shape)
			|| BoolExprShape.pendingBooleanTernaryTail(thenValue, shape) || BoolExprShape.pendingBooleanTernaryTail(elseValue, shape)
			|| BoolExprShape.statementLikeValue(thenValue, shape) || BoolExprShape.statementLikeValue(elseValue, shape)
			|| isStuckBooleanCollapse(thenValue, elseValue, shape, retType)
			|| strandsCascadeComment(
				// BEFORE the cascade claim, because it answers from spans this frame already has while
				// that one walks a whole cascade and re-runs another rule's gates. It is also the arm that
				// makes the claim's own refusal safe: `claimsCascade` declines a cascade whose comments it
				// cannot carry, and until this gate existed that decline handed the very same cascade to
				// this rule, which folded it and hoisted those comments.
				kids,
				i,
				next,
				s,
				source,
				comments
			)
			|| PreferIfExpressionReturn.claimsCascade(
				// LAST, because it is the only disjunct that walks a whole cascade and re-runs another
				// rule's gates: every cheap shape refusal above short-circuits it away.
				kids,
				head,
				source,
				comments,
				shape
			)
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
	private static function buildEdit(match: TernaryMatch, source: String, shape: RefShape, regions: Array<LexRegion>): Null<CarryingEdit> {
		final ifSpan: Null<Span> = match.ifNode.span;
		final condSpan: Null<Span> = match.condition.span;
		final thenSpan: Null<Span> = match.thenValue.span;
		final elseSpan: Null<Span> = match.elseValue.span;
		final nextSpan: Null<Span> = match.nextReturn.span;
		if (ifSpan == null || condSpan == null || thenSpan == null || elseSpan == null || nextSpan == null) return null;
		final condition: String = wrapCondition(source.substring(condSpan.from, condSpan.to), match.condition.kind, shape);
		final thenSource: String = source.substring(thenSpan.from, thenSpan.to);
		final elseSource: String = source.substring(elseSpan.from, elseSpan.to);
		final split: PreservedComments = preservedComments(source, ifSpan, thenSpan, nextSpan, [condSpan, thenSpan, elseSpan], regions);
		// The guard's own trailing comment rides its branch; every other comment
		// keeps the leading-block hoist. The broken layout is what makes the
		// line-style case legal (a `//` glued before the `:` would comment the
		// rest of the ternary out) — actual indentation and re-flow are the
		// writer's job, since `RefactorSupport.canonicalize` re-emits the whole
		// spliced file.
		final text: String = split.branchTrailing == null
			? '${split.hoisted}return $condition ? $thenSource : $elseSource;'
			: '${split.hoisted}return $condition\n? $thenSource ${split.branchTrailing}\n: $elseSource;';
		// The three ranges the replacement quotes byte for byte, in the order it puts them in —
		// the same three `preservedComments` is handed to decide which comments it may leave
		// alone, so the declaration is a list this function had already built. `wrapCondition` can
		// put parentheses AROUND the condition; the source text is still inside the result, which
		// is the whole of what a verbatim carry claims.
		return { span: new Span(ifSpan.from, nextSpan.to), text: text, carried: [condSpan, thenSpan, elseSpan] };
	}

	/**
	 * Parenthesise the condition iff it binds no tighter than `?:` — a ternary or
	 * an assignment — so `cond ? a : b` keeps the original meaning. Every other
	 * condition binds tighter and is emitted bare.
	 */
	private static function wrapCondition(source: String, kind: String, shape: RefShape): String {
		final ternaryKind: Null<String> = shape.ternaryKind;
		final needsParens: Bool = (ternaryKind != null && kind == ternaryKind) || shape.writeParentKinds.contains(kind);
		return needsParens ? '($source)' : source;
	}

	/**
	 * Whether collapsing `if (c) return a; return b;` would produce a "stuck" boolean
	 * ternary — exactly one of `a` / `b` is a boolean literal and the other is not a
	 * provably non-null `Bool`. `cond ? true : <Call>` then cannot be reduced to
	 * `cond || …` without a typer, so the ternary is uglier than the guard and is left
	 * alone. Both-literal (`? true : false` -> `cond`) and provably-Bool other side
	 * (reduces cleanly) and neither-literal (a value ternary) all collapse as before.
	 *
	 * `retType` is the SECOND proof: the source of the enclosing function's explicit
	 * return type. `a` and `b` are BOTH returned values of that one function, so a
	 * declared non-null boolean nominal (`RefactorSupport.declaresNonNullBool`) types
	 * either side symmetrically and there is no stuck ternary to fear — `simplify-boolean-
	 * ternary` reduces the pair on the next `--fix` pass, using the same proof. A missing
	 * annotation infers nothing and refuses; `Null<Bool>` refuses; a `null`-literal or
	 * statement-like tail refuses on its own merits (`statementLikeOrNullTail`).
	 */
	private static function isStuckBooleanCollapse(a: QueryNode, b: QueryNode, shape: RefShape, retType: Null<String>): Bool {
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (boolLitKind == null) return false;
		final aBool: Bool = a.kind == boolLitKind;
		final bBool: Bool = b.kind == boolLitKind;
		if (aBool == bBool) return false;
		final other: QueryNode = aBool ? b : a;
		final notKind: Null<String> = shape.notKind;
		final boolOpKinds: Array<String> = (shape.comparisonKinds ?? []).concat(notKind != null ? [notKind] : []);
		return !BoolExprShape.provablyBoolOperand(other, boolOpKinds, shape.parenKind)
			&& (!BoolExprShape.declaresNonNullBool(retType, shape) || BoolExprShape.statementLikeOrNullTail(other, shape));
	}

	/**
	 * Split every comment inside the replaced `[ifSpan.from, nextSpan.to)` region
	 * that is NOT already carried inside a copied expression span (`condSpan` /
	 * `thenSpan` / `elseSpan`) by its POSITION, because position is what the
	 * author's comment is about:
	 *
	 *  - a comment still on the guard's own line — it starts after the then-value
	 *    and no newline separates the two — describes THAT branch
	 *    (`if (a == b) return NoChange; // already correctly linked`). It becomes
	 *    `branchTrailing` and the caller re-attaches it to the rebuilt ternary's
	 *    then-branch. Hoisting it above the merged `return` (the pre-slice
	 *    behaviour) re-reads it as a description of the WHOLE collapsed chain,
	 *    which is a different — and wrong — statement.
	 *  - everything else (own-line comments between the two statements, a comment
	 *    inside the then-block before its `return`) keeps the leading-block hoist.
	 *
	 * Only the FIRST same-line comment is re-attached, and only when it has no
	 * internal newline: the writer's ternary operand slot holds one comment
	 * captured by a same-line scan, so a second one — or a newline-bearing block —
	 * has nowhere to land and is hoisted with the rest.
	 *
	 * `hoisted` is a newline-terminated block, empty when nothing hoists.
	 */
	private static function preservedComments(
		source: String, ifSpan: Span, thenSpan: Span, nextSpan: Span, kept: Array<Span>, regions: Array<LexRegion>
	): PreservedComments {
		final out: StringBuf = new StringBuf();
		var branchTrailing: Null<String> = null;
		for (tok in SourceComments.collectCommentTokens(regions)) if (!(tok.from < ifSpan.from || tok.to > nextSpan.to)) {
			var insideKept: Bool = false;
			for (k in kept) if (tok.from >= k.from && tok.to <= k.to) {
				insideKept = true;
				break;
			}
			if (insideKept) continue;
			final text: String = source.substring(tok.from, tok.to).trim();
			final onGuardLine: Bool = tok.from >= thenSpan.to && source.substring(thenSpan.to, tok.from).indexOf('\n') < 0;
			if (branchTrailing == null && onGuardLine && text.indexOf('\n') < 0) {
				branchTrailing = text;
				continue;
			}
			out.add(text);
			out.add('\n');
		}
		return { hoisted: out.toString(), branchTrailing: branchTrailing };
	}

	/** Resolve the if / return seam kinds plus control-flow support, or null when any required piece is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		if (ifKinds.length == 0) return null;
		final returnKind: Null<String> = shape.returnStatementKind;
		if (returnKind == null) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		return support == null ? null : {
			ifKinds: ifKinds,
			returnKind: returnKind,
			support: support,
			shape: shape,
			functionKinds: shape.functionKinds ?? [],
			lambdaKinds: shape.lambdaKinds ?? [],
			bodyKinds: shape.functionBodyKinds ?? [],
			paramKinds: shape.paramKinds ?? []
		};
	}

	/**
	 * Whether folding this pair would eventually strand a comment — the CASCADE question, which
	 * a per-pair look cannot answer.
	 *
	 * A fold is not a local edit when the pair is the tail of a run of `if (c) return v;` rungs:
	 * the fixed-point loop re-reports the rung above on the next pass, because its follower is now
	 * a plain `return`, and marches all the way up. Each step quotes that rung's condition and
	 * value verbatim and HOISTS everything else in the region to the front of the replacement
	 * (`preservedComments`), so a per-gate explanation standing between two rungs ends up stacked
	 * above the pyramid, detached from the gate it explains. Measured on this repo's own
	 * `MemberOrder.reorderRefusal`: one reported finding on the last of six gates, `--fix` then
	 * wrote 10 edits over 7 passes and welded both comment blocks to the top.
	 *
	 * The narrowing is deliberately the CONJUNCTION of the two candidate rules rather than either
	 * one. Refusing every cascade tail on SHAPE alone is what `pairAt` already declines to do, and
	 * S45 measured the price — 14 findings of 69 with no replacement anywhere. Refusing on a
	 * comment alone would fire on the single pair whose own leading comment stays exactly where it
	 * is. Both together name the one shape where a comment provably loses its subject: a march
	 * long enough to cross a comment that no step of it copies.
	 *
	 * `head == i` — a run of ONE — returns before any of that, and what it protects is a comment
	 * INSIDE the pair's own region, which the fold DOES hoist and which this project has decided to
	 * accept (`testOwnLineCommentBetweenStatementsStillHoists`, `testBothPositionsSplitCorrectly`,
	 * both of which drop to 0 edits without it). A comment LEADING the `if` needs no exception at
	 * all: a statement span starts at the `if` keyword, so it is outside the region either way.
	 *
	 * Fail-CLOSED on a span it cannot read, and only then: with no comment in the file at all the
	 * question is moot and the first line answers it without touching a span.
	 */
	private static function strandsCascadeComment(
		kids: Array<QueryNode>, i: Int, next: QueryNode, s: Seams, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>
	): Bool {
		if (comments.length == 0) return false;
		// The run THIS rule can march up, by its own foldability predicate rather than the sibling
		// rule's: `returnRunHead` answers for the cascade `prefer-if-expression-return` collects,
		// and a rung it counts but `thenReturnValue` refuses would extend the region past the point
		// where the march actually stops.
		var head: Int = i;
		while (head > 0) {
			final rung: QueryNode = kids[head - 1];
			if (!s.ifKinds.contains(rung.kind) || rung.children.length != 2) break;
			if (thenReturnValue(rung.children[1], s.shape, s.returnKind) == null) break;
			head--;
		}
		if (head == i) return false;
		final from: Null<Span> = kids[head].span;
		final to: Null<Span> = next.span;
		final elseValue: Null<Span> = next.children.length < 1 ? null : next.children[0].span;
		if (from == null || to == null || elseValue == null) return true;
		// The spans the march copies VERBATIM: every rung's condition and returned value, plus the
		// terminal return's value, which each later step re-copies as the accumulating else branch.
		final kept: Array<Span> = [elseValue];
		final values: Array<Span> = [];
		for (j in head ... i + 1) {
			final rung: QueryNode = kids[j];
			final cond: Null<Span> = rung.children[0].span;
			final value: Null<QueryNode> = thenReturnValue(rung.children[1], s.shape, s.returnKind);
			final valueSpan: Null<Span> = value?.span;
			if (cond == null || valueSpan == null) return true;
			kept.push(cond);
			kept.push(valueSpan);
			values.push(valueSpan);
		}
		for (token in comments) {
			if (token.from < from.from || token.to > to.to || spanCovers(kept, token)) continue;
			if (!ridesItsBranch(source, values, token)) return true;
		}
		return false;
	}

	/** Whether one of `spans` contains `token` whole. */
	private static function spanCovers(spans: Array<Span>, token: { from: Int, to: Int, isLine: Bool }): Bool {
		return spans.exists(span -> token.from >= span.from && token.to <= span.to);
	}

	/**
	 * Whether `token` is the guard's own TRAILING comment — one line, sitting after a rung's
	 * returned value with no line break in between. `buildEdit` splices such a comment after the
	 * `?` value instead of hoisting it, and the next step up finds it inside the else value it
	 * copies whole, so it rides the march to the end still attached to its branch.
	 */
	private static function ridesItsBranch(source: String, values: Array<Span>, token: { from: Int, to: Int, isLine: Bool }): Bool {
		return source.substring(token.from, token.to).trim().indexOf('\n') < 0
			&& values.exists(span -> token.from >= span.to && source.substring(span.to, token.from).indexOf('\n') < 0);
	}

}

/** The resolved seams `PreferTernaryReturn` reads in both `run` and `fix`. */
private typedef Seams = {
	final ifKinds: Array<String>;
	final returnKind: String;
	final support: ControlFlowSupport;
	final shape: RefShape;

	/** The four seams behind `TypeResolver.childReturnTypeSource`, resolved once per run. */
	final functionKinds: Array<String>;

	final lambdaKinds: Array<String>;
	final bodyKinds: Array<String>;
	final paramKinds: Array<String>;
};

/** `preservedComments`' position-split result: the hoisted block plus the one branch-attached comment. */
private typedef PreservedComments = {
	final hoisted: String;
	final branchTrailing: Null<String>;
};

private typedef TernaryMatch = {
	var ifNode: QueryNode;
	var condition: QueryNode;
	var thenValue: QueryNode;
	var elseValue: QueryNode;
	var nextReturn: QueryNode;
};
