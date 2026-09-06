package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import anyparse.macro.WriterCtorPatternLowering.*;
import anyparse.macro.WriterLowering.PrevBodyInfo;
import anyparse.macro.WriterLowering.SameLineShapeAwareCtx;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterPolicyLowering.*;
import anyparse.macro.WriterTriviaSlotLowering.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W - the gap between a struct field and the sibling before it.
 *
 * One question, asked once per field boundary: what `Doc` goes BETWEEN the
 * previous emit and this one. `sameLineSeparator` resolves
 * `@:fmt(sameLine)` into that gap (with `sameLineSeparatorShapeAware` as its
 * body-shape-dependent arm), `beforeKwSeparator` layers the before-keyword
 * trivia slots and the bracket-body glue over it, `valueIfFitSeam` is the
 * arrow / value-`if` reflow seam spliced into the same place,
 * `buildBareRefLeadingSep` is the bare-`Ref` variant that reads the source
 * newline slot instead of a policy, and `padTrailingDoc` is the pad a field
 * leaves BEHIND for the next one.
 *
 * Like `WriterCtorPatternLowering` this is a LAYER rather than a family, and
 * the inbound side is again what says so: the Seq walker, five Ref-field
 * emitters and one Star emitter all call in. S117 read the same edges as an
 * ENTANGLEMENT between the Seq-field and Ref-field families - seven members
 * one reached into the other - and priced a joint extraction. The edges were
 * real; the reading was not. Four of those seven are these separator
 * builders and two are ctor-pattern lookups, so they belong to neither
 * family: with both layers named, Ref-field reaches nothing in Seq-field but
 * the three naming helpers every family reaches.
 *
 * The dependency surface is four fields - `ctx` for the trivia gate, the
 * ctor-pattern bundle for the block-shape switches, and the two naming
 * helpers that stayed in `WriterLowering`.
 */
@:access(anyparse.macro.WriterCtorPatternLowering, anyparse.macro.WriterLowering, anyparse.macro.WriterLoweringSupport,
	anyparse.macro.WriterPolicyLowering, anyparse.macro.WriterTriviaSlotLowering)
final class WriterFieldSepLowering {

	/**
	 * Return a Doc-separator expression for the whitespace that precedes
	 * a struct-field's kw/lead token.
	 *
	 * Without `@:fmt(sameLine(...))` metadata, emits a plain space (`_dt(' ')`) —
	 * the existing D61 behaviour. With `@:fmt(sameLine("flagName"))`, emits a
	 * switch on `opt.<flagName>:SameLinePolicy` picking between space
	 * (`Same`), hardline (`Next`), and a runtime slot lookup (`Keep`).
	 *
	 * ω-keep-policy: when the field is an `@:optional @:kw(...)` Ref AND
	 * the writer runs in trivia mode, the field's synth
	 * `<fieldName>BeforeKwNewline:Bool` slot drives the `Keep` branch —
	 * `true` emits a hardline (source had the kw on its own line),
	 * `false` emits a space (source had the kw inline with the preceding
	 * token). Plain mode / non-kw fields don't carry the slot, so `Keep`
	 * degrades to `Same`.
	 *
	 * ψ₉ opt-in shape-awareness via `@:fmt(shapeAware)`: when the field also
	 * carries the `@:fmt(shapeAware)` meta AND `prevBody` is non-null (the
	 * immediately preceding struct field was a bare-Ref wrapped via
	 * `bodyPolicyWrap`) AND the body's enum type has at least one block
	 * ctor, the emitted separator adds a runtime ctor switch on the
	 * preceding body's value: block ctors keep the flag-based layout,
	 * every other ctor forces a hardline. Used by `HxIfStmt.elseBody`
	 * where a lone `else` on the same line as a semicolon-terminated
	 * thenBody would collide visually with the body's terminator. NOT
	 * used by `HxDoWhileStmt.cond`'s `while` or `HxTryCatchStmt.catches`
	 * — those keywords are part of the loop/try structure and stay
	 * inline regardless of body shape, matching haxe-formatter's
	 * `sameLine.doWhile`/`tryCatch` defaults.
	 *
	 * Consumed by the two struct-field sites (non-optional kw, optional
	 * Ref/lead) for the boundary between a field and the preceding token. The try-parse Star
	 * `@:fmt(sameLine(...))` site in `emitWriterStarField` has its own inline
	 * handler (per-element separator, different semantic) and routes
	 * `Keep` to `Same` since there is no per-element source-shape slot.
	 */
	private static function sameLineSeparator(
		ctx: FieldSepCtx, child: ShapeNode, prevBody: Null<PrevBodyInfo>, typePath: String, ?prevPadTrailing: Expr
	): Expr {
		// ω-pad-trailing-ref: every return path wraps via the static
		// `withPadTrailingDrop` helper — drops the sep at runtime when
		// the immediately preceding field's `@:fmt(padTrailing)` fired.
		// No-op when `prevPadTrailing == null`, so existing callers (no
		// upstream padTrailing) stay byte-identical.
		final flagName: Null<String> = child.fmtReadString('sameLine');
		// ω-cond-comp-expr-multiline (sub-slice 6): default sep is
		// `_dossh()` (Doc.OptSpaceSkipAfterHardline) — emits `' '` to
		// keep tokens separated when the previous emit ended on the same
		// line, drops to nothing when the previous emit ended with a
		// hardline. Closes the spurious-space-after-hardline window
		// without conflating with `prevPadTrailing` (the latter is a
		// macro-time signal about the prior FIELD's pad-emission, while
		// this drop reads the renderer's runtime `lastEmit` state — they
		// fire under different conditions and stack cleanly:
		// `withPadTrailingDrop` collapses to `_de()` when prev's pad
		// fired, otherwise `_dossh()` handles the residual hardline-
		// trailing case from a non-pad-bearing prev field's body, e.g.
		// `HxConditionalStmt.body → '#elseif'-clause → '#else'` where
		// elseifs is non-empty so body's pad is masked but elseifs's
		// last body element still ends with a hardline).
		if (flagName == null) return withPadTrailingDrop(prevPadTrailing, macro _dossh());
		final optFlag: Expr = optFieldAccess(flagName);
		final fieldName: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		// Mirror of Lowering's `hasKwTriviaSlots` gate — `<field>BeforeKwNewline`
		// only exists on the synth paired `*T` type of trivia-bearing enclosing
		// rules. Non-bearing rules with `@:optional @:kw @:fmt(sameLine(...))`
		// would otherwise hit an EField on a nonexistent slot. No current
		// grammar triggers this combo (first non-bearing `@:optional @:kw` is
		// `HxIfExpr.elseBranch`, which has no `@:fmt(sameLine)`), but closing
		// the gap preemptively avoids recurrence of the Lowering fix pattern.
		final hasKeepSlot: Bool = ctx.ctx.trivia && ctx.isTriviaBearing(typePath) && fieldName != null && child.kind == Ref
			&& child.annotations[AnnotationKeys.BASE_OPTIONAL] == true && child.readMetaString(':kw') != null;
		final keepExpr: Expr = if (hasKeepSlot) {
			final slotAccess: Expr = {
				expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX),
				pos: Context.currentPos()
			};
			macro ($slotAccess ? _dhl() : _dt(' '));
		} else
			macro _dt(' ');
		final flagBased: Expr = sameLinePolicySwitch(optFlag, keepExpr);
		if (prevBody == null || !child.fmtHasFlag('shapeAware')) return withPadTrailingDrop(prevPadTrailing, flagBased);
		// ω-same-on-block: the block arm splits by the DELIMITER the branch opens
		// with, because `SameLinePolicy.SameOnBlock` promises a cuddle after a `}`
		// and after nothing else. A curly branch takes `flagBased`, where
		// `SameOnBlock` falls through the default to a plain space — the `} else`
		// join the policy is named for. A bracket branch takes the sibling switch,
		// where `SameOnBlock` routes to `keepExpr` and the source keeps its own
		// shape: gluing a `]` is house style, owned by the opt-in
		// `bracketBodyGlueIfFlag` knob layered outside this separator, not a
		// structural fact about the close. Every other `SameLinePolicy` value
		// reaches both arms through the same `buildPolicySwitch` cases as before,
		// so a grammar that never sees `SameOnBlock` is byte-identical.
		final curlyPatterns: Array<Expr> = collectCurlyBlockCtorPatterns(ctx.ctorPat, prevBody.typePath);
		final otherBlockPatterns: Array<Expr> = collectNonCurlyBlockCtorPatterns(ctx.ctorPat, prevBody.typePath);
		if (curlyPatterns.length + otherBlockPatterns.length == 0) return withPadTrailingDrop(prevPadTrailing, flagBased);
		final cases: Array<Case> = [];
		if (curlyPatterns.length > 0) cases.push({ values: curlyPatterns, expr: flagBased, guard: null });
		if (otherBlockPatterns.length > 0) cases.push({
			values: otherBlockPatterns,
			expr: sameLineNonCurlyBlockPolicySwitch(optFlag, keepExpr),
			guard: null
		});
		cases.push({ values: [macro _], expr: macro _dhl(), guard: null });
		final ctorSwitch: Expr = { expr: ESwitch(prevBody.access, cases, null), pos: Context.currentPos() };
		// omega-else-switch CLOSE side: a `switch` the knob glued to the PREVIOUS
		// branch's head closes with a `}` in that head's own column, so the
		// hardline the `_` arm above forces on every non-block ctor would leave
		// the keyword stranded under a close it is flush with. The verdict comes
		// from the previous FIELD (`PrevBodyInfo.headGlue`), never from this
		// field's meta: at `next` / `keep`, on a field the knob does not arm, and
		// under a captured comment that declined the glue, the same `switch` sits
		// one indent deeper and the hardline is the right answer. Routed to
		// `flagBased` rather than to a bare space so a glued close reads the same
		// `sameLine` policy a curly close already reads.
		final headGlue: Null<Expr> = prevBody.headGlue;
		final shapeAwareSwitch: Expr = headGlue == null ? ctorSwitch : macro ($headGlue ? $flagBased : $ctorSwitch);
		return sameLineSeparatorShapeAware(ctx, {
			child: child,
			prevBody: prevBody,
			prevPadTrailing: prevPadTrailing,
			flagBased: flagBased,
			shapeAwareSwitch: shapeAwareSwitch,
			hasKeepSlot: hasKeepSlot,
			fieldName: fieldName
		});
	}

	/**
	 * Wrap `sameLineSeparator` with the trivia-mode before-kw comment layers
	 * (ω-trivia-before-kw). In trivia mode, own-line comments captured between
	 * the preceding token and the kw land in `<field>BeforeKwLeading` (routed
	 * through the `kwBeforeDoc` runtime helper, which replaces the plain
	 * separator with hardline-separated comments at the parent indent), and a
	 * same-line trailing comment lands in `<field>BeforeKwTrailing` (routed
	 * through `kwBeforeTrailingDoc`, prepended so it cuddles the prior token).
	 * `useTriviaGap` false → the plain `sameLineSeparator` output. Shared by the
	 * optional-kw Star and bodyPolicy body-field emit paths.
	 */
	private static function beforeKwSeparator(
		ctx: FieldSepCtx, useTriviaGap: Bool, fieldName: String, child: ShapeNode, prevBodyField: Null<PrevBodyInfo>, typePath: String,
		prevPadTrailing: Null<Expr>
	): Expr {
		final beforeKwLeadingExpr: Null<Expr> = useTriviaGap ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX),
			pos: Context.currentPos()
		} : null;
		final beforeKwTrailingExpr: Null<Expr> = useTriviaGap ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX),
			pos: Context.currentPos()
		} : null;
		// omega-bracket-body-glue CLOSE side: the gap before a keyword whose PRECEDING
		// sibling is a body the knob hugs to its head. `HxIfExpr.elseBranch` is the one
		// consumer — `sameLineExpressionElse` resolves to `Keep` under
		// `expressionIf: next`, so the gap answers from the source, and a source that
		// wrote `];` on its own line keeps `else` on the next one forever. Turning the
		// knob on is the explicit statement that this shape closes with `] else`, the
		// mirror of the `if (c) [` it already opens with. Layered OUTSIDE
		// `sameLineSeparator` so the `Keep` slot, the `shapeAware` switch and the
		// `padTrailing` drop keep their exact bytes for every other field, and INSIDE the
		// comment layers below so a captured own-line comment still replaces the gap.
		final sepPlainExpr: Expr = sameLineSeparator(ctx, child, prevBodyField, typePath, prevPadTrailing);
		final glueTest: Null<Expr> = prevBodyField == null
			? null
			: buildBracketBodyGlueTest(
				ctx.ctorPat, child.fmtReadStringArgs(WriterLowering.BRACKET_BODY_GLUE), prevBodyField.typePath, prevBodyField.access
			);
		final sepBaseExpr: Expr = glueTest == null ? sepPlainExpr : {
			final glued: Expr = withPadTrailingDrop(prevPadTrailing, macro _dt(' '));
			macro ($glueTest ? $glued : $sepPlainExpr);
		};
		final sepWithBeforeKwExpr: Expr = beforeKwLeadingExpr != null
			? macro kwBeforeDoc($beforeKwLeadingExpr, $sepBaseExpr, opt)
			: sepBaseExpr;
		final sepExpr: Expr = beforeKwTrailingExpr != null
			? macro kwBeforeTrailingDoc($beforeKwTrailingExpr, $sepWithBeforeKwExpr, opt)
			: sepWithBeforeKwExpr;
		// omega-arrow-value-if-reflow: on `HxIfExpr.elseBranch` the pre-`else`
		// gap becomes a SOFT `Line(' ')` when the struct-level gate local
		// `_aifReflow` fires - the single break axis of an arrow-body value-if
		// chain. Flat inside the `Group` `lowerStruct` wraps the node in, a
		// newline at the `if`'s own indent when that group breaks. Replaces the
		// whole computed gap (the `shapeAware` hardline AND the `Same`-policy
		// space), since with the branch policy forced to `Same` the shape-aware
		// arm is suppressed and the space would leave the chain unbreakable.
		// omega-value-if-fit reuses the seam, with ONE extra refusal the arrow knob does not need: a
		// BLOCK previous body. A block-branch chain (`return if (c) { … } else if (d) { … }`) can
		// never collapse to one line, so the soft gap buys nothing there and costs the `} else` glue
		// `shapeAware` computes -- the chain would come back as `}` / `else if (…) {` on two lines.
		// The arrow knob keeps its unconditional override in BOTH arms, so its output is unchanged.
		return child.fmtHasFlag(WriterLowering.ARROW_VALUE_IF_SITE) ? valueIfFitSeam(ctx, prevBodyField, sepExpr) : sepExpr;
	}

	/**
	 * The pre-`else` gap of an `arrowValueIfReflowSite`: a soft `Line(" ")` under either re-flow gate,
	 * so the chain has ONE break axis its enclosing `Group` decides. `_vifFit` is ignored when the
	 * PREVIOUS body is a block ctor -- see the call site; `_aifReflow` overrides in both arms, which
	 * is what keeps the arrow knob byte-identical.
	 */
	private static function valueIfFitSeam(ctx: FieldSepCtx, prevBody: Null<PrevBodyInfo>, sepExpr: Expr): Expr {
		final blockPatterns: Array<Expr> = prevBody == null ? [] : collectBlockCtorPatterns(ctx.ctorPat, prevBody.typePath);
		if (blockPatterns.length == 0) return macro (_aifReflow || _vifFit ? _dl() : $sepExpr);
		final cases: Array<Case> = [
			{ values: blockPatterns, expr: macro (_aifReflow ? _dl() : $sepExpr), guard: null },
			{ values: [macro _], expr: macro (_aifReflow || _vifFit ? _dl() : $sepExpr), guard: null }
		];
		return { expr: ESwitch(prevBody.access, cases, null), pos: Context.currentPos() };
	}

	/**
	 * ω-cond-comp-expr-multiline — emit the Doc that a Ref-side
	 * `@:fmt(padTrailing)` site pushes between `child` and the next
	 * sibling (or the parent ctor's trail literal). In plain mode
	 * or when the parent's struct rule is non-trivia-bearing, falls
	 * back to a literal `_dt(' ')` (byte-identical to the inline
	 * push the helper replaced in sub-slice 1).
	 *
	 * In trivia mode, walks the children that follow `child`
	 * via `collectFollowingNewlineSignals` and builds a runtime
	 * ternary chain that picks `_dhl()` over `_dt(' ')` when ANY
	 * downstream field's leading-newline signal is true at write
	 * time:
	 *
	 *   `(g₀ ? s₀ : (g₁ ? s₁ : … (g_n ? s_n : false))) ? _dhl() : _dt(' ')`
	 *
	 * Each `(guard, signal)` pair represents one downstream
	 * boundary candidate — guard is "this field is present at
	 * runtime", signal is "this field's leading-newline slot is
	 * true". The first guarded-and-present field's signal wins;
	 * absent fields pass through to the next entry.
	 *
	 * Sub-slice 2 wires the two existing slot kinds — `@:trivia`
	 * Star first-element `newlineBefore` and optional-kw-Ref/Star
	 * `BeforeKwNewline`. Sub-slice 5 will add a terminal entry on
	 * `child` itself (`<field>NewlineAfter`) for the
	 * parent-trail-literal boundary case where no downstream
	 * sibling carries a slot.
	 *
	 * Centralised so all three Ref-kind pad emit sites (mandatory
	 * Ref at the end-of-loop block, optional Ref inside `optParts`,
	 * and any future Ref-kind opt-in) share one decision surface.
	 * Star-kind fields keep their existing in-helper pad emission
	 * (`triviaTryparseStarExpr` reads `_arr[0].newlineBefore` for
	 * its own first-element signal — Star→Star path was
	 * pre-existing and unrelated to this slice's Ref-kind lift).
	 */
	private static function padTrailingDoc(ctx: FieldSepCtx, parent: ShapeNode, child: ShapeNode, typePath: String): Expr {
		if (!ctx.ctx.trivia || !ctx.isTriviaBearing(typePath)) return macro _dt(' ');
		final signals: Array<{ guard: Expr, signal: Expr }> = collectFollowingNewlineSignals(parent, child);
		if (signals.length == 0) return macro _dt(' ');
		var picked: Expr = macro false;
		var i: Int = signals.length;
		while (i-- > 0) {
			final sig: { guard: Expr, signal: Expr } = signals[i];
			final guard: Expr = sig.guard;
			final signal: Expr = sig.signal;
			picked = macro $guard ? $signal : $picked;
		}
		// omega-cond-expr-fit: `@:fmt(condExprFitBreak)` fields swap the flat
		// space for a soft `Line(' ')` under the runtime knob. The soft Line
		// must never land outside the ctor-level `condExprFitGroup` group
		// (root render mode is MBreak, so ungrouped it renders as a NEWLINE,
		// not a space) - the invariant holds by grammar co-location: the same
		// knob builds the group, and every flag carrier is a field of
		// `HxConditionalExpr`, consumed only by the group-building ctor.
		return child.fmtHasFlag('condExprFitBreak')
			? macro $picked ? _dhl() : (opt.conditionalExprFit ? _dl() : _dt(' '))
			: macro $picked ? _dhl() : _dt(' ');
	}

	/**
	 * Shape-aware tail of `sameLineSeparator`: given the shape-aware
	 * switch and `flagBased` sep, layer the body-policy inline probe and
	 * the `semicolonNextLineElse` `;`-tail discriminator on top, then wrap
	 * via `withPadTrailingDrop`. Extracted to keep `sameLineSeparator`
	 * below the complexity gate.
	 */
	private static function sameLineSeparatorShapeAware(ctx: FieldSepCtx, c: SameLineShapeAwareCtx): Expr {
		// ω-expression-case-flat-fanout: shape-aware-break for `else` is
		// correct only when the child body actually lays out on its own
		// line. The child's runtime layout is driven by `opt.<bodyPolicy>`:
		//  - `Same` — body is forced inline → else-break is wrong, fall to
		//    flagBased (sameLineElse drives the gap).
		//  - `Keep` + slot says source had body inline (`!BeforeKwNewline`)
		//    → body is inline → suppress, fall to flagBased.
		//  - `Next` / `FitLine` / `Keep`+slot=broken — body sits on its own
		//    line → keep the pre-slice shape-break.
		// Default `elseBody=Next` keeps existing behaviour. Without this
		// gate, fanning `elseBody` to `expressionCase` inside a flat case
		// body would still produce `if (cond) body;\n\telse elseBody;`
		// because shape-aware would force `else` to its own line
		// regardless of the runtime body decision. Children without a
		// `bodyPolicy` meta (no current consumers, but defensive) keep the
		// pre-slice unconditional shape-aware switch.
		// ω-issue-257-else-in-return-switch: dual-flag bodyPolicy on the
		// child propagates here too — the inline-shape probe must
		// dispatch on `opt._inExprPosition` so an expr-position parent
		// (e.g. inner `if/else` in the case body of a return-switch
		// when `expressionIf=Same`) reads the expr-side knob and
		// suppresses the shape-aware else-break consistently with the
		// dispatched body layout in `bodyPolicyWrap`. Single-flag
		// callers (no second arg) keep the byte-identical pre-slice
		// access.
		final childBodyPolicy: { stmt: Null<String>, expr: Null<String> } = readBodyPolicyDual(c.child);
		final childBodyPolicyFlag: Null<String> = childBodyPolicy.stmt;
		if (childBodyPolicyFlag == null) return withPadTrailingDrop(c.prevPadTrailing, c.shapeAwareSwitch);
		final stmtBpAccess: Expr = optFieldAccess(childBodyPolicyFlag);
		final bpAccess: Expr = if (childBodyPolicy.expr == null)
			stmtBpAccess
		else {
			final exprBpAccess: Expr = optFieldAccess(childBodyPolicy.expr);
			macro (opt._inExprPosition ? $exprBpAccess : $stmtBpAccess);
		};
		final samePat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Same']);
		final keepPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Keep']);
		final isInlineExpr: Expr = if (c.hasKeepSlot) {
			final slotAccess: Expr = {
				expr: EField(macro value, c.fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX),
				pos: Context.currentPos()
			};
			macro ($bpAccess == $samePat || ($bpAccess == $keepPat && !$slotAccess));
		} else
			macro $bpAccess == $samePat;
		// ω-ifelse-semicolon-next-line: when the body is forced inline
		// (`isInlineExpr` — e.g. `sameLine.ifBody:same`) the pre-slice
		// shape obeyed `flagBased` (`sameLineElse`), gluing `else` after a
		// `;`-terminated non-block then-body. Mirror fork's
		// `MarkSameLine.markElse` Semicolon branch: when the rendered
		// then-body ends with a `;` (the token immediately before `else`)
		// AND `opt.ifElseSemicolonNextLine` is set, break `else` onto its
		// own line instead. The discriminator is the then-body's RENDERED
		// Doc, re-derived by re-rendering the then-body value through its
		// own write fn and inspecting the right-spine tail via
		// `DocMeasure.endsWithSemi` (a bounded right-spine walk — NOT a
		// layout probe). `endsWithSemi` treats ONLY `;` as a terminator,
		// not `}`, so block then-bodies (`if (c) {…} else …`) keep gluing
		// and `;`-omitting non-blocks (`if (c) foo else …`) keep gluing —
		// matching the fixtures' rows. Re-rendering is pure (no state
		// mutation, INVARIANT #1) and produces the same Doc as the actual
		// emit, so the tail byte is authoritative.
		//
		// Gated on the opt-in `@:fmt(semicolonNextLineElse)` flag, present
		// ONLY on `HxIfStmt.elseBody`. The fork's `ifElseSemicolonNextLine`
		// is a statement-`if` rule, so two more gates pin it tightly:
		//   - macro-time `ctx.trivia`: source-`;`-presence is only knowable
		//     in the trivia pipeline (the corpus harness). The plain writer
		//     canonicalises `;`, so "did the source have `;`" is meaningless
		//     there — plain mode stays byte-identical (falls to `flagBased`).
		//   - runtime `!opt._inExprPosition`: value-position `if`
		//     (`return switch … case A: if (c) a(); else b()`, or
		//     `final x = if (a) b; else c`) is governed by
		//     `sameLineExpressionElse`, not the statement rule — keep `else`
		//     glued there. Mirrors fork's `MarkSameLine.markElse` (statement
		//     `if` only).
		final inlineSep: Expr = if (ctx.ctx.trivia && c.child.fmtHasFlag('semicolonNextLineElse')) {
			final prevWriteFn: String = ctx.writeFnFor(c.prevBody.typePath);
			final prevAccess: Expr = c.prevBody.access;
			final prevDoc: Expr = { expr: ECall(macro $i{prevWriteFn}, [prevAccess, macro opt]), pos: Context.currentPos() };
			macro (
				!opt._inExprPosition && opt.ifElseSemicolonNextLine && anyparse.core.DocMeasure.endsWithSemi($prevDoc)
					? _dhl()
					: ${c.flagBased}
			);
		} else
			c.flagBased;
		return withPadTrailingDrop(c.prevPadTrailing, macro $isInlineExpr ? $inlineSep : ${c.shapeAwareSwitch});
	}

	/**
	 * Leading separator for a bare (kw-less, lead-less) non-first Ref field.
	 *
	 * Shared by the mandatory path (`emitBareRefNonFirstBody`) and by the
	 * `@:optional @:absentOn` path opted in via `@:fmt(bareRefSepWhenPresent)`
	 * — a field that MAY be absent still needs the mandatory field's exact
	 * separator whenever it IS present, otherwise the gap between the
	 * preceding Star and the field's first token vanishes (`static inline`
	 * plus a `final x` member writing out as `static inlinefinal x`). The
	 * optional caller splices the result INSIDE its own null check, so an
	 * absent field contributes nothing at all.
	 */
	private static function buildBareRefLeadingSep(
		ctx: FieldSepCtx, child: ShapeNode, fieldName: String, typePath: String, prevAnyStarNonEmpty: Null<Expr>,
		prevPadTrailing: Null<Expr>, ?keepBlankGate: Null<Expr>
	): Expr {
		// ω-issue-48-v2: in trivia mode the bare Ref field grew a
		// `<field>BeforeNewline:Bool` slot (see `TriviaTypeSynth.isBareNonFirstRef`).
		// Consult it to emit a hardline when the parser captured a source newline
		// in the gap — this is the only signal available when a preceding
		// bare-tryparse Star (e.g. `HxMemberDecl.modifiers`) is empty, since that
		// Star has no first element whose `newlineBefore` could be read.
		if (ctx.ctx.trivia && ctx.isTriviaBearing(typePath)) {
			final nlAccess: Expr = beforeNewlineAccess(fieldName);
			// ω-splice-op-fill: `@:fmt(fillSeam)` hands this field's leading
			// separator to the STRUCT's `@:fmt(fillParts)` assembly — the
			// gap becomes a `Fill` seam, so the field itself contributes
			// `_de()` and the source-newline slot is not consulted. The
			// `buildBeforeLeadingSep` wrap still runs, so a comment the
			// parser captured in the gap is still emitted (as a Fill item
			// of its own); an empty slot leaves `_de()`, which
			// `D.fillOnOverflow` drops rather than counting as an item.
			// ω-splice-op-fill: `@:fmt(inlineSep)` is the same decision
			// for a gap the enclosing fill does NOT own — a single space,
			// never a break. Consumer: `HxCondSpliceOpTerm.op`, where the
			// operator must stay glued to the operand it closes.
			final fillSeam: Bool = child.fmtHasFlag('fillSeam');
			final inlineSep: Bool = child.fmtHasFlag('inlineSep');
			// ω-region-prefix-blank: `@:fmt(keepBlankAfterStarCtor(...))` adds one
			// state to this gap — a source BLANK, which `BeforeNewline` alone
			// cannot distinguish from a single break — and only when the gate says
			// the whole prefix is a `#if … #end` region.
			final blankBreak: Expr = dcCall([macro _dhl(), macro _dhl()]);
			final nlSep: Expr = keepBlankGate == null ? macro $nlAccess ? _dhl() : _dt(' ') : {
				final gate: Expr = keepBlankGate;
				final blankAccess: Expr = beforeBlankAccess(fieldName);
				macro $blankAccess && $gate ? $blankBreak : ($nlAccess ? _dhl() : _dt(' '));
			};
			final triviaSepExpr: Expr = if (fillSeam)
				macro _de();
			else if (inlineSep)
				macro _dt(' ');
			else if (prevAnyStarNonEmpty != null) {
				final prev: Expr = prevAnyStarNonEmpty;
				macro $prev ? $nlSep : _de();
			} else
				nlSep;
			// ω-598-member-leading-comment: own-line gap comments — see buildBeforeLeadingSep.
			final sepWithLeading: Expr = buildBeforeLeadingSep(child, fieldName, triviaSepExpr);
			return withPadTrailingDrop(prevPadTrailing, sepWithLeading);
		}
		if (prevAnyStarNonEmpty == null) return withPadTrailingDrop(prevPadTrailing, macro _dt(' '));
		final prev: Expr = prevAnyStarNonEmpty;
		return withPadTrailingDrop(prevPadTrailing, macro $prev ? _dt(' ') : _de());
	}

}

/**
 * The build state the separator builders read, bundled once per
 * `WriterLowering` instance.
 *
 * `ctx` is the trivia gate every source-fidelity branch opens with,
 * `ctorPat` the ctor-pattern layer these builders switch on, and
 * `isTriviaBearing` / `writeFnFor` the two naming helpers that stayed
 * behind. A member here that needs `shape` or the format info directly is
 * a member that stopped being a separator.
 */
typedef FieldSepCtx = {
	final ctx: LoweringCtx;
	final ctorPat: WriterCtorPatternLowering.CtorPatternCtx;
	final isTriviaBearing: (refName:String) -> Bool;
	final writeFnFor: (refName:String) -> String;
}
#end
