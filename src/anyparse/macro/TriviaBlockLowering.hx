package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

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
 * add gates over doc comments, existing blanks, split-leading clusters, the
 * interMember var/fn cascade and the uniform-between knob, plus the
 * per-element `_currHasDocComment` / `_currKind` / `_currHasSplitLeading`
 * computes feeding them).
 *
 * Split out of `WriterLowering` for size — the two are NOT independent. The
 * macro-time surface is small: one inbound entry (`triviaBlockStarExpr`,
 * called from `WriterLowering.emitTriviaBlockStarDispatch` and
 * `WriterLowering.triviaBlockStarBuild`) and a short outbound list back
 * into the shared lowering utilities (`astPredCallT`,
 * `blankBefore2ExtrasExpr`, `blankAroundMultilineExprs`,
 * `caseSiblingWidthProbeExpr`, `triviaBalcEmitExpr`,
 * `triviaUniformCollapseInitExpr`, plus the `_astPredsOnStatic` gate
 * mirror). Both directions run through `@:access` and every member here
 * stays private.
 *
 * Parameters typed by a `WriterLowering` sub-module typedef stay qualified:
 * the extraction moved the functions, not the typedefs, so the whole
 * sub-module typedef block still lives in `WriterLowering`'s module. The
 * classify / subdivision infos are also read by the struct-lowering members
 * that stayed behind; `BlockStarCtx` and `BlockLeafExprs` are now read only
 * from here.
 *
 * The GENERATED-code surface is the real contract, and no type carries it:
 * every helper splices identifiers declared elsewhere in the Star body —
 * `_arr` / `_t` / `_si` / `_inner` / `opt` / `_dhl()` from the Star
 * scaffold, `_prevHadDocComment` / `_currHasDocComment` /
 * `_currHasSplitLeading` / `_prevKind` / `_currKind` from
 * `triviaBlockLeafExprs`, `_uniformCollapse` from the declaration
 * `triviaBlockElseBody` splices. Those declare sites are gated on the SAME
 * `@:fmt` flags as the computes that read them
 * (`beforeDocCommentEmptyLines`, `existingBetweenFields`, `interMember`,
 * `uniformStmtBlanks`): move a gate on one side only and the generated
 * writer either reads an undeclared local or declares a dead one, with
 * nothing in this module's types to catch it.
 */
final class TriviaBlockLowering {

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
			final classifierAccess: Expr = {
				expr: EField(macro _t.node, condLeadingDocInfo.classifierFieldName),
				pos: pos,
			};
			final bodyAccess: Expr = {
				expr: EField(macro _inner, condLeadingDocInfo.bodyFieldName),
				pos: pos,
			};
			final scanBody: Expr = macro {
				final _condBody = $bodyAccess;
				if (_condBody.length > 0) {
					var _ctdi: Int = 0;
					while (_ctdi < _condBody[0].leadingComments.length) {
						if (StringTools.startsWith(_condBody[0].leadingComments[_ctdi], '/**')) {
							_currHasDocComment = true;
							break;
						}
						_ctdi++;
					}
				}
			};
			final lookThroughSwitch: Expr = {
				expr: ESwitch(classifierAccess, [{ values: [condLeadingDocInfo.condCasePattern], guard: null, expr: scanBody }], macro {}),
				pos: pos,
			};
			macro if (!_currHasDocComment) $lookThroughSwitch;
		} : macro {};
		return beforeDocCommentEmptyLines
			? macro {
				_currHasDocComment = false;
				var _cdci: Int = 0;
				while (_cdci < _t.leadingComments.length) {
					if (StringTools.startsWith(_t.leadingComments[_cdci], '/**')) {
						_currHasDocComment = true;
						break;
					}
					_cdci++;
				}
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
			final modAccess: Expr = {
				expr: EField(macro _t.node, staticVarSubdivInfo.modifierFieldName),
				pos: pos,
			};
			final staticIdent: Expr = { expr: EConst(CIdent(staticVarSubdivInfo.staticCtorName)), pos: pos };
			macro {
				if (_currKind == 1 || _currKind == 2) for (_m in $modAccess) if (_m.node.match($staticIdent)) {
					_currKind = _currKind == 1 ? 3 : 4; // noqa: magic-number
					break;
				}
			};
		} : macro {};
		return interMember ? {
			final classifierAccess: Expr = {
				expr: EField(macro _t.node, interMemberInfo.classifierFieldName),
				pos: Context.currentPos(),
			};
			final switchExpr: Expr = {
				expr: ESwitch(classifierAccess, interMemberInfo.classifyCases, null),
				pos: Context.currentPos(),
			};
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
	 * static-var/static-fn cascade, AND-ed out under extern context.
	 */
	private static function triviaBlockInterMemberAddExpr(
		interMember: Bool, interMemberInfo: Null<WriterLowering.InterMemberClassifyInfo>, staticVarSubdiv: Bool,
		staticVarSubdivInfo: Null<WriterLowering.StaticVarSubdivisionInfo>
	): Expr {
		if (!interMember) return macro false;
		final pos: Position = Context.currentPos();
		final betweenVarsAccess: Expr = {
			expr: EField(macro opt, interMemberInfo.betweenVarsField),
			pos: pos,
		};
		final betweenFnAccess: Expr = {
			expr: EField(macro opt, interMemberInfo.betweenFunctionsField),
			pos: pos,
		};
		final afterVarsAccess: Expr = {
			expr: EField(macro opt, interMemberInfo.afterVarsField),
			pos: pos,
		};
		// ω-extern-class-no-blanks: `_classExtern` is propagated from
		// `HxTopLevelDecl.decl` via `@:fmt(setBoolFlagFromStarCtor(...))` when the
		// sibling `modifiers` Star contains `Extern`. AND-out the entire interMember
		// add-rule when the flag is set so an `extern class { var; var; function;
		// function; }` round-trips with zero blanks regardless of `betweenVars` /
		// `betweenFunctions` / `afterVars` defaults — mirrors fork's
		// `externClassEmptyLines` config-section override.
		//
		// ω-class-static-var-cascade / ω-abstract-static-fn-cascade: when
		// subdivision is active, kinds `3` / `4` represent static-var / static-fn;
		// the var/fn cascade arms split accordingly (see the subdiv arm helpers).
		// When subdivision is off, kinds `3` / `4` are unreachable and the cascade
		// collapses to the pre-slice three arms.
		if (!staticVarSubdiv) return triviaBlockInterMemberPlainExpr(betweenVarsAccess, betweenFnAccess, afterVarsAccess);
		final afterStaticVarsAccess: Expr = {
			expr: EField(macro opt, staticVarSubdivInfo.afterStaticVarsField),
			pos: pos,
		};
		final betweenStaticFnAccess: Expr = {
			expr: EField(macro opt, staticVarSubdivInfo.betweenStaticFunctionsField),
			pos: pos,
		};
		return triviaBlockInterMemberSubdivExpr(
			betweenVarsAccess, betweenFnAccess, afterVarsAccess, afterStaticVarsAccess, betweenStaticFnAccess
		);
	}

	/**
	 * Block-Star inter-element blank-line build (ω-C-empty-lines-* family). Builds
	 * the `blankBeforeExpr` consumed in the per-element loop: the strip / add
	 * doc-comment + existing-between + split-leading + interMember + uniform-
	 * between gates, the `_currHasDocComment` / `_currKind` / `_currHasSplitLeading`
	 * computes (via the cascade sub-helpers), and the final `_stripBlank` /
	 * `_addBlank` / `_sourceBlank` decision.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaBlockBlankBeforeExpr(
		afterFieldsWithDocComments: Bool, existingBetweenFields: Bool, beforeDocCommentEmptyLines: Bool,
		condLeadingDocInfo: Null<WriterLowering.CondLeadingDocLookThroughInfo>, interMember: Bool,
		interMemberInfo: Null<WriterLowering.InterMemberClassifyInfo>, staticVarSubdiv: Bool,
		staticVarSubdivInfo: Null<WriterLowering.StaticVarSubdivisionInfo>, uniformBetween: Bool, uniformBetweenOptField: Null<String>,
		anyEmptyLinesFlag: Bool, uniformStmtBlanks: Bool
	): Expr {
		final blankExtras: Expr = WriterLowering.blankBefore2ExtrasExpr(macro _inner.push(_dhl()));
		if (!anyEmptyLinesFlag) return triviaBlockSourceBlankOnlyExpr(uniformStmtBlanks, blankExtras);
		final stripByDocExpr: Expr = afterFieldsWithDocComments
			? macro (_prevHadDocComment && opt.afterFieldsWithDocComments == anyparse.format.CommentEmptyLinesPolicy.None)
			: macro false;
		final addByDocExpr: Expr = afterFieldsWithDocComments
			? macro (_prevHadDocComment && opt.afterFieldsWithDocComments == anyparse.format.CommentEmptyLinesPolicy.One)
			: macro false;
		final stripByExistingExpr: Expr = existingBetweenFields
			? macro (opt.existingBetweenFields == anyparse.format.KeepEmptyLinesPolicy.Remove)
			: macro false;
		// ω-extern-existing-between-split-leading: when the current member's
		// `leadingComments` carries the "split" shape (a trailing `/**` doc-comment
		// preceded by `//` line-comments), fork's `existingBetweenFields=Remove`
		// strips the inter-member source blank under the extern-scoped policy.
		final stripBySplitLeadingExpr: Expr = existingBetweenFields
			? macro (
				opt._classExtern && _currHasSplitLeading && opt.externExistingBetweenFields == anyparse.format.KeepEmptyLinesPolicy.Remove
			)
			: macro false;
		// Companion suppress: in extern context fork never re-adds a blank at the
		// inter-member slot when the next member's leading carries the split shape.
		final addSuppressOnSplitLeadingExpr: Expr = existingBetweenFields ? macro (opt._classExtern && _currHasSplitLeading) : macro false;
		final stripByCurrDocExpr: Expr = beforeDocCommentEmptyLines
			? macro (_currHasDocComment && opt.beforeDocCommentEmptyLines == anyparse.format.CommentEmptyLinesPolicy.None)
			: macro false;
		final addByCurrDocExpr: Expr = beforeDocCommentEmptyLines
			? macro (_currHasDocComment && opt.beforeDocCommentEmptyLines == anyparse.format.CommentEmptyLinesPolicy.One)
			: macro false;
		final currHasDocComputeExpr: Expr = triviaBlockCurrHasDocComputeExpr(beforeDocCommentEmptyLines, condLeadingDocInfo);
		final currHasSplitLeadingComputeExpr: Expr = triviaBlockCurrHasSplitLeadingComputeExpr(existingBetweenFields);
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
			currHasSplitLeadingComputeExpr: currHasSplitLeadingComputeExpr,
			stripByDocExpr: stripByDocExpr,
			stripByExistingExpr: stripByExistingExpr,
			stripByCurrDocExpr: stripByCurrDocExpr,
			stripBySplitLeadingExpr: stripBySplitLeadingExpr,
			addSuppressOnSplitLeadingExpr: addSuppressOnSplitLeadingExpr,
			addByDocExpr: addByDocExpr,
			addByCurrDocExpr: addByCurrDocExpr,
			addByInterMemberExpr: addByInterMemberExpr,
			addByUniformBetweenExpr: addByUniformBetweenExpr,
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
				|| ((_prevKind == 2 || _prevKind == 4) && (_currKind == 1 || _currKind == 3))) && $afterVarsAccess > 0); // noqa
	}

	/**
	 * Block-Star interMember subdivision-active add rule (ω-class-static-var-
	 * cascade / ω-abstract-static-fn-cascade). Composes the var-family / fn-family
	 * / var↔fn arms, AND-ed out under extern context.
	 */
	private static function triviaBlockInterMemberSubdivExpr(
		betweenVarsAccess: Expr, betweenFnAccess: Expr, afterVarsAccess: Expr, afterStaticVarsAccess: Expr, betweenStaticFnAccess: Expr
	): Expr {
		final varArms: Expr = triviaBlockSubdivVarArmsExpr(betweenVarsAccess, afterStaticVarsAccess);
		final fnArms: Expr = triviaBlockSubdivFnArmsExpr(betweenFnAccess, betweenStaticFnAccess);
		final varFnArm: Expr = triviaBlockSubdivVarFnArmExpr(afterVarsAccess);
		return macro (!opt._classExtern && ($varArms || $fnArms || $varFnArm));
	}

	/**
	 * Block-Star interMember subdivision-off add rule (the pre-slice three arms):
	 * same-var `betweenVars`, same-fn `betweenFunctions`, var↔fn `afterVars`,
	 * AND-ed out under extern context.
	 */
	private static function triviaBlockInterMemberPlainExpr(betweenVarsAccess: Expr, betweenFnAccess: Expr, afterVarsAccess: Expr): Expr {
		return macro (!opt._classExtern
			&& ((_prevKind == 1 && _currKind == 1 && $betweenVarsAccess > 0) || (_prevKind == 2 && _currKind == 2 && $betweenFnAccess > 0)
				|| (_prevKind != 0 && _currKind != 0 && _prevKind != _currKind && $afterVarsAccess > 0)));
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
		final currHasSplitLeadingComputeExpr: Expr = g.currHasSplitLeadingComputeExpr;
		final stripByDocExpr: Expr = g.stripByDocExpr;
		final stripByExistingExpr: Expr = g.stripByExistingExpr;
		final stripByCurrDocExpr: Expr = g.stripByCurrDocExpr;
		final stripBySplitLeadingExpr: Expr = g.stripBySplitLeadingExpr;
		final addSuppressOnSplitLeadingExpr: Expr = g.addSuppressOnSplitLeadingExpr;
		final addByDocExpr: Expr = g.addByDocExpr;
		final addByCurrDocExpr: Expr = g.addByCurrDocExpr;
		final addByInterMemberExpr: Expr = g.addByInterMemberExpr;
		final addByUniformBetweenExpr: Expr = g.addByUniformBetweenExpr;
		final blankExtras: Expr = WriterLowering.blankBefore2ExtrasExpr(macro _inner.push(_dhl()));
		return macro {
			$currHasDocComputeExpr;
			$currKindComputeExpr;
			$currHasSplitLeadingComputeExpr;
			final _stripBlank: Bool = $stripByDocExpr || $stripByExistingExpr || $stripByCurrDocExpr || $stripBySplitLeadingExpr;
			// ω-beforedoc-none-precedence: fork's `markDocCommentEmptyLines` applies
			// `beforeDocCommentEmptyLines` to the before-doc slot AFTER
			// `afterFieldsWithDocComments` (the prior field's after-slot is the same
			// physical gap), so the before-policy is the last write and wins. When
			// the current element opens with a doc comment and the before-policy is
			// `None`, the slot is forced to zero blanks — `$stripByCurrDocExpr`
			// already zeroes `_sourceBlank`, so AND-out every add
			// (`afterFieldsWithDocComments.One`, the interMember / uniform adds) too.
			// Byte-inert when the Star carries no `beforeDocCommentEmptyLines` flag
			// (`$stripByCurrDocExpr` is the compile-time literal `false`) or the
			// runtime policy is not `None`.
			final _addBlank: Bool = !$stripByCurrDocExpr && !$addSuppressOnSplitLeadingExpr
				&& ($addByDocExpr || $addByCurrDocExpr || $addByInterMemberExpr || $addByUniformBetweenExpr);
			final _sourceBlank: Bool = _t.blankBefore && !_stripBlank;
			if (_si > 0 && (_sourceBlank || _addBlank)) {
				_inner.push(_dhl());
				if (_sourceBlank) $blankExtras;
			}
		};
	}

	/**
	 * Block-Star current-element split-leading scan (ω-extern-existing-between-
	 * split-leading). Per-element scan that flips `_currHasSplitLeading` true when
	 * the element's leading cluster ends in a `/**` doc comment whose immediate
	 * predecessor is a `//` line comment.
	 */
	private static function triviaBlockCurrHasSplitLeadingComputeExpr(existingBetweenFields: Bool): Expr {
		return existingBetweenFields
			? macro {
				_currHasSplitLeading = false;
				var _slLast: Int = -1;
				var _sli: Int = 0;
				while (_sli < _t.leadingComments.length) {
					if (StringTools.startsWith(_t.leadingComments[_sli], '/**')) _slLast = _sli;
					_sli++;
				}
				if (_slLast > 0 && StringTools.startsWith(_t.leadingComments[_slLast - 1], '//')) _currHasSplitLeading = true;
			}
			: macro {};
	}

	/**
	 * Block-Star uniform-between add-blank gate (ω-enum-empty-lines). Opt-in via
	 * `@:fmt(uniformBetween('<optField>'))` — the named non-negative-Int knob is
	 * consulted at the inter-element slot (`> 0` contributes a blank).
	 */
	private static function triviaBlockUniformBetweenAddExpr(uniformBetween: Bool, uniformBetweenOptField: Null<String>): Expr {
		if (!uniformBetween) return macro false;
		final optAccess: Expr = {
			expr: EField(macro opt, uniformBetweenOptField),
			pos: Context.currentPos(),
		};
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
	 * Build the Doc expression for a block-mode trivia Star field
	 * (`@:lead(open) @:trail(close) @:trivia`). Per-element layout:
	 * hardline baseline, optional extra hardline for `blankBefore`
	 * (skipped on the first element — the leading `{` already gives the
	 * break), leading comments each followed by a hardline, the element
	 * write call, optional trailing line comment. Wrapped in
	 * `_dc([_dt(open), _dn(cols, _dc(inner)), _dhl(), _dt(close)])` to
	 * match the Doc shape of the plain-mode `blockBody` helper.
	 *
	 * `elemFn` is the `*T`-variant write function (e.g. `writeHxMemberDeclT`)
	 * — the helper does not itself consult `isTriviaBearing`.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaBlockStarExpr(
		fieldAccess: Expr, trailBBAccess: Null<Expr>, trailLCAccess: Null<Expr>, trailCloseAccess: Null<Expr>, trailOpenAccess: Null<Expr>,
		elemFn: String, openText: String, closeText: String, appendHardlineAfterTrail: Bool = false,
		afterFieldsWithDocComments: Bool = false, existingBetweenFields: Bool = false, beforeDocCommentEmptyLines: Bool = false,
		?interMemberInfo: WriterLowering.InterMemberClassifyInfo, indentCaseLabelsGate: Bool = false, emptyCurlyBreak: Bool = false,
		beginEndType: Bool = false, keepCurlyBlanks: Bool = false, lineCommentTrailBlank: Bool = false,
		blankBeforeFinalDocInLeading: Bool = false, ?staticVarSubdivInfo: WriterLowering.StaticVarSubdivisionInfo,
		betweenMultilineCommentsBlanks: Bool = false, ?uniformBetweenOptField: String, clearAnonFnBodyOnElems: Bool = false,
		?emptyCurlyKnob: String, ?rightCurlyKnob: String, ?rightCurlyAnonFnKnob: String,
		// ω-blockended-trivia (Session 3): when the Star carries
		// `@:sep('text', tailRelax, blockEnded)`, the block-mode emit
		// gains between-element sep emission, gated on
		// `!DocMeasure.endsWithCloseBrace(priorElemDoc)`. Null sepText →
		// pre-slice byte-identical (no inter-stmt sep emit — per-stmt
		// `;` lives inside each element's own Doc via @:trailOpt).
		?sepText: String,
		blockEnded: Bool = false,
		// ω-condcomp-stray-semi (Stage A): the schema-instance predicate name
		// (`lit.sepBlockEndedPredicate`, e.g. `stmtNoSemi`) consulted on the
		// PRIOR / LAST element's AST when deciding between-element / trailing
		// sep elision. Mirror of the plain-mode block-Star path (L4400): a
		// `#if … #end` stmt ends with `d` so the `endsWithStmtTerminator` byte
		// check misses, but `stmtNoSemi` accepts the `Conditional` AST shape.
		// `blockEndedSchemaPath` is the dotted format-instance path (e.g.
		// `anyparse.grammar.haxe.HaxeFormat`) used to build the
		// `<schema>.instance.<predicate>(elem)` call. Both null → byte-
		// identical to the pre-fix path (no predicate consult).
		?blockEndedPredicate: String,
		?blockEndedSchemaPath: String,
		// ω-cond-leading-doc-lookthrough: when set (only alongside
		// `beforeDocCommentEmptyLines`), the `_currHasDocComment` scan looks
		// through a `#if … #end` member to its first inner member's leading
		// doc-comment. Null → byte-identical to the pre-fix path.
		?condLeadingDocInfo: WriterLowering.CondLeadingDocLookThroughInfo,
		// ω-value-yielded-if-tail-barrier (SI-2): when the parent Star carries
		// `@:fmt(clearExprPositionNonTail)` (BlockExpr / BlockStmt), every
		// NON-tail block statement's element-opt is wrapped in
		// `_clearExprPosition` so the expression-position frame inherited from
		// an enclosing arrow-body / return is dropped for statements whose value
		// is discarded. The block's LAST statement (its yielded value) keeps the
		// frame. False → byte-identical to the pre-slice element call.
		clearExprPositionNonTail: Bool = false,
		// ω-enum-begin-end: the opt field names read for the begin/end blank
		// counts. Default class-scoped `beginType` / `endType`; a Star whose
		// `@:fmt(beginEndType('a', 'b'))` names knobs (e.g. `HxEnumDecl.ctors`)
		// reads those instead, so per-type-kind begin/end scopes never share.
		beginTypeKnob: String = 'beginType',
		endTypeKnob: String = 'endType', uniformStmtBlanks: Bool = false,
		// omega-condswitchopen-for-close: force an empty body to break its close
		// onto its own line (the outer-block `}` of a `#if for { switch { #end`
		// region). See `triviaBlockEmptyDocExpr`.
		forceEmptyBreak: Bool = false,
		// ω-case-sibling-symmetry: `@:fmt(caseSiblingSymmetry('<stmtKnob>',
		// '<exprKnob>'))` on a case-list Star. The two names are the
		// statement-/expression-position body policies whose `FitLine` value
		// arms the coordination; null (every other block Star) ⇒ no pre-pass,
		// no element-opt copy, byte-identical emit.
		?caseSiblingSymmetryKnobs: Array<String>,
		// ω-if-leader-case-symmetry: the `caseSiblingUnits_<ElemRule>` fn-ref
		// that expands a `#if`-guarded case region into its inner case
		// elements for the widest-sibling pre-pass. Null alongside a null
		// `caseSiblingSymmetryKnobs` ⇒ no pre-pass at all; null WITH knobs is
		// a macro-time error (an opted-in Star needs the flattener).
		?caseSiblingUnitsFn: Expr,
		// ω-case-sibling-symmetry widened: the
		// `caseUnitStructuralBreak_<ElemRule>` fn-ref that answers whether ONE
		// expanded unit is below its label for structural reasons. Same
		// nullability contract as `caseSiblingUnitsFn` — null alongside null
		// knobs, a macro-time error with knobs.
		?caseSiblingStructuralFn: Expr,
		// omega-case-body-controlflow-glue: the
		// `caseUnitControlFlowBody_<ElemRule>` fn-ref that answers whether ONE
		// expanded unit holds a single control-flow body statement. Same
		// nullability contract as the two above — null alongside null knobs, a
		// macro-time error with knobs.
		?caseSiblingControlFlowFn: Expr,
		// ω-blank-around-multiline-members: the `WriteOptions` Int knob naming
		// the blank count, or null when the Star does not carry the flag — the
		// three splice points then lower to `macro {}` and the generated loop is
		// byte-identical to the pre-slice one.
		?blankAroundOptField: String
	): Expr {
		// ω-condcomp-stray-semi (Stage A): the schema-instance predicate-call build
		// moved to `triviaBlockPredCallExpr` (consumed by `triviaBlockSepExprs`).
		final caseSym: Bool = caseSiblingSymmetryKnobs != null && caseSiblingSymmetryKnobs.length == 2;
		final caseSiblingWidthExpr: Expr = WriterLowering.caseSiblingWidthProbeExpr(
			elemFn, caseSym ? caseSiblingSymmetryKnobs : null, caseSiblingUnitsFn, caseSiblingStructuralFn, caseSiblingControlFlowFn
		);
		final triviaElemCall: Expr = triviaBlockElemCallExpr(elemFn, clearAnonFnBodyOnElems, clearExprPositionNonTail, caseSym);
		final emptyText: String = openText + closeText;
		// ω-empty-curly-break / ω-anonfunction-empty-curly / ω-blockempty:
		// empty-body Doc dispatch moved to `triviaBlockEmptyDocExpr`.
		final emptyDocExpr: Expr = triviaBlockEmptyDocExpr(
			openText, closeText, emptyText, emptyCurlyBreak, emptyCurlyKnob, forceEmptyBreak
		);
		// ω-blockright-curly / ω-anonfunction-right-curly: before-`}` hardline
		// dispatch moved to `triviaBlockBeforeCloseHardlineExpr`.
		final beforeCloseHardlineExpr: Expr = triviaBlockBeforeCloseHardlineExpr(rightCurlyKnob, rightCurlyAnonFnKnob);
		// ω-orphan-trivia: Alt-branch Star call sites (BlockStmt) have no
		// synth trailing slots — the null branch drops trailing trivia,
		// matching pre-slice behaviour. Seq-struct call sites forward the
		// real accessors and round-trip orphan comments.
		final trailBB: Expr = trailBBAccess ?? macro false;
		final trailLC: Expr = trailLCAccess ?? macro ([]: Array<String>);
		// ω-close-trailing: same-line trailing comment captured right
		// after the close literal (e.g. `} // comment` before the next
		// sibling). Present only for close-peek Seq Stars (Seq-struct
		// + ω-close-trailing-alt's BlockStmt); EOF and try-parse sites
		// forward null and degrade to the pre-slice close emission.
		// ω-trailing-block-style: the captured string includes its
		// delimiters (producer uses `collectTrailingFull`), so the
		// emission routes through `trailingCommentDocVerbatim` to
		// preserve block-vs-line style on round-trip.
		final trailClose: Expr = trailCloseAccess ?? macro (null: Null<String>);
		// ω-open-trailing: same-line trailing comment captured right after
		// the open literal (e.g. `{ // foo` before the first member).
		// Synthesised only for Stars with `@:lead`; Alt-branch and EOF
		// sites forward null. Verbatim emission preserves block-vs-line
		// style.
		final trailOpen: Expr = trailOpenAccess ?? macro (null: Null<String>);
		// ω-close-trailing-alt: Alt-branch sites pass true so the trailing
		// line comment is followed by a hardline — line comments terminate
		// at \n semantically, and the Alt's parent struct may emit a space
		// sep next (e.g. HxTryCatchStmt.body→catches with sameLineCatch),
		// which would glue the next sibling onto the same line as the
		// comment. Seq-struct sites pass false: their close-trailing slot
		// always lives on the LAST field of its containing struct, where
		// the parent Star's element separator already supplies a hardline.
		//
		// ω-opthardlineskipbeforehardline (slice B opt-in): emit
		// `_dohsbh()` instead of `_dhl()`. Forward-looking opt-hardline
		// drops when the next non-OptSpace emit is itself a hardline —
		// closes the spurious-blank-line bug between two consecutive
		// `} // comment` / `<next stmt>` BlockStmt-Alt siblings where
		// the parent stmt-list Star's per-element sep emits a hardline.
		// In the sameLineCatch case the parent emits a content/space
		// follower, so `_dohsbh()` still fires (lands `\n+indent` for
		// the next-line catch placement). See target fixtures
		// `lineends/issue_445_curly_with_comment{,_both}`.
		final trailFollowExpr: Expr = appendHardlineAfterTrail ? macro _parts.push(_dohsbh()) : macro {};
		// Head -> body seam: without the explicit `_dhl()` the block-Star's
		// close-trailing comment is followed by whatever the parent struct
		// emits next, so a LINE comment needs the forward-looking guard.
		final emptyTrailExpr: Expr = appendHardlineAfterTrail
			? macro _dc([_dt($v{emptyText}), trailingCommentDocVerbatim(_trailClose, opt), _dhl()])
			: macro _dc([_dt($v{emptyText}), trailingCommentDocGuarded(_trailClose, opt)]);
		// ω-C-empty-lines-doc / ω-C-empty-lines-between-fields /
		// ω-C-empty-lines-before-doc: when the grammar field carries any
		// of the empty-line flags
		// (`@:fmt(afterFieldsWithDocComments)`,
		// `@:fmt(existingBetweenFields)`,
		// `@:fmt(beforeDocCommentEmptyLines)`), the per-element loop
		// gates its blank-line emission on the corresponding runtime
		// policies —
		// `afterFieldsWithDocComments.One` forces a blank line after any
		// element whose leading trivia carried a `/**`-prefixed entry,
		// `afterFieldsWithDocComments.None` strips source blanks adjacent
		// to such an element, `existingBetweenFields.Remove` strips every
		// source blank between siblings regardless of doc-comment status,
		// `beforeDocCommentEmptyLines.One` forces a blank line before any
		// element whose own leading trivia starts with a `/**`-prefixed
		// entry, `beforeDocCommentEmptyLines.None` strips source blanks
		// adjacent to such an element's leading side. The policies
		// compose: a blank line survives only when no active strip-policy
		// fires AND (the source had one OR any add-policy fires). The
		// compile-time gate keeps JSON / AS3 writers byte-identical —
		// their Star fields carry none of the flags and skip the policy
		// computation entirely.
		final interMember: Bool = interMemberInfo != null;
		final uniformBetween: Bool = uniformBetweenOptField != null;
		final anyEmptyLinesFlag: Bool = afterFieldsWithDocComments || existingBetweenFields || beforeDocCommentEmptyLines || interMember
			|| uniformBetween;
		// ω-extern-existing-between-split-leading / ω-cond-leading-doc-lookthrough /
		// ω-class-static-var-cascade / ω-abstract-static-fn-cascade: the per-element
		// doc-comment / kind / split-leading computes + the strip / add gates moved
		// to `triviaBlockBlankBeforeExpr` and its cascade
		// sub-helpers.
		final staticVarSubdiv: Bool = staticVarSubdivInfo != null;
		// ω-enum-empty-lines: opt-in via `@:fmt(uniformBetween('<optField>'))`.
		// When present, the named non-negative-Int knob on the runtime
		// `opt` is consulted at the inter-element slot — `> 0` contributes
		// to `_addBlank` (single-blank semantics, same shape as the other
		// add arms). Generic mech: any Star whose elements are an Alt
		// without a var/fn split (e.g. `HxEnumDecl.ctors` →
		// `opt.betweenEnumCtors`) can opt in by pointing at its own knob.
		final blankBeforeExpr: Expr = triviaBlockBlankBeforeExpr(
			afterFieldsWithDocComments, existingBetweenFields, beforeDocCommentEmptyLines, condLeadingDocInfo, interMember,
			interMemberInfo, staticVarSubdiv, staticVarSubdivInfo, uniformBetween, uniformBetweenOptField, anyEmptyLinesFlag,
			uniformStmtBlanks
		);
		// Remaining per-flag leaf builders moved to grouped helpers:
		// ω-indent-case-labels / ω-block-orphan-trail-blank + init/track exprs ->
		// triviaBlockLeafExprs; ω-class-begin-end-type / ω-bropen-keep ->
		// triviaBlockBeginEndExpr; ω-block-final-doc-leading-blank /
		// ω-fileheader-multiline-comments -> triviaBlockBetweenExprs; ω-blockended-
		// trivia / ω-phase-g / ω-condcomp-stray-semi -> triviaBlockSepExprs (predicate
		// build in triviaBlockPredCallExpr). The orchestrator now bundles every
		// spliced Expr into a BlockStarCtx and delegates to triviaBlockMainExpr.
		final beginEnd = triviaBlockBeginEndExpr(beginEndType, keepCurlyBlanks, beginTypeKnob, endTypeKnob);
		final between = triviaBlockBetweenExprs(blankBeforeFinalDocInLeading, betweenMultilineCommentsBlanks);
		final sep = triviaBlockSepExprs(sepText, blockEnded, blockEndedPredicate, blockEndedSchemaPath);
		final leaf = triviaBlockLeafExprs(
			afterFieldsWithDocComments, beforeDocCommentEmptyLines, existingBetweenFields, interMember, indentCaseLabelsGate,
			lineCommentTrailBlank
		);
		final blankAround = WriterLowering.blankAroundMultilineExprs(blankAroundOptField);
		final ctx: WriterLowering.BlockStarCtx = {
			fieldAccess: fieldAccess,
			openText: openText,
			closeText: closeText,
			emptyText: emptyText,
			triviaElemCall: triviaElemCall,
			emptyDocExpr: emptyDocExpr,
			beforeCloseHardlineExpr: beforeCloseHardlineExpr,
			trailBB: trailBB,
			trailLC: trailLC,
			trailClose: trailClose,
			trailOpen: trailOpen,
			trailFollowExpr: trailFollowExpr,
			emptyTrailExpr: emptyTrailExpr,
			blankBeforeExpr: blankBeforeExpr,
			trackDocCommentExpr: leaf.trackDocCommentExpr,
			initDocCommentExpr: leaf.initDocCommentExpr,
			initCurrDocCommentExpr: leaf.initCurrDocCommentExpr,
			initCurrSplitLeadingExpr: leaf.initCurrSplitLeadingExpr,
			initPrevKindExpr: leaf.initPrevKindExpr,
			initCurrKindExpr: leaf.initCurrKindExpr,
			trackPrevKindExpr: leaf.trackPrevKindExpr,
			innerWrapExpr: leaf.innerWrapExpr,
			beginTypeExpr: beginEnd.beginTypeExpr,
			endTypeExpr: beginEnd.endTypeExpr,
			leadingSplitGateExpr: between.leadingSplitGateExpr,
			extraInnerTrailBlankExpr: leaf.extraInnerTrailBlankExpr,
			blockLeadingBetweenExpr: between.blockLeadingBetweenExpr,
			blockTrailBetweenExpr: between.blockTrailBetweenExpr,
			blockSepBeforeHardlineExpr: sep.blockSepBeforeHardlineExpr,
			blockTrailSepEmitExpr: sep.blockTrailSepEmitExpr,
			afterFieldsWithDocComments: afterFieldsWithDocComments,
			existingBetweenFields: existingBetweenFields,
			beforeDocCommentEmptyLines: beforeDocCommentEmptyLines,
			condLeadingDocInfo: condLeadingDocInfo,
			interMember: interMember,
			interMemberInfo: interMemberInfo,
			staticVarSubdiv: staticVarSubdiv,
			staticVarSubdivInfo: staticVarSubdivInfo,
			uniformBetween: uniformBetween,
			uniformBetweenOptField: uniformBetweenOptField,
			anyEmptyLinesFlag: anyEmptyLinesFlag,
			uniformStmtBlanks: uniformStmtBlanks,
			caseSiblingWidthExpr: caseSiblingWidthExpr,
			blankAroundMarkExpr: blankAround.markExpr,
			blankAroundSeenExpr: blankAround.seenExpr,
			blankAroundApplyExpr: blankAround.applyExpr,
		};
		return triviaBlockMainExpr(ctx);
	}

	/**
	 * Block-Star per-element write-call build. Mirrors the inline element-call
	 * setup formerly at the top of `triviaBlockStarExpr`: the
	 * `clearAnonFnBodyOnElems` opt arg, the `clearExprPositionNonTail` tail
	 * barrier wrap, and the final `elemFn(_t.node, opt)` call. Extracted so the
	 * orchestrator stays under the complexity gate.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaBlockElemCallExpr(
		elemFn: String, clearAnonFnBodyOnElems: Bool, clearExprPositionNonTail: Bool, caseSiblingSymmetry: Bool = false
	): Expr {
		// ω-arrow-lambda-body-context: when the call site opts in via
		// `@:fmt(leftCurlyAnonFnOverride(...))` on the parent Star, the per-
		// element write call passes `_clearAnonFnBody(opt)` so the flag is
		// consumed at this Star's `{` placement and descendants (nested
		// statements / nested BlockExpr inside the body) fall back to the
		// default `blockLeftCurly` knob rather than re-triggering the
		// anon-fn override.
		final elemOptBase: Expr = clearAnonFnBodyOnElems ? macro _clearAnonFnBody(opt) : macro opt;
		// ω-case-sibling-symmetry: stamp the switch's widest-sibling flat width
		// (`_csW`, computed by the pre-pass in `triviaBlockMainExpr`) onto every
		// element's opt. ALWAYS written, never inherited, so a nested switch
		// overwrites the enclosing one's width instead of coordinating against
		// it. Flag off ⇒ the identical Expr as before.
		final elemOptExpr: Expr = caseSiblingSymmetry ? macro _setCaseSiblingWidth($elemOptBase, _csW) : elemOptBase;
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
		// `HxModuleWriteOptions` always declares `_inValueIfBranch` — so the
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
			macro (
				_si == _arr.length - 1 ? (
					$blockTailBarrier
						&& (opt.expressionIfBody == anyparse.format.BodyPolicy.Next
							|| opt.expressionIfBody == anyparse.format.BodyPolicy.FitLine)
						? _clearArrowLambdaBody(_clearValueIfBranch(_clearExprPosition($elemOptExpr)))
						: _clearArrowLambdaBody(_clearValueIfBranch($elemOptExpr))
				) : _clearArrowLambdaBody(_clearValueIfBranch(_clearExprPosition($elemOptExpr)))
			);
		} else
			elemOptExpr;
		return {
			expr: ECall(macro $i{elemFn}, [macro _t.node, elemCallOptArg]),
			pos: Context.currentPos(),
		};
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
		final emptyCurlyAccess: Expr = emptyCurlyKnob != null ? {
			expr: EField(macro opt, emptyCurlyKnob),
			pos: Context.currentPos()
		} : macro (opt._inAnonFnBody ? opt.anonFunctionEmptyCurly : opt.emptyCurly);
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
		final rightCurlyAccess: Null<Expr> = rightCurlyKnob != null ? {
			expr: EField(macro opt, rightCurlyKnob),
			pos: Context.currentPos()
		} : null;
		final rightCurlyAnonFnAccess: Null<Expr> = rightCurlyKnob == null && rightCurlyAnonFnKnob != null ? {
			expr: EField(macro opt, rightCurlyAnonFnKnob),
			pos: Context.currentPos()
		} : null;
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
		beginEndType: Bool, keepCurlyBlanks: Bool, beginKnob: String, endKnob: String
	): { final beginTypeExpr: Expr; final endTypeExpr: Expr; } {
		final emitBeginExtras: Bool = beginEndType || keepCurlyBlanks;
		final beginNExpr: Expr = triviaBlockBeginNExpr(beginEndType, beginKnob);
		final endNExpr: Expr = triviaBlockEndNExpr(beginEndType, endKnob);
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
					_ci > 0 && StringTools.startsWith(_t.leadingComments[_ci], '/**')
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
					_ci + 1 < _t.leadingComments.length && StringTools.startsWith(_t.leadingComments[_ci], '/*')
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
					_ti + 1 < _trailLC.length && StringTools.startsWith(_trailLC[_ti], '/*')
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
			blockTrailBetweenExpr: blockTrailBetweenExpr,
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
			pos: Context.currentPos(),
		};
	}

	/**
	 * Block-Star blockEnded between-element / trailing sep emission (ω-blockended-
	 * trivia, Session 3 + ω-phase-g + ω-condcomp-stray-semi). Builds the
	 * `blockSepBeforeHardlineExpr` (inter-element sep when the prior element isn't
	 * already statement-terminated) and the `blockTrailSepEmitExpr` (source-trail
	 * sep after the last element). Null sepText / non-blockEnded → no-op.
	 */
	private static function triviaBlockSepExprs(
		sepText: Null<String>, blockEnded: Bool, blockEndedPredicate: Null<String>, blockEndedSchemaPath: Null<String>
	): { final blockSepBeforeHardlineExpr: Expr; final blockTrailSepEmitExpr: Expr; } {
		if (sepText == null || !blockEnded) return { blockSepBeforeHardlineExpr: macro {}, blockTrailSepEmitExpr: macro {} };
		final priorPredCall: Expr = triviaBlockPredCallExpr(blockEndedPredicate, blockEndedSchemaPath, macro _arr[_si - 1].node);
		final lastPredCall: Expr = triviaBlockPredCallExpr(blockEndedPredicate, blockEndedSchemaPath, macro _arr[_arr.length - 1].node);
		// ω-phase-g (Session 4): source-fidelity OR `_arr[_si - 1].sepAfter`. Trust
		// the parser: if it consumed a sep after the prior element, preserve it even
		// when the prior already ends with `}`. The `endsWithStmtTerminator` arm is
		// the safety net for raw/programmatic AST inputs. ω-condcomp-stray-semi: the
		// `!priorPredCall` guard suppresses the spurious `;` between `#end` and the
		// next stmt (a `#if … #end` ends with `d`, byte check misses).
		final blockSepBeforeHardlineExpr: Expr = macro {
			if (
				_si > 0 && _priorElemDoc != null
				&& (_arr[_si - 1].sepAfter || (!anyparse.core.DocMeasure.endsWithStmtTerminator(_priorElemDoc) && !($priorPredCall)))
			) {
				_inner.push(_dt($v{sepText}));
			}
		};
		// ω-blockended-trivia-trail-sep (Session 3): after the last element, emit
		// `;` iff the LAST element's `sepAfter` is true and it doesn't already end
		// with `;` (inner `@:trail(';')` baked it in).
		final blockTrailSepEmitExpr: Expr = macro {
			if (
				_arr.length > 0 && _priorElemDoc != null && _arr[_arr.length - 1].sepAfter
				&& !anyparse.core.DocMeasure.endsWithSemi(_priorElemDoc) && !($lastPredCall)
			) {
				_inner.push(_dt($v{sepText}));
			}
		};
		return { blockSepBeforeHardlineExpr: blockSepBeforeHardlineExpr, blockTrailSepEmitExpr: blockTrailSepEmitExpr };
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
		afterFieldsWithDocComments: Bool, beforeDocCommentEmptyLines: Bool, existingBetweenFields: Bool, interMember: Bool,
		indentCaseLabelsGate: Bool, lineCommentTrailBlank: Bool
	): WriterLowering.BlockLeafExprs {
		final trackDocCommentExpr: Expr = afterFieldsWithDocComments
			? macro {
				var _hasDoc: Bool = false;
				var _dci: Int = 0;
				while (_dci < _t.leadingComments.length) {
					if (StringTools.startsWith(_t.leadingComments[_dci], '/**')) {
						_hasDoc = true;
						break;
					}
					_dci++;
				}
				_prevHadDocComment = _hasDoc;
			}
			: macro {};
		// ω-indent-case-labels: when the call site opts in via
		// `@:fmt(indentCaseLabels)`, the body wrap is gated on `opt.indentCaseLabels`
		// — `false` flushes case labels with the surrounding `switch` keyword.
		final innerWrapExpr: Expr = indentCaseLabelsGate
			? macro (opt.indentCaseLabels ? _dn(_cols, _dc(_inner)) : _dc(_inner))
			: macro _dn(_cols, _dc(_inner));
		// ω-block-orphan-trail-blank: opt-in via
		// `@:fmt(blankBeforeOrphanLineCommentTrail)`. When the orphan trail is led by
		// a line-comment `//`, force the extra `_dhl()` blank regardless of source.
		final extraInnerTrailBlankExpr: Expr = lineCommentTrailBlank
			? macro (_arr.length > 0 && (_trailBB || (_trailLC.length > 0 && StringTools.startsWith(_trailLC[0], '//'))))
			: macro (_trailBB && _arr.length > 0);
		return {
			initDocCommentExpr: afterFieldsWithDocComments ? macro var _prevHadDocComment: Bool = false : macro {},
			initCurrDocCommentExpr: beforeDocCommentEmptyLines ? macro var _currHasDocComment: Bool = false : macro {},
			initCurrSplitLeadingExpr: existingBetweenFields ? macro var _currHasSplitLeading: Bool = false : macro {},
			initPrevKindExpr: interMember ? macro var _prevKind: Int = 0 : macro {},
			initCurrKindExpr: interMember ? macro var _currKind: Int = 0 : macro {},
			trackPrevKindExpr: interMember ? macro _prevKind = _currKind : macro {},
			trackDocCommentExpr: trackDocCommentExpr,
			innerWrapExpr: innerWrapExpr,
			extraInnerTrailBlankExpr: extraInnerTrailBlankExpr,
		};
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
	private static function triviaBlockWhileExpr(c: WriterLowering.BlockStarCtx): Expr {
		final initCurrKindExpr: Expr = c.initCurrKindExpr;
		final blockSepBeforeHardlineExpr: Expr = c.blockSepBeforeHardlineExpr;
		final beginTypeExpr: Expr = c.beginTypeExpr;
		final blankBeforeExpr: Expr = c.blankBeforeExpr;
		final leadingSplitGateExpr: Expr = c.leadingSplitGateExpr;
		final blockLeadingBetweenExpr: Expr = c.blockLeadingBetweenExpr;
		final trackDocCommentExpr: Expr = c.trackDocCommentExpr;
		final triviaElemCall: Expr = c.triviaElemCall;
		final trackPrevKindExpr: Expr = c.trackPrevKindExpr;
		final balcEmitExpr: Expr = WriterLowering.triviaBalcEmitExpr(c.uniformStmtBlanks);
		final blankAroundMarkExpr: Expr = c.blankAroundMarkExpr;
		final blankAroundSeenExpr: Expr = c.blankAroundSeenExpr;
		final blankAroundApplyExpr: Expr = c.blankAroundApplyExpr;
		return macro {
			while (_si < _arr.length) {
				final _t = _arr[_si];
				$initCurrKindExpr;
				$blockSepBeforeHardlineExpr;
				_inner.push(_dhl());
				if (_si == 0) $beginTypeExpr;
				$blankAroundMarkExpr;
				$blankBeforeExpr;
				$blankAroundSeenExpr;
				var _ci: Int = 0;
				while (_ci < _t.leadingComments.length) {
					$leadingSplitGateExpr;
					_inner.push(leadingCommentDocRun(_t.leadingComments, _ci, opt));
					_inner.push(_dhl());
					$blockLeadingBetweenExpr;
					_ci++;
				}
				$balcEmitExpr;
				$trackDocCommentExpr;
				final _elem: anyparse.core.Doc = $triviaElemCall;
				$blankAroundApplyExpr;
				final _tc: Null<String> = _t.trailingComment;
				_inner.push(_tc != null ? foldTrailingIntoBodyGroup(_elem, trailingCommentDocVerbatim(_tc, opt)) : _elem);
				_priorElemDoc = _elem;
				$trackPrevKindExpr;
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
	private static function triviaBlockElseBody(c: WriterLowering.BlockStarCtx): Expr {
		final initDocCommentExpr: Expr = c.initDocCommentExpr;
		final initCurrDocCommentExpr: Expr = c.initCurrDocCommentExpr;
		final initCurrSplitLeadingExpr: Expr = c.initCurrSplitLeadingExpr;
		final initPrevKindExpr: Expr = c.initPrevKindExpr;
		final uniformCollapseInitExpr: Expr = WriterLowering.triviaUniformCollapseInitExpr(c.uniformStmtBlanks);
		final whileExpr: Expr = triviaBlockWhileExpr(c);
		final blockTrailSepEmitExpr: Expr = c.blockTrailSepEmitExpr;
		final extraInnerTrailBlankExpr: Expr = c.extraInnerTrailBlankExpr;
		final blockTrailBetweenExpr: Expr = c.blockTrailBetweenExpr;
		final endTypeExpr: Expr = c.endTypeExpr;
		final innerWrapExpr: Expr = c.innerWrapExpr;
		final beforeCloseHardlineExpr: Expr = c.beforeCloseHardlineExpr;
		final trailFollowExpr: Expr = c.trailFollowExpr;
		final openText: String = c.openText;
		final closeText: String = c.closeText;
		return macro {
			final _inner: Array<anyparse.core.Doc> = [];
			$initDocCommentExpr;
			$initCurrDocCommentExpr;
			$initCurrSplitLeadingExpr;
			$initPrevKindExpr;
			$uniformCollapseInitExpr;
			// ω-blockended-trivia (Session 3): tracks the prior iteration's rendered
			// element Doc so the between-element sep emission can query
			// `DocMeasure.endsWithStmtTerminator`. Null on the first iteration.
			var _priorElemDoc: Null<anyparse.core.Doc> = null;
			var _si: Int = 0;
			$whileExpr;
			// ω-blockended-trivia-trail-sep (Session 3): after the last element, if
			// source had `;` AND prior doesn't already terminate, emit `;` so
			// source-fidelity is preserved.
			$blockTrailSepEmitExpr;
			if (_trailLC.length > 0) {
				_inner.push(_dhl());
				if ($extraInnerTrailBlankExpr) _inner.push(_dhl());
				var _ti: Int = 0;
				while (_ti < _trailLC.length) {
					_inner.push(leadingCommentDocRun(_trailLC, _ti, opt));
					if (_ti < _trailLC.length - 1) _inner.push(_dhl());
					$blockTrailBetweenExpr;
					_ti++;
				}
			} else
				$endTypeExpr;
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _innerWrap: anyparse.core.Doc = $innerWrapExpr;
			final _parts: Array<anyparse.core.Doc> = [_dt($v{openText})];
			if (_trailOpen != null) _parts.push(trailingCommentDocVerbatim(_trailOpen, opt));
			_parts.push(_innerWrap);
			_parts.push($beforeCloseHardlineExpr);
			_parts.push(_dt($v{closeText}));
			if (_trailClose != null) {
				// Group-closer seam: `$trailFollowExpr` supplies the break only
				// for the Alt-branch arm; the Seq-struct arm assumes the parent
				// Star emits the next hardline, which holds for a STATEMENT-list
				// parent but not for a block that is itself an element of an
				// inline group - `g(function() {\n\th();\n} // c\n)` puts the
				// call's `)` right after the comment on the same Doc line and it
				// is swallowed. The guarded emitter carries its own forward-
				// looking hardline for LINE style; when the Alt arm pushes one
				// too the second simply overwrites the un-committed slot, so
				// that arm stays byte-identical, and a block comment keeps its
				// legal glue in both.
				_parts.push(trailingCommentDocGuarded(_trailClose, opt));
				$trailFollowExpr;
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
	 * the runtime `opt` local and the `BlockStarCtx`-bundled spliced Exprs.
	 *
	 */
	private static function triviaBlockMainExpr(c: WriterLowering.BlockStarCtx): Expr {
		final fieldAccess: Expr = c.fieldAccess;
		final trailLC: Expr = c.trailLC;
		final trailBB: Expr = c.trailBB;
		final trailClose: Expr = c.trailClose;
		final trailOpen: Expr = c.trailOpen;
		final openText: String = c.openText;
		final closeText: String = c.closeText;
		final emptyTrailExpr: Expr = c.emptyTrailExpr;
		final emptyDocExpr: Expr = c.emptyDocExpr;
		final caseSiblingWidthExpr: Expr = c.caseSiblingWidthExpr;
		final elseBody: Expr = triviaBlockElseBody(c);
		return macro {
			final _arr = $fieldAccess;
			final _csW: Int = $caseSiblingWidthExpr;
			final _trailLC: Array<String> = $trailLC;
			final _trailBB: Bool = $trailBB;
			final _trailClose: Null<String> = $trailClose;
			final _trailOpen: Null<String> = $trailOpen;
			// ω-open-trailing-alt: empty Star with a same-line block-style trail
			// comment after the open lit (`{ /* nop */ }`) emits flat tight. Mirror
			// of the equivalent fast path in `triviaSepStarExpr`.
			if (_arr.length == 0 && _trailLC.length == 0 && _trailOpen != null && StringTools.startsWith(_trailOpen, '/*')) {
				final _openDoc: anyparse.core.Doc = _dt(_trailOpen);
				if (_trailClose != null)
					_dc([
						_dt($v{openText}),
						_openDoc,
						_dt($v{closeText}),
						trailingCommentDocVerbatim(_trailClose, opt)
					]);
				else
					_dc([_dt($v{openText}), _openDoc, _dt($v{closeText})]);
			} else if (_arr.length == 0 && _trailLC.length == 0 && _trailOpen == null) {
				if (_trailClose != null)
					$emptyTrailExpr
				else
					$emptyDocExpr;
			} else
				$elseBody;
		};
	}

	/**
	 * Block-Star head blank-line count (ω-class-begin-end-type / ω-bropen-keep).
	 * Resolves the begin-side blank count: explicit `beginType` (type bodies) else
	 * the `afterLeftCurly` Keep-policy source-blank honour.
	 */
	private static function triviaBlockBeginNExpr(beginEndType: Bool, beginKnob: String): Expr {
		// ω-enumabstract-begin-end: read the enum-abstract begin knob under the
		// `_inEnumAbstract` context flag, else the passed (default class-scoped) knob.
		final beginAccess: Expr = macro (opt._inEnumAbstract ? opt.enumAbstractBeginType : $p{['opt', beginKnob]});
		return beginEndType
			? macro (
				$beginAccess > 0
					? $beginAccess
					: (opt.afterLeftCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _firstSourceBlank ? 1 : 0)
			)
			: macro (opt.afterLeftCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _firstSourceBlank ? 1 : 0);
	}

	/**
	 * Block-Star tail blank-line count (ω-class-begin-end-type / ω-bropen-keep).
	 * Resolves the end-side blank count: explicit `endType` (type bodies) else the
	 * `beforeRightCurly` Keep-policy source-blank honour.
	 */
	private static function triviaBlockEndNExpr(beginEndType: Bool, endKnob: String): Expr {
		// ω-enumabstract-begin-end: read the enum-abstract end knob under the
		// `_inEnumAbstract` context flag, else the passed (default class-scoped) knob.
		final endAccess: Expr = macro (opt._inEnumAbstract ? opt.enumAbstractEndType : $p{['opt', endKnob]});
		return beginEndType
			? macro (
				$endAccess > 0
					? $endAccess
					: (opt.beforeRightCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _trailBB && _arr.length > 0 ? 1 : 0)
			)
			: macro (opt.beforeRightCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _trailBB && _arr.length > 0 ? 1 : 0);
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
	final currHasSplitLeadingComputeExpr: Expr;
	final stripByDocExpr: Expr;
	final stripByExistingExpr: Expr;
	final stripByCurrDocExpr: Expr;
	final stripBySplitLeadingExpr: Expr;
	final addSuppressOnSplitLeadingExpr: Expr;
	final addByDocExpr: Expr;
	final addByCurrDocExpr: Expr;
	final addByInterMemberExpr: Expr;
	final addByUniformBetweenExpr: Expr;
};
#end
