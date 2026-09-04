package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.PrattMeta.*;
import anyparse.macro.WriterBlankLowering.*;
import anyparse.macro.WriterPolicyLowering.*;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterChainLowering.*;
import anyparse.macro.MacroNames.*;

using StringTools;
using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W helpers - the Pratt branch emit family.
 *
 * Builds the generated writer body for every OPERATOR branch of an `@:peg`
 * enum: `@:ternary`, `@:infix` (flat, tight-assign and the runtime chain
 * dispatch), `@:prefix` and `@:postfix` - including the postfix Star that
 * carries a call / index / cascade argument list, its inside-delimiter
 * policy spacing and its `WrapList` emit.
 *
 * Split out of `WriterLowering` for size. The family is a LEAF of that
 * module's call graph: four entries from `lowerEnumBranch` (one per
 * operator class) and nothing else reaches in, which is why it could
 * leave whole.
 *
 * Every member is static and the build state arrives as one
 * `PrattLoweringCtx` bundle, built once in `WriterLowering`'s constructor.
 * That bundle IS the boundary: two data fields (`shape`, `ctx`) and the
 * two shape-name helpers this family asks for (`ruleValueCT`,
 * `writeFnFor`). Nothing else here reads a `WriterLowering` instance, so
 * the whole module is a pure function of its arguments - and adding a
 * dependency means adding a bundle field, which is the point.
 *
 * The two parameter typedefs (`WriterLowering.LowerBranchCtx`,
 * `WriterLowering.PostfixStarCtx`) stay qualified: the extraction moved
 * the functions, not the typedefs, and `LowerBranchCtx` is shared with the
 * enum branch shapes that stayed behind.
 *
 * `WriterLowering.COMPLEX_ITEM_KINDS_PRED` also stays behind - it is the
 * shared spelling of one `@:fmt` flag read at TWO emit sites (the plain
 * postfix Star here, the trivia sep-Star in `TriviaSepLowering`), and a
 * name two modules reach for belongs to neither of them.
 *
 * The GENERATED-code surface is the real contract: every helper splices
 * identifiers declared elsewhere in the branch body (`_args`, `_docs`,
 * `_sepBeforeFlags`, the `_d*` Doc wrappers `WriterCodegen` emits on the
 * generated class) and none of that is visible to a type.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterCascadeLowering, anyparse.macro.WriterChainLowering,
	anyparse.macro.WriterLoweringSupport, anyparse.macro.WriterPolicyLowering)
final class WriterPrattLowering {

	/**
	 * Assignment-class emit (`prec == 0`, non-tight): the flat per-level
	 * `left = right` shape, plus — for a plain `=` — the runtime dispatch that
	 * routes a genuine CHAIN through `BinaryChainEmit.emitAssignChain`.
	 *
	 * ω-assign-chain-fill: `=` is right-assoc, so `a = b = c = v` nests as
	 * `Assign(a, Assign(b, Assign(c, v)))` and the per-level `Concat` hands the
	 * whole chain NO break opportunity -- an overflowing chain rendered on one
	 * over-long line and the writer still reported the file canonical.
	 *
	 * The gate is the operator TEXT, not `prec == 0`: that precedence also
	 * carries `in` / `->` / `=>` / `+=` / `??=` and friends, none of which may
	 * change shape here. `isAsymmetric` is excluded because the flatten is not
	 * merely pointless there but ill-typed: a `case Assign(_, _)` pattern does
	 * not match a right operand of a DIFFERENT rule type, and the tail write
	 * would have to go through `writeFnFor(rightRef)` rather than
	 * `c.writeFnName`. (Inert for every grammar in the repo -- Haxe's `Assign`
	 * is self-symmetric.)
	 *
	 * A NON-chain assignment falls back to `plainExpr`, the verbatim per-level
	 * emit. That fallback is the whole blast-radius argument: `a = b` produces
	 * the exact expression it produced before the slice, with no array, no
	 * closure and no probe; only chains, which had no wrap point at all, take
	 * the new path.
	 *
	 * Only the RIGHT spine recurses, and every left operand is written as a
	 * LEAF at `leftCtx` (`prec + 1`) while only the terminal right operand uses
	 * `rightCtx` (`prec`) -- which is what reproduces the nested emit's
	 * precedence-parenthesisation exactly. (Descending into `_l` could not
	 * match anyway: an explicit `(a = b) = c` keeps its own `ParenExpr` node,
	 * and a right-assoc parse never nests an `Assign` on the left.)
	 *
	 * `_optR` is the SAME opt expression the plain path threads into its right
	 * operand (`rightOptExpr`, derived from the branch's `propagateExprPosition`
	 * meta), bound ONCE and reused for every right-spine operand. It is
	 * `_setExprPosition(opt)`, which returns its argument unchanged once the
	 * expression-position flag is set and the narrow flags are clear
	 * (`WriterCodegen.setExprPositionField`), so a single binding is equivalent
	 * to the per-level application the nested emit performed. `_items[0]` --
	 * the OUTERMOST left operand -- keeps the unmodified `opt`, exactly as the
	 * plain path does.
	 *
	 * The hardcoded `Assign` ctor name follows `infixChainGatherSwitch`,
	 * which hardcodes `Or` / `And` / `Add` / `Sub` / `NullCoal` the same way;
	 * the switch subject's type (`ruleValueCT(typePath)`) resolves it against
	 * the plain enum or its trivia twin. `Assign` carries no capture metas,
	 * so its arity is 2 in BOTH modes -- unlike the chain ctors, which grow
	 * three trivia synth slots and need a `_ctx.trivia` fork here.
	 */
	private static function assignEmitExpr(
		pc: PrattLoweringCtx, c: WriterLowering.LowerBranchCtx, opText: String, isAsymmetric: Bool, leftCtx: Int, rightCtx: Int,
		leftCall: Expr, rightOptExpr: Null<Expr>, rightEmit: Expr
	): Expr {
		final plainExpr: Expr = macro _dc([
			$leftCall,
			_dt(' '),
			_dt($v{opText}),
			_dop(' '),
			$rightEmit,
		]);
		if (opText != '=' || isAsymmetric) return plainExpr;
		final argTypeCT: ComplexType = pc.ruleValueCT(c.typePath);
		final rightArg: Expr = macro $i{c.argNames[1]};
		final rightOpt: Expr = rightOptExpr ?? macro opt;
		final leftItemCall: Expr = makeWriteCall(c.writeFnName, macro _l, c.hasPratt, leftCtx, macro _optR);
		final tailItemCall: Expr = makeWriteCall(c.writeFnName, macro _e, c.hasPratt, rightCtx, macro _optR);
		// The subject needs parens: bare `switch $rightArg {` parses the
		// following block as a `$name{...}` reification form, not as the
		// switch body.
		return macro switch ($rightArg) {
			case Assign(_, _):
				final _items: Array<anyparse.core.Doc> = [$leftCall];
				final _optR = $rightOpt;
				function _gatherAssign(_e: $argTypeCT): Void switch _e {
					case Assign(_l, _r):
						_items.push($leftItemCall);
						_gatherAssign(_r);
					case _: _items.push($tailItemCall);
				}
				_gatherAssign($rightArg);
				anyparse.format.wrap.BinaryChainEmit.emitAssignChain(_items, opt);
			case _: $plainExpr;
		};
	}

	/**
	 * Builds the `_gather` switch body for `lowerInfixChain`: walks the
	 * same-class chain ctors (Or/And or Add/Sub), pushing operators (and
	 * per-operand source-newline breaks in Trivia mode) and recursing on
	 * operands. Leaf operands fall through to `$leafCall`. Inlined as a
	 * macro Expr so its `case Or(...)` patterns resolve against the
	 * current writer's value type.
	 */
	private static function infixChainGatherSwitch(isChainBool: Bool, isChainNullCoal: Bool, threadBreaks: Bool, leafCall: Expr): Expr {
		// noqa: complexity
		// `??` is right-assoc (`NullCoal(a, NullCoal(b, c))`); the recurse-left /
		// push-op / recurse-right gather still yields items in infix order with a
		// per-gap `_afterComments` entry, so the flat chain-emit preserves the
		// post-`??` line comments the plain infix path used to drop.
		return isChainNullCoal
			? threadBreaks
				? macro switch _e {
					case NullCoal(_l, _r, _nl, _lc, _ac):
						_gather(_l);
						if (_lc != null) {
							_items[_items.length - 1] = _dc([_items[_items.length - 1], trailingCommentDocVerbatim(_lc, opt)]);
							_hasLeadComment = true;
						}
						_ops.push('??');
						_breaks.push(_nl);
						_afterComments.push(_ac != null ? trailingCommentDocVerbatim(_ac, opt) : null);
						if (_ac != null) _hasLeadComment = true;
						_gather(_r);
					case _: _items.push($leafCall);
				}
				: macro switch _e {
					case NullCoal(_l, _r):
						_gather(_l);
						_ops.push('??');
						_gather(_r);
					case _: _items.push($leafCall);
				}
			: threadBreaks
				? isChainBool
					? macro switch _e {
						case Or(_l, _r, _nl, _lc, _ac):
							_gather(_l);
							if (_lc != null) {
								_items[_items.length - 1] = _dc([_items[_items.length - 1], trailingCommentDocVerbatim(_lc, opt)]);
								_hasLeadComment = true;
							}
							_ops.push('||');
							_breaks.push(_nl);
							_afterComments.push(_ac != null ? trailingCommentDocVerbatim(_ac, opt) : null);
							if (_ac != null) _hasLeadComment = true;
							_gather(_r);
						case And(_l, _r, _nl, _lc, _ac):
							_gather(_l);
							if (_lc != null) {
								_items[_items.length - 1] = _dc([_items[_items.length - 1], trailingCommentDocVerbatim(_lc, opt)]);
								_hasLeadComment = true;
							}
							_ops.push('&&');
							_breaks.push(_nl);
							_afterComments.push(_ac != null ? trailingCommentDocVerbatim(_ac, opt) : null);
							if (_ac != null) _hasLeadComment = true;
							_gather(_r);
						case _: _items.push($leafCall);
					}
					: macro switch _e {
						case Add(_l, _r, _nl, _lc, _ac):
							_gather(_l);
							if (_lc != null) {
								_items[_items.length - 1] = _dc([_items[_items.length - 1], trailingCommentDocVerbatim(_lc, opt)]);
								_hasLeadComment = true;
							}
							_ops.push('+');
							_breaks.push(_nl);
							_afterComments.push(_ac != null ? trailingCommentDocVerbatim(_ac, opt) : null);
							if (_ac != null) _hasLeadComment = true;
							_gather(_r);
						case Sub(_l, _r, _nl, _lc, _ac):
							_gather(_l);
							if (_lc != null) {
								_items[_items.length - 1] = _dc([_items[_items.length - 1], trailingCommentDocVerbatim(_lc, opt)]);
								_hasLeadComment = true;
							}
							_ops.push('-');
							_breaks.push(_nl);
							_afterComments.push(_ac != null ? trailingCommentDocVerbatim(_ac, opt) : null);
							if (_ac != null) _hasLeadComment = true;
							_gather(_r);
						case _: _items.push($leafCall);
					}
				: isChainBool
					? macro switch _e {
						case Or(_l, _r):
							_gather(_l);
							_ops.push('||');
							_gather(_r);
						case And(_l, _r):
							_gather(_l);
							_ops.push('&&');
							_gather(_r);
						case _: _items.push($leafCall);
					}
					: macro switch _e {
						case Add(_l, _r):
							_gather(_l);
							_ops.push('+');
							_gather(_r);
						case Sub(_l, _r):
							_gather(_l);
							_ops.push('-');
							_gather(_r);
						case _: _items.push($leafCall);
					};
	}

	/**
	 * Infix branch (`pratt.prec`): binary operator emit. Resolves the
	 * operator shape (tight / assign / chain / group-wrap) and dispatches
	 * to the matching sub-builder; the group/line/nest fallback stays
	 * inline.
	 */
	private static function lowerInfixBranch(pc: PrattLoweringCtx, c: WriterLowering.LowerBranchCtx): Expr {
		// noqa: complexity
		final branch: ShapeNode = c.branch;
		final typePath: String = c.typePath;
		final writeFnName: String = c.writeFnName;
		final hasPratt: Bool = c.hasPratt;
		final argNames: Array<String> = c.argNames;
		final children: Array<ShapeNode> = branch.children;
		final prec: Int = (branch.annotations[AnnotationKeys.PRATT_PREC]: Int);
		final assoc: String = (branch.annotations[AnnotationKeys.PRATT_ASSOC]: Null<String>) ?? 'Left';
		final opText: String = getOperatorText(branch);
		final leftCtx: Int = assoc == 'Right' ? prec + 1 : prec;
		final rightCtx: Int = assoc == 'Right' ? prec : prec + 1;
		final infixPolicyFlag: Null<String> = firstFmtFlag(branch, ['functionTypeHaxe3', 'intervalPolicy']);
		final isTight: Bool = branch.fmtHasFlag('tight') || infixPolicyFlag != null;
		final isAssign: Bool = prec == 0;
		final opWithSpaces: String = isTight ? opText : ' $opText ';
		final isChainBool: Bool = opText == '||' || opText == '&&';
		final isChainAddSub: Bool = opText == '+' || opText == '-';
		final isChainNullCoal: Bool = opText == '??';
		if (isTight || isAssign) return lowerInfixTightAssign(pc, c);
		if (isChainBool || isChainAddSub || isChainNullCoal) return lowerInfixChain(pc, c);
		// Asymmetric infix mirror of Lowering.lowerPrattLoop: when the
		// right child references a different enum (e.g. `Is(left:HxExpr,
		// right:HxType)`), the right operand uses that type's own writer
		// at its default ctxPrec (no precedence parenthesisation cross-
		// type). Self-symmetric branches keep the existing same-fn path.
		final rightChild: ShapeNode = children[1];
		final rightRef: Null<String> = rightChild.kind == Ref ? rightChild.annotations[AnnotationKeys.BASE_REF] : null;
		final isAsymmetric: Bool = rightRef != null && simpleName(rightRef) != simpleName(typePath);
		final rightOptExpr: Null<Expr> = branch.fmtHasFlag('propagateExprPosition') ? macro _setExprPosition(opt) : null;
		final leftCall: Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, leftCtx, null);
		final rightCall: Expr = isAsymmetric
			? makeWriteCall(pc.writeFnFor(rightRef), macro $i{argNames[1]}, false, -1, rightOptExpr)
			: makeWriteCall(writeFnName, macro $i{argNames[1]}, hasPratt, rightCtx, rightOptExpr);
		// Group/Line/Nest wrap for non-tight non-assign non-chain
		// infix (compare, shift, bitwise, `is`, `*`/`/`/`%`): lets
		// the renderer pick flat (Line(' ') → space) when the chain's
		// full flat width fits in the remaining columns, else break.
		// Per-binary Group cascading from G.1 (ω-binop-group-wrap).
		//
		// ω-binop-open-delim-glue (opadd_chain* B1-remainder): these
		// operators are NOT wrap-points in the fork — `MarkWrapping`
		// wrap-marks ONLY `Binop(OpAdd)` / `Binop(OpLt)` (type param) /
		// `Binop(OpArrow)`; `*`/`/`/`%`/`>`/`<<`/`&`/`is`/compare
		// never break at the operator, only their bracketed operands
		// break. The legacy `Group(Concat([left, Nest(cols, [Line, op,
		// right])]))` breaks the soft `Line` whenever the content carries
		// a committed hardline — which happens when the RIGHT operand is
		// a paren-wrapped chain that wraps one-per-line (e.g.
		// `return 1 * (a + b + c + …)`). The enclosing `Mul` Group then
		// over-breaks `1\n\t* (…` where the fork keeps `1 * (` glued and
		// lets ONLY the inner paren's chain wrap. When the right operand
		// STARTS WITH an open delimiter (`(`/`[`/`{` — a paren-expr /
		// call / array / object whose bracket absorbs the break),
		// emit the operator GLUED (flat `left op right`, no Group/Line):
		// the bracketed operand carries the wrap inside its own delims.
		// `startsWithOpenDelim` is an O(left-spine) structural check
		// (NO render-time re-measure) so it is exponential-safe even on
		// deeply nested same-class binary trees (`(a * (b * (c …)))`) —
		// each level just glues, no probe nesting. Non-delim right
		// operands (leaf idents, prefix-op exprs) keep the legacy Group
		// break unchanged. Byte-inert when the bracketed operand does
		// not wrap (no hardline → the legacy Group never broke → glued
		// shape is byte-identical to the flat Group resolution).
		final opAfterText: String = '$opText ';
		// ω-compare-operand-linewrap: fork parity for the glued compare arm.
		// The fork's breakLongOpBoolOperandAtCompare +
		// preferCompareBreakOverInnerCallParamWrap break a `==` / `!=` (ONLY
		// those two ops) before the operator when the physical line genuinely
		// overflows (strict `>` -- exactly-on-limit stays glued), preferring
		// `call(args)\n\t== X` over wrapping the call's own args. The
		// unconditional glue below (open/close-delim operand carries the wrap)
		// is stale for Eq/NotEq: a bracketed operand whose own Group fits flat
		// leaves the trailing `== CONST` invisible to any probe and the line
		// lands >max (TM FileSystemBase.hx 170-col `|| call(...) == CONST)`).
		// Gate with IfLineExceeds(lineWidth + 1) -- same probe + `+1` strict-`>`
		// restoration as WrapList.emitCondition -- byte-inert unless the
		// rendered line overflows. The probe sits AFTER `_left` in the Concat
		// (wrapping only the `op right` tail) so its render-time col is the end
		// of `_left`'s LAST rendered line: a left operand that wrapped its own
		// call args (`call(\n\targs\n) != null`) leaves a short `)` line and the
		// op stays glued. Where `_left` renders flat, col_afterLeft +
		// flatWidth(op right) equals the whole-expr col_beforeLeft +
		// flatWidth(left op right) (flat width is additive) so the decision is
		// byte-identical to measuring the full compare.
		final isCompareBreakOp: Bool = opText == '==' || opText == '!=';
		// ω-keep-infix-rhs-comment: append a captured right-operand trailing
		// comment (position #3) after the binop, inside any precedence parens.
		final rhsTrailAccess: Null<Expr> = pc.ctx.trivia ? altSlotAccess(branch, children.length, argNames, ChainRhsTrail) : null;
		final rhsTrailExpr: Expr = rhsTrailAccess ?? macro (null: Null<String>);
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _left: anyparse.core.Doc = $leftCall;
			final _right: anyparse.core.Doc = $rightCall;
			// ω-binop-close-delim-glue (cond-paren-OPEN sibling): when the
			// LEFT operand ENDS with a close delim (`[…].indexOf(x)`,
			// `(chain)`), the bracketed operand wraps inside its own brackets
			// and the never-wrap-marked operator (`<`/`>`/`*`/`/`/compare)
			// must RIDE the close-delim line (`].indexOf(x) < 0`), not break
			// onto its own line. The right-spine mirror of the existing
			// `startsWithOpenDelim(_right)` head-glue; both keep the operator
			// glued so only the bracketed operand carries the break. Byte-
			// inert when the left operand does not wrap (no committed hardline
			// → the legacy Group never broke → glued shape is byte-identical).
			final _glued: anyparse.core.Doc = _dc([_left, _dt($v{opWithSpaces}), _right]);
			// ω-compare-operand-linewrap gate: the fork breaks `==`/`!=` before
			// the op on a genuine line overflow in EVERY context -- a statement
			// condition (`if (a == b)`), an assignment (`final x = call() == C`),
			// and a `||`/`&&` operand -- via `breakLongOpBoolOperandAtCompare`
			// plus the operand-overflow pass. The ONE exception is a ternary
			// CONDITION (`x = call() == true ? a : b`): outside a condition-wrap
			// the fork breaks the ternary (`?`/`:`) and leaves the compare glued,
			// so `opt._inTernaryCond` (set only on the ternary cond's opt in
			// `lowerTernaryBranch`) suppresses the break. But INSIDE a condition
			// wrap (`if (call() == C ? a : b)`) the fork's
			// `breakLongOpBoolOperandAtCompare` fires on the compare regardless of
			// the enclosing ternary -- so the suppression is lifted when
			// `opt._chainModeOverride == FillLineWithLeadingBreak` (the
			// condition-wrap signal, set at the `@:fmt(condWrap)` site and NOT
			// cleared through the ternary's `_copyOpt` override). The `_dile`
			// probe below keeps a call-args-wrapping left operand glued
			// (`call(\n\targs\n) != null`) because its short `)` last line does
			// not overflow. Field reads are safe: only Haxe declares infix, so
			// `lowerInfixBranch` is generated for Haxe alone.
			final _compareBreakOnOverflow: Bool = $v{isCompareBreakOp}
				&& (!opt._inTernaryCond || opt._chainModeOverride == anyparse.format.wrap.WrapMode.FillLineWithLeadingBreak);
			final _inner: anyparse.core.Doc = anyparse.format.wrap.WrapList.startsWithOpenDelim(_right)
				|| anyparse.format.wrap.WrapList.endsWithCloseDelim(_left)
				? _compareBreakOnOverflow
					? _dc([
						_left,
						_dile(
							opt.lineWidth + 1, _dn(_cols, _dc([_dhl(), _dt($v{opAfterText}), _right])),
							_dc([_dt($v{opWithSpaces}), _right])
						)
					])
					: _glued
				: _dg(_dc([
					_left,
					_dn(_cols, _dc([_dl(), _dt($v{opAfterText}), _right])),
				]));
			final _rhsTrail: Null<String> = $rhsTrailExpr;
			final _innerT: anyparse.core.Doc = _rhsTrail != null ? _dc([_inner, trailingCommentDocVerbatim(_rhsTrail, opt)]) : _inner;
			if ($v{prec} < ctxPrec)
				_dc([_dt('('), _innerT, _dt(')')])
			else
				_innerT;
		};
	}

	/**
	 * Infix chain sub-builder (ω-binop-wraprules): `||`/`&&`
	 * (opBoolChain) and `+`/`-` (opAddSubChain) gather the full
	 * same-class subtree into a flat `(items, ops)` pair, run the cascade
	 * once, and emit one `BinaryChainEmit` shape. The `_gather` switch is
	 * built inline (vs an external helper) so its `case Or(...)` /
	 * `case Add(...)` patterns resolve against the current writer's value
	 * type (`HxExpr` plain / `HxExprT` trivia).
	 */
	private static function lowerInfixChain(pc: PrattLoweringCtx, c: WriterLowering.LowerBranchCtx): Expr {
		// noqa: complexity
		final branch: ShapeNode = c.branch;
		final typePath: String = c.typePath;
		final writeFnName: String = c.writeFnName;
		final hasPratt: Bool = c.hasPratt;
		final argNames: Array<String> = c.argNames;
		final children: Array<ShapeNode> = branch.children;
		final prec: Int = (branch.annotations[AnnotationKeys.PRATT_PREC]: Int);
		final opText: String = getOperatorText(branch);
		final isChainBool: Bool = opText == '||' || opText == '&&';
		final isChainNullCoal: Bool = opText == '??';
		final isChainAddSub: Bool = opText == '+' || opText == '-';
		final chainRulesField: String = isChainAddSub ? 'opAddSubChainWrap' : 'opBoolChainWrap';
		// `??` (right-assoc null-coalescing) does NOT wrap at the operator: the fork
		// keeps the chain glued and lets an overflowing operand break its own
		// brackets. Route it through the chain engine only to preserve post-`??`
		// line comments (the plain path dropped them) -- a comment forces the Keep
		// shape via `_hasLeadComment`, while a comment-free `??` chain stays glued
		// under this NoWrap cascade.
		final chainRulesExpr: Expr = isChainNullCoal
			? macro ({
				rules: [],
				defaultMode: anyparse.format.wrap.WrapMode.NoWrap
			}: anyparse.format.wrap.WrapRules)
			: optFieldAccess(chainRulesField);
		final argTypeCT: ComplexType = pc.ruleValueCT(typePath);
		// Leaf operands render at the chain's own precedence. A
		// sub-expression with strictly lower prec (ternary inside
		// `||`, assign inside `+`) gets the parens it needs;
		// same-class operators are consumed by the extractor.
		// omega-call-grouprestprobe-subposition: a `Call` operand carries
		// `@:fmt(groupRestProbe)`; its rest-of-line fit bias would otherwise
		// count the whole chain tail (`+ x + (...)`) against the operand's own
		// args and split a call that fits on its own (the chain head
		// `f(a, b) + ...`). Suppress it so a chain operand wraps on its OWN
		// overflow (plain Group); the chain absorbs the rest via its operator
		// break / paren-open. Applies to every chain operand, `??` included.
		final leafCall: Expr = makeWriteCall(writeFnName, macro _e, hasPratt, prec, macro _setSuppressCallRestProbe(opt, true));
		// ω-keep-chain (increment 2): in Trivia mode the chain ctors
		// Add/Sub/And/Or carry a 3rd `chainNewline:Bool` synth arg (the
		// per-operand source-newline). Bind it (`_nl`) and push into the
		// `_breaks` array parallel to `_ops` so `BinaryChainEmit.emit`'s
		// `WrapMode.Keep` shaper can reproduce the source line breaks. In
		// Plain mode the ctors keep 2-operand arity and no `_breaks` is
		// threaded (chain stays glued via shapeNoWrap) → byte-inert.
		// Outer-ctor chainNewline (read via altSlotAccess; null in Plain)
		// — the gap before THIS branch's right operand (`argNames[1]`),
		// pushed between the two top-level gathers to stay parallel to
		// the outer `_ops.push(opText)`.
		final outerChainNl: Null<Expr> = pc.ctx.trivia ? altSlotAccess(branch, children.length, argNames, ChainNewline) : null;
		// All four chain ctors (Or/And/Add/Sub) carry `captureChainNewline`,
		// so `outerChainNl` is non-null in Trivia mode; the `!= null` guard
		// keeps `_breaks` declaration and the gatherSwitch's `_breaks.push`
		// strictly in lockstep (no half-wired state).
		final threadBreaks: Bool = pc.ctx.trivia && outerChainNl != null;
		final gatherSwitch: Expr = infixChainGatherSwitch(isChainBool, isChainNullCoal, threadBreaks, leafCall);
		// `_breaks` (parallel to `_ops`) only exists in Trivia mode.
		// ω-keep-chain head break (increment 2): a `return`→head source
		// newline is delivered via the shared `opt._varKwNewline` channel
		// (set by the `ReturnStmt` Case-3 `_setVarKwNewline` threading;
		// the same field VarStmt uses). Read it as the chain head break
		// (single `EVars` → declared at the outer block scope) and CLEAR
		// it on `opt` (folded into the `_clearCallArgChainNest` re-bind
		// below) so it does not leak to a nested chain / the multiVar
		// fold. Trivia-keep only; in Plain / non-keep the field is false
		// and untouched → byte-inert.
		// ω-keep-chain (increment: opadd_chain_keep): drop the chain
		// `_headBreak` when this Keep chain is wrapped by a return-context
		// `ParenExpr` (`_keepChainInParen`, declared just above) — the
		// `return`→value source newline is reproduced at the value level
		// (`returnBody` FitLine), NOT inside the paren. A bare-value chain
		// (opbool case-2) has `_keepChainInParen == false` → keeps headBreak.
		final headDecl: Expr = threadBreaks ? macro final _headBreak: Bool = opt._varKwNewline && !_keepChainInParen : macro {};
		// Fold `_clearVarKwNewline` into the `_clearCallArgChainNest`
		// re-bind so the head-break flag is consumed once at the
		// outermost chain (leaf/nested chains see it cleared).
		// ω-keep-chain (increment: opadd_chain_keep): additionally mark
		// `_keepFlatInner` on the leaf-operand opt when THIS chain's config
		// resolves to `WrapMode.Keep` (`$chainRulesExpr.defaultMode == Keep`).
		// A kept chain preserves source line structure verbatim (operand
		// lines may exceed `lineWidth`), so its operands' inner `ParenExpr`
		// must stay GLUED — the flag flips the `expressionParenHardFlatten`
		// emit to the unconditional-glue branch. Runtime-gated so a non-keep
		// chain (NoWrap / FillLine / OnePerLine) passes the flag through false
		// → byte-inert. The `_setKeepFlatInner` re-bind wraps the existing
		// clear chain so the flag rides the SAME opt the leaf `makeWriteCall`s
		// thread. Trivia+chain-only (`threadBreaks`); Plain keeps the legacy form.
		final clearOptExpr: Expr = threadBreaks
			? macro _setKeepFlatInner(
				_clearKeepChainInParen(_clearVarKwNewline(_clearCallArgChainNest(opt))),
				$chainRulesExpr.defaultMode == anyparse.format.wrap.WrapMode.Keep
			)
			: macro _clearCallArgChainNest(opt);
		final breaksDecl: Expr = threadBreaks ? macro final _breaks: Array<Bool> = [] : macro {};
		// ω-keep-infix-operand-comment: trivia-only flag set by the gather when
		// an operand carried a captured trailing comment; forces the chain's
		// Keep shape so the comment round-trips (line comment → operator on the
		// continuation line; block comment → inline).
		final hasLeadDecl: Expr = threadBreaks ? macro var _hasLeadComment: Bool = false : macro {};
		// ω-keep-infix-postop-comment: per-op comment trailing the operator
		// (parallel to _ops); null entries when no comment. Threaded to
		// BinaryChainEmit so shapeKeep appends `OP // c` and forces a break.
		final afterCommentsDecl: Expr = threadBreaks ? macro final _afterComments: Array<Null<anyparse.core.Doc>> = [] : macro {};
		final outerAfterComment: Null<Expr> = pc.ctx.trivia ? altSlotAccess(branch, children.length, argNames, ChainAfterComment) : null;
		final outerAfterPush: Expr = threadBreaks && outerAfterComment != null
			? macro {
				final _oac: Null<String> = ${outerAfterComment};
				_afterComments.push(_oac != null ? trailingCommentDocVerbatim(_oac, opt) : null);
				if (_oac != null) _hasLeadComment = true;
			}
			: macro {};
		// Top-level gather: head operand, the outer operator, the outer
		// ctor's source-newline (parallel to that operator), tail operand.
		final outerBreakPush: Expr = threadBreaks ? macro _breaks.push(${outerChainNl}) : macro {};
		// ω-keep-infix-operand-comment: the OUTER ctor's own operand-trailing
		// comment (this branch's left operand, captured before the operator)
		// attaches to the last gathered head item — the gather switch only sees
		// NESTED chain ctors, so the top-level comment is threaded here.
		final outerLeadComment: Null<Expr> = pc.ctx.trivia ? altSlotAccess(branch, children.length, argNames, ChainLeadComment) : null;
		final outerLeadAttach: Expr = threadBreaks && outerLeadComment != null
			? macro {
				final _olc: Null<String> = ${outerLeadComment};
				if (_olc != null) {
					_items[_items.length - 1] = _dc([_items[_items.length - 1], trailingCommentDocVerbatim(_olc, opt)]);
					_hasLeadComment = true;
				}
			}
			: macro {};
		final gatherInvoke: Expr = macro {
			_gather($i{argNames[0]});
			$outerLeadAttach;
			_ops.push($v{opText});
			$outerBreakPush;
			$outerAfterPush;
			_gather($i{argNames[1]});
		};
		// Thread `_breaks` (sourceBreakBefore) + `_headBreak` only in
		// Trivia mode; Plain keeps the legacy 6-arg call (chain glues).
		final emitCall: Expr = threadBreaks
			? macro anyparse.format.wrap.BinaryChainEmit.emit(
				_items, _ops, opt, $chainRulesExpr, _chainNestSuppress, _condWrapForced, _breaks, _headBreak, _hasLeadComment,
				_afterComments
			)
			: macro anyparse.format.wrap.BinaryChainEmit.emit(_items, _ops, opt, $chainRulesExpr, _chainNestSuppress, _condWrapForced);
		return macro {
			final _items: Array<anyparse.core.Doc> = [];
			final _ops: Array<String> = [];
			$breaksDecl;
			$hasLeadDecl;
			$afterCommentsDecl;
			// ω-condwrap-call-arg-nest + ω-callarg-chain-nest: suppress
			// the chain's OWN continuation `Nest(cols, …)` when an outer
			// context already supplied the `+cols` indent — either a
			// condWrap `FillLineWithLeadingBreak` brkShape
			// (`_chainModeOverride`, set at the `@:fmt(condWrap)` site via
			// `_setChainModeOverride`; only that mode expands
			// `WrapList.emitCondition` to `Nest(cols, [Line('\n'),
			// condDoc])`), or a leading-break call argument
			// (`_callArgChainNest`, set at the call's per-arg writer call
			// when `callParameterWrap.defaultMode == FLWLB`, whose
			// `shapeFillLineWithLeadingBreak` Nests the arg at +cols).
			// Read the flag from the inbound opt, then CLEAR
			// `_callArgChainNest` so only the OUTERMOST chain consumes it
			// — leaf operands / nested chains (written via `makeWriteCall`,
			// which threads this same `opt`) keep their own Nest.
			// `_chainModeOverride` is deliberately NOT cleared: condWrap
			// collapses every chain in the condition. Safe to read both
			// fields directly: only Haxe declares `||`/`&&`/`+`/`-` chain
			// infix (HxModuleWriteOptions carries the fields).
			// `_condWrapForced` distinguishes the cond-wrap collapse
			// (`_chainModeOverride == FLWLB`, set at the `@:fmt(condWrap)`
			// site) from a leading-break CALL-ARG (`_callArgChainNest`):
			// both suppress the chain's own Nest, but only the cond-wrap
			// case is a chain-UNWRAP candidate (ω-chain-keep-flat). A
			// call-arg chain must keep its configured break shape (fork
			// `unwrapBoolOps` fires inside `applyArrowWrapping`, never for
			// a chain that is itself a call argument — `opbool_in_call_
			// leading_break_preserved`, `opsub_chain_in_single_param_call`).
			final _condWrapForced: Bool = opt._chainModeOverride == anyparse.format.wrap.WrapMode.FillLineWithLeadingBreak;
			// ω-keep-chain (increment: opadd_chain_keep): a `WrapMode.Keep`
			// chain wrapped by an enclosing `ParenExpr` in a return-head-break
			// context (`opt._keepChainInParen`, set at the paren's inner opt)
			// suppresses its OWN continuation `Nest` — the value-level break
			// already supplied the +cols, so the chain operators co-indent
			// with the head (no +2cols compounding). The `$headDecl` below
			// likewise drops the chain `_headBreak`. Gated on the chain config
			// being Keep so non-keep chains in a paren are byte-inert.
			final _keepChainInParen: Bool = opt._keepChainInParen && $chainRulesExpr.defaultMode == anyparse.format.wrap.WrapMode.Keep;
			final _chainNestSuppress: Bool = _condWrapForced || opt._callArgChainNest || _keepChainInParen;
			$headDecl;
			final opt = $clearOptExpr;
			function _gather(_e: $argTypeCT): Void $gatherSwitch;
			$gatherInvoke;
			final _inner: anyparse.core.Doc = $emitCall;
			if ($v{prec} < ctxPrec)
				_dc([_dt('('), _inner, _dt(')')])
			else
				_inner;
		};
	}

	/**
	 * Infix tight / assign sub-builder: tight operators (`...`, arrow
	 * type) and assignment-class operators (prec 0) keep flat emission.
	 *
	 */
	private static function lowerInfixTightAssign(pc: PrattLoweringCtx, c: WriterLowering.LowerBranchCtx): Expr {
		final branch: ShapeNode = c.branch;
		final typePath: String = c.typePath;
		final writeFnName: String = c.writeFnName;
		final hasPratt: Bool = c.hasPratt;
		final argNames: Array<String> = c.argNames;
		final children: Array<ShapeNode> = branch.children;
		final prec: Int = (branch.annotations[AnnotationKeys.PRATT_PREC]: Int);
		final assoc: String = (branch.annotations[AnnotationKeys.PRATT_ASSOC]: Null<String>) ?? 'Left';
		final opText: String = getOperatorText(branch);
		final leftCtx: Int = assoc == 'Right' ? prec + 1 : prec;
		final rightCtx: Int = assoc == 'Right' ? prec : prec + 1;
		final infixPolicyFlag: Null<String> = firstFmtFlag(branch, ['functionTypeHaxe3', 'intervalPolicy']);
		final isTight: Bool = branch.fmtHasFlag('tight') || infixPolicyFlag != null;
		final isAssign: Bool = prec == 0;
		final opWithSpaces: String = isTight ? opText : ' $opText ';
		final rightChild: ShapeNode = children[1];
		final rightRef: Null<String> = rightChild.kind == Ref ? rightChild.annotations[AnnotationKeys.BASE_REF] : null;
		final isAsymmetric: Bool = rightRef != null && simpleName(rightRef) != simpleName(typePath);
		final rightOptExpr: Null<Expr> = rightOperandOptExpr(branch);
		final leftCall: Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, leftCtx);
		final rightCall: Expr = isAsymmetric
			? makeWriteCall(pc.writeFnFor(rightRef), macro $i{argNames[1]}, false, -1, rightOptExpr)
			: makeWriteCall(writeFnName, macro $i{argNames[1]}, hasPratt, rightCtx, rightOptExpr);
		// Assign / arrow ops (prec 0, non-tight): split the trailing
		// space into `_dop(' ')` (OptSpace) so the renderer drops it
		// when the RHS emits a leading break-mode hardline (e.g.
		// `dirty =\n\t\t\tdirty || ...` from a OnePerLine wrapping
		// chain on the RHS), avoiding a spurious `dirty = \n…`
		// trailing-space-before-newline. Flat emission is unchanged
		// — the next Text from `$rightCall` flushes the OptSpace.
		// Tight ops keep the original single-Text shape (no spaces).
		final opEmitExpr: Expr = infixPolicyFlag != null && infixPolicyFlag != 'intervalPolicy'
			? whitespacePolicyInfix(opText, infixPolicyFlag)
			: macro _dt($v{opWithSpaces});
		// ω-thin-arrow-body-marker: the infix `->` lambda (`arg -> body`,
		// Pratt path — no typedef field to carry `@:fmt(arrowBodyLineWrap)`
		// the way `HxThinParenLambda.body` does) opts into the same
		// `_dwb(_dilr(...))` arrow-body wrap marker via a ctor-level
		// `@:fmt(arrowBodyLineWrap)`. Besides the line-wrap itself, the
		// marker is what `WrapList.isArrowBodyMarker` detects — without it
		// a trailing `arg -> { … }` call arg never reaches the sole-arrow /
		// multi-arg block-lambda glue shapes and the enclosing call opens
		// every arg one indent deeper instead of keeping the head glued.
		final rightEmit: Expr = branch.fmtHasFlag('arrowBodyLineWrap') ? arrowBodyLineWrapExpr(rightCall) : rightCall;
		final ivOpExpr: Expr = intervalPolicyOp(opText);
		final innerExpr: Expr = if (infixPolicyFlag == 'intervalPolicy')
			macro {
				final _leftIv: anyparse.core.Doc = $leftCall;
				_dc([_leftIv, $ivOpExpr, $rightCall]);
			}
		else if (isAssign && !isTight)
			assignEmitExpr(pc, c, opText, isAsymmetric, leftCtx, rightCtx, leftCall, rightOptExpr, rightEmit)
		else
			macro _dc([
				$leftCall,
				$opEmitExpr,
				$rightCall,
			]);
		return macro {
			final _inner: anyparse.core.Doc = $innerExpr;
			if ($v{prec} < ctxPrec)
				_dc([_dt('('), _inner, _dt(')')])
			else
				_inner;
		};
	}

	/**
	 * Postfix branch (`postfix.op`): unary postfix (`x++`), bracketed
	 * access (`arr[i]`), suffix-Ref, or Star-suffix forms.
	 */
	private static function lowerPostfixBranch(pc: PrattLoweringCtx, c: WriterLowering.LowerBranchCtx): Expr {
		final branch: ShapeNode = c.branch;
		final typePath: String = c.typePath;
		final writeFnName: String = c.writeFnName;
		final hasPratt: Bool = c.hasPratt;
		final argNames: Array<String> = c.argNames;
		final children: Array<ShapeNode> = branch.children;
		final postfixOp: String = branch.annotations[AnnotationKeys.POSTFIX_OP];
		final postfixClose: Null<String> = branch.annotations[AnnotationKeys.POSTFIX_CLOSE];
		final operandCall: Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, c.precPostfix);
		if (children.length == 1) {
			final text: String = postfixOp + (postfixClose ?? '');
			return macro _dc([$operandCall, _dt($v{text})]);
		}
		if (children.length == 2 && children[1].kind == Star)
			return lowerPostfixStar(pc, branch, typePath, writeFnName, hasPratt, argNames, operandCall);
		if (children.length == 2) {
			final suffixRef: String = children[1].annotations.get(AnnotationKeys.BASE_REF);
			final suffixFn: String = pc.writeFnFor(suffixRef);
			final suffixCall: Expr = {
				expr: ECall(macro $i{suffixFn}, [macro $i{argNames[1]}, macro opt]),
				pos: Context.currentPos()
			};
			final close: String = postfixClose ?? '';
			if (close.length > 0) {
				// ω-bracket-config: `HxExpr.IndexAccess` (`@:postfix('[',
				// ']') @:fmt(accessBrackets)`) is the sole close-bearing
				// two-child postfix ctor. With the flag, pad the inside of
				// the subscript brackets per `accessBracketsOpen` /
				// `accessBracketsClose` (`arr[ i ]`); without it, the slots
				// collapse to `_de()` so the default `arr[i]` stays byte-
				// identical. The `index` is a mandatory Ref (never empty),
				// so no empty-bracket guard is needed here.
				if (!branch.fmtHasFlag('accessBrackets')) return macro _dc([$operandCall, _dt($v{postfixOp}), $suffixCall, _dt($v{close})]);
				final openInside: Expr = policyInsideSpace('accessBracketsOpen', false);
				final closeInside: Expr = policyInsideSpace('accessBracketsClose', true);
				return macro _dc([
					$operandCall,
					_dt($v{postfixOp}),
					$openInside,
					$suffixCall,
					$closeInside,
					_dt($v{close})
				]);
			}
			// Word-like postfix ops (ω-cond-splice `#if`) sit between two
			// token streams that would glue into one word — pad both sides.
			// ω-postfix-op-space: a branch with `@:fmt(capturePostfixOpSpace)`
			// re-emits the LEFT pad source-faithfully from the `opSpaceBefore`
			// synth slot (`f()#if …` stays glued, `f() #if …` keeps its space);
			// the right pad stays hard — the operator and its raw fragment
			// would glue into one word otherwise. Plain mode has no slot and
			// keeps the unconditional both-side pad.
			if (!~/[A-Za-z0-9_]$/.match(postfixOp)) return macro _dc([$operandCall, _dt($v{postfixOp}), $suffixCall]);
			final opSpaceAccess: Null<Expr> = pc.ctx.trivia ? altSlotAccess(branch, children.length, argNames, PostfixOpSpace) : null;
			return opSpaceAccess != null
				? macro _dc([
					$operandCall,
					_dt(($opSpaceAccess ? ' ' : '') + $v{postfixOp + ' '}),
					$suffixCall
				])
				: macro _dc([$operandCall, _dt($v{' ' + postfixOp + ' '}), $suffixCall]);
		}
		Context.fatalError('WriterLowering: unsupported postfix shape', Context.currentPos());
		throw 'unreachable';
	}

	/**
	 * Compute the call-arg `(`/`)` inner-padding Docs for a postfix Star.
	 * Honours `@:fmt(callParensInside)` (runtime `callParensInsideOpen` /
	 * `callParensInsideClose`) and, for a `(`-open ctor, the
	 * compress-successive-parenthesis policy (a runtime space before a
	 * leading object-literal arg). Instance method because `policyInsideSpace` reads `ctx`.
	 */
	private static function lowerPostfixCallInside(branch: ShapeNode, postfixOp: String, isTriviaStar: Bool): { open: Expr, close: Expr } {
		// ω-call-parens-inside (Stage B): `@:fmt(callParensInside)` opts the
		// call-arg `(`/`)` into runtime inner padding driven by
		// `opt.callParensInsideOpen` / `opt.callParensInsideClose` (the
		// `after`/`before` sub-policies of fork's `parenConfig.callParens`).
		// Threaded into the WrapList.emit / fillList / sepList `openInside` /
		// `closeInside` slots (the same slots `triviaSepStarExpr` uses for
		// anon-type braces). Default `None` on both → `_de()`, byte-identical
		// to the tight `bar1(x)`. Empty `()` short-circuits before padding in
		// every emit path (`items.length == 0` guard).
		final callInsideFlag: Bool = branch.fmtHasFlag('callParensInside');
		var callInsideOpen: Expr = callInsideFlag ? policyInsideSpace('callParensInsideOpen', false) : macro _de();
		final callInsideClose: Expr = callInsideFlag ? policyInsideSpace('callParensInsideClose', true) : macro _de();
		// ω-compress-successive-paren: mirror fork's
		// `whitespace.compressSuccessiveParenthesis` for a paren-call open
		// `(` immediately followed by an object-literal `{` argument. The
		// fork's `successiveParenthesis` keeps the brace's `Before` policy
		// space (`( {`) when the knob is `false`, and removes it (`({`) when
		// `true`. In anyparse the inter-bracket pad lives in the WrapList /
		// fillList / sepList `openInside` slot — so when the open delim is a
		// `(` (compile-time `postfixOp == '('`) we make `openInside` a
		// runtime-conditional space: emit `_dop(' ')` iff
		// `!opt.compressSuccessiveParenthesis` AND the first call argument
		// renders as an object literal (its enum ctor is `ObjectLit`). Only
		// the first arg can sit directly after `(` (later args are preceded
		// by `, `), so the check is on `_args[0]`. Default `true` keeps the
		// glued `TPath({…})` layout byte-identical. `_args` is in scope where
		// this Expr is spliced (the emit call sits inside the
		// `final _args = $argsAccess; …` body). Trivia mode wraps each elem in
		// `Trivial<T>` (`.node` holds the paired enum); plain mode is the raw
		// enum — mirror `elemRead`'s `isTriviaStar` branch.
		if (postfixOp == '(') {
			final firstArgNode: Expr = isTriviaStar ? macro _args[0].node : macro _args[0];
			final firstArgObjLit: Expr = macro _args.length > 0 && Type.enumConstructor(cast $firstArgNode) == 'ObjectLit';
			callInsideOpen = macro !opt.compressSuccessiveParenthesis && $firstArgObjLit ? _dop(' ') : $callInsideOpen;
			// ω-switch-after-paren: a `switch` expression as the FIRST call
			// argument spaces the open `(` — fork emits `f( switch x {` and
			// keeps the close `)` tight to the switch's `}`. The space is the
			// switch keyword's LEADING gap, gated on `opt.switchKwLeadingSpace`
			// (the fork's `whitespace.switchPolicy` `before` / `around`); with
			// the default (or `after` / `none`) there is no leading space and
			// the `(` stays tight. Both `SwitchExpr` and `SwitchExprBare`
			// count. Layered outside the objlit ternary so the switch space
			// wins; a first arg is never both.
			final firstArgSwitch: Expr = macro _args.length > 0 && opt.switchKwLeadingSpace && {
				final _sc: String = Type.enumConstructor(cast $firstArgNode);
				_sc == 'SwitchExpr' || _sc == 'SwitchExprBare';
			};
			callInsideOpen = macro $firstArgSwitch ? _dop(' ') : $callInsideOpen;
		}
		return { open: callInsideOpen, close: callInsideClose };
	}

	/** The wrap-cascade arm of `lowerPostfixSepListCall` (`WrapList.emit` / `fillList` / `sepList`). */
	@:access(anyparse.macro.WriterLowering)
	private static function lowerPostfixCascadeCall(pc: PrattLoweringCtx, c: WriterLowering.PostfixStarCtx): Expr {
		final postfixOp: String = c.postfixOp;
		final postfixClose: String = c.postfixClose;
		final elemSep: String = c.elemSep;
		final tcExpr: Expr = c.tcExpr;
		final callInsideOpen: Expr = c.callInsideOpen;
		final callInsideClose: Expr = c.callInsideClose;
		if (c.wrapRulesField != null) {
			final rulesExpr: Expr = optFieldAccess(c.wrapRulesField);
			// ω-keep-callclose-newline: keep the outer call's close `)` glued iff
			// the chain config is Keep AND the parser saw no newline before the
			// close (`argsCloseNewline == false`). Only a trivia Star carrying
			// `methodChain` has the parser slot; otherwise the signal is constant
			// `false` (byte-inert legacy close placement).
			final keepCloseGluedExpr: Expr = c.isTriviaStar && c.methodChainField != null ? {
				final chainRulesExpr: Expr = optFieldAccess(c.methodChainField);
				final closeNlExpr: Expr = { expr: EConst(CIdent(c.argNames[4])), pos: Context.currentPos() };
				macro $chainRulesExpr.defaultMode == anyparse.format.wrap.WrapMode.Keep && !$closeNlExpr;
			} : macro false;
			// ω-sep-faithful outer elide: thread the per-pair source sep flags
			// (built in `lowerPostfixStar`'s element loop for trivia Stars) so
			// the engine suppresses commas the source elided around conditional
			// element groups. Plain mode passes an empty array — index misses
			// read `false`, byte-identical to the previous `null`.
			// omega-call-grouprestprobe-subposition: the `Call` ctor carries
			// `@:fmt(groupRestProbe)` so a statement/expression-position call
			// subtracts the trailing `;`/rest-of-line width at the cascade-Group
			// fit -- wrapping its args at limit+1 (fork parity). Gated OFF in a
			// sub-position (`opt._suppressCallRestProbe`): a case-pattern ctor
			// (`Nest(_, _)`) keeps its args glued (the `|` chain breaks instead),
			// and a `??` operand keeps pristine plain-Group wrapping (the fork packs
			// the chain, not the operand args). Every non-`groupRestProbe` postfix
			// sep-list ctor passes a constant `false` -- byte-inert.
			final groupRestProbeExpr: Expr = c.branch.fmtHasFlag('groupRestProbe')
				? (macro !opt._suppressCallRestProbe && !opt._suppressPatternRestProbe)
				: (macro false);
			// ω-complex-item-count (D2): postfix-Star reader for
			// `@:fmt(complexItems)` (`HxExpr.Call`). Classifies each ARGUMENT so
			// the fill-mode chunk policy can give a call-bearing container
			// literal past the first argument a line of its own — the fork's
			// packing for `super(…, null,` / `[{…}]` / `true, false, false)`.
			// Suppressed inside a case pattern / switch subject for the same
			// reason the array literal is (an enum-ctor pattern parses as a
			// `Call`). Absent flag → `null`, byte-identical emission.
			final complexKindsCall: Expr = AstPredLowering.predCallExpr(
				pc.shape.root, pc.ctx.trivia, false, WriterLowering.COMPLEX_ITEM_KINDS_PRED, [macro cast _args]
			);
			final complexKindsExpr: Expr = c.branch.fmtHasFlag('complexItems')
				? macro {
					final _ck: Null<Array<Int>> = opt._suppressComplexItems ? null : $complexKindsCall;
					_ck;
				}
				: macro null;
			final wrapListExpr: Expr = macro anyparse.format.wrap.WrapList.emit(
				$v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt, $callInsideOpen, $callInsideClose, false, $rulesExpr, {
					appendTrailingComma: $tcExpr,
					groupRestProbe: $groupRestProbeExpr,
					sepBeforeFlags: _sepBeforeFlags,
					keepCloseGlued: $keepCloseGluedExpr,
					complexItemKinds: $complexKindsExpr
				}
			);
			if (!c.isTriviaStar) return wrapListExpr;
			final keepDoc: Expr = lowerPostfixKeepDoc(c);
			return macro $rulesExpr.defaultMode == anyparse.format.wrap.WrapMode.Keep ? $keepDoc : $wrapListExpr;
		}
		if (!c.branch.fmtHasFlag('fill'))
			return macro sepList(
				$v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt, $tcExpr, $callInsideOpen, $callInsideClose, false, false
			);
		final fillDouble: Bool = c.branch.fmtHasFlag('fillDoubleIndent');
		return macro fillList(
			$v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt, $tcExpr, $callInsideOpen, $callInsideClose, false, $v{fillDouble}
		);
	}

	/**
	 * Build the args-list emission call for a postfix Star — the three-way
	 * dispatch between the runtime `WrapList.emit` cascade (`@:fmt(wrapRules)`,
	 * with a hand-built `Keep`-mode Doc for trivia Stars), the Wadler
	 * `fillList` (`@:fmt(fill)`), and the default `sepList`. Instance method because `optFieldAccess` reads `ctx`.
	 */
	private static function lowerPostfixSepListCall(pc: PrattLoweringCtx, c: WriterLowering.PostfixStarCtx): Expr {
		// ω-callarg-own-line-comment: a LINE comment anywhere in the list pre-empts
		// the cascade (see `lowerPostfixForceMultiDoc`). Trivia-only — plain mode's
		// `_args` carry no comment slots and `_forceArgMulti` is a constant false.
		final cascade: Expr = lowerPostfixCascadeCall(pc, c);
		if (!c.isTriviaStar) return cascade;
		final forceMulti: Expr = lowerPostfixForceMultiDoc(c);
		return macro _forceArgMulti ? $forceMulti : $cascade;
	}

	/** Postfix Star-suffix form: `Call(operand, args:Array<T>)`. */
	private static function lowerPostfixStar(
		pc: PrattLoweringCtx, branch: ShapeNode, typePath: String, writeFnName: String, hasPratt: Bool, argNames: Array<String>,
		operandCall: Expr
	): Expr {
		// noqa: complexity
		final postfixOp: String = branch.annotations[AnnotationKeys.POSTFIX_OP];
		final postfixClose: String = branch.annotations[AnnotationKeys.POSTFIX_CLOSE] ?? '';
		final starNode: ShapeNode = branch.children[1];
		final inner: ShapeNode = starNode.children[0];
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final isSelfRef: Bool = simpleName(elemRefName) == simpleName(typePath);
		final elemFn: String = isSelfRef ? writeFnName : pc.writeFnFor(elemRefName);
		final elemSep: String = branch.annotations[AnnotationKeys.LIT_SEP_TEXT] ?? ',';

		// ω-postfix-starsuffix-trivia: when TriviaAnalysis auto-marks
		// the postfix Star-suffix Star with `trivia.starCollects=true`
		// (Call.args, IndexAccess analogues, etc.), TriviaTypeSynth wraps
		// each elem in `Trivial<elemT>`. Read `.node` for the element
		// write call and append `.trailingComment` (verbatim, with
		// delimiters intact) as `_dt(' ') + trailingCommentDoc` after
		// the element when non-null. Plain mode and non-trivia-collecting
		// Stars keep the pre-slice direct `_args[_i]` access.
		final isTriviaStar: Bool = pc.ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		final elemRead: Expr = isTriviaStar ? macro _args[_i].node : macro _args[_i];
		// ω-issue-423-mech-a: ctor-level `@:fmt(propagateExprPosition)` on a
		// postfix-Star ctor (e.g. `HxExpr.Call`, `HxNewExpr`) wraps each
		// element's opt arg in `_setExprPosition` so call/ctor args land in
		// expression-position and any case body deeper than them picks
		// `expressionCase` via the dispatched flat-gate.
		final propagateExpr: Bool = branch.fmtHasFlag('propagateExprPosition');
		// ω-callarg-chain-nest: ctor-level `@:fmt(callArgChainNest)` opt-in on a
		// call-arg postfix Star (`HxExpr.Call`). When the call uses leading-break
		// wrapping (`callParameterWrap.defaultMode == FillLineWithLeadingBreak`),
		// the per-element opt is wrapped in `_setCallArgChainNest` so a chain
		// argument suppresses its own continuation Nest — the leading-break
		// call-arg Nest already supplies the +cols indent. Runtime-gated on the
		// cascade default (mirror of the condWrap `_chainModeOverride` path);
		// consumed exactly once via `_clearCallArgChainNest` — at the outermost
		// infix chain (`lowerInfixChain`, which HONOURS it) or at a ternary
		// (`lowerTernaryBranch`, which only CLEARS it: a ternary always keeps its
		// own `?` / `:` Nest, so the flag is stale for its operands).
		// `wrapRulesField` is read here (and reused by the sepList dispatch below)
		// so the per-element opt and the args-list cascade share one lookup.
		final wrapRulesField: Null<String> = branch.fmtReadString('wrapRules');
		final wantChainNest: Bool = branch.fmtHasFlag('callArgChainNest');
		// ω-keep-callclose-newline: the postfix-Star ctor that drives method
		// chains (`HxExpr.Call`) carries `@:fmt(methodChain('<field>'))`. When the
		// chain config is `Keep`, a chain sole-arg renders source-faithfully via
		// `MethodChainEmit.shapeKeep` — a length-2-Nest shape that
		// `shapeFillLine`'s `isChainOPLBreak` cannot tell apart from a genuine
		// OnePerLine chain, so it would force the OUTER call's close `)` onto its
		// own line. Under Keep we instead follow the source: keep `)` glued unless
		// the parser recorded a newline before it (`argsCloseNewline`). The signal
		// is computed only when the ctor carries both `methodChain` and is a
		// trivia Star (the parser-captured slot exists); every other postfix Star
		// passes the engine default `keepCloseGlued = false` and stays byte-inert.
		final methodChainField: Null<String> = branch.fmtReadString('methodChain');
		var elemOptArg: Expr = propagateExpr ? macro _setExprPosition(opt) : macro opt;
		if (wantChainNest && wrapRulesField != null) {
			final wrapRulesAccess: Expr = optFieldAccess(wrapRulesField);
			elemOptArg = macro $wrapRulesAccess.defaultMode == anyparse.format.wrap.WrapMode.FillLineWithLeadingBreak
				? _setCallArgChainNest($elemOptArg, opt)
				: $elemOptArg;
		}
		// omega-call-grouprestprobe-subposition (nested call argument): the two
		// `wrapRules('callParameterWrap')` Stars (`HxExpr.Call` / `HxNewExpr`) write
		// each element with `_suppressCallRestProbe` set, so a `Call` in argument
		// position does NOT rest-probe the outer call's sibling args + trailing `;`.
		// The outer call opens its paren first; the inner call stays flat (fork
		// parity). `HxNewExpr` args lack `groupRestProbe`, so this gates on the shared
		// `callParameterWrap` cascade, not that flag. Compile-time gate -> byte-inert
		// for every non-call sep-list Star (type-params, function sigs, arrays, object
		// lits). Mirrors the case-pattern / `??` / chain-operand guards.
		if (wrapRulesField == 'callParameterWrap') elemOptArg = macro _setSuppressCallRestProbe($elemOptArg, true, opt);
		// omega-arrow-value-if-reflow: ctor-level `@:fmt(arrowValueIfElemTrail)`
		// stamps `_arrowValueIfElemTrailComment` on the element that CARRIES a
		// captured trailing comment. The comment after an arrow-body value-`if`
		// chain's LAST branch value belongs to this element, not to any field of
		// the `HxIfExpr` - so neither the chain's `else`-spine walk nor its
		// `_arrowValueIfBlocked` descent can see it, and the chain re-flowed with
		// the comment dangling off the glued line. Runtime-gated on the slot, so
		// every comment-free element keeps the pre-slice opt and stays byte-inert;
		// compile-time gated on the trivia Star, since the slot only exists there.
		if (isTriviaStar && branch.fmtHasFlag('arrowValueIfElemTrail'))
			elemOptArg = macro _args[_i].trailingComment != null ? _setArrowValueIfElemTrailComment($elemOptArg, opt) : $elemOptArg;
		final elemCallArgs: Array<Expr> = [elemRead, elemOptArg];
		if (isSelfRef && hasPratt) elemCallArgs.push(macro -1);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, elemCallArgs),
			pos: Context.currentPos()
		};

		final argsAccess: Expr = macro $i{argNames[1]};
		final tcExpr: Expr = trailingCommaExpr(branch);
		// ω-call-parens: a `@:postfix('(', ')')` ctor with
		// `@:fmt(callParens)` opts into a runtime-switched space before
		// the open delim, mirroring `funcParamParens` on a struct Star.
		// `openDelimPolicySpace` returns null when the flag is absent so
		// the pre-slice tight emission stays byte-identical.
		final openSpace: Null<Expr> = openDelimPolicySpace(branch, ['callParens']);
		final callInside: { open: Expr, close: Expr } = lowerPostfixCallInside(branch, postfixOp, isTriviaStar);
		final c: WriterLowering.PostfixStarCtx = {
			branch: branch,
			postfixOp: postfixOp,
			postfixClose: postfixClose,
			elemSep: elemSep,
			isTriviaStar: isTriviaStar,
			argNames: argNames,
			tcExpr: tcExpr,
			callInsideOpen: callInside.open,
			callInsideClose: callInside.close,
			wrapRulesField: wrapRulesField,
			methodChainField: methodChainField,
			elemCall: elemCall
		};
		final sepListCall: Expr = lowerPostfixSepListCall(pc, c);
		// ω-cond-end-call-glue: a callee whose trailing visible text ends with
		// `#end` (a conditional group / splice callee:
		// `#if a X #elseif b Y #end (args)`) keeps a space before the open
		// paren — `#end('curl')` is not a shape any config's callParens policy
		// produces from a human source. Runtime structural probe on the
		// operand Doc (bound once as `_pfxOperand`); every non-`#end` callee
		// keeps the pre-slice emission byte-identically.
		final dcArgs: Array<Expr> = [macro _pfxOperand];
		final condEndSpace: Expr = macro anyparse.format.wrap.WrapList.endsWithCondEnd(_pfxOperand)
			? _dt(' ')
			: ${openSpace ?? macro _de()};
		dcArgs.push(condEndSpace);
		dcArgs.push(sepListCall);
		final dcExpr: Expr = dcCall(dcArgs);
		final pushElemExpr: Expr = lowerPostfixPushElem(c);
		final tailExpr: Expr = lowerPostfixTailExpr(c, dcExpr);
		// ω-sep-faithful outer elide: per-pair `sepBefore` flags mirror the
		// array threading — `WrapList.emit` suppresses the engine's
		// inter-element comma when the source elided it (canonical:
		// `g(true #if FSE, true #end)` — no comma between the plain arg and
		// the following conditional group; it lives INSIDE the group).
		final sepFlagsInit: Expr = c.isTriviaStar ? macro _sepBeforeFlags.push(_i != 0 && !_args[_i - 1].sepAfter) : macro {};
		// ω-callarg-own-line-comment: set by the element loop when any argument
		// carries a LINE-style comment. Such a list has exactly one legal layout —
		// one argument per line — so it bypasses the wrap cascade entirely
		// (`lowerPostfixForceMultiDoc`), the way a sep-Star routes to its own
		// force-multi branch for the same reason. Trivia-only: plain-mode elements
		// carry no comment slots, so the local would be dead in that writer.
		final forceMultiDecl: Expr = c.isTriviaStar ? macro var _forceArgMulti: Bool = false : macro {};
		// ω-callarg-empty-inner-comment: for an empty argument list carrying a
		// captured inner comment (`f(/* c */)`), push the comment Doc into
		// `_docs` before the sep-list renders `()` so it emits `(/* c */)`.
		// Gated on the Call ctor having grown the `argsInnerComment` slot
		// (argNames[5]); every other postfix Star has no slot and stays inert.
		final innerCommentEmit: Expr = c.isTriviaStar && c.argNames.length > 5 ? {
			final innerRef: Expr = { expr: EConst(CIdent(c.argNames[5])), pos: Context.currentPos() };
			macro if (_args.length == 0) {
				final _ic: Null<String> = $innerRef;
				if (_ic != null) _docs.push(leadingCommentDoc(_ic, opt));
			};
		} : macro {};
		// ω-keep-call-leading-comment: prepend the parser-captured pre-callee
		// comment (argNames[6]) before the operand Doc so a call emits
		// `/* c */ f()` instead of relocating it inside the parens. Gated on the
		// slot existing; every non-Call postfix Star lacks it and stays inert.
		final callLeadingBind: Expr = c.isTriviaStar && c.argNames.length > 6 ? {
			final clcRef: Expr = { expr: EConst(CIdent(c.argNames[6])), pos: Context.currentPos() };
			macro {
				final _clc: Null<String> = $clcRef;
				_clc != null ? _dc([leadingCommentDoc(_clc, opt), _dt(' '), _pfxOperandBase]) : _pfxOperandBase;
			};
		} : macro _pfxOperandBase;
		return macro {
			final _pfxOperandBase: anyparse.core.Doc = $operandCall;
			final _pfxOperand: anyparse.core.Doc = $callLeadingBind;
			final _args = $argsAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			final _sepBeforeFlags: Array<Bool> = [];
			$forceMultiDecl;
			var _i: Int = 0;
			while (_i < _args.length) {
				$sepFlagsInit;
				$pushElemExpr;
				_i++;
			}
			$innerCommentEmit;
			$tailExpr;
		};
	}

	/**
	 * Prefix branch (`prefix.op`): `op operand`.
	 */
	private static function lowerPrefixBranch(c: WriterLowering.LowerBranchCtx): Expr {
		final prefixOp: String = c.branch.annotations.get(AnnotationKeys.PREFIX_OP);
		final operandCall: Expr = makeWriteCall(c.writeFnName, macro $i{c.argNames[0]}, c.hasPratt, c.precPostfix);
		return macro _dc([_dt($v{prefixOp}), $operandCall]);
	}

	/**
	 * Ternary branch (`@:fmt`-driven `ternary.op`): dispatch to the
	 * chain-emit engine with a degenerate 3-item / 2-op chain. Like the infix
	 * dispatch it CONSUMES `_callArgChainNest` (see the body) — but it never
	 * suppresses its OWN Nest, so the flag is cleared, not honoured.
	 */
	private static function lowerTernaryBranch(pc: PrattLoweringCtx, c: WriterLowering.LowerBranchCtx): Expr {
		final branch: ShapeNode = c.branch;
		final writeFnName: String = c.writeFnName;
		final hasPratt: Bool = c.hasPratt;
		final argNames: Array<String> = c.argNames;
		final ternaryOp: String = branch.annotations[AnnotationKeys.TERNARY_OP];
		final tPrec: Int = (branch.annotations[AnnotationKeys.TERNARY_PREC]: Int);
		final sep: String = (branch.annotations[AnnotationKeys.TERNARY_SEP]: String);
		// ω-compare-operand-linewrap: mark the ternary CONDITION's opt so a
		// `==`/`!=` compare that IS the condition suppresses its operand-overflow
		// break (`lowerInfixBranch` reads `opt._inTernaryCond`) -- the fork breaks
		// the ternary `?`/`:`, not the compare. Only the cond opt carries the
		// flag; `middleCall` / `rightCall` use the plain `opt`.
		final condCall: Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, tPrec + 1, macro _setInTernaryCond(opt, true));
		final middleCall: Expr = makeWriteCall(writeFnName, macro $i{argNames[1]}, hasPratt, -1);
		final rightCall: Expr = makeWriteCall(writeFnName, macro $i{argNames[2]}, hasPratt, -1);
		// ω-ternary-wrap: dispatch to the chain-emit engine with a
		// degenerate 3-item / 2-op chain (items = [cond, then, else],
		// ops = [ternaryOp, sep]). `BinaryChainEmit.shapeNoWrap`
		// produces `cond ? then : else` with `' op '` spacing —
		// byte-equivalent to the prior flat emit when the cascade
		// resolves to NoWrap (default). `OnePerLineAfterFirst` +
		// BeforeLast (haxe-formatter `ternaryExpression` canonical
		// break shape) yields `cond\n\t? then\n\t: else`. The chain
		// extractor is intentionally NOT applied here: nested ternary
		// `Ternary(a, b, Ternary(c, d, e))` renders the inner ternary
		// as a self-contained leaf Doc through the standard writer
		// path — each `?:` node runs the cascade independently.
		// Collapsing nested ternaries into a single chain is a future
		// slice (no current fixture demands it).
		final rulesExpr: Expr = optFieldAccess('ternaryWrap');
		// ω-keep-ternary-operand-comment: the two operand-trailing slots grown by
		// `@:fmt(captureTernaryTrail)`. Each attaches to its operand's Doc so the
		// comment travels with the operand under EVERY shape the cascade can pick.
		// A LINE comment additionally forces the source-faithful `Keep` shape with
		// every gap broken — a `//` runs to the newline, so leaving `? then` or
		// `: else` glued after it would comment the rest of the ternary out. A
		// BLOCK comment is inline-safe: it rides along and the cascade still
		// decides the layout (`a /* c */ ? b : c` stays flat when it fits).
		final condTrailAccess: Null<Expr> =
			pc.ctx.trivia ? altSlotAccess(branch, branch.children.length, argNames, TernaryCondTrail) : null;
		final thenTrailAccess: Null<Expr> =
			pc.ctx.trivia ? altSlotAccess(branch, branch.children.length, argNames, TernaryThenTrail) : null;
		final trailDecl: Expr = condTrailAccess != null && thenTrailAccess != null
			? macro {
				final _condTrail: Null<String> = ${condTrailAccess};
				final _thenTrail: Null<String> = ${thenTrailAccess};
				if (_condTrail != null) {
					_items[0] = _dc([_items[0], trailingCommentDocVerbatim(_condTrail, opt)]);
					if (StringTools.startsWith(_condTrail, '//')) _forceKeep = true;
				}
				if (_thenTrail != null) {
					_items[1] = _dc([_items[1], trailingCommentDocVerbatim(_thenTrail, opt)]);
					if (StringTools.startsWith(_thenTrail, '//')) _forceKeep = true;
				}
			}
			: macro {};
		return macro {
			// omega-ternary-operand-chain-nest: consume the chain-nest flag HERE, the
			// way every other chain dispatch does (`lowerInfixChain`'s
			// `_clearCallArgChainNest`). This dispatch passes `nestSuppress = false`
			// — a ternary ALWAYS adds its own +cols for the `?` / `:` lines — so the
			// +cols the flag advertises (a leading-break call argument's Nest, or the
			// `#if`-splice tail's enclosing chain) is NOT the base indent of the
			// OPERANDS: their branch line is. Left set, an operand that is itself a
			// chain suppresses ITS continuation Nest and the continuation co-indents
			// with `?` / `:`, reading as a third ternary rung
			// (`cond\n? a\n+ b\n: ''`). Every other host already cleared the flag
			// before the ternary saw it (an enclosing chain / paren consumed it),
			// which is why only the call-arg context rendered wrong.
			final opt = _clearCallArgChainNest(opt);
			final _items: Array<anyparse.core.Doc> = [$condCall, $middleCall, $rightCall];
			final _ops: Array<String> = [$v{ternaryOp}, $v{sep}];
			var _forceKeep: Bool = false;
			$trailDecl;
			// ternary-rest-aware: measure the ternary's trailing rest-of-stack
			// (the statement `;`, an enclosing argument `,`, ...) so a ternary whose
			// flat body ends AT the line limit but whose physical line overflows
			// breaks its `?`/`:` - the plain `Group(IfBreak)` pivot measures only
			// `col + flatWidth` and ignores that trailing content, leaving such a
			// ternary glued while the fork wraps it (which then opened an inner
			// branch paren or spilled past the limit). The fork wraps the ternary
			// in every host context (return / assignment / bare statement /
			// array / object field / lambda body / call argument) EXCEPT two,
			// where it keeps the ternary flat and wraps the host instead: a
			// string-interpolation body (`_chainModeOverride == NoWrap`, set at the
			// `${...}` body - the fork never wraps an interpolation) and a ternary
			// kept inside an explicit expression paren (`_keepChainInParen` - that
			// paren owns the wrap and opens itself, `return a + (cond ? b : c)`).
			// ω-keep-ternary-operand-comment: a line comment on an operand breaks
			// EVERY gap (`_ternaryBreaks` all-true under `Keep`) at `BeforeLast`,
			// which is both the only safe shape and the canonical broken ternary
			// the cascade itself emits (`cond\n\t? then\n\t: else`) — so the round
			// trip is byte-stable from the second pass on. The location is PINNED
			// rather than taken from the cascade: `AfterLast` emits ` ?` before the
			// break, which the comment would swallow.
			final _ternaryBreaks: Null<Array<Bool>> = _forceKeep ? [for (_ in _ops) true] : null;
			final _ternaryKeepLoc: Null<anyparse.format.wrap.WrappingLocation> = _forceKeep
				? anyparse.format.wrap.WrappingLocation.BeforeLast
				: null;
			final _inner: anyparse.core.Doc = anyparse.format.wrap.BinaryChainEmit.emit(
				_items, _ops, opt, $rulesExpr, false, false, _ternaryBreaks, false, _forceKeep, null,
				opt._chainModeOverride != anyparse.format.wrap.WrapMode.NoWrap && !opt._keepChainInParen, _ternaryKeepLoc
			);
			if ($v{tPrec} < ctxPrec)
				_dc([_dt('('), _inner, _dt(')')])
			else
				_inner;
		};
	}

}

/**
 * The build state the Pratt branch family reads, bundled once per
 * `WriterLowering` instance.
 *
 * `shape` and `ctx` are the two of the three build inputs this family
 * touches; `ruleValueCT` and `writeFnFor` are the shape-name helpers that
 * stayed in `WriterLowering` because most of their callers did. Handing
 * them over as fields rather than reaching back through the instance is
 * what keeps every member here static and the dependency surface written
 * down.
 */
typedef PrattLoweringCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final ctx: LoweringCtx;
	final ruleValueCT: (refName:String) -> ComplexType;
	final writeFnFor: (refName:String) -> String;
}
#end
