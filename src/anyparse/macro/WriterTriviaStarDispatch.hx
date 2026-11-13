package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.MacroNames.*;
import anyparse.macro.WriterCascadeLowering.*;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterPolicyLowering.*;
import haxe.macro.Context;
import haxe.macro.Expr;

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
 * calls need ASSEMBLED first: the inter-member classifier, the static-var subdivision INFO and its
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

	/** How many knobs `@:fmt(beginEndType(...))` names: begin, end. */
	private static inline final BEGIN_END_KNOBS: Int = 2;

	/** The arguments of `@:fmt(interMemberBlankLines(...))` before its knobs: classifier field, var ctors, fn ctors. */
	private static inline final INTER_MEMBER_HEAD_ARGS: Int = 3;

	/** How many knobs `@:fmt(interMemberBlankLines(...))` names: between vars, between functions, after vars. */
	private static inline final INTER_MEMBER_KNOBS: Int = 3;

	/** The arguments of `@:fmt(staticVarSubdivision(...))` before its knobs: modifier field, static ctor. */
	private static inline final STATIC_SUBDIV_HEAD_ARGS: Int = 2;

	/** How many knobs `@:fmt(staticVarSubdivision(...))` names: after static vars, between static functions. */
	private static inline final STATIC_SUBDIV_KNOBS: Int = 2;

	/** The `@:fmt` flag that subdivides a member Star's kinds into static and instance. */
	private static final STATIC_SUBDIVISION: String = 'staticVarSubdivision';

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
			final afterTrailSlot: String = c.prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX;
			final afterTrailAccess: Expr = macro value.$afterTrailSlot;
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
			// Both paths read the sep-Star's flags through its plan; what a struct field spells differently from an enum
			// ctor arrives built: the inside-of-delimiter pads (`delimInsidePolicySpace` answers null without a delim
			// policy flag), the body-aware indent and the map wrap rules.
			final plan: SepStarPlan = new SepStarPlan(StarPlan.metaOf(starNode));
			parts.push(new TriviaSepLowering(
				plan, fieldAccess, c, c.trailPresentAccess, elemFn, openText ?? '', closeText, sepText,
				leftCurlyOwnedBySep ? knobLeftCurly : null,
				delimInsidePolicySpace(starNode, ['typeParamOpen', 'objectLiteralBracesOpen'], false),
				delimInsidePolicySpace(starNode, ['typeParamClose', 'objectLiteralBracesClose'], true),
				bodyEmptySuppressExpr(starNode, tc.shape.root, true), tc.mapWrapFor(plan.mapWrapRules()),
				TriviaTailRehome.fnRefFor(starNode.children[0]), afterDocPolicy(starNode)
			).triviaSepStarExpr());
			return;
		}
		emitTriviaBlockStarDispatch(tc, c, parts);
	}

	/**
	 * Trivia block-mode (`@:trail`, no flat sep) Star dispatch — the fall-through
	 * tail of `emitTriviaCloseStar` after the sep dispatch returns: pushes the block emit, which reads the Star's plan
	 * and its struct-field inputs itself, onto `parts`.
	 */
	@:access(anyparse.macro.TriviaBlockLowering)
	private static function emitTriviaBlockStarDispatch(
		tc: TriviaStarDispatchCtx, c: WriterLowering.TriviaStarCtx, parts: Array<Expr>
	): Void {
		final plan: BlockStarPlan = new BlockStarPlan(StarPlan.metaOf(c.starNode));
		final blockStar: Expr = new TriviaBlockLowering(
			plan, c.fieldAccess, c, c.elemFn, c.openText ?? '', c.closeText, plan.blockEnded() ? c.sepText : null,
			tc.formatInfo.schemaTypePath, { tc: tc, starNode: c.starNode, elemRefName: c.elemRefName }
		).triviaBlockStarExpr();
		// `@:fmt(condSwitchOpenCasesNest)`: the shared case list of a `#if for { switch { #else … #end` region sits two
		// block levels below its statement, one more than a block Star's body nests, so the whole emit takes another `_dn`.
		final blockStarNested: Expr = macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			_dn(_cols, $blockStar);
		};
		parts.push(plan.condSwitchOpenCasesNest() ? blockStarNested : blockStar);
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
		final staticVarSubdiv: Bool = starNode.fmtHasFlag(STATIC_SUBDIVISION);
		final staticVarSubdivArgs: Null<Array<String>> = staticVarSubdiv ? starNode.fmtReadStringArgs(STATIC_SUBDIVISION) : null;
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
		return { interMemberInfo: interMemberInfo, staticVarSubdivInfo: staticVarSubdivInfo, condLeadingDocInfo: condLeadingDocInfo };
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
		final knobs: Array<Expr> = knobReads('interMemberBlankLines', args.slice(INTER_MEMBER_HEAD_ARGS), INTER_MEMBER_KNOBS);
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
			betweenVars: knobs[0],
			betweenFunctions: knobs[1],
			afterVars: knobs[2]
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
		final condCasePattern: Expr = { expr: ECall({ expr: EConst(CIdent(condCtor)), pos: pos }, [macro _inner]), pos: pos };
		return { classifierFieldName: fieldName, condCasePattern: condCasePattern, bodyFieldName: bodyField };
	}

	/**
	 * ω-class-static-var-cascade — resolve `@:fmt(staticVarSubdivision(<modifierField>, <staticCtor>, <afterStaticVars>,
	 * <betweenStaticFunctions> [, <flag>, <switched afterStaticVars>, <switched betweenStaticFunctions>]))` into the data the
	 * per-iteration kind switch reads to promote kind `1` (instance var) to kind `3` (static var) and kind `2` (function) to
	 * kind `4` (static function); the knobs resolve through `knobReads`.
	 *
	 * The companion meta is read alongside `@:fmt(interMemberBlankLines)`; `@:fmt(staticVarSubdivision)` without
	 * `interMemberBlankLines` is inert (the cascade arms are written by `triviaBlockStarExpr` and gated on the interMember
	 * presence). Validates that the named modifier field exists on the element Seq rule and that it is a Star.
	 */
	private static function buildStaticVarSubdivisionInfo(
		tc: TriviaStarDispatchCtx, elemRefName: String, args: Array<String>
	): WriterLowering.StaticVarSubdivisionInfo {
		final knobs: Array<Expr> = knobReads(STATIC_SUBDIVISION, args.slice(STATIC_SUBDIV_HEAD_ARGS), STATIC_SUBDIV_KNOBS);
		final modifierField: String = args[0];
		final staticCtor: String = args[1];
		validateStaticVarSubdivision(tc, elemRefName, modifierField, staticCtor);
		return {
			modifierFieldName: modifierField,
			staticCtorName: staticCtor,
			afterStaticVars: knobs[0],
			betweenStaticFunctions: knobs[1]
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
	 * The one answer to "which option does a type body's `@:fmt` knob read": `meta` names `width` knobs of the body's own;
	 * a flag and `width` more name the knobs it reads while `opt.<flag>` is set — how one grammar type written in two roles
	 * (`abstract` and `enum abstract`, `class` and `extern class`) keeps two scopes. The grammar always names them: a
	 * default here would be one grammar's option name in the core macro. An empty name reads `null`: the role has no
	 * such knob.
	 */
	private static function knobReads(meta: String, knobs: Null<Array<String>>, width: Int): Array<Expr> {
		if (knobs == null || (knobs.length != width && knobs.length != 2 * width + 1))
			Context.fatalError(
				'@:fmt($meta) names its $width knob(s), optionally followed by a flag and the $width it switches to, got $knobs',
				Context.currentPos()
			);
		final own: Array<Expr> = [for (i in 0...width) knobRead(knobs[i])];
		if (knobs.length == width) return own;
		final flag: Expr = macro $p{['opt', knobs[width]]};
		return [
			for (i in 0...width) {
				final unswitched: Expr = own[i];
				final switched: Expr = knobRead(knobs[width + 1 + i]);
				macro ($flag ? $switched : $unswitched);
			}
		];
	}

	/** `knobReads` over the knob names a Star plan read for `@:fmt(<meta>(...))`; null when the Star does not carry the flag. */
	private static function starKnobReads(meta: String, knobs: Null<Array<String>>, width: Int = BEGIN_END_KNOBS): Null<Array<Expr>> {
		return knobs != null ? knobReads(meta, knobs, width) : null;
	}

	/** One knob of `knobReads`: `opt.<name>`, or `null` for an empty name. */
	private static function knobRead(name: String): Expr {
		return name == '' ? macro null : macro $p{['opt', name]};
	}

	/**
	 * The policy a Star applies after a doc-commented member, or null when it carries no
	 * `@:fmt(afterFieldsWithDocComments)`: the bare flag reads the global knob, `('<knob>')` or `('<knob>', '<flag>',
	 * '<alt>')` that knob, an unset `<alt>` falling back to `<knob>` and an unset `<knob>` (or `''`) to `Ignore`.
	 */
	private static function afterDocPolicy(star: ShapeNode): Null<Expr> {
		final meta: String = 'afterFieldsWithDocComments';
		if (!star.fmtHasFlag(meta)) return null;
		final knobs: Null<Array<String>> = star.fmtReadStringArgs(meta);
		if (knobs == null) return macro opt.afterFieldsWithDocComments;
		if (knobs.length != 1 && knobs.length != 3)
			Context.fatalError(
				'@:fmt($meta) names its knob, optionally followed by a flag and the knob it switches to, got $knobs', Context.currentPos()
			);
		final ignore: Expr = macro anyparse.format.CommentEmptyLinesPolicy.Ignore;
		final own: Expr = knobOr(knobs[0], ignore);
		if (knobs.length == 1) return own;
		final flag: Expr = macro $p{['opt', knobs[1]]};
		final alt: Expr = knobOr(knobs[2], own);
		return macro ($flag ? $alt : $own);
	}

	/**
	 * The knob `name` with `fallback` in its place when it is unset, or `fallback` alone for `''`; the read never yields
	 * a bare `null`, which a static target cannot hold in an enum abstract over `Int`.
	 */
	private static function knobOr(name: String, fallback: Expr): Expr {
		return name == '' ? fallback : macro (${knobRead(name)} ?? $fallback);
	}

	/**
	 * The `beginEndType` knob reads `edges` of a type body, each passed through `MemberGap.docEdge` when the Star also
	 * carries `@:fmt(beginEndTypeIfDoc(...))`, which names the counts a body holding a doc comment takes instead.
	 */
	private static function docEdgeReads(ifDocKnobs: Null<Array<String>>, edges: Array<Expr>): Array<Expr> {
		final ifDocFlag: String = BlockStarPlan.BEGIN_END_TYPE_IF_DOC;
		final ifDoc: Null<Array<Expr>> = starKnobReads(ifDocFlag, ifDocKnobs);
		if (ifDoc == null) return edges;
		if (edges.length != BEGIN_END_KNOBS) {
			final edgeFlag: String = BlockStarPlan.BEGIN_END_TYPE;
			Context.fatalError('@:fmt($ifDocFlag) replaces the counts of @:fmt($edgeFlag), which this Star lacks', Context.currentPos());
		}
		return [
			for (i in 0...BEGIN_END_KNOBS) {
				final stated: Expr = edges[i];
				final docCount: Expr = ifDoc[i];
				macro anyparse.format.MemberGap.docEdge($stated, $docCount, _arr, _trailLC);
			}
		];
	}

	/**
	 * The runtime answer of `@:fmt(blankBeforeOrphanLineCommentTrail)`: whether a `//`-led orphan trail takes a forced
	 * blank in front of it. An optional argument names an `opt` flag under which the Star's kind does not take it.
	 */
	private static function lineCommentTrailGate(star: ShapeNode): Expr {
		if (!star.fmtHasFlag('blankBeforeOrphanLineCommentTrail')) return macro false;
		final off: Null<String> = fmtFirstStringArg(star, 'blankBeforeOrphanLineCommentTrail');
		return off == null ? macro true : macro !$p{['opt', off]};
	}

}

/**
 * The build state the close-peek trivia Star dispatch reads, bundled once
 * per `WriterLowering` instance.
 */
typedef TriviaStarDispatchCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final formatInfo: FormatReader.FormatInfo;
	final isSpacedLead: (openText: Null<String>) -> Bool;
	final mapWrapFor: (field: Null<String>) -> Null<WriterLowering.SepStarMapWrap>;
}
#end
