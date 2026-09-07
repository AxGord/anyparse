package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import anyparse.macro.WriterBlankLowering.*;
import anyparse.macro.WriterBraceSymmetryLowering.*;
import anyparse.macro.WriterCondWrapLowering.*;
import anyparse.macro.WriterCtorPatternLowering.*;
import anyparse.macro.WriterFieldSepLowering.*;
import anyparse.macro.WriterLowering.PrevBodyInfo;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterPolicyLowering.*;
import anyparse.macro.WriterRefLeadLowering.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W - what a struct field that is a `Ref` emits.
 *
 * `lowerStruct` walks a Seq rule's fields and hands each one here. The two
 * halves are the OPTIONAL Ref (`emitOptionalRefField` and the four body
 * layouts under it - lead, absent-on-body, keyword body, body-policy-only)
 * and the MANDATORY one (`emitMandatoryRefField`, its body-policy and
 * non-body-policy arms, the four wraps under the latter, and the write call
 * itself). `finalizeNonStarField` closes both with the trail, and
 * `emitFieldLeadIn` / `emitKwPrefix` open them with the lead.
 *
 * S117 measured this family as ENTANGLED with the Seq walker - twenty-two
 * members reaching nine outside themselves, seven of which it read as
 * members of the Seq-field region - and priced the two as one joint
 * extraction. The edges were real and the reading was not: five of those
 * seven were separator builders and two were ctor-pattern lookups, so they
 * belonged to neither family. With `WriterFieldSepLowering` and
 * `WriterCtorPatternLowering` named as LAYERS, this family reaches nothing
 * in the Seq walker at all - `lowerStruct` calls in at four sites and
 * nothing calls back. The three helpers that looked shared
 * (`buildBodyPolicyForCtorChain`, `buildBoolFlagRawWriteCall`,
 * `buildLeftCurlySepExpr`) turned out to have both their callers here, so
 * they came too.
 *
 * The dependency surface is eight fields and reads neither `shape` nor the
 * format info: a Ref field's layout is decided from its own metadata, the
 * trivia gate, and the four bundles it hands through.
 */
@:access(anyparse.macro.WriterArrowValueIfLowering, anyparse.macro.WriterBlankLowering, anyparse.macro.WriterBodyPolicyLowering,
	anyparse.macro.WriterBraceSymmetryLowering, anyparse.macro.WriterCascadeLowering, anyparse.macro.WriterChainLowering,
	anyparse.macro.WriterCondWrapLowering, anyparse.macro.WriterCtorPatternLowering, anyparse.macro.WriterFieldSepLowering,
	anyparse.macro.WriterLowering, anyparse.macro.WriterLoweringSupport, anyparse.macro.WriterPolicyLowering,
	anyparse.macro.WriterRefLeadLowering, anyparse.macro.WriterTriviaSlotLowering)
final class WriterRefFieldLowering {

	/**
	 * The `value.<field>BeforeTrail` access for a mandatory Ref carrying `@:trail`
	 * in a trivia-bearing rule, or null when the field has no such slot. Gate and
	 * host set mirror `StructSeqLowering.hasBeforeTrailSlotField` /
	 * `TriviaTypeSynth.isBeforeTrailRef` — the three must agree or the generated
	 * writer reads a field the parser never pushed.
	 */
	private static function beforeTrailSlotAccess(
		ctx: RefFieldCtx, child: ShapeNode, fieldAccess: Expr, isOptional: Bool, trailText: Null<String>, typePath: String
	): Null<Expr> {
		if (trailText == null || isOptional || child.kind != Ref || !ctx.ctx.trivia || !ctx.isTriviaBearing(typePath)) return null;
		return switch fieldAccess.expr {
			case EField(base, name): { expr: EField(base, name + TriviaTypeSynth.BEFORE_TRAIL_SUFFIX), pos: fieldAccess.pos };
			case _: null;
		};
	}

	/**
	 * Emit an optional Ref struct field (the `case Ref if (isOptional)` arm of
	 * `lowerStruct`). Builds the descendant writeCall (opt-fanout flags +
	 * indentValueIfCtor), dispatches the optional body emission across the kw-led
	 * / lead-led / bodyPolicy-only / absent-on arms into `optParts`, appends the
	 * optional-Ref `@:fmt(padTrailing)` pad, and pushes the `_optVal != null ?
	 * optBody : _de()` guard onto `parts`. Returns this field's `thisPadTrailing`
	 * runtime expr (or null).
	 */
	private static function emitOptionalRefField(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, node: ShapeNode, typePath: String, fieldName: String, fieldAccess: Expr,
		kwLead: Null<String>, leadText: Null<String>, trailText: Null<String>, trailOptText: Null<String>, bodyPolicyFlag: Null<String>,
		bodyPolicyExprFlag: Null<String>, hasElseIf: Bool, elseFieldName: Null<String>, prevBodyField: Null<PrevBodyInfo>,
		prevPadTrailing: Null<Expr>, hasStructFieldTrailOptSlot: Bool, structTrailOptAccess: Null<Expr>, prevTrailFieldName: Null<String>,
		bareSep: Null<Expr>
	): Null<Expr> {
		final refName: String = child.annotations[AnnotationKeys.BASE_REF];
		final writeFn: String = ctx.writeFnFor(refName);
		// ω-single-stmt-braces CHAIN symmetry: runtime force-keep for this else's
		// chain. Mid-chain it is already true via `opt._ssbChainSuppress`; at the
		// chain root it is the spine scan over then + else-if bodies. Reused by the
		// unwrap gate (terminal else block) AND the else-if writeCall propagation.
		// `macro false` off-path (plain mode / non-dropSingleStmtBraces field).
		final elseChainSuppressExpr: Expr = buildElseChainSuppressExpr(ctx.braceSym, node, child, fieldAccess);
		final dropElseBraces: Bool = ctx.ctx.trivia && child.fmtHasFlag('dropSingleStmtBraces');
		final thenSiblingKeepsExpr: Expr = dropElseBraces ? buildThenSiblingKeepsProbe(ctx.braceSym, node, typePath) : macro false;
		// ω-single-stmt-braces trailing-comment hoist for the else-body: same gate args as
		// its `unwrapStmt` splice below (elseFollows=false, hasTrailingSemi=false, isThenBody=false)
		// so the hoisted comment fires exactly when the de-brace does.
		final elseTrailCommentExpr: Null<Expr> = dropElseBraces
			? macro anyparse.format.SingleStmtBraces.hoistTrailingComment(
				$fieldAccess, opt.dropSingleStmtBraces, opt._ssbSuppress, false, false, $thenSiblingKeepsExpr || $elseChainSuppressExpr,
				false
			)
			: null;
		// ω-orphan-prefix-decl: same opt-fanout seat the mandatory-Ref path has —
		// `@:fmt(setBoolFlagFromStarCtor(...))` hands the descendant a `_wo` copy
		// carrying the flag the sibling Star's ctor set decides. Without it,
		// `HxTopLevelDecl.decl` going optional dropped `_classExtern` and two
		// corpus fixtures (`emptylines/issue_65_extern_class`,
		// `issue_147_between_fields_with_comments`) went byte-fail.
		final boolFlagArgs: Null<Array<String>> = readBoolFlagStarCtorArgs(child);
		final optArgExpr: Expr = boolFlagArgs != null ? (macro _wo) : optionalRefOptArgExpr(ctx, child, refName, elseChainSuppressExpr);
		final rawWriteCall: Expr = buildBoolFlagRawWriteCall(ctx, boolFlagArgs, {
			expr: ECall(macro $i{writeFn}, [macro _optVal, optArgExpr]),
			pos: Context.currentPos()
		}, typePath, child.fmtHasFlag('propagateExprPosition'));
		// ω-indent-objectliteral / ω-expr-body-indent-objectliteral: the additive
		// `maybeIndentValueIfCtor` Nest is SKIPPED when a same-field
		// `@:fmt(bodyPolicy)` routes `indentValueIfCtor` through the subtractive
		// `bodyPolicyWrap.indentObjArgs` channel instead.
		final indentObjArgs: Null<Array<String>> = child.fmtReadStringArgs('indentValueIfCtor');
		final writeCall: Expr = foldSsbTrailingComment(
			bodyPolicyFlag != null && indentObjArgs != null ? rawWriteCall : maybeIndentValueIfCtor(rawWriteCall, macro _optVal, child),
			elseTrailCommentExpr
		);
		// Leading separator is runtime-conditional when @:fmt(sameLine(...)) is
		// present; @:fmt(bodyPolicy(...)) replaces the final ' ' before the body
		// with a runtime-switched separator. The per-parent kw-trivia slots are
		// read off `value` and threaded into the kw→body separator inside
		// emitOptionalKwBody.
		final optParts: Array<Expr> = [];
		// ω-N-break-after-eq: lead+RHS bundle handled in emitOptionalRefLead.
		if (kwLead != null)
			emitOptionalKwBody(
				ctx, child, optParts, kwLead, fieldName, bodyPolicyFlag, bodyPolicyExprFlag, writeCall, refName, hasElseIf, elseFieldName,
				prevBodyField, typePath, prevPadTrailing, indentObjArgs
			);
		else if (leadText != null)
			emitOptionalRefLead(
				ctx, child, optParts, leadText, writeCall, prevBodyField, typePath, prevPadTrailing, trailText, trailOptText,
				hasStructFieldTrailOptSlot, structTrailOptAccess
			);
		else if (bodyPolicyFlag != null)
			emitOptionalBodyPolicyOnly(
				ctx, child, optParts, bodyPolicyFlag, bodyPolicyExprFlag, writeCall, refName, hasElseIf, elseFieldName, indentObjArgs,
				prevTrailFieldName
			);
		else
			emitOptionalAbsentOnBody(ctx, child, optParts, refName, writeCall, bareSep);
		// ω-pad-trailing-ref: optional-Ref `@:fmt(padTrailing)` pushes a trailing
		// space INSIDE optParts so the pad is emitted only when `_optVal != null`;
		// the tracker expr `$fieldAccess != null` matches that runtime presence
		// guard one-to-one. First consumer: `HxConditionalExpr.elseExpr`.
		final thisPadTrailing: Null<Expr> = child.fmtHasFlag('padTrailing') ? {
			optParts.push(padTrailingDoc(ctx.fieldSep, node, child, typePath));
			macro $fieldAccess != null;
		} : null;
		final optBody: Expr = optParts.length == 1 ? optParts[0] : dcCall(optParts);
		// ω-single-stmt-braces: an optional body field carrying
		// `@:fmt(dropSingleStmtBraces)` (trivia mode only — `HxIfStmt.elseBody`)
		// substitutes `_optVal` at its single binding site, so every downstream
		// consumer (writeCall, elseIf ctor pattern, propagateElseIfBranch switch)
		// sees the unwrapped statement. An else-body is never followed by a
		// further `else` at its own level, so `elseFollows` is `false`; ancestor
		// dangling-else frames still apply via `opt._ssbSuppress`. Unwrapping
		// `else { if (c) x; }` yields the `else if` form by construction.
		// `hasTrailingSemi` is `false`: an else-body's own writer path already drops a
		// redundant trailing `;` (`else { x; };` → `else x;`, no `;;`), so — unlike the
		// for / while / then-body splice — de-bracing is always safe and never gated.
		// ω-single-stmt-braces symmetry (gate 7): an else-body must keep its braces whenever
		// the sibling then-body keeps its own (see buildThenSiblingKeepsProbe).
		final optValInit: Expr = dropElseBraces
			? macro {
				var _sv = $fieldAccess;
				if (_sv != null)
					_sv = cast anyparse.format.SingleStmtBraces.unwrapStmt(
						_sv, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, false, false,
						$thenSiblingKeepsExpr || $elseChainSuppressExpr, false
					);
				_sv;
			}
			: valueBraceSymmetryWrap(ctx.braceSym, child, fieldAccess);
		parts.push(macro {
			final _optVal = $optValInit;
			if (_optVal != null)
				$optBody
			else
				_de();
		});
		return thisPadTrailing;
	}

	/**
	 * Emit the lead + value + trail of an optional `@:lead`-bearing Ref struct
	 * field into `optParts` (the `case Ref if (isOptional)` `leadText != null`
	 * arm). Handles tight leads, `@:fmt(tightLead)`, `@:fmt(typeParamDefaultEquals)`,
	 * the ω-N-break-after-eq bundle, and the optional-ref-trail / trailOpt pushes.
	 *
	 */
	private static function emitOptionalRefLead(
		ctx: RefFieldCtx, child: ShapeNode, optParts: Array<Expr>, leadText: String, writeCall: Expr, prevBodyField: Null<PrevBodyInfo>,
		typePath: String, prevPadTrailing: Null<Expr>, trailText: Null<String>, trailOptText: Null<String>,
		hasStructFieldTrailOptSlot: Bool, structTrailOptAccess: Null<Expr>
	): Void {
		// ω-N-break-after-eq: when the meta-gated helper bundles the
		// lead + RHS together (via the natural-first-line probe), the
		// post-branch unconditional `optParts.push(writeCall)` must be
		// skipped — the RHS is already inside the bundled Doc.
		var breakAfterEqEmitted: Bool = false;
		final isFieldTight: Bool = child.fmtHasFlag('tightLead');
		if (ctx.isTightLead(leadText)) {
			// ω-E-whitespace: `@:fmt(typeHintColon)` on
			// optional-Ref tight leads routes through the same
			// WhitespacePolicy helper as mandatory leads.
			// Without the flag the `None` default keeps the
			// tight `_dt(leadText)` byte-identical to the pre-
			// flag path (`f():Void`).
			optParts.push(whitespacePolicyLead(child, leadText, ['typeHintColon']));
		} else if (isFieldTight) {
			// Per-field `@:fmt(tightLead)`: opts an
			// optional Ref's `@:lead` into tight emission
			// without joining the format-level `tightLeads`
			// list. No leading separator, no trailing
			// `_dop(' ')` — bare `_dt(leadText)` only.
			// Consumer: `HxVarDecl.access` (`@:lead('(')` for
			// property accessor clause). Format-level
			// `tightLeads` can't carry `(` because other
			// `@:lead('(')` sites (`HxFnDecl.params`,
			// `HxIfStmt.cond`, etc.) have distinct handlers.
			optParts.push(macro _dt($v{leadText}));
		} else if (firstFmtFlag(child, ['typeParamDefaultEquals']) != null) {
			// ω-typeparam-default-equals: optional non-tight lead with
			// `@:fmt(typeParamDefaultEquals)` collapses the
			// pre-slice `sameLineSeparator + leadText + ' '` pair
			// into a single `whitespacePolicyLead` switch so
			// `WhitespacePolicy.None` can produce a tight
			// `<T=Int>` (matching `whitespace.binopPolicy: "none"`).
			// The default `Both` branch emits ` = ` — byte-
			// identical to the previous pair when the field has
			// no `@:fmt(sameLine(...))` companion.
			optParts.push(whitespacePolicyLead(child, leadText, ['typeParamDefaultEquals']));
		} else {
			optParts.push(sameLineSeparator(ctx.fieldSep, child, prevBodyField, typePath, prevPadTrailing));
			// ω-N-break-after-eq: `@:fmt(breakAfterLeadOnOverflow('type'))`
			// (today: `HxVarDecl.init`) bundles the lead + RHS through
			// the natural-first-line probe so the `=`-break only fires
			// when the RHS's NATURAL first line still overflows (a
			// NoWrap-pinned RHS), NOT when the RHS wraps its own
			// call-args. The bundled Doc already contains the RHS, so
			// the post-branch unconditional `writeCall` push is skipped.
			final breakAfterEqArg: Null<String> = child.fmtReadString('breakAfterLeadOnOverflow');
			if (breakAfterEqArg != null && !ctx.isTightLead(leadText)) {
				optParts.push(breakAfterLeadOnOverflowWrap(leadText, writeCall, breakAfterEqArg));
				breakAfterEqEmitted = true;
			} else {
				// Trailing space after a non-tight optional lead
				// is split into a literal `_dt(leadText)` plus an
				// `_dop(' ')`. The optional space is dropped by
				// the renderer when the value emits a leading
				// hardline (e.g. `var x = {…}` with
				// `leftCurly=Next` on the object literal),
				// producing `var x =\n{…}` cleanly. For all
				// other values the rendering is byte-identical
				// to the pre-slice `_dt(leadText + ' ')` path.
				optParts.push(macro _dt($v{leadText}));
				optParts.push(macro _dop(' '));
			}
		}
		if (!breakAfterEqEmitted) optParts.push(writeCall);
		// ω-optional-ref-trail: bracket-pair close for an
		// `@:optional @:lead(<open>) @:trail(<close>)` Ref.
		// Pushed INSIDE optParts so the trail rides the
		// `_optVal != null` runtime gate (absent value
		// suppresses both lead and trail). Bracket-tight by
		// design — no separator before the close, mirroring
		// the mandatory-Ref trail emit (`!isOptional` arm
		// below). First consumer: `HxAbstractDecl.
		// underlyingType` (`(T)` group) for the bare-abstract
		// shape.
		if (trailText != null)
			optParts.push(macro _dt($v{trailText}));
		// ω-struct-trailopt-source-track:
		// optional Ref + kw/lead + `@:trailOpt(LIT)` lands here
		// as a parallel push (`trailText` covers `@:trail`,
		// `trailOptText` covers `@:trailOpt`; the two are
		// mutually exclusive in the same field). Gate on
		// `hasStructFieldTrailOptSlot` (trivia mode + bearing)
		// so plain mode and non-bearing rules preserve pre-
		// Phase-4 silent-drop behaviour for now (no slot to
		// consult, no canonical answer either — earlier code
		// simply never reached this trail at all). The
		// `<field>TrailPresent` slot is `null` only on raw->
		// paired upcasts from `Converters.rawToPaired_*`; the
		// `==false` test degrades safely there — null falls
		// through to canonical emit.
		else if (hasStructFieldTrailOptSlot && trailOptText != null)
			optParts.push(macro $structTrailOptAccess == false ? _de() : _dt($v{trailOptText}));
	}

	/**
	 * ω-absent-on: emit the optional-Ref body for a field with no `@:kw` /
	 * `@:lead`. Pushes only the `writeCall` by default, but when
	 * `@:fmt(leftCurly)` is present mirrors the mandatory-Ref runtime ctor
	 * switch (Allman `\n{` for BlockBody, ` ` for ExprBody) and routes
	 * `@:fmt(bodyPolicyForCtor(...))` pairs through `buildBodyPolicyForCtorChain`.
	 * Pushes into `optParts`.
	 */
	private static function emitOptionalAbsentOnBody(
		ctx: RefFieldCtx, child: ShapeNode, optParts: Array<Expr>, refName: String, writeCall: Expr, bareSep: Null<Expr>
	): Void {
		// ω-orphan-prefix-member: `@:fmt(bareRefSepWhenPresent)` opt-in — the
		// mandatory bare-Ref leading separator, emitted only on the present
		// branch (this whole body sits inside the field's `_optVal != null`
		// check). Absent by default, so the OTHER two `@:absentOn` consumers are
		// byte-unchanged: `HxFnExpr.body` reaches this function without the flag,
		// and `HxCatchClause.body` never reaches it at all (its
		// `@:fmt(bodyPolicy('catchBody'))` routes it to `emitOptionalBodyPolicyOnly`
		// — which is also why the caller refuses the flag on that path).
		if (bareSep != null) optParts.push(bareSep);
		final lcSep: Null<Expr> = child.fmtHasFlag('leftCurly') ? leftCurlySeparator(child) : null;
		final lcCtors: Array<String> = lcSep == null ? [] : leftCurlyTargetCtors(ctx.ctorPat, refName);
		// ω-anonfnbody-keep: optional-Ref mirror of the
		// mandatory-Ref `bodyPolicyForCtor` chain (see the
		// `HxFnDecl.body` site below, ω-fnbody-keep). When
		// `@:fmt(bodyPolicyForCtor('<ctor>', '<flagName>'))` pairs
		// are present, route each matched runtime ctor through
		// `bodyPolicyWrap` (which owns the signature→body
		// separator AND the body emission) and fall through to the
		// per-ctor `sep + writeCall` default for every other ctor.
		// Consumer: `HxFnExpr.body` for `('ExprBody',
		// 'anonFunctionBody')` — the bare-expr anon-fn body. The
		// gap-at-parent rationale matches the mandatory-Ref path:
		// the signature→body source-newline gap is consumed by the
		// parent struct's pre-field `skipWs` before this branch's
		// sub-rule probes, so the `Keep`-policy slot must be read
		// at the parent (`<field>BeforeNewline`), NOT inside the
		// kw-less `ExprBody` branch (which grows no slot). Default
		// `anonFunctionBody=Same` reproduces the prior ExprBody
		// `_dt(' ')` cuddle byte-for-byte, so this is inert until
		// the knob is set to `Next` / `Keep`.
		final bodyPolicyForCtorPairs: Array<Array<String>> = child.fmtReadStringArgsAll('bodyPolicyForCtor');
		if (lcSep != null && lcCtors.length > 0) {
			final ctorExpr: Expr = macro Type.enumConstructor(_optVal);
			final sepExpr: Expr = buildLeftCurlySepExpr(ctx, refName, lcCtors, ctorExpr, lcSep);
			if (bodyPolicyForCtorPairs.length > 0) {
				// The `<field>BeforeNewline` Keep-dispatch slot is
				// synthesised only for NON-optional bare Refs
				// (`TriviaTypeSynth.isBareNonFirstRef` excludes
				// `@:optional`). This optional-Ref path therefore has
				// no slot — pass `null`, so `Same` / `Next` work and
				// `Keep` degrades to the no-slot default. Supporting
				// `Keep` here would require extending slot synthesis
				// to optional Refs (a separate, larger change — the
				// `sourceMultilineKeep` wall noted in ω-fnbody-keep).
				final wrapBodyOnSameLineExpr: Null<Expr> = null;
				optParts.push(buildBodyPolicyForCtorChain(
					ctx, bodyPolicyForCtorPairs, ctorExpr, sepExpr, writeCall, macro _optVal, refName, wrapBodyOnSameLineExpr, null
				));
				// (ternary-chain fold lives in buildBodyPolicyForCtorChain)
			} else {
				optParts.push(sepExpr);
				optParts.push(writeCall);
			}
		} else
			optParts.push(writeCall);
	}

	/**
	 * Emit the optional-kw Ref body (the `@:optional @:kw(...)` path, e.g.
	 * `HxIfExpr.elseBranch`). Computes the leading separator (augmented with
	 * captured before-kw trivia in trivia mode) then dispatches the kw→body
	 * emission on `@:fmt(bodyPolicy(...))` (→ `bodyPolicyWrap`),
	 * `@:fmt(nestBodyOnSourceNewline)` (→ source-newline break+nest), or the
	 * default `_dt(kwLead + ' ') + writeCall`. The ω-issue-316 kw-trivia slots
	 * (`<field>AfterKw` / `KwLeading` / `BodyOnSameLine` / `BeforeKwLeading` /
	 * `BeforeKwTrailing`) are read off `value` here in trivia mode. Pushes into
	 * `optParts`.
	 */
	@:access(anyparse.macro.WriterBodyPolicyLowering)
	private static function emitOptionalKwBody(
		ctx: RefFieldCtx, child: ShapeNode, optParts: Array<Expr>, kwLead: String, fieldName: String, bodyPolicyFlag: Null<String>,
		bodyPolicyExprFlag: Null<String>, writeCall: Expr, refName: String, hasElseIf: Bool, elseFieldName: Null<String>,
		prevBodyField: Null<PrevBodyInfo>, typePath: String, prevPadTrailing: Null<Expr>, indentObjArgs: Null<Array<String>>
	): Void {
		// ω-issue-316: in Trivia mode, `@:optional @:kw(...)` Ref
		// children grow per-parent sibling slots `<field>AfterKw`
		// / `<field>KwLeading` holding captured trivia from the
		// gap between the kw and the body. Read them off `value`
		// (the parent struct) and forward to `bodyPolicyWrap`
		// which injects them into the kw→body separator.
		final useTriviaGap: Bool = ctx.ctx.trivia;
		final afterKwExpr: Null<Expr> = useTriviaGap ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.AFTER_KW_SUFFIX),
			pos: Context.currentPos()
		} : null;
		final kwLeadingExpr: Null<Expr> = useTriviaGap ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.KW_LEADING_SUFFIX),
			pos: Context.currentPos()
		} : null;
		// ω-keep-policy: `<field>BodyOnSameLine:Bool` drives the
		// `Keep` branch of `bodyPolicyWrap` / policySwitch.
		final bodyOnSameLineExpr: Null<Expr> = useTriviaGap ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BODY_ON_SAME_LINE_SUFFIX),
			pos: Context.currentPos()
		} : null;
		final sepWithBeforeKwTrailingExpr: Expr = beforeKwSeparator(
			ctx.fieldSep, useTriviaGap, fieldName, child, prevBodyField, typePath, prevPadTrailing
		);
		optParts.push(sepWithBeforeKwTrailingExpr);
		if (bodyPolicyFlag != null) {
			optParts.push(macro _dt($v{kwLead}));
			// ω-expression-if-with-blocks: sister read of
			// `@:fmt(inlineBlockBodyIfFlag(...))` on optional-kw
			// body field path (e.g. `HxIfExpr.elseBranch`'s
			// `@:optional @:kw('else')` form). Threaded into the
			// same `bodyPolicyWrap` plumbing as the bare-Ref path
			// below; the runtime override fires at writeCall-swap
			// time before policy dispatch.
			final inlineBlockBodyArgs: Null<Array<String>> = child.fmtReadStringArgs('inlineBlockBodyIfFlag');
			optParts.push(WriterBodyPolicyLowering.bodyPolicyWrap(ctx.bodyPolicy, {
				flagName: bodyPolicyFlag,
				exprFlagName: bodyPolicyExprFlag,
				writeCall: writeCall,
				bodyValueExpr: macro _optVal,
				bodyTypePath: refName,
				hasElseIf: hasElseIf,
				elseFieldName: elseFieldName,
				afterKwExpr: afterKwExpr,
				kwLeadingExpr: kwLeadingExpr,
				bodyOnSameLineExpr: bodyOnSameLineExpr,
				indentObjArgs: indentObjArgs,
				inlineBlockBodyArgs: inlineBlockBodyArgs,
				strictFitLine: child.fmtHasFlag(WriterLowering.STRICT_FIT_LINE_BODY),
				bracketBodyGlueArgs: child.fmtReadStringArgs(WriterLowering.BRACKET_BODY_GLUE),
				arrowValueIfSite: child.fmtHasFlag(WriterLowering.ARROW_VALUE_IF_SITE),
				elseIfCommentReflow: child.fmtHasFlag('elseIfCommentReflow'),
				elseSwitchArgs: child.fmtReadStringArgs('elseSwitch')
			}));
		} else if (child.fmtHasFlag('nestBodyOnSourceNewline') && bodyOnSameLineExpr != null) {
			// ω-cond-comp-expr-body-nest: optional-kw-Ref body
			// break+nest based on the captured `<f>BodyOnSameLine`
			// slot. When the slot is false (source had a newline
			// between the kw and the body) the wrapper emits
			// `Nest(_cols, [hardline, body])` so the body sits
			// one indent step deeper than the kw line. When true
			// the wrapper emits `' ' + body` for inline single-
			// line shape. Currently consumed by `HxConditionalExpr.elseExpr`.
			optParts.push(macro _dt($v{kwLead}));
			final invertedSignal: Expr = macro !$bodyOnSameLineExpr;
			optParts.push(nestBodyOnSourceNewlineWrap(writeCall, invertedSignal));
		} else {
			optParts.push(macro _dt($v{kwLead + ' '}));
			optParts.push(writeCall);
		}
	}

	/**
	 * ω-absent-on-bodypolicy: emit the optional-Ref body for a field with no
	 * `@:kw` / `@:lead` but `@:fmt(bodyPolicy(...))` — mirrors the mandatory-Ref
	 * `bodyPolicyWrap` path so the `)`→body separator survives; the surrounding
	 * `_optVal != null` guard drops the absent case to `_de()`. First consumer:
	 * `HxCatchClause.body` (bodyless `catch (e:T)`). Pushes into `optParts`.
	 *
	 */
	@:access(anyparse.macro.WriterBodyPolicyLowering)
	private static function emitOptionalBodyPolicyOnly(
		ctx: RefFieldCtx, child: ShapeNode, optParts: Array<Expr>, bodyPolicyFlag: String, bodyPolicyExprFlag: Null<String>,
		writeCall: Expr, refName: String, hasElseIf: Bool, elseFieldName: Null<String>, indentObjArgs: Null<Array<String>>,
		prevTrailFieldName: Null<String>
	): Void {
		final inlineBlockBodyArgs: Null<Array<String>> = child.fmtReadStringArgs('inlineBlockBodyIfFlag');
		// Head -> body seam, mirror of the mandatory-Ref path in
		// `emitBodyPolicyBareRef`: when the preceding sibling is a Ref with
		// `@:trail` in trivia mode, its `<field>AfterTrail` slot holds the
		// same-line comment cuddled to that closer. `HxCatchClause.body` is
		// the `@:optional` twin of `HxIfStmt.thenBody`, so without this the
		// comment in `} catch (e:T) // c` + newline `{` was captured and
		// then silently dropped.
		final afterTrailExpr: Null<Expr> = prevTrailFieldName == null ? null : {
			expr: EField(macro value, prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX),
			pos: Context.currentPos()
		};
		optParts.push(WriterBodyPolicyLowering.bodyPolicyWrap(ctx.bodyPolicy, {
			flagName: bodyPolicyFlag,
			exprFlagName: bodyPolicyExprFlag,
			writeCall: writeCall,
			bodyValueExpr: macro _optVal,
			bodyTypePath: refName,
			hasElseIf: hasElseIf,
			elseFieldName: elseFieldName,
			afterTrailExpr: afterTrailExpr,
			indentObjArgs: indentObjArgs,
			inlineBlockBodyArgs: inlineBlockBodyArgs,
			strictFitLine: child.fmtHasFlag(WriterLowering.STRICT_FIT_LINE_BODY),
			bracketBodyGlueArgs: child.fmtReadStringArgs(WriterLowering.BRACKET_BODY_GLUE),
			constructFitBody: child.fmtHasFlag('constructFitBody'),
			elseSwitchArgs: child.fmtReadStringArgs('elseSwitch')
		}));
	}

	/**
	 * The `opt` argument expression for an optional-Ref field's descendant writer: the
	 * opt-fanout wraps composed in declaration order, the `arrowValueIfBlockOpt` step,
	 * the `propagateElseIfBranch` runtime-ctor switch, and the else-chain suppress
	 * wrap.
	 */
	@:access(anyparse.macro.WriterArrowValueIfLowering)
	private static function optionalRefOptArgExpr(ctx: RefFieldCtx, child: ShapeNode, refName: String, elseChainSuppressExpr: Expr): Expr {
		// ω-issue-423-mech-a / ω-anonfunction-empty-curly /
		// ω-expressionif-collapse: opt-fanout flags wrapping the descendant
		// writer's `opt` arg in `_setExprPosition` / `_setAnonFnBody` /
		// `_setValueIfBranch`.
		final propagateExpr: Bool = child.fmtHasFlag('propagateExprPosition');
		final propagateAnonFn: Bool = child.fmtHasFlag('propagateAnonFnContext');
		final propagateValueIfBranch: Bool = child.fmtHasFlag('propagateValueIfBranch');
		// ω-elseif-body-break: `@:fmt(propagateElseIfBranch)` on `HxIfStmt.elseBody`
		// flags the else-branch recursion's opt with `_inElseIfBranch` — but ONLY
		// when the else-branch runtime ctor is `IfStmt` (an `else if`), matched via
		// the same trivia-aware ctor pattern as the elseIf glue. A block / simple
		// else-branch leaves the flag untouched, so a fitting `if` nested inside an
		// else-block body still keeps its own body inline.
		final propagateElseIfBranch: Bool = child.fmtHasFlag('propagateElseIfBranch');
		var e: Expr = macro opt;
		if (propagateExpr) e = macro _setExprPosition($e, opt);
		if (propagateAnonFn) e = macro _setAnonFnBody($e, opt);
		if (propagateValueIfBranch) e = macro _setValueIfBranch($e, opt);
		e = WriterArrowValueIfLowering.arrowValueIfBlockOpt(child, e);
		if (propagateElseIfBranch) {
			final ifPat: Null<Expr> = findCtorPattern(ctx.ctorPat, refName, 'IfStmt');
			if (ifPat != null) {
				// else-if -> set; a non-if else-branch (block / simple stmt) must
				// CLEAR the flag it may have inherited from a preceding chain link
				// (`if {} else if {} else { … }`) — the block is not an else-branch-if.
				final setExpr: Expr = macro _setElseIfBranch($e, opt);
				final clearExpr: Expr = macro _clearElseIfBranch($e, opt);
				e = {
					expr: ESwitch(macro _optVal, [{ values: [ifPat], expr: setExpr, guard: null }], clearExpr),
					pos: Context.currentPos()
				};
			}
		}
		return wrapElseChainSuppress(ctx.braceSym, e, child, refName, elseChainSuppressExpr);
	}

	/**
	 * Finalise a non-Star struct field after its body emission: push the trail
	 * (`emitMandatoryRefTrail`), fold the mandatory-Ref `@:fmt(padTrailing)` pad
	 * and the optional-Ref transparent guard into `prevPadTrailing`, publish the
	 * `@:trail` field name for the next sibling's `AfterTrail` slot, and splice a
	 * span-mode condWrap end. Pushes into `parts`; returns the recomputed loop
	 * accumulators (`prevBodyField` / `prevPadTrailing` / `prevTrailFieldName`).
	 * The caller resets `prevAnyStarNonEmpty` to null and `isFirstField` to false.
	 * `isStar` is always false here (Star fields
	 * early-continue before this block).
	 */
	private static function finalizeNonStarField(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, node: ShapeNode, typePath: String, fieldName: String, fieldAccess: Expr,
		isOptional: Bool, trailText: Null<String>, trailOptText: Null<String>, hasCondWrap: Bool, hasCondWrapEnd: Bool,
		hasStructFieldTrailOptSlot: Bool, structTrailOptAccess: Null<Expr>, thisPadTrailing: Null<Expr>, prevPadTrailing: Null<Expr>,
		justWrappedBody: Null<PrevBodyInfo>, spanInfo: Null<{
			startIdx: Int,
			endIdx: Int,
			leadText: String,
			trailText: String,
			knob: String
		}>,
		spanStartPartsIdx: Int
	): { prevBodyField: Null<PrevBodyInfo>, prevPadTrailing: Null<Expr>, prevTrailFieldName: Null<String> } {
		emitMandatoryRefTrail(
			ctx, child, parts, isOptional, trailText, trailOptText, hasCondWrap, hasCondWrapEnd, hasStructFieldTrailOptSlot,
			structTrailOptAccess, fieldAccess, typePath
		);
		// ω-pad-trailing-ref: bare-Ref `@:fmt(padTrailing)` — mandatory Ref
		// always fires, so push a trailing space unconditionally and set the
		// tracker to a constant `true`. (Optional-Ref padTrailing was pushed
		// inside the optParts wrap; Star fields early-continue.)
		final thisPad: Null<Expr> = if (!isOptional && child.fmtHasFlag('padTrailing')) {
			parts.push(padTrailingDoc(ctx.fieldSep, node, child, typePath));
			macro true;
		} else
			thisPadTrailing;
		// `thisTransparent` is null for mandatory bare Ref (always emits visible
		// content), `$fieldAccess == null` for optional Ref (transparent when
		// absent — lets a prev pad signal propagate across an absent middle field).
		final thisTransparent: Null<Expr> = isOptional ? (macro $fieldAccess == null) : null;
		// ω-trivia-after-trail: a mandatory Ref with `@:trail` in trivia-bearing
		// mode publishes its name so the NEXT field's `bodyPolicyWrap` can read
		// `value.<name>AfterTrail`. Optional Refs with `@:lead + @:trail`
		// also publish (mirror of the parser-side `hasAfterTrailSlot` extension).
		final newPrevTrailFieldName: Null<String> = trailText != null && ctx.ctx.trivia && ctx.isTriviaBearing(typePath) ? fieldName : null;
		// ω-condwrap-forstmt: end of span-mode iteration — splice the accumulated
		// cond-span Doc parts into a single `WrapList.emitCondition`.
		if (hasCondWrapEnd && spanInfo != null)
			spliceCondWrapEnd(parts, spanStartPartsIdx, spanInfo.knob, spanInfo.leadText, spanInfo.trailText);
		return {
			prevBodyField: justWrappedBody,
			prevPadTrailing: composePadTrailing(prevPadTrailing, thisPad, thisTransparent),
			prevTrailFieldName: newPrevTrailFieldName
		};
	}

	/**
	 * Emit a mandatory-Ref field's trail. Pushes the `@:trail` literal (routed
	 * through `whitespacePolicyTrail` for the catch / switch / while
	 * cond-parens-inside-close knobs) and, in trivia-bearing mode, the
	 * `@:trailOpt(LIT)` source-presence gate (`<field>TrailPresent` slot: `false`
	 * -> `_de()`, else emit). Both are skipped inside a condWrap span. Pushes into
	 * `parts`.
	 */
	private static function emitMandatoryRefTrail(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, isOptional: Bool, trailText: Null<String>, trailOptText: Null<String>,
		hasCondWrap: Bool, hasCondWrapEnd: Bool, hasStructFieldTrailOptSlot: Bool, structTrailOptAccess: Null<Expr>, fieldAccess: Expr,
		typePath: String
	): Void {
		// ω-before-trail: a BLOCK comment the source wrote between this field's
		// last token and the trail literal (`switch (subject /* c *\/)`). Emitted
		// BEFORE the trail dispatch below so it also survives the
		// `switchSubjectParensStrip` arm, which drops the close literal entirely.
		// A missing slot / null value contributes nothing. A `@:fmt(condWrap)`
		// field does not emit its trail here at all — `emitCondWrapSingleRef`
		// owns both parens, so it appends the comment to the condition Doc
		// itself; emitting here too would print it twice.
		final beforeTrailAccess: Null<Expr> = hasCondWrap || hasCondWrapEnd
			? null
			: beforeTrailSlotAccess(ctx, child, fieldAccess, isOptional, trailText, typePath);
		if (beforeTrailAccess != null) parts.push(macro {
			final _bt: Null<String> = $beforeTrailAccess;
			_bt == null ? _de() : trailingCommentDocVerbatim(_bt, opt);
		});
		// ω-condition-parens (Stage C): `@:fmt(catchParensInsideClose)` on
		// a mandatory-Ref `@:trail(')')` field routes the close literal
		// through `opt.catchParensInsideClose` (`Before`/`Both` → inner
		// ` )` pad). No flag → tight `_dt(trailText)` byte-identical.
		if (!isOptional && trailText != null && !hasCondWrap && !hasCondWrapEnd) {
			final trailDoc: Expr = whitespacePolicyTrail(child, trailText, [
				'catchParensInsideClose',
				'switchCondParensInsideClose',
				'whileCondParensInsideClose'
			]);
			// ω-switch-subject-parens: drop the switch-subject close `)` under the
			// same condition as the open `(` (see switchParensStripCond); nothing
			// replaces it — the cases block `{` follows directly.
			if (child.fmtHasFlag('switchSubjectParensStrip')) {
				final cond: Expr = switchParensStripCond(fieldAccess);
				parts.push(macro $cond ? _de() : $trailDoc);
			} else
				parts.push(trailDoc);
		}
		// ω-struct-trailopt-source-track: mandatory-
		// Ref `@:trailOpt(LIT)` field gates the trail emission on the
		// synth slot `<field>TrailPresent:Null<Bool>` so the writer
		// preserves source presence (true -> `;`, false -> ``) rather
		// than always re-emitting the canonical trail. Gate on
		// `hasStructFieldTrailOptSlot` (trivia mode + bearing) so plain
		// mode and non-bearing rules preserve pre-Phase-4 silent-drop
		// behaviour for now. `null` on `<field>TrailPresent` is reserved
		// for raw->paired upcasts from `Converters.rawToPaired_*` and
		// falls through to canonical emit via the `==false` test.
		// omega-ssb-trailopt-drop: a field whose braces may be dropped
		// (`@:fmt(dropSingleStmtBraces)` — `HxIfStmt.thenBody` / `HxForStmt.body` /
		// `HxWhileStmt.body` / `HxDoWhileStmt.body`) never re-emits this slot: a
		// STATEMENT owns its own terminator (`if (c) g();` puts the `;` inside the
		// inner `ExprStmt`), so the slot can only ever hold a REDUNDANT `;`
		// (`for (…) { x; };`). Canonicalising it away removes the `for (…) x;;`
		// hazard at the root instead of defending against it with a keep-braces
		// gate, and matches what the optional `elseBody` path has always done.
		if (
			!hasStructFieldTrailOptSlot || isOptional || hasCondWrap || hasCondWrapEnd || trailOptText == null
			|| child.fmtHasFlag('dropSingleStmtBraces')
		)
			return;
		final sourcePresent: Expr = macro $structTrailOptAccess == false ? _de() : _dt($v{trailOptText});
		final emit: Expr = semicolonBeforeSiblingWrap(ctx, child, trailOptText, fieldAccess, sourcePresent) ?? sourcePresent;
		parts.push(valueBraceSymmetryTrailDrop(ctx.braceSym, child, fieldAccess, emit));
	}

	/**
	 * omega-semi-before-else: `@:fmt(semicolonBeforeSibling('<field>'))` routes a mandatory-Ref
	 * `@:trailOpt(LIT)` slot through `opt.semicolonBeforeElse` INSTEAD of plain source presence,
	 * but only for the shape where the named sibling field is present.
	 *
	 * The one consumer is `HxIfExpr.thenBranch`, whose slot holds the `;` Haxe accepts before an
	 * `else` (`final x = if (c) a; else b;`). That `;` is inert -- verified against the compiler,
	 * both `if (c) var x = 1 else var y = 2` and a semicolon-less value-`if` chain compile -- so
	 * `Never` may drop it. The sibling gate is not a refinement but the correctness condition:
	 * with NO `else`, the same slot can hold the terminator of the ENCLOSING statement, which the
	 * grammar has no other place to park, and dropping it would emit code that does not compile.
	 *
	 * Distinct from `optionalSemicolon` (the `}`-terminated statement's own `;`) because a config
	 * legitimately wants opposite answers for the two: TM writes every statement terminator and
	 * no `;` before `else`. Returns null -- caller keeps plain source presence -- for every field
	 * without the meta, so the whole path is byte-inert unless a grammar opts in.
	 */
	private static function semicolonBeforeSiblingWrap(
		ctx: RefFieldCtx, child: ShapeNode, trailOptText: String, fieldAccess: Expr, sourcePresent: Expr
	): Null<Expr> {
		final args: Null<Array<String>> = child.fmtReadStringArgs('semicolonBeforeSibling');
		if (args == null) return null;
		if (args.length != 1 && args.length != 2)
			Context.fatalError(
				'WriterLowering: @:fmt(semicolonBeforeSibling) expects 1 or 2 string args '
				+ '(siblingField, ?sameLineFlag), got ${args.length}',
				Context.currentPos()
			);
		final siblingAccess: Null<Expr> = switch fieldAccess.expr {
			case EField(base, _): { expr: EField(base, args[0]), pos: fieldAccess.pos };
			case _: null;
		};
		if (siblingAccess == null) return null;
		final policyDispatch: Expr = macro switch opt.semicolonBeforeElse {
			case anyparse.format.OptionalSemicolon.Never:
				_sbeSibling ? _de() : $sourcePresent;
			case anyparse.format.OptionalSemicolon.Always:
				_sbeSibling ? _dt($v{trailOptText}) : $sourcePresent;
			case _:
				$sourcePresent;
		};
		// omega-bracket-body-glue CLOSE side: a branch value the knob hugs to its head
		// (`if (c) [`) has to close the same way (`] else`), and `];` cannot cuddle. So
		// when the glue fires AND a sibling follows, the slot is dropped whatever
		// `semicolonBeforeElse` says — the knob is the narrower, explicit statement.
		final glueTest: Null<Expr> = buildBracketBodyGlueTest(
			ctx.ctorPat, child.fmtReadStringArgs(WriterLowering.BRACKET_BODY_GLUE), child.annotations[AnnotationKeys.BASE_REF], fieldAccess
		);
		// ω-same-on-block CLOSE side, the curly twin of the line above: when the gap
		// policy is `SameOnBlock` and this branch value IS a curly block, the `}` and
		// the sibling keyword join, and `}; else` is not a join — the `;` goes with
		// the break it used to justify. Gated on `_sbeSibling`, so an else-less
		// value-`if` still carries the enclosing statement's terminator. This is what
		// the STATEMENT twin has always emitted for the same source (`}; else {` →
		// `} else {`); leaving the `;` here would be the very "one construct, two
		// layouts" split the policy exists to close.
		final curlyTest: Null<Expr> = buildCurlyBlockCuddleTest(
			ctx.ctorPat, args.length == 2 ? args[1] : null, child.annotations[AnnotationKeys.BASE_REF], fieldAccess
		);
		final dropTest: Null<Expr> = if (glueTest == null)
			curlyTest
		else if (curlyTest == null)
			glueTest
		else
			macro ($glueTest || $curlyTest);
		final emit: Expr = dropTest == null ? policyDispatch : macro (_sbeSibling && $dropTest ? _de() : $policyDispatch);
		return macro {
			final _sbeSibling: Bool = $siblingAccess != null;
			$emit;
		};
	}

	/**
	 * Emit a bare mandatory Ref struct field (the `case Ref` arm of
	 * `lowerStruct`). Builds the descendant writeCall, then dispatches the body
	 * emission to `emitBodyPolicyBareRef` (when a bare-Ref `@:fmt(bodyPolicy)`
	 * fires) or `emitBareRefNonBodyPolicy` (leftCurly / bodyBreak / non-first-body
	 * / condWrap / arrowBodyLineWrap), and records the bare-Ref body tracker.
	 * Pushes into `parts`; returns the `justWrappedBody` body-info (or null) and
	 * the `prevBareRefBody` tracker.
	 */
	private static function emitMandatoryRefField(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, typePath: String, fieldAccess: Expr, fieldName: String,
		bodyPolicyFlag: Null<String>, bodyPolicyExprFlag: Null<String>, kwLead: Null<String>, leadText: Null<String>, isRaw: Bool,
		isFirstField: Bool, hasElseIf: Bool, elseFieldName: Null<String>, fallbackFlag: Null<String>, hasCondWrap: Bool,
		condWrapArgs: Null<Array<String>>, spanInfoPresent: Bool, trailText: Null<String>, prevTrailFieldName: Null<String>,
		prevAnyStarNonEmpty: Null<Expr>, prevPadTrailing: Null<Expr>, condFitGroup: Bool
	): { justWrappedBody: Null<PrevBodyInfo>, prevBareRefBody: PrevBodyInfo } {
		final refName: String = child.annotations[AnnotationKeys.BASE_REF];
		final writeFn: String = ctx.writeFnFor(refName);
		// (opt-fanout / writeCall assembly lives in buildMandatoryRefWriteCall.)
		final indentObjArgs: Null<Array<String>> = child.fmtReadStringArgs('indentValueIfCtor');
		final deBraced = deBraceBodyAccess(ctx.braceSym, child, fieldAccess, elseFieldName);
		final effAccess: Expr = deBraced.effAccess;
		final ssbSuppressCond: Null<Expr> = deBraced.ssbSuppressCond;
		final ssbTrailCommentExpr: Null<Expr> = deBraced.ssbTrailCommentExpr;
		final writeCall: Expr = buildMandatoryRefWriteCall(
			ctx, child, effAccess, typePath, writeFn, bodyPolicyFlag, indentObjArgs, ssbSuppressCond
		);
		// bodyPolicy on a first field: the parent enum-branch Case 3 strips its
		// kwLead trailing space so the separator here is the sole transition
		// token. Non-first-field case (HxIfStmt.thenBody after cond's `)` trail):
		// the trail emits the token literally and bodyPolicyWrap replaces the
		// default ` ` separator.
		final justWrappedBody: Null<PrevBodyInfo> = if (bodyPolicyFlag != null && kwLead == null && leadText == null && !isRaw)
			// Bare-Ref body with @:fmt(bodyPolicy(...)) — see emitBodyPolicyBareRef.
			emitBodyPolicyBareRef(
				ctx, child, parts, prevTrailFieldName, isFirstField, fieldName, bodyPolicyFlag, bodyPolicyExprFlag, writeCall, effAccess,
				refName, hasElseIf, elseFieldName, indentObjArgs, fallbackFlag, condFitGroup, ssbTrailCommentExpr
			);
		else {
			// Bare-Ref body without @:fmt(bodyPolicy) — leftCurly / bodyBreak /
			// bareBodyBreaks / non-first-body / condWrap / arrowBodyLineWrap
			// dispatch lives in emitBareRefNonBodyPolicy.
			emitBareRefNonBodyPolicy(
				ctx, child, parts, refName, fieldName, typePath, effAccess, writeCall, isFirstField, isRaw, kwLead, leadText, hasCondWrap,
				condWrapArgs, spanInfoPresent, trailText, prevAnyStarNonEmpty, prevPadTrailing
			);
			null;
		};
		// ω-close-trailing-alt / ω-block-shape-aware: track ANY bare-Ref body so
		// the next field can react to its runtime closeTrailing slot; block-shape
		// consumers degrade to a no-op when the target has no block ctors.
		return { justWrappedBody: justWrappedBody, prevBareRefBody: { access: effAccess, typePath: refName } };
	}

	/**
	 * Emit a bare-Ref body field carrying `@:fmt(bodyPolicy(...))` (kw-less,
	 * lead-less, non-raw — the `case Ref` non-first / first-field body site).
	 * Reads the kwPolicy / after-trail / before-leading / before-newline /
	 * policy-override / allman / inline-block companion metas, threads them into a
	 * single `bodyPolicyWrap`, pushes onto `parts`, and returns the
	 * `justWrappedBody` PrevBodyInfo.
	 */
	@:access(anyparse.macro.WriterBodyPolicyLowering)
	private static function emitBodyPolicyBareRef(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, prevTrailFieldName: Null<String>, isFirstField: Bool, fieldName: String,
		bodyPolicyFlag: String, bodyPolicyExprFlag: Null<String>, writeCall: Expr, fieldAccess: Expr, refName: String, hasElseIf: Bool,
		elseFieldName: Null<String>, indentObjArgs: Null<Array<String>>, fallbackFlag: Null<String>, condFitGroup: Bool,
		ssbTrailCommentExpr: Null<Expr>
	): PrevBodyInfo {
		final kwPolicyFlag: Null<String> = child.fmtReadString('kwPolicy');
		// ω-trivia-after-trail: when the IMMEDIATELY preceding
		// sibling is a mandatory Ref carrying `@:trail` in
		// trivia-bearing mode, read its synth slot
		// `value.<priorField>AfterTrail:Null<String>` and
		// thread it into `bodyPolicyWrap`. The wrap prepends
		// ` //<comment>` (cuddled to the prior trail token) +
		// forces the body onto its own line at +cols indent
		// regardless of the runtime bodyPolicy. Currently
		// fired by `HxIfStmt.thenBody` after `cond`'s `)`
		// trail. Plain mode and non-bearing rules see a null
		// `prevTrailFieldName` and skip the threading.
		final afterTrailExpr: Null<Expr> = prevTrailFieldName == null ? null : {
			expr: EField(macro value, prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-556-then-body-leading-comment: the bare non-first Ref
		// body grows a `<field>BeforeLeading:Array<String>` slot
		// (`isBareNonFirstRef`, same host as the BeforeNewline
		// signal below). Thread it into `bodyPolicyWrap` so own-line
		// comments captured between the preceding token (the cond's
		// `)` trail / the prior body terminator) and the body's
		// first token survive round-trip. The kw-led else-body path
		// already has this via `kwLeadingExpr`; this closes the
		// bare-Ref then-body asymmetry. Gated on the same
		// `(!isFirstField || firstFieldNlOptIn)` predicate the parser
		// uses for `hasBeforeLeadingSlot`; null off the slot path →
		// byte-inert. (`firstFieldNlOptIn` is declared just below
		// alongside `bodyOnSameLineExpr` — both share the gate.)
		// Slice ω-expr-body-keep: `BodyPolicy.Keep` on bare-Ref
		// body fields reads the source-shape signal from the
		// existing `<field>BeforeNewline:Bool` synth slot
		// (created by `isBareNonFirstRef` in TriviaTypeSynth) —
		// `BodyOnSameLine` is its inverse, no separate slot
		// needed. First-field bodyPolicy paths (Case 3) have no
		// BeforeNewline slot, so the !isFirstField gate keeps
		// the pre-slice null fallback there. Without ctx.trivia
		// the slot doesn't exist either; null falls back to the
		// `Same` layout inside `bodyPolicyWrap` (matches the
		// pre-slice plain-mode behaviour for Keep).
		//
		// ω-untyped-keep-trybody: `@:fmt(beforeNewlineSlotFirst)`
		// opt-in extends slot reading to first-field bodyPolicy
		// paths. Pairs with parent Alt-branch
		// `@:fmt(forwardNewlineForBody)` (Case 3 omits post-kw
		// `skipWs`) and `TriviaTypeSynth.isBareNonFirstRef` /
		// `StructSeqLowering.computeBeforeSlots` first-field allowances.
		// Currently consumed by `HxTryCatchStmt.body` for
		// `untypedBody=Keep` source-shape preservation.
		final firstFieldNlOptIn: Bool = isFirstField && child.fmtHasFlag(WriterLowering.BEFORE_NEWLINE_SLOT_FIRST);
		final bodyOnSameLineExpr: Null<Expr> = ctx.ctx.trivia && (!isFirstField || firstFieldNlOptIn)
			? beforeNewlineNotAccess(fieldName)
			: null;
		// ω-556-then-body-leading-comment: own-line leading-comment
		// slot, same gate as `bodyOnSameLineExpr` (the BeforeNewline
		// sibling shares the `isBareNonFirstRef` host).
		final beforeLeadingExpr: Null<Expr> =
			ctx.ctx.trivia && (!isFirstField || firstFieldNlOptIn) ? beforeLeadingAccess(fieldName) : null;
		// ω-untyped-body-stmt-override: forward all
		// `@:fmt(bodyPolicyOverride('<ctor>', '<flag>'))`
		// entries on this field to bodyPolicyWrap. Each entry
		// flips the parent's own bodyPolicy flag to the named
		// replacement when the body's runtime ctor matches —
		// e.g. `HxTryCatchStmt.body` reads `untypedBody`
		// instead of `tryBody` when the value is
		// `HxStatement.UntypedBlockStmt`. Multiple entries
		// cascade through a runtime ternary chain.
		final policyOverrides: Array<Array<String>> = child.fmtReadStringArgsAll('bodyPolicyOverride');
		// ω-issue-168: `@:fmt(bodyAllmanIndentForCtor('<ctor>',
		// '<optField>', '<lcField>'))` runtime-overrides the
		// policy-decided layout when the body's runtime ctor
		// matches `<ctor>` AND `opt.<optField>` is true AND
		// `opt.<lcField>` is `Next` AND the body's writeCall
		// emits internal hardlines (multi-line). The override
		// places the body in Allman position with extra
		// `+cols` indent on contents, regardless of Keep/Same/
		// Next/FitLine policy. Currently consumed by
		// `HxForExpr.body` for the `[for (x in xs) {<multi>}]`
		// shape; HxIfExpr.thenBranch deliberately does NOT
		// carry this meta because fork keeps `if (cond) {`
		// cuddled.
		final bodyAllmanIndentArgs: Null<Array<String>> = child.fmtReadStringArgs('bodyAllmanIndentForCtor');
		// ω-expression-if-with-blocks: `@:fmt(inlineBlockBodyIfFlag(
		// '<flagName>'))` reads `opt.<flagName>:Bool` at runtime;
		// when true AND body's runtime ctor is `BlockExpr`, wrap
		// the body's writeCall result in `D.flatten(…)` to collapse
		// `{<hardline>stmt;<hardline>}` to `{stmt;}` regardless of
		// width. Mirrors fork's `expressionIfWithBlocks` knob
		// (`MarkSameLine.markBody` with `includeBrOpen=true` →
		// `markBlockBody` Same-policy collapse). Currently consumed
		// by `HxIfExpr.thenBranch` / `elseBranch`. Non-BlockExpr
		// bodies and flag-false fall through to the regular policy
		// cascade.
		final inlineBlockBodyArgs: Null<Array<String>> = child.fmtReadStringArgs('inlineBlockBodyIfFlag');
		// ω-loop-body-if-else-next: `@:fmt(loopBodyIfElseNext('<optField>',
		// '<ifCtor>', '<elseField>'[, '<wrapperCtor>']))` on a LOOP body field
		// forwards the names to `bodyPolicyWrap`, which substitutes
		// `BodyPolicy.Next` for the chosen placement when the knob is on and the
		// body is an `if` that owns an `else`. Consumed by `HxForStmt.body` /
		// `HxWhileStmt.body` / `HxDoWhileStmt.body`; the optional fourth name is one
		// enum ctor to unwrap first, which is what the do-while body needs.
		final loopBodyIfElseArgs: Null<Array<String>> = child.fmtReadStringArgs('loopBodyIfElseNext');
		// omega-else-switch: read ONCE - the body wrap decides the head glue from it and the
		// close-side verdict below is built from the same names, so the two cannot drift.
		final elseSwitchArgs: Null<Array<String>> = child.fmtReadStringArgs('elseSwitch');
		parts.push(WriterBodyPolicyLowering.bodyPolicyWrap(ctx.bodyPolicy, {
			flagName: bodyPolicyFlag,
			exprFlagName: bodyPolicyExprFlag,
			writeCall: writeCall,
			bodyValueExpr: fieldAccess,
			bodyTypePath: refName,
			hasElseIf: hasElseIf,
			elseFieldName: elseFieldName,
			bodyOnSameLineExpr: bodyOnSameLineExpr,
			kwPolicyFlagName: kwPolicyFlag,
			afterTrailExpr: afterTrailExpr,
			beforeLeadingExpr: beforeLeadingExpr,
			indentObjArgs: indentObjArgs,
			policyOverrides: policyOverrides,
			bodyAllmanIndentArgs: bodyAllmanIndentArgs,
			fallbackFlagName: fallbackFlag,
			inlineBlockBodyArgs: inlineBlockBodyArgs,
			strictFitLine: child.fmtHasFlag(WriterLowering.STRICT_FIT_LINE_BODY),
			bracketBodyGlueArgs: child.fmtReadStringArgs(WriterLowering.BRACKET_BODY_GLUE),
			condFitGroup: condFitGroup,
			constructFitBody: child.fmtHasFlag('constructFitBody'),
			ssbTrailCommentExpr: ssbTrailCommentExpr,
			arrowValueIfSite: child.fmtHasFlag(WriterLowering.ARROW_VALUE_IF_SITE),
			loopBodyIfElseArgs: loopBodyIfElseArgs,
			elseSwitchArgs: elseSwitchArgs
		}));
		// omega-else-switch CLOSE side: the next field's gap gets the glue verdict
		// from HERE, where the field's own meta and its own comment slots are in
		// scope. A comment captured between the head and this body forces the body
		// onto its own line whatever the policy said (`wrapBodyAfterTrail`), so a
		// following keyword must not cuddle a close that never moved up; and a
		// field carrying no `@:fmt(elseSwitch(...))` never glues at all, however
		// the keyword field beside it is annotated. Null when the knob is absent -
		// every existing gap keeps its bytes.
		final glueCtorTest: Null<Expr> = buildElseSwitchGlueTest(ctx.ctorPat, elseSwitchArgs, refName, fieldAccess);
		final headGlue: Null<Expr> = if (glueCtorTest == null || (afterTrailExpr == null && beforeLeadingExpr == null))
			glueCtorTest;
		else {
			final atRt: Expr = afterTrailExpr ?? macro null;
			final blRt: Expr = beforeLeadingExpr ?? macro ([]: Array<String>);
			macro ($glueCtorTest && $atRt == null && $blRt.length == 0);
		}
		return { access: fieldAccess, typePath: refName, headGlue: headGlue };
	}

	/**
	 * Emit a bare mandatory Ref body field (no `@:kw` / `@:lead`) that carries
	 * no `@:fmt(bodyPolicy(...))` — the non-bodyPolicy dispatch. Routes through
	 * `@:fmt(leftCurly)` runtime BracePlacement ctor switch (+ optional
	 * `bodyPolicyForCtor` chain), `@:fmt(bodyBreak)` / `@:fmt(bareBodyBreaks)`
	 * shape wraps, the bare-Ref non-first-body cascade, span-mode / single-Ref
	 * `@:fmt(condWrap)`, the `@:fmt(arrowBodyLineWrap)` line-fit break, or the
	 * default bare writeCall. Pushes into `parts`.
	 */
	private static function emitBareRefNonBodyPolicy(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, refName: String, fieldName: String, typePath: String, fieldAccess: Expr,
		writeCall: Expr, isFirstField: Bool, isRaw: Bool, kwLead: Null<String>, leadText: Null<String>, hasCondWrap: Bool,
		condWrapArgs: Null<Array<String>>, spanInfoPresent: Bool, trailText: Null<String>, prevAnyStarNonEmpty: Null<Expr>,
		prevPadTrailing: Null<Expr>
	): Void {
		// `@:fmt(leftCurly)` on a bare Ref field (e.g.
		// `HxFnDecl.body:HxFnBody`) routes the inter-field
		// space through the runtime BracePlacement switch —
		// same separator the Star path uses when the `{`
		// open lives on the field. The Ref points at an
		// enum (BlockBody / NoBody); the separator must be
		// suppressed when the runtime branch is the
		// `;`-terminated NoBody — emitting `_dt(' ')` ahead
		// of `;` would round-trip as `function f():Void ;`.
		// Detect the brace-bearing branch by `@:lead('{')`
		// at macro time; gate emission on enum-ctor identity
		// at runtime via `Type.enumConstructor`.
		final lcSep: Null<Expr> = child.fmtHasFlag('leftCurly') ? leftCurlySeparator(child) : null;
		final lcCtors: Array<String> = lcSep == null ? [] : leftCurlyTargetCtors(ctx.ctorPat, refName);
		final lcCtor: Null<String> = lcCtors.length == 0 ? null : lcCtors[0];
		final bodyBreakFlag: Null<String> = child.fmtReadString('bodyBreak');
		final bareBodyBreaksFlag: Bool = child.fmtHasFlag('bareBodyBreaks');
		final noLeadNoRaw: Bool = kwLead == null && leadText == null && !isRaw;
		if (lcSep != null && lcCtor != null) {
			// Sibling no-lead branches (e.g. `HxFnBody.ExprBody`) need a
			// ` ` separator between the parent kw and the sub-rule's
			// first token — Case 3 generic single-Ref branches whose
			// writer emits `subCall` first. `;`-led siblings (NoBody)
			// stay on the `_de()` default so `function f():Void;`
			// round-trips with no inserted space ahead of `;`.
			//
			// ω-functionBody-policy: a sibling ctor carrying ctor-level
			// `@:fmt(bodyPolicy(...))` has its own bodyPolicyWrap inside
			// the sub-rule writer (Case 3 path) which provides the
			// kw→body separator (`_dt(' ')` for Same, hardline+Nest for
			// Next). The parent must therefore emit `_de()` for that
			// ctor, otherwise we get a doubled space (Same) or a
			// trailing space ahead of the hardline (Next). The
			// per-sibling separator decision lives at the parent here
			// because only the parent knows the runtime ctor.
			emitLeftCurlyBody(
				ctx, child, parts, refName, fieldName, typePath, fieldAccess, writeCall, isFirstField, kwLead, leadText, lcSep, lcCtors
			);
			// (bodyPolicyForCtor ternary chain + metaBlockGlue descent live in emitLeftCurlyBody)
		} else if (bodyBreakFlag != null && noLeadNoRaw) {
			// ω-expression-try-body-break: wrap the body field in a
			// SameLinePolicy switch — `Same` emits ` ` + body, `Next`
			// emits hardline + Nest + body so the body sits one indent
			// deeper than the surrounding kw line. Used by
			// `HxTryCatchExpr.body` (first field; Case 3 strips the
			// `try` kw's trailing space so the wrap's `Same` ` ` is the
			// sole separator) and by `HxCatchClauseExpr.body` (last
			// field; replaces the fixed `_dt(' ')` between `)` and the
			// catch body).
			parts.push(bodyBreakWrap(ctx, bodyBreakFlag, writeCall, fieldAccess, refName, child.fmtHasFlag('blockBodyKeepsInline')));
		} else if (bareBodyBreaksFlag && noLeadNoRaw) {
			// ω-statement-bare-break: shape-only wrap — block body
			// emits inline ` ` + body, bare body emits hardline +
			// Nest + body. No policy involvement, so the layout is
			// independent of `sameLineCatch` (block bodies still get
			// their `} catch` placement controlled by the catches
			// Star sameLine knob; bare bodies always break). Used by
			// `HxTryCatchStmt.body` (first field; Case 3 strips the
			// `try` kw's trailing space) and `HxCatchClause.body`
			// (last field; replaces the default `_dt(' ')` separator
			// between `)` and the catch body).
			parts.push(bareBodyBreakWrap(
				ctx, writeCall, fieldAccess, refName, child.fmtReadString('bareBodyBreaks'), child.fmtHasFlag('constructFitBody')
			));
		} else if (noLeadNoRaw && !isFirstField) {
			// Bare-Ref non-first body: allmanIndentForCtor / nestBodyOnSourceNewline /
			// ω-issue-48-v2 sep cascade — see emitBareRefNonFirstBody.
			emitBareRefNonFirstBody(ctx, child, parts, fieldName, typePath, fieldAccess, writeCall, prevAnyStarNonEmpty, prevPadTrailing);
		} else if (hasCondWrap && spanInfoPresent) {
			// ω-condwrap-forstmt: span mode — defer the
			// `emitCondition` wrap to the end-field
			// iteration. Push writeCall directly so
			// inter-field separators / kw text /
			// trailing-field writeCall accumulate in
			// `parts` for splicing at the end. The
			// `_setChainModeOverride` shadow is also
			// applied lazily (inside the end-field's
			// splice block) so the inner writeCalls see
			// the overridden cascade.
			parts.push(writeCall);
		} else if (hasCondWrap) {
			// ω-condition-wrap-wiring / ω-chain-fillline-in-condwrap: single-Ref condWrap
			// emit — see emitCondWrapSingleRef.
			emitCondWrapSingleRef(ctx, child, parts, condWrapArgs, typePath, fieldName, leadText, trailText, writeCall);
			// (condParensInside / ω-condition-wrap-keep detail lives in emitCondWrapSingleRef)
		} else if (child.fmtHasFlag('arrowBodyLineWrap')) {
			// ω-arrow-body-line-wrap: when the line containing
			// the lambda body — `(params) -> body` plus rest of
			// stack — would exceed `opt.lineWidth`, break after
			// `->` (or `=>`) and indent the body one level. The
			// preceding lead emission via `whitespacePolicyLead`
			// terminates with `_dop(' ')` (OptSpace); the brk
			// side's leading hardline triggers the renderer's
			// `pendingOptSpace` clear so the post-arrow space
			// drops cleanly without leaving a trailing token.
			// Flat side is the bare writeCall — byte-identical
			// to the pre-slice default branch below.
			//
			// Mirrors fork's `MarkWrapping.applyArrowWrapping`
			// (`MarkWrapping.hx:985-1041`): collect arrows whose
			// flat line exceeds `maxLineLength`, apply break
			// after `->`, try collapse, restore on still-exceed.
			// Our `_dilr` IS the collapse — flat side fires
			// when the line fits, brk side fires when it does
			// not, both decided at render time.
			//
			// Wrapped in `_dwb` (WrapBoundary) so a sister probe
			// in `WrapList.shapeFillLine` 1-item path can detect
			// the arrow-body-line-wrap signature structurally
			// and route the outer Call's close paren to its own
			// line (mirrors fork's parent-walk close-paren mark
			// in `applyArrowWrapping`'s `lineEndBefore(pClose)`).
			// Slice-2 follow-up extends `isChainOPLBreak`.
			//
			// Currently consumed by `HxThinParenLambda.body`
			// (`->` form) and `HxParenLambda.body` (`=>` form)
			// for symmetric coverage of the canonical and
			// legacy lambda-body syntaxes.
			parts.push(arrowBodyLineWrapExpr(writeCall));
		} else {
			parts.push(writeCall);
		}
	}

	/**
	 * ω-expression-try-body-break — build a runtime switch over
	 * `opt.<sameLineFlag>:SameLinePolicy` that wraps the body
	 * `writeCall` with an extra Nest level on the `Next` branch so the
	 * body content sits one indent deeper than the surrounding `try` /
	 * `catch (...)` keyword line. `Same` (and the default) emits the
	 * existing `' ' + body` shape; `Next` emits `_dn(_cols, _dc([_dhl(),
	 * body]))` — hardline + nested-indent + body, mirroring
	 * `bodyPolicyWrap`'s `Next` layout. `Keep` falls back to `Same`
	 * because no per-field source-shape slot exists at this site.
	 *
	 * Used by `@:fmt(bodyBreak('flagName'))` on a bare-Ref body field —
	 * `HxTryCatchExpr.body` (first field; Case 3 strips the `try` kw's
	 * trailing space so the wrap's `Same` ` ` is the sole separator) and
	 * `HxCatchClauseExpr.body` (last field; replaces the fixed
	 * `_dt(' ')` between `)` and the catch body).
	 *
	 * ω-block-shape-aware (block-body shape-awareness): when the field
	 * also carries `@:fmt(blockBodyKeepsInline)` AND the body's type has
	 * block ctors (collected via `collectBlockCtorPatterns`), an outer
	 * ctor switch suppresses the `opt.<flag>` body-break policy for those
	 * ctors — block bodies have their own visual structure (`{ ... }`),
	 * so a policy body-break would emit `try \n\t{ ... }` instead of the
	 * brace-paired layout. The block branch instead defers to
	 * `opt.blockLeftCurly` (ω-block-allman-leftcurly): `Same` cuddles the
	 * brace inline (`try { ... }`), `Next` (Allman, `lineEnds.leftCurly =
	 * "both"`) breaks it onto its own line at the statement base indent
	 * (`try\n{ ... }`). Non-block ctors still honour the policy switch.
	 * Opt-in via the flag because statement-form siblings
	 * (`HxTryCatchStmt.body` etc.) want the OPPOSITE — `} catch` breaks
	 * to `}\ncatch` on `Next` regardless of body shape (see
	 * `testSameLineCatchAppliesToEveryCatch` for the upstream
	 * haxe-formatter contract).
	 */
	private static function bodyBreakWrap(
		ctx: RefFieldCtx, flagName: String, writeCall: Expr, bodyAccess: Expr, bodyTypePath: String, shapeAware: Bool
	): Expr {
		final optFlag: Expr = optFieldAccess(flagName);
		final sameLayoutExpr: Expr = macro _dc([_dt(' '), $writeCall]);
		final nextLayoutExpr: Expr = macro _dn(_cols, _dc([_dhl(), $writeCall]));
		final flagSwitch: Expr = buildPolicySwitch(['anyparse', 'format', 'SameLinePolicy'], optFlag, [
			{ values: ['Next'], expr: nextLayoutExpr },
			{ values: ['Keep'], expr: sameLayoutExpr }
		], sameLayoutExpr);
		final blockPatterns: Array<Expr> = shapeAware ? collectBlockCtorPatterns(ctx.ctorPat, bodyTypePath) : [];
		// ω-block-allman-leftcurly: when the body's runtime ctor is a block,
		// the inline `' ' + body` layout cuddles the brace (`try { … }`). That
		// is correct under `blockLeftCurly = Same`, but Allman (`Next`,
		// `lineEnds.leftCurly = "both"`) wants the brace on its own line at the
		// statement's base indent (`try\n{ … }`). `BlockExpr`'s own
		// `@:fmt(leftCurly('blockLeftCurly'))` separator is owned by this body
		// field, not emitted by the writeCall, so the gate lives here. `_dhl()`
		// (plain hardline, current indent — no extra Nest) mirrors
		// `leftCurlySeparator`'s `Next` branch so the brace sits at the same
		// column as the keyword, matching haxe-formatter's expression-form
		// try-catch Allman layout.
		final blockLayoutExpr: Expr = {
			final brace: Expr = optFieldAccess('blockLeftCurly');
			final braceNextPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
			final allmanLayoutExpr: Expr = macro _dc([_dhl(), $writeCall]);
			final braceCases: Array<Case> = [{ values: [braceNextPat], expr: allmanLayoutExpr, guard: null }];
			{ expr: ESwitch(brace, braceCases, sameLayoutExpr), pos: Context.currentPos() };
		};
		final wrapExpr: Expr = if (blockPatterns.length == 0)
			flagSwitch
		else {
			final shapeCases: Array<Case> = [
				{ values: blockPatterns, expr: blockLayoutExpr, guard: null },
				{ values: [macro _], expr: flagSwitch, guard: null }
			];
			{ expr: ESwitch(bodyAccess, shapeCases, null), pos: Context.currentPos() };
		};
		// `_dn(_cols, …)` in the Next branch needs a per-call `_cols` binding —
		// mirrors `bodyPolicyWrap`'s tail block (line 1721) and the Star
		// `_dn(_cols, _dc(_docs))` site at line 2337.
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$wrapExpr;
		};
	}

	/**
	 * ω-statement-bare-break — wrap a bare-Ref body field with a runtime
	 * ctor switch that forces a multi-line break for non-block bodies and
	 * keeps the inline single-space layout for block bodies. No policy
	 * involvement: the layout is decided purely by the body's enum ctor.
	 *
	 * Block ctors (`collectBlockCtorPatterns(bodyTypePath)`) → `_dc([_dt(' '),
	 * body])` (inline space + body). Catch-all → `_dn(_cols, _dc([_dhl(),
	 * body]))` (hardline + nested-indent + body, mirroring `bodyBreakWrap`'s
	 * Next layout).
	 *
	 * Used by `@:fmt(bareBodyBreaks)` on a bare-Ref body field —
	 * `HxTryCatchStmt.body` (first field; Case 3 strips the `try` kw's
	 * trailing space so the wrap's inline `' '` is the sole separator) and
	 * `HxCatchClause.body` (last field; replaces the fixed `_dt(' ')`
	 * between `)` and the catch body). The semantic is the inverse of
	 * `blockBodyKeepsInline` on `bodyBreakWrap` — that flag forces inline
	 * for blocks regardless of an existing `Next` policy; this flag forces
	 * break for bare bodies with no policy at all. The two flags address
	 * the opposite haxe-formatter conventions for expression-position
	 * (`expressionTry=Next` rare; bare bodies stay inline) versus
	 * statement-position try-catch (default `sameLineCatch=Same`; bare
	 * bodies always break).
	 *
	 * If `bodyTypePath` has no block ctors the helper degrades to an
	 * unconditional `nextLayoutExpr` — a fallback that should never fire
	 * in practice (statement-form bodies are `HxStatement` which carries
	 * `BlockStmt`); kept defensive so the macro doesn't fatal-error on a
	 * future grammar that adds the flag without a block alternative.
	 */
	private static function bareBodyBreakWrap(
		ctx: RefFieldCtx, writeCall: Expr, bodyAccess: Expr, bodyTypePath: String, policyField: Null<String>, constructFitBody: Bool
	): Expr {
		final sameLayoutExpr: Expr = macro _dc([_dt(' '), $writeCall]);
		final breakLayoutExpr: Expr = macro _dn(_cols, _dc([_dhl(), $writeCall]));
		// omega-try-brace-symmetry: the hardline was unconditional, which is haxe-formatter's
		// statement-context convention and stays the default. A form that names a `BodyPolicy` knob
		// gains the FitLine escape: the bare body keeps the header line while the whole line fits and
		// takes the old break when it does not. Without that escape the de-brace direction is a
		// DOWNGRADE — `try f() catch (e) g();` would render across four lines — and worse, the
		// de-braced statement form re-parses as the bare one, so a second `fmt` pass would explode
		// what the first collapsed and `fmt` would stop being a fixed point.
		final nextLayoutExpr: Expr = if (policyField == null)
			breakLayoutExpr
		else {
			final policy: Expr = optFieldAccess(policyField);
			// Under `@:fmt(constructFitBody)` the escape is ONE soft line owned by the enclosing
			// construct group (see WrapBodyOpts.constructFitBody) — the body drops to its own indented
			// line with the same break the `catch` seam takes, instead of answering for its own line
			// and gluing to the head. Without the flag the width probe stays per-line.
			final fitEscape: Expr = constructFitBody
				? macro _dn(_cols, _dc([_dl(), $writeCall]))
				: macro _dfle(opt.lineWidth, $breakLayoutExpr, $sameLayoutExpr);
			macro $policy == anyparse.format.BodyPolicy.FitLine ? $fitEscape : $breakLayoutExpr;
		};
		final blockPatterns: Array<Expr> = collectBlockCtorPatterns(ctx.ctorPat, bodyTypePath);
		final wrapExpr: Expr = if (blockPatterns.length == 0)
			nextLayoutExpr
		else {
			final shapeCases: Array<Case> = [
				{ values: blockPatterns, expr: sameLayoutExpr, guard: null },
				{ values: [macro _], expr: nextLayoutExpr, guard: null }
			];
			{ expr: ESwitch(bodyAccess, shapeCases, null), pos: Context.currentPos() };
		};
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$wrapExpr;
		};
	}

	/**
	 * Emit the separator + writeCall for a bare-Ref NON-FIRST struct body field
	 * (kw-less, lead-less, non-raw). Covers `@:fmt(allmanIndentForCtor)`,
	 * `@:fmt(nestBodyOnSourceNewline)`, and the ω-issue-48-v2 BeforeNewline /
	 * ω-598 leading-comment sep cascade. Pushes onto `parts`.
	 */
	private static function emitBareRefNonFirstBody(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, fieldName: String, typePath: String, fieldAccess: Expr, writeCall: Expr,
		prevAnyStarNonEmpty: Null<Expr>, prevPadTrailing: Null<Expr>
	): Void {
		// ω-meta-allman-objectlit: `@:fmt(allmanIndentForCtor('<ctor>'))`
		// on a bare-Ref non-first field forces an Allman-style
		// brace placement plus one indent step when the field's
		// runtime value matches the named ctor. The default
		// `_dt(' ')` separator is suppressed and the writer call
		// is wrapped in `Nest(_cols, [hardline, writeCall])` —
		// the hardline lands at indent base + _cols (Nest bumps
		// the current indent), so the value's own opening
		// literal sits one indent step deeper than the parent
		// and the value's body picks up another step from its
		// own internal Nest. Non-matching ctors fall through to
		// the default `_dt(' ') + writeCall` layout.
		//
		// First (and currently only) consumer: `HxMetaExpr.expr`
		// with `('ObjectLit')` so `@meta { ... }` round-trips
		// the haxe-formatter convention of placing `{` on its
		// own line at indent +1 regardless of the global
		// `objectLiteralLeftCurly` knob — the meta-prefixed
		// brace placement is structural, not configurable.
		//
		// Trivia-mode `BeforeNewline` signal is bypassed when
		// the flag fires — the runtime ctor check is
		// structurally definitive for the brace-form layout
		// and source-newline preservation would only matter
		// for non-brace alternatives that already fall through
		// to the default sep path.
		final allmanCtor: Null<String> = child.fmtReadString('allmanIndentForCtor');
		if (allmanCtor != null) {
			final ctorMatchExpr: Expr = macro Type.enumConstructor($fieldAccess) == $v{allmanCtor};
			// Non-matching ctor falls through to the same
			// BeforeNewline-aware separator the plain
			// bare-Ref non-first branch uses below
			// (ω-issue-48-v2 mechanism). In trivia mode the
			// synth slot `<f>BeforeNewline` records whether
			// source had a newline before this field's
			// first token; preserve it so `@:m if (…)` etc.
			// honour source-side line breaks the same way
			// the rest of the writer does. Plain mode (no
			// trivia signal) keeps the unconditional space.
			final sepExpr: Expr = ctx.ctx.trivia && ctx.isTriviaBearing(typePath)
				? macro ${beforeNewlineAccess(fieldName)} ? _dhl() : _dt(' ')
				: macro _dt(' ');
			parts.push(macro {
				final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				final _doc: anyparse.core.Doc = $writeCall;
				$ctorMatchExpr ? _dn(_cols, _dc([_dhl(), _doc])) : _dc([$sepExpr, _doc]);
			});
		} else if (child.fmtHasFlag('nestBodyOnSourceNewline') && ctx.ctx.trivia && ctx.isTriviaBearing(typePath)) {
			// ω-cond-comp-expr-body-nest: source-shape-driven
			// body break+nest. The bare-Ref non-first slot
			// `<f>BeforeNewline:Bool` (synth via
			// `TriviaTypeSynth.isBareNonFirstRef`) records
			// whether the source had a newline before this
			// field's first token. When true the wrapper
			// emits `Nest(_cols, [hardline, body])` so the
			// body sits one indent step deeper than the
			// preceding `#if`/`#elseif` keyword line; when
			// false the wrapper emits `' ' + body` for
			// inline single-line cond-comp expressions.
			// Currently consumed by `HxConditionalExpr.expr`
			// and `HxElseifExpr.expr`.
			final nlSignal: Expr = beforeNewlineAccess(fieldName);
			parts.push(nestBodyOnSourceNewlineWrap(writeCall, nlSignal));
		} else {
			// ω-issue-48-v2: in trivia mode the bare Ref field
			// grew a `<field>BeforeNewline:Bool` slot (see
			// `TriviaTypeSynth.isBareNonFirstRef`). Consult it
			// to emit a hardline when the parser captured a
			// source newline in the gap — this is the only
			// signal available when a preceding bare-tryparse
			// Star (e.g. `HxMemberDecl.modifiers`) is empty,
			// since that Star has no first element whose
			// `newlineBefore` could be read.
			parts.push(buildBareRefLeadingSep(ctx.fieldSep, child, fieldName, typePath, prevAnyStarNonEmpty, prevPadTrailing));
			parts.push(writeCall);
		}
	}

	/**
	 * ω-condition-wrap-wiring: emit a single-Ref `@:fmt(condWrap('<knob>'))` field
	 * as a runtime `WrapList.emitCondition` call (replacing the bare lead+value+
	 * trail pushes). Threads the chain-mode / paren-in-condition / cond-keep
	 * shadows and the inner-pad / source-open-newline args, then pushes onto
	 * `parts`.
	 */
	private static function emitCondWrapSingleRef(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, condWrapArgs: Array<String>, typePath: String, fieldName: String,
		leadText: Null<String>, trailText: Null<String>, writeCall: Expr
	): Void {
		final condKnobAccess: Expr = optFieldAccess(condWrapArgs[0]);
		// ω-before-trail: a `@:fmt(condWrap)` field's close paren is emitted by
		// `WrapList.emitCondition`, not by `emitMandatoryRefTrail`, so a comment
		// captured just before it has to ride INSIDE the condition Doc or it
		// lands after the `)`. Appending to `writeCall` is what keeps
		// `if (cond /* c *\/)` where the author wrote it.
		final condBeforeTrail: Null<Expr> = beforeTrailSlotAccess(ctx, child, macro value.$fieldName, false, trailText, typePath);
		final writeCall: Expr = condBeforeTrail == null
			? writeCall
			: macro {
				final _cbt: Null<String> = $condBeforeTrail;
				_cbt == null ? $writeCall : _dc([$writeCall, trailingCommentDocVerbatim(_cbt, opt)]);
			};
		// ω-condition-parens (Stage C): `@:fmt(condParensInside(
		// '<insideOpenKnob>', '<insideCloseKnob>'))` on the
		// condWrap cond field pads the FLAT `( cond )` shape via
		// `opt.<knob>:WhitespacePolicy`. Null when absent →
		// `_de()` inner Docs → tight `(cond)` byte-identical.
		final condInsideArgs: Null<Array<String>> = child.fmtReadStringArgs('condParensInside');
		final condInsideOpen: Expr = condInsideArgs != null && condInsideArgs.length == 2
			? policyInsideSpace(condInsideArgs[0], false)
			: macro _de();
		final condInsideClose: Expr = condInsideArgs != null && condInsideArgs.length == 2
			? policyInsideSpace(condInsideArgs[1], true)
			: macro _de();
		// ω-condition-wrap-keep: read the `<field>CondOpenNewline:Bool`
		// synth slot (populated by `Lowering` when the source broke
		// right after the open paren) and thread it into
		// `emitCondition`'s `sourceOpenNewline` arg. Under
		// `WrapMode.Keep` the engine forces `brkShape` so the
		// author's post-`(` break round-trips. Gated on trivia +
		// bearing + the field opting in via
		// `@:fmt(captureCondOpenNewline)`; otherwise the slot does
		// not exist, so we pass a literal `false` → byte-inert
		// (plain mode, non-keep modes, non-opted condWrap fields).
		final hasCondOpenNewlineSlot: Bool = ctx.ctx.trivia && ctx.isTriviaBearing(typePath) && child.fmtHasFlag('captureCondOpenNewline');
		final condOpenNewlineExpr: Expr = hasCondOpenNewlineSlot ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.CONDITION_OPEN_NEWLINE_SUFFIX),
			pos: Context.currentPos()
		} : macro false;
		// ω-condition-wrap-keep: only the trivia-bearing Haxe cond
		// path (slot present) sets `_keepChainInParen` — the
		// `_setKeepChainInParen` helper exists only on opt types that
		// declare `_keepChainInParen` (Haxe `HxModuleWriteOptions`). A
		// generic `@:fmt(condWrap)` grammar without the slot emits the
		// plain opt shadow → no reference to the Haxe-only helper. The
		// runtime `sourceOpenNewline` + Keep gate further narrows the
		// flag to force-broken keep conds.
		final condKeepChainInParen: Expr = hasCondOpenNewlineSlot
			? macro {
				final _condKeepBrk: Bool = $condOpenNewlineExpr && _condMode == anyparse.format.wrap.WrapMode.Keep;
				final opt = _condKeepBrk ? _setKeepChainInParen(opt, true) : opt;
				opt;
			}
			: macro opt;
		parts.push(macro {
			final _condRules: anyparse.format.wrap.WrapRules = $condKnobAccess;
			final _condMode: anyparse.format.wrap.WrapMode = _condRules.defaultMode;
			final _chainOvr: Null<anyparse.format.wrap.WrapMode> = _condMode == anyparse.format.wrap.WrapMode.NoWrap ? null : _condMode;
			// ω-expr-paren-in-condition (cond F2): mark the condition
			// content so an expression paren INSIDE it routes its inner
			// chain through `expressionWrapping` (fillLine) instead of
			// the unconditional HardFlatten collapse — the fork applies
			// `expressionWrapping` to expr parens regardless of context.
			// The flag is consumed ONLY at the `ParenExpr` lowering (it
			// threads the fillLine `_chainModeOverride` into the paren's
			// OWN inner chain and clears the flag), so the condition's
			// top-level chain (`a && b`) is untouched. Byte-inert for
			// the universal default `expressionWrappingWrap`
			// (`{rules: [], defaultMode: NoWrap}` → false).
			final _parenCond: Bool = anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap) != null;
			final opt = _setParenInCondition(_setChainModeOverride(opt, _chainOvr), _parenCond, opt);
			// ω-condition-wrap-keep: when the cond paren is force-broken
			// (source newline after `(` + Keep mode → `emitCondition`
			// returns `brkShape`), the `brkShape`'s `Nest(cols, condDoc)`
			// already supplies the +cols paren indent. Mark the cond
			// chain's opt `_keepChainInParen` so its OWN continuation
			// `Nest` is suppressed (chain operators co-indent with the
			// head at outer+cols, not compounding to outer+2cols) AND its
			// own `_headBreak` is dropped (`brkShape`'s leading `Line`
			// already put the head operand on its own line). Reuses the
			// `_keepChainInParen` channel (gated there on the
			// chain config being Keep). `condKeepChainInParen` is a
			// macro-time no-op (`opt`) for non-Haxe / non-bearing grammars
			// so the Haxe-only `_setKeepChainInParen` helper is never
			// referenced there.
			final opt = $condKeepChainInParen;
			anyparse.format.wrap.WrapList.emitCondition(
				$v{leadText}, $v{trailText}, $writeCall, opt, $condKnobAccess, $condInsideOpen, $condInsideClose, $condOpenNewlineExpr
			);
		});
	}

	/**
	 * Emit the `@:fmt(leftCurly)` bare-Ref body path — a runtime BracePlacement
	 * ctor switch (`buildLeftCurlySepExpr`) between the parent kw and the body's
	 * first token, optionally routing matched `@:fmt(bodyPolicyForCtor(...))`
	 * ctors through `buildBodyPolicyForCtorChain` (with `@:fmt(metaBlockGlue)`
	 * descent naming). Pushes into `parts`.
	 */
	private static function emitLeftCurlyBody(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, refName: String, fieldName: String, typePath: String, fieldAccess: Expr,
		writeCall: Expr, isFirstField: Bool, kwLead: Null<String>, leadText: Null<String>, lcSep: Expr, lcCtors: Array<String>
	): Void {
		final ctorExpr: Expr = macro Type.enumConstructor($fieldAccess);
		final sepExpr: Expr = buildLeftCurlySepExpr(ctx, refName, lcCtors, ctorExpr, lcSep);
		// ω-untyped-keep / ω-fnbody-keep: `@:fmt(bodyPolicyForCtor('<ctor>',
		// '<flagName>'))` (repeatable) runtime-replaces the per-ctor
		// `sep + writeCall` pair with a `bodyPolicyWrap` for each matched
		// runtime ctor, built as a ternary chain falling through to the
		// per-ctor default. The `<field>BeforeNewline` Keep-dispatch slot is
		// read at the parent (where it IS captured, see `hasBeforeNewlineSlot`
		// in `StructSeqLowering.lowerStruct`), NOT inside the kw-less branch. Consumers:
		// `HxFnDecl.body` for `('UntypedBlockBody', 'untypedBody')` and
		// `('ExprBody', 'functionBody')`. Same/Next output stays byte-identical
		// to the pre-slice inner-branch emission.
		final bodyPolicyForCtorPairs: Array<Array<String>> = child.fmtReadStringArgsAll('bodyPolicyForCtor');
		if (bodyPolicyForCtorPairs.length > 0) {
			final hasBeforeNlSlot: Bool = ctx.ctx.trivia && ctx.isTriviaBearing(typePath) && !isFirstField && kwLead == null
				&& leadText == null;
			final wrapBodyOnSameLineExpr: Null<Expr> = hasBeforeNlSlot ? beforeNewlineNotAccess(fieldName) : null;
			// ω-fnbody-meta-block-glue: `@:fmt(metaBlockGlue('<exprBodyCtor>',
			// '<metaCtor>', '<blockCtor>'))` names the runtime descent so
			// `bodyPolicyWrap` can route a metadata-wrapped block body
			// (`@:meta { … }`) to the glued layout. Consumer: `HxFnDecl.body`
			// with `('ExprBody', 'MetaExpr', 'BlockExpr')`.
			final metaBlockGlueArgs: Null<Array<String>> = child.fmtReadStringArgs('metaBlockGlue');
			if (metaBlockGlueArgs != null && metaBlockGlueArgs.length != 3)
				Context.fatalError(
					'WriterLowering: @:fmt(metaBlockGlue(...)) requires (exprBodyCtor, metaCtor, blockCtor), got '
					+ '${metaBlockGlueArgs.length} args',
					Context.currentPos()
				);
			parts.push(buildBodyPolicyForCtorChain(
				ctx, bodyPolicyForCtorPairs, ctorExpr, sepExpr, writeCall, fieldAccess, refName, wrapBodyOnSameLineExpr, metaBlockGlueArgs
			));
			// (ternary-chain fold lives in buildBodyPolicyForCtorChain)
		} else {
			parts.push(sepExpr);
			parts.push(writeCall);
		}
	}

	/**
	 * Build the mandatory-Ref body field's runtime `writeCall` Expr. Reads the
	 * opt-fanout flags (`propagateExprPosition` / `propagateAnonFnContext` /
	 * `propagateTypedefContext` / `switchSubjectNoWrap` / `propagateValueIfBranch`
	 * / `setBoolFlagFromStarCtor`) to assemble the descendant writer's `opt`
	 * argument, then layers `@:fmt(sharpCondParensInside)` and the
	 * `@:fmt(indentValueIfCtor)` additive-Nest wrap (skipped when a same-field
	 * `@:fmt(bodyPolicy)` routes it through the subtractive channel instead).
	 *
	 */
	@:access(anyparse.macro.WriterArrowValueIfLowering)
	private static function buildMandatoryRefWriteCall(
		ctx: RefFieldCtx, child: ShapeNode, fieldAccess: Expr, typePath: String, writeFn: String, bodyPolicyFlag: Null<String>,
		indentObjArgs: Null<Array<String>>, ?ssbSuppressCond: Expr
	): Expr {
		// ω-issue-423-mech-a / ω-arrow-lambda-body-context /
		// ω-typedef-anon-force-multi: opt-fanout flags wrapping the descendant
		// writer's `opt` arg in `_setExprPosition` / `_setAnonFnBody` /
		// `_setTypedefBody` so the descendant sees the matching context flag.
		final propagateExpr: Bool = child.fmtHasFlag('propagateExprPosition');
		final propagateAnonFn: Bool = child.fmtHasFlag('propagateAnonFnContext');
		final propagateTypedef: Bool = child.fmtHasFlag('propagateTypedefContext');
		// ω-enumabstract-begin-end: `@:fmt(propagateEnumAbstractContext)` on
		// `EnumAbstractDecl(decl)` flags the inner `HxAbstractDecl` opt so its
		// body reads the `enumAbstractBeginType` / `enumAbstractEndType` knobs.
		final propagateEnumAbstract: Bool = child.fmtHasFlag('propagateEnumAbstractContext');
		// ω-extern-class-no-blanks: `@:fmt(setBoolFlagFromStarCtor(optField,
		// starField, ctorName))` allocates a fresh opt copy and sets
		// `_wo.<optField> = true` iff the sibling `<starField>` Star contains
		// `<ctorName>`. Consumer: `HxTopLevelDecl.decl` (`_classExtern`).
		final boolFlagArgs: Null<Array<String>> = readBoolFlagStarCtorArgs(child);
		// ω-switch-subject-nowrap: the fork never wraps a switch subject —
		// thread `_setChainModeOverride(opt, NoWrap)` so a top-level chain in
		// the subject stays flat. Carried by `HxSwitchStmt(Bare).expr`.
		final switchSubjectNoWrap: Bool = child.fmtHasFlag('switchSubjectNoWrap');
		// ω-expressionif-collapse (mechanism B set-site): `@:fmt(propagateValueIfBranch)`
		// on a mandatory Ref (HxIfExpr.thenBranch) opts into the value-if-branch frame.
		final propagateValueIfBranch: Bool = child.fmtHasFlag('propagateValueIfBranch');
		// ω-elseif-body-break: `@:fmt(clearElseIfBranch)` on the inner `if`'s
		// then-body (HxIfStmt.thenBody) drops the one-level else-branch signal
		// before rendering the body content, so a statement nested inside the
		// else-if body is not itself treated as an else-branch.
		final clearElseIfBranch: Bool = child.fmtHasFlag('clearElseIfBranch');
		// ω-arrow-body-objlit-pad: `@:fmt(propagateArrowLambdaBody)` on an
		// arrow-lambda body Ref (HxThinParenLambda.body) flags the immediate
		// body write so its leftmost-leaf object literal drops the open pad.
		// Wrapped AFTER `_setExprPosition` so the descent clear inside it does
		// not wipe the just-set flag.
		final propagateArrowLambdaBody: Bool = child.fmtHasFlag('propagateArrowLambdaBody');
		// omega-condsplice-tail-nest: `@:fmt(chainNestSuppress)` on a mandatory Ref
		// (HxCondSpliceExpr.tail) suppresses the descendant chain's OWN continuation
		// Nest so a `#if … #end` token-splice tail co-indents with the ENCLOSING chain
		// instead of compounding a second indent level. Reuses the call-arg chain-nest
		// channel (`_setCallArgChainNest` → `_chainNestSuppress`); the flag is consumed
		// and cleared at the tail's outermost chain, so only a bare-ternary tail could
		// reach the sister `ternaryRestAware` coupling — and that tail CLEARS without
		// suppressing (`lowerTernaryBranch`: a ternary always keeps its own `?` / `:`
		// Nest), so the co-indent this flag buys never reaches a bare-ternary tail.
		final chainNestSuppress: Bool = child.fmtHasFlag('chainNestSuppress');
		final optArgExpr: Expr = if (boolFlagArgs != null) {
			macro _wo;
		} else {
			var e: Expr = macro opt;
			if (propagateExpr) e = macro _setExprPosition($e, opt);
			// ω-single-stmt-braces: dangling-else suppress frame — when the
			// enclosing `if` has an `else` at runtime AND its then-body renders
			// WITHOUT braces, the whole then-body write runs with `_ssbSuppress` so
			// nested `dropSingleStmtBraces` unwraps are gated by the same
			// trailing-spine test as the direct dangling-else gate (they could
			// otherwise expose a trailing braceless `if` that captures the outer
			// `else`). A brace-bearing then-body seals its subtree with its own `}`
			// and never arms the frame. Null cond (no meta / no else sibling /
			// plain mode) is byte-inert.
			if (ssbSuppressCond != null) e = macro ($ssbSuppressCond ? _setSsbSuppress($e, opt) : $e);
			// ω-single-stmt-braces CHAIN symmetry: a body's OWN content must NOT
			// inherit the else-if chain-suppress flag — an independent if-chain
			// nested inside this branch still de-braces on its own merits. Clear it
			// on the descendant opt (trivia mode only; the flag exists on the
			// HxModuleWriteOptions typedef the dropSingleStmtBraces bodies use).
			if (ctx.ctx.trivia && child.fmtHasFlag('dropSingleStmtBraces')) e = macro _setSsbChainSuppress($e, false, opt);
			// Set AFTER `_setExprPosition` so its descent-clear does not wipe the
			// just-set flag (mirrors the `propagateArrowLambdaBody` ordering).
			e = subPositionSuppressOpt(child, e);
			if (chainNestSuppress) e = macro _setCallArgChainNest($e, opt);
			if (propagateArrowLambdaBody) e = macro _setArrowLambdaBody($e, opt);
			if (propagateAnonFn) e = macro _setAnonFnBody($e, opt);
			if (propagateTypedef) e = macro _setTypedefBody($e, opt);
			if (propagateEnumAbstract) e = macro _setEnumAbstract($e, opt);
			if (switchSubjectNoWrap) e = macro _setChainModeOverride($e, anyparse.format.wrap.WrapMode.NoWrap, opt);
			// The helper gates on `opt._inExprPosition` so only a value-if
			// branch (not a statement-`if`) flips the narrow flag.
			if (propagateValueIfBranch) e = macro _setValueIfBranch($e, opt);
			if (clearElseIfBranch) e = macro _clearElseIfBranch($e, opt);
			e = WriterArrowValueIfLowering.arrowValueIfBlockOpt(child, e);
			e;
		};
		final baseRawWriteCall: Expr = {
			expr: ECall(macro $i{writeFn}, [fieldAccess, optArgExpr]),
			pos: Context.currentPos()
		};
		final rawWriteCall: Expr = buildBoolFlagRawWriteCall(ctx, boolFlagArgs, baseRawWriteCall, typePath, propagateExpr);
		// ω-condition-parens (Stage C): `@:fmt(sharpCondParensInside('<openKnob>',
		// '<closeKnob>'))` injects inner-paren pad into the verbatim `#if (cond)`
		// capture (`HxConditionalStmt.cond`). Null policies → byte-identical.
		final sharpInsideArgs: Null<Array<String>> = child.fmtReadStringArgs('sharpCondParensInside');
		final effRawWriteCall: Expr = buildSharpInsideWriteCall(sharpInsideArgs, fieldAccess, rawWriteCall);
		// ω-indent-objectliteral / ω-expr-body-indent-objectliteral: the additive
		// `maybeIndentValueIfCtor` Nest is SKIPPED when a same-field
		// `@:fmt(bodyPolicy)` routes `indentValueIfCtor` through the subtractive
		// `bodyPolicyWrap.indentObjArgs` channel instead (avoids double-indent).
		return bodyPolicyFlag != null && indentObjArgs != null
			? effRawWriteCall
			: maybeIndentValueIfCtor(effRawWriteCall, fieldAccess, child);
	}

	/**
	 * ω-fnbody-keep: fold a repeatable `@:fmt(bodyPolicyForCtor('<ctor>',
	 * '<flagName>'))` pair list into a runtime ternary chain — each pair routes
	 * its matched runtime ctor to a `bodyPolicyWrap`, falling through to the
	 * `_dc([sepExpr, writeCall])` default for every unpaired ctor. Iterates in
	 * reverse so the first-declared pair sits at the chain head. Shared by the
	 * mandatory `case Ref` leftCurly path (with metaBlockGlue / BeforeNewline
	 * slot) and the optional-Ref leftCurly path (null both).
	 */
	@:access(anyparse.macro.WriterBodyPolicyLowering)
	private static function buildBodyPolicyForCtorChain(
		ctx: RefFieldCtx, pairs: Array<Array<String>>, ctorExpr: Expr, sepExpr: Expr, writeCall: Expr, bodyValueExpr: Expr,
		refName: String, wrapBodyOnSameLineExpr: Null<Expr>, metaBlockGlueArgs: Null<Array<String>>
	): Expr {
		final defaultPair: Expr = macro _dc([$sepExpr, $writeCall]);
		// Fold the pairs into a ternary chain. Iterate in reverse
		// so the first-declared pair sits at the chain head
		// (tested first at runtime).
		var chain: Expr = defaultPair;
		var i: Int = pairs.length - 1;
		while (i >= 0) {
			final pair: Array<String> = pairs[i];
			if (pair.length != 2)
				Context.fatalError(
					'WriterLowering: @:fmt(bodyPolicyForCtor(...)) requires (ctorName, flagName), got ${pair.length} args',
					Context.currentPos()
				);
			final wrapCtorName: String = pair[0];
			final wrapFlagName: String = pair[1];
			final wrapMetaBlockGlue: Null<Array<String>> = metaBlockGlueArgs != null && metaBlockGlueArgs[0] == wrapCtorName
				? metaBlockGlueArgs
				: null;
			final wrapOutput: Expr = WriterBodyPolicyLowering.bodyPolicyWrap(ctx.bodyPolicy, {
				flagName: wrapFlagName,
				writeCall: writeCall,
				bodyValueExpr: bodyValueExpr,
				bodyTypePath: refName,
				hasElseIf: false,
				elseFieldName: null,
				bodyOnSameLineExpr: wrapBodyOnSameLineExpr,
				metaBlockGlueArgs: wrapMetaBlockGlue
			});
			chain = macro $ctorExpr == $v{wrapCtorName} ? $wrapOutput : $chain;
			i--;
		}
		return chain;
	}

	/**
	 * ω-extern-class-no-blanks: build the mandatory-Ref writeCall when
	 * `@:fmt(setBoolFlagFromStarCtor(optField, starField, ctorName))` is present —
	 * a block that allocates a fresh opt copy, probes the sibling Star for the
	 * named ctor, sets `_wo.<optField>`, then issues `baseRawWriteCall`. Returns
	 * `baseRawWriteCall` unchanged when the meta is absent.
	 */
	private static function buildBoolFlagRawWriteCall(
		ctx: RefFieldCtx, boolFlagArgs: Null<Array<String>>, baseRawWriteCall: Expr, typePath: String, propagateExpr: Bool
	): Expr {
		if (boolFlagArgs == null) return baseRawWriteCall;
		final pos: Position = Context.currentPos();
		final optField: String = boolFlagArgs[0];
		final starField: String = boolFlagArgs[1];
		final ctorName: String = boolFlagArgs[2];
		final starAccess: Expr = { expr: EField(macro value, starField), pos: pos };
		final flagAccess: Expr = { expr: EField(macro _c, optField), pos: pos };
		final flagOnOpt: Expr = { expr: EField(macro opt, optField), pos: pos };
		final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
		final useNodeAccess: Bool = ctx.ctx.trivia && ctx.isTriviaBearing(typePath);
		final probeBody: Expr = useNodeAccess
			? macro for (_m in $starAccess)
				if (_m.node.match($ctorIdent)) {
					_f = true;
					break;
				}
			: macro for (_m in $starAccess) if (_m.match($ctorIdent)) {
				_f = true;
				break;
			};
		final propagateExprStmt: Expr = propagateExpr ? (macro _c._inExprPosition = true) : (macro {});
		// ω-optclone-chain-fusion: the probe runs against the SHARED `opt` and
		// the 210-field copy is taken only when a field actually changes, so a
		// class WITHOUT the probed modifier — the overwhelming majority — reads
		// its flag off `opt` and allocates nothing (7 630 -> ~0 copies on a real
		// tree).
		var unchangedExpr: Expr = macro $flagOnOpt == _f;
		if (propagateExpr) unchangedExpr = macro $unchangedExpr && opt._inExprPosition;
		// Each `macro …` reification in an array literal must be
		// parenthesised — bare `macro` after `[…,` mis-parses as
		// "Keyword macro cannot be used as variable name". Plain
		// identifiers (`propagateExprStmt`, `baseRawWriteCall`)
		// are fine as-is.
		final block: Array<Expr> = [
			(macro var _f: Bool = false),
			probeBody,
			(macro final _wo = $unchangedExpr ? opt : {
				final _c = _copyOpt(opt);
				$propagateExprStmt;
				$flagAccess = _f;
				_c;
			}),
			baseRawWriteCall
		];
		return { expr: EBlock(block), pos: pos };
	}

	/**
	 * Build the per-ctor leftCurly separator ternary chain for a Ref-to-enum body
	 * field: space-prefix ctors get `_dt(' ')` (or `_de()` when the ctor carries
	 * its own bodyPolicy), leftCurly ctors get the runtime `BracePlacement`
	 * switch, everything else stays `_de()`. Returns the folded `sepExpr`. Shared
	 * by the mandatory and optional `case Ref` leftCurly paths in `lowerStruct`.
	 */
	private static function buildLeftCurlySepExpr(
		ctx: RefFieldCtx, refName: String, lcCtors: Array<String>, ctorExpr: Expr, lcSep: Expr
	): Expr {
		final spaceCtors: Array<String> = spacePrefixCtors(ctx.ctorPat, refName, lcCtors);
		var sepExpr: Expr = macro _de();
		for (sc in spaceCtors) {
			final scSep: Expr = ctorHasBodyPolicy(ctx.ctorPat, refName, sc) ? macro _de() : macro _dt(' ');
			sepExpr = macro $ctorExpr == $v{sc} ? $scSep : $sepExpr;
		}
		for (lc in lcCtors) sepExpr = macro $ctorExpr == $v{lc} ? $lcSep : $sepExpr;
		return sepExpr;
	}

	/**
	 * Emit a non-Star field's lead-in before its value: the kw prefix
	 * (`emitKwPrefix`, when `@:kw` is present on a non-optional field — incl. the
	 * `@:fmt(leftCurly)` BracePlacement split) and the mandatory `@:lead` literal
	 * (`emitMandatoryLead`, when present on a non-optional, non-condWrap field).
	 * Pushes into `parts`.
	 */
	private static function emitFieldLeadIn(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, kwLead: Null<String>, leadText: Null<String>, isOptional: Bool,
		isFirstField: Bool, isRaw: Bool, prevBodyField: Null<PrevBodyInfo>, typePath: String, prevPadTrailing: Null<Expr>,
		hasCondWrap: Bool, hasCondWrapEnd: Bool, prevAnyStarNonEmpty: Null<Expr>, fieldAccess: Expr
	): Void {
		// D61: kw prefix — space before kw (unless first), kw text with trailing
		// space. @:fmt(sameLine(...)) switches the leading space to a hardline;
		// @:fmt(leftCurly) splits the kw emission for a runtime BracePlacement.
		if (kwLead != null && !isOptional)
			emitKwPrefix(ctx, child, parts, kwLead, isFirstField, isRaw, prevBodyField, typePath, prevPadTrailing, prevAnyStarNonEmpty);
		// D61: non-optional lead — no space before lead. The end-field of a
		// condWrap span cannot push its own `@:lead` (the open paren is owned by
		// the start field and emitted via the splice's emitCondition wrap).
		if (leadText != null && !isOptional && !hasCondWrap && !hasCondWrapEnd) emitMandatoryLead(child, parts, leadText, fieldAccess);
	}

	/**
	 * D61: emit the kw prefix for a kw-led mandatory struct field — leading
	 * separator (unless first / raw) then the kw token. `@:fmt(leftCurly)`,
	 * `@:fmt(anonFuncParens)`, and the `catchParensGap` / `whilePolicy` kw-after
	 * knobs each split the kw-trailing space into a runtime policy switch;
	 * otherwise the kw carries a literal trailing space. Pushes onto `parts`.
	 *
	 */
	private static function emitKwPrefix(
		ctx: RefFieldCtx, child: ShapeNode, parts: Array<Expr>, kwLead: String, isFirstField: Bool, isRaw: Bool,
		prevBodyField: Null<PrevBodyInfo>, typePath: String, prevPadTrailing: Null<Expr>, prevAnyStarNonEmpty: Null<Expr>
	): Void {
		if (!isFirstField && !isRaw) {
			final sep: Expr = sameLineSeparator(ctx.fieldSep, child, prevBodyField, typePath, prevPadTrailing);
			// ω-final-modified-member-double-space: when every preceding field was
			// an empty bare-tryparse Star, drop this kw's leading separator, else a
			// stray space leaks (`final  function` when `HxFinalModifierMember.modifiers`
			// is empty). Mirrors the bare-Ref path's `prevAnyStarNonEmpty` gate in
			// `emitBareRefNonFirstBody`. Null tracker (no preceding Star) is byte-identical.
			if (prevAnyStarNonEmpty != null) {
				final prev: Expr = prevAnyStarNonEmpty;
				parts.push(macro $prev ? $sep : _de());
			} else
				parts.push(sep);
		}
		if (child.fmtHasFlag('leftCurly')) {
			// `leftCurlySeparator` (default `optSpaceUpstream=false`)
			// handles both forms identically at this site: bare-flag
			// reads `opt.leftCurly`, knob-form reads
			// `opt.<knobName>` — `Same` emits `_dt(' ')`
			// (byte-identical to the unsplit `kwLead + ' '` form) and
			// `Next` emits `_dhl()`. First knob-form consumer here:
			// `HxUntypedFnBody.block` with
			// `leftCurly('blockLeftCurly')` (slice
			// ω-blockcurly-broader) so the kw→`{` gap honors the
			// per-construct `Block` knob alongside the global
			// cascade.
			parts.push(macro _dt($v{kwLead}));
			parts.push(leftCurlySeparator(child));
		} else if (child.fmtHasFlag('anonFuncParens')) {
			// `@:fmt(anonFuncParens)` on a kw-led mandatory Ref
			// routes the kw-trailing space slot through the
			// runtime `WhitespacePolicy` knob (paren-side
			// semantics — `Before` / `Both` emit a space, `None`
			// / `After` collapse it). First consumer is
			// `HxExpr.FnExpr` (`@:kw('function')` Ref to
			// `HxFnExpr`) — default `None` keeps
			// `function<T>(...)` / `function(...)` tight, and
			// `whitespace.parenConfig.anonFuncParamParens.openingPolicy:
			// "before"` flips both to `function <T>(...)` /
			// `function (...)`. Mirrors the haxe-formatter
			// convention where `function`-led parens (also when
			// reached inside an `@:overload(...)` metadata arg)
			// track `anonFuncParamParens` (see
			// `MarkWhitespace.determinePOpenPolicy` default
			// fall-through).
			parts.push(macro _dt($v{kwLead}));
			final policySpace: Null<Expr> = kwTrailingSpacePolicyParenSide(child, ['anonFuncParens']);
			if (policySpace != null) parts.push(policySpace);
		} else if (firstFmtFlag(child, ['catchParensGap', 'whilePolicy']) != null) {
			// ω-condition-parens (Stage C): kw-led struct-field cond
			// whose `kw`→`(` gap tracks a kw-after `WhitespacePolicy`
			// knob. `catchParensGap` (`HxCatchClause.param`,
			// `@:kw('catch')`) and `whilePolicy` (`HxDoWhileStmt.cond`,
			// `@:kw('while')` — the trailing `while` of a `do … while`)
			// both use kw-after semantics (`After`/`Both` → space,
			// `None` → tight). Defaults keep `catch (` / `} while (`
			// byte-identical; fed from
			// `parenConfig.{catch|while}ConditionParens.openingPolicy`
			// (flipped to the kw-after axis) in `applyConditionParens`.
			parts.push(macro _dt($v{kwLead}));
			final policySpace: Null<Expr> = kwTrailingSpacePolicy(child, ['catchParensGap', 'whilePolicy']);
			if (policySpace != null) parts.push(policySpace);
		} else {
			parts.push(macro _dt($v{kwLead + ' '}));
		}
	}

}

/**
 * The build state the Ref-field family reads, bundled once per
 * `WriterLowering` instance.
 *
 * `ctx` is the trivia gate, `ctorPat` / `fieldSep` / `bodyPolicy` /
 * `braceSym` the four bundles this family hands straight through, and
 * `isTightLead` / `isTriviaBearing` / `writeFnFor` the naming helpers that
 * stayed behind. Neither `shape` nor the format info appears, which is the
 * measurement that this family decides a field's layout from the field
 * itself.
 */
typedef RefFieldCtx = {
	final ctx: LoweringCtx;
	final ctorPat: WriterCtorPatternLowering.CtorPatternCtx;
	final fieldSep: WriterFieldSepLowering.FieldSepCtx;
	final bodyPolicy: WriterBodyPolicyLowering.BodyPolicyCtx;
	final braceSym: WriterBraceSymmetryLowering.BraceSymmetryCtx;
	final isTightLead: (leadText:Null<String>) -> Bool;
	final isTriviaBearing: (refName:String) -> Bool;
	final writeFnFor: (refName:String) -> String;
}
#end
