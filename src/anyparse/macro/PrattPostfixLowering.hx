package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.macro.Lowering.*;
import anyparse.macro.OperatorLoopLowering.*;
import anyparse.macro.PrattMeta.*;
import anyparse.macro.ParseDispatchLowering.*;
import anyparse.macro.MacroNames.*;

using StringTools;
using anyparse.macro.MetaInspect;

/**
 * Pass 3 helpers - the operator-precedence rule shapes.
 *
 * The two loop shapes `Lowering.lowerRule` dispatches on when a rule
 * carries `@:infix` / `@:ternary` (`lowerPrattLoop`) or `@:postfix`
 * (`lowerPostfixLoop`): an atom call followed by a loop that keeps
 * consuming operators while the next one binds tightly enough. The
 * family is the two entries, the per-branch bodies
 * (`buildPrattBranchBody`, `buildPostfixSuffixBranch`,
 * `buildPostfixStarSuffixBranch`), the two loop skeletons
 * (`buildPrattLoopExpr`, `buildPostfixLoopExpr`) and the operator match
 * (`buildPostfixOpMatchExpr`).
 *
 * Not to be confused with the sibling `OperatorLoopLowering`, which
 * carries the PURE leaves of the same shapes - what a loop emits on its
 * no-match paths - and reads no build state at all. This module is the
 * state-carrying half: every member reads `_ctx.trivia` or reaches the
 * naming vocabulary, which is why it needed a bundle and why the earlier
 * purity split could not take it.
 */
@:access(anyparse.macro.BinaryParseLowering, anyparse.macro.KwBranchLowering, anyparse.macro.Lowering,
	anyparse.macro.OperatorLoopLowering, anyparse.macro.ParseDispatchLowering, anyparse.macro.SpanArgLowering,
	anyparse.macro.StarLoopLowering, anyparse.macro.StructFieldTrailLowering, anyparse.macro.TriviaSlotNames)
final class PrattPostfixLowering {

	/**
	 * Lower the Pratt-loop body for a `@:infix`-annotated enum. The body
	 * implements a standard precedence-climbing loop:
	 *
	 * ```
	 *   var left = parseXxxAtom(ctx);
	 *   while (true) {
	 *       skipWs(ctx);
	 *       final _savedPos = ctx.pos;
	 *       // Operators are dispatched longest-first — the branches
	 *       // are sorted by literal length descending before the
	 *       // chain is folded, so `<=` is tried before `<` and the
	 *       // naive `matchLit` cannot eat a short prefix of a longer
	 *       // operator. Declaration order is irrelevant to dispatch.
	 *       if (matchLit(ctx, "<op1>")) { ... }
	 *       else if (matchLit(ctx, "<op2>")) { ... }
	 *       else break;
	 *   }
	 *   return left;
	 * ```
	 *
	 * Each matched branch checks the operator's precedence against
	 * `minPrec`: if it falls below, the matched literal is rolled back and
	 * the loop breaks — the operator belongs to an outer caller. Otherwise
	 * the right operand is parsed by recursing into `parseXxx` itself at
	 * an elevated `minPrec`, and `left` is replaced with a freshly
	 * constructed ctor call built from the matched branch.
	 *
	 * Associativity is read from the `pratt.assoc` annotation on each
	 * branch (written by `Pratt.annotate`). Left-associative branches
	 * recurse at `prec + 1`, so a second same-prec operator fails the
	 * inner gate and is re-taken by the outer loop iteration, folding
	 * left. Right-associative branches recurse at `prec`, so a second
	 * same-prec operator is absorbed by the inner recursion, folding
	 * right. The per-branch choice is baked in at macro time — no
	 * runtime switch on associativity.
	 */
	private static function lowerPrattLoop(oc: PrattPostfixCtx, node: ShapeNode, typePath: String, simple: String): Expr {
		final returnCT: ComplexType = oc.ruleReturnCT(typePath);
		final loopFnName: String = oc.parseFnName(typePath);
		final atomFnName: String = '${loopFnName}Atom';
		final atomCall: Expr = {
			expr: ECall(macro $i{atomFnName}, [macro ctx]),
			pos: Context.currentPos()
		};
		final operatorBranches: Array<ShapeNode> = [
			for (b in node.children)
				if (b.annotations.get(AnnotationKeys.PRATT_PREC) != null || b.annotations.get(AnnotationKeys.TERNARY_OP) != null) b
		];
		// Longest-match sort: longer operator literals come first in the
		// generated dispatch chain so `<=` is attempted before `<` (and
		// `??` before `?`). Without this, `matchLit(ctx, "<")` succeeds on
		// input `<=`, consumes one char, and leaves `=` stranded for the
		// right operand parser to trip over. The sort is a Lowering-level
		// policy — `matchLit` stays a naive prefix match everywhere else
		// (enum-branch Case 1 `expectLit`, struct lead/trail, Case 4 array
		// loops) where ambiguity cannot arise because the literal is fixed
		// at macro time. Order among equal-length operators is semantically
		// irrelevant (no length-N operator is a prefix of another length-N
		// operator in a well-formed grammar), so `Array.sort` suffices.
		// The sort key uses `pratt.op` for binary infix branches and
		// `ternary.op` for ternary branches — both are operator literals
		// that compete in the same `matchLit` dispatch chain.
		operatorBranches.sort((a, b) -> {
			final la: Int = getOperatorText(a).length;
			final lb: Int = getOperatorText(b).length;
			return lb - la;
		});
		// Fold the operator chain into a nested if/else if tree. Each leaf
		// branch consumes the operator literal (already matched at the
		// peek), enforces `minPrec`, parses the right operand by recursing
		// into `parseXxx` at `prec + 1` for left-associative branches or
		// `prec` for right-associative branches, and rebuilds `left` as
		// the matched ctor call. Ternary branches (detected by `ternary.op`)
		// parse both middle and right operands at `minPrec = 0` (full
		// expression) with an `expectLit` separator in between.
		// ω-pratt-comment-stash: in Trivia mode, the matched-branch internal
		// `skipWs` calls swap to `skipWsAndStash` so any line/block comment
		// between the operator and the next operand is captured verbatim
		// into `ctx.pendingTrivia.leadingComments`. The next `collectTrivia`
		// drains them as leading-of-next-thing — orphan trivia rather than
		// data loss. Without this swap, `a + // c\n b` loses `// c` because
		// the post-op `skipWs` discards it (the outer Pratt rewind only fires
		// on no-match). Plain mode keeps `skipWs` (no Trivia channel).
		final skipFnName: String = oc.ctx.trivia ? 'skipWsAndStash' : 'skipWs';
		final skipCall: Expr = {
			expr: ECall(macro $i{skipFnName}, [macro ctx]),
			pos: Context.currentPos()
		};
		var opChain: Expr = macro _matched = false;
		for (i in 0...operatorBranches.length) {
			final branch: ShapeNode = operatorBranches[operatorBranches.length - 1 - i];
			final opText: String = getOperatorText(branch);
			final branchBody: Expr = buildPrattBranchBody(oc, branch, typePath, simple, skipCall);
			final matchFnName: String = endsWithWordChar(opText) ? 'matchKw' : 'matchLit';
			final matchCall: Expr = {
				expr: ECall(macro $i{matchFnName}, [macro ctx, macro $v{opText}]),
				pos: Context.currentPos()
			};
			opChain = macro if ($matchCall)
				$branchBody
			else
				$opChain;
		}
		// ω-cond-splice: word-like op literals of the ENUM (not only the
		// Pratt tier — the postfix tier's `#if` splice dispatch re-probes
		// from the position this loop exits at). Drives the conditional
		// no-match position restore in `buildPrattLoopExpr`.
		final wordOps: Array<String> = [for (op in collectAllOps(node)) if (endsWithWordChar(op)) op];
		return buildPrattLoopExpr(oc, returnCT, atomCall, opChain, wordOps);
	}

	/**
	 * Lower the postfix-loop body for a `@:postfix`-annotated enum. The
	 * body runs inside the atom wrapper function and looks like:
	 *
	 * ```
	 *   var left = parseXxxAtomCore(ctx);
	 *   while (true) {
	 *       skipWs(ctx);
	 *       var _matched:Bool = true;
	 *       if (matchLit(ctx, "(")) { skipWs; expectLit(")"); left = Ctor(left); }
	 *       else if (matchLit(ctx, "[")) { skipWs; _i = parseXxx(ctx); skipWs; expectLit("]"); left = Ctor(left, _i); }
	 *       else if (matchLit(ctx, ".")) { skipWs; _f = parseHxIdentLit(ctx); left = Ctor(left, _f); }
	 *       else _matched = false;
	 *       if (!_matched) break;
	 *   }
	 *   return left;
	 * ```
	 *
	 * There is no precedence gate and no `_savedPos` rollback. Once a
	 * postfix operator matches, the body commits: a failing inner parse
	 * (e.g. unclosed `[`) throws `ParseError` upward as a hard error.
	 * The loop only terminates by exhausting the dispatch chain — none
	 * of the peeked operators matched, so the postfix-extended atom is
	 * complete and control returns to the caller (usually the Pratt
	 * loop, which then tries its own operators around `left`).
	 *
	 * Longest-first sort on `postfix.op` (same pattern as `lowerPrattLoop`
	 * D33) keeps declaration order irrelevant to dispatch. For slice δ1
	 * the three shipping ops (`.`, `[`, `(`) have unique first characters
	 * so the sort is a no-op, but the guarantee holds for future
	 * shared-prefix cases (e.g. hypothetical `?.` vs `?`).
	 *
	 * Each branch picks one of three body shapes based on a combination
	 * of `postfix.close` presence and the branch's children:
	 *
	 *  1. **pair-lit (call-no-args)** — 1 child (operand only),
	 *     `postfix.close` set. Body: expect close literal, build
	 *     `Ctor(left)`.
	 *  2. **single-Ref-suffix (field access)** — 2 children (operand +
	 *     suffix Ref), `postfix.close` absent. Body: parse the suffix
	 *     Ref, build `Ctor(left, suffix)`. The suffix Ref typically
	 *     points at a Terminal like `HxIdentLit`.
	 *  3. **wrap-with-recurse (index access)** — 2 children (operand +
	 *     inner Ref), `postfix.close` set. Body: parse the inner Ref
	 *     (typically `SelfType`, a full recursive expression), expect
	 *     close, build `Ctor(left, inner)`.
	 *
	 * Validation of the operand child (must be `Ref` to same enum) and
	 * symbolic-op check (no word-like postfix ops yet) run at macro
	 * time — word-like ops would need a word-boundary-aware match helper
	 * which is not wired for postfix in this slice.
	 */
	private static function lowerPostfixLoop(
		oc: PrattPostfixCtx, node: ShapeNode, typePath: String, simple: String, coreFnName: String
	): Expr {
		final returnCT: ComplexType = oc.ruleReturnCT(typePath);
		final enumSimple: String = simple;
		final selfFnName: String = oc.parseFnName(typePath);
		final coreCall: Expr = {
			expr: ECall(macro $i{coreFnName}, [macro ctx]),
			pos: Context.currentPos()
		};
		final postfixBranches: Array<ShapeNode> = [
			for (b in node.children) if (b.annotations.get(AnnotationKeys.POSTFIX_OP) != null) b
		];
		if (postfixBranches.length == 0) {
			Context.fatalError('Lowering: lowerPostfixLoop called with no postfix branches', Context.currentPos());
		}
		// ω-keep-chain-receiver-comment: when this postfix enum has a method-chain
		// `@:fmt(captureChainNewline)` branch (`HxExpr.FieldAccess`), capture the
		// operand's trailing comment at the loop's pre-skipWs site so a bare chain
		// receiver's same-line comment survives the per-iteration `skipWs`. The
		// captured value feeds the FieldAccess ctor's `chainLeadComment` slot;
		// trivia-mode only and gated on the branch flag so every other postfix loop
		// emits the legacy body unchanged (byte-inert non-keep / non-chain).
		var hasChainBranch: Bool = false;
		for (b in postfixBranches) if (b.fmtHasFlag('captureChainNewline')) hasChainBranch = true;
		final wantOpTrail: Bool = oc.ctx.trivia && hasChainBranch;
		// Longest-first sort — same macro-time policy as lowerPrattLoop (D33).
		postfixBranches.sort((a, b) -> {
			final la: Int = (a.annotations.get(AnnotationKeys.POSTFIX_OP): String).length;
			final lb: Int = (b.annotations.get(AnnotationKeys.POSTFIX_OP): String).length;
			return lb - la;
		});
		// Cross-category longer-prefix resolution: a postfix op that is a
		// strict prefix of another op in the same enum (postfix, infix, or
		// ternary) must lose to that longer op. Without this, postfix `.`
		// commits on the first `.` of `...` — then fails to parse a
		// following HxIdentLit and throws upward, rewinding past the entire
		// HxVarDecl/HxClassMember/… chain. Collecting ALL op literals on
		// the enum lets us emit a `!peekLit(longer)` guard per conflict so
		// the postfix dispatch declines and Pratt picks up the longer op.
		final allOps: Array<String> = collectAllOps(node);
		// Fold the dispatch chain right-to-left, mirroring lowerPrattLoop.
		var opChain: Expr = macro _matched = false;
		for (i in 0...postfixBranches.length) {
			final branch: ShapeNode = postfixBranches[postfixBranches.length - 1 - i];
			final op: String = branch.annotations[AnnotationKeys.POSTFIX_OP];
			final close: Null<String> = branch.annotations[AnnotationKeys.POSTFIX_CLOSE];
			final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
			// Word-like postfix ops (ω-cond-splice: '#if' as the dispatch of
			// `CondSpliceTail`) route through `matchKw` in
			// `buildPostfixOpMatchExpr` — word-boundary-checked, so an
			// identifier merely PREFIXED by the op text never commits.
			final children: Array<ShapeNode> = branch.children;
			if (children.length == 0 || children[0].kind != Ref) {
				Context.fatalError(
					'Lowering: @:postfix branch "$ctor" must have operand:$enumSimple as its first argument', Context.currentPos()
				);
			}
			final operandRef: String = children[0].annotations.get(AnnotationKeys.BASE_REF);
			if (simpleName(operandRef) != enumSimple) {
				Context.fatalError('Lowering: @:postfix operand must reference the same enum ($enumSimple)', Context.currentPos());
			}
			final ctorPath: Array<String> = oc.ruleCtorPath(typePath, ctor);
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
			final branchBody: Expr = if (children.length == 1) {
				buildPostfixSingleBranch(close, ctorRef);
			} else if (children.length == 2 && children[1].kind == Star) {
				buildPostfixStarSuffixBranch(oc, branch, children, close, ctor, ctorRef, enumSimple, selfFnName);
			} else if (children.length == 2) {
				buildPostfixSuffixBranch(oc, children, ctor, ctorRef, close, branch, enumSimple, selfFnName);
			} else {
				Context.fatalError(
					'Lowering: @:postfix branch "$ctor" has ${children.length} arguments; expected 1 (pair-lit), 2 (suffix/Star form)',
					Context.currentPos()
				);
				throw 'unreachable';
			};
			// Prepend `!peekLit(longerOp)` guards for every op literal that
			// strictly starts with `op`. Short-circuits so matchLit is not
			// called when a longer op is about to match.
			final matchExpr: Expr = buildPostfixOpMatchExpr(oc, op, allOps);
			opChain = macro if ($matchExpr)
				$branchBody
			else
				$opChain;
		}
		// ω-trivia-sep: same pre-skipWs save + comment-only rewind as
		// `lowerPrattLoop`. See that function for the rationale.
		// ω-cond-comp-expr-multiline: mirror lowerPrattLoop's
		// `ω-untyped-keep` newline-stash on postfix-loop exit. When the
		// loop's last skipWs consumed a `\n` (and no comment, no postfix
		// match), the newline is otherwise silently dropped — Pratt's
		// outer trivia loop saves `_preWsPos` at the position the postfix
		// loop returns from, so by the time Pratt's own stash logic runs
		// the newline is already past `_preWsPos` and the scan-back finds
		// nothing. Without the stash, downstream `collectTrivia` calls
		// (e.g. the `@:trivia @:tryparse Star` `elseifs` of
		// `HxConditionalExpr` after `expr` is parsed) read
		// `newlineBefore=false` and the writer's pad-as-hardline lift
		// fires false on the `expr → elseifs[0]` boundary even when
		// source is multi-line.
		// ω-keep-chain-receiver-comment: capture the operand's same-line trailing
		// comment at the dot gap BEFORE the per-iteration `skipWs` eats it.
		// `collectTrailingFull` consumes only horizontal ws + a same-line comment
		// (rewinding on none) and stops at the newline, so the subsequent `skipWs`
		// lands at the identical position — position-inert for every branch — while
		// the FieldAccess branch reads `_opTrailComment` into its `chainLeadComment`
		// slot. Declared `null` when this enum has no chain branch so the local stays
		// in scope for the branch bodies without invoking the helper.
		final opTrailCapture: Expr = wantOpTrail
			? macro final _opTrailComment: Null<String> = collectTrailingFull(ctx)
			: macro final _opTrailComment: Null<String> = null;
		final postfixWordOps: Array<String> = [for (op in collectAllOps(node)) if (endsWithWordChar(op)) op];
		return buildPostfixLoopExpr(oc, returnCT, coreCall, opTrailCapture, opChain, postfixWordOps);
	}

	private static function buildPrattBranchBody(
		oc: PrattPostfixCtx, branch: ShapeNode, typePath: String, simple: String, skipCall: Expr
	): Expr {
		// noqa: complexity
		final returnCT: ComplexType = oc.ruleReturnCT(typePath);
		final loopFnName: String = oc.parseFnName(typePath);
		final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final ctorPath: Array<String> = oc.ruleCtorPath(typePath, ctor);
		final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
		final isTernary: Bool = branch.annotations[AnnotationKeys.TERNARY_OP] != null;
		final opText: String = getOperatorText(branch);
		final precValue: Int = isTernary
			? (branch.annotations[AnnotationKeys.TERNARY_PREC]: Int)
			: (branch.annotations[AnnotationKeys.PRATT_PREC]: Int);
		return if (isTernary) {
			// Ternary branch: three operands (cond, middle, right).
			// Both middle and right parse at minPrec=0 (full expression).
			final sepText: String = branch.annotations[AnnotationKeys.TERNARY_SEP];
			final fullExprCall: Expr = {
				expr: ECall(macro $i{loopFnName}, [macro ctx, macro $v{0}]),
				pos: Context.currentPos()
			};
			// ω-keep-ternary-operand-comment: `@:fmt(captureTernaryTrail)` grows
			// two operand-trailing slots. The CONDITION's comment is already in
			// scope as the Pratt loop's `_opTrailComment` (collected before the
			// `?` matched, and restored by the no-match rewind when this branch
			// declines); the THEN branch's is collected right after its operand
			// parse, before `$skipCall` stashes it into `pendingTrivia` where it
			// would leak out and be re-emitted below the whole statement.
			// Both styles are accepted: unlike the infix RHS slot there is no
			// enclosing chain that could own the comment — the mandatory `:` /
			// the ternary's own end bound it.
			final captureTernaryTrail: Bool = oc.ctx.trivia && branch.fmtHasFlag('captureTernaryTrail');
			final ctorArgs: Array<Expr> = [macro left, macro _middle, macro _right];
			if (captureTernaryTrail) {
				ctorArgs.push(macro _opTrailComment);
				ctorArgs.push(macro _thenTrailComment);
			}
			final ctorCall: Expr = {
				expr: ECall(ctorRef, ctorArgs),
				pos: Context.currentPos()
			};
			final thenTrailCapture: Expr = captureTernaryTrail
				? macro final _thenTrailComment: Null<String> = collectTrailingFull(ctx)
				: macro {};
			final clearStashNl: Expr = oc.stashNewlineClearExpr();
			macro {
				if ($v{precValue} < minPrec) {
					ctx.pos = _savedPos;
					_matched = false;
				} else {
					$clearStashNl;
					$skipCall;
					final _middle: $returnCT = $fullExprCall;
					$thenTrailCapture;
					$skipCall;
					expectLit(ctx, $v{sepText});
					$skipCall;
					// The separator is the ternary's SECOND operator commit — the middle
					// operand's own loop exit can have stashed the gap before it.
					$clearStashNl;
					final _right: $returnCT = $fullExprCall;
					left = $ctorCall;
				}
			};
		} else {
			// Binary infix branch: two operands (left, right). The right
			// operand normally recurses into the same Pratt loop at an
			// elevated minPrec to enforce associativity. When the right
			// child references a different enum than the loop's own
			// (asymmetric infix, e.g. `x is Type` where left:HxExpr but
			// right:HxType), recursing into the same loop is wrong — call
			// the other type's parse function once at its default starting
			// precedence and let outer Pratt iteration handle chaining.
			final assocValue: String = branch.annotations[AnnotationKeys.PRATT_ASSOC];
			final nextMinPrec: Int = assocValue == 'Right' ? precValue : precValue + 1;
			final rightChildren: Array<ShapeNode> = branch.children;
			final rightChild: ShapeNode = rightChildren[1];
			final rightRef: Null<String> = rightChild.kind == Ref ? rightChild.annotations[AnnotationKeys.BASE_REF] : null;
			final isAsymmetric: Bool = rightRef != null && simpleName(rightRef) != simple;
			final rightCT: ComplexType = isAsymmetric ? oc.ruleReturnCT(rightRef) : returnCT;
			final rightCall: Expr = if (isAsymmetric)
				{ expr: ECall(macro $i{oc.parseFnName(rightRef)}, [macro ctx]), pos: Context.currentPos() }
			else
				{ expr: ECall(macro $i{loopFnName}, [macro ctx, macro $v{nextMinPrec}]), pos: Context.currentPos() };
			// ω-keep-chain (increment 2): in Trivia mode, infix ctors carrying
			// `@:fmt(captureChainNewline)` (the chain ctors Add/Sub/And/Or)
			// grow a 3rd positional `chainNewline:Bool` synth arg holding
			// whether the source had a newline anywhere in the gap before
			// this ctor's RIGHT operand. Two sources:
			//  (1) `hasNewlineIn(ctx.input, _preWsPos, ctx.pos)` — the gap
			//      [before-op .. after-op-WS] scan. Correct whenever the gap
			//      newline is NOT pre-consumed by a higher-prec left-operand
			//      recursion (covers `a +\n b` and any chain whose left
			//      operand is an atom).
			//  (2) `ctx.pendingTrivia.newlineBefore` (boolean OR, `&&`/`||`
			//      ONLY) — when the left operand is itself an infix sub-expr
			//      (`X == Y && …`), its right-operand recursion's no-match
			//      already CONSUMED the `\n` before this operator and stashed
			//      the signal into pendingTrivia (the ω-untyped-keep stash),
			//      so the span scan misses it. Scoped to the boolean
			//      operators because their operands are routinely
			//      higher-precedence comparisons that pre-consume the gap;
			//      `+`/`-` keep relies on the span scan alone to avoid the
			//      head-leading-newline pollution that the stash carries when
			//      an additive chain is the head of a freshly-opened paren
			//      (`!(\n a.y + b.h …`). The flag is cleared after the read so
			//      it does not leak to the next operand. O(1), no recursive
			//      probe. Plain mode keeps the 2-arg ctor (synth widens only
			//      in Trivia).
			final captureChainNl: Bool = oc.ctx.trivia && branch.fmtHasFlag('captureChainNewline');
			// ω-keep-infix-rhs-comment: capture a same-line comment trailing the
			// RIGHT operand (position #3 — before the enclosing `)`/`;`/`,`).
			final captureRhsTrail: Bool = oc.ctx.trivia && branch.fmtHasFlag('captureRhsTrail');
			final isBoolChainOp: Bool = opText == '&&' || opText == '||';
			final ctorArgs: Array<Expr> = [macro left, macro _right];
			if (captureChainNl) {
				ctorArgs.push(macro _chainNl);
				ctorArgs.push(macro _opTrailComment);
				ctorArgs.push(macro _opAfterComment);
			}
			if (captureRhsTrail) ctorArgs.push(macro _opRhsTrail);
			final ctorCall: Expr = { expr: ECall(ctorRef, ctorArgs), pos: Context.currentPos() };
			// `_chainNl` is declared in the commit block; the right-operand
			// parse + ctor build live in the SAME block so it stays in scope
			// for `$ctorCall`. Non-capturing branches keep the legacy body.
			final chainNlValue: Expr = isBoolChainOp
				? macro hasNewlineIn(ctx.input, _preWsPos, ctx.pos) || (ctx.pendingTrivia != null && ctx.pendingTrivia.newlineBefore)
				: macro hasNewlineIn(ctx.input, _preWsPos, ctx.pos);
			final commitParts: Array<Expr> = [];
			// ω-keep-infix-postop-comment: capture a same-line comment trailing the
			// operator (before the right operand) BEFORE `skipWsAndStash` stashes it
			// into pendingTrivia (where it leaks into the next operand's parse).
			if (captureChainNl) commitParts.push(macro final _opAfterComment: Null<String> = collectTrailingFull(ctx));
			commitParts.push(skipCall);
			if (captureChainNl) commitParts.push(macro final _chainNl: Bool = $chainNlValue);
			// AFTER the `_chainNl` read (`&&`/`||` consume the very flag this drops).
			commitParts.push(oc.stashNewlineClearExpr());
			commitParts.push(macro final _right: $rightCT = $rightCall);
			// Restrict RHS-trail to BLOCK comments (`/* */`): a same-line LINE
			// comment after the operand belongs to an enclosing chain operator's
			// line-break slot (chainLeadComment) or the statement trailing slot —
			// stealing it here would collapse the chain and comment out the tail.
			// Block comments are inline-safe, so keep + rewind line comments.
			if (captureRhsTrail) {
				commitParts.push(macro final _savedRhsPos: Int = ctx.pos);
				commitParts.push(macro final _rhsRaw: Null<String> = collectTrailingFull(ctx));
				commitParts.push(
					macro final _opRhsTrail: Null<String> = _rhsRaw != null && StringTools.startsWith(_rhsRaw, '/*') ? _rhsRaw : null
				);
				commitParts.push(macro if (_opRhsTrail == null) ctx.pos = _savedRhsPos);
			}
			commitParts.push(macro left = $ctorCall);
			final commitBody: Expr = macro $b{commitParts};
			macro {
				if ($v{precValue} < minPrec) {
					ctx.pos = _savedPos;
					_matched = false;
				} else
					$commitBody;
			};
		};
	}

	private static function buildPrattLoopExpr(
		oc: PrattPostfixCtx, returnCT: ComplexType, atomCall: Expr, opChain: Expr, ?wordOps: Array<String>
	): Expr {
		// ω-trivia-sep: in Trivia mode, save pos BEFORE the per-iteration
		// `skipWs`. On no-match, scan the consumed range for comment
		// markers — if any are present, rewind to preserve the comment
		// for a sibling's `collectTrailing` capture (otherwise `field: ""
		// // some comment` loses its trailing comment). Plain whitespace
		// and `\n` stay consumed so `@:raw` siblings (e.g. `${expr}` in
		// string interp, where the trailing literal expects `}` directly
		// without skipWs) keep working: no comment → no rewind.
		// ω-pratt-comment-stash: outer per-iter skipWs swaps to skipWsAndStash
		// so comments BEFORE an operator (`a /* c */ + b`) get captured into
		// `pendingTrivia` when an op matches. On no-match rewind, the
		// captured comments must also be popped from the stash — otherwise
		// the caller's collectTrivia sees them AND re-captures from input,
		// duplicating. `_stashCount0` snapshot lets us truncate.
		final noMatch: Expr = buildPrattNoMatchHandlerExpr();
		return oc.ctx.trivia
			? macro {
				var left: $returnCT = $atomCall;
				while (true) {
					final _preWsPos: Int = ctx.pos;
					// ω-keep-infix-operand-comment: capture the left operand's
					// same-line trailing comment before `skipWsAndStash` consumes it,
					// mirroring the postfix loop's receiver-comment capture. Position-
					// inert — collectTrailingFull rewinds when there is no comment, and
					// on no operator match the `_hadComment` rewind (scanning from
					// `_preWsPos`) restores a consumed comment; only a matched chain
					// ctor reads it into its chainLeadComment slot.
					final _opTrailComment: Null<String> = collectTrailingFull(ctx);
					final _stashCount0: Int = ctx.pendingTrivia == null ? 0 : ctx.pendingTrivia.leadingComments.length;
					skipWsAndStash(ctx);
					final _savedPos: Int = ctx.pos;
					var _matched: Bool = true;
					$opChain;
					$noMatch;
				}
				return left;
			}
			: macro {
				var left: $returnCT = $atomCall;
				while (true) {
					// ω-cond-splice: save BEFORE skipWs and restore on no-match
					// ONLY when a word-like op (`#if` splice dispatch) is the
					// next token — an ENCLOSING atom's postfix loop reads the
					// operand↔`#if` gap for its same-line gate, and an inner
					// loop that consumed the newline on its way out would blind
					// it. The restore is CONDITIONAL because `@:raw` siblings
					// (`${expr}` string interpolation) expect the whitespace
					// consumed — an unconditional restore breaks them.
					final _preWsPos: Int = ctx.pos;
					skipWs(ctx);
					final _savedPos: Int = ctx.pos;
					var _matched: Bool = true;
					$opChain;
					if (!_matched) {
						${buildWordOpRestoreExpr(wordOps)};
						break;
					}
				}
				return left;
			};
	}

	private static function buildPostfixStarSuffixBranch(
		oc: PrattPostfixCtx, branch: ShapeNode, children: Array<ShapeNode>, close: Null<String>, ctor: String, ctorRef: Expr,
		enumSimple: String, selfFnName: String
	): Expr {
		// Star-suffix form: `Call(operand:T, args:Array<T>)` with
		// @:postfix('(', ')') @:sep(','). The Star child wraps a Ref to the
		// element type. After the open literal is consumed by the outer
		// matchLit, this emits a sep-peek array loop and then expects close.
		if (close == null) {
			Context.fatalError(
				'Lowering: @:postfix Star-suffix branch "$ctor" requires @:postfix(open, close) pair form', Context.currentPos()
			);
			throw 'unreachable';
		}
		final starNode: ShapeNode = children[1];
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: @:postfix Star child must be a Ref', Context.currentPos());
			throw 'unreachable';
		}
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = simpleName(elemRefName) == enumSimple ? selfFnName : oc.parseFnName(elemRefName);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos()
		};
		final elemCT: ComplexType = oc.ruleReturnCT(elemRefName);
		// See struct-field close-peek (emitStarFieldSteps) for why
		// we flip to full-string `peekLit` when close is multi-byte.
		final closeCharCode: Int = close.charCodeAt(0);
		final closeNotNextExpr: Expr = close.length == 1
			? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
			: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{close});
		final sepText: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final ctorCall: Expr = { expr: ECall(ctorRef, [macro left, macro _args]), pos: Context.currentPos() };
		// ω-postfix-call-trailing: when the synth pair grew a
		// `closeTrailing:Null<String>` slot (see
		// `TriviaTypeSynth.isPostfixCloseTrailingBranch`), the trivia
		// branch's ctor call grows a third positional arg. The slot
		// is filled by `collectTrailingFull` after `expectLit(close)`
		// — capturing same-line `// c` / `/* c */` between `)` and
		// the next postfix step's leading-trivia. Without the slot,
		// the inner `skipWs(ctx)` of the next postfix iteration eats
		// the comment.
		//
		// ω-D9A-keep-callargs-v2: alongside `_trailClose`, the ctor
		// call grows a fourth positional `_argsOpenNewline:Bool`
		// captured BEFORE the per-iter `skipWs`/`collectTrivia` (see
		// macro block below). The signal feeds `lowerPostfixStar`'s
		// Keep-mode args[0] hardline; `Trivial.newlineBefore` for
		// args[0] is unreliable due to upstream `ctx.pendingTrivia`
		// leak so a separate parser-side capture is required.
		final ctorCallTrivia: Expr = {
			expr: ECall(ctorRef, [
				macro left,
				macro _args,
				macro _trailClose,
				macro _argsOpenNewline,
				macro _argsCloseNewline,
				macro _argsInnerComment,
				macro _callLeadingComment
			]),
			pos: Context.currentPos()
		};
		// ω-postfix-starsuffix-trivia: when TriviaAnalysis marks
		// this Star with `trivia.starCollects=true` (auto-set for
		// postfix Star-suffix branches), the synth wraps the
		// args type as `Array<Trivial<elemCT>>` and the parser
		// captures per-arg trailing comments. Mirrors lowerStruct's
		// trivia-Star pattern: horizontal-only-skip before sep match
		// so an inline `// comment` or `/* x */` after each arg lands
		// in `collectTrailing` instead of being eaten by `skipWs`.
		final triviaCollect: Bool = oc.ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		if (triviaCollect && sepText != null) {
			final wrappedCT: ComplexType = TPath({
				pack: ['anyparse', 'runtime'],
				name: 'Trivial',
				params: [TPType(elemCT)]
			});
			final sepCharCode: Int = sepText.charCodeAt(0);
			return buildPostfixCallArgsTriviaLoop(
				elemCT, elemCall, wrappedCT, closeNotNextExpr, sepCharCode, sepText, close, ctorCallTrivia
			);
		}
		if (sepText != null) {
			final sepCharCode: Int = sepText.charCodeAt(0);
			return macro {
				skipWs(ctx);
				final _args: Array<$elemCT> = [];
				if ($closeNotNextExpr) {
					_args.push($elemCall);
					skipWs(ctx);
					// Permissive sep (ω-span-sep-permissive) — see
					// lowerStarSepBranch for rationale; same trivia-loop
					// alignment applied to the postfix Star-suffix loop
					// (call args).
					while ($closeNotNextExpr) {
						if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
							ctx.pos++;
							skipWs(ctx);
							if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
						}
						_args.push($elemCall);
						skipWs(ctx);
					}
				}
				skipWs(ctx);
				expectLit(ctx, $v{close});
				left = $ctorCall;
			};
		}
		if (triviaCollect) {
			// triviaCollect is auto-set only on `@:postfix(...) @:sep(...)`
			// branches by `TriviaAnalysis.markPostfixStarSuffix`, so this
			// branch is unreachable today. Surface the invariant loud rather
			// than carrying dead code that silently mishandles a future
			// no-sep variant.
			Context.fatalError(
				'Lowering: postfix Star-suffix branch "$ctor'
				+ '" has trivia.starCollects=true without @:sep — TriviaAnalysis should not auto-mark this shape; needs explicit support',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		// No separator — peek-close loop (same as Case 4 no-sep).
		return macro {
			skipWs(ctx);
			final _args: Array<$elemCT> = [];
			while ($closeNotNextExpr) {
				_args.push($elemCall);
				skipWs(ctx);
			}
			skipWs(ctx);
			expectLit(ctx, $v{close});
			left = $ctorCall;
		};
	}

	private static function buildPostfixSuffixBranch(
		oc: PrattPostfixCtx, children: Array<ShapeNode>, ctor: String, ctorRef: Expr, close: Null<String>, branch: ShapeNode,
		enumSimple: String, selfFnName: String
	): Expr {
		final suffix: ShapeNode = children[1];
		if (suffix.kind != Ref) {
			Context.fatalError('Lowering: @:postfix branch "$ctor" second argument must be a Ref', Context.currentPos());
			throw 'unreachable';
		}
		final suffixRef: String = suffix.annotations[AnnotationKeys.BASE_REF];
		// For the wrap-with-recurse form, the inner Ref typically points
		// at SelfType — to force a full expression parse reset we call
		// `parseXxx` directly (via its public entry) rather than the
		// atom wrapper. This lets a `[a + b]` index expression contain
		// arbitrary infix operators. For the single-Ref-suffix form,
		// the suffix is usually a Terminal like HxIdentLit and the
		// `parseXxxSuffix` call is just a terminal call.
		final suffixFn: String = simpleName(suffixRef) == enumSimple ? selfFnName : oc.parseFnName(suffixRef);
		final suffixCall: Expr = {
			expr: ECall(macro $i{suffixFn}, [macro ctx]),
			pos: Context.currentPos()
		};
		final suffixCT: ComplexType = oc.ruleReturnCT(suffixRef);
		// ω-keep-chain (increment 9): a `@:postfix('.')` ctor carrying
		// `@:fmt(captureChainNewline)` (`HxExpr.FieldAccess`) grows a 3rd
		// positional `chainNewline:Bool` synth arg in Trivia mode holding
		// whether the source had a newline in the gap BEFORE the `.`
		// dispatch. `_preWsPos` (the trivia while-loop's pre-skipWs save)
		// to `ctx.pos` (just past the matched `.`) spans exactly the
		// dot-leading gap; the `.` is a single non-newline char so the
		// scan is equivalent to the gap before it. The writer's chain
		// dispatch reads it into a `_breaks` array parallel to `_segs`
		// and threads it to `MethodChainEmit.emit(..., sourceBreakBefore)`
		// so a `WrapMode.Keep` method-chain round-trips the source per-
		// segment dot-boundary line breaks. Plain mode keeps the original
		// 2-arg ctor arity (no slot; chain always glues via shapeNoWrap).
		final captureChainNl: Bool = oc.ctx.trivia && branch.fmtHasFlag('captureChainNewline');
		// ω-postfix-op-space: a word-op postfix ctor with
		// `@:fmt(capturePostfixOpSpace)` grows a positional `opSpaceBefore:Bool`
		// synth arg in Trivia mode — whether the source had whitespace between
		// the operand and the operator. At branch entry `ctx.pos` sits just past
		// the matched operator and `_preWsPos` is the loop's pre-skipWs save, so
		// the gap is non-empty iff their distance exceeds the operator length.
		final captureOpSpace: Bool = oc.ctx.trivia && branch.fmtHasFlag('capturePostfixOpSpace');
		final postfixOpLen: Int = (branch.annotations[AnnotationKeys.POSTFIX_OP]: String).length;
		// ω-keep-chain-receiver-comment: the FieldAccess ctor grows a 4th
		// positional `chainLeadComment:Null<String>` slot after `chainNewline`.
		// It reads `_opTrailComment` — the operand's trailing comment captured
		// at the loop's pre-skipWs site (see the trivia postfix loop below).
		// The slot lets the writer's keep-mode chain dispatch reattach a bare
		// receiver's trailing comment (`owner // test`) that the per-iteration
		// `skipWs` would otherwise eat.
		final ctorCall: Expr = {
			expr: ECall(
				ctorRef,
				captureChainNl
					? [
						macro left,
						macro _suffix,
						macro _chainNl,
						macro _opTrailComment
					]
					: captureOpSpace
						? [
							macro left,
							macro _suffix,
							macro _opSpaceBefore
						]
						: [
							macro left,
							macro _suffix
						]
			),
			pos: Context.currentPos()
		};
		return if (close != null)
			macro {
				skipWs(ctx);
				final _suffix: $suffixCT = $suffixCall;
				skipWs(ctx);
				expectLit(ctx, $v{close});
				left = $ctorCall;
			}
		else if (captureChainNl)
			macro {
				final _chainNl: Bool = hasNewlineIn(ctx.input, _preWsPos, ctx.pos);
				skipWs(ctx);
				final _suffix: $suffixCT = $suffixCall;
				left = $ctorCall;
			}
		else if (captureOpSpace)
			macro {
				final _opSpaceBefore: Bool = ctx.pos - _preWsPos > $v{postfixOpLen};
				skipWs(ctx);
				final _suffix: $suffixCT = $suffixCall;
				left = $ctorCall;
			}
		else
			macro {
				skipWs(ctx);
				final _suffix: $suffixCT = $suffixCall;
				left = $ctorCall;
			};
	}

	private static function buildPostfixLoopExpr(
		oc: PrattPostfixCtx, returnCT: ComplexType, coreCall: Expr, opTrailCapture: Expr, opChain: Expr, ?wordOps: Array<String>
	): Expr {
		// Trivia mode adds the per-iteration operand-trail capture and the
		// no-match scan-back (comment-rewind / newline-stash); plain mode is
		// the bare matchExpr dispatch loop.
		final scanback: Expr = buildPostfixNoMatchScanback();
		final clearStashNl: Expr = oc.stashNewlineClearExpr();
		return oc.ctx.trivia
			? macro {
				var left: $returnCT = $coreCall;
				while (true) {
					final _preWsPos: Int = ctx.pos;
					$opTrailCapture;
					skipWs(ctx);
					var _matched: Bool = true;
					$opChain;
					if (!_matched) {
						$scanback;
						break;
					}
					// A matched suffix keeps the expression open, so any stash the
					// core / the suffix payload left describes an INTERIOR gap —
					// `(foo\n).bar` must not report a line break before whatever
					// follows `.bar`. See `stashNewlineClearExpr`.
					$clearStashNl;
				}
				return left;
			}
			: macro {
				var left: $returnCT = $coreCall;
				while (true) {
					final _preWsPos: Int = ctx.pos;
					skipWs(ctx);
					var _matched: Bool = true;
					$opChain;
					if (!_matched) {
						// ω-cond-splice: conditional restore — see
						// buildPrattLoopExpr (unconditional restore breaks
						// `@:raw` interpolation siblings).
						${buildWordOpRestoreExpr(wordOps)};
						break;
					}
				}
				return left;
			};
	}

	private static function buildPostfixOpMatchExpr(oc: PrattPostfixCtx, op: String, allOps: Array<String>): Expr {
		// Prepend `!peekLit(longerOp)` guards for every op literal that
		// strictly starts with `op`. Short-circuits so matchLit is not
		// called when a longer op is about to match.
		// Word-like postfix ops (cond-splice `#if`) carry an OWN-LINE gate.
		// A `#if` on its own line after a no-semi BLOCK-ENDED statement is a
		// structured STATEMENT conditional, not an infix splice-tail: without
		// the gate the splice raw-swallows it and the enclosing statement then
		// fails on the next token. Two live shapes need the rejection --
		// `@:privateAccess { ... }` followed by an own-line
		// `#if debug final t = ...; #end`
		// (`TM-Haxe4/src/video/GpuDirectPipeline.hx:52`, the original dogfood
		// catch recorded when this gate was written), and a `switch { ... }`
		// assignment followed by an own-line
		// `#if (haxe_ver >= 4.10) if (...) #else if (...) #end`
		// (`pony/ui/xml/HeapsXmlUi.hx:202`).
		//
		// The gate was UNCONDITIONAL on the newline until this slice, which
		// also rejected the two legitimate own-line SPLICE TAILS --
		// `return __idleThreads\n#if lime_threads - __queuedExitEvents #end;`
		// (`lime/system/ThreadPool.hx:1029`) and the in-condition operand form
		// `if (intf != null\n// ...\n#if (js_es >= 6) && (...) #end)`
		// (`std/js/Boot.hx:151`). Two predicates admit those without admitting
		// the scope-level regions:
		//  - `spliceFragmentIsInfix` is the discriminator: a splice TAIL
		//    continues the operand, so past the condition atom its fragment
		//    opens with an infix operator, while a scope-level region opens
		//    with a declaration, statement, list separator or metadata. It is
		//    what keeps the param-list
		//    (`whitespace/issue_582_type_hints_conditionals`) and array-element
		//    (`wrapping/issue_207_array_wrapping_with_conditionals`) fixtures
		//    on their own productions -- a newline-blind relaxation broke both.
		//  - `endsWithBlockClose` is the belt-and-braces half: a Haxe statement
		//    terminable WITHOUT a `;` always ends with `}`, so an own-line
		//    `#if` after a `}` is a statement conditional whatever its fragment
		//    looks like.
		// The same-line case is untouched (no newline => always a splice tail),
		// so the relaxation only ever ADDS accepted input.
		//
		// TRIVIA-MODE NEWLINE SOURCE #2 (ω-cond-splice-stash-newline). The gap
		// scan alone is BLIND when the operand's own parse pre-consumed the gap:
		// a construct ending in a `@:trivia @:tryparse` Star
		// (`HxTryCatchExpr.catches`) runs one no-match iteration past the
		// operand, which skips the newline and stashes the signal into
		// `ctx.pendingTrivia` (the ω-untyped-keep stash). The postfix loop then
		// saves `_preWsPos` PAST the newline, the gap scan reads empty, and an
		// own-line statement region binds as a SAME-LINE splice tail --
		// `try f() catch (_:Exception) {}` followed by an own-line
		// `#if cpp ... #end` raw-swallowed the whole region (dogfood
		// `utils/CleanExit.hx:36`); the glue then fed the region's flat width
		// into the operand's rest-stack and wrapped a method chain that fit.
		// `pendingTrivia.newlineBefore` is the same second newline source that
		// `captureChainNewline` already ORs in (see `chainNlValue`). This scan
		// runs in the MATCH expression, before any operator of the iteration has
		// committed, so `stashNewlineClearExpr` at the loop's matched tail cannot
		// blind it: the next iteration re-derives its gap from a freshly saved
		// `_preWsPos`, and the flag that tail dropped described a gap BEFORE the
		// operator already consumed.
		//
		// The leading `peekLit` is a pure cost guard: `matchKw` has to stay LAST
		// (it consumes on success), so without it both scanners would run at
		// every postfix-loop iteration whose operand happens to end a line.
		final gapNewline: Expr = oc.ctx.trivia
			? macro (hasNewlineIn(ctx.input, _preWsPos, ctx.pos) || (ctx.pendingTrivia != null && ctx.pendingTrivia.newlineBefore))
			: macro hasNewlineIn(ctx.input, _preWsPos, ctx.pos);
		var matchExpr: Expr = endsWithWordChar(op)
			? macro peekLit(ctx, $v{op}) && (
				!$gapNewline || (!endsWithBlockClose(ctx.input, _preWsPos) && spliceFragmentIsInfix(ctx.input, ctx.pos + $v{op.length}))
			) && matchKw(ctx, $v{op})
			: macro matchLit(ctx, $v{op});
		for (other in allOps) {
			if (other.length > op.length && other.startsWith(op)) {
				matchExpr = macro !peekLit(ctx, $v{other}) && $matchExpr;
			}
		}
		return matchExpr;
	}

}

/**
 * The build state `PrattPostfixLowering` reads, bundled once in
 * `Lowering`'s constructor. `ctx` is the only owner field the family
 * touches (always as `ctx.trivia`); the four closures are the naming
 * vocabulary that stayed in `Lowering`.
 */
typedef PrattPostfixCtx = {
	final ctx: LoweringCtx;
	final parseFnName: (refName:String) -> String;
	final ruleCtorPath: (typePath:String, ctor:String) -> Array<String>;
	final ruleReturnCT: (refName:String) -> ComplexType;
	final stashNewlineClearExpr: () -> Expr;
}
#end
