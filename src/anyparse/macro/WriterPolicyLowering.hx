package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLoweringSupport.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W — the `hxformat.json` policy vocabulary.
 *
 * One responsibility: turn a configured policy value into the `Doc`
 * separator the generated writer emits. `buildPolicySwitch` is the
 * shape every member here is built from — a macro-time `switch` over
 * the enum a format key resolves to, with one `Doc` arm per value —
 * and the rest name the positions that ask for one: the whitespace
 * policies around a lead / infix / trail token, the space just inside
 * an opening delimiter, the space a keyword carries before its
 * operand, the brace-placement seam, the trailing comma, and the
 * pad-leading / pad-trailing pair with its runtime drop.
 *
 * Split out of `WriterLowering` on that responsibility: these members
 * read the FORMAT, never the grammar's shape tree beyond the node they
 * are handed. They speak the shared vocabulary of
 * `WriterLoweringSupport` (imported unqualified, `@:access` at class
 * level) and nothing else in the package reaches back into them except
 * through the same import.
 */
@:access(anyparse.macro.WriterLoweringSupport)
final class WriterPolicyLowering {

	/**
	 * Build a runtime `ESwitch` over a `WhitespacePolicy` / `SameLinePolicy`
	 * opt field. `policyModule` is the enum's module path (e.g.
	 * `['anyparse', 'format', 'WhitespacePolicy']`); each spec names the policy
	 * values it matches (resolved to raw `EField` patterns to avoid macro-time
	 * enum resolution against the abstract) and the Doc `Expr` to emit for them.
	 * Shared core of the whitespace-/same-line-policy switch builders.
	 */
	private static function buildPolicySwitch(
		policyModule: Array<String>, scrutinee: Expr, caseSpecs: Array<{ values: Array<String>, expr: Expr }>, dflt: Expr
	): Expr {
		final cases: Array<Case> = [
			for (spec in caseSpecs)
				{
					values: [
						for (name in spec.values) MacroStringTools.toFieldExpr(policyModule.concat([name]))
					],
					expr: spec.expr,
					guard: null
				}
		];
		return { expr: ESwitch(scrutinee, cases, dflt), pos: Context.currentPos() };
	}

	/**
	 * ω-keep-policy — build a runtime switch over `opt.<sameLineFlag>`
	 * (a `SameLinePolicy` enum abstract). `Next` maps to hardline at
	 * the current indent, `Keep` routes to the caller-supplied
	 * `keepExpr` (a slot-based dispatch in the kw-Ref site, a `Same`
	 * fallback everywhere else), the default case (`Same` and unknown
	 * values) emits a plain space.
	 *
	 * The case patterns are built as raw `EField` expressions to avoid
	 * macro-time enum resolution against the `SameLinePolicy` abstract
	 * (same precedent as `bodyPolicyWrap` / `leftCurlySeparator`).
	 */
	private static function sameLinePolicySwitch(optFlag: Expr, keepExpr: Expr): Expr {
		return buildPolicySwitch(['anyparse', 'format', 'SameLinePolicy'], optFlag, [
			{ values: ['Next'], expr: macro _dhl() },
			{ values: ['Keep'], expr: keepExpr }
		], macro _dt(' '));
	}

	/**
	 * Return a Doc-separator expression for the whitespace that precedes
	 * a Star struct field's opening `{`.
	 *
	 * Without `@:fmt(leftCurly)` metadata, emits a plain space (`_dt(' ')`) —
	 * the existing pre-ψ₆ behaviour. With `@:fmt(leftCurly)` present (no
	 * argument), emits a switch that picks between `_dhl()` (hardline
	 * at the current indent, placing `{` on its own line) and
	 * `_dt(' ')` based on `opt.leftCurly:BracePlacement`.
	 *
	 * The bare flag `@:fmt(leftCurly)` reads the global `opt.leftCurly`
	 * knob — every grammar site without an arg maps to the same runtime
	 * option. The knob form `@:fmt(leftCurly('<knobName>'))` (ω-objectlit-leftCurly) reads `opt.<knobName>` instead, enabling
	 * per-construct overrides like `objectLiteralLeftCurly` for
	 * `HxObjectLit.fields`. Loader-side cascade decides whether the
	 * per-construct knob follows the global or stands on its own.
	 *
	 * The `Next` pattern is built as a raw `EField` expression to avoid
	 * macro-time enum resolution against the `BracePlacement` abstract
	 * (same precedent as `bodyPolicyWrap`). Everything other than
	 * `Next` (currently only `Same`) falls through to the default case
	 * and keeps the space — additional placements can be routed here
	 * by adding more cases.
	 */
	private static function leftCurlySeparator(starNode: ShapeNode, optSpaceUpstream: Bool = false): Expr {
		if (!starNode.fmtHasFlag('leftCurly')) return macro _dt(' ');
		final knobName: Null<String> = starNode.fmtReadString('leftCurly');
		final baseKnobExpr: Expr = optFieldAccess(knobName ?? 'leftCurly');
		// ω-arrow-lambda-body-context: sister meta
		// `@:fmt(leftCurlyAnonFnOverride('<knob>'))` co-located with
		// `@:fmt(leftCurly('<knob>'))` enables flag-aware dispatch — when
		// the writer descends through `@:fmt(propagateAnonFnContext)` (e.g.
		// from `HxThinParenLambda.body`), `opt._inAnonFnBody` is true and
		// the separator reads `opt.<overrideKnob>` (anonFunctionLeftCurly)
		// instead of the default knob (blockLeftCurly). Consumer:
		// `HxExpr.BlockExpr.stmts`. Star-element write site clears the flag
		// before per-element descent so nested BlockExpr in inner statements
		// fall back to the default knob.
		final anonFnOverrideKnob: Null<String> = starNode.fmtReadString('leftCurlyAnonFnOverride');
		final knobExpr: Expr = if (anonFnOverrideKnob != null) {
			final overrideExpr: Expr = optFieldAccess(anonFnOverrideKnob);
			macro opt._inAnonFnBody ? $overrideExpr : $baseKnobExpr;
		} else
			baseKnobExpr;
		final nextPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
		// `optSpaceUpstream=true` (currently only first-field Star with
		// knob-form `@:fmt(leftCurly('<knob>'))`, e.g. `HxObjectLit.fields` /
		// `HxType.Anon.fields`) means the outer caller already emits the
		// inter-token space via the lead's `_dop(' ')` (OptSpace). The
		// `Same` branch returns `_de()` — the OptSpace flushes as ' ' on
		// its own. The `Next` branch emits a hardline; the renderer drops
		// the pending OptSpace and writes `\n` cleanly.
		//
		// `optSpaceUpstream=false` (the default — kw-led mandatory Ref,
		// optional Ref / bare Ref `@:fmt(leftCurly)`, non-first-field
		// Star bare-flag) means no upstream space producer; the separator
		// must own the space directly: `Same` → `_dt(' ')`, `Next` →
		// `_dhl()`. Knob-form on these paths (slice
		// ω-anonfunction-left-curly first consumer: `HxFnExpr.body` with
		// `leftCurly('anonFunctionLeftCurly')`) keeps the `_dt(' ')` Same
		// default — the pre-slice heuristic that switched to `_de()` on
		// any knob-form was tuned for the first-field-Star site only.
		// ω-trivia-tryparse-linelength: switch the `Same` (and `Keep` / non-
		// `Next`) default from hard `_dt(' ')` to `_dossh()`
		// (OptSpaceSkipAfterHardline) so a preceding hardline (e.g. our
		// lineLengthAware-emitted trail-terminator after a trailing line
		// comment) drops the space, leaving the next `{` at base indent
		// without a leading space (`\n{` instead of `\n {`). Flat-mode
		// width is identical (1) so layout decisions stay byte-identical
		// outside the after-hardline state; `Next` branch unaffected.
		final defaultExpr: Expr = optSpaceUpstream ? macro _de() : macro _dossh();
		final cases: Array<Case> = [{ values: [nextPat], expr: macro _dhl(), guard: null }];
		return { expr: ESwitch(knobExpr, cases, defaultExpr), pos: Context.currentPos() };
	}

	/**
	 * Return a Doc expression that optionally prefixes a Star struct
	 * field's opening delimiter with a space driven by a
	 * `WhitespacePolicy` option — the paren counterpart of
	 * `whitespacePolicyLead`.
	 *
	 * Consumed today by `@:fmt(funcParamParens)` on `HxFnDecl.params` so
	 * users can opt into `function main ()` via
	 * `whitespace.parenConfig.funcParamParens.openingPolicy: "before"`
	 * without affecting call sites, `new T(...)` args, or `(expr)`.
	 *
	 * Returns `null` when the node carries no flag from `flagNames`,
	 * letting the call site fall through to its pre-slice emission
	 * (`_dt(' ')` for spaced leads, nothing for tight leads). When a
	 * flag matches, emits a runtime switch on `opt.<flagName>`:
	 *  - `Before` / `Both` → `_dt(' ')`.
	 *  - `None` / `After`  → `_de()` (no-op).
	 *
	 * `After` is accepted for surface parity with
	 * `WhitespacePolicy` but produces no space here — emitting a space
	 * after the opening delimiter would require injecting padding
	 * inside `sepList`, which currently concatenates the open token
	 * tight against the first element.
	 *
	 */
	private static function openDelimPolicySpace(starNode: ShapeNode, flagNames: Array<String>): Null<Expr> {
		final flagName: Null<String> = firstFmtFlag(starNode, flagNames);
		return flagName == null
			? null
			: buildPolicySwitch(
				['anyparse', 'format', 'WhitespacePolicy'], optFieldAccess(flagName),
				[{ values: ['Before', 'Both'], expr: macro _dt(' ') }],
				macro _de()
			);
	}

	/**
	 * Return a Doc expression that pads the INSIDE of a Star struct
	 * field's open or close delimiter — the symmetric counterpart of
	 * `openDelimPolicySpace`, which only spaces the OUTSIDE-before-open
	 * slot.
	 *
	 * For `isClose=false` (open delim, e.g. `<` of `Array<T>`):
	 *  - `After` / `Both`  → `_dt(' ')` — emits ` ` after the open delim.
	 *  - `Before` / `None` → `_de()` (no-op; outside slot is wired via
	 *    `openDelimPolicySpace`).
	 *
	 * For `isClose=true` (close delim, e.g. `>` of `Array<T>`):
	 *  - `Before` / `Both` → `_dt(' ')` — emits ` ` before the close delim.
	 *  - `After` / `None`  → `_de()` (no-op; outside-after-close is not
	 *    yet supported by the writer's `sepList` shape).
	 *
	 * Threaded into `sepList` via the `openInside` / `closeInside` Doc
	 * args; returns `null` when the node carries no matching flag, so
	 * the call site falls through to `_de()` and keeps the pre-slice
	 * tight layout byte-identical.
	 *
	 * Consumed by `@:fmt(typeParamOpen, typeParamClose)` on the seven
	 * `typeParams` Star sites (`HxTypeRef.params` plus the five declare-
	 * site `typeParams` fields on class / interface / abstract / enum /
	 * typedef / function decls), by `@:fmt(anonTypeBracesOpen,
	 * anonTypeBracesClose)` on the `HxType.Anon` Alt-branch's
	 * `@:lead('{') @:trail('}') @:sep(',')` Star (routed through
	 * `lowerEnumStar`), and by `@:fmt(objectLiteralBracesOpen,
	 * objectLiteralBracesClose)` on `HxObjectLit.fields`'s `@:lead('{')
	 * @:trail('}') @:sep(',')` Star (routed through the regular
	 * `emitWriterStarField` sep-Star path). Defaults `None` keep
	 * `Array<Int>` / `{x:Int}` / `{a: 1}` tight; the haxe-formatter
	 * `whitespace.bracesConfig.{anonTypeBraces|objectLiteralBraces}.
	 * {openingPolicy: "around", closingPolicy: "around"}` flip produces
	 * `{ x:Int }` / `{ a: 1 }`.
	 */
	private static function delimInsidePolicySpace(starNode: ShapeNode, flagNames: Array<String>, isClose: Bool): Null<Expr> {
		final flagName: Null<String> = firstFmtFlag(starNode, flagNames);
		if (flagName == null) return null;
		final sw: Expr = policyInsideSpace(flagName, isClose);
		// ω-arrow-body-objlit-pad: `@:fmt(arrowBodyOpenPadSuppress)` on the
		// Star drops the OPEN-side inner pad when `opt._inArrowLambdaBody` is
		// set — the fork's `MarkWhitespace.successiveParenthesis` compress
		// branch never applies the opening-brace policy to a `{` whose
		// previous token is `->` (`case Arrow: return;`). The close side has
		// no Arrow check in the fork, so `isClose` keeps the plain policy.
		// `opt.objectLiteralArrowBodyOpenPad` (config `objectLiteralBraces.
		// arrowBodyOpenPad: true`) disables the suppression — a deliberate
		// config-gated divergence keeping arrow-body literals padded like
		// every other object literal (`u -> { email: v }`).
		return !isClose && starNode.fmtHasFlag('arrowBodyOpenPadSuppress')
			? macro opt._inArrowLambdaBody && !opt.objectLiteralArrowBodyOpenPad ? _de() : $sw
			: sw;
	}

	/**
	 * Build the inside-delimiter space Doc Expr for a named
	 * `WhitespacePolicy` opt field: a runtime switch emitting `_dt(' ')`
	 * for `After`/`Both` (open side) or `Before`/`Both` (close side), else
	 * `_de()`. Shared core of `delimInsidePolicySpace` (where the flag name
	 * IS the opt field name, e.g. `anonTypeBracesOpen`) and the
	 * `HxExpr.IndexAccess` `accessBracketsOpen`/`Close` path (where the
	 * `@:fmt(accessBrackets)` flag name differs from the two opt fields).
	 */
	private static function policyInsideSpace(optFieldName: String, isClose: Bool): Expr {
		return buildPolicySwitch(['anyparse', 'format', 'WhitespacePolicy'], optFieldAccess(optFieldName), [
			{ values: isClose ? ['Before', 'Both'] : ['After', 'Both'], expr: macro _dt(' ') }
		], macro _de());
	}

	/**
	 * Return a Doc expression for the trailing space AFTER an enum
	 * branch's `@:kw` keyword, gated by a `WhitespacePolicy` option.
	 * The kw counterpart of `openDelimPolicySpace` — flipped semantics
	 * because here the `WhitespacePolicy` value describes the gap on
	 * the AFTER side of the kw (= BEFORE side of the following lead /
	 * sub-struct).
	 *
	 * Returns `null` when the branch carries no flag from `flagNames`,
	 * letting the call site fall through to the pre-slice fixed
	 * trailing space (`kwLead + ' '`). When a flag matches, emits a
	 * runtime switch on `opt.<flagName>`:
	 *  - `After` / `Both` → `_dt(' ')` (space follows the kw).
	 *  - `Before` / `None` → `_de()` (no space).
	 *
	 * Consumed today by `@:fmt(ifPolicy)` on `HxStatement.IfStmt` and
	 * `HxExpr.IfExpr` (ω-if-policy), by `@:fmt(forPolicy)` /
	 * `@:fmt(whilePolicy)` / `@:fmt(switchPolicy)` on the matching
	 * stmt / expr ctors (ω-control-flow-policies) so a single
	 * config knob controls both statement- and expression-form
	 * `for(...)` / `for (...)`, `while(...)` / `while (...)`,
	 * `switch(cond)` / `switch (cond)` (and bare `switch cond`) spacing,
	 * by `@:fmt(tryPolicy)` on `HxStatement.TryCatchStmt` (ω-try-policy) gating `try {` / `try{`, and by
	 * `@:fmt(anonFuncParens)` on `HxExpr.FnExpr(fn:HxFnExpr)` (ω-anon-fn-paren-policy) gating `function (args)…` /
	 * `function(args)…` independently of `funcParamParens` (which
	 * targets `HxFnDecl.params`). The bare-body try sibling
	 * `TryCatchStmtBare` does NOT carry the flag — its first field's
	 * `@:fmt(bareBodyBreaks)` strips the kw-trailing-space slot.
	 */
	private static function kwTrailingSpacePolicy(branch: ShapeNode, flagNames: Array<String>): Null<Expr> {
		final flagName: Null<String> = firstFmtFlag(branch, flagNames);
		return flagName == null
			? null
			: buildPolicySwitch(
				['anyparse', 'format', 'WhitespacePolicy'], optFieldAccess(flagName),
				[{ values: ['After', 'Both'], expr: macro _dt(' ') }],
				macro _de()
			);
	}

	/**
	 * Paren-side counterpart of `kwTrailingSpacePolicy` — same kw-after
	 * slot, but the `WhitespacePolicy` value names the gap from the
	 * FOLLOWING open-delimiter's perspective. `Before` / `Both` mean
	 * "space immediately before the `(`" (= space after the kw); `After`
	 * / `None` mean no space in this slot.
	 *
	 * Consumed by `@:fmt(anonFuncParens)` on `HxExpr.FnExpr(fn:HxFnExpr)`
	 * (ω-anon-fn-paren-policy) so the JSON config name
	 * `whitespace.parenConfig.anonFuncParamParens.openingPolicy: "before"`
	 * round-trips intuitively to `opt.anonFuncParens =
	 * WhitespacePolicy.Before` and emits the expected `function (args)…`
	 * spacing — matching the haxe-formatter convention where
	 * `anonFuncParamParens` policies name the gap from the paren side
	 * (siblings `funcParamParens`, `callParens`).
	 *
	 * Returned Expr shape mirrors `kwTrailingSpacePolicy`; only the
	 * Before/After mapping flips.
	 */
	private static function kwTrailingSpacePolicyParenSide(branch: ShapeNode, flagNames: Array<String>): Null<Expr> {
		final flagName: Null<String> = firstFmtFlag(branch, flagNames);
		return flagName == null
			? null
			: buildPolicySwitch(
				['anyparse', 'format', 'WhitespacePolicy'], optFieldAccess(flagName),
				[{ values: ['Before', 'Both'], expr: macro _dt(' ') }],
				macro _de()
			);
	}

	/**
	 * Operand-ctor-dispatched counterpart of `kwTrailingSpacePolicy` —
	 * same kw-after slot, but the choice between ` ` and `_de()` is
	 * driven at runtime by the operand's enum constructor name rather
	 * than a `WhitespacePolicy` option. Reads
	 * `@:fmt(tightOnParenOperand('A', 'B', …))` from the branch; when
	 * the operand's runtime `Type.enumConstructor(...)` matches any of
	 * the listed names, emits `_de()` (kw fuses tight to the operand's
	 * leading `(`); otherwise emits `_dt(' ')`.
	 *
	 * Returns `null` when the flag is absent so the call site falls
	 * through to the pre-slice fixed `kwLead + ' '` emission. Requires
	 * the branch to be a single-Ref ctor — `argNames[0]` carries the
	 * operand binding (mirror of `bodyPolicy`'s value-arg dispatch in
	 * the indent-wrap path).
	 *
	 * Consumed by `@:fmt(tightOnParenOperand('ParenExpr',
	 * 'ECheckTypeExpr'))` on `HxExpr.CastExpr` (paired with
	 * `@:fmt(atomOperand)` in Lowering so the operand binds at atom
	 * level and the listed ctors actually appear as the operand's
	 * runtime ctor — without atom-binding, `cast (x) is Bool` would
	 * carry operand=`Is(...)` and the ctor match would never fire).
	 * Emits tight `cast(x)` / `cast(x : Int)` per haxe-formatter's
	 * cast-as-function-call convention, while bare `cast x` (operand =
	 * `IdentExpr`) keeps the spaced shape.
	 */
	private static function kwTrailingSpaceOnOperandCtor(branch: ShapeNode, argNames: Array<String>): Null<Expr> {
		final names: Null<Array<String>> = branch.fmtReadStringArgs('tightOnParenOperand');
		if (names == null || names.length == 0) return null;
		if (argNames.length == 0) return null;
		final operandAccess: Expr = macro $i{argNames[0]};
		final ctorEquals: Array<Expr> = [for (n in names) macro _ctor == $v{n}];
		var matchExpr: Expr = ctorEquals[0];
		for (i in 1...ctorEquals.length) {
			final next: Expr = ctorEquals[i];
			matchExpr = macro $matchExpr || $next;
		}
		return macro {
			final _ctor: String = Type.enumConstructor($operandAccess);
			$matchExpr ? _de() : _dt(' ');
		};
	}

	/**
	 * Return a Doc expression for a `@:lead(text)` whose field carries a
	 * writer-only whitespace-policy flag. The helper picks the first flag
	 * from `flagNames` that is present on `child` and emits a runtime
	 * switch on `opt.<flagName>:WhitespacePolicy`; when no flag matches
	 * the output is plain `_dt(leadText)`, matching the tight default of
	 * the mandatory-lead path.
	 *
	 * Defined flags today:
	 *  - `objectFieldColon` (ψ₇) — `HxObjectField.value`'s `@:lead(':')`.
	 *    Default `After` on `HaxeFormat.instance.defaultWriteOptions`:
	 *    `{a: 0}`.
	 *  - `typeHintColon` (ω-E-whitespace) — the three type-annotation
	 *    colons: `HxVarDecl.type`, `HxParam.type`, `HxFnDecl.returnType`.
	 *    Default `None` — `x:Int`, `f():Void` stay compact.
	 *  - `typedefAssign` (ω-typedef-assign) — `HxTypedefDecl.type`'s
	 *    `@:lead('=')`. Default `Both` — `typedef Foo = Bar;`. The
	 *    `None` policy reverts to the pre-slice tight `=` via the
	 *    same switch's fall-through path.
	 *  - `typeParamDefaultEquals` (ω-typeparam-default-equals) —
	 *    `HxTypeParamDecl.defaultValue`'s `@:optional @:lead('=')`.
	 *    Default `Both` — `<T = Int>` / `<T:Foo = Bar>`. `None`
	 *    collapses the optional non-tight lead's `sameLineSeparator +
	 *    leadText + ' '` pair into a tight `<T=Int>` (matches
	 *    `whitespace.binopPolicy: "none"`). Routed from the optional
	 *    non-tight branch in `lowerStruct` Case 5, NOT from the
	 *    mandatory-lead path that handles the other knobs above.
	 *
	 * Runtime dispatch for each switch (cases built as raw `EField`
	 * patterns to avoid macro-time enum resolution against
	 * `WhitespacePolicy`):
	 *  - `Before` → `_dt(' ' + leadText)`.
	 *  - `After`  → `_dt(leadText + ' ')`.
	 *  - `Both`   → `_dt(' ' + leadText + ' ')`.
	 *  - `None`   → default, `_dt(leadText)` (tight).
	 *
	 * Pre-concatenating each case into a single `_dt` (instead of three
	 * Doc atoms) keeps the output byte-identical to the pre-flag layout
	 * for the `None` case and avoids introducing Doc boundaries the
	 * Renderer might break across.
	 *
	 * Per-field flags stay scoped to their own grammar sites — sibling
	 * leads on the same struct are unaffected. Adding a new tag follows
	 * the ψ₆ principle (one meta = one options field); multiple tags on
	 * one field are resolved by `flagNames` order.
	 */
	private static function whitespacePolicyLead(child: ShapeNode, leadText: String, flagNames: Array<String>): Expr {
		final flagName: Null<String> = firstFmtFlag(child, flagNames);
		// Opt-in `@:fmt(spaceAfterLead)` on a struct-
		// field mandatory `@:lead(LIT)` appends an OptSpace after the
		// lead literal — mirror of the enum-ctor `spaceAfterLead`
		// path (line ~1075) for the struct-field side. Used by
		// `HxVarMore.decl` (`@:lead(',')`) and `HxTypedCast.type`
		// (`@:lead(',')`) to emit `, b` and `cast(x, T)` respectively
		// instead of tight `,b` / `cast(x,T)`. The space is `_dop` so
		// the renderer can drop it when the value emits a leading
		// hardline.
		// Trailing whitespace after the lead is emitted as `_dop(' ')`
		// (OptSpace) so the renderer can drop it when the value emits a
		// leading hardline — e.g. `Address: {…}` with `leftCurly=Next`
		// on the nested object literal renders as `Address:\n{…}`. The
		// leading space (Before / Both case) stays a plain `_dt(' ')`
		// because nothing emits a hardline before the lead.
		return if (flagName != null)
			buildPolicySwitch(['anyparse', 'format', 'WhitespacePolicy'], optFieldAccess(flagName), [
				{ values: ['Before'], expr: macro _dc([_dt(' '), _dt($v{leadText})]) },
				{ values: ['After'], expr: macro _dc([_dt($v{leadText}), _dop(' ')]) },
				{ values: ['Both'], expr: macro _dc([_dt(' '), _dt($v{leadText}), _dop(' ')]) }
			], macro _dt($v{leadText}))
		else if (child.fmtHasFlag('spaceAfterLead'))
			macro _dc([_dt($v{leadText}), _dop(' ')])
		else
			macro _dt($v{leadText});
	}

	/**
	 * Infix-op sister of `whitespacePolicyLead`: emit the operator literal
	 * (e.g. `->` on `HxType.Arrow`) under a runtime switch on
	 * `opt.<flagName>:WhitespacePolicy`. Default `None` falls through to
	 * the tight `_dt(opText)`, preserving the pre-flag layout for the
	 * historic `@:fmt(tight)` shape; `Around` / `Before` / `After` add
	 * the matching adjacent spaces. Both adjacent spaces emit as plain
	 * `_dt` (not `_dop`) — an infix op sits between two value Docs that
	 * never emit leading or trailing hardlines on their own at the op
	 * boundary, so OptSpace would not pay off the way it does on a
	 * `@:lead` site whose value may break.
	 */
	private static function whitespacePolicyInfix(opText: String, flagName: String): Expr {
		return buildPolicySwitch(['anyparse', 'format', 'WhitespacePolicy'], optFieldAccess(flagName), [
			{ values: ['Before'], expr: macro _dt($v{' ' + opText}) },
			{ values: ['After'], expr: macro _dt($v{opText + ' '}) },
			{ values: ['Both'], expr: macro _dt($v{' ' + opText + ' '}) }
		], macro _dt($v{opText}));
	}

	/**
	 * ω-condition-parens (Stage C): trail-side sister of
	 * `whitespacePolicyLead`. Emit a `@:trail(text)` close literal under a
	 * runtime switch on `opt.<flagName>:WhitespacePolicy`, prepending an
	 * INNER space (` )`) when the policy carries the `before` side
	 * (`Before` / `Both`). The close literal sits right after a value Doc,
	 * so the inner space is a plain `_dt(' ')` (the value never emits a
	 * trailing hardline at the paren boundary). Picks the first flag from
	 * `flagNames` present on `child`; no flag → tight `_dt(trailText)`,
	 * byte-identical to the pre-slice mandatory-trail path. Used by
	 * `catchParensInsideClose` (`HxCatchClause.param` `@:trail(')')`).
	 */
	private static function whitespacePolicyTrail(child: ShapeNode, trailText: String, flagNames: Array<String>): Expr {
		final flagName: Null<String> = firstFmtFlag(child, flagNames);
		return flagName == null
			? macro _dt($v{trailText})
			: buildPolicySwitch(
				['anyparse', 'format', 'WhitespacePolicy'], optFieldAccess(flagName),
				[{ values: ['Before', 'Both'], expr: macro _dt($v{' ' + trailText}) }],
				macro _dt($v{trailText})
			);
	}

	/**
	 * Interval operator (`...`) whitespace under `opt.intervalPolicy`. Mirror
	 * of `whitespacePolicyInfix`, but a left operand whose rendered tail ends
	 * with a DECIMAL digit directly abuts the `...` in source (haxe-formatter
	 * fuses that into a single tight `IntInterval` token — `0...n`,
	 * `i + 1...len`) and is emitted TIGHT regardless of the policy; every other
	 * left-operand tail is a binary `OpInterval` that honours the policy.
	 * `None` (default) keeps the whole operator tight, byte-identical to the
	 * pre-slice `@:fmt(tight)` emission. Reads the runtime local `_leftIv:Doc`
	 * (the already-rendered left operand). A decimal int operand written WITH a
	 * source space (`1 ... n`) cannot be told apart from the fused form once
	 * adjacency is dropped at parse time, so it stays tight — an accepted
	 * residual.
	 */
	private static function intervalPolicyOp(opText: String): Expr {
		final tightDoc: Expr = macro _dt($v{opText});
		final fused: Expr = macro anyparse.format.wrap.WrapList.endsWithDecimalDigit(_leftIv);
		final beforeExpr: Expr = macro $fused ? $tightDoc : _dt($v{' ' + opText});
		final afterExpr: Expr = macro $fused ? $tightDoc : _dt($v{opText + ' '});
		final bothExpr: Expr = macro $fused ? $tightDoc : _dt($v{' ' + opText + ' '});
		return buildPolicySwitch(['anyparse', 'format', 'WhitespacePolicy'], optFieldAccess('intervalPolicy'), [
			{ values: ['Before'], expr: beforeExpr },
			{ values: ['After'], expr: afterExpr },
			{ values: ['Both'], expr: bothExpr }
		], tightDoc);
	}

	/**
	 * ω-block-body-alt-samelinepolicy: block-body branch of the catches-
	 * Star sep override. Bare `@:fmt(blockBodyKeepsInline)` returns
	 * `_dt(' ')` — block bodies stay inline regardless of policy
	 * (existing behavior). The knob form
	 * `@:fmt(blockBodyKeepsInline('<sameLineFlag>'))` redirects the
	 * block-body branch through `sameLinePolicySwitch` on the named
	 * runtime option, so the catch separator after a block body follows
	 * a different SameLine policy than the bare-body branch's
	 * `sameLine('<expressionFlag>')`. Consumed by
	 * `HxTryCatchExpr.catches` to match haxe-formatter, where a
	 * block-bodied expression-position `try` honours `sameLine.tryCatch`
	 * (`} catch` vs `}\ncatch`) while a bare-body expression-position
	 * `try` keeps reading `sameLine.expressionTry`.
	 */
	private static function blockBodyKeepsInlineBranch(starNode: ShapeNode): Expr {
		final altPolicy: Null<String> = starNode.fmtReadString('blockBodyKeepsInline');
		return altPolicy == null ? macro _dt(' ') : sameLinePolicySwitch(optFieldAccess(altPolicy), macro _dt(' '));
	}

	/**
	 * ω-pad-trailing-ref — fold a field's runtime pad-fire condition
	 * (`fires`) and runtime transparency condition (`transparent`)
	 * into the running `prevPadTrailing` tracker.
	 *
	 * Truth table per (fires, transparent, prev) presence:
	 *
	 *   fires=null, transparent=null      → return null
	 *     (visible non-pad emission resets the chain)
	 *   fires=null, transparent=expr      → return `transparent && prev`
	 *     (this field is sometimes-empty; when empty, propagate prev)
	 *   fires=expr, transparent=null      → return `fires`
	 *     (mandatory-Ref pad — always fires when present)
	 *   fires=expr, transparent=expr      → return `fires || (transparent && prev)`
	 *     (optional/Star with pad — fires when present, propagates when transparent)
	 *
	 * The `transparent` runtime expr must be the negation of "this
	 * field emitted any visible content" — i.e. true iff the field's
	 * presence guard fails (Star empty / optional-Ref absent / etc.).
	 * For optional-Star/Ref WITH pad, `transparent` and `fires` are
	 * mutex by construction (`length > 0` vs `length == 0`); the
	 * disjunction in the third arm therefore collapses cleanly without
	 * runtime overlap.
	 *
	 * Returns `null` to mean "no live pad signal" — every caller stores
	 * the result back into `prevPadTrailing`, and `sameLineSeparator`
	 * treats a `null` tracker as "wrap is a no-op" (byte-identical to
	 * the pre-engine path).
	 */
	private static function composePadTrailing(prev: Null<Expr>, fires: Null<Expr>, transparent: Null<Expr>): Null<Expr> {
		return if (fires == null && transparent == null)
			null
		else if (fires == null)
			prev != null ? macro $transparent && $prev : null
		else if (transparent == null)
			fires
		else if (prev != null)
			macro $fires || ($transparent && $prev)
		else
			fires;
	}

	/**
	 * ω-pad-trailing-ref — wrap a sep-emission `Expr` with the
	 * `prevPadTrailing` runtime drop. When the immediately preceding
	 * field fired `@:fmt(padTrailing)`, drop THIS sep at runtime so
	 * the pad's emission owns the boundary alone.
	 *
	 * No-op (returns `result` unchanged) when `prevPadTrailing` is
	 * null — preserves byte-identical behaviour for callers without
	 * an upstream pad signal.
	 *
	 * Two consumer sites: `sameLineSeparator` (kw-Ref / opt-Ref /
	 * opt-lead struct-field sep) and the inter-Star sep at the
	 * struct-field bare-tryparse-Star branch (sub-slice 7). Both
	 * read the same macro-time `prevPadTrailing` set by
	 * `composePadTrailing` at the end of each iteration.
	 */
	private static inline function withPadTrailingDrop(prevPadTrailing: Null<Expr>, result: Expr): Expr {
		return prevPadTrailing != null ? macro ($prevPadTrailing ? _de() : $result) : result;
	}

	/**
	 * ω-cond-comp-expr-body-nest — wrap a body Ref's writer call so the
	 * leading separator + body emit either as inline `' ' + body`
	 * (source on same line) or as `Nest(_cols, [hardline, body])`
	 * (source had a newline at the boundary). Pure source-shape decision —
	 * no user-config policy involvement, distinct from the heavier
	 * `bodyPolicyWrap` (Same/Next/Keep + bodyOnSameLine slot) and the
	 * shape-aware `bareBodyBreakWrap` (block-ctor switch). Sister to the
	 * issue_48-v2 inline `nlAccess ? _dhl() : _dt(' ')` sep but with the
	 * `_dn(_cols, ...)` wrap so the body picks up `+1` indent step on
	 * break — required for expression-scope cond-comp where the fork
	 * convention places the body one level deeper than `#if`/`#elseif`/
	 * `#else` (issue_429), unlike stmt/decl scope where body sits at
	 * the same indent as the keyword.
	 *
	 * `sourceNewlineExpr` is a runtime `Bool` Expr the caller assembles
	 * from the appropriate per-kind slot:
	 *   - Bare-Ref non-first → `value.<f>BeforeNewline` directly (true
	 *     means the source had a newline before this field's first
	 *     token, so break + nest).
	 *   - Optional-kw-Ref → `!value.<f>BodyOnSameLine` (the captured
	 *     slot stores `true` when body sat on the same line as the kw,
	 *     so we negate to get the break decision).
	 *
	 * The wrapper itself is signal-agnostic — kind dispatch lives at
	 * the call site so each path can read its own slot and gate on
	 * `ctx.trivia` / `isTriviaBearing(typePath)` before opting in.
	 *
	 * Plain mode and non-trivia-bearing types must NOT call this helper
	 * — there's no captured slot to read; the call site falls back to
	 * the existing `_dt(' ') + writeCall` default sep instead.
	 *
	 * Used by `@:fmt(nestBodyOnSourceNewline)` on body Ref fields of
	 * `HxConditionalExpr.expr`, `HxConditionalExpr.elseExpr`, and
	 * `HxElseifExpr.expr`. All current consumers have a non-Star
	 * prior sibling (`cond:HxPpCondLit` for the bare-Ref expr fields;
	 * the prior sibling is irrelevant for the optional-kw-Ref path
	 * which owns its own kw separator). Future consumers placing
	 * the flag on a bare-Ref whose prior sibling is an optional Star
	 * would need to compose with `prevAnyStarNonEmpty` at the call
	 * site — the wrapper itself is intentionally signal-only, mirroring
	 * the simplicity of `bareBodyBreakWrap`.
	 */
	private static inline function nestBodyOnSourceNewlineWrap(writeCall: Expr, sourceNewlineExpr: Expr): Expr {
		// omega-cond-expr-fit: with `sameLine.conditionalExprFit` on, the flat
		// arm becomes a soft `Nest(cols, [Line(' '), body])` - a space while the
		// ctor-level `condExprFitGroup` group fits, the nested next-line shape
		// when it breaks. Every consumer of this helper is a field of the
		// expression-scope cond-comp family, so no per-field opt-in is needed;
		// with the knob off the emitted Doc is byte-identical to the old shape.
		final sameLayoutExpr: Expr = macro opt.conditionalExprFit ? _dn(_cols, _dc([_dl(), $writeCall])) : _dc([_dt(' '), $writeCall]);
		final nextLayoutExpr: Expr = macro _dn(_cols, _dc([_dhl(), $writeCall]));
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$sourceNewlineExpr ? $nextLayoutExpr : $sameLayoutExpr;
		};
	}

	/**
	 * Return a `Bool`-valued expression for the `trailingComma` argument
	 * of `sepList`. Returns `macro false` when the node carries no
	 * `@:fmt(trailingComma("flagName"))` knob, else `macro opt.<flagName>` so
	 * the knob is resolved at runtime against the caller's options.
	 *
	 * Read from the node that owns the separated list — an enum branch
	 * (Case 4 Star / postfix Star) or a struct Star field.
	 */
	private static function trailingCommaExpr(node: ShapeNode): Expr {
		final flagName: Null<String> = node.fmtReadString('trailingComma');
		// ω-multiline-trailing-comma-remove: the plain / postfix Star path
		// (`HxExpr.Call.args`) reaches its trailing separator through this
		// helper, not through `triviaSepTrailExprs` — apply the same veto here
		// so one policy answers the question for every list that opts in.
		return flagName == null ? macro false : keepsTrailingCommaExpr(optFieldAccess(flagName), node.fmtHasFlag('trailingCommaRemovable'));
	}

	/**
	 * ω-multiline-trailing-comma-remove: conjoins the `wrapping.trailingComma
	 * != Remove` veto onto a BREAK-mode trailing-separator Expr, so a source
	 * `,` no longer round-trips and the per-construct add-knob no longer
	 * fires. Returns `e` untouched for a Star without
	 * `@:fmt(trailingCommaRemovable)` — the policy therefore cannot reach a
	 * construct whose trailing separator is MANDATORY (a `{ > Base, }`
	 * anon-type extension), and every non-opted Star's emit stays
	 * byte-identical.
	 */
	private static function keepsTrailingCommaExpr(e: Expr, trailingCommaRemovable: Bool): Expr {
		return trailingCommaRemovable ? macro ($e && opt.trailingComma != anyparse.format.TrailingCommaPolicy.Remove) : e;
	}

	/**
	 * Return a `Bool`-valued expression for the `keepInnerWhenEmpty`
	 * argument of `sepList`. Returns `macro false` when the field
	 * carries no `@:fmt(keepInnerWhenEmpty("flagName"))` knob, else
	 * `macro opt.<flagName>` so the knob is resolved at runtime.
	 *
	 * Today only struct Star fields opt in (`HxFnExpr.params` →
	 * `anonFuncParamParensKeepInnerWhenEmpty`). The two other `sepList`
	 * call sites (postfix Star, enum Case 4 Star) pass `false`
	 * directly — they have no fixture demand for the inside-space-on-
	 * empty shape and the literal keeps the macro dependency narrow.
	 */
	private static function keepInnerWhenEmptyExpr(node: ShapeNode): Expr {
		final flagName: Null<String> = node.fmtReadString('keepInnerWhenEmpty');
		return flagName == null ? macro false : optFieldAccess(flagName);
	}

	private static function buildCaseBodyFlagPredicate(flagName: String): Expr {
		final samePat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Same']);
		final keepPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'Keep']);
		final optFlag: Expr = optFieldAccess(flagName);
		return macro ($optFlag == $samePat || ($optFlag == $keepPat && !_arr[0].newlineBefore));
	}

	/**
	 * ω-case-body-fitline — per-flag FIT predicate: `opt.<flag> == FitLine`.
	 *
	 * Sister to `buildCaseBodyFlagPredicate`, which answers "is the body
	 * COMMITTED to the case-header line at write time" (`Same`, or `Keep`
	 * with same-line source). This one answers "is the placement DEFERRED
	 * to the renderer" — the emit then lays the body out as
	 * `BodyGroup(Nest(cols, [Line, body]))` so the renderer's own
	 * `fitsFlat` picks inline when `indent + patterns + ': ' + flat body`
	 * fits `lineWidth` and next-line-at-one-deeper otherwise. Mirrors the
	 * bare-Ref `bodyPolicyWrap` `FitLine` layout (`buildBodyFitExpr`), so a
	 * case body and a `return` body measure by the SAME route.
	 *
	 * Deliberately does NOT read `_arr[0].newlineBefore`: `FitLine` is a
	 * width decision, not a source-shape one — an author-broken body that
	 * fits re-joins the case line, which is the point of asking for it.
	 */
	private static function buildCaseBodyFitPredicate(flagName: String): Expr {
		final fitPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'FitLine']);
		final optFlag: Expr = optFieldAccess(flagName);
		return macro ($optFlag == $fitPat);
	}

}
#end
