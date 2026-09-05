package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterPolicyLowering.*;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W — what a `Ref` field's lead literal becomes at runtime, and what
 * wraps its write call.
 *
 * A struct field that is a bare `Ref` emits at most three things: a lead
 * literal, the descendant writer's call, and a trail. This module owns the
 * first two halves of that question wherever the answer depends only on the
 * field's own metadata. `emitMandatoryLead` turns the `@:lead` text into a
 * `Doc` under the whitespace policies (and, for a switch subject, into the
 * runtime strip test `switchParensStripCond` builds).
 * `breakAfterLeadOnOverflowWrap` is the `=`-lead's overflow arm — which of
 * the three RHS shapes decides whether the break lands after the `=` or
 * inside the RHS. `buildSharpInsideWriteCall`, `subPositionSuppressOpt`,
 * `readBoolFlagStarCtorArgs`, `indentValueIfCtorWrap` and
 * `maybeIndentValueIfCtor` are the wraps layered onto the write call, one
 * per `@:fmt` entry that can appear on such a field.
 *
 * Every member is a pure function of its arguments — the field's
 * `ShapeNode`, the accessors the caller already built, and the raw call —
 * so they are statics here and their call sites in `WriterLowering` are
 * unchanged.
 */
@:access(anyparse.macro.WriterLoweringSupport, anyparse.macro.WriterPolicyLowering)
final class WriterRefLeadLowering {

	/**
	 * D61: emit a mandatory (non-optional, non-condWrap) `@:lead` literal — tight
	 * by default, routed through `whitespacePolicyLead` for the configurable-
	 * spacing leads (objectFieldColon / typeHintColon / typedefAssign / …). The
	 * `@:fmt(typedefIntersectionBreak)` field makes the `&`→operand whitespace a
	 * runtime `opt._intersectionOperandBreak` decision. Pushes onto `parts`.
	 *
	 */
	private static function emitMandatoryLead(child: ShapeNode, parts: Array<Expr>, leadText: String, fieldAccess: Expr): Void {
		// ω-typedef-intersection-operand-break: `HxIntersectionClause.type`
		// (`@:lead('&') @:fmt(typedefIntersection, typedefIntersectionBreak)`)
		// makes the `&`→operand whitespace a runtime decision. When the
		// consuming Star (`HxTypedefDecl.intersections`) sets
		// `opt._intersectionOperandBreak == true` — this clause follows a
		// multi-line brace-closed operand (`A & {\n…\n} & B`) — emit the
		// `&` glued to the preceding `}` line, then a hardline + one-tab
		// nest before the operand value (`} &\n\tB`). The `Nest(cols, …)`
		// wraps only the hardline so the newline's trailing indent is
		// bumped one level; the operand renders right after at base+cols.
		// Mirrors fork `MarkLineEnds`'s `lineEndAfter` on the `&` that
		// follows a `BrClose`. Flag false (every single-line intersection)
		// falls through to the `typedefIntersection` After space, byte-
		// identical to the pre-slice layout.
		final leadDoc: Expr = if (child.fmtHasFlag('typedefIntersectionBreak')) {
			final gluedLead: Expr = whitespacePolicyLead(child, leadText, ['typedefIntersection']);
			macro opt._intersectionOperandBreak
				? _dc([
					_dt($v{leadText}),
					_dn(opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth, _dhl())
				])
				: $gluedLead;
		} else
			whitespacePolicyLead(child, leadText, [
				'objectFieldColon',
				'typeHintColon',
				'typeCheckColon',
				'typedefAssign',
				'typedefIntersection',
				'functionTypeHaxe4',
				'arrowFunctions',
				'catchParensInsideOpen',
				'switchCondParensInsideOpen',
				'whileCondParensInsideOpen'
			]);
		// ω-switch-subject-parens: drop the switch-subject open `(` when the knob
		// is on and the subject is not a leading-brace expr (object literal / block
		// keep their parens). Nothing replaces it — the `switch` keyword already
		// emits its trailing space, so `switch (v)` → `switch v` like the bare form.
		if (child.fmtHasFlag('switchSubjectParensStrip')) {
			final cond: Expr = switchParensStripCond(fieldAccess);
			parts.push(macro $cond ? _de() : $leadDoc);
		} else
			parts.push(leadDoc);
	}

	/**
	 * ω-switch-subject-parens: the runtime condition under which the switch
	 * subject's parens are dropped — the `dropSwitchSubjectParens` knob is on
	 * AND the subject is not a leading-brace expression (object literal / block,
	 * kept so a brace-first subject never abuts the cases brace). Shared by the
	 * `@:lead('(')` and `@:trail(')')` emit sites of `HxSwitchStmt.expr`
	 * (`@:fmt(switchSubjectParensStrip)`).
	 */
	private static function switchParensStripCond(fieldAccess: Expr): Expr {
		return macro opt.dropSwitchSubjectParens && {
			final _sc: String = Type.enumConstructor(cast $fieldAccess);
			_sc != 'ObjectLit' && _sc != 'BlockExpr';
		};
	}

	/**
	 * ω-N-break-after-eq: bundle a non-tight optional `@:lead` + its RHS
	 * through the natural-first-line probe so the lead breaks (LF + Nest
	 * +1) ONLY when the probe arm is armed AND the RHS's NATURAL first
	 * line (its own wrap decisions active) still overflows
	 * `opt.lineWidth`. Two arming gates, either suffices:
	 *
	 *  - the LHS declared type carries type-params (gate 1, fork parity —
	 *    reads the sibling field named by `typeFieldName`, today
	 *    `HxVarDecl.type`: a `Named` ctor with a non-empty `params`
	 *    list);
	 *  - the RHS is an unbreakable string atom (`SingleStringExpr` /
	 *    `DoubleStringExpr` on `_optVal`) — a long interpolated string
	 *    has NO internal wrap point, so without the `=`-break the writer
	 *    emits a line past `maxLineLength` untouched (the motivating
	 *    real-code shape).
	 *
	 * An un-armed field keeps the glued ` = RHS` emit byte-identical to
	 * the plain path. The probe itself: a NoWrap-pinned / atom RHS keeps
	 * its full flat first line -> probe crosses -> break after `=`; a RHS
	 * that wraps its own call-args has a short natural first line ->
	 * probe stays flat -> keep ` = RHS` inline (the fork wraps the RHS
	 * bracket, not the `=`). The gates stay narrow deliberately: a
	 * fill-wrapping RHS (an opAdd / shift / bool chain, a call, a `new`)
	 * fits by breaking its LATER lines, so its natural first line is long
	 * by design and an unconditional probe would double-break it
	 * (`x =\n\ta << b\n\t\t<< c`) — caught by the corpus sweep when the
	 * gate was briefly dropped. Mode-agnostic — a single optional Ref's
	 * paired value is the paired enum directly (NOT Trivial<…>-wrapped,
	 * unlike Star elements).
	 *
	 * Differs from the `bodyPolicyWrap` `_difle` precedent (same file,
	 * width path) by calling `_dinfle` (natural-first-line probe) instead
	 * of `_difle` (flat first-line probe): the flat probe cannot tell a
	 * wrappable RHS bracket from a NoWrap-pinned one and over-breaks.
	 *
	 * Un-armed fields take the DECL-HEADER arm (ω-N-break-after-eq,
	 * decl-header increment) — a strictly weaker, last-resort break for the
	 * shape the natural probe is blind to: the RHS's call args ALREADY wrap
	 * past `(`, yet the remaining HEADER line (up to that open paren) still
	 * exceeds `maxLineLength`. The natural probe cannot see it because it
	 * resolves such a RHS flat and reports the one-line width, which reaches
	 * the limit for every declaration whose args wrap. This arm measures the
	 * head statically instead (`DocMeasure.breakableHead`) and drives the
	 * plain `_diwe` column probe with a shifted threshold, so the break
	 * fires exactly when no amount of RHS-internal wrapping can bring the
	 * header back under the limit. `endsAtOpenDelim` keeps it off a head
	 * that ends at an OPERAND — an operator chain led by a literal or an
	 * identifier, the shape whose double-break motivated the narrow gates
	 * above. A chain led by a bracketed construct DOES arm: its head is a
	 * genuinely over-wide line and the chain's own break points are all
	 * past it.
	 */
	private static function breakAfterLeadOnOverflowWrap(leadText: String, writeCall: Expr, typeFieldName: String): Expr {
		final typeAccess: Expr = { expr: EField(macro value, typeFieldName), pos: Context.currentPos() };
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _rhs: anyparse.core.Doc = $writeCall;
			final _lhsType = $typeAccess;
			final _lhsHasTypeParam: Bool = _lhsType != null && Type.enumConstructor(_lhsType) == 'Named' && {
				final _p = Reflect.field(Type.enumParameters(_lhsType)[0], 'params');
				_p != null && (_p: Array<Dynamic>).length > 0;
			};
			final _rhsCtor: String = Type.enumConstructor(cast _optVal);
			// ω-comprehension-fit-measure: a `for`/`while` array comprehension
			// DISARMS gate 1. Gate 1 exists for a RHS the writer cannot wrap
			// internally; a comprehension's `[` IS its wrap point, and the fork
			// wraps the RHS bracket rather than the `=` (see the natural-probe
			// paragraph above). The probe is meant to notice that on its own,
			// but it resolves the bracket's Group one column EARLIER than the
			// renderer does — the renderer holds the post-`=` `OptSpace` pending
			// while the probe spends it — so at exactly `maxLineLength + 1` the
			// probe still sees the comprehension flat and breaks the `=`, while
			// the renderer would have opened the bracket.
			//
			// This DEFERS that column skew, it does not remove it: every other
			// gate-1 RHS (a `new`, a NoWrap-pinned call under a type-param LHS)
			// still carries the same ±1. Fixing it at the source means teaching
			// `Renderer.fitsFlat`'s plain-`Group` arm to charge
			// `RenderCtx.pendingOptSpace` the way its `GroupWithRestProbe` arm
			// already does — a renderer-wide change, not a comprehension one.
			//
			// Evaluated only when gate 1 would otherwise fire; a comprehension
			// RHS under a param-less LHS reaches the same decl-header arm either
			// way, so the probe would be pure cost there. Element classification
			// is the shared `HaxeFormat.isComprehensionGenerator` seam (it also
			// absorbs the trivia-synth `{node: …}` wrapper and any non-enum
			// element), so a new generator ctor is taught in ONE place.
			// `Type.enumParameters` slot 0 is `ArrayExpr.elems` in both the plain
			// and the trivia writer — `TriviaTypeSynth` APPENDS its synth args.
			final _rhsIsComprehension: Bool = _lhsHasTypeParam && _rhsCtor == 'ArrayExpr' && {
				final _elems: Null<Array<Dynamic>> = cast Type.enumParameters(cast _optVal)[0];
				_elems != null && _elems.length > 0 && anyparse.grammar.haxe.HaxeFormat.isComprehensionGenerator(_elems[0]);
			};
			if ((_lhsHasTypeParam && !_rhsIsComprehension) || _rhsCtor == 'SingleStringExpr' || _rhsCtor == 'DoubleStringExpr')
				_dc([
					_dt($v{leadText}),
					_dinfle(opt.lineWidth, _dn(_cols, _dc([_dhl(), _rhs])), _dc([_dop(' '), _rhs]))
				]);
			else {
				// Decl-header arm (last resort). `_head.width` is what the
				// glued shape keeps on THIS line once the RHS's own wrap
				// fires — `= new Foo(` for a call whose args leading-break.
				// Armed only when that head ENDS at the open delimiter: a
				// head ending at an OPERAND belongs to an operator chain
				// that carries its wrap on its own LATER lines, and breaking
				// the `=` there double-breaks it (fork breaks the chain).
				final _eqGlued: anyparse.core.Doc = _dc([_dop(' '), _rhs]);
				final _head: { width: Int, endsAtOpenDelim: Bool } = anyparse.core.DocMeasure.breakableHead(_eqGlued);
				// `_diwe` probes `col + flatTokenWidth(flatDoc) >= n` at
				// RENDER time over the very Doc passed as `flatDoc`, so
				// shifting the threshold by that same flat width makes the
				// effective test `col + _head.width > opt.lineWidth` — a
				// header EXACTLY on the limit stays glued (the width+1
				// convention the other fits-probes share). The cancellation
				// assumes `_eqGlued`'s flat width is the same at build and at
				// render: `CollapsePass` descends `IfWidthExceeds`'s flat
				// side, so a future collapse rule that RESIZES a decl RHS
				// would skew this threshold by the delta.
				final _flatW: Int = anyparse.core.DocMeasure.flatTokenWidth(_eqGlued);
				if (_head.endsAtOpenDelim)
					_dc([
						_dt($v{leadText}),
						_diwe(opt.lineWidth + 1 - _head.width + _flatW, _dn(_cols, _dc([_dhl(), _rhs])), _eqGlued)
					]);
				else
					_dc([_dt($v{leadText}), _dop(' '), _rhs]);
			}
		};
	}

	/**
	 * ω-condition-parens (Stage C): build the mandatory-Ref writeCall when
	 * `@:fmt(sharpCondParensInside('<openKnob>', '<closeKnob>'))` is present — a
	 * runtime rewrite of the verbatim `#if (cond)` string that injects inner
	 * parens padding per the named WhitespacePolicy knobs. Returns `rawWriteCall`
	 * unchanged when the meta is absent.
	 */
	private static function buildSharpInsideWriteCall(sharpInsideArgs: Null<Array<String>>, fieldAccess: Expr, rawWriteCall: Expr): Expr {
		if (sharpInsideArgs == null || sharpInsideArgs.length != 2) return rawWriteCall;
		final openKnob: Expr = optFieldAccess(sharpInsideArgs[0]);
		final closeKnob: Expr = optFieldAccess(sharpInsideArgs[1]);
		final wpAfter: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'WhitespacePolicy', 'After']);
		final wpBoth: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'WhitespacePolicy', 'Both']);
		final wpBefore: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'WhitespacePolicy', 'Before']);
		return macro {
			// omega-cond-directive-binop: this arm emits the condition text ITSELF, so the
			// terminal's `@:writeNormalize('condOperatorSpacing')` never runs for it - the
			// `#if` head took this path while `#elseif`, which has no `@:fmt` on its cond
			// field, took the normalising one, and the two spelled the same condition
			// differently. Normalise here too, before the paren pad reads the text.
			final _condStr: String = anyparse.format.DirectiveCondition.spaceOperators(($fieldAccess: String), opt.condDirectiveOpSpacing);
			if (
				_condStr.length >= 2 && StringTools.fastCodeAt(_condStr, 0) == '('.code
				&& StringTools.fastCodeAt(_condStr, _condStr.length - 1) == ')'.code
			) {
				final _inner: String = _condStr.substr(1, _condStr.length - 2);
				final _op: anyparse.format.WhitespacePolicy = $openKnob;
				final _cp: anyparse.format.WhitespacePolicy = $closeKnob;
				final _openPad: String = _op == $wpAfter || _op == $wpBoth ? ' ' : '';
				final _closePad: String = _cp == $wpBefore || _cp == $wpBoth ? ' ' : '';
				_dt('(' + _openPad + _inner + _closePad + ')');
			} else
				_dt(_condStr);
		};
	}

	/**
	 * Apply the three SUB-POSITION suppress flags a mandatory-Ref child can carry.
	 *
	 * `@:fmt(suppressCallRestProbe)` (omega-call-grouprestprobe-subposition) marks a
	 * `Call` subtree that is not in statement/expression position — a ctor pattern
	 * (`case Nest(_, _) | Concat(_):`) must not wrap its args, the fork breaks the
	 * `|` chain instead. `@:fmt(suppressPatternRestProbe)` (ω-pattern-rest-probe)
	 * widens that to the WHOLE pattern subtree: nothing below it rest-probes the
	 * line, so the guard rather than the pattern absorbs the overflow.
	 * `@:fmt(suppressComplexItems)` (ω-complex-item-count) marks a case-pattern body
	 * or a switch subject so an array literal below it skips the per-element
	 * complexity classification — an enum-constructor pattern parses as a `Call` and
	 * would otherwise be counted.
	 *
	 * The two ω-flags are never cleared on descent, so a nested construct inherits
	 * both. `suppressCallRestProbe` IS cleared, by the collection-literal element arm
	 * in `TriviaSepLowering` (a nested call in a field VALUE must still wrap) — which
	 * is exactly the hole `suppressPatternRestProbe` exists to close, and the reason
	 * the two are separate flags rather than one.
	 *
	 * Application order is inert: each shim early-returns on its own flag and the
	 * `_b` chain base makes the copy happen once whichever call reaches it first.
	 */
	private static function subPositionSuppressOpt(child: ShapeNode, e: Expr): Expr {
		var out: Expr = e;
		if (child.fmtHasFlag('suppressCallRestProbe')) out = macro _setSuppressCallRestProbe($out, true, opt);
		if (child.fmtHasFlag('suppressPatternRestProbe')) out = macro _setSuppressPatternRestProbe($out, opt);
		return child.fmtHasFlag('suppressComplexItems') ? macro _setSuppressComplexItems($out, opt) : out;
	}

	/**
	 * ω-orphan-prefix-decl: read + validate `@:fmt(setBoolFlagFromStarCtor(optField,
	 * starField, ctorName))` off one field. Shared by the mandatory-Ref and the
	 * optional-Ref writer seats — the flag is a property of the FIELD, not of its
	 * optionality, and reading it in only one seat is how `HxTopLevelDecl.decl`
	 * going `@:optional @:absentOnEof` silently stopped suppressing extern-class
	 * blank lines.
	 */
	private static function readBoolFlagStarCtorArgs(child: ShapeNode): Null<Array<String>> {
		final args: Null<Array<String>> = child.fmtReadStringArgs('setBoolFlagFromStarCtor');
		if (args != null && args.length != 3) {
			final n: Int = args.length;
			Context.fatalError(
				'WriterLowering: @:fmt(setBoolFlagFromStarCtor) expects 3 string args (optField, starField, ctorName), got $n',
				Context.currentPos()
			);
		}
		return args;
	}

	/**
	 * ω-indent-objectliteral — wrap a Ref field's writer call in a runtime
	 * gate that, when the conditions hold, replaces the inline emission
	 * with `Nest(_cols, value)`:
	 *
	 *  1. The bound value's enum ctor matches `ctorName`.
	 *  2. The named knob `opt.<optField>:Bool` is true.
	 *  3. (3-arg form only) The named knob
	 *     `opt.<leftCurlyField>:BracePlacement` is `Next`.
	 *
	 * The 3-arg form mirrors haxe-formatter's
	 * `indentation.indentObjectLiteral=true` rule, which only fires when
	 * `{` lands on its own line — i.e. when the per-construct leftCurly
	 * placement is Allman (`Next` / `both`). In that layout the value's
	 * hardlines pick up one extra indent step: `var x =\n\t{...}` instead
	 * of `var x =\n{...}`. With `Same` (cuddled) leftCurly the wrap is
	 * inert — `{` already sits on the parent line, so the inner content's
	 * existing nest is enough (`var x = {\n\t...}` byte-identical to the
	 * pre-slice layout).
	 *
	 * The 2-arg form (ω-indent-complex-value-expr) drops the leftCurly
	 * check — the wrap fires whenever the ctor + opt knob match,
	 * unconditionally. Used for ctors where the leading `{` placement is
	 * fixed by the grammar (e.g. `IfExpr` always has `if (cond) {…}` on
	 * the same line as `if`) so a leftCurly gate would be inert. Mirrors
	 * haxe-formatter's `indentation.indentComplexValueExpressions=true`
	 * rule which adds an indent step to `if`/`switch`/`try` value
	 * expressions on RHS regardless of brace placement.
	 *
	 * Used by `@:fmt(indentValueIfCtor('<ctorName>', '<optField>'))` or
	 * `@:fmt(indentValueIfCtor('<ctorName>', '<optField>',
	 * '<leftCurlyField>'))` on RHS-style Ref fields. Multiple entries
	 * stack on the same field — `HxVarDecl.init` carries one entry for
	 * `('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly')`
	 * plus a second for `('IfExpr', 'indentComplexValueExpressions')`.
	 * All args are grammar-driven so the macro core stays format-neutral:
	 * the ctor name is local to the field's enum type, and runtime knobs
	 * live on the per-grammar `WriteOptions` struct (no base-options
	 * bloat for non-Haxe formats). New RHS sites opt in by tagging their
	 * field, no core edit required.
	 *
	 * The wrap is `Nest`, not `Group(IfBreak)`. An earlier draft tried
	 * to gate the indent on the value's own break decision via
	 * `Group(IfBreak(brk, flat))`, but `HxObjectLit.fields` emits a
	 * `BodyGroup` that the renderer's `fitsFlat` defers — the outer
	 * Group sees the IfBreak's flat branch as ~2 chars (just `{` + `}`
	 * with the BodyGroup deferred) and always picks flat, so the wrap
	 * never fired. Plain `Nest` sidesteps the measurement: when the
	 * value emits inline (no internal hardlines) `Nest` is inert — short
	 * literals stay cuddled (`var x = {a:1}`); when the value emits
	 * multi-line the hardlines pick up the extra indent step.
	 *
	 * The `_cols:Int` binding mirrors `bodyPolicyWrap` / `bareBodyBreakWrap`
	 * — `_dn(_cols, …)` reads the indent-step from `opt.indentChar` /
	 * `opt.indentSize` / `opt.tabWidth` per call so generated code does
	 * not assume any particular caller-side scope.
	 */
	private static function indentValueIfCtorWrap(
		writeCall: Expr, fieldAccess: Expr, ctorName: String, optField: String, ?leftCurlyField: String
	): Expr {
		final optAccess: Expr = optFieldAccess(optField);
		// ω-fieldlevel-var-value-expr-indent: the `indentComplexValueExpressions`
		// entry (value-position `if`/`switch`/`try` on a `var`/`final` RHS)
		// differs from the ObjectLit/Anon entries on two axes the fork's
		// token-tree indenter treats specially:
		//   1. Transparent prefix keywords. `var x = untyped if (…) … else …`
		//      parses with `UntypedExpr(IfExpr(…))` as the RHS ctor, so a plain
		//      top-ctor check misses `IfExpr`. The fork's `findIndentingCandidates`
		//      keeps `untyped`/`inline`/`cast`/`macro` in the candidate chain, so
		//      the inner `if` still indents. Mirror it by unwrapping those single-
		//      operand prefix wrappers before matching the ctor.
		//   2. Field-level force. The fork's `Indenter.isFieldLevelVar` sets
		//      `indentComplexValueExpressions = true` unconditionally for a class-
		//      member `var`/`final` RHS, regardless of the config knob — so the
		//      gate also fires when `opt._inFieldLevelVar` (set at
		//      `VarMember`/`FinalMember` via `_setFieldLevelVar`). Local-var inits
		//      keep the flag false and stay knob-gated.
		// Both axes are scoped to this one optField at macro time, so the
		// ObjectLit/Anon entries and every non-Haxe grammar stay byte-identical
		// (no `opt._inFieldLevelVar` / wrapper-unwrap code is emitted for them).
		final isComplexValueExpr: Bool = optField == 'indentComplexValueExpressions';
		final ctorMatch: Expr = isComplexValueExpr
			? macro {
				var _eff: Dynamic = $fieldAccess;
				var _effCtor: String = Type.enumConstructor(_eff);
				while (_effCtor == 'UntypedExpr' || _effCtor == 'InlineExpr' || _effCtor == 'CastExpr' || _effCtor == 'MacroExpr') {
					_eff = Type.enumParameters(_eff)[0];
					_effCtor = Type.enumConstructor(_eff);
				}
				_effCtor == $v{ctorName};
			}
			: macro Type.enumConstructor($fieldAccess) == $v{ctorName};
		final gateAccess: Expr = isComplexValueExpr ? macro (opt._inFieldLevelVar || $optAccess) : optAccess;
		final condExpr: Expr = if (leftCurlyField == null)
			macro $gateAccess && $ctorMatch
		else {
			final leftCurlyAccess: Expr = optFieldAccess(leftCurlyField);
			macro $gateAccess && $leftCurlyAccess == anyparse.format.BracePlacement.Next && $ctorMatch;
		};
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _doc: anyparse.core.Doc = $writeCall;
			if ($condExpr)
				_dn(_cols, _doc)
			else
				_doc;
		};
	}

	/**
	 * Read every `@:fmt(indentValueIfCtor(...))` entry off `child` and
	 * chain a wrap per entry. Returns the (possibly multi-wrapped) writer
	 * call when any entry is present, the raw call when none. Both Ref-
	 * field branches (optional + mandatory) in `lowerStruct` route through
	 * this single helper to avoid duplicating the meta-validation block.
	 *
	 * Each entry accepts 2 args (`ctorName, optField`) or 3 args
	 * (`ctorName, optField, leftCurlyField`); the 2-arg form drops the
	 * leftCurly gate. Entries' ctor names are mutually exclusive in
	 * practice (an `HxExpr` value's runtime ctor is one of its variants)
	 * so at most one wrap fires per render — chaining is safe.
	 */
	private static function maybeIndentValueIfCtor(rawWriteCall: Expr, fieldAccess: Expr, child: ShapeNode): Expr {
		final all: Array<Array<String>> = child.fmtReadStringArgsAll('indentValueIfCtor');
		if (all.length == 0) return rawWriteCall;
		var current: Expr = rawWriteCall;
		for (entry in all) {
			if (entry.length != 2 && entry.length != 3)
				Context.fatalError(
					'WriterLowering: @:fmt(indentValueIfCtor(...)) requires (ctorName, optField) or ('
					+ 'ctorName, optField, leftCurlyField), got ${entry.length} args',
					Context.currentPos()
				);
			final lc: Null<String> = entry.length == 3 ? entry[2] : null;
			current = indentValueIfCtorWrap(current, fieldAccess, entry[0], entry[1], lc);
		}
		return current;
	}

}
#end
