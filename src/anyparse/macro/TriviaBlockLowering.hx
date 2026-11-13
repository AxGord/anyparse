package anyparse.macro;

#if macro
import anyparse.core.ShapeTree.ShapeNode;
import anyparse.macro.WriterBlankLowering.*;
import haxe.macro.Context;
import haxe.macro.Expr;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W helpers — the block-mode (`@:lead` + `@:trail` + `@:trivia`) Star
 * emit family.
 *
 * Builds the generated writer body for a delimited trivia Star — class /
 * enum / abstract bodies, block statements and expressions, switch bodies:
 * the per-element hardline baseline, the leading / trailing comment
 * placement, the begin/end-of-body blank-line counts
 * (`@:fmt(beginEndType)` → `opt.beginType` / `opt.endType`, with the
 * enum-abstract override and the `afterLeftCurly` / `beforeRightCurly`
 * Keep fallback), the element write call with its
 * `tailStmtReadsExprPosition` tail barrier, the between-element and
 * trailing `@:sep(text, tailRelax, blockEnded)` separator emission and its
 * predicate elision, and the inter-element blank-line decision (the strip /
 * add gates over doc comments, existing blanks, the interMember var/fn cascade and the uniform-between
 * knob, plus the per-element `_currHasDocComment` / `_currKind` computes feeding them).
 *
 * Split out of `WriterLowering` for size — the two are NOT independent. The
 * macro-time surface is small: one inbound entry (`triviaBlockStarExpr`,
 * called from `WriterLowering.emitTriviaBlockStarDispatch` and
 * `WriterLowering.triviaBlockStarBuild`) and a short outbound list back
 * into the shared lowering utilities (`astPredCallT`,
 * `blankBefore2ExtrasExpr`, `blankAroundMultilineExprs`, `triviaBalcEmitExpr`,
 * `triviaUniformCollapseInitExpr`, plus the `_astPredsOnStatic` gate
 * mirror). Both directions run through `@:access` and every member here
 * stays private.
 *
 * Parameters typed by a `WriterLowering` sub-module typedef stay qualified:
 * the extraction moved the functions, not the typedefs, so the whole
 * sub-module typedef block still lives in `WriterLowering`'s module. The
 * classify / subdivision infos are also read by the struct-lowering members
 * that stayed behind; `BlockLeafExprs` is now read only from here. One instance is one Star's emit
 * (`TriviaStarEmit`): the constructor reads its plan and builds its inputs, the instance builders splice them.
 *
 * The GENERATED-code surface is the real contract, and no type carries it:
 * every helper splices identifiers declared elsewhere in the Star body —
 * `_arr` / `_t` / `_si` / `_inner` / `opt` / `_dhl()` from the Star
 * scaffold, `_prevHadDocComment` / `_currHasDocComment` / `_prevKind` / `_currKind` from
 * `triviaBlockLeafExprs`, `_uniformCollapse` from the declaration
 * `triviaBlockElseBody` splices. Those declare sites are gated on the SAME
 * `@:fmt` flags as the computes that read them
 * (`beforeDocCommentEmptyLines`, `interMember`, `uniformStmtBlanks`): move a gate on one side only and the generated
 * writer either reads an undeclared local or declares a dead one, with
 * nothing in this module's types to catch it.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterLoweringSupport)
final class TriviaBlockLowering extends TriviaStarEmit<BlockStarPlan> {

	private final _beginEnd: { final beginTypeExpr: Expr; final endTypeExpr: Expr; };
	private final _between: { final leadingSplitGateExpr: Expr; final blockLeadingBetweenExpr: Expr; final blockTrailBetweenExpr: Expr; };
	private final _sep: { final blockSepBeforeHardlineExpr: Expr; final blockTrailSepEmitExpr: Expr; final elemSepGlueExpr: Expr; };
	private final _blankAround: { final markExpr: Expr; final seenExpr: Expr; final applyExpr: Expr; };
	private final _elemCall: Expr;
	private final _emptyDocExpr: Expr;
	private final _beforeCloseHardlineExpr: Expr;
	private final _blankBeforeExpr: Expr;
	private final _leaf: WriterLowering.BlockLeafExprs;
	private final _elemPushExpr: Expr;
	private final _glueToPreviousExpr: Expr;

	/**
	 * Reads a block-mode trivia Star's (`@:lead(open) @:trail(close) @:trivia`) plan and builds every input its emit splices.
	 * A struct field's block Star (`source` non-null) also reads its member-gap, doc-edge and line-comment inputs off its node
	 * through the dispatch's readers; an enum ctor's block Star has none of them. `blockSep` is the separator of a blockEnded
	 * Star, null for every other. `elemFn` is the `*T`-variant write function: the emit does not consult `isTriviaBearing`.
	 */
	@:access(anyparse.macro.WriterTriviaStarDispatch)
	private function new(
		plan: BlockStarPlan, fieldAccess: Expr, slots: TriviaStarEmit.TrailSlots, elemFn: String, openText: String, closeText: String,
		blockSep: Null<String>, schemaTypePath: Null<String>,
		source: Null<{ final tc: WriterTriviaStarDispatch.TriviaStarDispatchCtx; final starNode: ShapeNode; final elemRefName: String; }>
	) {
		// noqa: complexity
		super(plan, fieldAccess, slots, openText, closeText);
		final afterFieldsWithDocComments: Null<Expr> = source == null ? null : WriterTriviaStarDispatch.afterDocPolicy(source.starNode);
		final existingBetweenFields: Null<Expr> = source == null
			? null
			: WriterTriviaStarDispatch.starKnobReads(BlockStarPlan.EXISTING_BETWEEN_FIELDS, plan.existingBetweenFields(), 1)?.pop();
		final beginEndKnobs: Array<Expr> = source == null
			? []
			: WriterTriviaStarDispatch.docEdgeReads(
				plan.beginEndTypeIfDoc(),
				WriterTriviaStarDispatch.starKnobReads(BlockStarPlan.BEGIN_END_TYPE, plan.beginEndTypeKnobs()) ?? []
			);
		final beginTypeAccess: Null<Expr> = beginEndKnobs[0];
		final endTypeAccess: Null<Expr> = beginEndKnobs[1];
		final lineCommentTrailBlank: Null<Expr> = source == null ? null : WriterTriviaStarDispatch.lineCommentTrailGate(source.starNode);
		final infos: Null<WriterLowering.TriviaBlockInfos> = source == null
			? null
			: WriterTriviaStarDispatch.buildTriviaBlockInfos(
				source.tc, source.starNode, source.elemRefName, plan.beforeDocCommentEmptyLines()
			);
		final uniformBetweenOptField: Null<String> = source == null
			? null
			: WriterLoweringSupport.fmtSingleStringArg(BlockStarPlan.UNIFORM_BETWEEN, plan.uniformBetween());
		_elemCall = triviaBlockElemCallExpr(elemFn, plan.leftCurlyAnonFnOverride(), plan.clearExprPositionNonTail());
		_emptyDocExpr = triviaBlockEmptyDocExpr(
			openText, closeText, openText + closeText, plan.emptyCurlyBreak(), plan.emptyCurlyBreakKnob(), plan.emptyBlockBreak()
		);
		_beforeCloseHardlineExpr = triviaBlockBeforeCloseHardlineExpr(plan.rightCurlyKnob(), plan.rightCurlyAnonFnOverrideKnob());
		final interMemberInfo: Null<WriterLowering.InterMemberClassifyInfo> = infos?.interMemberInfo;
		final staticVarSubdivInfo: Null<WriterLowering.StaticVarSubdivisionInfo> = infos?.staticVarSubdivInfo;
		final interMember: Bool = interMemberInfo != null;
		final uniformBetween: Bool = uniformBetweenOptField != null;
		final anyEmptyLinesFlag: Bool = afterFieldsWithDocComments != null
			|| existingBetweenFields != null
			|| plan.beforeDocCommentEmptyLines()
			|| interMember
			|| uniformBetween;
		_blankBeforeExpr = triviaBlockBlankBeforeExpr(
			afterFieldsWithDocComments, existingBetweenFields, plan.beforeDocCommentEmptyLines(), infos?.condLeadingDocInfo, interMember,
			interMemberInfo, staticVarSubdivInfo != null, staticVarSubdivInfo, uniformBetween, uniformBetweenOptField, anyEmptyLinesFlag,
			plan.uniformStmtBlanks()
		);
		_beginEnd = triviaBlockBeginEndExpr(
			plan.beginEndType(), plan.keepCurlyBlanks(), beginTypeAccess ?? macro null, endTypeAccess ?? macro null
		);
		_between = triviaBlockBetweenExprs(plan.blankBeforeFinalDocCommentInLeading(), plan.betweenMultilineCommentsBlanks());
		_sep = triviaBlockSepExprs(
			blockSep, blockSep != null, blockSep != null ? plan.blockEndedPredicate() : null, blockSep != null ? schemaTypePath : null
		);
		_leaf = triviaBlockLeafExprs(
			afterFieldsWithDocComments, plan.beforeDocCommentEmptyLines(), interMember, plan.indentCaseLabels(), lineCommentTrailBlank
		);
		_blankAround = blankAroundMultilineExprs(plan.gapRule());
		_elemPushExpr = triviaBlockElemPushExpr(plan.relocateTrailingComments());
		_glueToPreviousExpr = WriterLoweringSupport.triviaGlueToPreviousExpr(plan.glueToPrevious());
	}

	/**
	 * Block-Star per-element while-loop emit. Builds the `while (_si < _arr.length)`
	 * loop: blockEnded sep, per-iter hardline, begin-type (first elem), blank-
	 * before, leading-comment emit (with split-gate + between-blank), element emit
	 * with trailing-comment fold, and prev-kind track. References the runtime
	 * `_arr`/`_inner`/`_si`/`_priorElemDoc`/`opt` locals declared in the emitted
	 * scope.
	 */
	@:access(anyparse.macro.WriterLowering)
	private function triviaBlockWhileExpr(): Expr {
		final balcEmitExpr: Expr = triviaBalcEmitExpr(_plan.uniformStmtBlanks());
		return macro {
			while (_si < _arr.length) {
				final _t = _arr[_si];
				// A glued element skips its own line, blank-line policy and kind tracking, so the
				// element after it is spaced as if it followed the previous element directly.
				if ($_glueToPreviousExpr) {
					final _elem: anyparse.core.Doc = $_elemCall;
					final _tc: Null<String> = _t.trailingComment;
					final _elemSep: anyparse.core.Doc = _elem;
					$_elemPushExpr;
					_si++;
					continue;
				}
				${_leaf.initCurrKindExpr};
				${_sep.blockSepBeforeHardlineExpr};
				_inner.push(_dhl());
				if (_si == 0) ${_beginEnd.beginTypeExpr};
				${_blankAround.markExpr};
				$_blankBeforeExpr;
				${_blankAround.seenExpr};
				var _ci: Int = 0;
				while (_ci < _t.leadingComments.length) {
					${_between.leadingSplitGateExpr};
					_inner.push(leadingCommentDocRun(_t.leadingComments, _ci, opt));
					_inner.push(_dhl());
					${_between.blockLeadingBetweenExpr};
					_ci++;
				}
				$balcEmitExpr;
				${_leaf.trackDocCommentExpr};
				final _elem: anyparse.core.Doc = $_elemCall;
				${_blankAround.applyExpr};
				final _tc: Null<String> = _t.trailingComment;
				final _elemSep: anyparse.core.Doc = ${_sep.elemSepGlueExpr};
				$_elemPushExpr;
				_priorElemDoc = _elem;
				${_leaf.trackPrevKindExpr};
				_si++;
			}
		};
	}

	/**
	 * Block-Star non-empty branch body. Builds the `_inner` accumulation, the
	 * per-element while loop (via `triviaBlockWhileExpr`), the trailing-sep emit,
	 * the orphan-trail-comment chain (or end-type tail), and the open/close-
	 * trailing-comment `_parts` assembly wrapped in `_dwb(_dbg(...))`.
	 */
	@:access(anyparse.macro.WriterLowering)
	private function triviaBlockElseBody(): Expr {
		final uniformCollapseInitExpr: Expr = triviaUniformCollapseInitExpr(_plan.uniformStmtBlanks());
		final whileExpr: Expr = triviaBlockWhileExpr();
		return macro {
			final _inner: Array<anyparse.core.Doc> = [];
			${_leaf.initDocCommentExpr};
			${_leaf.initCurrDocCommentExpr};

			${_leaf.initPrevKindExpr};
			$uniformCollapseInitExpr;
			// ω-blockended-trivia (Session 3): tracks the prior iteration's rendered
			// element Doc so the between-element sep emission can query
			// `DocMeasure.endsWithStmtTerminator`. Null on the first iteration.
			var _priorElemDoc: Null<anyparse.core.Doc> = null;
			var _sepGlued: Bool = false;
			var _si: Int = 0;
			$whileExpr;
			// ω-blockended-trivia-trail-sep (Session 3): after the last element, if
			// source had `;` AND prior doesn't already terminate, emit `;` so
			// source-fidelity is preserved.
			${_sep.blockTrailSepEmitExpr};
			if (_trailLC.length > 0) {
				_inner.push(_dhl());
				if (${_leaf.extraInnerTrailBlankExpr}) _inner.push(_dhl());
				var _ti: Int = 0;
				while (_ti < _trailLC.length) {
					_inner.push(leadingCommentDocRun(_trailLC, _ti, opt));
					if (_ti < _trailLC.length - 1) _inner.push(_dhl());
					${_between.blockTrailBetweenExpr};
					_ti++;
				}
			}
			// A body of comments only has no edge blanks: the type's edges are read against members.
			if (_trailLC.length == 0 || _arr.length > 0) ${_beginEnd.endTypeExpr};
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _innerWrap: anyparse.core.Doc = ${_leaf.innerWrapExpr};
			final _parts: Array<anyparse.core.Doc> = [_dt($v{_openText})];
			if (_trailOpen != null) _parts.push(trailingCommentDocVerbatim(_trailOpen, opt));
			_parts.push(_innerWrap);
			_parts.push($_beforeCloseHardlineExpr);
			_parts.push(_dt($v{_closeText}));
			if (_trailClose != null) {
				// Group-closer seam: a block that is itself an element of an
				// inline group - `g(function() {\n\th();\n} // c\n)` - puts the
				// call's `)` right after the comment on the same Doc line, where a
				// LINE comment swallows it. The guarded emitter carries its own
				// forward-looking hardline for LINE style; a block comment keeps
				// its legal glue.
				_parts.push(trailingCommentDocGuarded(_trailClose, opt));
			}
			// ω-break-group / ω-force-flat-engine sister-coverage: wrap the block
			// body in BodyGroup so a surrounding Group does not see the body's
			// hardlines through its fitsFlat measurement; `_dwb` is a no-op outside
			// a Flatten frame, an opt-out boundary inside one.
			_dwb(_dbg(_dc(_parts)));
		};
	}

	/**
	 * Block-Star top-level Doc build (the orchestrator's emitted body). Dispatches
	 * the empty-Star fast paths (open-trailing-comment flat emit / empty-curly
	 * dispatch) and the non-empty branch (via `triviaBlockElseBody`). References
	 * the runtime `opt` local and the spliced Exprs the constructor built.
	 *
	 */
	private function triviaBlockStarExpr(): Expr {
		final emptyText: String = _openText + _closeText;
		final emptyTrailExpr: Expr = macro _dc([_dt($v{emptyText}), trailingCommentDocGuarded(_trailClose, opt)]);
		final elseBody: Expr = triviaBlockElseBody();
		return macro {
			final _arr = $_fieldAccess;

			${trailSlotDecls()};
			// ω-open-trailing-alt: empty Star with a same-line block-style trail
			// comment after the open lit (`{ /* nop */ }`) emits flat tight. Mirror
			// of the equivalent fast path in `triviaSepStarExpr`.
			if (_arr.length == 0 && _trailLC.length == 0 && _trailOpen != null && StringTools.startsWith(_trailOpen, '/*')) {
				final _openDoc: anyparse.core.Doc = anyparse.core.LeafTag.DelimiterLeaf.leaf(_trailOpen);
				if (_trailClose != null)
					_dc([
						_dt($v{_openText}),
						_openDoc,
						_dt($v{_closeText}),
						trailingCommentDocGuarded(_trailClose, opt)
					]);
				else
					_dc([_dt($v{_openText}), _openDoc, _dt($v{_closeText})]);
			} else if (_arr.length == 0 && _trailLC.length == 0 && _trailOpen == null) {
				if (_trailClose != null)
					$emptyTrailExpr
				else
					$_emptyDocExpr;
			} else
				$elseBody;
		};
	}

	/**
	 * Block-Star current-element doc-comment compute (ω-cond-leading-doc-
	 * lookthrough). Builds the `_currHasDocComment` per-iteration scan, folding
	 * in the `#if … #end` inner-member look-through when `condLeadingDocInfo`
	 * resolved.
	 */
	private static function triviaBlockCurrHasDocComputeExpr(
		beforeDocCommentEmptyLines: Bool, condLeadingDocInfo: Null<WriterLowering.CondLeadingDocLookThroughInfo>
	): Expr {
		// ω-cond-leading-doc-lookthrough: when the element is a `#if … #end`
		// member whose first inner member opens with `/**`, treat the
		// Conditional as doc-comment-led (the inner doc-comment lives on the
		// inner member's leading, never on the `#if` directive). Spliced into
		// `currHasDocComputeExpr` only when the look-through info resolved.
		final condLeadingDocExpr: Expr = condLeadingDocInfo != null ? {
			final pos: Position = Context.currentPos();
			final classifierAccess: Expr = { expr: EField(macro _t.node, condLeadingDocInfo.classifierFieldName), pos: pos };
			final bodyAccess: Expr = { expr: EField(macro _inner, condLeadingDocInfo.bodyFieldName), pos: pos };
			final scanBody: Expr = macro {
				final _condBody = $bodyAccess;
				if (_condBody.length > 0 && anyparse.format.MemberGap.docLed(_condBody[0].leadingComments)) _currHasDocComment = true;
			};
			final lookThroughSwitch: Expr = {
				expr: ESwitch(classifierAccess, [{ values: [condLeadingDocInfo.condCasePattern], guard: null, expr: scanBody }], macro {}),
				pos: pos
			};
			macro if (!_currHasDocComment) $lookThroughSwitch;
		} : macro {};
		return beforeDocCommentEmptyLines
			? macro {
				_currHasDocComment = anyparse.format.MemberGap.docLed(_t.leadingComments);
				$condLeadingDocExpr;
			}
			: macro {};
	}

	/**
	 * Block-Star current-element kind compute (ω-class-static-var-cascade /
	 * ω-abstract-static-fn-cascade). Builds the `_currKind` classifier switch
	 * plus the static-promotion sibling-modifier scan.
	 */
	private static function triviaBlockCurrKindComputeExpr(
		interMember: Bool, interMemberInfo: Null<WriterLowering.InterMemberClassifyInfo>, staticVarSubdiv: Bool,
		staticVarSubdivInfo: Null<WriterLowering.StaticVarSubdivisionInfo>
	): Expr {
		final staticPromoteExpr: Expr = staticVarSubdiv ? {
			final pos: Position = Context.currentPos();
			final modAccess: Expr = { expr: EField(macro _t.node, staticVarSubdivInfo.modifierFieldName), pos: pos };
			final staticIdent: Expr = { expr: EConst(CIdent(staticVarSubdivInfo.staticCtorName)), pos: pos };
			macro {
				if (_currKind == 1 || _currKind == 2) for (_m in $modAccess) if (_m.node.match($staticIdent)) {
					_currKind = _currKind == 1 ? 3 : 4; // noqa: magic-number
					break;
				}
			};
		} : macro {};
		return interMember ? {
			final classifierAccess: Expr = { expr: EField(macro _t.node, interMemberInfo.classifierFieldName), pos: Context.currentPos() };
			final switchExpr: Expr = { expr: ESwitch(classifierAccess, interMemberInfo.classifyCases, null), pos: Context.currentPos() };
			macro {
				_currKind = $switchExpr;
				$staticPromoteExpr;
			};
		} : macro {};
	}

	/**
	 * Block-Star inter-member add-blank rule (ω-extern-class-no-blanks /
	 * ω-class-static-var-cascade / ω-abstract-static-fn-cascade). Builds the
	 * runtime boolean that fires a blank between two members per the var/fn /
	 * static-var/static-fn cascade.
	 */
	private static function triviaBlockInterMemberAddExpr(
		interMember: Bool, interMemberInfo: Null<WriterLowering.InterMemberClassifyInfo>, staticVarSubdiv: Bool,
		staticVarSubdivInfo: Null<WriterLowering.StaticVarSubdivisionInfo>
	): Expr {
		if (!interMember) return macro false;
		final betweenVarsAccess: Expr = interMemberInfo.betweenVars;
		final betweenFnAccess: Expr = interMemberInfo.betweenFunctions;
		final afterVarsAccess: Expr = interMemberInfo.afterVars;
		// ω-class-static-var-cascade / ω-abstract-static-fn-cascade: when
		// subdivision is active, kinds `3` / `4` represent static-var / static-fn;
		// the var/fn cascade arms split accordingly (see the subdiv arm helpers).
		// When subdivision is off, kinds `3` / `4` are unreachable and the cascade
		// collapses to the pre-slice three arms.
		return staticVarSubdiv
			? triviaBlockInterMemberSubdivExpr(
				betweenVarsAccess, betweenFnAccess, afterVarsAccess, staticVarSubdivInfo.afterStaticVars,
				staticVarSubdivInfo.betweenStaticFunctions
			)
			: triviaBlockInterMemberPlainExpr(betweenVarsAccess, betweenFnAccess, afterVarsAccess);
	}

	/**
	 * Block-Star inter-element blank-line build (ω-C-empty-lines-* family). Builds
	 * the `blankBeforeExpr` consumed in the per-element loop: the strip / add
	 * doc-comment + existing-between + interMember + uniform-
	 * between gates, the `_currHasDocComment` / `_currKind` / `_currHasSplitLeading`
	 * computes (via the cascade sub-helpers), and the final `_stripBlank` /
	 * `_addBlank` / `_sourceBlank` decision.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaBlockBlankBeforeExpr(
		afterFieldsWithDocComments: Null<Expr>, existingBetweenFields: Null<Expr>, beforeDocCommentEmptyLines: Bool,
		condLeadingDocInfo: Null<WriterLowering.CondLeadingDocLookThroughInfo>, interMember: Bool,
		interMemberInfo: Null<WriterLowering.InterMemberClassifyInfo>, staticVarSubdiv: Bool,
		staticVarSubdivInfo: Null<WriterLowering.StaticVarSubdivisionInfo>, uniformBetween: Bool, uniformBetweenOptField: Null<String>,
		anyEmptyLinesFlag: Bool, uniformStmtBlanks: Bool
	): Expr {
		final blankExtras: Expr = blankBefore2ExtrasExpr(macro _inner.push(_dhl()));
		if (!anyEmptyLinesFlag) return triviaBlockSourceBlankOnlyExpr(uniformStmtBlanks, blankExtras);
		// The doc-comment rule is ONE runtime policy (`anyparse.format.MemberGap`), shared with the
		// `member-order` check: each side the Star carries no flag for reads as "not doc-led" under `Ignore`.
		final prevDocExpr: Expr = afterFieldsWithDocComments != null ? macro _prevHadDocComment : macro false;
		final afterPolicyExpr: Expr = afterFieldsWithDocComments ?? macro anyparse.format.CommentEmptyLinesPolicy.Ignore;
		final currDocExpr: Expr = beforeDocCommentEmptyLines ? macro _currHasDocComment : macro false;
		final beforePolicyExpr: Expr = beforeDocCommentEmptyLines
			? macro opt.beforeDocCommentEmptyLines
			: macro anyparse.format.CommentEmptyLinesPolicy.Ignore;
		final docRule: Bool = afterFieldsWithDocComments != null || beforeDocCommentEmptyLines;
		final stripByDocExpr: Expr = docRule
			? macro anyparse.format.MemberGap.docStrips($prevDocExpr, $currDocExpr, $afterPolicyExpr, $beforePolicyExpr)
			: macro false;
		final currAddsByDocExpr: Expr = beforeDocCommentEmptyLines
			? macro (_currHasDocComment && !anyparse.format.MemberGap.docSplitLead(_t.leadingComments))
			: macro false;
		final addByDocExpr: Expr = docRule
			? macro anyparse.format.MemberGap.docAdds($prevDocExpr, $currAddsByDocExpr, $afterPolicyExpr, $beforePolicyExpr)
			: macro false;
		final stripByExistingExpr: Expr = existingBetweenFields != null
			? macro ($existingBetweenFields == anyparse.format.KeepEmptyLinesPolicy.Remove)
			: macro false;
		final vetoByDocExpr: Expr = beforeDocCommentEmptyLines
			? macro anyparse.format.MemberGap.docVetoes(_currHasDocComment, opt.beforeDocCommentEmptyLines)
			: macro false;
		final currHasDocComputeExpr: Expr = triviaBlockCurrHasDocComputeExpr(beforeDocCommentEmptyLines, condLeadingDocInfo);

		final currKindComputeExpr: Expr = triviaBlockCurrKindComputeExpr(
			interMember, interMemberInfo, staticVarSubdiv, staticVarSubdivInfo
		);
		final addByInterMemberExpr: Expr = triviaBlockInterMemberAddExpr(
			interMember, interMemberInfo, staticVarSubdiv, staticVarSubdivInfo
		);
		final addByUniformBetweenExpr: Expr = triviaBlockUniformBetweenAddExpr(uniformBetween, uniformBetweenOptField);
		return triviaBlockBlankBeforeAssemblyExpr({
			currHasDocComputeExpr: currHasDocComputeExpr,
			currKindComputeExpr: currKindComputeExpr,

			stripByDocExpr: stripByDocExpr,
			stripByExistingExpr: stripByExistingExpr,
			vetoByDocExpr: vetoByDocExpr,

			addByDocExpr: addByDocExpr,

			addByInterMemberExpr: addByInterMemberExpr,
			addByUniformBetweenExpr: addByUniformBetweenExpr
		});
	}

	/**
	 * Block-Star interMember subdivision var-family add arms (kinds 1/3, the
	 * instance-var / static-var rows): same-kind `betweenVars` + instance↔static
	 * `afterStaticVars`. Returns the OR of the three var-family arms.
	 */
	private static function triviaBlockSubdivVarArmsExpr(betweenVarsAccess: Expr, afterStaticVarsAccess: Expr): Expr {
		return macro ((_prevKind == 1 && _currKind == 1 && $betweenVarsAccess > 0)
			|| (_prevKind == 3 && _currKind == 3 && $betweenVarsAccess > 0) // noqa: magic-number
			|| (((_prevKind == 1 && _currKind == 3) || (_prevKind == 3 && _currKind == 1)) && $afterStaticVarsAccess > 0)); // noqa
	}

	/**
	 * Block-Star interMember subdivision fn-family add arms (kinds 2/4, the
	 * function / static-function rows): (4,4) `betweenStaticFunctions` + every
	 * other fn-fn pair `betweenFunctions`. Returns the OR of the two fn-family
	 * arms.
	 */
	private static function triviaBlockSubdivFnArmsExpr(betweenFnAccess: Expr, betweenStaticFnAccess: Expr): Expr {
		return macro ((_prevKind == 4 && _currKind == 4 && $betweenStaticFnAccess > 0) // noqa: magic-number
			|| (((_prevKind == 2 && _currKind == 2) || (_prevKind == 2 && _currKind == 4) || (_prevKind == 4 && _currKind == 2)) // noqa
				&& $betweenFnAccess > 0));
	}

	/**
	 * Block-Star interMember subdivision var↔fn transition arm: a {1,3}↔{2,4}
	 * boundary fires `afterVars`. Returns the single transition arm.
	 */
	private static function triviaBlockSubdivVarFnArmExpr(afterVarsAccess: Expr): Expr {
		return macro ((((_prevKind == 1 || _prevKind == 3) && (_currKind == 2 || _currKind == 4)) // noqa: magic-number
			|| ((_prevKind == 2 || _prevKind == 4) && (_currKind == 1 || _currKind == 3)))
			&& $afterVarsAccess > 0); // noqa
	}

	/**
	 * Block-Star interMember subdivision-active add rule (ω-class-static-var-
	 * cascade / ω-abstract-static-fn-cascade). Composes the var-family / fn-family
	 * / var↔fn arms.
	 */
	private static function triviaBlockInterMemberSubdivExpr(
		betweenVarsAccess: Expr, betweenFnAccess: Expr, afterVarsAccess: Expr, afterStaticVarsAccess: Expr, betweenStaticFnAccess: Expr
	): Expr {
		final varArms: Expr = triviaBlockSubdivVarArmsExpr(betweenVarsAccess, afterStaticVarsAccess);
		final fnArms: Expr = triviaBlockSubdivFnArmsExpr(betweenFnAccess, betweenStaticFnAccess);
		final varFnArm: Expr = triviaBlockSubdivVarFnArmExpr(afterVarsAccess);
		return macro ($varArms || $fnArms || $varFnArm);
	}

	/**
	 * Block-Star interMember subdivision-off add rule (the pre-slice three arms):
	 * same-var `betweenVars`, same-fn `betweenFunctions`, var↔fn `afterVars`.
	 */
	private static function triviaBlockInterMemberPlainExpr(betweenVarsAccess: Expr, betweenFnAccess: Expr, afterVarsAccess: Expr): Expr {
		return macro (
			(_prevKind == 1 && _currKind == 1 && $betweenVarsAccess > 0)
			|| (_prevKind == 2 && _currKind == 2 && $betweenFnAccess > 0)
			|| (_prevKind != 0 && _currKind != 0 && _prevKind != _currKind && $afterVarsAccess > 0)
		);
	}

	/**
	 * Block-Star blank-before final assembly (ω-beforedoc-none-precedence). Builds
	 * the `macro {}` consumed when any empty-lines flag is active: runs the
	 * per-element computes, derives `_stripBlank` / `_addBlank` / `_sourceBlank`
	 * from the strip / add gate Exprs, and emits the inter-element `_dhl()`.
	 *
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaBlockBlankBeforeAssemblyExpr(g: BlankGateExprs): Expr {
		final currHasDocComputeExpr: Expr = g.currHasDocComputeExpr;
		final currKindComputeExpr: Expr = g.currKindComputeExpr;

		final stripByDocExpr: Expr = g.stripByDocExpr;
		final stripByExistingExpr: Expr = g.stripByExistingExpr;
		final vetoByDocExpr: Expr = g.vetoByDocExpr;

		final addByDocExpr: Expr = g.addByDocExpr;
		final addByInterMemberExpr: Expr = g.addByInterMemberExpr;
		final addByUniformBetweenExpr: Expr = g.addByUniformBetweenExpr;
		final blankExtras: Expr = blankBefore2ExtrasExpr(macro _inner.push(_dhl()));
		return macro {
			$currHasDocComputeExpr;
			$currKindComputeExpr;
			final _stripBlank: Bool = $stripByDocExpr || $stripByExistingExpr;
			// ω-beforedoc-none-precedence: fork's `markDocCommentEmptyLines` applies
			// `beforeDocCommentEmptyLines` to the before-doc slot AFTER
			// `afterFieldsWithDocComments` (the prior field's after-slot is the same
			// physical gap), so the before-policy is the last write and wins. When
			// the current element opens with a doc comment and the before-policy is
			// `None`, the slot is forced to zero blanks — `$stripByDocExpr`
			// already zeroes `_sourceBlank`, so `$vetoByDocExpr` AND-outs every add
			// (`afterFieldsWithDocComments.One`, the interMember / uniform adds) too.
			// Byte-inert when the Star carries no `beforeDocCommentEmptyLines` flag
			// (`$vetoByDocExpr` is the compile-time literal `false`) or the
			// runtime policy is not `None`.
			final _addBlank: Bool = !$vetoByDocExpr && ($addByDocExpr || $addByInterMemberExpr || $addByUniformBetweenExpr);
			final _sourceBlank: Bool = _t.blankBefore && !_stripBlank;
			if (_si > 0 && (_sourceBlank || _addBlank)) {
				_inner.push(_dhl());
				if (_sourceBlank) $blankExtras;
			}
		};
	}

	/**
	 * Block-Star uniform-between add-blank gate (ω-enum-empty-lines). Opt-in via
	 * `@:fmt(uniformBetween('<optField>'))` — the named non-negative-Int knob is
	 * consulted at the inter-element slot (`> 0` contributes a blank).
	 */
	private static function triviaBlockUniformBetweenAddExpr(uniformBetween: Bool, uniformBetweenOptField: Null<String>): Expr {
		if (!uniformBetween) return macro false;
		final optAccess: Expr = { expr: EField(macro opt, uniformBetweenOptField), pos: Context.currentPos() };
		return macro $optAccess > 0;
	}

	/**
	 * The blank-before emit for a block Star carrying no empty-line policy flags:
	 * push a hardline for the source blank the parser recorded, gated on the
	 * `_uniformCollapse` pre-pass when the Star opted into `uniformStmtBlanks`.
	 */
	private static function triviaBlockSourceBlankOnlyExpr(uniformStmtBlanks: Bool, blankExtras: Expr): Expr {
		// ω-uniform-statement-blanks: gate the source-blank push on the
		// pre-pass `_uniformCollapse` flag (declared in `triviaBlockElseBody`
		// when this Star opted into `@:fmt(uniformStmtBlanks)`). Non-opted
		// block Stars keep the pre-slice guard byte-identical.
		final blankGuardExpr: Expr = uniformStmtBlanks
			? macro (_t.blankBefore && _si > 0 && !_uniformCollapse)
			: macro (_t.blankBefore && _si > 0);
		return macro {
			if ($blankGuardExpr) {
				_inner.push(_dhl());
				$blankExtras;
			}
		};
	}

	/**
	 * Block-Star per-element write-call build. Mirrors the inline element-call
	 * setup formerly at the top of `triviaBlockStarExpr`: the
	 * `clearAnonFnBodyOnElems` opt arg, the `clearExprPositionNonTail` tail
	 * barrier wrap, and the final `elemFn(_t.node, opt)` call. Extracted so the
	 * orchestrator stays under the complexity gate.
	 */
	@:access(anyparse.macro.WriterLowering)
	@:access(anyparse.macro.WriterOptFanout)
	private static function triviaBlockElemCallExpr(elemFn: String, clearAnonFnBodyOnElems: Bool, clearExprPositionNonTail: Bool): Expr {
		// ω-arrow-lambda-body-context: when the call site opts in via
		// `@:fmt(leftCurlyAnonFnOverride(...))` on the parent Star, the per-
		// element write call passes `_clearAnonFnBody(opt)` so the flag is
		// consumed at this Star's `{` placement and descendants (nested
		// statements / nested BlockExpr inside the body) fall back to the
		// default `blockLeftCurly` knob rather than re-triggering the
		// anon-fn override.
		final elemOptExpr: Expr = clearAnonFnBodyOnElems ? macro _clearAnonFnBody(opt) : macro opt;
		// ω-value-yielded-if-tail-barrier (SI-2): the per-element opt arg. When
		// `clearExprPositionNonTail` is set (BlockExpr / BlockStmt), every block
		// statement EXCEPT the tail gets `_clearExprPosition` so a discarded
		// statement-if reverts to the statement-position `ifBody` policy; only
		// the block's last statement (its yielded value) keeps the inherited
		// expression-position frame. `_si` / `_arr` are in scope at the single
		// splice site (`while (_si < _arr.length)` over `final _arr = …`). The
		// non-flag path emits the IDENTICAL `elemOptExpr` Doc as before.
		// ω-expressionif-collapse: a BLOCK-shaped branch (`if (c) { …; {obj} }`)
		// is an opaque barrier for the value-if-branch collapse — an object
		// literal that is the block's value is NOT the immediate value of the
		// value-if branch, so `_clearValueIfBranch` drops the narrow flag for
		// every block element (tail included). The broad `_inExprPosition`
		// frame still threads through (only non-tail clears it, per SI-2), so
		// this composes with the existing tail-keeps-expr-position rule.
		// `clearExprPositionNonTail` is carried only by Haxe block constructs
		// (BlockExpr / BlockStmt / HxFnBlock.stmts), whose shared
		// `HxModuleWriteOptions` always declares `_literalReflow` — so the
		// helper reference is safe inside this branch.
		// ω-arrow-body-objlit-pad: a block-shaped arrow body (`u -> { … }`) is
		// the same opaque barrier for the open-pad suppression — the `{` that
		// sat right after `->` was the BLOCK's brace, so no element's object
		// literal is token-adjacent to the arrow; `_clearArrowLambdaBody` drops
		// the flag for every block element (tail included). Those block
		// constructs' shared `HxModuleWriteOptions` always declares
		// `_inArrowLambdaBody`, so the helper reference is safe inside this branch.
		// ω-if-tail-fork-parity: a block-body TAIL that is an `if` (IfStmt) is a
		// STATEMENT — its DIRECT parent is a block brace, for which fork's
		// `isExpression` is unconditionally false → the body uses `sameLine.ifBody`,
		// never `expressionIf`. So the inherited expression frame is DROPPED for a
		// block tail `if` (lambda callback `if (cb != null) cb();` stays inline
		// under `ifBody:fitLine`), regardless of the block's own expression context.
		// Non-`if` tails (a tail switch whose cases flatten via the arrow / return
		// walk-up, `for` / `while` bodies the fork breaks) keep the inherited frame.
		final elemCallOptArg: Expr = if (clearExprPositionNonTail) {
			final blockTailBarrier: Expr = WriterLowering.astPredCallT('tailStmtReadsExprPosition', [macro _t.node]);
			// omega-stmt-list-callarg-barrier: every element, tail included.
			final stmtOptExpr: Expr = WriterOptFanout.statementListElemOpt(elemOptExpr);
			macro (
				_si == _arr.length - 1 ? (
					$blockTailBarrier && (
						opt.expressionIfBody == anyparse.format.BodyPolicy.Next
						|| opt.expressionIfBody == anyparse.format.BodyPolicy.FitLine
					)
						? _clearArrowLambdaBody(_clearValueIfBranch(_clearExprPosition($stmtOptExpr)))
						: _clearArrowLambdaBody(_clearValueIfBranch($stmtOptExpr))
				) : _clearArrowLambdaBody(_clearValueIfBranch(_clearExprPosition($stmtOptExpr)))
			);
		} else {
			elemOptExpr;
		};
		return { expr: ECall(macro $i{elemFn}, [macro _t.node, elemCallOptArg]), pos: Context.currentPos() };
	}

	/**
	 * Block-Star empty-body Doc build (ω-empty-curly-break / ω-anonfunction-
	 * empty-curly / ω-blockempty). Resolves the empty-curly access (named knob
	 * vs `_inAnonFnBody`-dispatched default) and dispatches `Break` vs flat
	 * `{}`.
	 */
	private static function triviaBlockEmptyDocExpr(
		openText: String, closeText: String, emptyText: String, emptyCurlyBreak: Bool, emptyCurlyKnob: Null<String>,
		forceBreak: Bool = false
	): Expr {
		// omega-condswitchopen-for-close: a block Star whose open `{` lives OUTSIDE
		// this field (the outer block of a `#if for { switch { ... #end` region,
		// captured verbatim in `raw`) must still break its close onto its own line
		// when its body is empty - a glued `_dt('}')` would fuse the outer-block
		// close onto the switch-close line (`}}`). Unlike `emptyCurly` (which
		// governs a self-contained `{}` pair), this is unconditional.
		if (forceBreak) return macro _dc([_dt($v{openText}), _dhl(), _dt($v{closeText})]);
		final emptyCurlyAccess: Expr = emptyCurlyKnob != null
			? { expr: EField(macro opt, emptyCurlyKnob), pos: Context.currentPos() }
			: macro (opt._inAnonFnBody ? opt.anonFunctionEmptyCurly : opt.emptyCurly);
		return emptyCurlyBreak
			? macro (
				$emptyCurlyAccess == anyparse.format.EmptyCurly.Break
					? _dc([_dt($v{openText}), _dhl(), _dt($v{closeText})])
					: _dt($v{emptyText})
			)
			: macro _dt($v{emptyText});
	}

	/**
	 * Block-Star before-`}` hardline build (ω-blockright-curly / ω-anonfunction-
	 * right-curly). Reads the optional `rightCurly` / `rightCurlyAnonFn` knobs
	 * and drops the hardline before `}` when the resolved placement is `Inline`.
	 * Both knobs null → unconditional `_dhl()`.
	 */
	private static function triviaBlockBeforeCloseHardlineExpr(rightCurlyKnob: Null<String>, rightCurlyAnonFnKnob: Null<String>): Expr {
		final rightCurlyAccess: Null<Expr> = rightCurlyKnob != null
			? { expr: EField(macro opt, rightCurlyKnob), pos: Context.currentPos() }
			: null;
		final rightCurlyAnonFnAccess: Null<Expr> = rightCurlyKnob == null && rightCurlyAnonFnKnob != null
			? { expr: EField(macro opt, rightCurlyAnonFnKnob), pos: Context.currentPos() }
			: null;
		return if (rightCurlyAccess != null)
			macro ($rightCurlyAccess == anyparse.format.RightCurlyPlacement.Inline ? _de() : _dhl());
		else if (rightCurlyAnonFnAccess != null)
			macro (opt._inAnonFnBody && $rightCurlyAnonFnAccess == anyparse.format.RightCurlyPlacement.Inline ? _de() : _dhl());
		else
			macro _dhl();
	}

	/**
	 * Block-Star begin/end head-tail blank-line inserts (ω-class-begin-end-type /
	 * ω-bropen-keep). Builds the `beginTypeExpr` / `endTypeExpr` pair: explicit
	 * `beginType` / `endType` counts (type bodies) else the `afterLeftCurly` /
	 * `beforeRightCurly` Keep-policy source-blank honour.
	 */
	private static function triviaBlockBeginEndExpr(
		beginEndType: Bool, keepCurlyBlanks: Bool, beginAccess: Expr, endAccess: Expr
	): { final beginTypeExpr: Expr; final endTypeExpr: Expr; } {
		final emitBeginExtras: Bool = beginEndType || keepCurlyBlanks;
		final beginNExpr: Expr = triviaBlockBeginNExpr(beginEndType, beginAccess);
		final endNExpr: Expr = triviaBlockEndNExpr(beginEndType, endAccess);
		final beginTypeExpr: Expr = emitBeginExtras
			? macro {
				final _firstSourceBlank: Bool = _arr.length > 0 && _arr[0].blankBefore;
				final _beginN: Int = $beginNExpr;
				var _bi: Int = 0;
				while (_bi < _beginN) {
					_inner.push(_dhl());
					_bi++;
				}
			}
			: macro {};
		final endTypeExpr: Expr = emitBeginExtras
			? macro {
				final _endN: Int = $endNExpr;
				var _ei: Int = 0;
				while (_ei < _endN) {
					_inner.push(_dhl());
					_ei++;
				}
			}
			: macro {};
		return { beginTypeExpr: beginTypeExpr, endTypeExpr: endTypeExpr };
	}

	/**
	 * Block-Star leading-comment between-blank inserts. Builds the
	 * `leadingSplitGateExpr` (ω-block-final-doc-leading-blank — single blank
	 * between the last `//` and a trailing `/**` in a member's leading cluster)
	 * and the `blockLeadingBetweenExpr` / `blockTrailBetweenExpr`
	 * (ω-fileheader-multiline-comments — blank between adjacent block comments).
	 *
	 */
	private static function triviaBlockBetweenExprs(
		blankBeforeFinalDocInLeading: Bool, betweenMultilineCommentsBlanks: Bool
	): { final leadingSplitGateExpr: Expr; final blockLeadingBetweenExpr: Expr; final blockTrailBetweenExpr: Expr; } {
		final leadingSplitGateExpr: Expr = blankBeforeFinalDocInLeading
			? macro {
				if (
					_ci > 0
					&& StringTools.startsWith(_t.leadingComments[_ci], '/**')
					&& StringTools.startsWith(_t.leadingComments[_ci - 1], '//')
				) {
					var _isLastDoc: Bool = true;
					var _ldi: Int = _ci + 1;
					while (_ldi < _t.leadingComments.length) {
						if (StringTools.startsWith(_t.leadingComments[_ldi], '/**')) {
							_isLastDoc = false;
							break;
						}
						_ldi++;
					}
					if (_isLastDoc) _inner.push(_dhl());
				}
			}
			: macro {};
		final blockLeadingBetweenExpr: Expr = betweenMultilineCommentsBlanks
			? macro {
				if (
					_ci + 1 < _t.leadingComments.length
					&& StringTools.startsWith(_t.leadingComments[_ci], '/*')
					&& StringTools.startsWith(_t.leadingComments[_ci + 1], '/*')
				) {
					var _bbi: Int = 0;
					while (_bbi < opt.betweenMultilineComments) {
						_inner.push(_dhl());
						_bbi++;
					}
				}
			}
			: macro {};
		final blockTrailBetweenExpr: Expr = betweenMultilineCommentsBlanks
			? macro {
				if (
					_ti + 1 < _trailLC.length
					&& StringTools.startsWith(_trailLC[_ti], '/*')
					&& StringTools.startsWith(_trailLC[_ti + 1], '/*')
				) {
					var _bbi: Int = 0;
					while (_bbi < opt.betweenMultilineComments) {
						_inner.push(_dhl());
						_bbi++;
					}
				}
			}
			: macro {};
		return {
			leadingSplitGateExpr: leadingSplitGateExpr,
			blockLeadingBetweenExpr: blockLeadingBetweenExpr,
			blockTrailBetweenExpr: blockTrailBetweenExpr
		};
	}

	/**
	 * Block-Star blockEnded schema-instance predicate-call build (ω-condcomp-stray-
	 * semi, Stage A). Builds the `<schema>.instance.<predicate>(elemAccess)` call
	 * Expr for a given element-access Expr, or `macro false` when no predicate is
	 * wired.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaBlockPredCallExpr(
		blockEndedPredicate: Null<String>, blockEndedSchemaPath: Null<String>, elemAccess: Expr
	): Expr {
		if (blockEndedPredicate == null || blockEndedSchemaPath == null) return macro false;
		// astPreds formats route to the generated trivia-family predicate
		// (callers pass the `.node`-unwrapped element); the legacy
		// schema-instance channel remains for pilot formats.
		if (WriterLowering._astPredsOnStatic) return WriterLowering.astPredCallT(blockEndedPredicate, [elemAccess]);
		final fmtParts: Array<String> = blockEndedSchemaPath.split('.');
		return {
			expr: ECall({ expr: EField(macro $p{fmtParts}.instance, blockEndedPredicate), pos: Context.currentPos() }, [elemAccess]),
			pos: Context.currentPos()
		};
	}

	/**
	 * Block-Star blockEnded between-element / trailing sep emission (ω-blockended-
	 * trivia, Session 3 + ω-phase-g + ω-condcomp-stray-semi). Builds the
	 * `blockSepBeforeHardlineExpr` (inter-element sep when the prior element isn't
	 * already statement-terminated) and the `blockTrailSepEmitExpr` (source-trail
	 * sep after the last element). Null sepText / non-blockEnded → no-op.
	 * `trailSepKeepPredicate` exempts a last element from the predicate drop: a `#if`
	 * region whose last branch ends unterminated needs the `;` after its `#end`.
	 * `elemSepGlueExpr` writes an element's sep BEFORE its trailing comment (`#end; // c`)
	 * and sets `_sepGlued`, which the two sep emissions then honour; after the comment the
	 * sep would be commented out.
	 */
	private static function triviaBlockSepExprs(
		sepText: Null<String>, blockEnded: Bool, blockEndedPredicate: Null<String>, blockEndedSchemaPath: Null<String>
	): { final blockSepBeforeHardlineExpr: Expr; final blockTrailSepEmitExpr: Expr; final elemSepGlueExpr: Expr; } {
		if (sepText == null || !blockEnded)
			return { blockSepBeforeHardlineExpr: macro {}, blockTrailSepEmitExpr: macro {}, elemSepGlueExpr: macro _elem };
		inline function pred(i: Expr): Expr return triviaBlockPredCallExpr(blockEndedPredicate, blockEndedSchemaPath, macro _arr[$i].node);
		inline function betweenSep(i: Expr, doc: Expr): Expr {
			final p: Expr = pred(i);
			return macro (_arr[$i].sepAfter || (!anyparse.core.DocMeasure.endsWithStmtTerminator($doc) && !($p)));
		}
		// A source `;` after the LAST element is written back whatever the element: after a
		// block-terminated statement it is redundant, but removing a source token is a lint's job.
		inline function trailSep(i: Expr, doc: Expr): Expr return macro (_arr[$i].sepAfter && !anyparse.core.DocMeasure.endsWithSemi($doc));
		final priorSep: Expr = betweenSep(macro _si - 1, macro _priorElemDoc);
		final lastSep: Expr = trailSep(macro _arr.length - 1, macro _priorElemDoc);
		final ownBetween: Expr = betweenSep(macro _si, macro _elem);
		final ownTrail: Expr = trailSep(macro _si, macro _elem);
		// ω-phase-g (Session 4): source-fidelity OR `_arr[_si - 1].sepAfter`. Trust
		// the parser: if it consumed a sep after the prior element, preserve it even
		// when the prior already ends with `}`. The `endsWithStmtTerminator` arm is
		// the safety net for raw/programmatic AST inputs. ω-condcomp-stray-semi: the
		// `!priorPredCall` guard suppresses the spurious `;` between `#end` and the
		// next stmt (a `#if … #end` ends with `d`, byte check misses).
		final blockSepBeforeHardlineExpr: Expr = macro {
			if (_si > 0 && _priorElemDoc != null && !_sepGlued && $priorSep) _inner.push(_dt($v{sepText}));
		};
		// ω-blockended-trivia-trail-sep (Session 3): after the last element, emit
		// `;` iff the LAST element's `sepAfter` is true and it doesn't already end
		// with `;` (inner `@:trail(';')` baked it in).
		final blockTrailSepEmitExpr: Expr = macro {
			if (_arr.length > 0 && _priorElemDoc != null && !_sepGlued && $lastSep) _inner.push(_dt($v{sepText}));
		};
		final elemSepGlueExpr: Expr = macro {
			_sepGlued = _t.trailingComment != null && (_si < _arr.length - 1 ? $ownBetween : $ownTrail);
			_sepGlued ? _dc([_elem, _dt($v{sepText})]) : _elem;
		};
		return {
			blockSepBeforeHardlineExpr: blockSepBeforeHardlineExpr,
			blockTrailSepEmitExpr: blockTrailSepEmitExpr,
			elemSepGlueExpr: elemSepGlueExpr
		};
	}

	/**
	 * Block-Star per-flag init / track / wrap leaf Exprs. Bundles the empty-lines
	 * accumulator var inits (`_prevHadDocComment` / `_currHasDocComment` /
	 * `_currHasSplitLeading` / `_prevKind` / `_currKind`), the prior-kind track,
	 * the `trackDocCommentExpr` after-element doc scan, the `innerWrapExpr`
	 * (ω-indent-case-labels), and the `extraInnerTrailBlankExpr` (ω-block-orphan-
	 * trail-blank).
	 */
	private static function triviaBlockLeafExprs(
		afterFieldsWithDocComments: Null<Expr>, beforeDocCommentEmptyLines: Bool, interMember: Bool, indentCaseLabelsGate: Bool,
		?lineCommentTrailBlank: Expr
	): WriterLowering.BlockLeafExprs {
		final trackDocCommentExpr: Expr = afterFieldsWithDocComments != null
			? macro _prevHadDocComment = anyparse.format.MemberGap.docLed(_t.leadingComments)
			: macro {};
		// ω-indent-case-labels: when the call site opts in via
		// `@:fmt(indentCaseLabels)`, the body wrap is gated on `opt.indentCaseLabels`
		// — `false` flushes case labels with the surrounding `switch` keyword.
		final innerWrapExpr: Expr = indentCaseLabelsGate
			? macro (opt.indentCaseLabels ? _dn(_cols, _dc(_inner)) : _dc(_inner))
			: macro _dn(_cols, _dc(_inner));
		// ω-block-orphan-trail-blank: opt-in via
		// `@:fmt(blankBeforeOrphanLineCommentTrail)`. When the orphan trail is led by
		// a line-comment `//`, force the extra `_dhl()` blank regardless of source;
		// `lineCommentTrailBlank` is the runtime answer, absent for a Star without the flag.
		final forcedTrailBlank: Expr = lineCommentTrailBlank ?? macro false;
		final extraInnerTrailBlankExpr: Expr = macro (
			_arr.length > 0 && (_trailBB || ($forcedTrailBlank && _trailLC.length > 0 && StringTools.startsWith(_trailLC[0], '//')))
		);
		return {
			initDocCommentExpr: afterFieldsWithDocComments != null ? macro var _prevHadDocComment: Bool = false : macro {},
			initCurrDocCommentExpr: beforeDocCommentEmptyLines ? macro var _currHasDocComment: Bool = false : macro {},

			initPrevKindExpr: interMember ? macro var _prevKind: Int = 0 : macro {},
			initCurrKindExpr: interMember ? macro var _currKind: Int = 0 : macro {},
			trackPrevKindExpr: interMember ? macro _prevKind = _currKind : macro {},
			trackDocCommentExpr: trackDocCommentExpr,
			innerWrapExpr: innerWrapExpr,
			extraInnerTrailBlankExpr: extraInnerTrailBlankExpr
		};
	}

	/**
	 * Block-Star per-element push: the element Doc with its same-line trailing comment folded into the body
	 * measurement (`foldTrailingIntoBodyGroup`), or the bare element when it has none.
	 *
	 * FU12 `@:fmt(relocateTrailingComments)`: under `opt.trailingCommentAbove` the folded Doc becomes the
	 * FLAT side of the `trailingCommentAboveOr` choice whose break side is the comment on its own line above the
	 * element — the comment rendered by `leadingCommentDocRun` over a one-entry run, exactly what the second
	 * pass renders once the comment reads back as the element's only leading comment. The choice is built only
	 * where that second pass is provably the same layout (positive list):
	 *
	 *  - the comment is a `//` line comment and not a directive (`CommentDirective.relocatableTrailing`);
	 *  - the element has NO leading comment, so the moved one reads back as the whole leading list and no rule
	 *    reading that list (doc-led blanks, the `//` before `/**` split blank, the line-comment run adapter,
	 *    the blank after leading comments) answers differently.
	 *
	 * The `uniformStmtBlanks` collapse needs no gate of its own, although its pre-pass refuses a list in which a
	 * later element carries a leading comment: a collapsing list has a blank before EVERY later element, the
	 * collapse deletes them all, and a list with no blanks left does not collapse on the second pass either — it
	 * keeps its (absent) source blanks, the same layout. A list that does not collapse cannot start to once a
	 * comment is added. Gating the move on the collapse made the SECOND pass move the comment instead.
	 */
	private static function triviaBlockElemPushExpr(relocateTrailingComments: Bool): Expr {
		final besideExpr: Expr = macro foldTrailingIntoBodyGroup(_elemSep, trailingCommentDocVerbatim(_tc, opt));
		return if (relocateTrailingComments)
			macro {
				if (_tc == null)
					_inner.push(_elem);
				else
					_inner.push(
						trailingCommentAboveOr(opt.trailingCommentAbove && _t.leadingComments.length == 0, _tc, _elemSep, $besideExpr, opt)
					);
			}
		else
			macro _inner.push(_tc != null ? $besideExpr : _elem);
	}

	/**
	 * Block-Star head blank-line count (ω-class-begin-end-type / ω-bropen-keep): `MemberGap.bodyEdge` over the type
	 * body's stated `beginAccess` count, or — a Star without `beginEndType` — over none, which leaves the
	 * `afterLeftCurly` Keep-policy source-blank honour.
	 */
	private static function triviaBlockBeginNExpr(beginEndType: Bool, beginAccess: Expr): Expr {
		final stated: Expr = beginEndType ? beginAccess : macro null;
		return macro anyparse.format.MemberGap.bodyEdge($stated, opt.afterLeftCurly, _firstSourceBlank);
	}

	/**
	 * Block-Star tail blank-line count (ω-class-begin-end-type / ω-bropen-keep): the `}`-side twin of
	 * `triviaBlockBeginNExpr`, under `beforeRightCurly`. The edge sits after the orphan comments when the body ends in
	 * some, so the source blank in front of those comments, which their own run keeps, is not this edge's.
	 */
	private static function triviaBlockEndNExpr(beginEndType: Bool, endAccess: Expr): Expr {
		final stated: Expr = beginEndType ? endAccess : macro null;
		return macro anyparse.format.MemberGap.bodyEdge($stated, opt.beforeRightCurly, _trailBB && _arr.length > 0 && _trailLC.length == 0);
	}

}

/**
 * The strip / add gate Exprs + per-element compute Exprs bundled for the
 * `triviaBlockBlankBeforeAssemblyExpr` final-assembly helper. Replaces a
 * >5-param helper signature with one struct.
 */
typedef BlankGateExprs = {
	final currHasDocComputeExpr: Expr;
	final currKindComputeExpr: Expr;
	final stripByDocExpr: Expr;
	final stripByExistingExpr: Expr;
	final vetoByDocExpr: Expr;
	final addByDocExpr: Expr;
	final addByInterMemberExpr: Expr;
	final addByUniformBetweenExpr: Expr;
};
#end
