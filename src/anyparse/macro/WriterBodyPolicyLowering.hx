package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.macro.WriterLoweringSupport.*;

using StringTools;
using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W helpers - the body-policy wrap family.
 *
 * Everything behind ONE decision: given a field the grammar marked as a
 * construct's BODY (`@:fmt(bodyPolicy(...))`), where does that body go
 * relative to its head - same line, next line, its own block, or kept as
 * the source had it - and what separator, indent, brace placement and
 * comment fold the choice implies. The five layout builders
 * (`buildBodySameLayout` / `Next` / `Block` / `Fit` / `Keep`) each emit one
 * arm, `buildBodyCoreWrap` selects between them at runtime, and the
 * `wrapBody*` members bolt on the trailing-doc, Allman, meta-block-glue and
 * loop-shape corrections.
 *
 * Split out of `WriterLowering` for size. Five members there enter through
 * `bodyPolicyWrap`, the family's single door.
 *
 * ⚠️ `buildBodyCoreWrap`'s outer switch is deliberately NOT the place to add
 * an arm - S79 folded its new behaviour into the policy SELECTOR instead,
 * for the JVM method-size reason that switch documents. Moving the family
 * to its own module does not change that: the constraint is on the
 * GENERATED method, not on this one.
 *
 * Every member is static and the build state arrives as one `BodyPolicyCtx`
 * bundle, built once in `WriterLowering`'s constructor. The bundle IS the
 * dependency surface: two data fields and the four shape helpers whose
 * other callers stayed behind.
 *
 * The GENERATED-code surface is the real contract: the arms splice `value`,
 * `opt` and the `_d*` Doc wrappers `WriterCodegen` emits, and
 * `arrowValueIfPolicy` reads `_aifReflow`, a local DECLARED by
 * `WriterArrowValueIfLowering.arrowValueIfReflowWrap` one level out.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterLoweringSupport, anyparse.macro.WriterPolicyLowering)
final class WriterBodyPolicyLowering {

	/**
	 * Build a Doc expression that wraps a bare-Ref body field with a
	 * runtime-switched separator driven by `@:fmt(bodyPolicy("flagName"))`.
	 *
	 * Reads `opt.<flagName>:BodyPolicy` and dispatches:
	 *  - `Same`    → `_dc([_dt(' '), body])` — body on the same line,
	 *                separated by a single space (current behaviour).
	 *  - `Next`    → `_dn(cols, _dc([_dhl(), body]))` — body on the
	 *                next line at one indent level deeper.
	 *  - `FitLine` → `_dbg(_dn(cols, _dc([_dl(), body])))` — `BodyGroup`
	 *                lets the renderer pick flat (space + body) or break
	 *                (hardline + indent + body) based on `lineWidth`.
	 *                `BodyGroup` is layout-identical to `Group` but
	 *                acts as a semantic marker so the trivia writer's
	 *                `foldTrailingIntoBodyGroup` can splice a trailing
	 *                line comment into the body's measured content
	 *                without catching unrelated `Group`s in the tree
	 *                (e.g. `trailingCommaArgs` inside a call expression).
	 *
	 * `cols` is derived from the same `indentChar`/`indentSize`/
	 * `tabWidth` triple as `blockBody`, so one-level body indent matches
	 * a `{}` block's nesting depth.
	 *
	 * Block-bodied values bypass the policy: when `bodyTypePath` is an
	 * enum whose branches carry `@:lead(openText) @:trail(closeText)` on
	 * a single Star child (the characteristic of a `blockBody`-rendered
	 * constructor, e.g. `BlockStmt(@:lead('{') @:trail('}'))`), an outer
	 * runtime `switch` routes those ctors to a single-space layout —
	 * matching haxe-formatter's convention that `{ … }` stays on the
	 * same line as `do` / `if` / `while` / `for` regardless of the
	 * placement knob. This keeps policy targeted at the non-block
	 * expression-body case where the knob actually shifts layout.
	 *
	 * ω-issue-316-curly-both: block-ctor branches tagged with
	 * `@:fmt(leftCurly)` (e.g. `HxStatement.BlockStmt`) participate in
	 * the outer switch with a leftCurly-aware separator — the space
	 * between the preceding token and the body's `{` flips to a hardline
	 * at the outer indent when `opt.leftCurly:BracePlacement` is `Next`.
	 * Threaded through `kwGapDoc`'s `nextCurly` parameter on the
	 * kw-slot path so captured trivia still renders correctly (kwGapDoc
	 * already emits a trailing hardline when trivia is present — only
	 * the no-trivia path is affected by `nextCurly`). Untagged block
	 * ctors keep the pre-slice single-space layout.
	 *
	 * ψ₈: when `hasElseIf` is true, an additional outer-switch case is
	 * added for the `IfStmt` ctor of `bodyTypePath` that routes to
	 * `opt.elseIf:KeywordPlacement` — `Same` keeps `else if (...)`
	 * inline (single space + body) while `Next` moves the nested `if`
	 * to the next line (hardline + indent + body). This override runs
	 * regardless of the field's own `@:fmt(bodyPolicy(...))` flag value, so
	 * `elseBody=Next` with `elseIf=Same` still emits `} else if (...)`
	 * on one line for nested ifs and only pushes non-if else branches
	 * to the next line.
	 *
	 * ψ₁₂: when `elseFieldName` is non-null (derived from a sibling
	 * `@:optional` bodyPolicy field captured by `lowerStruct` and gated
	 * by the field's own `@:fmt(fitLineIfWithElse)` flag), the `FitLine`
	 * branch is replaced with a runtime ternary that degrades to the
	 * `Next` layout when `opt.fitLineIfWithElse` is `false` AND the
	 * sibling is non-null. On the sibling site itself (`elseBody`) the
	 * runtime check trivially resolves to `opt.fitLineIfWithElse`
	 * because the emission is already inside the `if (_optVal != null)`
	 * guard; on the peer site (`thenBody`) the check becomes a real
	 * lookup on `value.<elseFieldName>`. When `elseFieldName` is null,
	 * the `FitLine` branch stays byte-identical to pre-ψ₁₂.
	 *
	 * The case patterns are built as raw `EField` expressions to avoid
	 * macro-time enum resolution against the `BodyPolicy` abstract.
	 */
	private static function bodyPolicyWrap(bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts): Expr {
		final writeCall: Expr = buildBodyWriteCall(bp, opts);
		final optFlag: Expr = resolveBodyOptFlag(bp, opts);
		final hasKwSlots: Bool = opts.afterKwExpr != null && opts.kwLeadingExpr != null;
		final kwSep: { kwPolicyInlineSep: Null<Expr>, sameSepNb: Expr } = buildBodyKwSep(opts, hasKwSlots);
		final shared: WriterLowering.BodyWrapShared = {
			writeCall: writeCall,
			sameSepNb: kwSep.sameSepNb,
			kwPolicyInlineSep: kwSep.kwPolicyInlineSep,
			hasKwSlots: hasKwSlots
		};
		final sameLayoutExpr: Expr = buildBodySameLayout(bp, opts, shared);
		final nextLayoutExpr: Expr = buildBodyNextLayout(bp, opts, shared);
		final blockLayoutExpr: Expr = buildBodyBlockLayout(opts, shared);
		final fitExpr: Expr = buildBodyFitExpr(bp, opts, shared);
		final layouts: WriterLowering.BodyLayouts = {
			sameLayoutExpr: sameLayoutExpr,
			nextLayoutExpr: nextLayoutExpr,
			blockLayoutExpr: blockLayoutExpr,
			fitExpr: fitExpr,
			elseIfSameLayoutExpr: buildElseIfCommentReflowLayout(bp, opts, shared, sameLayoutExpr)
		};
		final blockSplit: { tagged: Array<Expr>, untagged: Array<Expr> } = collectBlockCtorPatternsByLeftCurly(bp, opts.bodyTypePath);
		final ifStmtPattern: Null<Expr> = opts.hasElseIf
			? (bp.findCtorPattern(opts.bodyTypePath, 'IfStmt') ?? bp.findCtorPattern(opts.bodyTypePath, 'IfExpr'))
			: null;
		final keepLayoutExpr: Expr = buildBodyKeepLayout(bp, opts, layouts, blockSplit, ifStmtPattern);
		final coreWrapExpr: Expr = buildBodyCoreWrap(bp, opts, optFlag, layouts, keepLayoutExpr, blockSplit, ifStmtPattern);
		final wrapExpr: Expr = wrapBodyAfterTrail(opts, coreWrapExpr, writeCall, blockSplit);
		final finalWrapExpr: Expr = wrapBodyAllman(opts, wrapExpr, writeCall);
		final mbgWrapExpr: Expr = wrapBodyMetaBlockGlue(opts, finalWrapExpr, sameLayoutExpr);
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$mbgWrapExpr;
		};
	}

	/**
	 * Build the body's writeCall, optionally wrapping it in the
	 * `inlineBlockBodyIfFlag` runtime flatten (ω-expression-if-with-blocks).
	 *
	 */
	private static function buildBodyWriteCall(bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts): Expr {
		final inlineBlockBodyArgs: Null<Array<String>> = opts.inlineBlockBodyArgs;
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		// ω-expression-if-with-blocks: when the field carries
		// `@:fmt(inlineBlockBodyIfFlag('<flagName>'))`, swap the body's
		// writeCall for a runtime-conditional Doc that flattens block
		// bodies inline when `opt.<flagName>` is true AND the body's
		// runtime ctor is `BlockExpr`. Done at the entry of bodyPolicyWrap
		// so the flattened body propagates through every downstream
		// policy / override layout (Same / Next / Keep / FitLine / etc.).
		// Non-BlockExpr bodies and flag-false invocations get the original
		// writeCall result unchanged.
		//
		// Note: ctor literal `'BlockExpr'` is hardcoded by-definition —
		// the meta's semantic IS "block-shaped body collapse" (mirrors
		// fork's `markBlockBody`). If a future grammar wants the same
		// override on a different block-shaped ctor, extend the meta to
		// `inlineBlockBodyIfFlag('<flag>', '<ctorName>')` and read both
		// args here.
		final base: Expr = if (inlineBlockBodyArgs == null)
			opts.writeCall;
		else {
			if (inlineBlockBodyArgs.length != 1)
				Context.fatalError(
					'WriterLowering: bodyPolicyWrap inlineBlockBodyArgs requires (flagName), got ${inlineBlockBodyArgs.length} args',
					Context.currentPos()
				);
			final inlineFlag: Expr = optFieldAccess(inlineBlockBodyArgs[0]);
			final origWriteCall: Expr = opts.writeCall;
			macro {
				final _bodyDoc: anyparse.core.Doc = $origWriteCall;
				$inlineFlag && Type.enumConstructor($bodyValueExpr) == 'BlockExpr' ? anyparse.core.D.flatten(_bodyDoc) : _bodyDoc;
			};
		}
		// ω-single-stmt-braces trailing-comment hoist: fold a de-braced statement's
		// same-line trailing comment after its `;` so it enters the body fit/break
		// measurement. Null off the dropSingleStmtBraces path -> base unchanged.
		return bp.foldSsbTrailingComment(base, opts.ssbTrailCommentExpr);
	}

	/**
	 * Resolve the runtime body-policy flag Expr — the four-stage chain:
	 * expr-position dual-flag (ω-issue-257), single-line-vs-multi (ω-return-
	 * body-single-line), per-ctor policy overrides (ω-untyped-body-stmt-
	 * override), and the no-sibling fallback (ω-expression-if-next).
	 */
	private static function resolveBodyOptFlag(bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts): Expr {
		final flagName: String = opts.flagName;
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		final exprFlagName: Null<String> = opts.exprFlagName;
		final baseOptFlag: Expr = if (exprFlagName == null)
			optFieldAccess(flagName)
		else {
			final stmtAccess: Expr = optFieldAccess(flagName);
			final exprAccess: Expr = optFieldAccess(exprFlagName);
			macro (opt._inExprPosition ? $exprAccess : $stmtAccess);
		};
		final singleLineFlagName: Null<String> = opts.singleLineFlagName;
		final singleLineMultiCtors: Null<Array<String>> = opts.singleLineMultiCtors;
		final defaultOptFlag: Expr = if (singleLineFlagName == null)
			baseOptFlag
		else {
			final singleLineAccess: Expr = optFieldAccess(singleLineFlagName);
			final ctors: Array<String> = singleLineMultiCtors ?? [];
			final ctorExpr: Expr = macro Type.enumConstructor($bodyValueExpr);
			var isMultiLine: Expr = macro false;
			for (ctorName in ctors) isMultiLine = macro $isMultiLine || $ctorExpr == $v{ctorName};
			macro ($isMultiLine ? $baseOptFlag : $singleLineAccess);
		};
		final policyOverrides: Null<Array<Array<String>>> = opts.policyOverrides;
		final ctorOverriddenOptFlag: Expr = if (policyOverrides == null || policyOverrides.length == 0)
			defaultOptFlag
		else {
			final ctorExpr: Expr = macro Type.enumConstructor($bodyValueExpr);
			var chain: Expr = defaultOptFlag;
			var i: Int = policyOverrides.length - 1;
			while (i >= 0) {
				final pair: Array<String> = policyOverrides[i];
				if (pair.length != 2)
					Context.fatalError(
						'WriterLowering: bodyPolicyWrap policyOverrides entry requires (ctorName, flagName), got ${pair.length} args',
						Context.currentPos()
					);
				final ctorName: String = pair[0];
				final overrideFlag: String = pair[1];
				final overrideField: Expr = optFieldAccess(overrideFlag);
				chain = macro $ctorExpr == $v{ctorName} ? $overrideField : $chain;
				i--;
			}
			chain;
		};
		final fallbackFlagName: Null<String> = opts.fallbackFlagName;
		final elseFieldName: Null<String> = opts.elseFieldName;
		final bpPath: Array<String> = ['anyparse', 'format', 'BodyPolicy'];
		final samePat: Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Same']));
		final keepPat: Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Keep']));
		final baseResolved: Expr = if (fallbackFlagName == null || elseFieldName == null)
			ctorOverriddenOptFlag;
		else {
			final elseAccess: Expr = { expr: EField(macro value, elseFieldName), pos: Context.currentPos() };
			final fallbackAccess: Expr = optFieldAccess(fallbackFlagName);
			macro {
				final _resolvedBP: anyparse.format.BodyPolicy = $ctorOverriddenOptFlag;
				$elseAccess == null && _resolvedBP != $samePat && _resolvedBP != $keepPat ? $fallbackAccess : _resolvedBP;
			};
		};
		return arrowValueIfPolicy(opts, baseResolved, samePat);
	}

	/**
	 * omega-arrow-value-if-reflow - outermost arm of `resolveBodyOptFlag`.
	 *
	 * A body field carrying `@:fmt(arrowValueIfReflowSite)` reads `Same`
	 * instead of its own resolved policy whenever the struct-level gate local
	 * `_aifReflow` is set (the enclosing `HxIfExpr` is the direct body of an
	 * arrow lambda, the config knob is on, and the chain carries no captured
	 * comment). Glueing every branch value to its own condition is what leaves
	 * the chain with exactly ONE break axis - the soft `Line` before each
	 * `else` - so the `Group` that `lowerStruct` wraps the whole node in can
	 * decide flat-vs-one-arm-per-line for the chain as a unit.
	 *
	 * The override is additionally gated on the sibling `else` being PRESENT
	 * (`elseFieldName`, the same access `noSiblingFallback` reads): an
	 * else-less arrow-body `if` (`item -> if (c) body`) has no chain to
	 * re-flow and keeps the `noSiblingFallback` answer it has today.
	 *
	 * Returns `resolved` unchanged when the field does not carry the flag, so
	 * every other body site is byte-inert.
	 */
	private static function arrowValueIfPolicy(opts: WriterLowering.WrapBodyOpts, resolved: Expr, samePat: Expr): Expr {
		if (opts.arrowValueIfSite != true) return resolved;
		final elseFieldName: Null<String> = opts.elseFieldName;
		final gate: Expr = if (elseFieldName == null)
			macro _aifReflow;
		else {
			final elseAccess: Expr = { expr: EField(macro value, elseFieldName), pos: Context.currentPos() };
			macro _aifReflow && $elseAccess != null;
		};
		return macro ($gate ? $samePat : $resolved);
	}

	/**
	 * Build the `Same`-policy kw→body inline separator (ω-issue-316 / ω-tryBody
	 * kwOwnsInlineSpace). Returns the `kwPolicyInlineSep` (null when no
	 * `kwPolicy` knob) and `sameSepNb` (kwGapDoc with kw-trivia slots, the
	 * kw-policy switch, or the default `_dop(' ')`).
	 */
	private static function buildBodyKwSep(
		opts: WriterLowering.WrapBodyOpts, hasKwSlots: Bool
	): { kwPolicyInlineSep: Null<Expr>, sameSepNb: Expr } {
		final kwPolicyFlagName: Null<String> = opts.kwPolicyFlagName;
		final afterKwExpr: Null<Expr> = opts.afterKwExpr;
		final kwLeadingExpr: Null<Expr> = opts.kwLeadingExpr;
		final wpPath: Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final wpAfter: Expr = MacroStringTools.toFieldExpr(wpPath.concat(['After']));
		final wpBoth: Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final kwPolicyInlineSep: Null<Expr> = kwPolicyFlagName == null ? null : {
			final kwOpt: Expr = optFieldAccess(kwPolicyFlagName);
			{
				expr: ESwitch(kwOpt, [{ values: [wpAfter, wpBoth], expr: macro _dt(' '), guard: null }], macro _de()),
				pos: Context.currentPos()
			};
		};
		// ω-keep-degraded-optspace: default kw→body separator is `_dop(' ')`
		// (OptSpace, drops before break-mode hardline) instead of `_dt(' ')`
		// (Text). When `Keep` policy degrades to `sameLayoutExpr` (no
		// `bodyOnSameLineExpr` slot — Case 3 enum-branch path) and the body's
		// own emission opens with a hardline (e.g. ObjectLit + leftCurly=Next),
		// the OptSpace drops, yielding `return\n{...}` instead of the spurious
		// `return \n{...}`. For Same policy with non-hardline-opening body
		// (Ident, Call, block ctor `{...}`), OptSpace renders as `' '`,
		// preserving pre-slice byte output.
		final sameSepNb: Expr = hasKwSlots
			? macro kwGapDoc($afterKwExpr, $kwLeadingExpr, _cols, false, opt)
			: kwPolicyInlineSep ?? macro _dop(' ');
		return { kwPolicyInlineSep: kwPolicyInlineSep, sameSepNb: sameSepNb };
	}

	/**
	 * Build the `Same`-policy layout Expr (ω-returnbody-widthaware + the
	 * value-expr Nest wrap).
	 */
	private static function buildBodySameLayout(
		bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts, shared: WriterLowering.BodyWrapShared
	): Expr {
		final writeCall: Expr = shared.writeCall;
		final sameSepNb: Expr = shared.sameSepNb;
		final ifExprIndentArgs: Null<Array<String>> = opts.ifExprIndentArgs;
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		if (opts.widthAware == true) {
			final flatBody: Expr = wrapIfExprNest(macro _bodyW, ifExprIndentArgs, bodyValueExpr);
			return macro {
				final _bodyW: anyparse.core.Doc = $writeCall;
				_difle(opt.lineWidth, _dn(_cols, _dc([_dhl(), _bodyW])), _dc([$sameSepNb, $flatBody]));
			};
		}
		final flatBody: Expr = wrapIfExprNest(writeCall, ifExprIndentArgs, bodyValueExpr);
		return macro _dc([$sameSepNb, $flatBody]);
	}

	/**
	 * Build the `Next`-policy layout Expr — the `indentObjGuardedNext` outer-
	 * Nest-drop (ω-expr-body-indent-objectliteral), the kw-slot threaded
	 * `nextLayoutKwGapDoc`, or the default `Nest(_cols, [hardline, body])`.
	 *
	 */
	private static function buildBodyNextLayout(
		bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts, shared: WriterLowering.BodyWrapShared
	): Expr {
		final writeCall: Expr = shared.writeCall;
		final hasKwSlots: Bool = shared.hasKwSlots;
		final afterKwExpr: Null<Expr> = opts.afterKwExpr;
		final kwLeadingExpr: Null<Expr> = opts.kwLeadingExpr;
		final indentObjArgs: Null<Array<String>> = opts.indentObjArgs;
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		if (indentObjArgs != null && indentObjArgs.length != 3)
			Context.fatalError(
				'WriterLowering: bodyPolicyWrap indentObjArgs requires (ctorName, optField, leftCurlyField), got ${indentObjArgs.length}'
				+ ' args',
				Context.currentPos()
			);
		// omega-value-if-fit: at an `arrowValueIfReflowSite` the gap before the body softens from
		// `Line('\n')` (a break the renderer can never flatten) to `Line(' ')`, so the `Group`
		// wrapping the chain decides it. Broken, the two render identically -- newline plus the
		// `Nest` indent -- which is why a NON-fitting chain keeps the layout it has today. Every
		// other body site keeps the bare `_dhl()` and stays byte-identical.
		final softGap: Bool = opts.arrowValueIfSite == true;
		final indentObjGuardedNext: Null<Expr> = if (indentObjArgs != null && !hasKwSlots) {
			final ctorName: String = indentObjArgs[0];
			final optAccess: Expr = optFieldAccess(indentObjArgs[1]);
			final lcAccess: Expr = optFieldAccess(indentObjArgs[2]);
			macro {
				final _body: anyparse.core.Doc = $writeCall;
				if (
					!$optAccess && $lcAccess == anyparse.format.BracePlacement.Next && Type.enumConstructor($bodyValueExpr) == $v{ctorName}
					&& anyparse.format.wrap.WrapList.flatLength(_body) == -1
				)
					_dc([${valueIfGapExpr(softGap, macro _body)}, _body])
				else
					_dn(_cols, _dc([${valueIfGapExpr(softGap, macro _body)}, _body]));
			};
		}
		else
			null;
		return indentObjGuardedNext ?? (
			hasKwSlots
				? macro {
					final _vifBody: anyparse.core.Doc = $writeCall;
					nextLayoutKwGapDoc($afterKwExpr, $kwLeadingExpr, _cols, _vifBody, opt, ${valueIfGapExpr(softGap, macro _vifBody)});
				}
				: macro {
					final _vifBody: anyparse.core.Doc = $writeCall;
					_dn(_cols, _dc([${valueIfGapExpr(softGap, macro _vifBody)}, _vifBody]));
				}
		);
	}

	/**
	 * Build the block-ctor layout Expr — the `Same`/`Next` leftCurly switch on
	 * the separator before a `{`-opening body (ω-issue-316-curly-both),
	 * threaded through `kwGapDoc` for kw-slot sites.
	 */
	private static function buildBodyBlockLayout(opts: WriterLowering.WrapBodyOpts, shared: WriterLowering.BodyWrapShared): Expr {
		final writeCall: Expr = shared.writeCall;
		final hasKwSlots: Bool = shared.hasKwSlots;
		final kwPolicyInlineSep: Null<Expr> = shared.kwPolicyInlineSep;
		final afterKwExpr: Null<Expr> = opts.afterKwExpr;
		final kwLeadingExpr: Null<Expr> = opts.kwLeadingExpr;
		final bpPathLC: Array<String> = ['anyparse', 'format', 'BracePlacement'];
		final nextPatLC: Expr = MacroStringTools.toFieldExpr(bpPathLC.concat(['Next']));
		final isNextExpr: Expr = {
			expr: ESwitch(macro opt.leftCurly, [{ values: [nextPatLC], expr: macro true, guard: null }], macro false),
			pos: Context.currentPos()
		};
		final sameSepBlockSameLayout: Expr = kwPolicyInlineSep ?? macro _dt(' ');
		final sameSepBlock: Expr = hasKwSlots ? macro kwGapDoc($afterKwExpr, $kwLeadingExpr, _cols, $isNextExpr, opt) : {
			expr: ESwitch(macro opt.leftCurly, [{ values: [nextPatLC], expr: macro _dhl(), guard: null }], sameSepBlockSameLayout),
			pos: Context.currentPos()
		};
		return macro _dc([$sameSepBlock, $writeCall]);
	}

	/**
	 * Build the `FitLine`-policy layout Expr — the return-style natural-first-
	 * line glue (ω-return-fitline-natural-glue), the keep-chain head-break
	 * (ω-keep-chain), and the if/for/while wholesale `BodyGroup` break.
	 *
	 */
	private static function buildBodyFitExpr(
		bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts, shared: WriterLowering.BodyWrapShared
	): Expr {
		final writeCall: Expr = shared.writeCall;
		final singleLineFlagName: Null<String> = opts.singleLineFlagName;
		final kwNewlineExpr: Null<Expr> = opts.kwNewlineExpr;
		final elseFieldName: Null<String> = opts.elseFieldName;
		final ifExprIndentArgs: Null<Array<String>> = opts.ifExprIndentArgs;
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		final gluedBody: Expr = wrapIfExprNest(macro _body, ifExprIndentArgs, bodyValueExpr);
		// ω-glue-width: every glue this builder emits is width-gated at the ONE
		// policy owner (`BodyFit.glueLayout`) — a body that cannot render flat
		// still puts its FIRST line on the header line, and that line has to fit.
		// The two arms below reach the glue by the same `flatLength == -1` test
		// the shared `fitLineLayout` uses, so all three inherit one answer.
		final gluedLayout: Expr = macro anyparse.format.BodyFit.glueLayout(_cols, _body, _dc([_dop(' '), $gluedBody]), opt.lineWidth);
		final multilineGlue: Expr = kwNewlineExpr != null
			? macro ($kwNewlineExpr
				&& (opt.opAddSubChainWrap.defaultMode == anyparse.format.wrap.WrapMode.Keep
					|| opt.opBoolChainWrap.defaultMode == anyparse.format.wrap.WrapMode.Keep)
				&& !anyparse.format.wrap.WrapList.startsWithHardline(_body)
				? _dn(_cols, _dc([_dhl(), _body]))
				: $gluedLayout)
			: gluedLayout;
		// ω-condwrap-fitline-construct-group: under a construct-level BodyGroup
		// (see WrapBodyOpts.condFitGroup) the flat-body FitLine layout is the
		// soft line — the group's whole-construct fitsFlat owns the same-vs-next
		// decision, so a wrapped condition (hardlines in its committed shape)
		// forces the body onto the next line. Multiline non-block bodies keep
		// the glue branch (the group is already broken; OptSpace flushes).
		final fitInnerExpr: Expr = if (opts.strictFitLine == true)
			// omega-strict-fitline-body: the whole body decides, not its first line.
			macro anyparse.format.BodyFit.fitLineLayout(_cols, _body, false, opt.lineWidth, anyparse.format.BodyFit.SIBLING_NONE, true);
		else if (opts.constructFitBody == true)
			// One soft line, no group of its own — see WrapBodyOpts.constructFitBody.
			macro _dn(_cols, _dc([_dl(), _body]));
		else if (opts.condFitGroup == true)
			macro anyparse.format.wrap.WrapList.flatLength(_body) == -1
				? $multilineGlue
				: opt.fitLineBodyGlue
					? _dib(
						anyparse.format.BodyFit.continuationRescuesBody(
							_cols, _body, _dc([_dop(' '), $gluedBody]), anyparse.format.wrap.WrapList.flatLength(_body), opt.lineWidth
						),
						_dn(_cols, _dc([_dl(), _body]))
					)
					: anyparse.format.BodyFit.chainStaircase(_cols, _body, _dn(_cols, _dc([_dl(), _body])), opt.lineWidth);
		else if (singleLineFlagName != null)
			macro anyparse.format.wrap.WrapList.flatLength(_body) == -1
				? $multilineGlue
				: _dinfler(opt.lineWidth, _dn(_cols, _dc([_dhl(), _body])), _dc([_dop(' '), $gluedBody]));
		else
			// ω-case-body-fitline-shared: the plain FitLine shape now has ONE
			// owner (`anyparse.format.BodyFit`), shared with the case-body Star
			// path. `nestGluedBody = false` keeps this site byte-identical.
			macro anyparse.format.BodyFit.fitLineLayout(_cols, _body, false, opt.lineWidth, anyparse.format.BodyFit.SIBLING_NONE);
		// ω-loop-body-if-else-next: on a LOOP body field the whole FitLine answer
		// above is skipped for one body shape — an `if` that owns an `else` — and
		// replaced by the same `Next` layout the `fitLineIfWithElse` escape below
		// uses. Every other body, this flag off, and every non-loop field keep the
		// answer unchanged.
		final fitGatedExpr: Expr = wrapLoopBodyIfElseNext(opts, fitInnerExpr);
		if (elseFieldName == null) return macro {
			final _body: anyparse.core.Doc = $writeCall;
			$fitGatedExpr;
		};
		final elseAccess: Expr = {
			expr: EField(macro value, elseFieldName),
			pos: Context.currentPos()
		};
		return macro {
			final _body: anyparse.core.Doc = $writeCall;
			// ω-elseif-body-break: `_inElseIfBranch` (set by an enclosing `else if`
			// via propagateElseIfBranch) is an extra break trigger even when this
			// `if` has no `else` of its own — mirrors fork's `isPartOfIfElse`
			// "if inside else" clause. Still suppressed by `fitLineIfWithElse`.
			opt.fitLineIfWithElse || ($elseAccess == null && !opt._inElseIfBranch) ? $fitGatedExpr : _dn(_cols, _dc([_dhl(), _body]));
		};
	}

	/**
	 * omega-elseif-comment-reflow: build the `Same` layout the `elseIf`-ctor arm uses.
	 *
	 * Off-path (no `@:fmt(elseIfCommentReflow)` on the field, plain mode, or a site
	 * without the kw-trivia slots) it IS `sameLayoutExpr`, so every other grammar and
	 * the knob's own `false` default stay byte-identical.
	 *
	 * On-path it prepends one runtime gate. The knob must be on, the `else` itself
	 * must carry no same-line comment (`AfterKw`), and the kw-leading slot must hold
	 * EXACTLY one `//` comment - anything else is a shape whose relocation is not
	 * modelled. The splice then anchors that comment at the nested `if`'s head line
	 * inside the ALREADY-BUILT body Doc; when the body offers no anchor the splice
	 * returns `null` and the untouched `sameLayoutExpr` runs, comment still in its
	 * `kwGapDoc` position. The separator drops to a plain space because the comment no
	 * longer travels through `kwGapDoc` - the same byte that helper emits for empty
	 * trivia slots.
	 */
	private static function buildElseIfCommentReflowLayout(
		bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts, shared: WriterLowering.BodyWrapShared, sameLayoutExpr: Expr
	): Expr {
		final afterKwExpr: Null<Expr> = opts.afterKwExpr;
		final kwLeadingExpr: Null<Expr> = opts.kwLeadingExpr;
		if (opts.elseIfCommentReflow != true || !bp.ctx.trivia || afterKwExpr == null || kwLeadingExpr == null) return sameLayoutExpr;
		// The refusal arm RE-STATES the `Same` layout over the hoisted body local
		// instead of re-splicing `sameLayoutExpr` (whose own copy of the writeCall
		// made a refused else-if chain rebuild its body once per link — 2^n). That
		// re-statement is only equivalent for the plain shape, so a field pairing
		// this knob with either opt that makes `buildBodySameLayout` emit something
		// else is a COMPILE error rather than a silently inert knob. No grammar
		// pairs them today; the check exists so the day one does is loud.
		if (opts.widthAware == true || opts.ifExprIndentArgs != null)
			Context.fatalError(
				'WriterLowering: @:fmt(elseIfCommentReflow) cannot be combined with @:fmt('
				+ (opts.widthAware == true ? 'widthAware' : 'indentValueIfCtor')
				+ ') — the reflow arm re-states the Same layout and would drop that opt\'s shape',
				Context.currentPos()
			);
		final writeCall: Expr = shared.writeCall;
		final sameSepNb: Expr = shared.sameSepNb;
		return macro {
			final _eicrBody: anyparse.core.Doc = $writeCall;
			final _eicrLead: Array<String> = $kwLeadingExpr;
			final _eicrDoc: Null<anyparse.core.Doc> = opt.elseIfCommentReflow && $afterKwExpr == null && _eicrLead.length == 1
				&& StringTools.startsWith(_eicrLead[0], '//')
				? anyparse.format.ElseIfCommentReflow.insertHeadTrail(_eicrBody, trailingCommentDocGuarded(_eicrLead[0], opt))
				: null;
			_eicrDoc != null ? _dc([_dt(' '), _eicrDoc]) : _dc([$sameSepNb, _eicrBody]);
		};
	}

	/**
	 * The same decision as `buildElseSwitchCases`, but as a pair of BOOL tests instead of a pair
	 * of switch arms — `(same, next)`, each `null` when the field declares no `@:fmt(elseSwitch)`.
	 *
	 * Why it exists: an arm carries a whole LAYOUT expression, and the layouts of the `if`
	 * writer are large. Two arms in `buildBodyKeepLayout` plus two in `buildBodyCoreWrap` added
	 * four more copies of them to ONE generated function, and `HaxeModuleTriviaWriter` — a
	 * single generated class already 1.22 MB of JS — grew 161 712 bytes and stopped fitting a
	 * JVM class file: `tools/jvm-portability.hxml` failed with `IO.Overflow("write_ui16")`, the
	 * 16-bit constant-pool counter. Reverting this ONE field's meta made it pass again, which is
	 * how the cause was pinned. As a condition folded into the layout choice, the same decision
	 * adds no layout copy at all.
	 */
	private static function buildElseSwitchTests(
		bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts
	): { same: Null<Expr>, next: Null<Expr> } {
		final cases: Array<Case> = buildElseSwitchCases(bp, opts, macro true, macro false);
		if (cases.length == 0) return { same: null, next: null };
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		return {
			same: {
				expr: ESwitch(bodyValueExpr, [{ values: cases[0].values, expr: macro true, guard: cases[0].guard }], macro false),
				pos: Context.currentPos()
			},
			next: {
				expr: ESwitch(bodyValueExpr, [{ values: cases[1].values, expr: macro true, guard: cases[1].guard }], macro false),
				pos: Context.currentPos()
			}
		};
	}

	/**
	 * omega-else-switch: the two GUARDED outer-switch arms a
	 * `@:fmt(elseSwitch('<knobField>', '<ctor>'…))` field contributes - one for
	 * `KeywordPlacement.Same` (the `switch` glues to the `else` line) and one for
	 * `Next` (it moves to the next line at the outer indent).
	 *
	 * Guards rather than a nested switch on the knob, because the third value
	 * `Keep` must mean "no opinion": a failed guard continues matching with the
	 * arms that follow, so `Keep` reaches exactly the block-ctor / elseIf / policy
	 * arms that answered before this flag existed. That is what makes the default
	 * byte-inert without a second copy of those arms.
	 *
	 * Unlike the `elseIf` flag beside it, the ctor names come from the GRAMMAR: the
	 * meta's tail lists them (`'SwitchStmt', 'SwitchStmtBare'` in statement
	 * position, `'SwitchExpr', 'SwitchExprBare'` in value position), so the core
	 * macro spells none. A named ctor the body type does not declare is a compile
	 * error - a typo cannot degrade into a silently dead arm.
	 *
	 * Empty array for every field without the meta.
	 */
	private static function buildElseSwitchCases(
		bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts, sameLayoutExpr: Expr, nextLayoutExpr: Expr
	): Array<Case> {
		final args: Null<Array<String>> = opts.elseSwitchArgs;
		if (args == null) return [];
		if (args.length < 2)
			Context.fatalError(
				'WriterLowering: @:fmt(elseSwitch) expects a knob field name and at least one ctor name, got ${args.length} arg(s)',
				Context.currentPos()
			);
		final patterns: Array<Expr> = [];
		for (i in 1...args.length) {
			final pat: Null<Expr> = bp.findCtorPattern(opts.bodyTypePath, args[i]);
			if (pat == null)
				Context.fatalError(
					'WriterLowering: @:fmt(elseSwitch) names ctor "${args[i]}", which "${opts.bodyTypePath}" does not declare',
					Context.currentPos()
				);
			else
				patterns.push(pat);
		}
		final knob: Expr = { expr: EField(macro opt, args[0]), pos: Context.currentPos() };
		final kpPath: Array<String> = ['anyparse', 'format', 'KeywordPlacement'];
		final samePat: Expr = MacroStringTools.toFieldExpr(kpPath.concat(['Same']));
		final nextPat: Expr = MacroStringTools.toFieldExpr(kpPath.concat(['Next']));
		// A comment the source wrote between `else` and the `switch` DECLINES the glue: the
		// `Same` layout has no channel for it and emitted the body without it, which is comment
		// LOSS, the one thing this writer fails closed on. Declining lets the arms below answer,
		// so the source's own two-line shape - comment included - is what survives. The `elseIf`
		// twin reaches the same end by a different road: its Same layout goes through
		// `buildElseIfCommentReflowLayout`, which either relocates the comment or restates the
		// layout with it. Generalising that machinery to a keyword-headed body is worth doing and
		// is NOT done here; refusing to glue is the fail-closed half of it.
		final lead: Null<Expr> = opts.kwLeadingExpr;
		final sameGuard: Expr = lead == null ? macro $knob == $samePat : macro $knob == $samePat && ($lead).length == 0;
		return [
			{ values: patterns, expr: sameLayoutExpr, guard: sameGuard },
			{ values: patterns.copy(), expr: nextLayoutExpr, guard: macro $knob == $nextPat }
		];
	}

	/**
	 * Build the `Keep`-policy layout Expr (ω-keep-policy) — runtime-dispatched
	 * between same and next layouts via the parser's `bodyOnSameLine` slot,
	 * with the block-ctor `blockLayoutExpr` route (ω-D8-keep-block-trivia) and
	 * the `elseIf == Next` override (ω-D8-keep-elseif-override).
	 */
	private static function buildBodyKeepLayout(
		bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts, layouts: WriterLowering.BodyLayouts,
		blockSplit: { tagged: Array<Expr>, untagged: Array<Expr> }, ifStmtPattern: Null<Expr>
	): Expr {
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		final bodyOnSameLineExpr: Null<Expr> = opts.bodyOnSameLineExpr;
		final sameLayoutExpr: Expr = layouts.sameLayoutExpr;
		final nextLayoutExpr: Expr = layouts.nextLayoutExpr;
		final blockLayoutExpr: Expr = layouts.blockLayoutExpr;
		final keepNextLayoutExpr: Expr = if (blockSplit.tagged.length > 0) {
			final cases: Array<Case> = [{ values: blockSplit.tagged, expr: blockLayoutExpr, guard: null }];
			cases.push({ values: [macro _], expr: nextLayoutExpr, guard: null });
			{ expr: ESwitch(bodyValueExpr, cases, null), pos: Context.currentPos() };
		}
		else
			nextLayoutExpr;
		// omega-else-switch: the `Keep` body policy is the path Pony's config takes
		// (`sameLine.elseBody` unset), so the knob has to be honoured HERE as well as
		// in `buildBodyCoreWrap` - otherwise `elseSwitch: "same"` would move nothing
		// on the very tree it was asked for. It is folded into the layout CHOICE rather
		// than added as two more switch arms: an arm carries a whole layout expression,
		// and four extra copies of these two overflowed a JVM class file (see
		// `buildElseSwitchTests`). `same` wins over the source's own line, `next` loses
		// to nothing - together they read as "the knob overrides `bodyOnSameLine`".
		final tests: { same: Null<Expr>, next: Null<Expr> } = buildElseSwitchTests(bp, opts);
		final esSame: Null<Expr> = tests.same;
		final esNext: Null<Expr> = tests.next;
		final keepBaseExpr: Expr = if (bodyOnSameLineExpr == null)
			sameLayoutExpr;
		else if (esSame == null)
			macro ($bodyOnSameLineExpr ? $sameLayoutExpr : $keepNextLayoutExpr);
		else
			macro ($esSame || (!$esNext && $bodyOnSameLineExpr) ? $sameLayoutExpr : $keepNextLayoutExpr);
		if (ifStmtPattern == null) return keepBaseExpr;
		final kpPath: Array<String> = ['anyparse', 'format', 'KeywordPlacement'];
		final kpNextPat: Expr = MacroStringTools.toFieldExpr(kpPath.concat(['Next']));
		final elseIfCases: Array<Case> = [{ values: [kpNextPat], expr: nextLayoutExpr, guard: null }];
		final elseIfSwitchForKeep: Expr = {
			expr: ESwitch(macro opt.elseIf, elseIfCases, keepBaseExpr),
			pos: Context.currentPos()
		};
		final outerKeepBodyCases: Array<Case> = [{ values: [ifStmtPattern], expr: elseIfSwitchForKeep, guard: null }];
		outerKeepBodyCases.push({ values: [macro _], expr: keepBaseExpr, guard: null });
		return { expr: ESwitch(bodyValueExpr, outerKeepBodyCases, null), pos: Context.currentPos() };
	}

	/**
	 * Build the core body-wrap Expr — the policy switch (Same/Next/FitLine),
	 * the block-ctor + elseIf outer overrides (bodySwitch), and the outer Keep
	 * dispatch (ω-keep-policy).
	 */
	private static function buildBodyCoreWrap(
		bp: BodyPolicyCtx, opts: WriterLowering.WrapBodyOpts, optFlag: Expr, layouts: WriterLowering.BodyLayouts, keepLayoutExpr: Expr,
		blockSplit: { tagged: Array<Expr>, untagged: Array<Expr> }, ifStmtPattern: Null<Expr>
	): Expr {
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		final sameLayoutExpr: Expr = layouts.sameLayoutExpr;
		final nextLayoutExpr: Expr = layouts.nextLayoutExpr;
		final blockLayoutExpr: Expr = layouts.blockLayoutExpr;
		final bpPath: Array<String> = ['anyparse', 'format', 'BodyPolicy'];
		final samePat: Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Same']));
		final nextPat: Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Next']));
		final fitPat: Expr = MacroStringTools.toFieldExpr(bpPath.concat(['FitLine']));
		final keepPat: Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Keep']));
		final policyCases: Array<Case> = [
			{ values: [samePat], expr: sameLayoutExpr, guard: null },
			{ values: [nextPat], expr: nextLayoutExpr, guard: null },
			{ values: [fitPat], expr: layouts.fitExpr, guard: null }
		];
		// omega-else-switch: folded into the policy SELECTOR rather than added as two more
		// outer arms. An arm carries a whole layout expression, and `writeHxIfStmtT` is the
		// largest method the writer emits: two arms here plus two in `buildBodyKeepLayout`
		// pushed it past the JVM's 16-bit branch offsets, and `jvm-portability` refused the
		// class with `Expecting a stackmap frame at branch target -1728`. As a substitution
		// on the policy value the same decision costs one ternary over two enum constants.
		// A `switch` body matches neither the block-ctor arms nor the `IfStmt` one, so it
		// still reaches this switch exactly as the prepended arms intended.
		final tests: { same: Null<Expr>, next: Null<Expr> } = buildElseSwitchTests(bp, opts);
		final esSame: Null<Expr> = tests.same;
		final esNext: Null<Expr> = tests.next;
		final elseSwitchPolicy: Expr = esSame == null ? optFlag : macro ($esSame ? $samePat : ($esNext ? $nextPat : $optFlag));
		// omega-bracket-body-glue: same substitution seam, same reason — a `[` body
		// that hugs its branch head is the `Same` layout, so it costs one ternary
		// here instead of a whole extra outer arm.
		final bracketTest: Null<Expr> = bp.buildBracketBodyGlueTest(opts.bracketBodyGlueArgs, opts.bodyTypePath, opts.bodyValueExpr);
		final effPolicy: Expr = bracketTest == null ? elseSwitchPolicy : macro ($bracketTest ? $samePat : $elseSwitchPolicy);
		final policySwitch: Expr = { expr: ESwitch(effPolicy, policyCases, sameLayoutExpr), pos: Context.currentPos() };
		final outerCases: Array<Case> = [];
		if (ifStmtPattern != null) {
			final kpPath: Array<String> = ['anyparse', 'format', 'KeywordPlacement'];
			final kpNextPat: Expr = MacroStringTools.toFieldExpr(kpPath.concat(['Next']));
			final elseIfCases: Array<Case> = [{ values: [kpNextPat], expr: nextLayoutExpr, guard: null }];
			// omega-elseif-comment-reflow: the glued arm is the ONE place the knob
			// acts - `layouts.elseIfSameLayoutExpr` is `sameLayoutExpr` itself
			// off-path, and the gated variant on it.
			final elseIfSwitch: Expr = {
				expr: ESwitch(macro opt.elseIf, elseIfCases, layouts.elseIfSameLayoutExpr),
				pos: Context.currentPos()
			};
			outerCases.push({ values: [ifStmtPattern], expr: elseIfSwitch, guard: null });
		}
		if (blockSplit.untagged.length > 0) outerCases.push({ values: blockSplit.untagged, expr: sameLayoutExpr, guard: null });
		if (blockSplit.tagged.length > 0) outerCases.push({ values: blockSplit.tagged, expr: blockLayoutExpr, guard: null });
		final bodySwitch: Expr = if (outerCases.length == 0)
			policySwitch
		else {
			outerCases.push({ values: [macro _], expr: policySwitch, guard: null });
			{ expr: ESwitch(bodyValueExpr, outerCases, null), pos: Context.currentPos() };
		};
		// ω-keep-policy: `Keep` takes precedence over block-ctor and
		// elseIf overrides — "keep" means preserve source, so the
		// policy-driven layout shortcuts do not apply. Route the whole
		// wrap through `keepLayoutExpr` when `opt.<flag> == Keep`.
		final outerKeepCases: Array<Case> = [{ values: [keepPat], expr: keepLayoutExpr, guard: null }];
		return { expr: ESwitch(optFlag, outerKeepCases, bodySwitch), pos: Context.currentPos() };
	}

	/**
	 * Wrap the core body Expr with the after-trail / before-leading comment
	 * forced-Next-layout (ω-issue-316-then-trail / ω-556-then-body-leading-
	 * comment). Returns `coreWrapExpr` unchanged when neither slot was
	 * forwarded.
	 *
	 * The forced-Next layout nests the body one level in - right for a BARE
	 * body (`if (c) // n` + newline + `resize(1);`), wrong for a BLOCK body,
	 * which already owns its interior indent through its own `{ }` Nest and
	 * so would be pushed a whole level right. `blockSplit` carries the body
	 * enum's block-ctor patterns (the same ones `bodyPolicyWrap` routes to
	 * `blockLayoutExpr`), which selects the un-nested arm - the shape the
	 * fork emits for `} else // comment` + newline `{`.
	 */
	private static function wrapBodyAfterTrail(
		opts: WriterLowering.WrapBodyOpts, coreWrapExpr: Expr, writeCall: Expr, blockSplit: { tagged: Array<Expr>, untagged: Array<Expr> }
	): Expr {
		final afterTrailExpr: Null<Expr> = opts.afterTrailExpr;
		final beforeLeadingExpr: Null<Expr> = opts.beforeLeadingExpr;
		if (afterTrailExpr == null && beforeLeadingExpr == null) return coreWrapExpr;
		// Runtime guard: fire the forced Next-layout iff there is an
		// after-trail comment OR at least one own-line leading comment.
		final afterTrailRt: Expr = afterTrailExpr ?? macro null;
		final beforeLeadingRt: Expr = beforeLeadingExpr ?? macro ([]: Array<String>);
		final blockPatterns: Array<Expr> = blockSplit.tagged.concat(blockSplit.untagged);
		final isBlockBodyExpr: Expr = blockPatterns.length == 0 ? macro false : {
			expr: ESwitch(opts.bodyValueExpr, [{ values: blockPatterns, expr: macro true, guard: null }], macro false),
			pos: Context.currentPos()
		};
		return macro {
			final _at556: Null<String> = $afterTrailRt;
			final _bl556: Array<String> = $beforeLeadingRt;
			if (_at556 == null && _bl556.length == 0)
				$coreWrapExpr;
			else {
				final _outer556: Array<anyparse.core.Doc> = [];
				if (_at556 != null) _outer556.push(trailingCommentDocVerbatim(_at556, opt));
				final _inner556: Array<anyparse.core.Doc> = [_dhl()];
				for (_ci556 in 0..._bl556.length) {
					_inner556.push(leadingCommentDocRun(_bl556, _ci556, opt));
					_inner556.push(_dhl());
				}
				_inner556.push($writeCall);
				final _body556: anyparse.core.Doc = _dc(_inner556);
				_outer556.push($isBlockBodyExpr ? _body556 : _dn(_cols, _body556));
				_dc(_outer556);
			}
		};
	}

	/**
	 * Wrap the body Expr with the ω-issue-168 Allman-indent-for-ctor override
	 * (`@:fmt(bodyAllmanIndentForCtor(...))`). Returns `wrapExpr` unchanged
	 * when no args.
	 */
	private static function wrapBodyAllman(opts: WriterLowering.WrapBodyOpts, wrapExpr: Expr, writeCall: Expr): Expr {
		final bodyAllmanIndentArgs: Null<Array<String>> = opts.bodyAllmanIndentArgs;
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		if (bodyAllmanIndentArgs == null) return wrapExpr;
		if (bodyAllmanIndentArgs.length != 2)
			Context.fatalError(
				'WriterLowering: bodyPolicyWrap bodyAllmanIndentArgs requires (ctorName, optField), got ${bodyAllmanIndentArgs.length}'
				+ ' args',
				Context.currentPos()
			);
		final ctorName: String = bodyAllmanIndentArgs[0];
		final optAccess: Expr = optFieldAccess(bodyAllmanIndentArgs[1]);
		return macro {
			final _bodyForAllman: anyparse.core.Doc = $writeCall;
			if (
				$optAccess && Type.enumConstructor($bodyValueExpr) == $v{ctorName}
				&& anyparse.format.wrap.WrapList.flatLength(_bodyForAllman) == -1
			)
				_dn(_cols, _dc([_dhl(), _bodyForAllman]))
			else
				$wrapExpr;
		};
	}

	/**
	 * Wrap the body Expr with the ω-fnbody-meta-block-glue override — a
	 * meta-wrapped block body (`@:meta { … }`) routes to the glued
	 * `sameLayoutExpr`. Returns `finalWrapExpr` unchanged when no args.
	 *
	 */
	private static function wrapBodyMetaBlockGlue(opts: WriterLowering.WrapBodyOpts, finalWrapExpr: Expr, sameLayoutExpr: Expr): Expr {
		final metaBlockGlueArgs: Null<Array<String>> = opts.metaBlockGlueArgs;
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		if (metaBlockGlueArgs == null) return finalWrapExpr;
		if (metaBlockGlueArgs.length != 3)
			Context.fatalError(
				'WriterLowering: bodyPolicyWrap metaBlockGlueArgs requires (exprBodyCtor, metaCtor, blockCtor), got '
				+ '${metaBlockGlueArgs.length} args',
				Context.currentPos()
			);
		final exprBodyCtor: String = metaBlockGlueArgs[0];
		final metaCtor: String = metaBlockGlueArgs[1];
		final blockCtor: String = metaBlockGlueArgs[2];
		return macro {
			final _mbgIsMetaBlock: Bool = if (Type.enumConstructor($bodyValueExpr) != $v{exprBodyCtor})
				false
			else {
				var _mbgInner: Dynamic = Type.enumParameters($bodyValueExpr)[0];
				var _mbgSawMeta: Bool = false;
				while (Type.enumConstructor(_mbgInner) == $v{metaCtor}) {
					_mbgSawMeta = true;
					_mbgInner = Reflect.field(Type.enumParameters(_mbgInner)[0], 'expr');
				}
				_mbgSawMeta && Type.enumConstructor(_mbgInner) == $v{blockCtor};
			};
			_mbgIsMetaBlock ? $sameLayoutExpr : $finalWrapExpr;
		};
	}

	/**
	 * Wrap the `FitLine` layout Expr with the ω-loop-body-if-else-next gate: a
	 * loop body that is an `if` carrying an `else` takes the `Next` layout
	 * instead of the FitLine answer.
	 *
	 * The three names arrive declaratively from
	 * `@:fmt(loopBodyIfElseNext('<optField>', '<ifCtor>', '<elseField>'))` so the
	 * macro stays format-neutral, and the shape question itself is asked at
	 * runtime by `anyparse.format.LoopBodyShape.isIfWithElse` — the body value is
	 * a trivia-synthesised enum, which no non-macro module may name.
	 *
	 * The gate looks at the CHILD's shape, not at a sibling field, and that is
	 * the whole difference from `fitLineIfWithElse`: an `if` WITHOUT an `else`
	 * keeps gluing to the loop header, because `for (x in xs) if (c) f(x);` is a
	 * deliberate idiom. A body policy cannot express that distinction —
	 * `forBody: next` moves the guard idiom under the header too, which is why
	 * this is a knob and not a config value.
	 *
	 * Returns `fitInnerExpr` unchanged when no args (every non-loop body field).
	 */
	private static function wrapLoopBodyIfElseNext(opts: WriterLowering.WrapBodyOpts, fitInnerExpr: Expr): Expr {
		final args: Null<Array<String>> = opts.loopBodyIfElseArgs;
		if (args == null) return fitInnerExpr;
		if (args.length != 3)
			Context.fatalError(
				'WriterLowering: bodyPolicyWrap loopBodyIfElseArgs requires (optField, ifCtor, elseField), got ${args.length} args',
				Context.currentPos()
			);
		final flagAccess: Expr = { expr: EField(macro opt, args[0]), pos: Context.currentPos() };
		final ifCtor: String = args[1];
		final elseField: String = args[2];
		final bodyValueExpr: Expr = opts.bodyValueExpr;
		return macro $flagAccess && anyparse.format.LoopBodyShape.isIfWithElse($bodyValueExpr, $v{ifCtor}, $v{elseField})
			? _dn(_cols, _dc([_dhl(), _body]))
			: $fitInnerExpr;
	}

	/**
	 * Wrap a body Expr in the conditional value-expr `Nest(_cols, body)` per
	 * `@:fmt(indentValueIfCtor('<ctor>', '<optField>'))` — the ω-issue-257
	 * return-same-indent-value-expr / ω-value-if-block-body-no-indent rule.
	 * Returns `bodyExpr` unchanged when `ifExprIndentArgs` is null.
	 */
	private static function wrapIfExprNest(bodyExpr: Expr, ifExprIndentArgs: Null<Array<String>>, bodyValueExpr: Expr): Expr {
		if (ifExprIndentArgs == null) return bodyExpr;
		final ifCtorName: String = ifExprIndentArgs[0];
		final ifOptAccess: Expr = optFieldAccess(ifExprIndentArgs[1]);
		// ω-value-if-block-body-no-indent: a value-position `if (…) { … }`
		// whose then-branch is a real `BlockExpr` already owns its body indent
		// via the block's `{ }` Nest. Mirror the fork `Indenter`
		// `case Kwd(KwdIf): … case Block: continue;` arm — a block-typed if-body
		// makes the indenter SKIP the value-expr indent step (before the
		// knob/field-level check). The then-branch lives at
		// `Reflect.field(enumParameters(value)[0], 'thenBranch')` (same
		// `enumParameters[0]` + `Reflect.field` descent as the `metaBlockGlue`
		// precedent); Trivia mode wraps it in `Trivial<HxExpr>` (unwrap via
		// `node`), Plain mode holds the raw enum. Gated on `ifCtorName ==
		// 'IfExpr'` so non-if entries stay byte-identical.
		return macro {
			final _bIfn: anyparse.core.Doc = $bodyExpr;
			var _ifBlockBody: Bool = false;
			if ($v{ifCtorName} == 'IfExpr' && Type.enumConstructor($bodyValueExpr) == 'IfExpr') {
				var _then: Dynamic = Reflect.field(Type.enumParameters($bodyValueExpr)[0], 'thenBranch');
				if (Reflect.hasField(_then, 'node')) _then = Reflect.field(_then, 'node');
				_ifBlockBody = Type.enumConstructor(_then) == 'BlockExpr';
			}
			$ifOptAccess && Type.enumConstructor($bodyValueExpr) == $v{ifCtorName} && !_ifBlockBody ? _dn(_cols, _bIfn) : _bIfn;
		};
	}

	/**
	 * The gap before a body at an `arrowValueIfReflowSite`: a soft `Line(" ")` the enclosing `Group`
	 * may flatten, or the bare `Line("\n")` every other site keeps.
	 *
	 * The soft form is additionally refused at RUNTIME for a body that already breaks
	 * (`WrapList.flatLength(body) < 0`) -- a block, a `switch`, a multi-line literal. Such a chain can
	 * never be one line, so softening buys nothing and costs the layout the policy gives it: the
	 * construct would glue to the `if` / `else` head and the author"s vertical shape would be gone.
	 * The predicate is the one `measureItems` and `arrowBodyIsBrokenIfElse` already ask, and it reads
	 * the BUILT doc, so it covers every construct without enumerating ctor names.
	 */
	private static function valueIfGapExpr(softGap: Bool, bodyRef: Expr): Expr {
		return softGap ? macro (_vifFit && anyparse.format.wrap.WrapList.flatLength($bodyRef) >= 0 ? _dl() : _dhl()) : macro _dhl();
	}

	/**
	 * ω-issue-316-curly-both — parallel to `collectBlockCtorPatterns`, but
	 * partitions the block-ctor branches by whether the branch carries a
	 * `@:fmt(leftCurly)` flag. Consumed by `bodyPolicyWrap` so block-ctor
	 * bodies (`BlockStmt(_)`) can honour `opt.leftCurly:BracePlacement`
	 * at the body-placement override — tagged patterns emit a
	 * leftCurly-aware separator, untagged patterns fall back to the
	 * pre-slice single-space layout.
	 *
	 * ω-issue-303-array-comprehension — only genuine curly-brace block
	 * bodies (`{ … }`, lead `{`) are partitioned here. Bracket-delimited
	 * list ctors (`[ … ]`, lead `[` — `HxExpr.ArrayExpr`, incl. array
	 * comprehensions `[for (x in xs) …]`) match `isBlockCtorBranch`'s
	 * shape (lead + trail + single `Star`) but are VALUE expressions, not
	 * block bodies: they must obey the resolved body policy
	 * (`returnBody` / `returnBodySingleLine`), not the unconditional
	 * keyword-glue the block-split override forces. Excluding them here
	 * lets `bodyPolicyWrap`'s `bodySwitch` fall through to the policy
	 * switch — mirroring fork `MarkSameLine.shouldReturnBeSameLine`, which
	 * routes a single-line `return [for …];` value to
	 * `sameLine.returnBodySingleLine` instead of force-gluing it. The
	 * single-vs-multi-line distinction is handled downstream by the
	 * policy's own layout (`Same` width-probe / `Next` break / `Keep`
	 * source-shape), so no source-line probe is needed at this point.
	 */
	private static function collectBlockCtorPatternsByLeftCurly(
		bp: BodyPolicyCtx, bodyTypePath: String
	): { tagged: Array<Expr>, untagged: Array<Expr> } {
		final rule: Null<ShapeNode> = bp.shape.rules[bodyTypePath];
		if (rule == null || rule.kind != Alt) return { tagged: [], untagged: [] };
		final tagged: Array<Expr> = [];
		final untagged: Array<Expr> = [];
		for (branch in rule.children) if (isCurlyBlockCtorBranch(branch)) {
			final pattern: Expr = bp.branchCtorPattern(bodyTypePath, branch);
			if (branch.fmtHasFlag('leftCurly'))
				tagged.push(pattern);
			else
				untagged.push(pattern);
		}
		return { tagged: tagged, untagged: untagged };
	}

}

/**
 * The build state the body-policy family reads, bundled once per
 * `WriterLowering` instance.
 *
 * The four function fields are shape / comment helpers that stayed in
 * `WriterLowering` because most of their callers did; handing them over as
 * fields is what keeps every member here static.
 */
typedef BodyPolicyCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final ctx: LoweringCtx;
	final branchCtorPattern: (bodyTypePath:String, branch:ShapeNode) -> Expr;
	final buildBracketBodyGlueTest: (args:Null<Array<String>>, bodyTypePath:Null<String>, bodyValueExpr:Expr) -> Null<Expr>;
	final findCtorPattern: (bodyTypePath:String, ctorName:String) -> Null<Expr>;
	final foldSsbTrailingComment: (base:Expr, ssbTrailCommentExpr:Null<Expr>) -> Expr;
}
#end
