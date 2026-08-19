package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 3W helpers — the `@:trivia` + `@:tryparse` Star emit family.
 *
 * Builds the generated writer body for a tryparse Star (member lists,
 * case / default bodies, conditional-compilation branch bodies, class
 * heritage clauses): the per-iteration `while` loop, the inter-element
 * separator cascade, the ctor-blank cascade wiring, the case-body
 * flat / fit gates, the block-ended `;` re-emission, the heritage fill
 * layout, the shape / glue refusals, and the final assembly of the
 * Star's `Doc` parts.
 *
 * Split out of `WriterLowering` for size — the two are NOT independent.
 * The macro-time surface is small: one inbound call
 * (`triviaTryparseStarExpr`, from `WriterLowering.emitTriviaTryparseStar`)
 * and a short outbound list back into the shared lowering utilities
 * (`optFieldAccess`, `astPredCallT`, `buildCascadeEmit`,
 * `buildCaseBodyFlagPredicate`, `buildCaseBodyFitPredicate`,
 * `blankBefore2ExtrasExpr` — the last one is shared with the sibling
 * block-Star and sep-Star families, which is why it stayed behind). Both
 * directions run through `@:access` and every member here stays private.
 *
 * Parameters typed by a `WriterLowering` sub-module typedef stay
 * qualified: the extraction moved the functions, not the typedefs, so the
 * whole sub-module typedef block still lives in `WriterLowering`'s module
 * and this file imports nothing from it. The ctor-blank infos are also
 * read by the cascade members that stayed behind; `TryparseStarCtx` is now
 * read only from here.
 *
 * The GENERATED-code surface is the real contract, and no type carries it:
 * every helper splices identifiers declared elsewhere in the Star body —
 * `_arr` / `_t` / `_si` / `_elem` / `opt` from the Star scaffold, and the
 * Doc wrappers and opt helpers `WriterCodegen` emits on the generated
 * class (`_dt()` / `_dc()` / `_dn()` / `_de()` / `_dhl()` / `_dwb()` /
 * `_dile()` / `_dohsbh()`, `_copyOpt` / `_clearExprPosition` /
 * `_setIntersectionBreak`, `leadingCommentDocRun` /
 * `trailingCommentDoc*`). Rename one of those on either side and the
 * failure surfaces in the generated writer, not here.
 */
final class TriviaTryparseLowering {

	/**
	 * Tryparse-Star `flatGateExpr` builder (ω-case-body-policy /
	 * ω-issue-423-mech-a). Builds the runtime COMMITTED-flatten gate from the
	 * `@:fmt(bodyPolicy(...))` flag names: single-flag, dual-flag (dispatch
	 * on `opt._inExprPosition`), or `false`.
	 */
	private static inline function triviaTryparseFlatGateExpr(caseBodyFlagNames: Null<Array<String>>): Expr {
		return triviaTryparseCaseGateExpr(caseBodyFlagNames, false);
	}

	/**
	 * ω-case-body-fitline — the `FitLine` sibling of `triviaTryparseFlatGateExpr`.
	 *
	 * Same dual-flag dispatch, different per-flag predicate: reports that
	 * the resolved policy is `FitLine`, i.e. the flat/break choice is the
	 * renderer's. Consumed by the `_fitCase` runtime local, which is
	 * computed AFTER `_flatCase` and is mutually exclusive with it (a
	 * policy is `Same`/`Keep` or `FitLine`, never both).
	 */
	private static inline function triviaTryparseFitGateExpr(caseBodyFlagNames: Null<Array<String>>): Expr {
		return triviaTryparseCaseGateExpr(caseBodyFlagNames, true);
	}

	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseStarExpr(
		fieldAccess: Expr, elemFn: String, sepExpr: Expr, sepBeforeFirst: Bool, nestBody: Bool, trailBBAccess: Null<Expr>,
		trailLCAccess: Null<Expr>, trailBAAccess: Null<Expr>, ?firstSepOverride: Expr, ?subsequentSepOverride: Expr,
		?caseBodyFlagNames: Array<String>, ?flatChildOptPairs: Array<Array<String>>, padLeading: Bool = false, padTrailing: Bool = false,
		propagateExprPosition: Bool = false, refuseFlatOnComplex: Bool = false, ?afterCtorInfos: Array<WriterLowering.AfterCtorBlankInfo>,
		?beforeCtorInfos: Array<WriterLowering.BeforeCtorBlankInfo>, ?betweenCtorInfos: Array<WriterLowering.BetweenCtorBlankInfo>,
		?transitionAcrossInfos: Array<WriterLowering.TransitionAcrossInfo>, ?headCtorInfos: Array<WriterLowering.HeadCtorBlankInfo>,
		?metaLineEndOptField: String, ?betweenSameCtorIfNotInfos: Array<WriterLowering.BetweenSameCtorIfNotInfo>,
		lineLengthAwareSeps: Bool = false, ?priorAfterTrailExpr: Expr, forceInlineSep: Bool = false,
		// ω-blockended-trivia-tryparse (Session 3): when the tryparse
		// Star carries `@:sep('text', tailRelax, blockEnded)`, the
		// per-iteration emit inserts `;` (or other sepText) between two
		// non-`}`-ending elements before the existing hardline / space
		// dispatch. Null sepText → byte-identical to pre-slice.
		?sepText: String,
		blockEnded: Bool = false,
		// ω-sep-faithful: source-fidelity sep re-emission (see
		// triviaTryparseBlockEndedSepEmit) — comma-lists inside
		// conditional element groups. Mutually exclusive with blockEnded.
		sepFaithful: Bool = false,
		// B4 ω-implements-extends-wrap: HxClassDecl/HxInterfaceDecl heritage
		// Star. When true, MULTI-clause heritage uses fork FillLine layout
		// (pack-from-front, break overflow clause at additionalIndent 2);
		// single-clause stays on the lineLengthAwareSeps 1-tab break path.
		heritageWrap: Bool = false,
		// ω-cond-indent-policy: cond-comp body Star opts into the runtime
		// `opt.conditionalPolicy` indent rule. Default false → byte-inert.
		condBodyIndent: Bool = false,
		// ω-typedef-intersection-operand-break: when true, each Star element
		// whose PRECEDING element rendered multi-line and ended with a close
		// brace (a broke anon-struct operand) receives a per-element opt copy
		// with `_intersectionOperandBreak = true`, so the element's
		// `@:fmt(typedefIntersectionBreak)` lead emits `&\n\t` before the
		// operand. The discriminator is purely structural — `flatLength(prev) <
		// 0` (prev has a committed hardline) AND `endsWithCloseDelim(prev)`
		// (prev ends with `}`/`)`/`]`) — so single-line intersections stay
		// glued. First (and only) consumer: `HxTypedefDecl.intersections`.
		operandBreakAfterMultilineBrace: Bool = false,
		// ω-value-yielded-if-tail-barrier (case-body extension of SI-2): when
		// the case-body / default-body Star carries
		// `@:fmt(clearExprPositionNonTail)` (paired with
		// `@:fmt(propagateExprPosition)`), every NON-tail body statement's
		// element-opt is wrapped in `_clearExprPosition` so a discarded
		// statement (e.g. `if (c) return x;` before the tail) reverts to the
		// statement-position `ifBody` policy. The body's LAST statement (the
		// case's yielded value when the switch is itself in expression
		// position) keeps the inherited expression-position frame. Mirrors the
		// `triviaBlockStarExpr` SI-2 mechanism for BlockExpr / BlockStmt; the
		// case body routes through THIS Star (`@:tryparse`), not
		// `triviaBlockStarExpr`. False → byte-identical to the pre-slice call.
		clearExprPositionNonTail: Bool = false,
		// ω-sep-faithful: runtime access to the `<field>SepBefore`
		// slot; when non-null and true at write time, the leading pad becomes
		// `sep + ' '` (re-emitting the source's leading sep inside the group).
		?sepBeforeAccess: Expr,
		// ω-cond-comp-elseif-double-newline: elements of this Star each
		// self-terminate with their own @:fmt(padTrailing) hardline (the
		// cond-comp `elseifs` Stars — every HxElseif* ends its body with a
		// padTrailing `\n` before the next `#elseif`/`#else`/`#end`). When true,
		// the inter-element `_si > 0 && newlineBefore` separator skips its base
		// `_dhl()` (the preceding element's padTrailing already supplied it);
		// double-emitting inserts a spurious blank that COMPOUNDS on re-format.
		// Blank-line extras (authored blanks) are still emitted. Default false.
		elemSelfTrailsNewline: Bool = false,
		// omega-cond-expr-fit: the Star carries `@:fmt(condExprFitBreak)` (the
		// expression-scope cond-comp `elseifs`). Its inter-element and
		// trailing-pad SPACE separators become knob-gated soft `Line(' ')`
		// docs, so they break together with the ctor-level
		// `condExprFitGroup` group. Default false -> byte-identical.
		// Mutually exclusive with `lineLengthAwareSeps` (disjoint carriers
		// today): the sep builders prefer that flag, and the trailing-pad
		// soft doc ignores it - a Star carrying both would get split-brain
		// separators.
		condExprFitSeps: Bool = false,
		// Typed nested-conditional element probe: the
		// `<AstPredsT>.elementIsConditional_<ElemRule>` function-reference
		// Expr, built at the instance caller (where the Star's element
		// rule is in scope) iff the format declares `astPreds`. Applied
		// to `_t.node` (alignedNestedIncrease span lift) and
		// `_arr[_si - 1].node` (blockEnded sep suppression). Null → both
		// sites emit their inert `false`, byte-identical for formats
		// without generated predicates.
		?elemCondFnExpr: Expr,
		// omega-case-body-controlflow-glue: when the case-body Star carries
		// `@:fmt(refuseGlueOnControlFlowRoot)`, a `FitLine` body that cannot
		// render flat AND whose single statement is keyword-led control flow
		// takes the BREAK shape instead of gluing onto the case label. The
		// enclosing case-LIST Star reads the same meta back off this one
		// (`elemBodyStarHasFlag`) to gate its sibling FORCE, so the placement and
		// the spread turn on together. False -> byte-identical to the pre-slice
		// call, here and in the pre-pass.
		refuseGlueOnControlFlow: Bool = false
	): Expr {
		// noqa: complexity
		// ω-bug-2c-inner-star — cascade emit for the tryparse-Star path.
		// Cascade trackers + cascade-fire blank count come from
		// `buildCascadeEmit`; consumer splices `$cascadeInitPrev` once
		// before the while loop (in `_docs` outer scope), `$cascadeInitCurr`
		// + `$cascadeCurrCompute` at the top of each iteration, replaces
		// the source-driven `if (blankBefore) push(\\n)` between iterations
		// with a `_blanks` cascade loop, and `$cascadeTrackPrev` at the end
		// of each iteration. With all info arrays empty, the cascade
		// fallback is `(_t.blankBefore ? 1 : 0)` — byte-identical to the
		// pre-slice behavior on `_si > 0 && _t.newlineBefore`.
		final afterInfos: Array<WriterLowering.AfterCtorBlankInfo> = afterCtorInfos ?? [];
		final beforeInfos: Array<WriterLowering.BeforeCtorBlankInfo> = beforeCtorInfos ?? [];
		final betweenInfos: Array<WriterLowering.BetweenCtorBlankInfo> = betweenCtorInfos ?? [];
		final transitionInfos: Array<WriterLowering.TransitionAcrossInfo> = transitionAcrossInfos ?? [];
		final headInfos: Array<WriterLowering.HeadCtorBlankInfo> = headCtorInfos ?? [];
		final betweenIfNotInfos: Array<WriterLowering.BetweenSameCtorIfNotInfo> = betweenSameCtorIfNotInfos ?? [];
		final cascadeEmit: WriterLowering.CascadeEmit = WriterLowering.buildCascadeEmit(
			afterInfos, beforeInfos, betweenInfos, transitionInfos, headInfos, betweenIfNotInfos
		);
		final cascadeInitPrev: Expr = cascadeEmit.initPrev;
		final cascadeInitCurr: Expr = cascadeEmit.initCurr;
		final cascadeCurrCompute: Expr = cascadeEmit.currCompute;
		final cascadeTrackPrev: Expr = cascadeEmit.trackPrev;
		// ω-meta-strip-blanks: meta Stars cap inter-element separator at a single
		// hardline (metaLineEndOptField); ω-slice-45: forceInlineSep Stars short-
		// circuit cascade blanks too. Both ⇒ macro 0; else the cascade count.
		final cascadeBlanksCount: Expr = metaLineEndOptField != null || forceInlineSep ? macro 0 : cascadeEmit.blanksCount;
		// ω-before-package — head-of-Star override; `macro {}` when no
		// `blankLinesAtHeadIfCtor` meta on this inner Star (byte-identical).
		final cascadeHeadEmit: Expr = cascadeEmit.headEmit;
		final elemCallExprs = triviaTryparseElemCallExprs(elemFn, clearExprPositionNonTail, operandBreakAfterMultilineBrace);
		final triviaElemCall: Expr = elemCallExprs.triviaElemCall;
		final triviaElemCallMaybeBreak: Expr = elemCallExprs.triviaElemCallMaybeBreak;
		final elemOptInit: Expr = elemCallExprs.elemOptInit;
		final sepBeforeFirstExpr: Expr = macro $v{sepBeforeFirst};
		final nestBodyExpr: Expr = macro $v{nestBody};
		final trailBB: Expr = trailBBAccess ?? macro false;
		final trailLC: Expr = trailLCAccess ?? macro ([]: Array<String>);
		// ω-trail-blank-after: extra hardline at trail tail when source had a
		// blank between orphan trail and next outer sibling. Null ⇒ false.
		final trailBA: Expr = trailBAAccess ?? macro false;
		// ω-close-trailing-alt / ω-block-shape-aware: first / subsequent element
		// separators pick their override when supplied, else fall back to sepExpr.
		final firstSepExpr: Expr = firstSepOverride ?? sepExpr;
		final subsequentSepExpr: Expr = subsequentSepOverride ?? sepExpr;
		final flatGateExpr: Expr = triviaTryparseFlatGateExpr(caseBodyFlagNames);
		final fitGateExpr: Expr = triviaTryparseFitGateExpr(caseBodyFlagNames);
		final writerOptExpr: Expr = triviaTryparseWriterOptExpr(flatChildOptPairs, propagateExprPosition);
		final padLeadingExpr: Expr = macro $v{padLeading};
		final padTrailingExpr: Expr = macro $v{padTrailing};
		// ω-trivia-tryparse-linelength: swap hard `_dt(' ')` separators for
		// `_dile(...)` line-length probes when the Star carries
		// `@:fmt(lineLengthAwareSeps)`.
		final basePadLeadingSpaceDoc: Expr = lineLengthAwareSeps ? macro _dile(opt.lineWidth, _dhl(), _dt(' ')) : macro _dt(' ');
		final padLeadingSpaceDoc: Expr = sepBeforeAccess != null && sepText != null
			? macro ($sepBeforeAccess ? _dt($v{sepText + ' '}) : $basePadLeadingSpaceDoc)
			: basePadLeadingSpaceDoc;
		// omega-cond-expr-fit: soft inter-element / trailing-pad separators for
		// the `@:fmt(condExprFitBreak)` Star - a space while the ctor-level
		// group fits, a break when it does not. Knob-gated at runtime so the
		// default stays byte-identical.
		final subsequentSepDoc: Expr = if (lineLengthAwareSeps)
			macro _dile(opt.lineWidth, _dhl(), _dt(' '))
		else if (condExprFitSeps)
			macro (opt.conditionalExprFit ? _dl() : $subsequentSepExpr)
		else
			subsequentSepExpr;
		final trailPadSpaceDoc: Expr = condExprFitSeps ? macro (opt.conditionalExprFit ? _dl() : _dt(' ')) : macro _dt(' ');
		final priorAfterTrailEmit: Expr = triviaTryparsePriorAfterTrailEmit(priorAfterTrailExpr);
		final finalWrapDocs: Expr = triviaTryparseFinalWrapDocs(lineLengthAwareSeps);
		final condIncreaseGateExpr: Expr = triviaTryparseCondIncreaseGateExpr(condBodyIndent);
		final condNestedIncreaseGateExpr: Expr = triviaTryparseCondNestedIncreaseGateExpr(condBodyIndent);
		final lastTrailTerminatorEmit: Expr = macro {};
		// ω-metadata-line-end-function: runtime `_metaPolicy:Int` from
		// `opt.<metaLineEndOptField>` (0 = None default, byte-identical).
		final metaPolicyExpr: Expr = metaLineEndOptField != null ? WriterLowering.optFieldAccess(metaLineEndOptField) : macro 0;
		final shapeRefusalExpr: Expr = triviaTryparseShapeRefusalExpr(refuseFlatOnComplex);
		final glueRefusalExpr: Expr = triviaTryparseGlueRefusalExpr(refuseGlueOnControlFlow);
		final tryparseBlockEndedSepEmit: Expr = triviaTryparseBlockEndedSepEmit(sepText, blockEnded, sepFaithful, elemCondFnExpr);
		final tryparseBlockEndedTrailEmit: Expr = triviaTryparseBlockEndedTrailEmit(sepText, blockEnded, sepFaithful);
		final c: WriterLowering.TryparseStarCtx = {
			fieldAccess: fieldAccess,
			trailBB: trailBB,
			trailLC: trailLC,
			trailBA: trailBA,
			sepBeforeFirstExpr: sepBeforeFirstExpr,
			nestBodyExpr: nestBodyExpr,
			shapeRefusalExpr: shapeRefusalExpr,
			glueRefusalExpr: glueRefusalExpr,
			flatGateExpr: flatGateExpr,
			fitGateExpr: fitGateExpr,
			writerOptExpr: writerOptExpr,
			padLeadingExpr: padLeadingExpr,
			padTrailingExpr: padTrailingExpr,
			metaPolicyExpr: metaPolicyExpr,
			condIncreaseGateExpr: condIncreaseGateExpr,
			condNestedIncreaseGateExpr: condNestedIncreaseGateExpr,
			cascadeInitPrev: cascadeInitPrev,
			cascadeInitCurr: cascadeInitCurr,
			cascadeCurrCompute: cascadeCurrCompute,
			cascadeTrackPrev: cascadeTrackPrev,
			cascadeHeadEmit: cascadeHeadEmit,
			cascadeBlanksCount: cascadeBlanksCount,
			priorAfterTrailEmit: priorAfterTrailEmit,
			priorAfterTrailRaw: priorAfterTrailExpr ?? macro (null: Null<String>),
			padLeadingSpaceDoc: padLeadingSpaceDoc,
			subsequentSepDoc: subsequentSepDoc,
			firstSepExpr: firstSepExpr,
			triviaElemCall: triviaElemCall,
			triviaElemCallMaybeBreak: triviaElemCallMaybeBreak,
			elemOptInit: elemOptInit,
			tryparseBlockEndedSepEmit: tryparseBlockEndedSepEmit,
			tryparseBlockEndedTrailEmit: tryparseBlockEndedTrailEmit,
			lastTrailTerminatorEmit: lastTrailTerminatorEmit,
			trailPadSpaceDoc: trailPadSpaceDoc,
			finalWrapDocs: finalWrapDocs,
			forceInlineSep: forceInlineSep,
			elemSelfTrailsNewline: elemSelfTrailsNewline,
			elemCondFn: elemCondFnExpr
		};
		return heritageWrap ? triviaTryparseHeritageExpr(c) : triviaTryparseMainExpr(c);
	}

	/**
	 * Tryparse-Star heritage-wrap emit (B4 ω-implements-extends-wrap):
	 * dedicated heritage emit bypassing the shared incremental loop.
	 * MULTI-clause heritage packs clauses from the front via `Fill` and
	 * breaks the overflow clause(s) at additionalIndent 2; single-clause
	 * heritage stays byte-identical to the `lineLengthAwareSeps` path.
	 *
	 */
	private static function triviaTryparseHeritageExpr(c: WriterLowering.TryparseStarCtx): Expr {
		final fieldAccess: Expr = c.fieldAccess;
		final writerOptExpr: Expr = c.writerOptExpr;
		final triviaElemCall: Expr = c.triviaElemCall;
		final multiClauseExpr: Expr = triviaTryparseHeritageMultiExpr();
		return macro {
			final _arr = $fieldAccess;
			if (_arr.length == 0)
				_de()
			else {
				final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				final _writerOpt = $writerOptExpr;
				var _hasComments: Bool = false;
				var _hci: Int = 0;
				while (_hci < _arr.length) {
					if (_arr[_hci].leadingComments.length > 0 || _arr[_hci].trailingComment != null) _hasComments = true;
					_hci++;
				}
				final _items: Array<anyparse.core.Doc> = [];
				var _hi: Int = 0;
				while (_hi < _arr.length) {
					final _t = _arr[_hi];
					_items.push($triviaElemCall);
					_hi++;
				}
				if (_hasComments) {
					final _docs: Array<anyparse.core.Doc> = [_dt(' ')];
					var _hj: Int = 0;
					while (_hj < _items.length) {
						if (_hj > 0) _docs.push(_dt(' '));
						_docs.push(_items[_hj]);
						_hj++;
					}
					_dc(_docs);
				} else if (_items.length <= 1) {
					_dn(_cols, _dc([_dile(opt.lineWidth, _dhl(), _dt(' ')), _items[0]]));
				} else {
					$multiClauseExpr;
				}
			}
		};
	}

	/**
	 * Tryparse-Star heritage multi-clause layout (B4 ω-implements-extends-wrap):
	 * config-driven multi-clause wrap. Resolves the fork-style WrapRules
	 * cascade (via triviaTryparseHeritageResolveExpr) then builds the broken
	 * layout for the resolved mode plus the glued fallback, gated via the
	 * lineLength threshold. References the runtime `_arr`/`_items`/`_cols`/
	 * `opt` locals declared in `triviaTryparseHeritageExpr`'s emitted scope.
	 * Extracted so the heritage emit stays under the complexity gate.
	 */
	private static function triviaTryparseHeritageMultiExpr(): Expr {
		final resolveExpr: Expr = triviaTryparseHeritageResolveExpr();
		return macro {
			// B4 ω-implements-extends-wrap: config-driven multi-clause
			// layout. Resolve the fork-style WrapRules cascade at write
			// time from opt.implementsExtendsWrap. lineLength rules gate
			// via IfLineExceeds (prefix-aware); itemCount / defaultMode
			// resolve as plain Haxe. additionalIndent comes from the
			// cascade (defaultAdditionalIndent; anyparse WrapRule has no
			// per-rule indent — see HaxeFormat.defaultImplementsExtendsWrap).
			final _rules = opt.implementsExtendsWrap;
			final _ai: Int = _cols * (_rules.defaultAdditionalIndent ?? 0);
			// Resolve mode + lineLength threshold from the first matching
			// rule (itemCount evaluated now; lineLength deferred to the
			// render gate via _thr). _thr<0 means "apply mode always".
			var _mode: anyparse.format.wrap.WrapMode = _rules.defaultMode;
			var _thr: Int = -1;
			$resolveExpr;
			// Build the broken layout for the resolved mode, plus the
			// all-glued (space-joined) fallback used when the lineLength
			// gate does not fire.
			final _glued: Array<anyparse.core.Doc> = [_dt(' ')];
			var _gj: Int = 0;
			while (_gj < _items.length) {
				if (_gj > 0) _glued.push(_dt(' '));
				_glued.push(_items[_gj]);
				_gj++;
			}
			final _gluedDoc: anyparse.core.Doc = _dc(_glued);
			final _broken: anyparse.core.Doc = switch (_mode) {
				case anyparse.format.wrap.WrapMode.OnePerLine:
					final _ds: Array<anyparse.core.Doc> = [];
					var _k: Int = 0;
					while (_k < _items.length) {
						_ds.push(_dhl());
						_ds.push(_items[_k]);
						_k++;
					}
					_dn(_ai, _dc(_ds));
				case anyparse.format.wrap.WrapMode.OnePerLineAfterFirst:
					final _ds: Array<anyparse.core.Doc> = [_dt(' '), _items[0]];
					var _k: Int = 1;
					while (_k < _items.length) {
						_ds.push(_dhl());
						_ds.push(_items[_k]);
						_k++;
					}
					_dn(_ai, _dc(_ds));
				case anyparse.format.wrap.WrapMode.FillLine | anyparse.format.wrap.WrapMode.FillLineWithLeadingBreak:
					_dn(_ai, _dc([_dt(' '), _dfill(_items, _dl())]));
				case _:
					_gluedDoc;
			};
			if (_mode == anyparse.format.wrap.WrapMode.NoWrap)
				_gluedDoc;
			else if (_thr < 0)
				_broken;
			else
				_dile(_thr, _broken, _gluedDoc);
		};
	}

	/**
	 * Tryparse-Star heritage WrapRules cascade resolution (B4
	 * ω-implements-extends-wrap): walks `_rules.rules`, evaluates each rule's
	 * itemCount / lineLength conditions, and assigns the first matching
	 * rule's `_mode` + lineLength `_thr`. References the runtime `_rules`/
	 * `_arr`/`_mode`/`_thr`/`opt` locals declared in
	 * `triviaTryparseHeritageMultiExpr`'s emitted scope. Extracted so the
	 * multi-clause layout stays under the complexity gate.
	 */
	private static function triviaTryparseHeritageResolveExpr(): Expr {
		return macro {
			var _ri: Int = 0;
			var _matched: Bool = false;
			while (_ri < _rules.rules.length && !_matched) {
				final _rule = _rules.rules[_ri];
				_ri++;
				var _llThr: Int = -1;
				var _ok: Bool = true;
				var _ci2: Int = 0;
				while (_ci2 < _rule.conditions.length) {
					final _cond = _rule.conditions[_ci2];
					_ci2++;
					switch (_cond.cond) {
						case anyparse.format.wrap.WrapConditionType.ItemCountLargerThan:
							if (_arr.length < _cond.value) _ok = false;
						case anyparse.format.wrap.WrapConditionType.ItemCountLessThan:
							if (_arr.length > _cond.value) _ok = false;
						case anyparse.format.wrap.WrapConditionType.LineLengthLargerThan:
							_llThr = _cond.value;
						case anyparse.format.wrap.WrapConditionType.ExceedsMaxLineLength:
							_llThr = opt.lineWidth;
						case _:
							_ok = false;
					}
				}
				if (_ok) {
					_mode = _rule.mode;
					_thr = _llThr;
					_matched = true;
				}
			}
		};
	}

	/**
	 * Tryparse-Star main (non-heritage) emit. Builds the per-element while
	 * loop (via triviaTryparseWhileExpr) and the trailing assembly (via
	 * triviaTryparseAssemblyExpr) inside the shared `_docs` scope.
	 *
	 */
	private static function triviaTryparseMainExpr(c: WriterLowering.TryparseStarCtx): Expr {
		final fieldAccess: Expr = c.fieldAccess;
		final trailLC: Expr = c.trailLC;
		final trailBB: Expr = c.trailBB;
		final trailBA: Expr = c.trailBA;
		final sepBeforeFirstExpr: Expr = c.sepBeforeFirstExpr;
		final nestBodyExpr: Expr = c.nestBodyExpr;
		final shapeRefusalExpr: Expr = c.shapeRefusalExpr;
		final flatGateExpr: Expr = c.flatGateExpr;
		final fitGateExpr: Expr = c.fitGateExpr;
		final writerOptExpr: Expr = c.writerOptExpr;
		final padLeadingExpr: Expr = c.padLeadingExpr;
		final padTrailingExpr: Expr = c.padTrailingExpr;
		final metaPolicyExpr: Expr = c.metaPolicyExpr;
		final condIncreaseGateExpr: Expr = c.condIncreaseGateExpr;
		final condNestedIncreaseGateExpr: Expr = c.condNestedIncreaseGateExpr;
		final cascadeInitPrev: Expr = c.cascadeInitPrev;
		final cascadeHeadEmit: Expr = c.cascadeHeadEmit;
		final priorAfterTrailEmit: Expr = c.priorAfterTrailEmit;
		final priorAfterTrailRaw: Expr = c.priorAfterTrailRaw;
		final padLeadingSpaceDoc: Expr = c.padLeadingSpaceDoc;
		final whileExpr: Expr = triviaTryparseWhileExpr(c);
		final assemblyExpr: Expr = triviaTryparseAssemblyExpr(c);
		final trailEndsLineDecl: Expr = triviaTryparseTrailEndsLineDecl();
		final caseGateDecls: Expr = triviaTryparseCaseGateDecls(shapeRefusalExpr, flatGateExpr, fitGateExpr, priorAfterTrailRaw);
		return macro {
			final _arr = $fieldAccess;
			final _trailLC: Array<String> = $trailLC;
			final _trailBB: Bool = $trailBB;
			final _trailBA: Bool = $trailBA;
			final _sepFirst: Bool = $sepBeforeFirstExpr;
			final _nestBody: Bool = $nestBodyExpr;
			$caseGateDecls;
			final _writerOpt = $writerOptExpr;
			// ω-cond-mod-pad: padLeading/padTrailing emit a space (single-line
			// shape) or hardline (multi-line, when first element carries a
			// source newline) around the Star body. Trail-side decision
			// mirrors leading-side because the parser does not capture a
			// body[last]→outer-trail newline slot — in legal source shapes
			// the two are correlated. Empty arrays skip both pads.
			final _padLeading: Bool = $padLeadingExpr;
			final _padTrailing: Bool = $padTrailingExpr;
			final _padHardline: Bool = (_padLeading || _padTrailing) && _arr.length > 0 && _arr[0].newlineBefore;
			$trailEndsLineDecl;
			final _metaPolicy: Int = $metaPolicyExpr;
			// ω-condcomp-empty-body-newline (Stage A): an EMPTY cond-comp body
			// / elseBody Star (`HxConditionalStmt`/`Decl`/… `body` carries BOTH
			// `@:fmt(padLeading, padTrailing)`) must still emit a single
			// hardline so `#if(cond)\n#end` keeps its interior newline rather
			// than collapsing to `#if(cond)#end`. The `padLeading && padTrailing`
			// gate is cond-comp-EXCLUSIVE (the expr-position `elseifs` Star has
			// padTrailing ONLY) — every other tryparse-Star consumer leaves
			// both false, so the empty body stays `_de()` byte-identical.
			if (_arr.length == 0 && _trailLC.length == 0) {
				// ω-case-label-trail-comment: an EMPTY body (e.g. `case A: // c`
				// with no statements) still cuddles the captured after-trail
				// comment to the `:` token before the empty-body base Doc.
				final _patEmpty: Null<String> = $priorAfterTrailRaw;
				final _baseEmpty: anyparse.core.Doc = _padLeading && _padTrailing ? _dhl() : _de();
				// Head -> body seam: an EMPTY tryparse Star contributes no
				// break of its own (`abstract A(Int) // c` with no from/to
				// clauses), so the next struct field's `{` would glue onto
				// the comment line. Guarded emit breaks instead.
				_patEmpty != null ? _dc([trailingCommentDocGuarded(_patEmpty, opt), _baseEmpty]) : _baseEmpty;
			} else {
				final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				final _docs: Array<anyparse.core.Doc> = [];
				// ω-cond-indent-policy: when active, the trailing pad hardline
				// (the `\n` before `#else`/`#end`) is held OUT of `_docs` so it
				// lands at the surrounding statement indent; the body content
				// inside `_docs` is wrapped in `_dn(_cols, …)` at assembly.
				final _condIncrease: Bool = $condIncreaseGateExpr;
				// ω-cond-indent-policy AlignedNestedIncrease: per-element gate.
				// True only on the cond-comp body Stars under that policy; each
				// element that is a nested `Conditional` (recognised via the
				// generated `elementIsConditional_<ElemRule>` probe threaded
				// through `elemCondFn`) is wrapped `+1` at the splice below.
				// Null probe (formats without generated predicates) ⇒ no wrap.
				final _condNestedIncrease: Bool = $condNestedIncreaseGateExpr;
				var _condTrailPad: Null<anyparse.core.Doc> = null;
				// ω-line-comment-directive-break: set once a pad hardline has
				// already terminated the Star's last line comment, so the tail
				// guard below does not stack a second break on top of it.
				var _lineTrailBroken: Bool = false;
				$cascadeInitPrev;
				$cascadeHeadEmit;
				$priorAfterTrailEmit;
				if (_padLeading && _arr.length > 0) _docs.push(_padHardline ? _dhl() : $padLeadingSpaceDoc);
				// ω-blockended-trivia-tryparse (Session 3): see comment near
				// tryparseBlockEndedSepEmit construction. Always declared so
				// the splice site reads it safely; when sepText is null /
				// blockEnded false, the splice expands to `{}` (no read).
				var _priorElemDoc: Null<anyparse.core.Doc> = null;
				$whileExpr;
				$assemblyExpr;
			}
		};
	}

	/**
	 * ω-line-comment-directive-break: declare the tryparse-Star's
	 * `_lastTrailComment` / `_trailEndsLine` runtime locals.
	 *
	 * A `//` comment runs to the next PHYSICAL newline, so whatever the parent
	 * emits after this Star on the same Doc line becomes comment TEXT. On a
	 * cond-comp arm the swallowed token is the `#end` / `#else` / `#elseif`
	 * marker: the region never closes and the emitted file stops parsing -
	 * corruption, worse than losing the comment. `_trailEndsLine` is true when
	 * the LAST comment this Star emits is line-style: the orphan trail when
	 * there is one, else the last element's cuddled trailing comment. Block
	 * comments do not terminate at a newline, so their same-line glue is legal
	 * and stays.
	 *
	 * Emitted as a single `EVars` (NOT an `EBlock`) so both locals land in the
	 * caller's scope, and extracted so `triviaTryparseMainExpr` stays under the
	 * complexity gate.
	 */
	private static function triviaTryparseTrailEndsLineDecl(): Expr {
		final lastComment: Expr = macro _arr.length > 0 ? _arr[_arr.length - 1].trailingComment : null;
		final endsLine: Expr = macro _trailLC.length > 0
			? StringTools.startsWith(_trailLC[_trailLC.length - 1], '//')
			: (_lastTrailComment != null && StringTools.startsWith(_lastTrailComment, '//'));
		return {
			expr: EVars([
				{
					name: '_lastTrailComment',
					type: macro :Null<String>,
					expr: lastComment,
					isFinal: true
				},
				{
					name: '_trailEndsLine',
					type: macro :Bool,
					expr: endsLine,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		};
	}

	/**
	 * Tryparse-Star main per-element while-loop emit. Builds the cascade
	 * fire + leading-comment emit + inter-element separator cascade +
	 * element emit + cond-nested-increase splice + track, and returns the
	 * `EWhile` spliced into `triviaTryparseMainExpr`. Extracted so the main
	 * builder stays under the complexity gate.
	 */
	private static function triviaTryparseWhileExpr(c: WriterLowering.TryparseStarCtx): Expr {
		final cascadeInitCurr: Expr = c.cascadeInitCurr;
		final cascadeCurrCompute: Expr = c.cascadeCurrCompute;
		final cascadeTrackPrev: Expr = c.cascadeTrackPrev;
		final triviaElemCallMaybeBreak: Expr = c.triviaElemCallMaybeBreak;
		final elemOptInit: Expr = c.elemOptInit;
		final tryparseBlockEndedSepEmit: Expr = c.tryparseBlockEndedSepEmit;
		final sepCascade: Expr = triviaTryparseSepCascadeExpr(c);
		final elemCondFn: Null<Expr> = c.elemCondFn;
		final elemCondProbe: Expr = elemCondFn == null ? macro false : macro $elemCondFn(_t.node);
		return macro {
			var _si: Int = 0;
			while (_si < _arr.length) {
				final _t = _arr[_si];
				// ω-cond-indent-policy AlignedNestedIncrease: remember where
				// THIS element's docs begin (its leading inter-element
				// separator + the element body) so the splice at loop tail
				// can wrap the whole span `+1` when the element is a nested
				// conditional. Captured before any separator push.
				final _condNestLen: Int = _docs.length;
				$cascadeInitCurr;
				$cascadeCurrCompute;
				$tryparseBlockEndedSepEmit;
				$sepCascade;
				$elemOptInit;
				final _elem: anyparse.core.Doc = $triviaElemCallMaybeBreak;
				final _tc: Null<String> = _t.trailingComment;
				_docs.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDocVerbatim(_tc, opt)) : _elem);
				// ω-cond-indent-policy AlignedNestedIncrease: if this body
				// element is itself a nested `Conditional`, lift its whole
				// span (leading separator + markers + guarded body, captured
				// from `_condNestLen`) into a `_dn(_cols, …)` so the
				// `#if`/`#elseif`/`#else`/`#end` markers AND body render one
				// indent step deeper than the surrounding region. The leading
				// separator is inside the span so the `#if` marker line (which
				// renders at the PRECEDING hardline's indent) also shifts.
				// Recursion through the nested conditional's own body Star
				// accumulates the shift per depth. Formats without generated
				// predicates (null `elemCondFn`) and non-conditional elements
				// leave `_docs` untouched (byte-identical).
				if (_condNestedIncrease && $elemCondProbe && _docs.length > _condNestLen) {
					final _condNestSpan: Array<anyparse.core.Doc> = _docs.splice(_condNestLen, _docs.length - _condNestLen);
					_docs.push(_dn(_cols, _dc(_condNestSpan)));
				}
				_priorElemDoc = _elem;
				$cascadeTrackPrev;
				_si++;
			}
		};
	}

	/**
	 * Tryparse-Star inter-element separator cascade (the `if/else if` chain
	 * deciding the leading separator of element `_si`). Returns the spliced
	 * statement; references the runtime `_docs`/`_si`/`_t`/`_arr` locals
	 * declared in `triviaTryparseWhileExpr`'s emitted scope. Extracted so
	 * the while builder stays under the complexity gate.
	 */
	private static function triviaTryparseSepCascadeExpr(c: WriterLowering.TryparseStarCtx): Expr {
		final cascadeBlanksCount: Expr = c.cascadeBlanksCount;
		final subsequentSepDoc: Expr = c.subsequentSepDoc;
		final firstSepExpr: Expr = c.firstSepExpr;
		final forceInlineSep: Bool = c.forceInlineSep;
		final elemSelfTrailsNewline: Bool = c.elemSelfTrailsNewline;
		final leadCommentEmit: Expr = triviaTryparseLeadCommentSepExpr();
		final forceInlineCond: Expr = triviaTryparseForceInlineSepCond(forceInlineSep);
		return macro {
			if (_t.leadingComments.length > 0) {
				$leadCommentEmit;
			} else if (_flatCase) {
				_docs.push(_dt(' '));
			} else if (_fitCase) {
				// ω-case-body-fitline-shared: NO separator here. `BodyFit.
				// fitLineLayout` (see `triviaTryparseCaseWrapExpr`) owns the whole
				// `<separator><body>` shape, because the separator it picks — a soft
				// `Line` inside a measured `BodyGroup` vs an `OptSpace` glue — is
				// part of the same decision as the wrap. Pushing one here would
				// force this cascade to duplicate that decision, which is exactly
				// the drift the shared emitter exists to prevent.
			} else if (_nestBody) {
				// ω-nestbody-blank: case / default body statements preserve a source
				// blank line between elements (fork keeps inter-statement blanks in
				// case / default bodies). Mirrors the `_t.newlineBefore` branch's
				// cascade-blanks loop, gated on `_si > 0` so the body's first
				// statement stays hugged under `case X:` / `default:` with no leading
				// blank. `$cascadeBlanksCount` reduces to `_t.blankBefore ? 1 : 0`
				// (case / default bodies carry no cascade infos).
				_docs.push(_dhl());
				if (_si > 0) {
					final _blanks: Int = $cascadeBlanksCount;
					var _bli: Int = 0;
					while (_bli < _blanks) {
						_docs.push(_dhl());
						_bli++;
					}
				}
			} else if (_si > 0 && _metaPolicy == 1) {
				// ω-metadata-line-end-function: After policy collapses
				// source-driven inter-meta sep to a forced hardline,
				// emitting one metadata per line regardless of source
				// layout. Skips the cascade-blanks path — blank-line
				// separators between metas aren't a fork-supported shape
				// for the After policy.
				_docs.push(_dhl());
			} else if (_si > 0 && _metaPolicy == 3) { // noqa: magic-number
				// ω-metadata-line-end-function: ForceAfterLast collapses
				// any source newline between consecutive metas to a
				// single space, producing the canonical `@A @B @C`
				// inline shape ahead of the trailing hardline.
				_docs.push(_dt(' '));
			} else if ($forceInlineCond) {
				_docs.push(_dt(' '));
			} else if (_si > 0 && _t.newlineBefore) {
				// ω-cond-mod-newline: preserve a single source newline
				// between try-parse Star elements. Without this, the
				// default `sepExpr` (space) would collapse
				// `#if COND <mods> #end\n\tpublic` (issue_332 V1) down
				// to `#if COND <mods> #end public` on round-trip,
				// losing the author's modifier-list line break.
				//
				// ω-bug-2c-inner-star: cascade-blanks loop replaces the
				// pre-slice `if (_t.blankBefore) push(\\n)` source-driven
				// path. With no cascade infos active, `$cascadeBlanksCount`
				// reduces to `(_t.blankBefore ? 1 : 0)` — byte-identical
				// to the prior single-blank emit.
				if (!$v{elemSelfTrailsNewline}) _docs.push(_dhl());
				final _blanks: Int = $cascadeBlanksCount;
				var _bli: Int = 0;
				while (_bli < _blanks) {
					_docs.push(_dhl());
					_bli++;
				}
			} else if (_si > 0) {
				_docs.push($subsequentSepDoc);
			} else if (_sepFirst) {
				_docs.push($firstSepExpr);
			}
		};
	}

	/**
	 * ω-slice-45 — the `@:fmt(forceInlineSep)` arm's runtime condition, built
	 * here so its `&&` chain does not count against the cascade builder's
	 * complexity budget.
	 *
	 * `@:fmt(forceInlineSep)` collapses every source linebreak between
	 * consecutive SimpleCtor elements to a single space. Modifier Stars
	 * (`HxMemberDecl.modifiers`, `HxTopLevelDecl.modifiers`) opt in so
	 * multi-line `static\n\toverload` round-trips as `static overload`.
	 * ParamCtor elements (current consumers: `Conditional(inner:
	 * HxConditionalMod)` — the `#if … #end` modifier region) are gated OUT so
	 * the existing CondMod layout (issue_332 V1/V4: source newline between
	 * `#end` and the next keyword preserved) stays byte-identical.
	 * Plugin-agnostic ctor classification via `Type.enumParameters` — no
	 * reflection by ctor name. The `cast` suppresses macro-time type-checking
	 * on `.node` (struct-shaped Star elements like `HxMemberDeclT` /
	 * `HxTopLevelDeclT` would otherwise fail `EnumValue` unification —
	 * dead-code elimination runs AFTER type-check); the compile-time
	 * `$v{forceInlineSep}` short-circuit keeps the runtime reflection cost on
	 * opted-in modifier Stars only, where `.node` IS an enum
	 * (`HxMemberModifier` / `HxModifier`).
	 */
	private static function triviaTryparseForceInlineSepCond(forceInlineSep: Bool): Expr {
		return macro _si > 0 && $v{forceInlineSep} && Type.enumParameters(cast _arr[_si - 1].node).length == 0
			&& Type.enumParameters(cast _t.node).length == 0;
	}

	/**
	 * Tryparse-Star leading-comment separator emit (the body of the
	 * `_t.leadingComments.length > 0` arm in the separator cascade):
	 * padLeading-dup guard + blank-before + per-comment hardline emit +
	 * blank-after. References the runtime `_si`/`_padLeading`/`_padHardline`/
	 * `_t`/`_docs`/`opt` locals declared in the emitted scope. Extracted so
	 * the separator cascade stays under the complexity gate.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseLeadCommentSepExpr(): Expr {
		final blankExtras: Expr = WriterLowering.blankBefore2ExtrasExpr(macro _docs.push(_dhl()));
		return macro {
			// ω-D16-padleading-first-comment-no-dup: padLeading
			// already emitted `_dhl()` for the first element when
			// `_padHardline` is true (driven by `_arr[0].newlineBefore`).
			// Both reflect the SAME source newline between the
			// prior token and the stmt's trivia — a second `_dhl()`
			// here produces a spurious blank line (visible as
			// `#if sys\n\n\t\t// comment` for HxConditionalStmt.body
			// with `@:fmt(padLeading)` and a leading line comment
			// on the first body stmt). Skip the dup only on the
			// first iteration when padLeading fired as a hardline;
			// inter-stmt path (`_si > 0`) and non-padLeading
			// consumers stay byte-identical.
			if (!(_si == 0 && _padLeading && _padHardline)) _docs.push(_dhl());
			if (_t.blankBefore && _si > 0) {
				_docs.push(_dhl());
				$blankExtras;
			}
			var _ci: Int = 0;
			while (_ci < _t.leadingComments.length) {
				_docs.push(leadingCommentDocRun(_t.leadingComments, _ci, opt));
				_docs.push(_dhl());
				_ci++;
			}
			if (_t.blankAfterLeadingComments) _docs.push(_dhl());
		};
	}

	/**
	 * Tryparse-Star main trailing assembly: the post-loop tail-sep emit,
	 * trailing pad / meta-policy hardline, orphan-trail-comment docs (via
	 * triviaTryparseTrailDocsExpr), and the wrap dispatch (via
	 * triviaTryparseWrapDispatchExpr). Returns the spliced statement;
	 * references the runtime locals declared in `triviaTryparseMainExpr`'s
	 * emitted scope. Extracted so the main builder stays under the
	 * complexity gate.
	 */
	private static function triviaTryparseAssemblyExpr(c: WriterLowering.TryparseStarCtx): Expr {
		final tryparseBlockEndedTrailEmit: Expr = c.tryparseBlockEndedTrailEmit;
		final lastTrailTerminatorEmit: Expr = c.lastTrailTerminatorEmit;
		final finalWrapDocs: Expr = c.finalWrapDocs;
		final trailPadSpaceDoc: Expr = c.trailPadSpaceDoc;
		final trailDocsExpr: Expr = triviaTryparseTrailDocsExpr();
		final wrapDispatch: Expr = triviaTryparseWrapDispatchExpr(finalWrapDocs, c.glueRefusalExpr, trailPadSpaceDoc);
		return macro {
			$tryparseBlockEndedTrailEmit;
			// ω-cond-indent-policy: under AlignedIncrease hold the trailing
			// pad out of `_docs` so the close marker (`#else`/`#end`)
			// renders at the surrounding indent rather than at body+1. The
			// pad doc is identical to the pre-policy push; only its
			// placement (outside the `_dn`) changes. Other policies /
			// non-cond Stars keep the inline push (`_condIncrease` false →
			// byte-identical).
			// ω-line-comment-directive-break: `_trailEndsLine` upgrades the pad
			// from a space to a hardline. A space is right after code and wrong
			// after a `//` comment - it leaves the close marker on the comment's
			// line, which is exactly the single-line arm shape
			// (`#if a var q:Int; // t` + newline `#end`).
			if (_condIncrease && _padTrailing && _arr.length > 0) {
				_lineTrailBroken = _padHardline || _trailEndsLine;
				_condTrailPad = _lineTrailBroken ? _dhl() : _dt(' ');
			} else if (_padTrailing && _arr.length > 0 && _trailLC.length == 0) {
				_lineTrailBroken = _padHardline || _trailEndsLine;
				_docs.push(_lineTrailBroken ? _dhl() : $trailPadSpaceDoc);
			} else if (_metaPolicy != 0 && _arr.length > 0) {
				_lineTrailBroken = true;
				_docs.push(_dhl());
			}
			// ω-trivia-tryparse-linelength: when the LAST element carries
			// a same-line `// trail`, a `//` line comment runs until the
			// next physical newline, so an inline ` ` separator before
			// the next sibling's lead literal (`{`/`}`/...) would inline
			// that sibling INSIDE the comment. Emit a terminating
			// hardline so the next field's lead lands on its own line.
			// Gated by `lineLengthAwareSeps` so non-opt-in callers stay
			// byte-identical. First consumer: HxAbstractDecl.clauses
			// terminating the last-clause trail before members `{` lead.
			$lastTrailTerminatorEmit;
			// Trail comments collected into a separate Doc array so the
			// nestBody branch can render them at parent indent when the
			// body has stmts (issue_392): a `// comment` on its own line
			// between case body's last stmt and the next `case` label
			// belongs at case-label level, not case-body level. Empty-
			// body cases (only-comment) keep body-level indent — the
			// trail concat fold below restores that path.
			final _trailDocs: Array<anyparse.core.Doc> = [];
			$trailDocsExpr;
			$wrapDispatch;
		};
	}

	/**
	 * Tryparse-Star orphan-trail-comment docs build (the `_trailLC.length > 0`
	 * loop): pushes hardline + per-comment doc into `_trailDocs`, with the
	 * trailBB lead-blank and trailBA tail-blank. References the runtime
	 * `_trailDocs`/`_trailLC`/`_trailBB`/`_trailBA`/`_arr`/`opt` locals.
	 * Extracted so `triviaTryparseAssemblyExpr` stays under the complexity
	 * gate.
	 */
	private static function triviaTryparseTrailDocsExpr(): Expr {
		return macro {
			if (_trailLC.length > 0) {
				var _ti: Int = 0;
				while (_ti < _trailLC.length) {
					_trailDocs.push(_dhl());
					if (_trailBB && _ti == 0 && _arr.length > 0) _trailDocs.push(_dhl());
					_trailDocs.push(leadingCommentDocRun(_trailLC, _ti, opt));
					_ti++;
				}
				// ω-trail-blank-after: source had a blank line between this
				// trail comment and the next outer-Star sibling (e.g. case
				// label). Append an extra hardline at trail's tail; the
				// outer Star will then add its own element-leading hardline
				// for a true blank-line separator. Trailing whitespace on
				// the empty line is trimmed by the renderer (default).
				if (_trailBA) _trailDocs.push(_dhl());
			}
		};
	}

	/**
	 * ω-case-body-fitline-shared — the terminal Doc for a single-statement
	 * case / default body that the resolved policy puts on the case line.
	 * Both such policies land here, split out of
	 * `triviaTryparseWrapDispatchExpr` so they share one arm (and so this
	 * two-way choice does not count against that cascade's complexity).
	 *
	 * `_flatCase` (`Same`, or `Keep` on same-line source) is COMMITTED to the
	 * label line: the separator is already the hard `_dt(' ')` the cascade
	 * pushed, and the body may still wrap internally afterwards, so the
	 * `_dn(_cols, …)` gives those wrapped lines their `+1` continuation
	 * indent. `opt.alignInlineSwitchCaseBody` drops it for configs whose
	 * wrapped argument already indents relative to the case line (mirrors
	 * fork `Indenter.alignInlineSwitchCaseBody` skipping `mustIndent` on the
	 * case DblDot). Issue_121 fixtures pin the default.
	 *
	 * `_fitCase` (`FitLine`) hands the whole `<separator><body>` shape to
	 * `anyparse.format.BodyFit.fitLineLayout` — the same emitter
	 * `bodyPolicyWrap`'s FitLine branch uses for a bare-Ref body, so a case
	 * body and a `return` body cannot drift apart again. The cascade pushes
	 * NO separator on this path, so `_docs` here is the body alone
	 * (`_fitCase` refuses a case label that captured a trailing comment,
	 * which is the only other thing that can precede the body in `_docs`).
	 *
	 * `$glueRefusalExpr` is the `refuseGlue` argument
	 * (omega-case-body-controlflow-glue): true when the body's single
	 * statement is keyword-led control flow, which turns the glue outcome
	 * into a break. It is read only here, where `_arr.length == 1` holds by
	 * construction, and it is inert (`false`) for any Star that does not
	 * carry `@:fmt(refuseGlueOnControlFlowRoot)`.
	 *
	 * `_trailDocs` (the body Star's ORPHAN trailing comments) is appended
	 * AFTER the placement Doc, outside whatever `Nest` the placement chose, so
	 * the comment run renders at LABEL indent. That matches the `nestBody`
	 * arm's NON-EMPTY-body sub-shape (issue_392) and only that one: with no
	 * body statements at all, `nestBody` folds the run INTO its `_dn` so an
	 * only-comment case keeps body-level indent. That shape cannot reach here
	 * - `_caseBodyFlattenable` requires exactly one element. Both arms handle it uniformly; on the `_flatCase`
	 * arm the run is provably empty (that gate still requires it), so the
	 * append is inert there.
	 *
	 * `alignInlineSwitchCaseBody` reaches the fit path too, as
	 * `nestGluedBody`: it is the same "does the body's container already
	 * indent relative to the case line" question, and it is live on the GLUE
	 * outcome (a body that cannot render flat, whose own lines still need the
	 * `+1`). On the measured outcome the knob is provably inert rather than
	 * ignored — `BodyFit` reaches that branch only when
	 * `WrapList.flatLength(body) >= 0`, i.e. the body holds no hardline at
	 * all, so no inner line exists for a `Nest` to move.
	 */
	private static function triviaTryparseCaseWrapExpr(glueRefusalExpr: Expr): Expr {
		return macro {
			final _caseBody: anyparse.core.Doc = if (_fitCase)
				anyparse.format.BodyFit.fitLineLayout(
					_cols, _dc(_docs), !opt.alignInlineSwitchCaseBody, opt.lineWidth, opt._caseSiblingFlatWidth, $glueRefusalExpr
				);
			else
				opt.alignInlineSwitchCaseBody ? _dc(_docs) : _dn(_cols, _dc(_docs));
			_dwb(_trailDocs.length > 0 ? _dc([_caseBody, _dc(_trailDocs)]) : _caseBody);
		};
	}

	/**
	 * Tryparse-Star terminal wrap dispatch (the flat-case / nestBody /
	 * cond-increase / default `if/else` chain producing the final `_dwb`
	 * Doc). `finalWrapDocs` is the default-branch terminal. References the
	 * runtime `_docs`/`_trailDocs`/`_flatCase`/`_fitCase`/`_nestBody`/
	 * `_condIncrease`/`_cols`/`opt` locals. Extracted so
	 * `triviaTryparseAssemblyExpr` stays under the complexity gate.
	 *
	 * ω-line-comment-directive-break: only the `_condIncrease` and default arms
	 * carry the line-comment break guard. The case-body arms need none: no
	 * `nestBody` Star carries `padTrailing` (case / default bodies are always
	 * followed by a hardline-led sibling), and since
	 * omega-case-trail-comment-inline the `_fitCase` arm that may now hold an
	 * orphan trail run ends with that run's own hardline-led docs — so neither
	 * can glue a follower onto a `//` comment.
	 */
	private static function triviaTryparseWrapDispatchExpr(finalWrapDocs: Expr, glueRefusalExpr: Expr, trailPadSpaceDoc: Expr): Expr {
		final caseWrap: Expr = triviaTryparseCaseWrapExpr(glueRefusalExpr);
		return macro {
			// ω-force-flat-engine sister-coverage: tryparse Star is used
			// for inner-Star bodies (case bodies, `HxConditionalDecl.body`)
			// which can sit under wrap-cascade Flatten parents in expression
			// position. Each leaf branch hand-rolls its terminal Doc — wrap
			// uniformly in `_dwb` so a nested wrap-engine reads its own
			// independent layout. `_dwb` is no-op outside Flatten frame.
			if (_flatCase || _fitCase) {
				$caseWrap;
			} else if (_nestBody) {
				if (_arr.length > 0 && _trailDocs.length > 0) {
					_dwb(_dc([_dn(_cols, _dc(_docs)), _dc(_trailDocs)]));
				} else {
					for (_d in _trailDocs) _docs.push(_d);
					_dwb(_dn(_cols, _dc(_docs)));
				}
			} else if (_condIncrease) {
				// ω-cond-indent-policy: AlignedIncrease — body content
				// (leading pad + each body element, all inside `_docs`)
				// nests one level deeper; the trailing close-marker pad
				// (`_condTrailPad`, held out above) renders at the
				// surrounding indent. `_trailDocs` (orphan trail comments)
				// is empty for cond-comp bodies but appended defensively
				// inside the nest to preserve the pre-policy ordering.
				for (_d in _trailDocs) _docs.push(_d);
				// ω-line-comment-directive-break: under AlignedIncrease the close
				// marker's pad is held OUT of `_docs` so the marker renders at the
				// surrounding indent. The break a line comment forces must ride the
				// same channel - pushed into `_docs` it would capture the body's
				// `_dn` and land `#end` one level too deep. `_condTrailPad` is
				// provably null here: the only site that sets it also sets
				// `_lineTrailBroken` whenever `_trailEndsLine` holds.
				if (_trailEndsLine && !_lineTrailBroken) _condTrailPad = _dohsbh();
				final _nested: anyparse.core.Doc = _dn(_cols, _dc(_docs));
				_dwb(_condTrailPad != null ? _dc([_nested, _condTrailPad]) : _nested);
			} else {
				for (_d in _trailDocs) _docs.push(_d);
				// ω-cond-comp-branch-trail: the padTrailing pad (the newline before
				// the `#end`/`#else` close marker) was deferred past the orphan
				// trail comments so the marker lands on its own line instead of
				// being commented out by a trailing `//` line comment.
				if (_padTrailing && _trailLC.length > 0 && _arr.length > 0) {
					_lineTrailBroken = _padHardline || _trailEndsLine;
					_docs.push(_lineTrailBroken ? _dhl() : $trailPadSpaceDoc);
				}
				// ω-line-comment-directive-break: an arm that emits NO pad at all
				// (an EMPTY body holding only comments) still owes the break. The
				// guard is forward-looking, so it DROPS when the parent's next
				// emit is already a hardline - every sound seam stays byte-inert.
				if (_trailEndsLine && !_lineTrailBroken) _docs.push(_dohsbh());
				_dwb($finalWrapDocs);
			}
		};
	}

	/**
	 * Tryparse-Star `writerOptExpr` builder (ω-expression-case-flat-fanout /
	 * ω-issue-423-mech-a). Builds the `_writerOpt` Expr: plain `opt`, a
	 * flat-only `_copyOpt` + per-pair field override, or (when
	 * `propagateExprPosition`) an unconditional copy setting
	 * `_inExprPosition = true`.
	 *
	 * ω-case-body-fitline-shared: the per-pair override stays gated on the
	 * COMMITTED `_flatCase`, NOT on `_flatCase || _fitCase`. `flatChildOpt`
	 * hands a child the shape the case body itself took; on the fit path that
	 * shape is still undecided at write time (the renderer picks it), so
	 * propagating it would be the blind fanout the `applyExpressionIfFanout`
	 * gate warns about. Widening the gate compiles and passes every other
	 * test, so the direction is pinned by
	 * `HxCaseBodyFitLineSliceTest.testFlatChildOptDoesNotFanOutOnTheFitPath`.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseWriterOptExpr(flatChildOptPairs: Null<Array<Array<String>>>, propagateExprPosition: Bool): Expr {
		final hasFlatChildOpt: Bool = flatChildOptPairs != null && flatChildOptPairs.length > 0;
		return if (!hasFlatChildOpt && !propagateExprPosition)
			macro opt;
		else if (!propagateExprPosition) {
			final block: Array<Expr> = [macro final _wo = _copyOpt(opt)];
			for (pair in flatChildOptPairs) {
				final fromAccess: Expr = { expr: EField(macro _wo, pair[0]), pos: Context.currentPos() };
				final toAccess: Expr = WriterLowering.optFieldAccess(pair[1]);
				block.push(macro $fromAccess = $toAccess);
			}
			block.push(macro _wo);
			final overrideBlock: Expr = { expr: EBlock(block), pos: Context.currentPos() };
			macro (_flatCase ? $overrideBlock : opt);
		} else {
			// Wrap each `macro` expression in parens — array-literal `,` after
			// a `macro final ... = ...` reification fragment otherwise mis-parses
			// (the parser treats `macro` as a variable name in the next element).
			final block: Array<Expr> = [
				(macro final _wo = _copyOpt(opt)),
				macro _wo._inExprPosition = true
			];
			if (hasFlatChildOpt) {
				final flatOnlyParts: Array<Expr> = [
					for (pair in flatChildOptPairs) {
						final fromAccess: Expr = { expr: EField(macro _wo, pair[0]), pos: Context.currentPos() };
						final toAccess: Expr = WriterLowering.optFieldAccess(pair[1]);
						macro $fromAccess = $toAccess;
					}
				];
				final flatOnlyExpr: Expr = { expr: EBlock(flatOnlyParts), pos: Context.currentPos() };
				block.push(macro if (_flatCase) $flatOnlyExpr);
			}
			block.push(macro _wo);
			final overrideBlock: Expr = { expr: EBlock(block), pos: Context.currentPos() };
			overrideBlock;
		};
	}

	/**
	 * Shared body of the two case-body gate builders: arity validation plus
	 * the single-flag / dual-flag (`opt._inExprPosition` dispatch) shape.
	 * `fit` selects which per-flag predicate the arms are built from.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseCaseGateExpr(caseBodyFlagNames: Null<Array<String>>, fit: Bool): Expr {
		if (caseBodyFlagNames != null && caseBodyFlagNames.length > 2)
			Context.fatalError(
				'WriterLowering: @:fmt(bodyPolicy(...)) takes at most 2 args (stmtFlag, exprFlag), got ${caseBodyFlagNames.length}',
				Context.currentPos()
			);
		inline function pred(flagName: String): Expr
			return fit ? WriterLowering.buildCaseBodyFitPredicate(flagName) : WriterLowering.buildCaseBodyFlagPredicate(flagName);
		return if (caseBodyFlagNames == null || caseBodyFlagNames.length == 0)
			macro false;
		else if (caseBodyFlagNames.length == 1)
			pred(caseBodyFlagNames[0]);
		else {
			final stmtPred: Expr = pred(caseBodyFlagNames[0]);
			final exprPred: Expr = pred(caseBodyFlagNames[1]);
			macro (opt._inExprPosition ? $exprPred : $stmtPred);
		};
	}

	/**
	 * Tryparse-Star element-call Expr group (caseTailOptArg / triviaElemCall /
	 * triviaElemCallMaybeBreak / elemOptInit). Builds the per-element writer
	 * call and the operand-break opt init.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseElemCallExprs(
		elemFn: String, clearExprPositionNonTail: Bool, operandBreakAfterMultilineBrace: Bool
	): { triviaElemCall: Expr, triviaElemCallMaybeBreak: Expr, elemOptInit: Expr } {
		// ω-value-yielded-if-tail-barrier (case-body extension): the per-element
		// opt argument. When `clearExprPositionNonTail` is set (case / default
		// body Star), every body statement EXCEPT the tail gets
		// `_clearExprPosition` so a discarded statement-if reverts to the
		// statement-position `ifBody` policy; only the body's last statement
		// (the switch's yielded value at expression position) keeps the
		// inherited frame. `_si` / `_arr` are in scope at the element-call
		// splice. Flag off ⇒ the IDENTICAL `_writerOpt` Doc as before.
		// ω-if-tail-fork-parity: a case-body TAIL that is an `if` (IfStmt) reads
		// the case's OWN incoming `_inExprPosition` frame, NOT the force-propagated
		// one — a value-yielded case (`return switch …`, incoming true) keeps the
		// expression frame so the body breaks under `expressionIf:next`, while a
		// statement-switch case (incoming false) drops it so the body inlines under
		// `ifBody:fitLine`. Mirrors fork's `isExpression`→`isReturnExpression(case)`
		// dispatch. Non-`if` tails (nested switch for issue-423 flattening, `for` /
		// `while` bodies the fork breaks) keep the force-propagated `_writerOpt`.
		final caseTailOptArg: Expr = if (clearExprPositionNonTail) {
			final caseTailBarrier: Expr = WriterLowering.astPredCallT('tailStmtReadsExprPosition', [macro _t.node]);
			macro (
				_si == _arr.length - 1 ? (
					$caseTailBarrier && !opt._inExprPosition
						&& (opt.expressionIfBody == anyparse.format.BodyPolicy.Next
							|| opt.expressionIfBody == anyparse.format.BodyPolicy.FitLine)
						? _clearExprPosition(_writerOpt)
						: _writerOpt
				) : _clearExprPosition(_writerOpt)
			);
		} else
			macro _writerOpt;
		final triviaElemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, caseTailOptArg]),
			pos: Context.currentPos()
		};
		// ω-typedef-intersection-operand-break: per-iteration element call for
		// the MAIN inter-element loop only (the heritage/wrap fast paths keep
		// `triviaElemCall`/`_writerOpt`). Flag off (every Star but
		// `HxTypedefDecl.intersections`) ⇒ identical to `triviaElemCall`,
		// byte-inert. Flag on ⇒ when the prior element rendered multi-line AND
		// ended with a close delim, hand the element a `_copyOpt` with
		// `_intersectionOperandBreak = true` so its
		// `@:fmt(typedefIntersectionBreak)` lead breaks `&\n\t` before the
		// operand; otherwise the shared `_writerOpt` (stays glued — no copy,
		// no mutation of the shared opt).
		final triviaElemCallMaybeBreak: Expr = operandBreakAfterMultilineBrace ? {
			expr: ECall(macro $i{elemFn}, [macro _t.node, macro _elemOpt]),
			pos: Context.currentPos()
		} : triviaElemCall;
		// Single `final _elemOpt = …;` declaration spliced at loop scope (NOT a
		// nested EBlock — that would isolate `_elemOpt` from the element call).
		// Flag on ⇒ when the prior element rendered multi-line AND ended with a
		// close delim, fan the opt through `_setIntersectionBreak` (idempotent
		// `_copyOpt` + flag set), else the shared `_writerOpt` (no copy, shared
		// opt untouched). Flag off ⇒ `macro {}` (no local — `triviaElemCall`
		// uses `_writerOpt` directly, byte-identical to the pre-slice loop).
		final elemOptInit: Expr = operandBreakAfterMultilineBrace
			? macro final _elemOpt = _priorElemDoc != null && anyparse.format.wrap.WrapList.flatLength(_priorElemDoc) < 0
				&& anyparse.format.wrap.WrapList.endsWithCloseDelim(_priorElemDoc)
				? _setIntersectionBreak(_writerOpt)
				: _writerOpt
			: macro {};
		return { triviaElemCall: triviaElemCall, triviaElemCallMaybeBreak: triviaElemCallMaybeBreak, elemOptInit: elemOptInit };
	}

	/**
	 * Tryparse-Star `priorAfterTrailEmit` builder
	 * (ω-trivia-tryparse-prior-after-trail): inline-emit the prev-field's
	 * same-line trail comment before padLeading. Null slot ⇒ no-op.
	 *
	 */
	private static function triviaTryparsePriorAfterTrailEmit(priorAfterTrailExpr: Null<Expr>): Expr {
		return priorAfterTrailExpr == null
			? macro {}
			: macro {
				final _pat: Null<String> = $priorAfterTrailExpr;
				// Head -> body seam: the Star's own padLeading may be a
				// SPACE (single-line source), so a line comment here would
				// swallow the first element. Guarded emit breaks instead.
				if (_pat != null) _docs.push(trailingCommentDocGuarded(_pat, opt));
			};
	}

	/**
	 * Tryparse-Star `finalWrapDocs` builder (ω-trivia-tryparse-linelength):
	 * the default-branch terminal Doc — `_dc(_docs)` plus, when
	 * `lineLengthAwareSeps`, a `_dn` nest and a last-element trail
	 * terminator.
	 */
	private static function triviaTryparseFinalWrapDocs(lineLengthAwareSeps: Bool): Expr {
		return lineLengthAwareSeps
			? macro _dc([
				_dn(_cols, _dc(_docs)),
				_arr.length > 0 && _arr[_arr.length - 1].trailingComment != null ? _dhl() : _de()
			])
			: macro _dc(_docs);
	}

	/**
	 * Tryparse-Star `shapeRefusalExpr` builder (ω-issue-423-mech-b): the
	 * extra `_flatCase` AND-clause deferring to the generated typed
	 * `caseBodyRefusesFlat` predicate. Flag off ⇒ `macro true`.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseShapeRefusalExpr(refuseFlatOnComplex: Bool): Expr {
		if (!refuseFlatOnComplex) return macro true;
		final refuses: Expr = WriterLowering.astPredCallT('caseBodyRefusesFlat', [macro _arr[0].node]);
		return macro !$refuses;
	}

	/**
	 * Tryparse-Star `glueRefusalExpr` builder
	 * (omega-case-body-controlflow-glue): the `refuseGlue` argument handed to
	 * `BodyFit.fitLineLayout` on the `_fitCase` path — the generated typed
	 * `caseBodyControlFlowRoot` predicate applied to the body's single
	 * statement. Flag off ⇒ `macro false`, which is `fitLineLayout`'s own
	 * default and therefore byte-inert.
	 *
	 * Read only inside the `_fitCase` arm, where `_arr.length == 1` holds by
	 * construction (`_caseBodyFlattenable`).
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaTryparseGlueRefusalExpr(refuseGlueOnControlFlow: Bool): Expr {
		return refuseGlueOnControlFlow ? WriterLowering.astPredCallT('caseBodyControlFlowRoot', [macro _arr[0].node]) : macro false;
	}

	/**
	 * Tryparse-Star `tryparseBlockEndedSepEmit` builder
	 * (ω-blockended-trivia-tryparse): inject `sepText` between two not-yet-
	 * statement-terminated elements. Null sepText / non-blockEnded ⇒ no-op.
	 *
	 */
	private static function triviaTryparseBlockEndedSepEmit(
		sepText: Null<String>, blockEnded: Bool, sepFaithful: Bool = false, ?elemCondFnExpr: Expr
	): Expr {
		// ω-sep-faithful: source-fidelity mode — the sep re-emits iff the
		// parser captured one after the prior element (`sepAfter`), with no
		// `}`/`;` shape heuristics. Used by comma-lists inside conditional
		// element groups (`HxConditionalArgs.body`), where a `}`-ending
		// object-literal element still needs its comma.
		final priorCondProbe: Expr = elemCondFnExpr == null ? macro false : macro $elemCondFnExpr(_arr[_si - 1].node);
		return sepText != null && sepFaithful
			? macro {
				if (_si > 0 && _arr[_si - 1].sepAfter) {
					_docs.push(_dt($v{sepText}));
				}
			}
			: sepText != null && blockEnded
				? macro {
					if (
						_si > 0 && _priorElemDoc != null
						&& (_arr[_si - 1].sepAfter || (!anyparse.core.DocMeasure.endsWithStmtTerminator(_priorElemDoc) && !$priorCondProbe))
					) {
						_docs.push(_dt($v{sepText}));
					}
				}
				: macro {};
	}

	/**
	 * Tryparse-Star `tryparseBlockEndedTrailEmit` builder
	 * (ω-blockended-trivia-tryparse-trail): post-loop tail sep so the last
	 * element keeps its source `;`. Null sepText / non-blockEnded ⇒ no-op.
	 *
	 */
	private static function triviaTryparseBlockEndedTrailEmit(sepText: Null<String>, blockEnded: Bool, sepFaithful: Bool = false): Expr {
		// ω-sep-faithful: trailing sep before the enclosing `#end`/`#else`
		// re-emits iff the source had it (`sepAfter` on the LAST element) —
		// the mandatory-comma case `[a, #if x b, #end c]`.
		return sepText != null && sepFaithful
			? macro {
				if (_arr.length > 0 && _arr[_arr.length - 1].sepAfter) {
					_docs.push(_dt($v{sepText}));
				}
			}
			: sepText != null && blockEnded
				? macro {
					if (
						_arr.length > 0 && _priorElemDoc != null && _arr[_arr.length - 1].sepAfter
						&& !anyparse.core.DocMeasure.endsWithSemi(_priorElemDoc)
					) {
						_docs.push(_dt($v{sepText}));
					}
				}
				: macro {};
	}

	/**
	 * Tryparse-Star `condIncreaseGateExpr` builder (ω-cond-indent-policy):
	 * runtime gate true when `condBodyIndent` AND the active
	 * `opt.conditionalPolicy` is AlignedIncrease / AlignedDecrease.
	 *
	 */
	private static function triviaTryparseCondIncreaseGateExpr(condBodyIndent: Bool): Expr {
		return condBodyIndent
			? macro (opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.AlignedIncrease
				|| opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.AlignedDecrease)
			: macro false;
	}

	/**
	 * Tryparse-Star `condNestedIncreaseGateExpr` builder (ω-cond-indent-policy
	 * AlignedNestedIncrease): per-element gate true when `condBodyIndent` AND
	 * the active `opt.conditionalPolicy` is AlignedNestedIncrease.
	 */
	private static function triviaTryparseCondNestedIncreaseGateExpr(condBodyIndent: Bool): Expr {
		return condBodyIndent
			? macro (opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.AlignedNestedIncrease)
			: macro false;
	}

	/**
	 * ω-case-body-fitline-shared — declare the tryparse-Star's
	 * `_caseBodyFlattenable` / `_flatCase` / `_fitCase` runtime locals.
	 *
	 * One eligibility, two placement decisions. The eligibility is the body
	 * SHAPE: a `nestBody` Star holding exactly one element, with no leading
	 * comment on that element, and not refused by `refuseFlatOnComplexExpr`.
	 * On top of it, `_flatCase` COMMITS the body to the case-header line at
	 * write time (`Same`, or `Keep` on same-line source) and `_fitCase` defers
	 * the same-vs-next choice to the renderer (`FitLine`). Every other policy —
	 * `Next`, and `Keep` with a source-broken body — leaves both false, which
	 * is the plain `nestBody` break.
	 *
	 * The two are mutually exclusive because one policy value cannot be both
	 * `Same`/`Keep` and `FitLine`; the explicit `!_flatCase` keeps that true
	 * by construction, so the two consumers may test them in either order
	 * (the separator cascade asks `_flatCase` first, the wrap helper asks
	 * `_fitCase` first) without the orderings ever disagreeing.
	 *
	 * `_flatCase` additionally requires an EMPTY orphan trailing-comment run
	 * (omega-case-trail-comment-inline). The eligibility used to carry that
	 * clause, which pushed a body below its label for a comment that never
	 * needed it out of the way — one commented-out case between two live ones
	 * made the switch read asymmetric with no visible cause. `_fitCase` no
	 * longer asks: `BodyFit.fitLineLayout` places the body and the wrap helper
	 * appends the trail docs after it at LABEL level, exactly where the
	 * `nestBody` arm already renders them (issue_392). `_flatCase` keeps the clause deliberately - it is the policy the fork
	 * corpus runs under (which is what keeps that corpus byte-identical per
	 * fixture; a `fitLine` tree does move, by design), and its separator is
	 * already pushed by the cascade, so relaxing it there would be a parity
	 * change rather than a placement fix.
	 *
	 * `_fitCase` additionally refuses a case label that captured a same-line
	 * trailing comment. `BodyFit.fitLineLayout` owns the header→body
	 * separator, so it must receive the body ALONE; a captured comment sits
	 * in `_docs` AHEAD of the body and would land on the wrong side of that
	 * separator (`case 1:  // note`, double space). Refusing costs nothing:
	 * a `//` comment runs to a physical newline, so the body could never
	 * share the label's line anyway, and the `nestBody` break that catches
	 * it is exactly what `Next` and the pre-slice engine emit.
	 *
	 * Emitted as a single `EVars` (NOT an `EBlock`) so all three locals land
	 * in the caller's scope, mirroring `triviaTryparseTrailEndsLineDecl`, and
	 * extracted so `triviaTryparseMainExpr` stays under the complexity gate.
	 */
	private static function triviaTryparseCaseGateDecls(
		shapeRefusalExpr: Expr, flatGateExpr: Expr, fitGateExpr: Expr, priorAfterTrailRaw: Expr
	): Expr {
		final eligible: Expr = macro _nestBody && _arr.length == 1 && _arr[0].leadingComments.length == 0 && $shapeRefusalExpr;
		return {
			expr: EVars([
				{
					name: '_caseBodyFlattenable',
					type: macro :Bool,
					expr: eligible,
					isFinal: true
				},
				{
					name: '_flatCase',
					type: macro :Bool,
					expr: macro _caseBodyFlattenable && _trailLC.length == 0 && $flatGateExpr,
					isFinal: true
				},
				{
					name: '_fitCase',
					type: macro :Bool,
					expr: macro _caseBodyFlattenable && !_flatCase && $priorAfterTrailRaw == null && $fitGateExpr,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		};
	}

}
#end
