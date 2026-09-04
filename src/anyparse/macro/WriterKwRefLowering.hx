package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.WriterPolicyLowering.*;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.MacroNames.*;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W helpers - the keyword-plus-Ref enum branch family.
 *
 * Builds the generated writer body for the two enum-branch shapes that are
 * a KEYWORD and (at most) one referenced sub-rule: the zero-argument
 * literal / keyword branches (`lowerLitKwBranch`, Cases 0-2) and the
 * single-`Ref` branch (`lowerKwRefBranch`, Case 3) - `HxStmt.If`,
 * `HxStmt.Return`, `HxExpr.Switch` and their kin. The bulk of it is the
 * Case 3 body: the keyword trailing space, the lead / inner / trail
 * assembly, the two wrap shapes (hard-flatten and source-newline), the
 * optional-semicolon and trail-opt shape gates, and the sub-struct probes
 * that ask what the referenced rule STARTS with before choosing any of it.
 *
 * Split out of `WriterLowering` for size. Both entries come from
 * `lowerEnumBranch` and nothing else reaches in.
 *
 * Every member is static and the build state arrives as one `KwRefCtx`
 * bundle, built once in `WriterLowering`'s constructor. Note the shape of
 * that bundle's last field: the family reaches the body-policy wrap, so it
 * carries `WriterBodyPolicyLowering`'s OWN bundle rather than a callback -
 * the dependency between the two families is then written down as a type,
 * not hidden in a closure.
 *
 * The GENERATED-code surface is the real contract: the parts splice
 * `value`, `opt` and the `_d*` Doc wrappers `WriterCodegen` emits on the
 * generated class.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterLoweringSupport, anyparse.macro.WriterPolicyLowering)
final class WriterKwRefLowering {

	/**
	 * Lit / kw zero-or-one-arg branches (Cases 0/1/2): zero-arg kw
	 * (`@:kw` no children), zero-arg single lit, and the multi-lit Bool
	 * (`true`/`false` pair). Returns the matched Doc Expr, or null when
	 * the branch is none of these (the dispatcher then falls through to
	 * the Star / Ref / wrap shapes).
	 */
	private static function lowerLitKwBranch(kw: KwRefCtx, c: WriterLowering.LowerBranchCtx): Null<Expr> {
		final branch: ShapeNode = c.branch;
		final children: Array<ShapeNode> = branch.children;
		final litList: Null<Array<String>> = branch.annotations[AnnotationKeys.LIT_LIT_LIST];
		final kwLead: Null<String> = branch.annotations[AnnotationKeys.KW_LEAD_TEXT];
		// ---- Case 0: zero-arg kw ----
		if (kwLead != null && children.length == 0 && litList == null) {
			final trail: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
			final text: String = kwLead + (trail ?? '');
			return macro _dt($v{text});
		}
		// ---- Case 1: zero-arg lit ----
		if (litList != null && litList.length == 1 && children.length == 0) return macro _dt($v{litList[0]});
		// ---- Case 2: multi-lit Bool ----
		if (litList == null || litList.length <= 1 || children.length != 1) return null;
		final trueLit: String = litList[0];
		final falseLit: String = litList[1];
		return macro if (_v0)
			_dt($v{trueLit})
		else
			_dt($v{falseLit});
	}

	/**
	 * Case 3 — single-arg Ref branch (kw-led `T(value:Ref)`): the largest
	 * enum-branch shape. Resolves the sub-call opt frame, the bodyPolicy /
	 * indent wrap, the body-source-capture gate, the kw / lead / trail
	 * parts, the `@:wrap` paren shape, and the conditional-marker scope.
	 *
	 */
	@:access(anyparse.macro.WriterBodyPolicyLowering)
	private static function lowerKwRefBranch(kw: KwRefCtx, c: WriterLowering.LowerBranchCtx): Expr {
		final branch: ShapeNode = c.branch;
		final typePath: String = c.typePath;
		final hasPratt: Bool = c.hasPratt;
		final argNames: Array<String> = c.argNames;
		final children: Array<ShapeNode> = branch.children;
		final refName: String = children[0].annotations.get(AnnotationKeys.BASE_REF);
		final subFn: String = kw.writeFnFor(refName);
		final isSelfRef: Bool = simpleName(refName) == simpleName(typePath);
		// ω-issue-423-mech-a: when the kw-Ref ctor itself carries
		// `@:fmt(propagateExprPosition)` (e.g. `HxStatement.ReturnStmt`,
		// `HxExpr.ReturnExpr`), wrap the sub-call's opt arg in
		// `_setExprPosition` so the `value:HxExpr` descendant sees the
		// expression-position frame. Idempotent — already-true opt
		// passes through.
		// ω-value-yielded-if-tail-barrier (macro-block clear): when this kw-
		// Ref ctor carries `@:fmt(clearExprPosition)` (HxExpr.MacroExpr), the
		// sub-call's opt arg is wrapped in `_clearExprPosition` ONLY when the
		// operand is a block (`macro { … }`) — gated at runtime via the
		// generated typed `operandIsBlockExpr` predicate, so a non-block
		// `macro <expr>` (e.g. `macro if (1) 2 else 3`) stays transparent and
		// keeps its inherited expression-position frame. The block's reified
		// statements revert to statement-position body policy (dropping the
		// SI-2 block-tail frame). A grammar carrying the meta must provide
		// the marker classes. Idempotent helper; allocation-free when
		// already cleared.
		// ω-string-interp-noformat-flat: the interpolation `${expr}` body
		// (`@:fmt(captureSource(...))` ctor — `HxStringSegment.Block`)
		// threads `_setChainModeOverride(opt, NoWrap)` into the sub-call
		// so the descendant chain emit collapses its cascade to `NoWrap`
		// — an inner `+`/`-`/`&&` chain stays flat regardless of the
		// `opAddSubChain`/`opBoolChain` config (the fork never wraps
		// expressions inside interpolations). Reuses the existing
		// chain-override channel (no new opt field): `_setChainModeOverride`
		// swaps `opBoolChainWrap`/`opAddSubChainWrap` to a degenerate
		// `{rules: [], defaultMode: NoWrap}` cascade. `NoWrap` is distinct
		// from the `FillLineWithLeadingBreak` cond-wrap mode, so the
		// chain dispatch's `_condWrapForced` gate (== FLWLB) stays false —
		// no interaction with the inc6 chain-unwrap path. The HardFlatten
		// wrap at `bodyExpr` (below) covers width-conditional breaks +
		// non-chain Groups; this NoWrap channel covers the unconditional
		// `onePerLine` chain shape whose `Line('\n')` flat form would
		// survive HardFlatten. Composes with `propagateExpr`. Gated on the
		// `captureSource` flag alone (Haxe-only today, and `HxModuleWriteOptions`
		// carries the chain-override channel) — mirrors the `@:fmt(condWrap)`
		// site (L3592), which calls `_setChainModeOverride` ungated for the
		// same reason: the flag's presence implies the grammar's channel.
		// ω-expr-paren-in-condition (cond F2): the `ParenExpr`
		// (`@:fmt(expressionParenHardFlatten)`) inner chain is HardFlatten-
		// collapsed by default. When this paren sits inside a condition
		// (`opt._parenInCondition`, set at the `@:fmt(condWrap)` site) AND the
		// user configured `expressionWrapping` to fillLine, thread the fillLine
		// mode as a `_chainModeOverride` into the paren's OWN inner writeCall so
		// its chain wraps fillLine — and CLEAR `_parenInCondition` so a nested
		// expr paren inside this one does not re-trigger. Runtime-gated so a
		// standalone expr paren (flag false, e.g. `expression_paren_wrapping`)
		// is byte-identical (`opt` passed through unchanged).
		// ω-fieldlevel-var-value-expr-indent: when this kw-Ref ctor carries
		// `@:fmt(propagateFieldLevelVar)` (class-member `var`/`final` —
		// `HxClassMember.VarMember` / `FinalMember`), wrap the sub-call's opt
		// arg in `_setFieldLevelVar` so the descendant `HxVarDecl.init` write
		// forces the `indentComplexValueExpressions` value-expr indent for an
		// if/switch/try value (fork's `Indenter.isFieldLevelVar`). Local-var
		// inits route through `HxStatement.VarStmt` / `HxExpr.VarExpr` — never
		// this ctor — so the flag stays false there and they remain
		// knob-gated. Idempotent helper; allocation-free when already set.
		// ω-keep-kw-newline (increment 1b): when this VarStmt-family ctor
		// captured a `var`→head newline (the synth `kwNewline:Bool` slot),
		// thread `_setVarKwNewline(opt, true)` into the inner `decl`
		// writeCall so the `HxVarDecl` multiVar fold reproduces the head
		// break under `WrapMode.Keep`. The helper is idempotent and
		// allocation-free when the flag matches, so a same-line `var x = …`
		// (kwNewline false) leaves `opt` unchanged — byte-inert. Trivia-
		// only (the slot exists only on bearing trivia ctors); plain mode
		// leaves `kwNewlineExpr` null and the head stays glued to `var `.
		final kwNewlineExpr: Null<Expr> = kw.ctx.trivia && kw.isTriviaBearing(typePath)
			? altSlotAccess(branch, children.length, argNames, KwNewline)
			: null;
		final ctorOptArg: Expr = kwRefCtorOptArg(kw, c, kwNewlineExpr);
		final subCall: Expr = if (isSelfRef && hasPratt)
			{ expr: ECall(macro $i{subFn}, [macro $i{argNames[0]}, ctorOptArg, macro -1]), pos: Context.currentPos() }
		else
			{ expr: ECall(macro $i{subFn}, [macro $i{argNames[0]}, ctorOptArg]), pos: Context.currentPos() };

		// ω-return-body: ctor-level `@:fmt(bodyPolicy(...))` on a kw-led
		// single-Ref branch (e.g. `HxStatement.ReturnStmt(value:HxExpr)`)
		// wraps the sub-call through `bodyPolicyWrap` so the kw→body
		// separator is runtime-switchable. The wrap supplies the
		// separator (`_dt(' ')` for `Same`, `_dn(_cols, _dhl + body)`
		// for `Next`, etc.), so the kw must drop its trailing space —
		// the existing `subStructStartsWithBodyPolicy` path covers the
		// sub-struct case (`HxStatement.IfStmt(stmt:HxIfStmt)` where the
		// `bodyPolicy` flag lives on a field of `HxIfStmt`); this new
		// path covers the direct-Ref case where no wrapper struct hosts
		// the field.
		// ω-issue-257-else-in-return-switch: `bodyPolicy(...)` accepts
		// 1 or 2 flag names. Two-arg form dispatches between the
		// stmt-position knob (arg 0) and expr-position knob (arg 1)
		// at runtime via `opt._inExprPosition`. Mirrors the dual-flag
		// dispatch in `triviaTryparseStarExpr` for case-body Stars.
		final ctorBodyPolicy: { stmt: Null<String>, expr: Null<String> } = readBodyPolicyDual(branch);
		final ctorBodyPolicyFlag: Null<String> = ctorBodyPolicy.stmt;
		final ctorBodyPolicyExprFlag: Null<String> = ctorBodyPolicy.expr;
		// ω-returnbody-widthaware: read the parameterless `@:fmt(widthAware)`
		// flag at the same call site so the runtime IfFirstLineExceeds
		// wrap is opt-in per ctor (currently `HxStatement.ReturnStmt`).
		final ctorWidthAware: Bool = branch.fmtHasFlag('widthAware');
		// ω-return-body-single-line: read the
		// `@:fmt(bodyPolicySingleLine('<flag>', '<multiCtor>'...))` knob
		// (currently `HxStatement.ReturnStmt`) so `bodyPolicyWrap` can split
		// the policy between single-line and multi-line value shapes. Arg 0
		// is the single-line flag name; the remaining args name the value
		// ctors treated as multi-line (control-flow / block), which keep the
		// base `returnBody` policy.
		final ctorSingleLineArgs: Null<Array<String>> = branch.fmtReadStringArgs('bodyPolicySingleLine');
		final ctorSingleLineFlag: Null<String> = ctorSingleLineArgs == null ? null : ctorSingleLineArgs[0];
		final ctorSingleLineMultiCtors: Null<Array<String>> = ctorSingleLineArgs?.slice(1);
		// ω-issue-257-firstline: when the ctor is the bodyPolicy-kw-Ref
		// shape (predicate matches `HxStatement.ReturnStmt`) and trivia
		// mode + bearing typePath, the synth ctor carries a positional
		// `bodyOnSameLine:Bool` arg captured by the parser. Forward its
		// access expression so `bodyPolicyWrap`'s `Keep` branch can
		// dispatch source-shape-aware. The arg index follows the same
		// ordering as `TriviaTypeSynth.buildEnumCtor`: closeTrailing
		// (+ openTrailing/trailingBlankBefore/trailingLeading) →
		// trailPresent → sourceText → bodyOnSameLine → postfix
		// closeTrailing. Plain mode keeps `null` and the wrap degrades
		// to `sameLayoutExpr` (no Keep slot — falls through the same
		// width-aware path as `Same`).
		final bodyOnSameLineExpr: Null<Expr> = kw.ctx.trivia && kw.isTriviaBearing(typePath)
			? altSlotAccess(branch, children.length, argNames, BodyPolicyKw)
			: null;
		// omega-paren-wrap-source-newline: ctors carrying
		// @:fmt(captureWrapOpenNewline) on a single-Ref @:wrap branch grow
		// a positional `wrapOpenNewline:Bool` arg in the synth pair (see
		// TriviaTypeSynth.buildEnumCtor push order). Compute its access
		// expression here so the @:wrap shape below can switch break-mode
		// shape based on source-shape capture. Plain mode (or trivia-mode
		// without the opt-in flag) leaves `wrapOpenNewlineExpr` null and
		// the shape falls back to the existing unconditional glue.
		final wrapOpenNewlineExpr: Null<Expr> = kw.ctx.trivia && kw.isTriviaBearing(typePath)
			? altSlotAccess(branch, children.length, argNames, WrapOpenNewline)
			: null;
		// ω-issue-257-firstline regression-fix: forward `indentArgs` to
		// `bodyPolicyWrap` so its `indentObjGuardedNext` rule fires for
		// the ctor-level `Next`/`Keep`-bodyOnSameLine-false fallback path
		// when the body is an ObjectLit and `indentObjectLiteral=false`.
		// Without forwarding, the `Keep`-route nextLayoutExpr always
		// emits `_dn(_cols, [_dhl, body])` and over-indents `{` by one
		// step (`return\n\t\t\t{` instead of `return\n\t\t{` for
		// `indentObjectLiteral=false` configs). The post-process wrap
		// below at `indentWrapped` keeps overriding the SAME-policy case
		// when `indentObjectLiteral=true`; the two layers are orthogonal
		// — post-process handles `Same+true`, bodyPolicyWrap handles
		// `Next+false` and `Keep+false`. Reads the meta once and reuses
		// the result for both layers.
		//
		// ω-issue-257-return-same-indent-value-expr: split the
		// `indentValueIfCtor` entries on this ctor by arity:
		//   - 3-arg form `(ctorName, optField, leftCurlyField)` →
		//     `indentArgs`, fed to `bodyPolicyWrap.indentObjGuardedNext`
		//     (Next/Keep+false ObjectLit path) AND post-hoc
		//     `indentWrapped` (Same+true ObjectLit path). At most one
		//     entry per ctor.
		//   - 2-arg form `(ctorName, optField)` → `ifExprIndentArgs`,
		//     fed to `bodyPolicyWrap` as the new `ifExprIndentArgs`
		//     param which conditionally wraps the writeCall in
		//     `Nest(_cols, …)` ONLY in the Same flat-path (so multi-
		//     line IfExpr-as-value picks up `+cols` on its internal
		//     else-branch hardlines, mirroring the struct-field
		//     `HxVarDecl.init` semantic). At most one entry per ctor.
		// Mirrors the multi-entry pattern in `maybeIndentValueIfCtor`
		// for struct-field path.
		final indentEntries: { indentArgs: Null<Array<String>>, ifExprIndentArgs: Null<Array<String>> } = kwRefIndentEntries(branch);
		final indentArgs: Null<Array<String>> = indentEntries.indentArgs;
		final ifExprIndentArgs: Null<Array<String>> = indentEntries.ifExprIndentArgs;
		final policyWrapped: Expr = ctorBodyPolicyFlag != null
			? WriterBodyPolicyLowering.bodyPolicyWrap(kw.bodyPolicy, {
				flagName: ctorBodyPolicyFlag,
				exprFlagName: ctorBodyPolicyExprFlag,
				writeCall: subCall,
				bodyValueExpr: macro $i{argNames[0]},
				bodyTypePath: refName,
				hasElseIf: false,
				elseFieldName: null,
				bodyOnSameLineExpr: bodyOnSameLineExpr,
				indentObjArgs: indentArgs,
				widthAware: ctorWidthAware,
				ifExprIndentArgs: ifExprIndentArgs,
				singleLineFlagName: ctorSingleLineFlag,
				singleLineMultiCtors: ctorSingleLineMultiCtors,
				kwNewlineExpr: kwNewlineExpr
			})
			: subCall;

		// Build the body Doc: indentValueIfCtor ObjectLit-indent override +
		// captureSource verbatim/HardFlatten gate — see kwRefBodyExpr.
		final bodyExpr: Expr = kwRefBodyExpr(kw, c, policyWrapped, subCall, indentArgs);

		// Resolve the kw-trailing-space behaviour (strip vs runtime-switched
		// space) and assemble the kw / lead / body / trail parts — see
		// kwRefKwTrailSpace and kwRefParts for the per-flag detail.
		final kwTrail: { strip: Bool, space: Null<Expr> } = kwRefKwTrailSpace(kw, c, refName, ctorBodyPolicyFlag);
		final parts: Array<Expr> = kwRefParts(kw, c, bodyExpr, kwTrail.space, kwTrail.strip);
		// ω-switch-after-paren: a `@:fmt(switchWrapSpace)` `@:wrap('(', ')')`
		// ctor (`HxExpr.ParenExpr`) spaces the open `(` when its inner
		// expression is a `switch` — fork emits `( switch x {`, close `)`
		// tight to the switch's `}`. The space is the switch keyword's LEADING
		// gap, gated on `opt.switchKwLeadingSpace` (the fork's
		// `whitespace.switchPolicy` `before` / `around`); with the default (or
		// `after` / `none`) the `(` stays tight. The inner is a single Ref, so
		// its paired/plain value is `argNames[0]` directly (NOT Trivial<…>-
		// wrapped — see breakAfterLeadOnOverflowWrap). Appending the
		// conditional space to the lead Doc lands it after `(` in the flat wrap
		// shape (the only shape a subject-fits switch takes; the switch's own
		// `{ }` supplies the internal breaks). Runtime-gated on both the policy
		// and the inner ctor so a non-switch paren (`(a + b)`) and a non-`around`
		// config stay byte-identical; the flag scopes it off `HxType.Parens`.
		if (branch.fmtHasFlag('switchWrapSpace') && parts.length == 3) {
			final innerAccess: Expr = macro $i{argNames[0]};
			final origLead: Expr = parts[0];
			final switchGuard: Expr = macro opt.switchKwLeadingSpace && {
				final _sc: String = Type.enumConstructor(cast $innerAccess);
				_sc == 'SwitchExpr' || _sc == 'SwitchExprBare';
			};
			parts[0] = macro _dc([$origLead, $switchGuard ? _dt(' ') : _de()]);
		}
		// ω-paren-wrap-break: `@:wrap(open, close)` ctor (no kw, both lead
		// and trail set) — the Group/hardline-before-close shape is built in
		// kwRefWrapShape; null when not the wrap shape (falls through below).
		final wrapDoc: Null<Expr> = kwRefWrapShape(kw, c, parts, wrapOpenNewlineExpr);
		return wrapDoc ?? kwRefFinalDoc(kw, c, parts);
	}

	/**
	 * `@:wrap(open, close)` paren shape (Case 3 sub-branch): a no-kw
	 * branch with both lead and trail set renders as a Group whose break
	 * shape lands the close delimiter on its own line. Returns the wrap
	 * Doc Expr, or null when the branch is not the wrap shape (the caller
	 * then falls through to the plain Case-3 concat).
	 */
	private static function kwRefWrapShape(
		kw: KwRefCtx, c: WriterLowering.LowerBranchCtx, parts: Array<Expr>, wrapOpenNewlineExpr: Null<Expr>
	): Null<Expr> {
		final branch: ShapeNode = c.branch;
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final kwLead: Null<String> = branch.annotations[AnnotationKeys.KW_LEAD_TEXT];
		// ω-paren-wrap-break: `@:wrap(open, close)` enum ctor (no kw,
		// both lead and trail set) renders as a Group whose break
		// shape adds a hardline before the close delimiter, so a
		// multi-line inner Doc lands the close on its own line at
		// the outer indent — matches haxe-formatter's
		// `return !(\n\t\t\t...\n\t\t)` shape on issue_187_oneline.
		// Gated at runtime on `WrapList.startsWithHardline(_inner)`
		// so the close-on-own-line behavior is symmetric with the
		// open-with-hardline behavior of the inner Doc:
		//  - inner with leading hardline (e.g. `BinaryChainEmit`
		//    `OnePerLine` shape — every operand on its own line):
		//    close goes on its own line.
		//  - inner without leading hardline (e.g.
		//    `OnePerLineAfterFirst` keeps items[0] inline): close
		//    stays glued to the last item — matches the
		//    default-cascade `((items[0]\n\t…\n\titems[n-1]))`
		//    shape on issue_187_multi_line_wrapped_assignment.
		// The flat shape stays byte-identical to the pre-slice
		// `lead + inner + trail` concat.
		final isWrapShape: Bool = kwLead == null && leadText != null && trailText != null && parts.length == 3;
		if (!isWrapShape) return null;
		final leadDoc: Expr = parts[0];
		final innerDoc: Expr = parts[1];
		final trailDoc: Expr = parts[2];
		return branch.fmtHasFlag('expressionParenHardFlatten')
			? kwRefWrapHardFlatten(leadDoc, innerDoc, trailDoc, wrapOpenNewlineExpr)
			: kwRefWrapSourceNewline(leadDoc, innerDoc, trailDoc, wrapOpenNewlineExpr);
	}

	/**
	 * `@:fmt(expressionParenHardFlatten)` wrap shape (ω-hardflatten
	 * increment-2): expression-paren collapse consumer. Emits the
	 * width-driven `IfFullLineExceeds(OPEN, GLUED)` cascade with the
	 * keep-chain / pure-opAddSub / ternary / value-`if` special cases.
	 *
	 * ω-paren-value-if-open: the value-`if` arm is the ternary arm's sister
	 * and emits the same OPEN shape, but it exists as its own arm rather
	 * than as a widened `isTopLevelTernary` because the two are told apart
	 * by different reads (depth-1 separators vs the leading keyword) and
	 * because only this one HAS to bypass the generic tail. The generic tail
	 * wraps its open branch in a `CollapseProbe`, and
	 * `Renderer.collapseParenCommitsOpen` then refuses to open unless the
	 * inner can be made ONE FITTING FLAT LINE. That rule is right for an
	 * opBool chain and for an object literal (both keep breaking at their
	 * own indent inside a glued paren — `comprehension_struct_in_expr_parens_fits`),
	 * and it is exactly inverted for an `if` ladder: a ladder that overflows
	 * can NEVER become one fitting flat line, yet opening the paren is
	 * precisely what it needs — otherwise its `else` keywords lay out at the
	 * ENCLOSING STATEMENT's indent (`sameLine.expressionIf: "next"` anchors
	 * there) and the ladder reads as if it belonged to the statement rather
	 * than to the parens. Emitting the probe-free `IfFullLineExceeds` lets
	 * the raw width answer decide, so a ladder that FITS still glues.
	 */
	private static function kwRefWrapHardFlatten(leadDoc: Expr, innerDoc: Expr, trailDoc: Expr, wrapOpenNewlineExpr: Null<Expr>): Expr {
		// Leading-hardline (opBool/ternary already one-per-line)
		// defer-open shape. Honors `captureWrapOpenNewline`: when the
		// source had a `\n` after the open delim, the break shape
		// opens `(\n<inner>\n)` (first operand on its own line —
		// fork issue_187_oneline `!(\n a.y…)`); otherwise the glued-
		// open `(<inner>\n)`. Computed at macro time so the null-
		// `wrapOpenNewlineExpr` case (plain mode / no opt-in) is not
		// spliced.
		final hardlineOpenShape: Expr = wrapOpenNewlineExpr != null
			? macro (
				$wrapOpenNewlineExpr
					? _dc([$leadDoc, _dhl(), _wrapInner, _dhl(), _wrapTrail])
					: _dc([$leadDoc, _wrapInner, _dhl(), _wrapTrail])
			)
			: macro _dc([$leadDoc, _wrapInner, _dhl(), _wrapTrail]);
		// ω-keep-chain (increment: opbool-expr-paren-keep): an
		// expression paren whose inner is a kept chain that DID NOT
		// open with a leading hardline (head glued to the open delim,
		// only INTERNAL operator gaps broke — the `return !(chain)`
		// shape) is invisible to the `startsWithHardline` gate below,
		// so it falls through to the width-driven `_dfle` collapse
		// (glued head, no `(`-indent, glued `)`). When the source
		// placed a newline right after the open delim
		// (`wrapOpenNewlineExpr`) AND the inner already broke
		// (`flatLength < 0`, the kept chain reproduced its source
		// `||`/`+` gaps), open the paren condition-style:
		// `( + Nest(cols, [hardline, inner]) + hardline + )`. The
		// inner chain own continuation `Nest` is already suppressed
		// (cols=0) and its `_headBreak` dropped via `_keepChainInParen`
		// (set at the `ctorOptArg` site), so the PAREN `Nest(cols)`
		// supplies the +cols indent (head + every `||` continuation at
		// outer+cols) and the leading `Line` supplies the head break —
		// mirroring `WrapList.emitCondition` `brkShape` for the
		// `if (\n cond \n)` keep case. Computed at macro time so the
		// null-`wrapOpenNewlineExpr` case (plain / no opt-in) is not
		// spliced; the runtime `flatLength` gate keeps it byte-inert for a
		// flat (non-broken) paren content and for non-keep configs (where
		// the inner does not source-break). `_keepFlatInner` (operand of a
		// kept chain) is excluded by the outer ternary below.
		final keepOpenGate: Expr = wrapOpenNewlineExpr != null
			? macro ($wrapOpenNewlineExpr && anyparse.format.wrap.WrapList.flatLength(_wrapInner) < 0)
			: macro false;
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _wrapInner: anyparse.core.Doc = $innerDoc;
			final _wrapTrail: anyparse.core.Doc = $trailDoc;
			// ω-keep-chain (increment: opadd_chain_keep): when this expr
			// paren is an operand of a `WrapMode.Keep` chain
			// (`opt._keepFlatInner`, set on the leaf-operand opt at the
			// chain emit), the kept chain preserves source line structure
			// verbatim — its operand lines may exceed `lineWidth`. The
			// inner paren must therefore stay GLUED `(<inner>)`
			// UNCONDITIONALLY, NOT re-open via the width-driven
			// `IfFullLineExceeds` probe below (which would force
			// `(\n\tHardFlatten(inner)\n)`). Mirrors fork `keep2`'s
			// `noLineEndBefore` lock on operand-interior boundaries.
			// Byte-identical to the existing GLUED flat side, so a
			// standalone expr paren (flag false) is byte-inert.
			opt._keepFlatInner
				? _dc([$leadDoc, _wrapInner, _wrapTrail])
				: anyparse.format.wrap.WrapList.startsWithHardline(_wrapInner)
					? _dg(_dib($hardlineOpenShape, _dc([$leadDoc, _wrapInner, _wrapTrail])))
					: $keepOpenGate
						? _dc([$leadDoc, _dn(_cols, _dc([_dhl(), _wrapInner])), _dhl(), _wrapTrail])
						: anyparse.format.wrap.WrapList.isPureOpAddSubChain(_wrapInner)
							? (
								anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap) != null
									? _dfle(opt.lineWidth + 1, _dc([
										$leadDoc,
										_dn(_cols, _dc([_dhl(), _wrapInner])),
										_dhl(),
										_wrapTrail
									]), _dc([$leadDoc, _wrapInner, _wrapTrail]))
									: _dfle(opt.lineWidth + 1, _dc([
										$leadDoc,
										_dn(_cols, _dc([_dhl(), _dcp(_dhf(_wrapInner))])),
										_dhl(),
										_wrapTrail
									]), _dc([$leadDoc, _wrapInner, _wrapTrail]))
							)
							: anyparse.format.wrap.WrapList.isTopLevelTernary(_wrapInner)
								? (
									anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap) != null
										? _dfle(opt.lineWidth + 1, _dc([
											$leadDoc,
											_dn(_cols, _dc([_dhl(), _wrapInner])),
											_dhl(),
											_wrapTrail
										]), _dc([$leadDoc, _wrapInner, _wrapTrail]))
										: _dc([$leadDoc, _wrapInner, _wrapTrail])
								)
								: anyparse.format.wrap.WrapList.isTopLevelValueIf(_wrapInner)
									&& anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap) != null
									? _dfle(opt.lineWidth + 1, _dc([
										$leadDoc,
										_dn(_cols, _dc([_dhl(), _wrapInner])),
										_dhl(),
										_wrapTrail
									]), _dc([$leadDoc, _wrapInner, _wrapTrail]))
									: opt._parenInCondition
										&& anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap) != null
										? _dfle(opt.lineWidth + 1, _dc([
											$leadDoc,
											_dn(_cols, _dc([_dhl(), _wrapInner])),
											_dhl(),
											_wrapTrail
										]), _dc([$leadDoc, _wrapInner, _wrapTrail]))
										: _dfle(opt.lineWidth + 1, _dc([
											$leadDoc,
											_dn(_cols, _dc([_dhl(), _dcp(_wrapInner)])),
											_dhl(),
											_wrapTrail
										]), _dc([$leadDoc, _wrapInner, _wrapTrail]));
		};
	}

	/**
	 * omega-paren-wrap-source-newline wrap shape: the non-hardflatten
	 * `@:wrap` branch. When the ctor opted into
	 * `@:fmt(captureWrapOpenNewline)` and the parser captured a source
	 * `\n` after the open delim, routes the break shape to `(\n<inner>\n)`;
	 * else falls back to the chain emit's open-delim glue.
	 */
	private static function kwRefWrapSourceNewline(leadDoc: Expr, innerDoc: Expr, trailDoc: Expr, wrapOpenNewlineExpr: Null<Expr>): Expr {
		return wrapOpenNewlineExpr != null
			? macro {
				final _wrapInner: anyparse.core.Doc = $innerDoc;
				final _wrapTrail: anyparse.core.Doc = $trailDoc;
				anyparse.format.wrap.WrapList.startsWithHardline(_wrapInner)
					? _dg(_dib(
						$wrapOpenNewlineExpr
							? _dc([$leadDoc, _dhl(), _wrapInner, _dhl(), _wrapTrail])
							: _dc([$leadDoc, _wrapInner, _dhl(), _wrapTrail]),
						_dc([$leadDoc, _wrapInner, _wrapTrail])
					))
					: _dc([$leadDoc, _wrapInner, _wrapTrail]);
			}
			: macro {
				final _wrapInner: anyparse.core.Doc = $innerDoc;
				final _wrapTrail: anyparse.core.Doc = $trailDoc;
				anyparse.format.wrap.WrapList.startsWithHardline(_wrapInner)
					? _dg(_dib(_dc([$leadDoc, _wrapInner, _dhl(), _wrapTrail]), _dc([$leadDoc, _wrapInner, _wrapTrail])))
					: _dc([$leadDoc, _wrapInner, _wrapTrail]);
			};
	}

	/**
	 * Builds the kw-Ref sub-call's opt-frame arg (Case 3): folds the
	 * per-ctor `@:fmt` opt-threading flags (propagateExprPosition /
	 * clearExprPosition / propagateFieldLevelVar / captureSource /
	 * expressionParenHardFlatten / keep-chain-in-paren / var-kw-newline)
	 * onto `macro opt`.
	 */
	private static function kwRefCtorOptArg(kw: KwRefCtx, c: WriterLowering.LowerBranchCtx, kwNewlineExpr: Null<Expr>): Expr {
		final branch: ShapeNode = c.branch;
		final argNames: Array<String> = c.argNames;
		final propagateExpr: Bool = branch.fmtHasFlag('propagateExprPosition');
		// ω-enumabstract-begin-end: `@:fmt(propagateEnumAbstractContext)` on the
		// kw-Ref ctor `EnumAbstractDecl(decl)` flags the inner `HxAbstractDecl` opt.
		final propagateEnumAbstract: Bool = branch.fmtHasFlag('propagateEnumAbstractContext');
		final clearExpr: Bool = branch.fmtHasFlag('clearExprPosition');
		final interpFlat: Bool = branch.fmtHasFlag('captureSource');
		final parenHardFlatten: Bool = branch.fmtHasFlag('expressionParenHardFlatten');
		final propagateFieldLevelVar: Bool = branch.fmtHasFlag('propagateFieldLevelVar');
		var optExpr: Expr = macro opt;
		if (propagateExpr) optExpr = macro _setExprPosition($optExpr, opt);
		if (propagateEnumAbstract) optExpr = macro _setEnumAbstract($optExpr, opt);
		if (clearExpr) {
			final operandAccess: Expr = macro $i{argNames[0]};
			final operandIsBlock: Expr = AstPredLowering.predCallExpr(
				kw.shape.root, kw.ctx.trivia, false, 'operandIsBlockExpr', [operandAccess]
			);
			optExpr = macro ($operandIsBlock ? _clearExprPosition($optExpr, opt) : $optExpr);
		}
		// omega-macro-reification-braces: `@:fmt(clearBracePolicy)` on a kw-Ref ctor
		// (`HxExpr.MacroExpr` / `MacroClassExpr`) disarms BOTH halves of the
		// single-statement brace policy for the whole reified subtree — inside `macro …`
		// a `{ … }` is an `EBlock` of the emitted value, so adding or removing one
		// changes what the macro produces, not how it reads. Inert (and allocation-free)
		// whenever neither knob is set.
		if (branch.fmtHasFlag('clearBracePolicy')) optExpr = macro _clearBracePolicy($optExpr, opt);
		if (propagateFieldLevelVar) optExpr = macro _setFieldLevelVar($optExpr, opt);
		if (interpFlat) optExpr = macro _setChainModeOverride($optExpr, anyparse.format.wrap.WrapMode.NoWrap, opt);
		if (parenHardFlatten)
			optExpr = macro (
				opt._parenInCondition
					? _setChainModeOverride(
						_clearParenInCondition($optExpr, opt),
						anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap), opt
					)
					: $optExpr
			);
		// ω-keep-chain (increment: opadd_chain_keep): a `ParenExpr`
		// (`@:fmt(expressionParenHardFlatten)`) wrapping a chain marks the
		// inner opt `_keepChainInParen`. A `WrapMode.Keep` chain reads it to
		// (a) SUPPRESS its own `_headBreak` — the `return`→value source
		// newline is reproduced at the VALUE level (`returnBody` FitLine
		// breaks `return\n\tvalue`), not inside the paren (`(\n head`); and
		// (b) SUPPRESS its continuation `Nest` — the value-level break Nest
		// already supplies the +cols, so the chain operators continue at that
		// SAME indent (no compounding to +2cols). Mirrors fork keep2 keeping
		// the `return`→`1` newline at the value and the chain ops co-indented
		// with the head. Non-keep chains ignore the flag (gated on `isKeep`)
		// → byte-inert. A BARE chain return value (opbool case-2) has NO
		// enclosing `ParenExpr`, so the flag stays false and its chain keeps
		// its own headBreak + Nest. Trivia-only.
		if (parenHardFlatten && kw.ctx.trivia) optExpr = macro _setKeepChainInParen($optExpr, true, opt);
		return kwNewlineExpr != null ? macro _setVarKwNewline($optExpr, $kwNewlineExpr, opt) : optExpr;
	}

	/**
	 * Reads + arity-splits the ctor's `@:fmt(indentValueIfCtor(...))`
	 * entries (Case 3): the 3-arg form `(ctorName, optField,
	 * leftCurlyField)` feeds the ObjectLit-indent path, the 2-arg form
	 * `(ctorName, optField)` feeds the IfExpr-indent path. At most one of
	 * each per ctor (else a macro fatalError).
	 */
	private static function kwRefIndentEntries(branch: ShapeNode): {
		indentArgs: Null<Array<String>>,
		ifExprIndentArgs: Null<Array<String>>
	} {
		var indentArgs: Null<Array<String>> = null;
		var ifExprIndentArgs: Null<Array<String>> = null;
		final indentEntries: Array<Array<String>> = branch.fmtReadStringArgsAll('indentValueIfCtor');
		for (entry in indentEntries) switch entry.length {
			case 3: // noqa: magic-number
				if (indentArgs != null)
					Context.fatalError(
						'WriterLowering: at most one 3-arg @:fmt(indentValueIfCtor(ctorName, optField, leftCurlyField)) per ctor',
						Context.currentPos()
					);
				indentArgs = entry;
			case 2:
				if (ifExprIndentArgs != null)
					Context.fatalError(
						'WriterLowering: at most one 2-arg @:fmt(indentValueIfCtor(ctorName, optField)) per ctor', Context.currentPos()
					);
				ifExprIndentArgs = entry;
			case _:
				Context.fatalError(
					'WriterLowering: @:fmt(indentValueIfCtor(...)) on ctor requires 2 or 3 args, got ${entry.length}', Context.currentPos()
				);
		}
		return { indentArgs: indentArgs, ifExprIndentArgs: ifExprIndentArgs };
	}

	/**
	 * Resolves the kw-trailing-space behaviour (Case 3): whether the kw's
	 * trailing space is stripped (sub-struct bodyPolicy / bodyBreak /
	 * tight-lead / symbol-lead), and the runtime-switched trailing-space
	 * Doc (control-flow / anon-fn-paren / cast-tight-on-paren policies).
	 * Returns `{ strip, space }` for the parts assembly.
	 */
	private static function kwRefKwTrailSpace(
		kw: KwRefCtx, c: WriterLowering.LowerBranchCtx, refName: String, ctorBodyPolicyFlag: Null<String>
	): { strip: Bool, space: Null<Expr> } {
		final branch: ShapeNode = c.branch;
		final argNames: Array<String> = c.argNames;
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		// ω-kw-word-lead-spacing: a ctor-level `@:lead` whose
		// first char is a word character is a second keyword, NOT a tight
		// symbol delimiter (`static var` / `inline function`) — it keeps
		// the kw trailing space. Symbol leads (`(`, `{`, `:`, `->`, …) stay
		// tight under the strip.
		final leadIsWord: Bool = leadText != null && isWordStart(leadText);
		final stripKwTrailingSpace: Bool = ctorBodyPolicyFlag != null || subStructStartsWithBodyPolicy(kw, refName)
			|| subStructStartsWithBodyBreak(kw, refName) || subStructStartsWithBareBodyBreaks(kw, refName)
			|| subStructStartsWithTightLead(kw, refName) || branch.fmtHasFlag('tightKw')
			|| (leadText != null && !leadIsWord && !branch.fmtHasFlag('spaceBeforeLead'));
		// ω-if-policy / ω-control-flow-policies / ω-try-policy /
		// ω-anon-fn-paren-policy: a branch with a `@:fmt(<flag>)` whose
		// runtime value is `WhitespacePolicy` opts into a runtime-switched
		// trailing space after the kw. kw-side knobs (control flow) feed
		// the same slot as the paren-side `anonFuncParens`; `firstFmtFlag`
		// partitions them so a branch carries at most one family.
		final kwSidePolicySpace: Null<Expr> = stripKwTrailingSpace
			? null
			: kwTrailingSpacePolicy(branch, [
				'ifPolicy',
				'forPolicy',
				'whilePolicy',
				'switchPolicy',
				'tryPolicy',
				'sharpCondParensGap'
			]);
		final parenSidePolicySpace: Null<Expr> = stripKwTrailingSpace ? null : kwTrailingSpacePolicyParenSide(branch, ['anonFuncParens']);
		// ω-cast-tight-on-paren: `@:fmt(tightOnParenOperand(...))`
		// suppresses the kw trailing space at runtime when the operand's
		// enum ctor matches the list (`cast(x)` vs `cast x`).
		final ctorTightSpace: Null<Expr> = stripKwTrailingSpace ? null : kwTrailingSpaceOnOperandCtor(branch, argNames);
		return { strip: stripKwTrailingSpace, space: kwSidePolicySpace ?? parenSidePolicySpace ?? ctorTightSpace };
	}

	/**
	 * Assembles the `parts` Doc array for the kw-Ref branch (Case 3): the
	 * kw prefix (with its trailing-space / deferred-space / stripped
	 * variants), the lead delimiter, the body, and the trail delimiter
	 * (with the trivia trail-presence gate).
	 */
	private static function kwRefParts(
		kw: KwRefCtx, c: WriterLowering.LowerBranchCtx, bodyExpr: Expr, kwTrailSpace: Null<Expr>, stripKwTrailingSpace: Bool
	): Array<Expr> {
		final branch: ShapeNode = c.branch;
		final argNames: Array<String> = c.argNames;
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final kwLead: Null<String> = branch.annotations[AnnotationKeys.KW_LEAD_TEXT];
		final leadIsWord: Bool = leadText != null && isWordStart(leadText);
		final parts: Array<Expr> = [];
		if (kwLead != null) {
			if (kwTrailSpace != null) {
				parts.push(macro _dt($v{kwLead}));
				parts.push(kwTrailSpace);
			} else if (branch.fmtHasFlag('deferKwSpace') && !stripKwTrailingSpace) {
				// ω-multivar-wrap one_line: opt-in `@:fmt(deferKwSpace)` on a
				// kw-led single-Ref ctor emits the kw's trailing space as a
				// deferred `_dop(' ')` (OptSpace) instead of a hard `_dt(kw ')`.
				// The renderer flushes it as a real space before the next Text
				// (flat / head-inline cases — byte-identical), but DROPS it when
				// the sub-call leads with a break-mode hardline. Used by
				// `HxStatement.VarStmt` / `FinalStmt`: when the `HxVarDecl`
				// body routes its `more` list through `multiVarWrap` with
				// `defaultWrap: onePerLine`, the head binding breaks too
				// (`var\n\trawRead,…`), so the `var `
				// trailing space must collapse into the break — mirror of the
				// assign-op `=`→`_dop(' ')` split (ω-binop-wraprules).
				parts.push(macro _dt($v{kwLead}));
				parts.push(macro _dop(' '));
			} else {
				final kwText: String = stripKwTrailingSpace ? kwLead : '$kwLead ';
				final kwDoc: Expr = macro _dt($v{kwText});
				// condsplice-case-marker-dedent: a `#if` token-splice wrapping switch
				// case/default clauses parses as a CondSpliceStmt INSIDE the case body's
				// nest, so its leading `#if` lands one level too deep vs the verbatim
				// `case`/`#else`/`#end` (source-preserved at the case-list level). When
				// the generated `condSpliceRawWrapsCases` predicate confirms case clauses
				// (vs a dangling-else splice), dedent the `#if` marker one level via
				// ConditionalMarkerDecrease.
				if (branch.fmtHasFlag('condSpliceCaseMarkerDedent')) {
					final rawAccess: Expr = macro $i{argNames[0]}.raw;
					final wrapsCases: Expr = AstPredLowering.predCallExpr(
						kw.shape.root, kw.ctx.trivia, false, 'condSpliceRawWrapsCases', [rawAccess]
					);
					parts.push(macro $wrapsCases ? _dcmd($kwDoc) : $kwDoc);
				} else
					parts.push(kwDoc);
			}
		}
		if (leadText != null) {
			// ω-kw-word-lead-spacing: word-keyword lead also gets
			// a trailing space so it doesn't fuse with the body's first
			// token. `@:fmt(spaceAfterLead)` adds a trailing
			// space to a symbol lead (`> Foo` structure-extension).
			final spaceAfterLead: Bool = branch.fmtHasFlag('spaceAfterLead');
			final leadEmit: String = leadIsWord || spaceAfterLead ? '$leadText ' : leadText;
			parts.push(macro _dt($v{leadEmit}));
		}
		parts.push(bodyExpr);
		if (trailText != null) {
			// ω-trailopt-source-track: in trivia mode the parser captures
			// `matchLit`'s presence into `argNames[1]`; gate trail emission on
			// it directly (bypassing the Plain-mode AST-shape gate).
			// `@:fmt(spaceBeforeTrail)` prepends a space so a
			// word-start trail (`#end`) does not fuse with the body's last
			// word character.
			final isTriviaTrailOpt: Bool = kw.ctx.trivia && TriviaTypeSynth.isAltTrailOptBranch(branch);
			final trailEmit: String = branch.fmtHasFlag('spaceBeforeTrail') ? ' $trailText' : trailText;
			final trailExpr: Expr = if (isTriviaTrailOpt) {
				final flagAccess: Expr = macro $i{argNames[1]};
				optionalSemicolonWrap(kw, branch, trailEmit, argNames[0], flagAccess) ?? macro $flagAccess ? _dt($v{trailEmit}) : _de();
			} else {
				trailOptShapeGateWrap(kw, branch, trailEmit, argNames[0]) ?? macro _dt($v{trailEmit});
			};
			parts.push(trailExpr);
		}
		return parts;
	}

	/**
	 * Builds the kw-Ref body Doc (Case 3): applies the
	 * `@:fmt(indentValueIfCtor)` 3-arg ObjectLit-indent override on top of
	 * `policyWrapped`, then the `@:fmt(captureSource)` verbatim-source gate
	 * (trivia mode) and its force-flat HardFlatten pin.
	 */
	private static function kwRefBodyExpr(
		kw: KwRefCtx, c: WriterLowering.LowerBranchCtx, policyWrapped: Expr, subCall: Expr, indentArgs: Null<Array<String>>
	): Expr {
		final branch: ShapeNode = c.branch;
		final argNames: Array<String> = c.argNames;
		// ω-return-indent-objectliteral: when the runtime conditions match
		// (named bool opt true AND named leftCurly opt `Next` AND
		// `Type.enumConstructor(value) == ctorName`), bypass `bodyPolicyWrap`'s
		// sameLayoutExpr fallback and emit `Nest(_cols, subCall)` directly so
		// the body's own leading `_dhl` (ObjectLit `leftCurly=Next`) picks up
		// `+cols`. `indentArgs` is the 3-arg entry (null → no override).
		final indentWrapped: Expr = if (indentArgs == null)
			policyWrapped
		else {
			final ctorName: String = indentArgs[0];
			final optField: String = indentArgs[1];
			final leftCurlyField: String = indentArgs[2];
			final optAccess: Expr = optFieldAccess(optField);
			final leftCurlyAccess: Expr = optFieldAccess(leftCurlyField);
			final valueAccess: Expr = macro $i{argNames[0]};
			macro {
				final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				if (
					$optAccess && $leftCurlyAccess == anyparse.format.BracePlacement.Next
					&& Type.enumConstructor($valueAccess) == $v{ctorName}
				)
					_dc([_dop(' '), _dn(_cols, $subCall)])
				else
					$policyWrapped;
			};
		}
		// ω-string-interp-noformat: when the ctor opted into source-byte
		// capture (`@:fmt(captureSource('<optName>'))` + trivia mode),
		// `argNames[1]` holds the verbatim slice. Gate on the named Bool opt:
		// `false` → emit captured bytes via `_dt(sourceText)`. Match fork's
		// `printStringToken` bail-outs: any `{`/`}` in the slice → verbatim.
		final captureSourceOpt: Null<String> = kw.ctx.trivia ? branch.fmtReadString('captureSource') : null;
		final bodyExpr: Expr = if (captureSourceOpt != null) {
			final sourceAccess: Expr = macro $i{argNames[1]};
			final optAccess: Expr = optFieldAccess(captureSourceOpt);
			macro $optAccess && $sourceAccess.indexOf('{') < 0 && $sourceAccess.indexOf('}') < 0 ? $indentWrapped : _dt($sourceAccess);
		} else
			indentWrapped;
		// ω-string-interp-noformat-flat: pin the re-rendered interpolation
		// body force-flat through `HardFlatten` so an inner chain collapses to
		// one line (the fork never wraps expressions inside interpolations).
		// The verbatim branch is a single Text → HardFlatten is a no-op.
		return branch.fmtHasFlag('captureSource') ? macro _dhf($bodyExpr) : bodyExpr;
	}

	/**
	 * Finalises the kw-Ref Doc (Case 3): concats the parts, then wraps the
	 * whole construct in the `@:fmt(conditionalMarkerDedent)` render-time
	 * marker scope (`#if … #end` FixedZero / AlignedDecrease policies);
	 * every other policy leaves it unwrapped (byte-identical).
	 */
	private static function kwRefFinalDoc(kw: KwRefCtx, c: WriterLowering.LowerBranchCtx, parts: Array<Expr>): Expr {
		final concatDoc: Expr = parts.length == 1 ? parts[0] : dcCall(parts);
		// omega-cond-expr-fit: `@:fmt(condExprFitGroup)` on an expression-scope
		// cond-comp ctor wraps the whole `#if ... #end` emission in a
		// `GroupWithRestProbe` when `sameLine.conditionalExprFit` is on, so the
		// family's soft `Line(' ')` seams (padTrailingDoc / nest-body flat arms /
		// the elseifs Star separators) resolve TOGETHER against one fit decision
		// - rest-aware so the statement's own `;` after `#end` is counted. Off
		// (the default) the group is not built and no soft Line exists anywhere
		// in the family, so the output is byte-identical to the source-driven
		// layout. Gated on trivia mode like every soft-seam emitter (plain mode
		// captures no source-newline slots, so a plain-mode group would wrap
		// only hard content and could still flip a stray ungrouped `Line` in a
		// branch body from newline to space when it fits).
		final case3Doc: Expr = c.branch.fmtHasFlag('condExprFitGroup') && kw.ctx.trivia
			? macro (opt.conditionalExprFit ? _dgrp($concatDoc) : $concatDoc)
			: concatDoc;
		// ω-cond-indent-policy FixedZero/AlignedDecrease: a cond-comp ctor
		// opting into `@:fmt(conditionalMarkerDedent)` (the `#if … #end`
		// Conditional ctors) wraps its whole construct Doc in a render-time
		// marker scope — FixedZero flushes `#`-leading lines at column 0;
		// AlignedDecrease shifts every fresh line one level shallower. Every
		// other policy leaves the ctor unwrapped → byte-identical.
		return c.branch.fmtHasFlag('conditionalMarkerDedent')
			? macro (
				opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.FixedZero
					? _dcmz($case3Doc)
					: (opt.conditionalPolicy == anyparse.format.ConditionalIndentationPolicy.AlignedDecrease ? _dcmd($case3Doc) : $case3Doc)
			)
			: case3Doc;
	}

	/**
	 * The first child field of the Seq (struct) rule named `refName`, or null
	 * when `refName` is not a Seq rule or the Seq has no fields. Shared prologue
	 * of the `subStructStartsWith*` predicates.
	 */
	private static function firstFieldOfSubSeq(kw: KwRefCtx, refName: String): Null<ShapeNode> {
		final subNode: Null<ShapeNode> = kw.shape.rules[refName];
		if (subNode == null || subNode.kind != Seq) return null;
		final children: Array<ShapeNode> = subNode.children;
		return children.length == 0 ? null : children[0];
	}

	/**
	 * ω-optional-semicolon (E11): routes a trivia-mode `@:trailOpt(LIT)`
	 * trail through the runtime `opt.optionalSemicolon` policy instead of
	 * the recorded source presence. Activates only on a branch carrying
	 * `@:fmt(optionalSemicolon('<gatePredicate>'))`; returns `null`
	 * otherwise, so every other `@:trailOpt` ctor keeps preserving and
	 * the whitelist stays POSITIVE — a slot participates only where both
	 * directions have been checked to be legal.
	 *
	 * `gatePredicate` is a generated typed AST predicate over the single
	 * Ref arg, answering "is the trail omittable here?". It is mandatory:
	 * `Never` may only drop the token where the language permits
	 * omission — `return 42` before `}` is `Missing ;`. `Always` needs no
	 * gate (the token is legal wherever the grammar declares the slot),
	 * and `Preserve` reproduces the caller's own fallback.
	 *
	 * Unlike `trailOptShapeGateWrap` the predicate takes the Ref arg
	 * WHOLE rather than a field path into it. That is not a
	 * simplification: for the `var` / `final` family the answer depends
	 * on the LAST binding of a multi-variable declaration, which a path
	 * to the head's `init` cannot reach — see
	 * `varDeclTailEndsWithCloseBrace`.
	 */
	private static function optionalSemicolonWrap(
		kw: KwRefCtx, branch: ShapeNode, trailText: String, rootArg: String, presentFlag: Expr
	): Null<Expr> {
		final args: Null<Array<String>> = branch.fmtReadStringArgs('optionalSemicolon');
		if (args == null || args.length != 1) return null;
		final gateCall: Expr = AstPredLowering.predCallExpr(kw.shape.root, kw.ctx.trivia, false, args[0], [macro $i{rootArg}]);
		return macro switch opt.optionalSemicolon {
			case anyparse.format.OptionalSemicolon.Always: _dt($v{trailText});
			case anyparse.format.OptionalSemicolon.Never: $gateCall ? _de() : _dt($v{trailText});
			case _: $presentFlag ? _dt($v{trailText}) : _de();
		};
	}

	/**
	 * True when `refName` names a Seq (struct) rule whose first field is
	 * a bare Ref annotated with `@:fmt(bodyPolicy(...))` and no `@:kw` / `@:lead`
	 * of its own. Used by Case 3 enum-branch lowering to decide whether
	 * to strip the trailing space from a `@:kw` lead — the sub-struct's
	 * writer will emit the header→body separator via `bodyPolicyWrap`,
	 * so leaving the space in would yield a double space in the `Same`
	 * case and a dangling space before a hardline in `Next` / `FitLine`.
	 *
	 */
	private static function subStructStartsWithBodyPolicy(kw: KwRefCtx, refName: String): Bool {
		final first: Null<ShapeNode> = firstFieldOfSubSeq(kw, refName);
		return first != null && first.kind == Ref && first.annotations.get(AnnotationKeys.BASE_OPTIONAL) != true
			&& first.readMetaString(':kw') == null && first.readMetaString(':lead') == null
			&& first.fmtReadStringArgs('bodyPolicy') != null;
	}

	/**
	 * True when `refName` names a Seq rule whose first field is a bare
	 * Ref annotated with `@:fmt(bodyBreak(...))` and no `@:kw` / `@:lead`
	 * of its own. Mirrors `subStructStartsWithBodyPolicy` for the 2-way
	 * `SameLinePolicy` body-break knob (ω-expression-try-body-break).
	 * The field's own `bodyBreakWrap` provides the conditional
	 * space/hardline-Nest between the parent kw and the body, so the
	 * parent Case 3 must strip the trailing space from `kwLead` to
	 * avoid a double space in `Same` and a dangling space before a
	 * hardline in `Next`.
	 */
	private static function subStructStartsWithBodyBreak(kw: KwRefCtx, refName: String): Bool {
		final first: Null<ShapeNode> = firstFieldOfSubSeq(kw, refName);
		return first != null && first.kind == Ref && first.annotations.get(AnnotationKeys.BASE_OPTIONAL) != true
			&& first.readMetaString(':kw') == null && first.readMetaString(':lead') == null && first.fmtReadString('bodyBreak') != null;
	}

	/**
	 * True when `refName` names a Seq rule whose first field is a bare
	 * Ref annotated with `@:fmt(bareBodyBreaks)` and no `@:kw` / `@:lead`
	 * of its own. Mirror of `subStructStartsWithBodyBreak` for the
	 * shape-driven (no policy) bare-body break knob (ω-statement-
	 * bare-break). The field's own `bareBodyBreakWrap` provides the
	 * conditional space/hardline-Nest between the parent kw and the body,
	 * so the parent Case 3 must strip the trailing space from `kwLead` —
	 * otherwise `try` + ` ` + (block branch's inline ` `) yields `try  body`
	 * for blocks and `try \n\tbody` for bare bodies (dangling space before
	 * the hardline).
	 */
	private static function subStructStartsWithBareBodyBreaks(kw: KwRefCtx, refName: String): Bool {
		final first: Null<ShapeNode> = firstFieldOfSubSeq(kw, refName);
		return first != null && first.kind == Ref && first.annotations.get(AnnotationKeys.BASE_OPTIONAL) != true
			&& first.readMetaString(':kw') == null && first.readMetaString(':lead') == null && first.fmtHasFlag('bareBodyBreaks');
	}

	/**
	 * True when `refName` names a Seq rule whose first field's `@:lead`
	 * is declared tight by the format (`FormatInfo.tightLeads`, e.g. `:`
	 * for Haxe). A `@:kw` that routes into such a sub-struct must not
	 * emit a trailing word-boundary space — the tight lead wants to
	 * abut the kw without a space (`default:`, not `default :`). Leads
	 * that are NOT tight (`(`, `{`) keep the space (`if (`, `else {`).
	 */
	private static function subStructStartsWithTightLead(kw: KwRefCtx, refName: String): Bool {
		final first: Null<ShapeNode> = firstFieldOfSubSeq(kw, refName);
		return first != null && kw.isTightLead(first.readMetaString(':lead'));
	}

	/**
	 * Wraps the trail-literal emission for a `@:trailOpt(...)` ctor in a
	 * runtime-conditional `_de() / _dt(trail)` switch driven by the
	 * generated typed shape predicate. Activates only when the branch
	 * carries both `lit.trailOptional=true` and
	 * `@:fmt(trailOptShapeGate('<predicate>', '<argFieldPath>'))`.
	 * Returns `null` when either condition is absent so the caller
	 * falls back to the unconditional `_dt(trail)` emission.
	 *
	 * `argFieldPath` is a dot-separated chain rooted at `argNames[0]`
	 * (the single Ref-arg name in Case 3). For Haxe's
	 * `VarStmt(decl:HxVarDecl)` the path is `init` — the optional
	 * initializer field on `HxVarDecl`. The predicate receives the
	 * BARE (possibly paired) node — plain mode `Null<HxExpr>`, trivia
	 * mode `Null<HxExprT>`; Ref fields are never `Trivial<…>`-wrapped
	 * (that wrapping is Star-element-only), so a future Star-element
	 * path through this gate would have to pass `.node` itself.
	 */
	private static function trailOptShapeGateWrap(kw: KwRefCtx, branch: ShapeNode, trailText: String, rootArg: String): Null<Expr> {
		final trailOptional: Bool = branch.annotations[AnnotationKeys.LIT_TRAIL_OPTIONAL] == true;
		if (!trailOptional) return null;
		final args: Null<Array<String>> = branch.fmtReadStringArgs('trailOptShapeGate');
		if (args == null || args.length == 0 || args.length > 2) return null;
		final predName: String = args[0];
		var pathExpr: Expr = macro $i{rootArg};
		// ONE argument = the predicate takes the Ref arg WHOLE. The `var` / `final` family needs
		// that: the `;` belongs to the LAST binding of a right-recursive `HxVarDecl`, which no
		// path into the head's `init` can reach (`varDeclTailEndsWithCloseBrace`). Two arguments
		// keep the original field-path form for gates whose question really is about one field.
		if (args.length == 2) for (segment in args[1].split('.')) pathExpr = { expr: EField(pathExpr, segment), pos: Context.currentPos() };
		// The gate is the generated typed predicate of this build's AST
		// family (a grammar carrying `trailOptShapeGate` must provide the
		// marker classes); a null field value answers the predicate's own
		// false → the unconditional `_dt(trail)` branch, same as before.
		final gateCall: Expr = AstPredLowering.predCallExpr(kw.shape.root, kw.ctx.trivia, false, predName, [pathExpr]);
		return macro ($gateCall ? _de() : _dt($v{trailText}));
	}

}

/**
 * The build state the keyword-plus-Ref family reads, bundled once per
 * `WriterLowering` instance.
 *
 * `bodyPolicy` is the sibling family's bundle, threaded through because
 * Case 3 wraps its Ref body with `WriterBodyPolicyLowering.bodyPolicyWrap`.
 */
typedef KwRefCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final ctx: LoweringCtx;
	final bodyPolicy: WriterBodyPolicyLowering.BodyPolicyCtx;
	final isTightLead: (leadText:Null<String>) -> Bool;
	final isTriviaBearing: (refName:String) -> Bool;
	final writeFnFor: (refName:String) -> String;
}
#end
