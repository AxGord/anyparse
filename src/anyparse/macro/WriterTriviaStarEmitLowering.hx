package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.MacroNames.*;
import anyparse.macro.WriterBlankLowering.*;
import anyparse.macro.WriterBraceSymmetryLowering.*;
import anyparse.macro.WriterCtorPatternLowering.*;
import anyparse.macro.WriterLowering.CascadeInfos;
import anyparse.macro.WriterLowering.PrevBodyInfo;
import anyparse.macro.WriterLowering.StarFieldArgs;
import anyparse.macro.WriterLowering.TriviaStarCtx;
import anyparse.macro.WriterLowering.TryparseSepOverrides;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterPolicyLowering.*;
import anyparse.macro.WriterTriviaSlotLowering.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W - the `@:trivia` Star emit ROUTER and the two routes it owns.
 *
 * `emitTriviaStar` is the whole `if (isTriviaStar)` block of
 * `emitWriterStarField`: it validates the sep / raw / tryparse combinations,
 * builds the `TriviaStarCtx`, and then picks one of three routes - tryparse,
 * close-peek, EOF. Close-peek is `WriterTriviaStarDispatch`'s; the other two
 * are here, `emitTriviaTryparseStar` with the sep-override assembly it alone
 * reads (`buildTryparseSepOverrides`, `buildCloseTrailingFirstSepOverride`)
 * and `emitTriviaEofStar`.
 *
 * A SIZE split, and named as one: the five members are one closed region of
 * `WriterStarEmitLowering`'s call graph with a single inbound edge, not a
 * layer - they take the whole `StarEmitCtx` and read about half its fields,
 * where a layer takes a narrow bundle and answers to several unrelated
 * callers. `WriterStarEmitLowering` was up against the `oversized-type` line
 * cap when they left.
 *
 * ⚠️ Star emission FORKS across FOUR sites - `StarFieldLowering.emitStarFieldSteps`
 * and the `lowerStar*Branch` leaves beside it on the parse side,
 * `emitWriterStarField` (struct field) and `lowerEnumStar` (enum ctor) on the
 * writer side. All four stayed where they were. Nothing here is reachable from
 * `lowerEnumStar` - the enum arm reaches its trivia emit through
 * `lowerEnumStarTrivia` and shares no member with this one - so no fork half
 * was separated from its twin. A change to
 * trivia Star emission still has to visit all four sites, and they still name
 * each other.
 */
@:access(anyparse.macro.TriviaPairAltCtor, anyparse.macro.WriterBlankLowering, anyparse.macro.WriterBraceSymmetryLowering,
	anyparse.macro.WriterCtorPatternLowering, anyparse.macro.WriterLoweringSupport, anyparse.macro.WriterPolicyLowering,
	anyparse.macro.WriterTriviaSlotLowering)
final class WriterTriviaStarEmitLowering {

	/**
	 * `@:trivia` Star dispatch (the whole `if (isTriviaStar)` block of
	 * `emitWriterStarField`). Validates the trivia sep/raw/tryparse combinations,
	 * builds the `TriviaStarCtx` via `buildTriviaStarCtx`, then routes to the
	 * tryparse / close / EOF trivia emit helper. Extracted to keep the orchestrator
	 * under the complexity gate.
	 */
	@:access(anyparse.macro.WriterTriviaStarDispatch)
	private static function emitTriviaStar(ctx: WriterStarEmitLowering.StarEmitCtx, args: StarFieldArgs, parts: Array<Expr>): Void {
		final starNode: ShapeNode = args.starNode;
		final isLastField: Bool = args.isLastField;
		final isRaw: Bool = args.isRaw;
		final closeText: Null<String> = args.closeText;
		final sepText: Null<String> = args.sepText;
		if (isRaw) Context.fatalError('WriterLowering: @:trivia Star does not support @:raw', Context.currentPos());
		// ω-blockended-trivia-tryparse (Session 3): @:trivia + @:sep +
		// @:tryparse is now allowed when the `blockEnded` flag is
		// present (sole consumer: HxCaseBranch.body / HxDefaultBranch.stmts).
		// EOF mode (closeText == null, no @:tryparse) still rejects.
		final writerBlockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		// ω-sep-faithful: valid alternative to blockEnded — sep re-emission
		// keyed purely on the captured per-element `sepAfter`.
		final writerSepFaithful: Bool = starNode.annotations['lit.sepFaithful'] == true;
		if (sepText != null && closeText == null && !starNode.hasMeta(':tryparse'))
			Context.fatalError('WriterLowering: @:trivia + @:sep requires close-peek (@:trail) or @:tryparse', Context.currentPos());
		if (sepText != null && starNode.hasMeta(':tryparse') && !writerBlockEnded && !writerSepFaithful)
			Context.fatalError(
				'WriterLowering: @:trivia + @:sep + @:tryparse requires blockEnded flag (@:sep(text, tailRelax, blockEnded)) '
				+ 'or sepFaithful',
				Context.currentPos()
			);
		// ω-orphan-trivia / ω-close-trailing: Seq-struct call sites
		// drive the trailing slots synthesised on the paired type.
		// Alt-branch Star call sites (`HxStatement.BlockStmt`) have
		// no synth slots and pass null — writer falls back to pre-
		// slice behaviour. `TrailingClose` is only synthesised for
		// close-peek Stars (those with `lit.trailText`); EOF-mode
		// Stars forward null to preserve the post-loop emission
		// shape without a dangling slot access.
		final triviaCtx: TriviaStarCtx = buildTriviaStarCtx(args);
		if (starNode.hasMeta(':tryparse'))
			emitTriviaTryparseStar(ctx, triviaCtx, parts);
		else if (closeText != null)
			WriterTriviaStarDispatch.emitTriviaCloseStar(ctx.triviaStar, triviaCtx, parts);
		else if (isLastField)
			emitTriviaEofStar(ctx, triviaCtx, parts);
		else
			Context.fatalError('WriterLowering: @:trivia Star without @:trail must be the last field', Context.currentPos());
		wrapSiblingFlags(starNode, parts);
	}

	/**
	 * Trivia `@:tryparse` Star dispatch (the `if (starNode.hasMeta(':tryparse'))`
	 * branch of `emitWriterStarField`): refuses a trailed or a non-last led Star, then pushes the lead and the
	 * `triviaTryparseStarExpr` emit onto `parts`, which reads the Star's plan itself.
	 */
	@:access(anyparse.macro.TriviaTryparseLowering)
	private static function emitTriviaTryparseStar(ctx: WriterStarEmitLowering.StarEmitCtx, c: TriviaStarCtx, parts: Array<Expr>): Void {
		if (c.closeText != null) Context.fatalError('WriterLowering: @:trivia + @:tryparse must not have @:trail', Context.currentPos());
		// Non-last-field @:trivia @:tryparse is supported only when
		// the Star is bare (no `@:lead`). The emitted Doc then
		// stands alone (empty array → `_de()`), and the next
		// sibling's leading separator in `lowerStruct` already gates
		// on `prevAnyStarNonEmpty` via the bare-tryparse-Star
		// tracker, so the space between Star output and next
		// field never leaks when the Star was empty. Required by
		// `HxMemberDecl.modifiers` (not last — `member` follows).
		//
		// `@:lead` on a non-last bare-tryparse Star would emit the
		// lead text unconditionally even on empty input, leaking
		// the literal across an otherwise-empty member position.
		// Reject loudly until a grammar needs it AND the empty-
		// input case is gated.
		if (!c.isLastField && c.openText != null)
			Context.fatalError('WriterLowering: non-last @:trivia @:tryparse Star must be bare (no @:lead)', Context.currentPos());
		if (c.openText != null) parts.push(macro _dt($v{c.openText}));
		parts.push(TriviaTryparseLowering.triviaTryparseStarExpr(ctx, c));
	}

	/**
	 * Emit writer steps for a Star struct field.
	 * Trivia `@:tryparse` Star dispatch (the `if (starNode.hasMeta(':tryparse'))`
	 * branch of `emitWriterStarField`). Reads the per-construct `@:fmt` flags and
	 * sep-override switches, then pushes the `triviaTryparseStarExpr` emit onto
	 * `parts`. Extracted so the orchestrator stays under the complexity gate.
	 * Builds the first / subsequent element separator overrides for a
	 * `@:trivia @:tryparse` Star (the close-trailing + block-shape-aware switches).
	 * Bundled for `emitTriviaTryparseStar`. Extracted to keep that helper under the
	 * complexity gate.
	 */
	private static function buildTryparseSepOverrides(
		ctx: WriterStarEmitLowering.StarEmitCtx, starNode: ShapeNode, sameLineName: Null<String>, prevBareRefBody: Null<PrevBodyInfo>,
		elemRefName: String, sepExpr: Expr
	): TryparseSepOverrides {
		final closeTrailingFirstOverride: Null<Expr> = sameLineName != null
			? buildCloseTrailingFirstSepOverride(ctx, prevBareRefBody, sepExpr)
			: null;
		// ω-block-shape-aware: when the Star carries
		// `@:fmt(blockBodyKeepsInline)` AND the prev body's enum has
		// block ctors, force the leading sep before each catch
		// element to `_dt(' ')` whenever the previous body (struct
		// field for the first iteration, prev element's body for
		// subsequent iterations) was a block ctor. Composes with the
		// close-trailing override above by using it as the non-block
		// fallback on the first iteration.
		//
		// ω-statement-bare-break: dual flag `@:fmt(bareBodyBreaks)`
		// flips the cases — block bodies fall through to the policy-
		// driven `sepExpr` (or close-trailing override on the first
		// iteration) and bare bodies force `_dhl()`. Both
		// `HxTryCatchStmt.catches` (block-form ctor with non-block
		// body via `ExprStmt(...)`) and `HxTryCatchStmtBare.catches`
		// (bare-form, body=HxExpr) opt in — non-block prev-body
		// pairs with `tryBody=Next` to keep the multi-line layout
		// coherent: `try\n\tBARE;\ncatch (...)`. Block bodies stay
		// under policy control (`sameLineCatch=Next` still breaks
		// `} catch` to `}\ncatch`). The block-ctor predicate is
		// `isBlockShapeEquivalentBranch` (sister of
		// `isBlockCtorBranch` that also accepts `@:fmt(blockShape)`
		// opt-in ctors like `UntypedBlockStmt(body:HxUntypedFnBody)`,
		// which emits `untyped { … }` — visually a block).
		final blockShapeAware: Bool = starNode.fmtHasFlag('blockBodyKeepsInline');
		final bareShapeAware: Bool = starNode.fmtHasFlag('bareBodyBreaks');
		// omega-try-brace-symmetry: the `BodyPolicy` knobs governing the two bodies this separator
		// can follow — the try body for the FIRST catch, the previous catch's body for every later
		// one. Absent (`@:fmt(bareBodyBreaks)` with no args) keeps the unconditional hardline.
		final barePolicyFields: Array<String> = starNode.fmtReadStringArgs('bareBodyBreaks') ?? [];
		final softSeam: Bool = starNode.fmtHasFlag('constructFitSep');
		final shapeAware: Bool = blockShapeAware || bareShapeAware;
		// Under `blockBodyKeepsInline` the bare branch answers from the policy separator, so a
		// construct-fit seam swaps that separator's `Same` for the group's soft line.
		final softBareSep: Null<Expr> = constructFitBareSep(blockShapeAware, softSeam, sameLineName);
		final bareSep: Expr = softBareSep ?? sepExpr;
		// `bareBodyBreaks` includes blockShape opt-in ctors (e.g.
		// `UntypedBlockStmt`) — they end with `}` and should be
		// treated as block for the catch-separator decision while
		// staying non-block in `bodyPolicyWrap`'s strict block-ctor
		// override path.
		// A bracket list is a value under a construct-fit seam, not a block (see `bodyBreakWrap`).
		final fitValueLists: Bool = softBareSep != null;
		final bodyType: Null<String> = prevBareRefBody?.typePath;
		final blockPatterns: Array<Expr> = sameLineName != null && shapeAware
			? blockBodyPatterns(ctx.ctorPat, bodyType, bareShapeAware, fitValueLists)
			: [];
		final listPatterns: Array<Expr> = fitValueLists ? fitValueListPatterns(ctx.ctorPat, bodyType) : [];
		final seamFlag: Expr = sameLineName == null ? macro null : optFieldAccess(sameLineName);
		final elemBodyField: Null<String> = sameLineName != null && blockPatterns.length > 0
			? findElementBodyField(ctx.ctorPat, elemRefName, prevBareRefBody.typePath)
			: null;
		final blockKeepsInlineBranch: Expr = blockBodyKeepsInlineBranch(starNode);
		final firstSepOverride: Null<Expr> = if (blockPatterns.length == 0) {
			closeTrailingFirstOverride;
		} else {
			final fallback: Expr = closeTrailingFirstOverride ?? sepExpr;
			final blockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : fallback;
			final bareFallback: Expr = softBareSep == null
				? fallback
				: (buildCloseTrailingFirstSepOverride(ctx, prevBareRefBody, softBareSep) ?? softBareSep);
			final bareBranch: Expr = blockShapeAware ? bareFallback : bareSepBreak(barePolicyFields[0], sepExpr, softSeam);
			final cases: Array<Case> = shapeSepCases(blockPatterns, listPatterns, seamFlag, blockBranch, bareBranch);
			{ expr: ESwitch(prevBareRefBody.access, cases, null), pos: Context.currentPos() };
		};
		final subsequentSepOverride: Null<Expr> = if (elemBodyField == null) {
			null;
		} else {
			final prevElemBodyAccess: Expr = { expr: EField(macro _arr[_si - 1].node, elemBodyField), pos: Context.currentPos() };
			final blockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
			final bareBranch: Expr = blockShapeAware ? bareSep : bareSepBreak(barePolicyFields[1], sepExpr, softSeam);
			final cases: Array<Case> = shapeSepCases(blockPatterns, listPatterns, seamFlag, blockBranch, bareBranch);
			{ expr: ESwitch(prevElemBodyAccess, cases, null), pos: Context.currentPos() };
		};
		return { firstSepOverride: firstSepOverride, subsequentSepOverride: subsequentSepOverride };
	}

	/** The soft `Same` separator of a `@:fmt(constructFitSep)` Star under `blockBodyKeepsInline`; null otherwise. */
	private static function constructFitBareSep(blockShapeAware: Bool, softSeam: Bool, sameLineName: Null<String>): Null<Expr> {
		return blockShapeAware && softSeam && sameLineName != null ? softSameLinePolicySwitch(optFieldAccess(sameLineName)) : null;
	}

	/**
	 * ω-close-trailing-alt — runtime override for a Star's first-element
	 * separator when the immediately preceding struct field was a bare
	 * Ref to a trivia-bearing type. Iterates the prev body's Alt branches
	 * looking for close-trailing branches (Star + `@:trail` + `@:trivia`)
	 * — currently only `HxStatement.BlockStmt`. For each, binds the
	 * comment as `_ct`: a LINE comment maps to `_de()` (its guarded emitter
	 * already ended the line, so any sep would leak ` ` between the indent
	 * and the next sibling); a BLOCK comment that ended its source line (the
	 * first element's `newlineBefore`) maps to a hardline, as the later
	 * elements' separator already does; a block comment the source glued
	 * falls through to `sepExpr`, the separator the policy gives with no
	 * comment. Returns `null` when no override is needed (no prev body,
	 * non-bearing target, or no close-trailing branches in the Alt) so the
	 * caller skips the override path.
	 */
	private static function buildCloseTrailingFirstSepOverride(
		ctx: WriterStarEmitLowering.StarEmitCtx, prevBareRefBody: Null<PrevBodyInfo>, sepExpr: Expr
	): Null<Expr> {
		if (prevBareRefBody == null) return null;
		final rule: Null<ShapeNode> = ctx.shape.rules[prevBareRefBody.typePath];
		if (rule == null || rule.kind != Alt) return null;
		final cases: Array<Case> = [];
		for (branch in rule.children) if (TriviaPairAltCtor.isAltCloseTrailingBranch(branch)) {
			final ctorName: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			final ctorPath: Array<String> = ctx.ruleCtorPath(prevBareRefBody.typePath, ctorName);
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
			// Pattern arity: child shape (1 Star) + the closeTrailing slot
			// (which we BIND as `_ct`) + any further synth extras
			// (currently only openTrailing for `:lead` branches; trailOpt /
			// captureSource predicates are disjoint from the close-trailing
			// shape, but the helper covers them for forward compatibility).
			final extras: Int = branchSynthExtraArity(ctx.ctorPat, prevBareRefBody.typePath, branch);
			final patternArgs: Array<Expr> = [macro _, macro _ct];
			for (_ in 0...extras - 1) patternArgs.push(macro _);
			final pattern: Expr = { expr: ECall(ctorRef, patternArgs), pos: Context.currentPos() };
			cases.push({ values: [pattern], guard: macro _ct != null && StringTools.startsWith(_ct, '//'), expr: macro _de() });
			cases.push({ values: [pattern], guard: macro _ct != null && _t.newlineBefore, expr: macro _dhl() });
		}
		if (cases.length == 0) return null;
		cases.push({ values: [macro _], guard: null, expr: sepExpr });
		return { expr: ESwitch(prevBareRefBody.access, cases, null), pos: Context.currentPos() };
	}

	/**
	 * Trivia EOF Star dispatch (the `else if (isLastField)` branch of the
	 * `isTriviaStar` block in `emitWriterStarField`). Reads the cascade infos and
	 * file-header / line-comment blank flags, then pushes the `triviaEofStarExpr`
	 * emit onto `parts`. Extracted to keep the orchestrator under the complexity
	 * gate.
	 */
	@:access(anyparse.macro.TriviaEofLowering, anyparse.macro.WriterCtorBlankLowering)
	private static function emitTriviaEofStar(ctx: WriterStarEmitLowering.StarEmitCtx, c: TriviaStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final elemRefName: String = c.elemRefName;
		final openText: Null<String> = c.openText;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		if (openText != null) parts.push(macro _dt($v{openText}));
		// ω-measured-multiline-decl — this is the ONE Star kind whose scaffold
		// declares `_measMulti`, so this is the one caller that may hand the
		// cascade an accessor into it.
		final measuredMultiline: Bool = starNode.fmtHasFlag('measuredMultilineDecls');
		final cascadeInfos: CascadeInfos = WriterCtorBlankLowering.readCascadeInfosFromStar(
			ctx.ctorBlank, starNode, elemRefName, measuredMultiline ? (macro _measMulti[_si]) : null
		);
		final lineCommentTrailBlank: Bool = starNode.fmtHasFlag('blankBeforeOrphanLineCommentTrail');
		final lineCommentLedAddBlank: Bool = starNode.fmtHasFlag('blankBeforeLineCommentLed');
		final afterFileHeaderCommentBlanks: Bool = starNode.fmtHasFlag('afterFileHeaderCommentBlanks');
		final betweenMultilineCommentsBlanks: Bool = starNode.fmtHasFlag('betweenMultilineCommentsBlanks');
		parts.push(TriviaEofLowering.triviaEofStarExpr(
			fieldAccess, trailBBAccess, trailLCAccess, elemFn, cascadeInfos.afterCtorInfos, cascadeInfos.beforeCtorInfos,
			cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos, cascadeInfos.headCtorInfos, lineCommentTrailBlank,
			lineCommentLedAddBlank, afterFileHeaderCommentBlanks, betweenMultilineCommentsBlanks, cascadeInfos.betweenSameCtorIfNotInfos,
			measuredMultiline
		));
	}

	/**
	 * The comment the field after `prevField` cuddles to that field's trail literal: the literal's own captured slot,
	 * or — for a list whose closing line comment moves past its literal — that comment
	 * (`WriterStarEmitLowering.movedPastTrailExpr`), so the list and this field agree on who writes it.
	 */
	@:access(anyparse.macro.WriterStarEmitLowering)
	private static function priorAfterTrailExpr(ctx: WriterStarEmitLowering.StarEmitCtx, typePath: String, prevField: String): Expr {
		final afterTrail: Expr = { expr: EField(macro value, prevField + TriviaTypeSynth.AFTER_TRAIL_SUFFIX), pos: Context.currentPos() };
		final node: Null<ShapeNode> = ctx.shape.rules[typePath];
		final prev: Null<ShapeNode> = node?.children.find(ch -> ch.annotations[AnnotationKeys.BASE_FIELD_NAME] == prevField);
		final moved: Null<Expr> = prev == null ? null : WriterStarEmitLowering.movedPastTrailExpr(prev);
		return moved == null ? afterTrail : macro $moved ?? $afterTrail;
	}

	/**
	 * The Star's finished Doc is the last part on every emit path, so a lead vote and a list's decision wrap it whole
	 * whatever the Star's shape. An enum-ctor Star does not pass here, and `anyparse.macro.SiblingScope` refuses it as a sharing list.
	 */
	private static function wrapSiblingFlags(starNode: ShapeNode, parts: Array<Expr>): Void {
		final lead: Null<Array<String>> = starNode.fmtReadStringArgs('siblingLead');
		final shared: Null<Array<String>> = starNode.fmtReadStringArgs('siblingShare');
		if (lead == null && shared == null) return;
		final star: Null<Expr> = parts.pop();
		if (star == null) return;
		final voted: Expr = lead == null ? star : macro ${hookFn(lead[0])}(${optFieldAccess(lead[1])}, true, $star);
		parts.push(shared == null ? voted : macro ${hookFn(shared[0])}($voted, ${optFieldAccess(shared[1])}, opt.lineWidth));
	}

}
#end
