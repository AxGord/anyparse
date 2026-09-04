package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.WriterCascadeLowering.*;
import anyparse.macro.WriterPolicyLowering.*;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.MacroNames.*;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W helpers - the close-peek trivia Star dispatch and its per-element
 * readers.
 *
 * A `@:trivia` Star whose end is found by peeking for the CLOSE delimiter
 * has two emit shapes - separated (`@:sep`) and block - and one member here
 * chooses between them: `emitTriviaCloseStar` hands off to
 * `TriviaSepLowering` or, through `emitTriviaBlockStarDispatch`, to
 * `TriviaBlockLowering`. Everything else in the module is what those two
 * calls need ASSEMBLED first: the per-element `@:fmt` predicate function
 * expressions (`casePredFnExpr` and the three `caseSibling*` shapes), the
 * inter-member classifier, the static-var subdivision INFO and its
 * validation, and the three `*StarHasFlag` readers.
 *
 * Split out of `WriterLowering` for size. One member there enters, through
 * `emitTriviaStar`.
 *
 * Every member is static and the build state arrives as one
 * `TriviaStarDispatchCtx` bundle, built once in `WriterLowering`'s
 * constructor - two data fields and two format probes, which is the whole
 * of what a dispatch layer needs.
 *
 * ⚠️ Star emission FORKS across four sites and this module is next to two of
 * them - see the project note behind `emitWriterStarField` (struct field)
 * and `lowerEnumStar` (enum ctor), both of which stayed in
 * `WriterLowering`. Nothing here is one of those four: the two entries are
 * a trivia-mode dispatch, the same class of site as `triviaSepStarExpr` and
 * `triviaBlockStarExpr`, which already live in their own modules.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterCascadeLowering, anyparse.macro.WriterLoweringSupport,
	anyparse.macro.WriterPolicyLowering)
final class WriterTriviaStarDispatch {

	/**
	 * Trivia close-peek (`@:trail`) Star dispatch (the `if (closeText != null)`
	 * branch of the `isTriviaStar` block in `emitWriterStarField`). Emits the
	 * leftCurly separator, routes a flat-sep Star through `triviaSepStarExpr`, else
	 * falls through to `emitTriviaBlockStarDispatch`. Extracted to keep the
	 * orchestrator under the complexity gate.
	 */
	@:access(anyparse.macro.TriviaSepLowering)
	private static function emitTriviaCloseStar(tc: TriviaStarDispatchCtx, c: WriterLowering.TriviaStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final isFirstField: Bool = c.isFirstField;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailNLAccess: Null<Expr> = c.trailNLAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		final trailCloseAccess: Null<Expr> = c.trailCloseAccess;
		final trailOpenAccess: Null<Expr> = c.trailOpenAccess;
		final trailPresentAccess: Null<Expr> = c.trailPresentAccess;
		// First-field Star with knob-form `@:fmt(leftCurly('<knob>'))`
		// (e.g. `HxObjectLit.fields`) fires the leftCurly switch
		// even at first-field position — its outer caller already
		// emits the inter-token space via `_dop(' ')`, so the
		// `Same` branch is `_de()` and `Next` is `_dhl()` (drops
		// the pending OptSpace and writes a hardline).
		final knobLeftCurly: Null<String> = starNode.fmtReadString('leftCurly');
		final hasKnobLeftCurly: Bool = knobLeftCurly != null;
		// ω-objectlit-leftCurly-cascade: when the Star carries BOTH
		// `@:fmt(wrapRules(...))` AND `@:fmt(leftCurly('<knob>'))`,
		// leftCurly emission moves INSIDE `triviaSepStarExpr` so the
		// no-trivia branch can wire `IfBreak(_dhl(), _de())` into the
		// wrap engine's Group — short literals stay cuddled even when
		// the knob is `Next`. Trivia-bearing branch keeps the
		// pre-slice unconditional `_dhl()`/`_de()`. Outer site keeps
		// emitting `leftCurlySeparator` for the no-wrap-rules case
		// (legacy bare-flag callers and future knob-form callers
		// without wrap-rules).
		final wrapRulesField: Null<String> = starNode.fmtReadString('wrapRules');
		final leftCurlyOwnedBySep: Bool = hasKnobLeftCurly && wrapRulesField != null;
		// Head -> body seam: a close-peek Star opens the construct's body
		// (`HxSwitchStmt.cases`), and when the preceding sibling is a Ref
		// with `@:trail` its `<field>AfterTrail` slot holds the same-line
		// comment cuddled to that closer (`switch (v) // c` + newline `{`).
		// Only the tryparse-Star path consumed that slot, so here the
		// comment was captured and then dropped. Emitting it guarded turns
		// the following `leftCurlySeparator` default (`_dossh`, drops after
		// a hardline) into the Allman `{` placement the comment forces.
		if (c.prevTrailFieldName != null) {
			final afterTrailAccess: Expr = {
				expr: EField(macro value, c.prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX),
				pos: Context.currentPos()
			};
			parts.push(macro {
				final _atSeam: Null<String> = $afterTrailAccess;
				_atSeam != null ? trailingCommentDocGuarded(_atSeam, opt) : _de();
			});
		}
		if (!leftCurlyOwnedBySep && (!isFirstField || hasKnobLeftCurly) && tc.isSpacedLead(openText))
			parts.push(leftCurlySeparator(starNode, isFirstField && hasKnobLeftCurly));
		// ω-trivia-sep: sep-Star with @:trivia routes to a
		// dedicated helper that drives multi-line vs flat layout
		// from per-element `newlineBefore` / comment trivia.
		//
		// ω-wraprules-objlit: when the Star carries
		// `@:fmt(wrapRules('<field>'))`, the no-trivia branch of
		// `triviaSepStarExpr` defers to the runtime
		// `WrapList.emit` engine so the cascade picks the layout
		// shape (NoWrap / OnePerLine / FillLine / …). The
		// trivia-bearing branch still forces multi-line — when
		// inline / leading / trailing comments are present, the
		// list cannot collapse to a single line regardless of
		// what the cascade would say.
		// ω-blockended-trivia (Session 3): `@:sep('text', tailRelax,
		// blockEnded)` on a block-mode trivia Star (HxFnBlock.stmts
		// / HxBlockExpr.stmts / HxBlockStmt.stmts) keeps the
		// per-element hardlined block layout — sep emit moves
		// INSIDE `triviaBlockStarExpr` (extended), NOT through the
		// flat-or-multi `triviaSepStarExpr`. Detect the flag here
		// and skip the sep dispatch so the fall-through reaches
		// the block dispatch with sepText/blockEnded threaded.
		final blockEndedFlag: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		if (sepText != null && !blockEndedFlag) {
			// ω-cascade-emits-comments: emit the funcParamParens /
			// typeParamOpen space inside the @:trivia + sep
			// dispatch — the @:trivia path returns BEFORE the
			// no-trivia branch at `:3504-3510` that owns the
			// equivalent emit, so without this mirror the
			// `function foo ()` space (and sister knobs) is
			// silently dropped when the Star becomes @:trivia.
			// First-field Stars skip (matches the no-trivia path's
			// `!isFirstField` gate).
			if (!isFirstField) {
				final triviaParamSpace: Null<Expr> = openDelimPolicySpace(starNode, ['funcParamParens', 'typeParamOpen']);
				if (triviaParamSpace != null) parts.push(triviaParamSpace);
			}
			// ω-objectlit-source-trail-comma: when the Star also
			// carries `@:fmt(trailingComma('<knob>'))`, thread the
			// knob's field name into `triviaSepStarExpr` so its
			// no-trivia branch can `forceExceeds` on the wrap engine
			// when the source had a trailing separator AND the knob
			// is on. Null knob → behaves identically to pre-slice
			// (cascade evaluates exceeds=false / =true symmetrically).
			final trailingCommaField: Null<String> = starNode.fmtReadString('trailingComma');
			// ω-objectlit-right-curly: struct-Star path now threads
			// `@:fmt(rightCurly('<knob>'))` (e.g.
			// `rightCurly('objectLiteralRightCurly')` on
			// `HxObjectLit.fields`) into `triviaSepStarExpr`'s 12th
			// param. Null (no opt-in) preserves pre-slice
			// unconditional `_dhl()` before close.
			final knobRightCurly: Null<String> = starNode.fmtReadString('rightCurly');
			// ω-typedef-anon-force-multi: when the sep-Star carries
			// `@:fmt(forceMultiInTypedef)` (currently only
			// `HxType.Anon.fields`), thread the flag into
			// `triviaSepStarExpr` so its no-trivia branch emits a
			// runtime `opt._inTypedefBody ? WrapMode.OnePerLine :
			// null` as `WrapList.emit`'s `forceMode` option.
			// Bypasses the cascade only when the typedef-RHS
			// context is active — non-typedef anon consumers
			// (var-type-hint, fn-return-type) stay cascade-driven.
			final forceMultiTypedef: Bool = starNode.fmtHasFlag('forceMultiInTypedef');
			final bodyAware: Bool = starNode.fmtHasFlag('bodyAwareCompactIndent');
			// ω-group-rest-probe slice 2: struct-Star path reader for
			// `@:fmt(groupRestProbe)`. Mirrors the lowerStruct plain-
			// path read (added at the lowerStruct dispatch site).
			// Trivia-path dual-dispatch closure per
			// [[feedback-wraprules-dispatch-dual-path]].
			final groupRestProbe: Bool = starNode.fmtHasFlag('groupRestProbe');
			// ω-cascade-emits-comments: struct-Star path reader for
			// `@:fmt(ignoreSourceNewlinesForWrap)`. Intrinsic
			// per-construct opt-in to fork's `Ignore` semantic —
			// drops `Trivial<T>.newlineBefore` signal, routes
			// per-element block-trailing + leading comments
			// through the cascade no-trivia branch. Currently
			// `HxFnDecl.params`.
			final ignoreSourceNewlines: Bool = starNode.fmtHasFlag('ignoreSourceNewlinesForWrap');
			// ω-array-reflow: struct-Star path reader for
			// `@:fmt(reflowSourceMultiline)`. Sister to the enum-Alt
			// read; threads into `triviaSepStarExpr`'s `_smlKeep`
			// gate. No struct-Star consumer opts in yet (first
			// consumer `HxExpr.ArrayExpr` is enum-Alt) — present for
			// dual-dispatch symmetry.
			final reflowSourceMultilineStar: Bool = starNode.fmtHasFlag('reflowSourceMultiline');
			// ω-arraymatrix-wrap: struct-Star path reader for
			// `@:fmt(arrayMatrixWrap)`. Sister to the enum-Alt read;
			// no struct-Star consumer opts in yet (first consumer
			// `HxExpr.ArrayExpr` is enum-Alt) — present for dual-
			// dispatch symmetry. `bracketKindPad` is not read on this
			// path (passed false) so matrix slots in after it.
			final matrixWrapStar: Bool = starNode.fmtHasFlag('arrayMatrixWrap');
			// ω-expressionif-collapse (mechanism A): the struct-Star
			// trivia path must not pass literal `null, null` for
			// the inside-of-delimiter spacing slots — else a Star carrying
			// `@:fmt(objectLiteralBracesOpen, objectLiteralBracesClose)`
			// (HxObjectLit.fields) gets no `{ x }` padding. Read
			// the policy Doc the same way the plain `@:sep` path
			// (~5560) and the enum-Alt path (~2363) do —
			// `delimInsidePolicySpace` returns null when no delim
			// policy flag is present, so every other struct-Star stays
			// byte-identical.
			final openInsideStar: Null<Expr> = delimInsidePolicySpace(starNode, ['typeParamOpen', 'objectLiteralBracesOpen'], false);
			final closeInsideStar: Null<Expr> = delimInsidePolicySpace(starNode, ['typeParamClose', 'objectLiteralBracesClose'], true);
			// ω-expressionif-collapse (mechanism B read-site):
			// `@:fmt(reflowInExprPosition)` (HxObjectLit.fields) opts
			// the Star into source-newline ignore — but only at runtime
			// when `opt._inValueIfBranch` is set (the immediate value of
			// a value-if branch). Default false → byte-inert.
			final reflowInExprBranchStar: Bool = starNode.fmtHasFlag('reflowInExprPosition');
			// ω-multiline-trailing-comma-remove / ω-uniform-element-blanks:
			// struct-Star path readers. `trailingCommaRemovable` is live here
			// (`HxObjectLit.fields`, `HxNewExpr.args`); `uniformStmtBlanks` has
			// no struct-Star consumer yet (first consumer `HxExpr.ArrayExpr` is
			// enum-Alt) — read for dual-dispatch symmetry.
			final trailingCommaRemovableStar: Bool = starNode.fmtHasFlag('trailingCommaRemovable');
			final uniformStmtBlanksStar: Bool = starNode.fmtHasFlag('uniformStmtBlanks');
			// ω-complex-item-count: struct-Star path reader for
			// `@:fmt(complexItems)` — the per-element AST classification behind
			// the `complexItemCount >= n` cascade condition and the fill-mode
			// chunk policy. Live here for `HxNewExpr.args`; the array literal
			// opts in through the enum-Alt reader.
			final complexItemsStar: Bool = starNode.fmtHasFlag('complexItems');
			// ω-mapwrap: struct-Star reader, dual-dispatch twin of the enum-Alt
			// one in `triviaSepStarBuild`. This is the OTHER trivia sep-Star
			// entry point, and it is the only other one: the two plain-path
			// `wrapRules` sites build their own `WrapList.emit` call and never
			// reach `triviaSepStarExpr`, so a Star naming a map cascade there
			// would be ignored — but no Star can, since `@:trivia` is what routes
			// a sep-Star here and `HxExpr.ArrayExpr` carries it.
			//
			// No struct-Star names a map cascade today, so this reads null and the
			// emitted call is byte-identical. It is wired rather than hardcoded
			// null because the read alone is what the next Star to carry the meta
			// on this path will need. Such a Star would also have to hold `HxExpr`
			// elements — `mapWrapFor` hands `_arr[0].node` to a predicate whose
			// parameter is `Null<HxExpr>`, so a Star of anything else is a
			// macro-time type error rather than a silent misclassification.
			final mapWrapStar: Null<WriterLowering.SepStarMapWrap> = tc.mapWrapFor(starNode.fmtReadString('mapWrapRules'));
			parts.push(TriviaSepLowering.triviaSepStarExpr(
				fieldAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn, openText ?? '', closeText, sepText,
				wrapRulesField, leftCurlyOwnedBySep ? knobLeftCurly : null, knobRightCurly, trailPresentAccess, trailingCommaField,
				openInsideStar, closeInsideStar, false, forceMultiTypedef, bodyAware, groupRestProbe, ignoreSourceNewlines,
				reflowSourceMultilineStar, matrixWrapStar, trailNLAccess, false, false, reflowInExprBranchStar, trailingCommaRemovableStar,
				uniformStmtBlanksStar, complexItemsStar, mapWrapStar
			));
			return;
		}
		emitTriviaBlockStarDispatch(tc, c, parts);
	}

	/**
	 * Trivia block-mode (`@:trail`, no flat sep) Star dispatch — the fall-through
	 * tail of `emitTriviaCloseStar` after the sep dispatch returns. Reads the
	 * block-layout `@:fmt` flags and pushes the `triviaBlockStarExpr` emit onto
	 * `parts`. Extracted to keep the helper under the complexity gate.
	 */
	@:access(anyparse.macro.TriviaBlockLowering)
	private static function emitTriviaBlockStarDispatch(
		tc: TriviaStarDispatchCtx, c: WriterLowering.TriviaStarCtx, parts: Array<Expr>
	): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final elemRefName: String = c.elemRefName;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		final trailCloseAccess: Null<Expr> = c.trailCloseAccess;
		final trailOpenAccess: Null<Expr> = c.trailOpenAccess;
		final blockEndedFlag: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		// `openText ?? ''` (was `?? '{'` through ω₅) — when a
		// close-peek Star has no `@:lead`, the surrounding Seq
		// emits the open delimiter before this field, so the Star
		// itself contributes nothing at the open position. Empty
		// string → `_dt('')` is a no-op, and `emptyText = '' +
		// closeText` stays format-neutral (invariant #5).
		final afterDocComments: Bool = starNode.fmtHasFlag('afterFieldsWithDocComments');
		final keepBetweenFields: Bool = starNode.fmtHasFlag('existingBetweenFields');
		final beforeDocComments: Bool = starNode.fmtHasFlag('beforeDocCommentEmptyLines');
		final indentCaseLabelsGate: Bool = starNode.fmtHasFlag('indentCaseLabels');
		final emptyCurlyBreak: Bool = starNode.fmtHasFlag('emptyCurlyBreak');
		// ω-blockempty: call-form `@:fmt(emptyCurlyBreak('<knob>'))`
		// names a per-construct EmptyCurly opt field. The bare form
		// returns null and falls back to `_inAnonFnBody` dispatch
		// inside `triviaBlockStarExpr`.
		final emptyCurlyKnob: Null<String> = fmtFirstStringArg(starNode, 'emptyCurlyBreak');
		final beginEndType: Bool = starNode.fmtHasFlag('beginEndType');
		// ω-enum-begin-end: `@:fmt(beginEndType('a', 'b'))` names the begin/end
		// opt knobs to read (default class-scoped `beginType` / `endType`), so
		// `HxEnumDecl.ctors` reads its own `enumBeginType` / `enumEndType`.
		final beginEndKnobArgs: Null<Array<String>> = starNode.fmtReadStringArgs('beginEndType');
		final beginTypeKnob: String = beginEndKnobArgs != null && beginEndKnobArgs.length >= 2 ? beginEndKnobArgs[0] : 'beginType';
		final endTypeKnob: String = beginEndKnobArgs != null && beginEndKnobArgs.length >= 2 ? beginEndKnobArgs[1] : 'endType';
		final keepCurlyBlanks: Bool = starNode.fmtHasFlag('keepCurlyBlanks');
		final lineCommentTrailBlank: Bool = starNode.fmtHasFlag('blankBeforeOrphanLineCommentTrail');
		final blankBeforeFinalDocInLeading: Bool = starNode.fmtHasFlag('blankBeforeFinalDocCommentInLeading');
		// ω-* classify-info builders resolved in buildTriviaBlockInfos.
		final infos: WriterLowering.TriviaBlockInfos = buildTriviaBlockInfos(tc, starNode, elemRefName, beforeDocComments);
		final interMemberInfo: Null<WriterLowering.InterMemberClassifyInfo> = infos.interMemberInfo;
		final staticVarSubdivInfo: Null<WriterLowering.StaticVarSubdivisionInfo> = infos.staticVarSubdivInfo;
		final condLeadingDocInfo: Null<WriterLowering.CondLeadingDocLookThroughInfo> = infos.condLeadingDocInfo;
		final betweenMultilineCommentsBlanks: Bool = starNode.fmtHasFlag('betweenMultilineCommentsBlanks');
		// ω-blank-around-multiline-members: `@:fmt(blankAroundMultilineMembers('<optField>'))`
		// names the `WriteOptions` Int knob holding the blank count. Absent → the
		// three splice points are `macro {}` and the loop generates byte-identical.
		final blankAroundOptField: Null<String> = fmtSingleStringArg(starNode, 'blankAroundMultilineMembers');
		final uniformBetweenOptField: Null<String> = fmtSingleStringArg(starNode, 'uniformBetween');
		final anonFnClear: Bool = starNode.fmtHasFlag('leftCurlyAnonFnOverride');
		// ω-blockright-curly: call-form `@:fmt(rightCurly('<knob>'))`
		// on a Seq-struct Star names a per-construct
		// RightCurlyPlacement opt field. Sister to `emptyCurlyKnob`
		// — when null, dispatch falls back to unconditional
		// `_dhl()` before close inside `triviaBlockStarExpr`.
		final rightCurlyKnob: Null<String> = fmtFirstStringArg(starNode, 'rightCurly');
		// ω-anonfunction-right-curly: call-form
		// `@:fmt(rightCurlyAnonFnOverride('<knob>'))` on a Seq-struct
		// Star names a RightCurlyPlacement opt field read only when
		// `_inAnonFnBody=true`. Used by `HxFnBlock.stmts` to route
		// anon-fn body closes through `opt.anonFunctionRightCurly`
		// while keeping `HxFnDecl.body` / `HxUntypedFnBody.block`
		// (same `HxFnBlock` Star, `_inAnonFnBody=false`) on the
		// pre-slice `_dhl()` path.
		final rightCurlyAnonFnKnob: Null<String> = fmtFirstStringArg(starNode, 'rightCurlyAnonFnOverride');
		// ω-anon-fn-body-stmt-position: HxFnExpr / HxFnDecl / HxUntypedFnBody
		// bodies share HxFnBlock.stmts; when it carries
		// @:fmt(clearExprPositionNonTail) (mirroring HxExpr.BlockExpr) the block
		// clears the leaked expression-position frame for its statements, so a
		// statement `if` in an anon-fn body inlines via `ifBody` instead of
		// `expressionIf`. Struct-block Stars without the flag stay byte-identical.
		final clearExprPositionNonTail: Bool = starNode.fmtHasFlag('clearExprPositionNonTail');
		// ω-uniform-statement-blanks: opt-in on statement-block Stars
		// (`HxExpr.BlockExpr.stmts`, `HxFnBlock.stmts`). Drives the
		// `_uniformCollapse` pre-pass + per-element blank suppression.
		final uniformStmtBlanks: Bool = starNode.fmtHasFlag('uniformStmtBlanks');
		// omega-condswitchopen-cases-nest: `HxCondSpliceSwitchOpen.cases` (the shared
		// switch case list of a `#if for { switch { #else ... #end` region) sits
		// TWO block levels below the enclosing statement - the region's outer
		// block AND the switch - but a block Star's body Doc carries only one
		// `_dn` level. This flag wraps the whole field emit in one extra
		// `_dn(_cols, ...)` so the case labels land at statement+2 and the
		// switch-closing `}` at statement+1, matching a physically-nested
		// `for (..) { switch (..) { case .. } }`. Byte-inert for every other
		// block Star (the flag is unique to that one field).
		final condSwitchOpenCasesNest: Bool = starNode.fmtHasFlag('condSwitchOpenCasesNest');
		final emptyBlockBreak: Bool = starNode.fmtHasFlag('emptyBlockBreak');
		final caseSymArgs: Null<Array<String>> = starNode.fmtReadStringArgs('caseSiblingSymmetry');
		final caseSiblingUnitsFn: Null<Expr> = caseSiblingUnitsFnExpr(tc, caseSymArgs, elemRefName);
		final caseSiblingStructuralFn: Null<Expr> = caseSiblingStructuralFnExpr(tc, caseSymArgs, elemRefName);
		final caseSiblingControlFlowFn: Null<Expr> = caseSiblingControlFlowFnExpr(tc, caseSymArgs, elemRefName);
		final blockStar: Expr = TriviaBlockLowering.triviaBlockStarExpr(
			fieldAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn, openText ?? '', closeText, false,
			afterDocComments, keepBetweenFields, beforeDocComments, interMemberInfo, indentCaseLabelsGate, emptyCurlyBreak, beginEndType,
			keepCurlyBlanks, lineCommentTrailBlank, blankBeforeFinalDocInLeading, staticVarSubdivInfo, betweenMultilineCommentsBlanks,
			uniformBetweenOptField, anonFnClear, emptyCurlyKnob, rightCurlyKnob, rightCurlyAnonFnKnob, blockEndedFlag ? sepText : null,
			blockEndedFlag, blockEndedFlag ? (starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE]: Null<String>) : null,
			blockEndedFlag ? tc.formatInfo.schemaTypePath : null, condLeadingDocInfo, clearExprPositionNonTail, beginTypeKnob, endTypeKnob,
			uniformStmtBlanks, emptyBlockBreak, caseSymArgs, caseSiblingUnitsFn, caseSiblingStructuralFn, caseSiblingControlFlowFn,
			blankAroundOptField
		);
		final blockStarNested: Expr = macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			_dn(_cols, $blockStar);
		};
		parts.push(condSwitchOpenCasesNest ? blockStarNested : blockStar);
	}

	/**
	 * Trivia close-peek (`@:trail`) Star dispatch (the `if (closeText != null)`
	 * branch of the `isTriviaStar` block in `emitWriterStarField`). Routes the
	 * Star through `triviaSepStarExpr` (sep-bearing) or `triviaBlockStarExpr`
	 * (block) and pushes onto `parts`. Extracted to keep the orchestrator under
	 * the complexity gate.
	 * Trivia block-mode (`@:trail`, no flat sep) Star dispatch — the fall-through
	 * tail of `emitTriviaCloseStar` after the sep dispatch returns. Reads the
	 * block-layout `@:fmt` flags and pushes the `triviaBlockStarExpr` emit onto
	 * `parts`. Extracted to keep the helper under the complexity gate.
	 * Resolves the three classify-info builders (`interMemberInfo` /
	 * `staticVarSubdivInfo` / `condLeadingDocInfo`) read off a block-mode trivia
	 * Star, bundled for `emitTriviaBlockStarDispatch`. Extracted to keep that
	 * helper under the complexity gate.
	 */
	private static function buildTriviaBlockInfos(
		tc: TriviaStarDispatchCtx, starNode: ShapeNode, elemRefName: String, beforeDocComments: Bool
	): WriterLowering.TriviaBlockInfos {
		final interMemberArgs: Null<Array<String>> = starNode.fmtReadStringArgs('interMemberBlankLines');
		// ω-interblank-cond-lookthrough: opt-in `@:fmt(interMember
		// CondLookThrough('<classifierField>', '<condCtor>',
		// '<bodyField>'))` makes `buildInterMemberClassifyInfo` classify
		// a `#if … #end` member by its FIRST inner member's kind instead
		// of the flat `0` ("other"). Mirrors `beforeDocCondLookThrough`'s
		// doc-comment look-through so two consecutive function-bearing
		// conditional members get a `betweenFunctions` blank. Inert unless
		// `interMemberBlankLines` is also present (the policy it widens).
		final interMemberCondArgs: Null<Array<String>> = starNode.fmtReadStringArgs('interMemberCondLookThrough');
		final interMemberInfo: Null<WriterLowering.InterMemberClassifyInfo> = interMemberArgs == null
			? null
			: buildInterMemberClassifyInfo(tc, elemRefName, interMemberArgs, interMemberCondArgs);
		// `fmtHasFlag` accepts both bare-identifier (`staticVarSubdivision`)
		// and call form (`staticVarSubdivision('modifiers', 'Static',
		// 'afterStaticVars')`) — `fmtReadStringArgs` is null in the
		// bare form and only carries args when the call form is used.
		final staticVarSubdiv: Bool = starNode.fmtHasFlag('staticVarSubdivision');
		final staticVarSubdivArgs: Null<Array<String>> = staticVarSubdiv ? starNode.fmtReadStringArgs('staticVarSubdivision') : null;
		final staticVarSubdivInfo: Null<WriterLowering.StaticVarSubdivisionInfo> = staticVarSubdiv && interMemberInfo != null
			? buildStaticVarSubdivisionInfo(tc, elemRefName, staticVarSubdivArgs ?? [])
			: null;
		// ω-cond-leading-doc-lookthrough: only meaningful alongside
		// `beforeDocCommentEmptyLines` (the policy whose doc-comment scan
		// it widens). Inert otherwise — the resolved info is dropped.
		final condLeadingDocArgs: Null<Array<String>> = starNode.fmtReadStringArgs('beforeDocCondLookThrough');
		final condLeadingDocInfo: Null<WriterLowering.CondLeadingDocLookThroughInfo> = condLeadingDocArgs != null && beforeDocComments
			? buildCondLeadingDocLookThroughInfo(tc, elemRefName, condLeadingDocArgs)
			: null;
		return {
			interMemberInfo: interMemberInfo,
			staticVarSubdivInfo: staticVarSubdivInfo,
			condLeadingDocInfo: condLeadingDocInfo
		};
	}

	/**
	 * ω-interblank — resolve the `@:fmt(interMemberBlankLines(fieldName,
	 * varCtor, fnCtor))` meta into the classify-switch shape that
	 * `triviaBlockStarExpr` splices into its per-element loop.
	 *
	 * Inspects the element Seq rule's named field to locate the
	 * classifier enum rule, then builds one `case <Ctor>(_):` pattern
	 * per variant in that enum, mapping the configured `varCtor` name to
	 * kind `1`, `fnCtor` to kind `2`, and every other variant to kind
	 * `0`. Iterating every variant (instead of emitting a wildcard
	 * default) keeps the switch exhaustive without relying on Haxe's
	 * unused-pattern warnings for the single-grammar two-variant case.
	 *
	 * ω-interblank-cond-lookthrough — when `condArgs` is non-null (the
	 * Star also carried `@:fmt(interMemberCondLookThrough('<classifier
	 * Field>', '<condCtor>', '<bodyField>'))`), the `<condCtor>` variant's
	 * top-level case classifies the member by its FIRST inner member's
	 * kind, read from a nested switch on
	 * `_inner.<bodyField>[0].node.<classifierField>` (the body Star is
	 * trivia-collected, so its elements carry the `.node` raw accessor).
	 * An empty body falls back to `0`.
	 *
	 * The look-through is FUNCTION-ONLY: only a `fnCtor` inner member maps
	 * to kind `2`; var-family inner members (and a nested `<condCtor>`)
	 * map to `0`. This is the byte-safe subset of the fork's
	 * `markClassFieldEmptyLines`, which pairs the REAL inner fields across
	 * the `#if … #end` boundary with full static-ness / visibility
	 * arbitration and doc-comment-policy override. anyparse classifies a
	 * whole conditional MEMBER as one outer-loop unit, so a var-bearing
	 * conditional cannot reproduce that field-vs-field arbitration and
	 * over-fires the static-var subdivision cascade (`afterStaticVars`) and
	 * the `none`-doc-comment strip. Functions carry no member-scope
	 * subdivision and surfaced no doc-comment-strip conflict in the corpus,
	 * so two consecutive function-bearing conditional members get a
	 * `betweenFunctions` blank and nothing else changes. (See the inner-case
	 * builder comment for the regression detail.)
	 */
	private static function buildInterMemberClassifyInfo(
		tc: TriviaStarDispatchCtx, elemRefName: String, args: Array<String>, ?condArgs: Array<String>
	): WriterLowering.InterMemberClassifyInfo {
		if (args.length != 3 && args.length != 6)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) expects 3 or 6 string args (classifierField, varCtor, fnCtor ['
				+ ', betweenVarsField, betweenFunctionsField, afterVarsField]), got ${args.length}',
				Context.currentPos()
			);
		final fieldName: String = args[0];
		// The var-ctor arg accepts a `|`-separated set so grammars whose
		// element enum splits the "var" family across multiple ctors (Haxe:
		// `VarMember` for `var x`, `FinalMember` for `final x` / `static
		// final x`) classify every member of that family as kind 1. Mirrors
		// the fork's `FieldUtils.getFieldType`, which folds `Kwd(KwdFinal)`
		// into the same `Var(...)` field kind as `Kwd(KwdVar)`.
		final varCtors: Array<String> = args[1].split('|');
		// The fn-ctor arg also accepts a `|`-separated set, symmetric with the
		// var-ctor set, so a grammar whose "function" family spans multiple
		// ctors (Haxe: `FnMember` for `function f()`, `FinalModifiedMember` for
		// the `final`-modifier form `final static function f()`) classifies
		// every member of that family as kind 2. Mirrors the fork's
		// `FieldUtils.getFieldType`, which classifies a `final`-modified
		// `function` as the same `Function(...)` kind as a plain `function`.
		final fnCtors: Array<String> = args[2].split('|');
		final betweenVarsField: String = args.length == 6 ? args[3] : 'betweenVars';
		final betweenFunctionsField: String = args.length == 6 ? args[4] : 'betweenFunctions';
		final afterVarsField: String = args.length == 6 ? args[5] : 'afterVars';
		// ω-interblank-cond-lookthrough: validate + unpack the optional
		// look-through config. The classifier field must match
		// `interMemberBlankLines`'s — both switches read the same enum.
		final condArgsResolved: Null<Array<String>> = condArgs != null && condArgs.length > 0 ? condArgs : null;
		if (condArgsResolved != null) {
			if (condArgsResolved.length != 3)
				Context.fatalError(
					'WriterLowering: @:fmt(interMemberCondLookThrough) expects exactly 3 string args ('
					+ 'classifierField, condCtor, bodyField), got ${condArgsResolved.length}',
					Context.currentPos()
				);
			if (condArgsResolved[0] != fieldName)
				Context.fatalError(
					'WriterLowering: @:fmt(interMemberCondLookThrough) classifierField "${condArgsResolved[0]}'
					+ '" must match interMemberBlankLines classifierField "$fieldName"',
					Context.currentPos()
				);
		}
		final condCtor: Null<String> = condArgsResolved != null ? condArgsResolved[1] : null;
		final bodyField: Null<String> = condArgsResolved != null ? condArgsResolved[2] : null;
		final enumRule: ShapeNode = resolveInterMemberEnumRule(tc, elemRefName, fieldName);
		final cases: Array<Case> = buildInterMemberClassifyCases({
			enumRule: enumRule,
			varCtors: varCtors,
			fnCtors: fnCtors,
			condCtor: condCtor,
			bodyField: bodyField,
			fieldName: fieldName
		});
		return {
			classifierFieldName: fieldName,
			classifyCases: cases,
			betweenVarsField: betweenVarsField,
			betweenFunctionsField: betweenFunctionsField,
			afterVarsField: afterVarsField
		};
	}

	/**
	 * Resolve the classifier enum (Alt) rule reached from the element Seq
	 * rule's `fieldName` Ref. Walks the elemRule -> classifierNode -> enumRuleName -> enumRule chain
	 * with its validation gates.
	 */
	private static function resolveInterMemberEnumRule(tc: TriviaStarDispatchCtx, elemRefName: String, fieldName: String): ShapeNode {
		final elemRule: Null<ShapeNode> = tc.shape.rules[elemRefName];
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) requires element rule $elemRefName to be a Seq struct', Context.currentPos()
			);
		final classifierNode: Null<ShapeNode> = elemRule.children.find(child ->
			child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == fieldName
		);
		if (classifierNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier field "$fieldName" not found on element rule $elemRefName',
				Context.currentPos()
			);
		if (classifierNode.kind != Ref)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier field "$fieldName" must be a plain Ref to an enum rule',
				Context.currentPos()
			);
		final enumRuleName: Null<String> = classifierNode.annotations.get(AnnotationKeys.BASE_REF);
		if (enumRuleName == null)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier field "$fieldName" has no base.ref annotation',
				Context.currentPos()
			);
		final enumRule: Null<ShapeNode> = tc.shape.rules[enumRuleName];
		if (enumRule == null || enumRule.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier target $enumRuleName must be an Alt (enum)', Context.currentPos()
			);
		return enumRule;
	}

	/**
	 * ω-cond-leading-doc-lookthrough — resolve
	 * `@:fmt(beforeDocCondLookThrough('<classifierField>', '<condCtor>',
	 * '<bodyField>'))` into the case pattern + body field name that
	 * `triviaBlockStarExpr` uses to look through a `#if … #end` member to
	 * its first inner member's leading doc-comment.
	 *
	 * Inspects the element Seq rule's named classifier field to locate the
	 * member-dispatch enum, verifies the named `<condCtor>` variant exists
	 * with exactly one arg (the conditional-body wrapper), and builds the
	 * `case <condCtor>(_inner):` pattern. `<bodyField>` is taken on trust as
	 * a Star field on that wrapper — its `[0].leadingComments` shape matches
	 * every trivia-collected Star element, so no per-shape validation beyond
	 * the ctor existence is needed.
	 */
	private static function buildCondLeadingDocLookThroughInfo(
		tc: TriviaStarDispatchCtx, elemRefName: String, args: Array<String>
	): WriterLowering.CondLeadingDocLookThroughInfo {
		if (args.length != 3)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) expects exactly 3 string args (classifierField, condCtor, bodyField), got '
				+ args.length,
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final condCtor: String = args[1];
		final bodyField: String = args[2];
		final elemRule: Null<ShapeNode> = tc.shape.rules[elemRefName];
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) requires element rule $elemRefName to be a Seq struct',
				Context.currentPos()
			);
		final classifierNode: Null<ShapeNode> = elemRule.children.find(child ->
			child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == fieldName
		);
		if (classifierNode == null || classifierNode.kind != Ref)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) classifier field "$fieldName" must be a plain Ref to an enum rule on '
				+ elemRefName,
				Context.currentPos()
			);
		final enumRuleName: Null<String> = classifierNode.annotations.get(AnnotationKeys.BASE_REF);
		final enumRule: Null<ShapeNode> = enumRuleName == null ? null : tc.shape.rules[enumRuleName];
		if (enumRule == null || enumRule.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) classifier target for "$fieldName" must be an Alt (enum)',
				Context.currentPos()
			);
		final condBranch: Null<ShapeNode> = enumRule.children.find(branch -> branch.annotations.get(AnnotationKeys.BASE_CTOR) == condCtor);
		if (condBranch == null)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) condCtor "$condCtor" not found on enum $enumRuleName',
				Context.currentPos()
			);
		if (condBranch.children.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) condCtor "$condCtor'
				+ '" must take exactly one arg (the conditional-body wrapper), got ${condBranch.children.length}',
				Context.currentPos()
			);
		final pos: Position = Context.currentPos();
		final condCasePattern: Expr = {
			expr: ECall({ expr: EConst(CIdent(condCtor)), pos: pos }, [macro _inner]),
			pos: pos
		};
		return {
			classifierFieldName: fieldName,
			condCasePattern: condCasePattern,
			bodyFieldName: bodyField
		};
	}

	/**
	 * ω-class-static-var-cascade — resolve `@:fmt(staticVarSubdivision)` /
	 * `@:fmt(staticVarSubdivision('<modifierField>', '<staticCtor>',
	 * '<afterStaticVarsField>' [, '<betweenStaticFunctionsField>']))` into
	 * the data the per-iteration kind switch reads to promote kind `1`
	 * (instance var) to kind `3` (static var) and kind `2` (function) to
	 * kind `4` (static function). The zero-arg form defaults to the
	 * `('modifiers', 'Static', 'afterStaticVars', 'betweenStaticFunctions')`
	 * quadruple — matches the canonical `HxMemberDecl.modifiers` Star +
	 * `HxMemberModifier.Static` ctor + the matching `HxModuleWriteOptions`
	 * knobs.
	 *
	 * ω-abstract-static-fn-cascade — the optional 4th arg names the
	 * `betweenStaticFunctions` opt knob consulted at a (4,4) static-fn pair.
	 *
	 * The companion meta is read alongside `@:fmt(interMemberBlankLines)`;
	 * `@:fmt(staticVarSubdivision)` without `interMemberBlankLines` is
	 * inert (the cascade arms are written by `triviaBlockStarExpr` and
	 * gated on the interMember presence). Validates that the named
	 * modifier field exists on the element Seq rule and that it's a Star.
	 */
	private static function buildStaticVarSubdivisionInfo(
		tc: TriviaStarDispatchCtx, elemRefName: String, args: Array<String>
	): WriterLowering.StaticVarSubdivisionInfo {
		if (args.length != 0 && args.length != 3 && args.length != 4)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) expects 0, 3 or 4 string args ('
				+ 'modifierField, staticCtor, afterStaticVarsField [, betweenStaticFunctionsField]), got ${args.length}',
				Context.currentPos()
			);
		final modifierField: String = args.length >= 3 ? args[0] : 'modifiers';
		final staticCtor: String = args.length >= 3 ? args[1] : 'Static';
		final afterStaticVarsField: String = args.length >= 3 ? args[2] : 'afterStaticVars';
		final betweenStaticFunctionsField: String = args.length == 4 ? args[3] : 'betweenStaticFunctions';
		validateStaticVarSubdivision(tc, elemRefName, modifierField, staticCtor);
		return {
			modifierFieldName: modifierField,
			staticCtorName: staticCtor,
			afterStaticVarsField: afterStaticVarsField,
			betweenStaticFunctionsField: betweenStaticFunctionsField
		};
	}

	/**
	 * Validate the modifier Star → enum → static-ctor chain that
	 * `@:fmt(staticVarSubdivision)` relies on. Fatal-errors on any
	 * misconfiguration; returns normally when the shape is sound.
	 *
	 */
	private static function validateStaticVarSubdivision(
		tc: TriviaStarDispatchCtx, elemRefName: String, modifierField: String, staticCtor: String
	): Void {
		final elemRule: Null<ShapeNode> = tc.shape.rules[elemRefName];
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) requires element rule $elemRefName to be a Seq struct', Context.currentPos()
			);
		final modifierNode: Null<ShapeNode> = elemRule.children.find(child ->
			child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == modifierField
		);
		if (modifierNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" not found on element rule $elemRefName',
				Context.currentPos()
			);
		if (modifierNode.kind != Star)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" must be a Star', Context.currentPos()
			);
		// `base.ref` lives on the Star's element child (the Ref node), not the
		// Star itself — `ShapeBuilder.shapeFieldType` builds `Array<T>` as a
		// Star with `children = [shapeFieldType(T)]` and only the inner Ref
		// carries `base.ref`.
		if (modifierNode.children.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" must have exactly one Star child',
				Context.currentPos()
			);
		final modifierEnumName: Null<String> = modifierNode.children[0].annotations.get(AnnotationKeys.BASE_REF);
		if (modifierEnumName == null)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" has no base.ref annotation',
				Context.currentPos()
			);
		final modifierEnum: Null<ShapeNode> = tc.shape.rules[modifierEnumName];
		if (modifierEnum == null || modifierEnum.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier target $modifierEnumName must be an Alt (enum)', Context.currentPos()
			);
		var staticBranchFound: Bool = false;
		for (branch in modifierEnum.children) if (branch.annotations.get(AnnotationKeys.BASE_CTOR) == staticCtor) {
			staticBranchFound = true;
			break;
		}
		if (!staticBranchFound)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) static ctor "$staticCtor" not found on enum $modifierEnumName',
				Context.currentPos()
			);
	}

	/**
	 * The `<namePrefix>_<ElemRule>` fn-ref a block Star's case-symmetry
	 * pre-pass consumes, or null when the Star does not opt into
	 * `caseSiblingSymmetry` (⇒ `caseSiblingWidthProbeExpr` yields `macro -1`
	 * and no pre-pass runs) or the format generates no AST predicates (⇒ that
	 * builder fatal-errors: the flattener and the structural verdict are
	 * mandatory for an opted-in Star, the same loud failure every other
	 * predicate-only `@:fmt` feature gives - carrying a second,
	 * never-exercised copy of the pre-pass is exactly the drift those features
	 * refuse). The control-flow verdict is the one OPTIONAL member of the
	 * family: it is gated on a second meta and its absence drops an arm rather
	 * than failing (see `caseSiblingControlFlowFnExpr`).
	 *
	 * Resolved from the Star's ELEMENT rule — the same seam as
	 * `tryparseElemCondFn`, though the grammar generates all of these for
	 * `HxSwitchCase` alone, so a `caseSiblingSymmetry` Star over any other
	 * element rule fails at macro time with an unresolved field. Split out of
	 * `emitTriviaBlockStarDispatch` to keep that helper under the complexity
	 * gate.
	 */
	private static function casePredFnExpr(
		tc: TriviaStarDispatchCtx, caseSymArgs: Null<Array<String>>, elemRefName: String, namePrefix: String
	): Null<Expr> {
		return !tc.formatInfo.astPreds || caseSymArgs == null || caseSymArgs.length != 2
			? null
			: AstPredLowering.predFnExpr(tc.shape.root, true, false, '${namePrefix}_${simpleName(elemRefName)}');
	}

	/**
	 * ω-if-leader-case-symmetry: the case-UNIT flattener. A `#if`-guarded case
	 * region is ONE Star element whose Doc carries directive hardlines (flat
	 * width `-1`), so without this predicate the region could only FOLLOW a
	 * sibling's break, never LEAD one; it expands the region into its inner
	 * case elements, and both channels of the pre-pass then judge each one on
	 * its own.
	 */
	private static inline function caseSiblingUnitsFnExpr(
		tc: TriviaStarDispatchCtx, caseSymArgs: Null<Array<String>>, elemRefName: String
	): Null<Expr> {
		return casePredFnExpr(tc, caseSymArgs, elemRefName, 'caseSiblingUnits');
	}

	/**
	 * ω-case-sibling-symmetry widened: the STRUCTURAL verdict, answering what
	 * the flat-width measurement cannot — whether a unit sits below its label
	 * for reasons of SHAPE (a multi-statement body, a single statement the
	 * flat-refusal gate rejects, or a label-splice region, whose shared body
	 * always renders below the labels it was split from). One `true` in the
	 * expanded unit list decides the whole switch, so the pre-pass short-
	 * circuits to `BodyFit.SIBLING_FORCE_BREAK` and never runs the measuring
	 * loop at all.
	 */
	private static inline function caseSiblingStructuralFnExpr(
		tc: TriviaStarDispatchCtx, caseSymArgs: Null<Array<String>>, elemRefName: String
	): Null<Expr> {
		return casePredFnExpr(tc, caseSymArgs, elemRefName, 'caseUnitStructuralBreak');
	}

	/**
	 * omega-case-body-controlflow-glue: the CONTROL-FLOW verdict — whether a
	 * unit holds exactly one body statement and that statement is keyword-led
	 * control flow. Paired with the pre-pass's own `flatLength == -1`
	 * measurement, since the statement KIND alone cannot tell an inline-able
	 * `case X: if (c) x();` from a refused `case X: if (c) { x(); }`.
	 */
	private static function caseSiblingControlFlowFnExpr(
		tc: TriviaStarDispatchCtx, caseSymArgs: Null<Array<String>>, elemRefName: String
	): Null<Expr> {
		return !elemBodyStarHasFlag(tc, elemRefName, 'refuseGlueOnControlFlowRoot')
			? null
			: casePredFnExpr(tc, caseSymArgs, elemRefName, 'caseUnitControlFlowBody');
	}

	/**
	 * True iff the case-list Star's ELEMENT rule reaches a body Star carrying
	 * `@:fmt(<flag>)` - the macro-time link that keeps the two halves of the
	 * glue refusal gated by ONE meta.
	 *
	 * The refusal itself is read off `HxCaseBranch.body` /
	 * `HxDefaultBranch.stmts` inside the body Star's own emit; the sibling
	 * FORCE that must accompany it is emitted in the case-LIST Star's pre-pass,
	 * a different rule with a different meta. Left ungated, a grammar opting
	 * into `caseSiblingSymmetry` without the body flag would spread every
	 * sibling for a body that then GLUED to its label - the exact contradiction
	 * the symmetry rule exists to prevent.
	 *
	 * The walk is bounded to ONE rule hop on purpose: the element rule's own
	 * Star fields, plus those of the rules its direct `Ref` children name (for
	 * an `Alt` element rule that is each ctor's payload - `CaseBranch` ->
	 * `HxCaseBranch`). Following refs transitively would answer "does the flag
	 * exist ANYWHERE in the grammar", which is true as soon as it is declared
	 * once and would gate nothing.
	 */
	private static function elemBodyStarHasFlag(tc: TriviaStarDispatchCtx, elemRefName: String, flag: String): Bool {
		final elem: Null<ShapeNode> = tc.shape.rules[elemRefName];
		return elem != null && (ownStarHasFlag(elem, flag) || elem.children.exists(branch -> refStarHasFlag(tc, branch, flag)));
	}

	/** Any direct `Star` child of `node` carrying `@:fmt(<flag>)`. */
	private static function ownStarHasFlag(node: ShapeNode, flag: String): Bool {
		return node.children.exists(c -> c.kind == Star && c.fmtHasFlag(flag));
	}

	/** `ownStarHasFlag` on the rules named by `node`'s own direct `Ref` children (one hop, no recursion). */
	private static function refStarHasFlag(tc: TriviaStarDispatchCtx, node: ShapeNode, flag: String): Bool {
		for (child in node.children) {
			final ref: Null<String> = child.annotations.get(AnnotationKeys.BASE_REF);
			if (ref == null) continue;
			final target: Null<ShapeNode> = tc.shape.rules[ref];
			if (target != null && ownStarHasFlag(target, flag)) return true;
		}
		return false;
	}

}

/**
 * The build state the close-peek trivia Star dispatch reads, bundled once
 * per `WriterLowering` instance.
 */
typedef TriviaStarDispatchCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final formatInfo: FormatReader.FormatInfo;
	final isSpacedLead: (openText:Null<String>) -> Bool;
	final mapWrapFor: (field:Null<String>) -> Null<WriterLowering.SepStarMapWrap>;
}
#end
