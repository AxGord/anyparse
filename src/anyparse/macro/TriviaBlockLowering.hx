package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 3W helpers — the block-Star inter-element blank-line family.
 *
 * Builds the `blankBeforeExpr` a block Star's generated writer runs at every
 * element boundary: the strip / add gates (doc comments, existing blanks,
 * split-leading clusters, the interMember var/fn cascade, the uniform-between
 * knob), the per-element `_currHasDocComment` / `_currKind` /
 * `_currHasSplitLeading` computes, and the final `_stripBlank` / `_addBlank` /
 * `_sourceBlank` decision.
 *
 * Split out of `WriterLowering` for size — the two are NOT independent. The
 * macro-time surface is small: one inbound call (`triviaBlockBlankBeforeExpr`,
 * from `WriterLowering.triviaBlockStarExpr`) and one outbound call
 * (`WriterLowering.blankBefore2ExtrasExpr`). The GENERATED-code surface is the
 * real contract, and no type carries it: every helper here splices identifiers
 * declared elsewhere in the Star body — `_t` / `_si` / `_inner` / `opt` /
 * `_dhl()` from the Star scaffold, `_prevHadDocComment` / `_currHasDocComment` /
 * `_currHasSplitLeading` / `_prevKind` / `_currKind` from
 * `WriterLowering.triviaBlockLeafExprs`, `_uniformCollapse` from
 * `WriterLowering.triviaBlockElseBody`. Those declare sites are gated on the
 * SAME `@:fmt` flags as the computes here (`beforeDocCommentEmptyLines`,
 * `existingBetweenFields`, `interMember`, `uniformStmtBlanks`): move a gate on
 * one side only and the generated writer either reads an undeclared local or
 * declares a dead one, with nothing in either module's types to catch it.
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
