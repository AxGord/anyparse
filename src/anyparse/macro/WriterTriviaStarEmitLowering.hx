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
 * layer - they take the whole `StarEmitCtx` and read seven of its fifteen
 * fields, where a layer takes a narrow bundle and answers to several
 * unrelated callers. `WriterStarEmitLowering` was 1957 lines against the
 * 2000-line `oversized-type` cap when they left.
 *
 * ⚠️ Star emission FORKS across FOUR sites - `StarFieldLowering.emitStarFieldSteps`
 * and the `lowerStar*Branch` leaves beside it on the parse side,
 * `emitWriterStarField` (struct field) and `lowerEnumStar` (enum ctor) on the
 * writer side. All four stayed where they were. Nothing here is reachable from
 * `lowerEnumStar` - measured on the module's own call graph, the enum arm
 * reaches its trivia emit through `lowerEnumStarTrivia` and shares no member
 * with this one - so no fork half was separated from its twin. A change to
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
		if (starNode.hasMeta(':tryparse')) {
			emitTriviaTryparseStar(ctx, triviaCtx, parts);
			return;
		}
		if (closeText != null) {
			WriterTriviaStarDispatch.emitTriviaCloseStar(ctx.triviaStar, triviaCtx, parts);
		} else if (isLastField) {
			emitTriviaEofStar(ctx, triviaCtx, parts);
		} else {
			Context.fatalError('WriterLowering: @:trivia Star without @:trail must be the last field', Context.currentPos());
		}
	}

	/**
	 * Trivia `@:tryparse` Star dispatch (the `if (starNode.hasMeta(':tryparse'))`
	 * branch of `emitWriterStarField`). Reads the per-construct `@:fmt` flags and
	 * sep-override switches, then pushes the `triviaTryparseStarExpr` emit onto
	 * `parts`. Extracted so the orchestrator stays under the complexity gate.
	 */
	@:access(anyparse.macro.TriviaTryparseLowering, anyparse.macro.WriterCtorBlankLowering)
	private static function emitTriviaTryparseStar(ctx: WriterStarEmitLowering.StarEmitCtx, c: TriviaStarCtx, parts: Array<Expr>): Void {
		// noqa: complexity
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final elemRefName: String = c.elemRefName;
		final isLastField: Bool = c.isLastField;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final prevBareRefBody: Null<PrevBodyInfo> = c.prevBareRefBody;
		final prevTrailFieldName: Null<String> = c.prevTrailFieldName;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		final trailBAAccess: Null<Expr> = c.trailBAAccess;
		if (closeText != null) Context.fatalError('WriterLowering: @:trivia + @:tryparse must not have @:trail', Context.currentPos());
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
		if (!isLastField && openText != null)
			Context.fatalError('WriterLowering: non-last @:trivia @:tryparse Star must be bare (no @:lead)', Context.currentPos());
		if (openText != null) parts.push(macro _dt($v{openText}));
		// sameLine-annotated Stars (catches against try body) emit
		// the separator before EVERY element — it's the boundary
		// with the preceding struct field. Non-sameLine Stars
		// (case / default bodies) emit it only between elements,
		// matching the plain-mode tryparse writer.
		final sameLineName: Null<String> = starNode.fmtReadString('sameLine');
		final sepExpr: Expr = if (sameLineName != null) {
			final optFlag: Expr = optFieldAccess(sameLineName);
			sameLinePolicySwitch(optFlag, macro _dt(' '));
		} else {
			macro _dt(' ');
		};
		final nestBody: Bool = starNode.fmtHasFlag('nestBody');
		// ω-cond-comp-branch-trail: conditional branch bodies (`@:fmt(padTrailing)`
		// tryparse Stars) also carry orphan trailing trivia before `#end`/`#else`
		// (the parser captures it on element-parse failure, same as nestBody). The
		// slots stay empty for every other padTrailing Star, so the emit is
		// byte-inert until the parser writes them.
		final branchTrail: Bool = starNode.fmtHasFlag('padTrailing');
		// Trailing slots carry orphan trivia when nestBody (case/default bodies)
		// or padTrailing (conditional branch bodies) is on — the parser gates
		// capture on the same flags. Otherwise zero; forward null to keep the
		// writer path byte-identical.
		final tryparseTrailBB: Null<Expr> = nestBody || branchTrail ? trailBBAccess : null;
		final tryparseTrailLC: Null<Expr> = nestBody || branchTrail ? trailLCAccess : null;
		final tryparseTrailBA: Null<Expr> = nestBody ? trailBAAccess : null;
		// ω-close-trailing-alt: when prev field was a bare-Ref to a
		// trivia-bearing type whose Alt has close-trailing branches
		// (currently `HxStatement.BlockStmt`), build a runtime
		// override on the FIRST element's separator. `BlockStmt(_, ct)`
		// with `ct != null` means the body's writer already
		// terminated its output with `\n` after the trailing line
		// comment — the normal space sep would leak ` ` between the
		// indent and the next sibling (e.g. `catch`). The override
		// emits `_de()` instead; non-matching ctors fall through.
		final sepOverrides: TryparseSepOverrides = buildTryparseSepOverrides(
			ctx, starNode, sameLineName, prevBareRefBody, elemRefName, sepExpr
		);
		final firstSepOverride: Null<Expr> = sepOverrides.firstSepOverride;
		final subsequentSepOverride: Null<Expr> = sepOverrides.subsequentSepOverride;
		// ω-case-body-policy / ω-case-body-keep:
		// `@:fmt(bodyPolicy('flag1', 'flag2', ...))` on a
		// `nestBody` Star opts the body field into runtime
		// single-stmt-flat emission. The runtime ORs all named
		// `BodyPolicy` flags across two predicates:
		//  - ANY flag == `Same` → flatten unconditionally (override).
		//  - ANY flag == `Keep` → flatten IFF the source had the
		//    body's first element on the same line as the lead
		//    (read off `Trivial<T>.newlineBefore`).
		// Either path gates on the body holding exactly one element
		// with no leading / orphan-trailing trivia; multi-stmt and
		// trivia-bearing bodies stay multiline. Consumed by
		// `HxCaseBranch.body` and `HxDefaultBranch.stmts` to
		// switch between `case X:\n\tstmt;` (Next) and
		// `case X: stmt;` (Same / Keep+sameLine).
		final caseBodyFlagNames: Array<String> = starNode.fmtReadStringArgs('bodyPolicy') ?? [];
		// ω-expression-case-flat-fanout: when `@:fmt(flatChildOpt('A=B', …))`
		// is present, parse each `'from=to'` arg into a [from, to] pair so
		// `triviaTryparseStarExpr` can emit a `Reflect.copy(opt)` + per-pair
		// override block in the runtime flat-case branch.
		final flatChildOptRaw: Null<Array<String>> = starNode.fmtReadStringArgs('flatChildOpt');
		final flatChildOptPairs: Array<Array<String>> = if (flatChildOptRaw == null)
			[]
		else {
			final out: Array<Array<String>> = [];
			for (raw in flatChildOptRaw) {
				final eq: Int = raw.indexOf('=');
				if (eq <= 0 || eq >= raw.length - 1)
					Context.fatalError(
						'WriterLowering: @:fmt(flatChildOpt(...)) arg must be "from=to", got "${raw}"', Context.currentPos()
					);
				out.push([raw.substr(0, eq), raw.substr(eq + 1)]);
			}
			out;
		};
		// ω-cond-mod-pad: `@:fmt(padLeading)`/`@:fmt(padTrailing)` on
		// a `@:trivia @:tryparse` Star emit a leading/trailing space
		// when non-empty (matches the non-trivia padLeading/padTrailing
		// branch), with the leading slot SWITCHING to `_dhl()` when
		// the source had a newline before the first element. Used by
		// `HxConditionalMod.body` so V1–V3 (single-line `#if X mods #end`)
		// stay on one line and V4 (newline-separated cond/mods/`#end`)
		// breaks all three pad slots together — the trail-side pad
		// follows the leading-side decision because the parser does
		// not capture a body→`#end` newline slot, but in legal source
		// shapes the two newlines are correlated.
		// ω-splice-op-fill: `@:fmt(fillItems)` hands the gap BEFORE the first
		// element to the enclosing struct's `@:fmt(fillParts)` run, so the
		// Star's own leading pad must not fire in trivia mode — including on
		// the comment fallback, which emits the ordinary Star body and would
		// otherwise spend a second separator on the same gap (`#if flash  'b'`,
		// measured). The PLAIN writer keeps the pad: it has no fill to take
		// the gap from it.
		final tryparsePadLeading: Bool = starNode.fmtHasFlag('padLeading') && !starNode.fmtHasFlag('fillItems');
		final tryparsePadTrailing: Bool = starNode.fmtHasFlag('padTrailing');
		// ω-cond-indent-policy: `@:fmt(conditionalBodyIndent)` on a
		// `@:trivia @:tryparse` cond-comp body / elseBody / elseif-body
		// Star opts the body content into the runtime
		// `opt.conditionalPolicy` indent rule. When the policy is
		// `AlignedIncrease`, the body content (leading pad hardline +
		// each body element) is wrapped in `_dn(_cols, …)` so it sits
		// one level deeper than the `#if`/`#else`/`#end` markers, while
		// the trailing pad hardline (the `\n` before `#else`/`#end`)
		// is emitted OUTSIDE the nest so the close marker stays at the
		// surrounding statement indent. Nesting accumulates per
		// conditional depth (a nested `#if` body re-enters the same
		// `_dn`). DEFAULT `Aligned` → the runtime gate is false → the
		// pre-policy `else` branch fires → byte-identical. Only the
		// cond-comp body Stars carry this flag, so every other tryparse
		// Star consumer is untouched.
		final tryparseCondBodyIndent: Bool = starNode.fmtHasFlag('conditionalBodyIndent');
		// ω-issue-423-mech-a: `@:fmt(propagateExprPosition)` on a
		// `@:trivia @:tryparse` Star marks the body as an expression-
		// position frame for descendants. The runtime block emits an
		// always-copy of `opt` with `_inExprPosition = true` set, so
		// the dual-flag `bodyPolicy('A','B')` flat-gate in nested
		// case-body sites picks the expression-position policy
		// (`expressionCase`) instead of the statement-position one
		// (`caseBody`). Mirrors fork's `isReturnExpression` walk-up
		// heuristic — currently wired only by `HxCaseBranch.body` /
		// `HxDefaultBranch.stmts` so a case nested in another case's
		// body inherits expression context.
		final propagateExprPosition: Bool = starNode.fmtHasFlag('propagateExprPosition');
		// ω-value-yielded-if-tail-barrier (case-body extension of SI-2):
		// `@:fmt(clearExprPositionNonTail)` on a case / default body Star
		// (paired with `propagateExprPosition`) clears `_inExprPosition`
		// for every NON-tail body statement, so a discarded statement-if
		// reverts to the statement-position `ifBody` policy while the
		// body's yielded tail keeps the expression frame. False → byte-
		// identical (every other tryparse-Star consumer is untouched).
		final clearExprPositionNonTail: Bool = starNode.fmtHasFlag('clearExprPositionNonTail');
		// ω-issue-423-mech-b: `@:fmt(refuseFlatOnComplexExpr)` AND-s the
		// runtime `_flatCase` gate with the generated typed
		// `caseBodyRefusesFlat` predicate of the build's AST family
		// (addressed by naming convention — the engine never references
		// the grammar plugin by name; a grammar carrying the meta must
		// provide the marker classes). Wired on `HxCaseBranch.body` /
		// `HxDefaultBranch.stmts` to mirror fork's
		// `MarkSameLine.markExpressionCase` body-shape check.
		final refuseFlatOnComplex: Bool = starNode.fmtHasFlag('refuseFlatOnComplexExpr');
		// omega-case-body-controlflow-glue: `@:fmt(refuseGlueOnControlFlowRoot)`
		// tells the `FitLine` case-body path to REFUSE the glue outcome when
		// the body's single statement is keyword-led control flow (the
		// generated `caseBodyControlFlowRoot` predicate of the build's AST
		// family). Such a construct's continuation lines are siblings of its
		// head, so glued they render at the head's indent, which under
		// `alignInlineSwitchCaseBody` is the LABEL's. Wired on
		// `HxCaseBranch.body` / `HxDefaultBranch.stmts` alongside
		// `refuseFlatOnComplexExpr`.
		//
		// The SAME meta gates the accompanying sibling FORCE in the case-LIST
		// Star's pre-pass - `caseSiblingControlFlowFnExpr` reads it back off this
		// body Star through `elemBodyStarHasFlag`, so the two halves cannot be
		// enabled apart. Flag off => byte-identical on BOTH.
		final refuseGlueOnControlFlow: Bool = starNode.fmtHasFlag('refuseGlueOnControlFlowRoot');
		// ω-metadata-line-end-function: `@:fmt(metaLineEndPolicy('<optField>'))`
		// on a `@:trivia @:tryparse` Star wires inter-element + post-Star
		// separator dispatch through `opt.<optField>:MetadataLineEndPolicy`.
		// Default `None` (and absent flag) is byte-identical to pre-slice.
		final metaLineEndOptField: Null<String> = starNode.fmtReadString('metaLineEndPolicy');
		// ω-bug-2c-inner-star — read the same cascade `@:fmt(blankLines*)`
		// metas that the EOF-Star branch reads, so an inner Star (e.g.
		// `HxConditionalDecl.body`) opted in via the metas drives the
		// blank-line cascade between its sibling elements.
		final cascadeInfos: CascadeInfos = WriterCtorBlankLowering.readCascadeInfosFromStar(ctx.ctorBlank, starNode, elemRefName);
		// ω-trivia-tryparse-linelength: when the Star carries
		// `@:fmt(lineLengthAwareSeps)`, swap inter-element + padLeading
		// hard spaces for `_dile` probes + wrap in `_dn(_cols, ...)`.
		// Sister to the non-trivia bare-Star `padLeading||padTrailing`
		// branch's lineLengthAware path.
		final tryparseLineLengthAware: Bool = starNode.fmtHasFlag('lineLengthAwareSeps');
		// B4 ω-implements-extends-wrap: `@:fmt(heritageWrap)` on a
		// `@:trivia @:tryparse` Star (HxClassDecl.heritage /
		// HxInterfaceDecl.heritage) routes a MULTI-clause heritage list
		// (`extends A implements B …`) through the fork's
		// `wrapping.implementsExtends` FillLine layout: when the full
		// glued decl line is long, pack clauses from the front and break
		// the overflow clause(s) at additionalIndent 2 (8 spaces). The
		// single-clause path stays on the existing `lineLengthAwareSeps`
		// 1-tab break-before-keyword (matches fork single-clause +
		// `extends_break_before_keyword_not_type_params`). Abstract
		// `clauses` (from/to) never carries this flag — its
		// `lineLengthAwareSeps` behaviour is untouched.
		final tryparseHeritageWrap: Bool = starNode.fmtHasFlag('heritageWrap');
		// ω-slice-45 / issue_626: `@:fmt(forceInlineSep)` on a `@:trivia
		// @:tryparse` Star collapses every source linebreak between
		// consecutive elements to a single space. First consumers are
		// the modifier Stars on `HxMemberDecl.modifiers` and
		// `HxTopLevelDecl.modifiers` so multi-line `static\n\toverload`
		// round-trips as `static overload`. Comment trivia between
		// elements is out of scope — flag's contract is "treat
		// inter-element whitespace trivia as one space".
		final tryparseForceInlineSep: Bool = starNode.fmtHasFlag('forceInlineSep');
		// ω-cond-comp-elseif-double-newline: set on the cond-comp `elseifs`
		// Stars (HxConditional*.elseifs) whose HxElseif* elements self-terminate
		// with a padTrailing newline. See triviaTryparseStarExpr's
		// elemSelfTrailsNewline param.
		final tryparseElemSelfTrailsNewline: Bool = starNode.fmtHasFlag('elemSelfTrailsNewline');
		// ω-typedef-intersection-operand-break: `@:fmt(
		// operandBreakAfterMultilineBrace)` on a `@:trivia @:tryparse`
		// Star makes each element whose PRECEDING element rendered
		// multi-line and ended with a close brace receive a per-element
		// opt copy with `_intersectionOperandBreak = true`. Consumer:
		// `HxTypedefDecl.intersections` (the `& Type` clause Star).
		final tryparseOperandBreakAfterMultilineBrace: Bool = starNode.fmtHasFlag('operandBreakAfterMultilineBrace');
		// ω-trivia-tryparse-prior-after-trail: when the PREV sibling
		// field has a synthesised `<priorField>AfterTrail:Null<String>`
		// slot (mandatory Ref with `@:trail` in trivia-bearing mode),
		// thread its access so the Star can inline-emit the captured
		// trail-of-prev-field comment cuddled to the prev token.
		final tryparsePriorAfterTrailExpr: Null<Expr> = prevTrailFieldName == null ? null : {
			expr: EField(macro value, prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-blockended-trivia-tryparse (Session 3): thread the Star's
		// `@:sep('text', tailRelax, blockEnded)` annotation into
		// `triviaTryparseStarExpr` so the helper can inject `;`
		// between two non-`}`-ending elements. Non-blockEnded
		// tryparse Stars (every existing consumer) pass null sepText
		// and the helper splices a no-op.
		final tryparseSepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final tryparseBlockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		final tryparseSepFaithful: Bool = starNode.annotations['lit.sepFaithful'] == true;
		// ω-sep-faithful: re-emit a source-captured LEADING sep
		// (`#if X, elem #end`) from the `<field>SepBefore` slot — the trivia
		// twin of the plain path's sepBeforeOptActive pad swap.
		final tryparseSepBeforeAccess: Null<Expr> = tryparseSepFaithful && starNode.fmtHasFlag('sepBeforeOpt')
			? switch fieldAccess.expr {
				case EField(b, n): { expr: EField(b, '${n}SepBefore'), pos: fieldAccess.pos };
				case _: null;
			}
			: null;
		// Typed nested-conditional element probe (alignedNestedIncrease
		// span lift + blockEnded sep suppression): built HERE, where the
		// Star's element rule is known, as the mode-family
		// `elementIsConditional_<ElemRule>` fn-ref. Built only for the
		// Stars whose emission paths can consult it (conditionalBodyIndent
		// / blockEnded) — the grammar generates the per-rule variants for
		// exactly those element rules. Formats without generated
		// predicates pass null and both consumer sites emit their inert
		// `false`.
		final tryparseElemCondFn: Null<Expr> = ctx.formatInfo.astPreds && (tryparseCondBodyIndent || tryparseBlockEnded)
			? AstPredLowering.predFnExpr(ctx.shape.root, true, false, 'elementIsConditional_${simpleName(c.elemRefName)}')
			: null;
		// omega-cond-expr-fit: `@:fmt(condExprFitBreak)` on the tryparse Star
		// (the expression-scope cond-comp `elseifs`) swaps its inter-element
		// and trailing-pad spaces for knob-gated soft `Line(' ')` seps.
		final tryparseCondExprFit: Bool = starNode.fmtHasFlag('condExprFitBreak');
		// ω-splice-op-fill: `@:fmt(fillItems)` routes the Star to the fill
		// bypass — soft `Line(' ')` between elements, no pad, source newlines
		// ignored. Sole consumer: `HxCondSpliceOpExpr.terms`.
		final tryparseFillItems: Bool = starNode.fmtHasFlag('fillItems');
		parts.push(TriviaTryparseLowering.triviaTryparseStarExpr(
			tryCatchesSymmetryWrap(ctx.braceSym, starNode, fieldAccess, elemRefName), elemFn, sepExpr, sameLineName != null, nestBody,
			tryparseTrailBB, tryparseTrailLC, tryparseTrailBA, firstSepOverride, subsequentSepOverride, caseBodyFlagNames,
			flatChildOptPairs, tryparsePadLeading, tryparsePadTrailing, propagateExprPosition, refuseFlatOnComplex,
			cascadeInfos.afterCtorInfos, cascadeInfos.beforeCtorInfos, cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos,
			cascadeInfos.headCtorInfos, metaLineEndOptField, cascadeInfos.betweenSameCtorIfNotInfos, tryparseLineLengthAware,
			tryparsePriorAfterTrailExpr, tryparseForceInlineSep, tryparseBlockEnded || tryparseSepFaithful ? tryparseSepText : null,
			tryparseBlockEnded, tryparseSepFaithful, tryparseHeritageWrap, tryparseCondBodyIndent, tryparseOperandBreakAfterMultilineBrace,
			clearExprPositionNonTail, tryparseSepBeforeAccess, tryparseElemSelfTrailsNewline, tryparseCondExprFit, tryparseElemCondFn,
			refuseGlueOnControlFlow, tryparseFillItems
		));
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
		// `bareBodyBreaks` includes blockShape opt-in ctors (e.g.
		// `UntypedBlockStmt`) — they end with `}` and should be
		// treated as block for the catch-separator decision while
		// staying non-block in `bodyPolicyWrap`'s strict block-ctor
		// override path.
		final blockPatterns: Array<Expr> = sameLineName != null && prevBareRefBody != null && shapeAware
			? (
				bareShapeAware
					? collectBlockShapeEquivalentPatterns(ctx.ctorPat, prevBareRefBody.typePath)
					: collectBlockCtorPatterns(ctx.ctorPat, prevBareRefBody.typePath)
			)
			: [];
		final elemBodyField: Null<String> = sameLineName != null && blockPatterns.length > 0
			? findElementBodyField(ctx.ctorPat, elemRefName, prevBareRefBody.typePath)
			: null;
		final blockKeepsInlineBranch: Expr = blockBodyKeepsInlineBranch(starNode);
		final firstSepOverride: Null<Expr> = if (blockPatterns.length == 0)
			closeTrailingFirstOverride;
		else {
			final fallback: Expr = closeTrailingFirstOverride ?? sepExpr;
			final blockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : fallback;
			final bareBranch: Expr = blockShapeAware ? fallback : bareSepBreak(barePolicyFields[0], sepExpr, softSeam);
			final cases: Array<Case> = [
				{ values: blockPatterns, expr: blockBranch, guard: null },
				{ values: [macro _], expr: bareBranch, guard: null }
			];
			{ expr: ESwitch(prevBareRefBody.access, cases, null), pos: Context.currentPos() };
		};
		final subsequentSepOverride: Null<Expr> = if (elemBodyField == null)
			null;
		else {
			final prevElemBodyAccess: Expr = {
				expr: EField(macro _arr[_si - 1].node, elemBodyField),
				pos: Context.currentPos()
			};
			final blockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
			final bareBranch: Expr = blockShapeAware ? sepExpr : bareSepBreak(barePolicyFields[1], sepExpr, softSeam);
			final cases: Array<Case> = [
				{ values: blockPatterns, expr: blockBranch, guard: null },
				{ values: [macro _], expr: bareBranch, guard: null }
			];
			{ expr: ESwitch(prevElemBodyAccess, cases, null), pos: Context.currentPos() };
		};
		return { firstSepOverride: firstSepOverride, subsequentSepOverride: subsequentSepOverride };
	}

	/**
	 * ω-close-trailing-alt — runtime override for a Star's first-element
	 * separator when the immediately preceding struct field was a bare
	 * Ref to a trivia-bearing type. Iterates the prev body's Alt branches
	 * looking for close-trailing branches (Star + `@:trail` + `@:trivia`)
	 * — currently only `HxStatement.BlockStmt`. For each, emits a case
	 * `BlockStmt(_, _ct)` with guard `_ct != null` mapping to `_de()`
	 * (the body's writer already terminated with `\n`, so any sep would
	 * leak ` ` between the indent and the next sibling). The default
	 * case falls through to `sepExpr`. Returns `null` when no override
	 * is needed (no prev body, non-bearing target, or no close-trailing
	 * branches in the Alt) so the caller skips the override path.
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
			final pattern: Expr = {
				expr: ECall(ctorRef, patternArgs),
				pos: Context.currentPos()
			};
			cases.push({ values: [pattern], guard: macro _ct != null, expr: macro _de() });
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

}
#end
