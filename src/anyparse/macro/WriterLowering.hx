package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using StringTools;
using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W of the macro pipeline — writer lowering.
 *
 * Walks the shape tree and emits one `WriterRule` per type in the grammar.
 * Each rule's body builds a `Doc` value from the typed AST node.
 * This is the structural inverse of `Lowering`, which emits parse bodies
 * that consume input and build AST nodes.
 *
 * Four trivia Star emit families live in sibling `#if macro` modules of
 * this package — `TriviaTryparseLowering`, `TriviaEofLowering`,
 * `TriviaSepLowering` and `TriviaBlockLowering`. Each is entered from one
 * or two members here under `@:access`, calls back into the shared
 * lowering utilities (`optFieldAccess`, `astPredCallT`,
 * `buildCascadeEmit`, `blankBefore2ExtrasExpr`, …) the same way, and types
 * its parameters with this module's sub-module typedefs, which stayed
 * behind.
 *
 * Generated code references `_dt`, `_dc`, `_dhl`, `_de` etc. — thin
 * wrappers over `Doc` constructors emitted by `WriterCodegen` on the
 * same class. This avoids direct enum constructor calls in `macro {}`
 * blocks, which trigger macro-time type checking.
 */
class WriterLowering {

	/**
	 * omega-arrow-value-if-reflow - the per-field opt-in flag read at four
	 * unrelated lowering sites (body policy, pre-kw separator, both branch
	 * opt-fanouts). Named once so a rename cannot desynchronise them; the
	 * class has no other flag-name constants, so this is the convention's
	 * first member rather than an existing group.
	 */
	private static inline final ARROW_VALUE_IF_SITE: String = 'arrowValueIfReflowSite';

	/** `@:fmt(arrowValueIfReflow)` arg count that carries the optional value-if FIT knob as its 4th arg. */
	private static inline final FIT_KNOB_ARG_COUNT: Int = 4;

	/**
	 * The grammar-supplied predicate that classifies an array-`[…]` ctor by its
	 * first element (1 map literal, 2 comprehension, 0 array literal). Named
	 * once because three emission paths ask for it — inner-bracket padding and
	 * both trivia sep-Star entry points — and they must ask the SAME question:
	 * a list that is a map to one of them and an array to another is a bug the
	 * user sees as inconsistent formatting.
	 */
	private static inline final ARRAY_BRACKET_KIND_PRED: String = 'arrayBracketKind';

	/**
	 * The grammar-supplied classifier behind `@:fmt(complexItems)` — one
	 * complexity code per element of a delimited list, for `WrapList`'s
	 * `complexItemKinds` axis. Read at the two emit sites the flag has (the
	 * plain postfix-Star here, the trivia sep-Star in `TriviaSepLowering`),
	 * which must ask the SAME question for the same list.
	 *
	 * Addressed through `AstPredLowering` like every other grammar
	 * predicate. Both sites used to emit a direct call to
	 * `anyparse.grammar.haxe.HxComplexItems.kinds` instead — the last
	 * grammar type this package named, and the reason a second grammar
	 * could not have opted into `complexItems` at all.
	 */
	private static inline final COMPLEX_ITEM_KINDS_PRED: String = 'complexItemKinds';

	/** `@:fmt(valueBraceSymmetry)` required args (siblingField, blockCtor, stmtCtor); any further ones are skip-ctors. */
	private static inline final VALUE_BRACE_SYMMETRY_MIN_ARGS: Int = 3;

	/**
	 * ω-orphan-prefix-member — the first-field escape read at three sites that
	 * must agree on ONE answer: it also gates `TriviaTypeSynth.isBareNonFirstRef`
	 * (synthesise the slot) and `Lowering.computeBeforeSlots` (capture it), so a
	 * site spelling it differently would emit a read of a slot that does not
	 * exist, or drop a separator whose signal was captured.
	 */
	private static inline final BEFORE_NEWLINE_SLOT_FIRST: String = 'beforeNewlineSlotFirst';

	/**
	 * Build-scoped mirrors of `_shape.root` / `_formatInfo.astPreds` for
	 * the STATIC trivia emit helpers (the tryparse/block builder web),
	 * which have no instance in reach. Set at `generate()` entry; one
	 * writer build runs at a time, so the mirrors cannot interleave
	 * (`astPredCallT` fatal-errors if read before initialisation). The
	 * trivia builders address the trivia-family predicate class
	 * (`AstPredsT`) — plain-mode paths use the instance fields directly.
	 *
	 * Gating contract: `_astPredsOnStatic` is consulted ONLY at sites
	 * that have a legacy `schema.instance` channel to fall back to
	 * (`triviaBlockPredCallExpr`). The other trivia-web predicate sites
	 * are Haxe-only `@:fmt` features that never had a runtime fallback —
	 * they reference the marker class unconditionally, and a grammar
	 * that opts into such a meta without providing the classes fails
	 * loudly at typing. Do NOT add the gate to a new site unless it has
	 * a legacy channel to preserve.
	 */
	private static var _predRootStatic: String = '';

	/** See `_predRootStatic` — the second half of the same build-scoped mirror pair. */
	private static var _astPredsOnStatic: Bool = false;

	private final _shape: ShapeBuilder.ShapeResult;
	private final _formatInfo: FormatReader.FormatInfo;
	private final _ctx: LoweringCtx;

	public function new(shape: ShapeBuilder.ShapeResult, formatInfo: FormatReader.FormatInfo, ctx: LoweringCtx) {
		_shape = shape;
		_formatInfo = formatInfo;
		_ctx = ctx;
	}

	public function generate(): Array<WriterRule> {
		_predRootStatic = _shape.root;
		_astPredsOnStatic = _formatInfo.astPreds;
		final rules: Array<WriterRule> = [
			for (typePath => node in _shape.rules) for (rule in lowerRule(typePath, node)) rule
		];
		// Reset the mirrors so a stale root from THIS build can never
		// leak into a later build's static helpers — the astPredCallT
		// guard then catches any out-of-generate() read, not just the
		// cold start.
		_predRootStatic = '';
		_astPredsOnStatic = false;
		return rules;
	}

	/**
	 * ω-if-leader-case-symmetry: the case-UNIT flattener. A `#if`-guarded case
	 * region is ONE Star element whose Doc carries directive hardlines (flat
	 * width `-1`), so without this predicate the region could only FOLLOW a
	 * sibling's break, never LEAD one; it expands the region into its inner
	 * case elements, and both channels of the pre-pass then judge each one on
	 * its own.
	 */
	private inline function caseSiblingUnitsFnExpr(caseSymArgs: Null<Array<String>>, elemRefName: String): Null<Expr> {
		return casePredFnExpr(caseSymArgs, elemRefName, 'caseSiblingUnits');
	}

	/**
	 * ω-case-sibling-symmetry widened: the STRUCTURAL verdict, answering what
	 * the flat-width measurement cannot — whether a unit sits below its label
	 * for reasons of SHAPE (a multi-statement body, a single statement the
	 * flat-refusal gate rejects, or a label-splice region, whose shared body
	 * always renders below the labels it was split from). One `true` in the
	 * expanded unit list decides the whole switch, so the pre-pass short-
	 * circuits to `BodyFit.SIBLING_FORCE_BREAK` and never runs the measuring
	 * loop at all.
	 */
	private inline function caseSiblingStructuralFnExpr(caseSymArgs: Null<Array<String>>, elemRefName: String): Null<Expr> {
		return casePredFnExpr(caseSymArgs, elemRefName, 'caseUnitStructuralBreak');
	}

	/**
	 * The three-way blockEnded predicate channel, shared by the plain
	 * writer's sep-elision sites: no predicate → inert `false`; an
	 * `astPreds` format → the generated typed predicate of the build's
	 * AST family; otherwise the legacy `<schema>.instance.<predicate>`
	 * channel (the pilot formats' path — byte-identical to the
	 * pre-campaign emission).
	 */
	private function blockEndedPredCheck(predicateName: Null<String>, elemAccess: Expr): Expr {
		if (predicateName == null) return macro false;
		if (_formatInfo.astPreds) return AstPredLowering.predCallExpr(_shape.root, false, false, predicateName, [elemAccess]);
		final fmtParts: Array<String> = _formatInfo.schemaTypePath.split('.');
		return {
			expr: ECall({ expr: EField(macro $p{fmtParts}.instance, predicateName), pos: Context.currentPos() }, [elemAccess]),
			pos: Context.currentPos()
		};
	}

	private function lowerRule(typePath: String, node: ShapeNode): Array<WriterRule> {
		final fnName: String = writeFnFor(typePath);
		final valueCT: ComplexType = ruleValueCT(typePath);

		final hasPratt: Bool = node.kind == Alt && (hasPrattBranch(node) || hasPostfixBranch(node));

		final rawBody: Expr = switch node.kind {
			case Alt: lowerEnum(node, typePath, hasPratt);
			case Seq: lowerStruct(node, typePath);
			case Terminal: lowerTerminal(node);
			case _:
				Context.fatalError('WriterLowering: cannot lower ${node.kind} for $typePath', Context.currentPos());
				throw 'unreachable';
		};
		// ω-fmt-prewrite-hook: `@:fmt(preWrite(Pkg.Cls.fnName))` on the
		// rule's TYPE (enum, typedef, terminal) lets a plugin rewrite
		// the value before the default emission. Function signature:
		// `(<RuleType>, WriteOptions) -> Null<<RuleType>>` — non-null
		// re-dispatches through `fnName` so the rewritten value lands
		// on its own ctor branch / struct path. Used for shape-
		// conditional canonicalisation that fits no declarative
		// `@:fmt(...)` knob: e.g. `HxType.ArrowFn([Pos(Arrow)], R)` →
		// `Arrow(Parens, R)` for old-style curried chain rendering, or
		// `BlockComment.lines` per-line variant pick + indent
		// canonicalisation. The arg is a real Haxe expression (typically
		// `EField` field-access) — type-checked at compile time, IDE
		// go-to-def works, no string typo can survive compile.
		final preWriteFn: Null<Expr> = fmtReadCall(node, 'preWrite');
		final body: Expr = preWriteFn != null ? wrapWithPreWrite(preWriteFn, rawBody, fnName, typePath) : rawBody;
		return [
			{
				fnName: fnName,
				valueCT: valueCT,
				body: body,
				hasCtxPrec: hasPratt,
				isBinary: false
			}
		];
	}

	// -------- enum rule --------

	private function lowerEnum(node: ShapeNode, typePath: String, hasPratt: Bool): Expr {
		final writeFnName: String = writeFnFor(typePath);

		// Compute PREC_POSTFIX for Pratt enums: max(all prec values) + 1
		var precPostfix: Int = 0;
		if (hasPratt) {
			for (b in node.children) {
				final p: Null<Int> = b.annotations.get(AnnotationKeys.PRATT_PREC);
				if (p != null && p > precPostfix) precPostfix = p;
				final tp: Null<Int> = b.annotations.get(AnnotationKeys.TERNARY_PREC);
				if (tp != null && tp > precPostfix) precPostfix = tp;
			}
			precPostfix++;
		}

		final cases: Array<Case> = [];
		for (branch in node.children) {
			final ctor: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			final children: Array<ShapeNode> = branch.children;
			final extraArgs: Int = branchExtraArgs(branch);
			final argNames: Array<String> = [for (i in 0...children.length + extraArgs) '_v$i'];

			// Build pattern
			final ctorPath: Array<String> = ruleCtorPath(typePath, ctor);
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
			final pattern: Expr = if (children.length == 0)
				ctorRef
			else {
				final argExprs: Array<Expr> = [for (name in argNames) macro $i{name}];
				{ expr: ECall(ctorRef, argExprs), pos: Context.currentPos() };
			};

			// Build body. The `@:fmt(preWrite(...))` hook lives at the
			// rule level (see `lowerRule`), so per-ctor branches need no
			// additional wrapping here.
			final body: Expr = lowerEnumBranch(branch, typePath, writeFnName, hasPratt, argNames, precPostfix);
			// ω-methodchain-emit: ctors carrying `@:fmt(methodChain('<wrapField>'))`
			// (currently `HxExpr.Call` and `HxExpr.FieldAccess`) wrap their
			// case body with a runtime walk that detects two-or-more-segment
			// chains and emits via `MethodChainEmit` against the named
			// `WrapRules` cascade on `opt`. Non-chain values (single calls,
			// plain field access) fall through to the default emission.
			final chainField: Null<String> = branch.fmtReadString('methodChain');
			final wrappedBody: Expr = chainField != null ? wrapWithChainDispatch(body, chainField, writeFnName, node, precPostfix) : body;
			cases.push({ values: [pattern], expr: wrappedBody, guard: null });
		}
		return macro return ${{ expr: ESwitch(macro value, cases, null), pos: Context.currentPos() }};
	}

	/**
	 * ω-fmt-prewrite-hook — wrap a per-ctor case body so the writer
	 * first calls a plugin rewrite function, and on a non-null result
	 * re-dispatches through the rule's main writer. The recurse path
	 * routes the rewritten value back through the same `switch value`
	 * so any ctor produced by the rewrite lands on its proper branch
	 * (and on its own `@:fmt(...)` knobs). When the rewrite returns
	 * null the case falls back to the default emission.
	 *
	 * The hook lives at the case-branch level (not at function entry)
	 * so it fires only for the ctors that opt in via `@:fmt(preWrite)`
	 * — non-opt-in ctors carry zero overhead, no extra dispatch.
	 */
	private function wrapWithPreWrite(fnExpr: Expr, defaultBody: Expr, writeFnName: String, typePath: String): Expr {
		// preWrite signature: `(value:T, opt:WriteOptions) -> Null<T>`.
		// `opt` is passed through unconditionally so future rewrites can
		// branch on config (line width, comment style, etc.) without a
		// signature break — current consumers that don't need it accept
		// and ignore the param. Replace-value semantics: when the rewrite
		// returns non-null, the function's `value` parameter is reassigned
		// in place and the default emission body runs against the new
		// value. For enum rules the body's `switch value { ... }`
		// dispatches against the rewritten value naturally — no recursive
		// call to `$writeFnName`, so no risk of infinite loops on
		// rewrites that produce values still matching the same hook (e.g.
		// `anyparse.format.comment.BlockCommentNormalizer.normalize` always returns a canonical
		// `BlockComment`). For struct rules the body reads `value.<field>`
		// which now sees the rewritten value's fields. The single rule-
		// level wrap covers both kinds uniformly.
		//
		// ω-paired-converters (Phase A3): in trivia mode, the writer's
		// `value` is paired-T but the plugin signature accepts raw type.
		// Route through the synth-generated `Converters.pairedToRaw_<T>`
		// / `rawToPaired_<T>` helpers so plugins remain raw-only. The
		// rewrite path loses the source trivia by design — when the
		// plugin substitutes a different ctor shape, the original trivia
		// no longer fits and defaults to empty.
		final pos: Position = Context.currentPos();
		if (isTriviaBearing(typePath)) {
			final simple: String = simpleName(typePath);
			final convPath: Array<String> = packOf(typePath).concat(['trivia', 'Pairs', 'Converters']);
			final pairedToRawFn: Expr = MacroStringTools.toFieldExpr(convPath.concat(['pairedToRaw_$simple']));
			final rawToPairedFn: Expr = MacroStringTools.toFieldExpr(convPath.concat(['rawToPaired_$simple']));
			final userCall: Expr = { expr: ECall(fnExpr, [macro _raw, macro opt]), pos: pos };
			final wrapBack: Expr = { expr: ECall(rawToPairedFn, [macro _rw]), pos: pos };
			final unwrap: Expr = { expr: ECall(pairedToRawFn, [macro value]), pos: pos };
			return macro {
				final _raw = $unwrap;
				final _rw = $userCall;
				if (_rw != null) value = $wrapBack;
				$defaultBody;
			};
		}
		final preCall: Expr = { expr: ECall(fnExpr, [macro value, macro opt]), pos: pos };
		return macro {
			final _rw = $preCall;
			if (_rw != null) value = _rw;
			$defaultBody;
		};
	}

	/**
	 * ω-methodchain-emit — wrap a per-ctor case body with a writer-time
	 * chain extractor + cascade-driven emit.
	 *
	 * The pattern: at each entry to a ctor tagged
	 * `@:fmt(methodChain('<wrapField>'))` we walk down the AST collecting
	 * chain segments. Two segment shapes are recognised, both keyed off
	 * sibling enum ctors carrying the same `methodChain` flag:
	 *  - **Call segment** — `Call(FieldAccess(prev, fld), args)` — emits
	 *    `.<fld>(<args>)` with the inner args list routed through
	 *    `WrapList.emit` against the Call ctor's `wrapRules` /
	 *    `trailingComma` / postfix delimiters (preserving per-call
	 *    callParameter wrapping inside each segment);
	 *  - **Field segment** — `FieldAccess(prev, fld)` — emits `.<fld>`
	 *    (no args list).
	 *
	 * The walk also pulls out the chain `receiver` — the deepest
	 * non-chain operand (anything that doesn't match `Call(FieldAccess
	 * (Call,_), _)` / `FieldAccess(Call,_)` rest of the way down).
	 *
	 * When the walk finds at least one segment whose own receiver is a
	 * Call (`_hasCallPrev` — fork's `isDotAfterPClose` chain-start rule)
	 * the body short-circuits via a `return` to
	 * `MethodChainEmit.emit(receiverDoc, segs, opt, opt.<wrapField>)`.
	 * ω-methodchain-all-or-nothing widened that from two segments to one:
	 * `f(args).g(args)` is the shape where a single link glued to an
	 * over-wide head produced a line past `maxLineLength`, and the chain
	 * layout is the only decision that can move that link off the head
	 * line. `_segs.length` is not the real predicate — `_hasCallPrev` is,
	 * and it admits EVERY `.` that follows a `)`, so `f(args).b` (a bare
	 * field after a call) now routes through the chain layout too, and with
	 * it through every chain-aware gate in `WrapList`. That is the widening's
	 * true blast radius; it is wider than the `f(args).g(args)` shape that
	 * motivated it. Non-chain shapes — `a.b()` on a bare receiver, `a.b`
	 * plain field — still fall through to the default emission, so they pay
	 * only the cost of one `switch` per Call/FieldAccess ctor entry (no
	 * recursion, no allocation).
	 *
	 * Args list config (open/close/sep/wrapRules/trailingComma) is read
	 * from the sibling Call ctor's annotations — keeping the chain
	 * emit's arg formatting byte-identical to the regular call emit.
	 * `opt` and `ctxPrec` are in scope from the surrounding writer-fn
	 * signature; recursive renderings (receiver, args) call the same
	 * `$writeFnName` — for HxExpr trivia mode that's `writeHxExprT`,
	 * for plain mode `writeHxExpr`.
	 */
	private function wrapWithChainDispatch(body: Expr, chainField: String, writeFnName: String, node: ShapeNode, precPostfix: Int): Expr {
		final cb: ShapeNode = locateChainCallBranch(node);
		final callOpen: String = cb.annotations[AnnotationKeys.POSTFIX_OP];
		final callClose: String = cb.annotations[AnnotationKeys.POSTFIX_CLOSE] ?? '';
		final callSep: String = cb.annotations[AnnotationKeys.LIT_SEP_TEXT] ?? ',';
		final callWrapField: Null<String> = cb.fmtReadString('wrapRules');
		final callTcExpr: Expr = trailingCommaExpr(cb);
		// Args list shape: the Call ctor MUST carry `@:fmt(wrapRules(
		// '<field>'))` for the chain-emit's per-segment rendering to use
		// the same arg layout as a regular Call. Surfacing this as a
		// macro-time error rather than carrying a dead fallback per
		// architecture skill ("no complexity before pain"); a future
		// grammar that drops wrapRules can extend this path then.
		if (callWrapField == null)
			Context.error(
				'WriterLowering.methodChain: Call sibling ctor must carry @:fmt(wrapRules(\'<field>\')) '
				+ 'for the chain-emit per-segment args layout to share the regular call shape',
				Context.currentPos()
			);
		final cwf: String = callWrapField;
		final callRulesExpr: Expr = optFieldAccess(cwf);
		final argsListExpr: Expr = macro anyparse.format.wrap.WrapList.emit(
			$v{callOpen}, $v{callClose}, $v{callSep}, _argDocs, opt, _de(), _de(), false, $callRulesExpr,
			{ appendTrailingComma: $callTcExpr }
		);
		final chainRulesExpr: Expr = optFieldAccess(chainField);
		final writeIdent: Expr = {
			expr: EConst(CIdent(writeFnName)),
			pos: Context.currentPos()
		};
		// ω-postfix-starsuffix-trivia: per-arg Doc comprehension below
		// must mirror `lowerPostfixStar`'s trivia branch: when args are
		// `Array<Trivial<HxExprT>>` (auto-wrapped by TriviaTypeSynth),
		// read `.node` for the recursive write and append
		// `.trailingComment` verbatim. Plain-mode and grammars that
		// don't auto-collect on the postfix Star-suffix keep the
		// pre-slice direct `_a` access.
		final cbStar: ShapeNode = cb.children[1];
		final isCallTriviaStar: Bool = _ctx.trivia && cbStar.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		// ω-methodchain-reeval-after-callparam (axis 2): a chain segment's call
		// args bypass the normal `HxExpr.Call` postfix path's per-arg
		// `_setCallArgChainNest` wrapping (the chain segment goes through
		// `argsListExpr` here, not `lowerPostfixStar`). When the call uses
		// leading-break wrapping (`callParameterWrap.defaultMode == FLWLB`) AND
		// the Call ctor opted into `callArgChainNest`, wrap each segment-arg's
		// opt in `_setCallArgChainNest` so a chain / opAddSub argument suppresses
		// its OWN continuation Nest (the leading-break call-arg already supplies
		// the +cols). Without this an opAddSub arg of a re-glued chain's segment
		// call (the #3 `getInstance().add(<opAdd>)` shape) over-nests its
		// fillLine-beforeLast continuation by one tab. Runtime-gated on the
		// cascade default; mirror of the `lowerPostfixStar` path.
		final chainArgWantsNest: Bool = cb.fmtHasFlag('callArgChainNest');
		final segArgOpt: Expr = chainArgWantsNest
			? macro ($callRulesExpr.defaultMode == anyparse.format.wrap.WrapMode.FillLineWithLeadingBreak ? _setCallArgChainNest(opt) : opt)
			: macro opt;
		// ω-methodchain-reeval-after-callparam (axis 1 discriminator): the chain
		// re-glue (fork `reEvaluateMethodChainAfterCallParam`) fires ONLY when the
		// segment call's args wrap with a LEADING BREAK after the open paren
		// (`isNewLineAfter(POpen)`) — i.e. the call uses
		// `callParameterWrap.defaultMode == FillLineWithLeadingBreak`. A
		// `FillLine` default (glued first arg) or a glued arrow/lambda body that
		// breaks is NOT an `isNewLineAfter(POpen)` and keeps its dot-break. Pass
		// the runtime FLWLB fact to `MethodChainEmit.emit`.
		final segCallLeadingBreakExpr: Expr = macro $callRulesExpr.defaultMode == anyparse.format.wrap.WrapMode.FillLineWithLeadingBreak;
		final argDocsExpr: Expr = isCallTriviaStar
			? macro {
				final _argDocs: Array<anyparse.core.Doc> = [];
				final _segArgOpt = $segArgOpt;
				for (_a in _args) {
					final _aDoc: anyparse.core.Doc = $writeIdent(_a.node, _segArgOpt, -1);
					final _aTc: Null<String> = _a.trailingComment;
					// `trailingCommentDocGuarded` already prepends ' '. Group-closer
					// seam (mirror of `lowerPostfixPushElem`): the segment call's `)`
					// follows the last argument on the same Doc line, and a LINE
					// comment there swallows it plus the whole `.next()` tail. The
					// guard moves the `)` off the comment's line and drops before
					// an existing hardline; inside a force-flat region the renderer
					// drops it instead, which is why `WrapList.shapeNoWrap` skips
					// its `Flatten` marker for a guard-bearing body. Sound seams
					// stay byte-identical.
					_argDocs.push(_aTc != null ? _dc([_aDoc, trailingCommentDocGuarded(_aTc, opt)]) : _aDoc);
				}
				_argDocs;
			}
			: macro {
				final _segArgOpt = $segArgOpt;
				[for (_a in _args) $writeIdent(_a, _segArgOpt, -1)];
			};
		// Receiver renders at the postfix precedence so a binop /
		// ternary receiver gets parenthesised — `(a + b).foo().bar()`
		// must keep its parens or the chain misreads as
		// `a + b.foo().bar()`. Mirrors the `lowerEnumBranch` postfix
		// path which passes `precPostfix` for the same reason.
		final precExpr: Expr = macro $v{precPostfix};
		final c: ChainDispatchCtx = {
			argsListExpr: argsListExpr,
			argDocsExpr: argDocsExpr,
			chainRulesExpr: chainRulesExpr,
			writeIdent: writeIdent,
			precExpr: precExpr,
			segCallLeadingBreakExpr: segCallLeadingBreakExpr,
			body: body
		};
		return isCallTriviaStar ? wrapChainTriviaBody(c) : wrapChainPlainBody(c);
	}

	private function lowerEnumBranch(
		branch: ShapeNode, typePath: String, writeFnName: String, hasPratt: Bool, argNames: Array<String>, precPostfix: Int
	): Expr {
		final children: Array<ShapeNode> = branch.children;
		final litList: Null<Array<String>> = branch.annotations[AnnotationKeys.LIT_LIT_LIST];
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];

		final prefixOp: Null<String> = branch.annotations[AnnotationKeys.PREFIX_OP];
		final postfixOp: Null<String> = branch.annotations[AnnotationKeys.POSTFIX_OP];
		final prattPrec: Null<Int> = branch.annotations[AnnotationKeys.PRATT_PREC];
		final ternaryOp: Null<String> = branch.annotations[AnnotationKeys.TERNARY_OP];
		final c: LowerBranchCtx = {
			branch: branch,
			typePath: typePath,
			writeFnName: writeFnName,
			hasPratt: hasPratt,
			argNames: argNames,
			precPostfix: precPostfix
		};

		// ---- Ternary ----
		if (ternaryOp != null) return lowerTernaryBranch(c);

		// ---- Infix ----
		if (prattPrec != null) return lowerInfixBranch(c);

		// ---- Prefix ----
		if (prefixOp != null) return lowerPrefixBranch(c);

		// ---- Postfix ----
		if (postfixOp != null) return lowerPostfixBranch(c);

		// ---- Cases 0/1/2: zero-arg kw / zero-arg lit / multi-lit Bool ----
		final litKwDoc: Null<Expr> = lowerLitKwBranch(c);
		if (litKwDoc != null) return litKwDoc;

		// ---- Case 4: single-arg Star with lead/trail ----
		if (leadText != null && trailText != null && children.length == 1 && children[0].kind == Star)
			return lowerEnumStar(branch, typePath, writeFnName, hasPratt, argNames);

		// ---- Case 3: single-arg Ref ----
		if (litList == null && children.length == 1 && children[0].kind == Ref) return lowerKwRefBranch(c);

		Context.fatalError('WriterLowering: unsupported enum branch shape for ${simpleName(typePath)}', Context.currentPos());
		throw 'unreachable';
	}

	/** Postfix Star-suffix form: `Call(operand, args:Array<T>)`. */
	private function lowerPostfixStar(
		branch: ShapeNode, typePath: String, writeFnName: String, hasPratt: Bool, argNames: Array<String>, operandCall: Expr
	): Expr {
		// noqa: complexity
		final postfixOp: String = branch.annotations[AnnotationKeys.POSTFIX_OP];
		final postfixClose: String = branch.annotations[AnnotationKeys.POSTFIX_CLOSE] ?? '';
		final starNode: ShapeNode = branch.children[1];
		final inner: ShapeNode = starNode.children[0];
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final isSelfRef: Bool = simpleName(elemRefName) == simpleName(typePath);
		final elemFn: String = isSelfRef ? writeFnName : writeFnFor(elemRefName);
		final elemSep: String = branch.annotations[AnnotationKeys.LIT_SEP_TEXT] ?? ',';

		// ω-postfix-starsuffix-trivia: when TriviaAnalysis auto-marks
		// the postfix Star-suffix Star with `trivia.starCollects=true`
		// (Call.args, IndexAccess analogues, etc.), TriviaTypeSynth wraps
		// each elem in `Trivial<elemT>`. Read `.node` for the element
		// write call and append `.trailingComment` (verbatim, with
		// delimiters intact) as `_dt(' ') + trailingCommentDoc` after
		// the element when non-null. Plain mode and non-trivia-collecting
		// Stars keep the pre-slice direct `_args[_i]` access.
		final isTriviaStar: Bool = _ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
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
		final c: PostfixStarCtx = {
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
		final sepListCall: Expr = lowerPostfixSepListCall(c);
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

	/** Enum Case 4 Star: `@:lead @:trail` with optional `@:sep`. */
	private function lowerEnumStar(
		branch: ShapeNode, typePath: String, writeFnName: String, hasPratt: Bool, argNames: Array<String>
	): Expr {
		final leadText: String = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: String = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final kwLead: Null<String> = branch.annotations[AnnotationKeys.KW_LEAD_TEXT];
		final starNode: ShapeNode = branch.children[0];
		final inner: ShapeNode = starNode.children[0];
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final isSelfRef: Bool = simpleName(elemRefName) == simpleName(typePath);
		final elemFn: String = isSelfRef ? writeFnName : writeFnFor(elemRefName);

		final elemCallArgs: Array<Expr> = [macro _args[_i], macro opt];
		if (isSelfRef && hasPratt) elemCallArgs.push(macro -1);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, elemCallArgs),
			pos: Context.currentPos()
		};

		final argsAccess: Expr = macro $i{argNames[0]};
		final parts: Array<Expr> = [];
		if (kwLead != null) parts.push(macro _dt($v{kwLead + ' '}));

		// ω-arrow-lambda-body-context: enum-Case Star branches opting into
		// `@:fmt(leftCurlyAnonFnOverride('<knob>'))` (currently
		// `HxExpr.BlockExpr`) prepend a runtime-gated hardline before the
		// open delimiter — when the writer was descended through
		// `@:fmt(propagateAnonFnContext)` (parent flips `_inAnonFnBody=true`
		// via `_setAnonFnBody`) AND the named knob is `Next`, the hardline
		// fires and the renderer drops the parent's preceding `_dop(' ')`
		// OptSpace (e.g. `arrowFunctions=Both` after `->`), placing `{` on
		// its own line at the parent indent. When the override knob is
		// `Same` OR `_inAnonFnBody=false` (non-lambda context like
		// `HxIfExpr.thenBranch` reaching `BlockExpr`), the prefix is `_de()`
		// and the pre-slice cuddled `{` layout is preserved. The flag is
		// then cleared on per-element opt by `triviaBlockStarExpr` so
		// nested BlockExpr inside body statements falls back to default
		// `blockLeftCurly`.
		final anonFnOverrideKnob: Null<String> = branch.fmtReadString('leftCurlyAnonFnOverride');
		if (anonFnOverrideKnob != null) {
			final knobAccess: Expr = optFieldAccess(anonFnOverrideKnob);
			final nextPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
			parts.push(macro opt._inAnonFnBody && $knobAccess == $nextPat ? _dhl() : _de());
		}

		final c: EnumStarCtx = {
			branch: branch,
			argNames: argNames,
			argsAccess: argsAccess,
			elemFn: elemFn,
			elemCall: elemCall,
			leadText: leadText,
			trailText: trailText,
			sepText: sepText,
			starNode: starNode
		};
		final isTriviaStar: Bool = _ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		final emission: Expr = isTriviaStar ? lowerEnumStarTrivia(c) : lowerEnumStarPlain(c);
		parts.push(emission);
		return parts.length == 1 ? parts[0] : dcCall(parts);
	}

	// -------- struct rule --------

	/**
	 * Mirror of `Lowering.shouldLowerByName` for the writer side. When
	 * the resolved format has `fieldLookup == ByName + keySyntax ==
	 * Quoted` and no struct field carries positional metadata
	 * (`@:kw / @:lead / @:trail / @:sep`) or binary metadata, the
	 * writer emits the struct as a JSON-style key-dispatched object —
	 * `"<key>": <value>` entries joined by the format's `entrySep` and
	 * wrapped in `mappingOpen` / `mappingClose`. Symmetric to the
	 * parser's ByName codepath so `@:peg @:schema(JsonFormat) typedef
	 * T = { … }` round-trips through `Build.buildParser` /
	 * `Build.buildWriter` without any positional metadata.
	 */
	private function shouldWriteByName(node: ShapeNode): Bool {
		if (_formatInfo.isBinary) return false;
		if (_formatInfo.fieldLookup != ByName) return false;
		if (_formatInfo.keySyntax != Quoted) return false;
		if (node.annotations[AnnotationKeys.BIN_MAGIC] != null) return false;
		if (node.annotations['bin.align'] != null) return false;
		for (child in node.children) {
			if (child.readMetaString(':kw') != null) return false;
			if (child.readMetaString(':lead') != null) return false;
			if (child.readMetaString(':trail') != null) return false;
			if (child.readMetaString(':sep') != null) return false;
		}
		return true;
	}

	/**
	 * Emit the writer body for a struct lowered as a key-dispatched
	 * object. For each child field, build a `Doc` for
	 * `"<key>"<keyValueSep> <value>` and push it into a runtime
	 * accumulator. Optional fields whose value is `null` are skipped
	 * entirely — neither their key nor their separator is emitted.
	 * The accumulator is then handed to `sepList` so the entries get
	 * width-aware line breaks for free, just like the positional-
	 * struct writer paths.
	 *
	 * Field value dispatch:
	 *  - `Ref` → call the sub-rule's `write<Ref>(value, opt)`. For
	 *    primitive fields the ShapeBuilder has already rewritten
	 *    `base.ref` to the format-declared terminal (e.g. `String` →
	 *    `JStringLit`), so the same call handles string escaping.
	 *  - `Star` → emit `sequenceOpen + items joined by entrySep +
	 *    sequenceClose` via `sepList`. The element shape must be a
	 *    single `Ref`; nested `Star` is deferred until a real schema
	 *    needs `Array<Array<T>>`.
	 *
	 * Failure modes match the parser's `byNameStarParseExpr`: missing
	 * `sequenceOpen` / `sequenceClose` on the format is a macro-time
	 * fatal error.
	 */
	private function lowerStructByName(node: ShapeNode, typePath: String): Expr {
		final mappingOpen: String = _formatInfo.mappingOpen;
		final mappingClose: String = _formatInfo.mappingClose;
		final keyValueSep: String = _formatInfo.keyValueSep;
		final entrySep: String = _formatInfo.entrySep;

		final stmts: Array<Expr> = [macro final _entries: Array<anyparse.core.Doc> = []];

		for (child in node.children) {
			final fieldName: Null<String> = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			if (fieldName == null)
				Context.fatalError('WriterLowering: ByName struct field missing base.fieldName for $typePath', Context.currentPos());
			final isOptional: Bool = child.annotations.get(AnnotationKeys.BASE_OPTIONAL) == true;
			final fieldAccess: Expr = { expr: EField(macro value, fieldName), pos: Context.currentPos() };
			final keyPrefix: String = '"$fieldName"$keyValueSep';
			if (isOptional) {
				// Strict null safety does not narrow field reads — capture into
				// a non-null local before handing off to the per-kind writer.
				final fieldCT: Null<ComplexType> = child.annotations.get(AnnotationKeys.BASE_FIELD_TYPE);
				if (fieldCT == null)
					Context.fatalError(
						'WriterLowering: ByName optional field "$fieldName" missing base.fieldType for $typePath', Context.currentPos()
					);
				final localName: String = '_v_$fieldName';
				final valueDocExpr: Expr = byNameFieldWriteExpr(child, fieldName, macro $i{localName});
				stmts.push(macro if ($fieldAccess != null) {
					final $localName: $fieldCT = $fieldAccess;
					_entries.push(_dc([_dt($v{keyPrefix}), $valueDocExpr]));
				});
			} else {
				final valueDocExpr: Expr = byNameFieldWriteExpr(child, fieldName, fieldAccess);
				stmts.push(macro _entries.push(_dc([_dt($v{keyPrefix}), $valueDocExpr])));
			}
		}

		stmts.push(macro return sepList($v{mappingOpen}, $v{mappingClose}, $v{entrySep}, _entries, opt, false, _de(), _de(), false, false));
		return macro $b{stmts};
	}

	private function byNameFieldWriteExpr(child: ShapeNode, fieldName: String, valueAccess: Expr): Expr {
		return switch child.kind {
			case Ref:
				final refName: String = child.annotations[AnnotationKeys.BASE_REF];
				makeWriteCall(writeFnFor(refName), valueAccess, false, -1);
			case Star:
				if (child.annotations.exists(AnnotationKeys.BASE_MAP_VALUE)) {
					Context.fatalError(
						'WriterLowering: ByName Map<String, V> field "$fieldName" is parse-only — no writer lowering is implemented '
						+ 'for arbitrary-key mappings, so a schema declaring one cannot carry a writer marker',
						Context.currentPos()
					);
					throw 'unreachable';
				}
				byNameStarWriteExpr(child, fieldName, valueAccess);
			case _:
				Context.fatalError(
					'WriterLowering: ByName struct field "$fieldName" has unsupported kind ${child.kind}'
					+ ' — format ${_formatInfo.schemaTypePath} may be missing a primitive type mapping',
					Context.currentPos()
				);
				throw 'unreachable';
		};
	}

	private function byNameStarWriteExpr(child: ShapeNode, fieldName: String, valueAccess: Expr): Expr {
		final seqOpen: Null<String> = _formatInfo.sequenceOpen;
		final seqClose: Null<String> = _formatInfo.sequenceClose;
		if (seqOpen == null || seqClose == null) {
			Context.fatalError(
				'WriterLowering: ByName Array<T> field "$fieldName" requires the format ${_formatInfo.schemaTypePath} '
				+ 'to declare sequenceOpen / sequenceClose',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		if (child.children.length != 1) {
			Context.fatalError(
				'WriterLowering: ByName Array<T> field "$fieldName" expected exactly one element child, got ${child.children.length}',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final inner: ShapeNode = child.children[0];
		if (inner.kind != Ref) {
			Context.fatalError(
				'WriterLowering: ByName Array<T> field "$fieldName" element kind ${inner.kind} is not supported '
				+ '— only Array<RefType> (a single named element type) is implemented',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final refName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = writeFnFor(refName);
		final entrySep: String = _formatInfo.entrySep;
		return macro {
			final _items: Array<anyparse.core.Doc> = [for (_e in $valueAccess) $i{elemFn}(_e, opt)];
			sepList($v{seqOpen}, $v{seqClose}, $v{entrySep}, _items, opt, false, _de(), _de(), false, false);
		};
	}

	private function lowerStruct(node: ShapeNode, typePath: String): Expr {
		// noqa: complexity
		if (shouldWriteByName(node)) return lowerStructByName(node, typePath);
		final isRaw: Bool = node.hasMeta(':raw');
		final parts: Array<Expr> = [];
		var isFirstField: Bool = true;
		// Tracks a cumulative bool expr: `true` when ANY preceding
		// bare-tryparse Star in this struct contributed non-zero output.
		// A following bare-Ref field gates its leading separator on this
		// expr — otherwise a stray space leaks when every preceding Star
		// was empty (e.g. `\t function` instead of `\tfunction` when
		// `HxMemberDecl.modifiers` is empty). An intervening bare-
		// tryparse Star ORs its own `length > 0` check into the expr so
		// the signal propagates across a chain of Stars — required by
		// ω-member-meta where `meta` (non-empty) is followed by
		// `modifiers` (empty) is followed by `member`: the member still
		// needs its leading space because `meta` was non-empty two
		// fields back. Reset to `null` on any non-Star field, since the
		// emitted content at that point forms its own boundary.
		var prevAnyStarNonEmpty: Null<Expr> = null;
		// ω-metastmt-sep: `true` while the previous field was a mandatory
		// Ref (always emits content). Consumed by the Star branch below to
		// seed `prevAnyStarNonEmpty` — see the comment at the reset site.
		var prevFieldAlwaysEmits: Bool = false;
		// ω-pad-trailing-ref: tracks the runtime-Bool expr representing
		// the immediately preceding field's `@:fmt(padTrailing)` emission
		// (or `null` when the previous field neither carried the flag
		// nor — for optional/Star kinds — had its presence guard pass).
		// Read by `sameLineSeparator` to drop the next field's leading
		// space to `_de()` when this expr is truthy at runtime — closes
		// the double-space window when prev field's padTrailing meets
		// next field's sameLineSep at the same gate (canonical example:
		// `HxConditionalExpr` `expr` (bare-Ref padTrailing) immediately
		// followed by `elseExpr` (optional-kw-Ref sameLineSep)).
		//
		// Set at the end of each iteration's field branch from the per-
		// iteration scratch `thisPadTrailing`. Cleared (set to null) when
		// the iteration's field doesn't fire padTrailing — natural
		// boundary reset, no separate clear needed.
		var prevPadTrailing: Null<Expr> = null;
		// ψ₉: tracks the immediately preceding bare-Ref field that was
		// wrapped via `bodyPolicyWrap` — the next field's `@:fmt(sameLine(...))`
		// separator must then be shape-aware on the preceding body's
		// runtime ctor: a block ctor (e.g. `BlockStmt`) respects the
		// flag (space / hardline), any other ctor forces a hardline
		// because a lone keyword on the same line as a semicolon-
		// terminated body has no meaning.
		var prevBodyField: Null<PrevBodyInfo> = null;
		// ω-close-trailing-alt: tracks the immediately preceding bare-Ref
		// body field (any Ref kind, not just bodyPolicy-wrapped) so a
		// following Star with `@:fmt(sameLine(...))` can emit a runtime
		// override on its FIRST element's separator: when the prev body's
		// runtime ctor was a BlockStmt-style branch with a non-null
		// `closeTrailing` slot, the body's writer already terminated its
		// output with `\n`, and emitting the normal space separator would
		// leak a stray ` ` between the indent and the next sibling. The
		// override emits `_de()` instead. Reset on Star to avoid carrying
		// across non-Ref siblings.
		var prevBareRefBody: Null<PrevBodyInfo> = null;
		// ω-trivia-after-trail: tracks the field name of the immediately
		// preceding mandatory Ref that carried `@:trail` in trivia-bearing
		// mode. The next sibling's `bodyPolicyWrap` reads
		// `value.<prevTrailFieldName>AfterTrail:Null<String>` and threads
		// the captured same-line comment before the body's leading
		// separator. Reset to null on any non-Ref-with-trail sibling so
		// the slot is not carried across an intervening field that would
		// itself terminate the visual gap. Plain mode and non-bearing
		// rules leave this null — the synth slot does not exist there.
		var prevTrailFieldName: Null<String> = null;
		// ψ₁₂: captures the name of the first `@:optional` sibling that
		// carries `@:fmt(bodyPolicy(...))` — consumed by children tagged
		// `@:fmt(fitLineIfWithElse)` to wire a runtime sibling-presence
		// check into the `FitLine` branch of `bodyPolicyWrap`. In the
		// current grammar this is `HxIfStmt.elseBody`; the same shape
		// (pair of bodyPolicy fields, one required, one optional) can
		// opt in without further macro changes. First-match semantics:
		// a struct with two optional bodyPolicy siblings would quietly
		// pick one — no such grammar exists today, and a future case
		// can disambiguate via an explicit arg on `@:fmt(fitLineIfWithElse)`.
		var optionalBodyFieldName: Null<String> = null;
		for (c in node.children) if (c.annotations.get(AnnotationKeys.BASE_OPTIONAL) == true && c.fmtReadStringArgs('bodyPolicy') != null) {
			optionalBodyFieldName = c.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			break;
		}

		// ω-condwrap-forstmt: detect a span-mode condWrap pair —
		// `@:fmt(condWrap('<knob>'))` on a starting field plus a later
		// sibling carrying the `@:fmt(condWrapEnd)` sentinel flag. The
		// open paren literal comes from the start field's `@:lead`, the
		// close paren from the end field's `@:trail`; the inter-field
		// pushes (separators, `@:kw` text, second writeCall) accumulate
		// normally into `parts` and are spliced into a single
		// `WrapList.emitCondition` wrap at the end of the end-field's
		// iteration. Single-Ref consumers (`HxIfStmt.cond`,
		// `HxWhileStmt.cond`) have no `condWrapEnd` sibling, so
		// `spanInfo` stays null and the existing single-Ref path runs.
		//
		// First consumer: `HxForStmt` — span covers
		// `varName + 'in' + iterable` with `(` from varName.@:lead and
		// `)` from iterable.@:trail. Fork's `markPWrapping` dispatches
		// `ForLoop` to the same `wrapCondition` path as `WhileCondition`
		// / `IfCondition`.
		final spanInfo = detectCondWrapSpan(node);
		var fieldIdx: Int = -1;
		var spanStartPartsIdx: Int = -1;
		// ω-condwrap-fitline-construct-group: parts index where the single-Ref
		// condWrap field's emission begins. When the IMMEDIATELY following
		// mandatory bodyPolicy Ref field is emitted, everything from this index
		// through that field's finalize is spliced into ONE BodyGroup so the
		// FitLine body layout can be the classic whole-construct soft line
		// (see WrapBodyOpts.condFitGroup). -1 = no pending cond. Reset by any
		// intervening field that is not the consumer.
		var condFitGroupStartIdx: Int = -1;
		// omega-try-brace-symmetry: `@:fmt(constructFitGroup('<startField>', '<endStarField>'))` on the
		// STRUCT splices everything from the start field's emission through the end Star into ONE
		// construct-level `BodyGroup`, the same shape the condWrap path builds for `if` / `for` /
		// `while`. Those get it through their CONDITION field; a try/catch has none, so without this
		// its body and its `catch` seams each answer the width question on their OWN line — and the
		// body's answer is read after the seam already committed, which is how a de-braced
		// `try f(a, b) catch (e) g();` that overflows ends up breaking INSIDE the call instead of at
		// the seams. One group asks once, before any inner group commits.
		final constructFitArgs: Null<Array<String>> = node.fmtReadStringArgs('constructFitGroup');
		var constructFitStartIdx: Int = -1;

		// ω-multivar-wrap: detect the struct-level
		// `@:fmt(multiVarWrap('<knob>', '<moreField>'))` opt-in (sole
		// consumer: `HxVarDecl`). When present, the named right-recursive
		// list field is routed through the `<knob>` `WrapRules` cascade at
		// the return-folding step below: the head binding plus each chain
		// link become head-only item Docs and are spliced into one
		// `WrapList.emit('', '', ',', …)`. The per-field emit of the
		// `<moreField>` Star is gated on the runtime `_suppressMore` entry
		// flag so a recursive head-only self-call drops it to `_de()`. Off
		// every other struct (args == null) → byte-identical to pre-slice.
		final multiVarArgs: Null<Array<String>> = node.fmtReadStringArgs('multiVarWrap');
		final multiVarKnob: Null<String> = multiVarArgs != null ? multiVarArgs[0] : null;
		final multiVarMoreField: Null<String> = multiVarArgs != null ? multiVarArgs[1] : null;
		if (multiVarArgs != null && multiVarArgs.length != 2)
			Context.fatalError(
				'WriterLowering: @:fmt(multiVarWrap) expects 2 string args (knobFieldName, moreFieldName), got ${multiVarArgs.length}',
				Context.currentPos()
			);

		for (child in node.children) {
			fieldIdx++;
			final meta: FieldMeta = readFieldMeta(child, spanInfo, fieldIdx, typePath);
			final fieldName: String = meta.fieldName;
			final kwLead: Null<String> = meta.kwLead;
			final leadText: Null<String> = meta.leadText;
			final trailText: Null<String> = meta.trailText;
			final trailOptText: Null<String> = meta.trailOptText;
			final isStar: Bool = meta.isStar;
			final isOptional: Bool = meta.isOptional;
			final hasElseIf: Bool = meta.hasElseIf;
			final condWrapArgs: Null<Array<String>> = meta.condWrapArgs;
			final hasCondWrapEnd: Bool = meta.hasCondWrapEnd;
			final hasCondWrap: Bool = meta.hasCondWrap;
			final fieldAccess: Expr = meta.fieldAccess;
			final hasStructFieldTrailOptSlot: Bool = meta.hasStructFieldTrailOptSlot;
			final structTrailOptAccess: Null<Expr> = meta.structTrailOptAccess;
			// Tracker is "prev" — clear at the start so a non-bearing-Ref
			// field doesn't leak the value set two iterations back.
			final stalePrevBareRefBody: Null<PrevBodyInfo> = prevBareRefBody;
			prevBareRefBody = null;
			// ω-pad-trailing-ref: per-iteration scratch holding THIS
			// field's padTrailing-emission runtime expr (or null if this
			// field doesn't fire padTrailing). Each field-kind branch
			// sets it locally before its `continue` (Star branches) or
			// fall-through (Ref/OptRef branches) to the shared end-of-
			// loop block, where `composePadTrailing` folds it into
			// `prevPadTrailing`.
			var thisPadTrailing: Null<Expr> = null;
			// (per-field literal / condWrap / trailOpt-slot facts are read by readFieldMeta into `meta`.)
			if (meta.isSpanStart) spanStartPartsIdx = parts.length;
			if (constructFitArgs != null && fieldName == constructFitArgs[0]) constructFitStartIdx = parts.length;

			// (the @:trailOpt source-presence slot facts live in readFieldMeta.)

			if (isStar) {
				condFitGroupStartIdx = -1;
				final closesConstructFit: Bool = constructFitArgs != null && constructFitStartIdx >= 0 && fieldName == constructFitArgs[1];
				final starResult = emitStarField(
					child, parts, node, typePath, isFirstField, isRaw, stalePrevBareRefBody, prevTrailFieldName, kwLead, fieldName,
					prevBodyField, prevPadTrailing, fieldAccess, prevAnyStarNonEmpty, multiVarMoreField, isOptional, prevFieldAlwaysEmits
				);
				prevAnyStarNonEmpty = starResult.prevAnyStarNonEmpty;
				prevFieldAlwaysEmits = false;
				prevBodyField = null;
				// ω-case-label-trail-comment: a @:fmt(captureTrailComment) Star (the
				// case-pattern list ending in `:`) publishes its name so the NEXT
				// sibling's tryparse-Star emit cuddles the captured same-line trail
				// comment to the `:` token, like a mandatory Ref with @:trail.
				prevTrailFieldName = _ctx.trivia && child.fmtHasFlag('captureTrailComment') ? fieldName : null;
				prevPadTrailing = starResult.prevPadTrailing;
				isFirstField = false;
				if (closesConstructFit) {
					final grpBuf: Array<Expr> = parts.slice(constructFitStartIdx, parts.length);
					parts.splice(constructFitStartIdx, parts.length - constructFitStartIdx);
					parts.push(macro _dbg(${grpBuf.length == 1 ? grpBuf[0] : dcCall(grpBuf)}));
					constructFitStartIdx = -1;
				}
				continue;
			}

			final isCondFitSetter: Bool = hasCondWrap && spanInfo == null;
			if (isCondFitSetter) condFitGroupStartIdx = parts.length;

			// D61: kw prefix + mandatory @:lead lead-in — see emitFieldLeadIn.
			emitFieldLeadIn(
				child, parts, kwLead, leadText, isOptional, isFirstField, isRaw, prevBodyField, typePath, prevPadTrailing, hasCondWrap,
				hasCondWrapEnd, prevAnyStarNonEmpty, fieldAccess
			);

			// Field value.
			// ω-issue-257-else-in-return-switch: `bodyPolicy('<stmtFlag>', '<exprFlag>')`
			// dispatches at runtime on `opt._inExprPosition`.
			final bodyPolicy: { stmt: Null<String>, expr: Null<String> } = readBodyPolicyDual(child);
			final bodyPolicyFlag: Null<String> = bodyPolicy.stmt;
			final bodyPolicyExprFlag: Null<String> = bodyPolicy.expr;
			// ω-expression-if-next-with-fitline-body: `@:fmt(noSiblingFallback(
			// 'fallbackFlag'))` on a bare-Ref body field tells `bodyPolicyWrap`
			// to swap `opt.<bodyPolicy>` for `opt.<fallbackFlag>` at runtime
			// when the next optional sibling field's value is null. Used by
			// `HxIfExpr.thenBranch` to fall back to `opt.ifBody` (FitLine) when
			// `elseBranch` is null — mirrors fork's arrow-body / comprehension-
			// filter-if short-circuits onto `ifBody`. When this flag is set
			// the field also opts into the `optionalBodyFieldName` channel so
			// `elseFieldName` is populated regardless of `fitLineIfWithElse`.
			final fallbackFlag: Null<String> = child.fmtReadString('noSiblingFallback');
			final elseFieldName: Null<String> =
				child.fmtHasFlag('fitLineIfWithElse') || fallbackFlag != null ? optionalBodyFieldName : null;
			// ω-condwrap-fitline-construct-group: this field consumes the pending
			// cond iff it is the mandatory bare-Ref bodyPolicy body immediately
			// following the condWrap field (mirrors emitMandatoryRefField's
			// emitBodyPolicyBareRef dispatch predicate).
			final condFitGroupConsumer: Bool = condFitGroupStartIdx >= 0 && !isCondFitSetter && child.kind == Ref && !isOptional
				&& bodyPolicyFlag != null && kwLead == null && leadText == null && !isRaw;
			// omega-try-brace-symmetry: the construct group's START field is a body in the same sense
			// the condWrap consumer is - its FitLine layout must be the group's soft line, not a
			// self-contained one - but it must NOT close a group here: the splice happens at the END
			// Star. Only the `condFitGroup` half of the consumer's treatment is shared.
			final inConstructFitGroup: Bool = constructFitArgs != null && fieldName == constructFitArgs[0];
			var justWrappedBody: Null<PrevBodyInfo> = null;
			switch child.kind {
				case Ref if (isOptional):
					// ω-orphan-prefix-member: an `@:optional @:absentOn` bare Ref that opts
					// into `@:fmt(bareRefSepWhenPresent)` keeps the MANDATORY bare-Ref
					// leading separator for the present case — built here, where the
					// per-field trackers live, and spliced inside the field's own null
					// check so absence stays byte-silent.
					//
					// The first-field escape mirrors `TriviaTypeSynth.isBareNonFirstRef` and
					// `Lowering.computeBeforeSlots` exactly, because those three decide
					// synthesise / capture / consume for the SAME slot and a field the first two
					// admit but this one refuses would be captured and then silently dropped.
					// `bodyPolicy` is the one shape that reaches a different emit branch
					// (`emitOptionalBodyPolicyOnly`, which takes no separator), so a field
					// combining it with this flag would lose the gap with no diagnostic —
					// refused loudly instead of shipped silently.
					final bareSepOptIn: Bool = child.fmtHasFlag('bareRefSepWhenPresent');
					if (bareSepOptIn && bodyPolicyFlag != null)
						Context.fatalError(
							'WriterLowering: @:fmt(bareRefSepWhenPresent) cannot combine with @:fmt(bodyPolicy)'
							+ ' — the body-policy emit path owns the separator (field "$fieldName" of $typePath)',
							Context.currentPos()
						);
					final optBareSep: Null<Expr> = bareSepOptIn && kwLead == null && leadText == null
						&& (!isFirstField || child.fmtHasFlag(BEFORE_NEWLINE_SLOT_FIRST))
						? buildBareRefLeadingSep(
							child, fieldName, typePath, prevAnyStarNonEmpty, prevPadTrailing,
							buildKeepBlankAfterCtorGate(child, node, typePath)
						)
						: null;
					thisPadTrailing = emitOptionalRefField(
						child, parts, node, typePath, fieldName, fieldAccess, kwLead, leadText, trailText, trailOptText, bodyPolicyFlag,
						bodyPolicyExprFlag, hasElseIf, elseFieldName, prevBodyField, prevPadTrailing, hasStructFieldTrailOptSlot,
						structTrailOptAccess, prevTrailFieldName, optBareSep
					);

				case Ref:
					final mandResult = emitMandatoryRefField(
						child, parts, typePath, fieldAccess, fieldName, bodyPolicyFlag, bodyPolicyExprFlag, kwLead, leadText, isRaw,
						isFirstField, hasElseIf, elseFieldName, fallbackFlag, hasCondWrap, condWrapArgs, spanInfo != null, trailText,
						prevTrailFieldName, prevAnyStarNonEmpty, prevPadTrailing, condFitGroupConsumer || inConstructFitGroup
					);
					justWrappedBody = mandResult.justWrappedBody;
					prevBareRefBody = mandResult.prevBareRefBody;

				case _:
					Context.fatalError('WriterLowering: struct field kind ${child.kind} not supported', Context.currentPos());
			}

			// Trail + per-field finalize (accumulator fold) — see finalizeNonStarField.
			final finalizeResult = finalizeNonStarField(
				child, parts, node, typePath, fieldName, fieldAccess, isOptional, trailText, trailOptText, hasCondWrap, hasCondWrapEnd,
				hasStructFieldTrailOptSlot, structTrailOptAccess, thisPadTrailing, prevPadTrailing, justWrappedBody, spanInfo,
				spanStartPartsIdx
			);
			// ω-condwrap-fitline-construct-group: the consumer body field (incl.
			// its trail finalize) closes the construct group — splice
			// [condFitGroupStartIdx, end) into one construct-level group. A
			// non-consumer, non-setter field in between drops the pending cond
			// instead. The group flavour is RUNTIME-conditional on the optional
			// else sibling (ψ₁₂'s optionalBodyFieldName):
			//  - NO else → BodyGroup. The trivia writer's per-element
			//    trailing-comment fold (`foldTrailingIntoBodyGroup`) then
			//    splices a trailing `// comment` INSIDE the group, so the
			//    whole-construct fitsFlat measures it (`if (c) return x; // n`
			//    breaks when the comment pushes the line over), and a parent
			//    fit measure (chained `for (...) if (...) body` FitLines)
			//    keeps deferring the nested construct like the body-level
			//    BodyGroup it replaces.
			//  - else PRESENT → plain Group, opaque to the fold: the element's
			//    trailing comment belongs AFTER the whole if/else (a
			//    construct-level BodyGroup swallowed it between the then-body
			//    and `else`). Same render-time fitsFlat dispatch either way;
			//    with an else the FitLine body already degrades to Next via
			//    fitLineIfWithElse, so losing the comment from the measure
			//    costs nothing.
			if (condFitGroupConsumer) {
				final grpBuf: Array<Expr> = parts.slice(condFitGroupStartIdx, parts.length);
				parts.splice(condFitGroupStartIdx, parts.length - condFitGroupStartIdx);
				final grpInner: Expr = grpBuf.length == 1 ? grpBuf[0] : dcCall(grpBuf);
				if (optionalBodyFieldName != null) {
					final elseAcc: Expr = { expr: EField(macro value, optionalBodyFieldName), pos: Context.currentPos() };
					// omega-value-if-fit: the cond-fit group must NOT open under the value-if re-flow. It
					// wraps the condition plus the THEN body only, so its own `fitsFlat` answers for half
					// the chain: the then-gap renders flat inside it while the `else` gaps break in the
					// enclosing group, and the chain comes out a ragged hybrid. The re-flow's premise is
					// ONE break axis for every arm, so the construct group is dropped and the outer
					// `Group` decides alone.
					parts.push(fitGroupExpr(node, elseAcc, grpInner));
				} else
					parts.push(macro _dbg($grpInner));
				condFitGroupStartIdx = -1;
			} else if (!isCondFitSetter)
				condFitGroupStartIdx = -1;
			prevAnyStarNonEmpty = null;
			// ω-metastmt-sep: a mandatory Ref ALWAYS emits content, so a
			// bare-tryparse Star that starts right after it must seed the
			// cumulative `prevAnyStarNonEmpty` signal with `true` (inside
			// `emitStarField`'s return, NOT before it — the inter-Star
			// separator at the Star's own iteration must stay quiet so
			// trivia Stars that emit their own leading hardline don't get
			// a doubled break). Without the seed the next bare Ref's
			// separator gate reads only the Star's emptiness and glues
			// across the boundary (`@:nullSafety(Off)if` in `HxMetaStmt`
			// where `rest` is empty). Optional Refs may emit nothing, so
			// they don't set the flag.
			prevFieldAlwaysEmits = child.kind == Ref && !isOptional;
			prevBodyField = finalizeResult.prevBodyField;
			prevPadTrailing = finalizeResult.prevPadTrailing;
			prevTrailFieldName = finalizeResult.prevTrailFieldName;
			isFirstField = false;
			// (trail emit + padTrailing / transparent fold + AfterTrail publish + condWrap-end splice live in finalizeNonStarField.)
		}

		// ω-multivar-wrap: `@:fmt(multiVarWrap('<knob>', '<moreField>'))` (sole
		// consumer: HxVarDecl) folds the head binding + right-recursion links into
		// one WrapList.emit under the `<knob>` cascade — see buildMultiVarWrapFold.
		// ω-splice-op-fill: `@:fmt(fillParts)` on the STRUCT assembles its
		// fields as one Wadler `Fill` instead of a `Concat` — the node owns a
		// layout policy of its own rather than replaying the source's line
		// breaks. Every seam the fill owns is declared `@:fmt(fillSeam)` on
		// the field after it, so those fields push no separator and the fill's
		// `Line(' ')` is the only thing between two items: a seam that fits
		// stays a space, one that does not becomes a break at the fill's
		// indent, and the decision is the same for every legal spelling of the
		// same tree. `D.fillOnOverflow` drops the `_de()` a `fillSeam` field
		// leaves behind when the gap carried no comment, and — see its own doc
		// — keeps the plain space-joined shape while the run still fits, so a
		// region that never needed to break is measured exactly as before.
		// Trivia mode only —
		// the plain writer captures no source-newline slots, so it has nothing
		// to normalise and stays byte-identical.
		// Sole consumer: `HxCondSpliceOpExpr` (`#if c (operand op)* #end tail`).
		final dcExpr: Expr = if (node.fmtHasFlag('fillParts') && _ctx.trivia)
			macro anyparse.core.D.fillOnOverflow([$a{parts}], opt.lineWidth + 1);
		else if (multiVarKnob == null || multiVarMoreField == null)
			dcCall(parts);
		else
			buildMultiVarWrapFold(parts, typePath, multiVarKnob, multiVarMoreField);
		final wrapped: Expr = arrowValueIfReflowWrap(node, dcExpr);
		return macro return $wrapped;
	}

	/**
	 * Emit writer steps for a Star struct field.
	 * Trivia `@:tryparse` Star dispatch (the `if (starNode.hasMeta(':tryparse'))`
	 * branch of `emitWriterStarField`). Reads the per-construct `@:fmt` flags and
	 * sep-override switches, then pushes the `triviaTryparseStarExpr` emit onto
	 * `parts`. Extracted so the orchestrator stays under the complexity gate.
	 * Builds the first / subsequent element separator overrides for a
	 * `@:trivia @:tryparse` Star (the close-trailing + block-shape-aware switches).
	 * Bundled for `emitTriviaTryparseStar`. Extracted to keep that helper under the
	 * complexity gate.
	 */
	private function buildTryparseSepOverrides(
		starNode: ShapeNode, sameLineName: Null<String>, prevBareRefBody: Null<PrevBodyInfo>, elemRefName: String, sepExpr: Expr
	): TryparseSepOverrides {
		final closeTrailingFirstOverride: Null<Expr> = sameLineName != null
			? buildCloseTrailingFirstSepOverride(prevBareRefBody, sepExpr)
			: null;
		// ω-block-shape-aware: when the Star carries
		// `@:fmt(blockBodyKeepsInline)` AND the prev body's enum has
		// block ctors, force the leading sep before each catch
		// element to `_dt(' ')` whenever the previous body (struct
		// field for the first iteration, prev element's body for
		// subsequent iterations) was a block ctor. Composes with the
		// close-trailing override above by using it as the non-block
		// fallback on the first iteration.
		//
		// ω-statement-bare-break: dual flag `@:fmt(bareBodyBreaks)`
		// flips the cases — block bodies fall through to the policy-
		// driven `sepExpr` (or close-trailing override on the first
		// iteration) and bare bodies force `_dhl()`. Both
		// `HxTryCatchStmt.catches` (block-form ctor with non-block
		// body via `ExprStmt(...)`) and `HxTryCatchStmtBare.catches`
		// (bare-form, body=HxExpr) opt in — non-block prev-body
		// pairs with `tryBody=Next` to keep the multi-line layout
		// coherent: `try\n\tBARE;\ncatch (...)`. Block bodies stay
		// under policy control (`sameLineCatch=Next` still breaks
		// `} catch` to `}\ncatch`). The block-ctor predicate is
		// `isBlockShapeEquivalentBranch` (sister of
		// `isBlockCtorBranch` that also accepts `@:fmt(blockShape)`
		// opt-in ctors like `UntypedBlockStmt(body:HxUntypedFnBody)`,
		// which emits `untyped { … }` — visually a block).
		final blockShapeAware: Bool = starNode.fmtHasFlag('blockBodyKeepsInline');
		final bareShapeAware: Bool = starNode.fmtHasFlag('bareBodyBreaks');
		// omega-try-brace-symmetry: the `BodyPolicy` knobs governing the two bodies this separator
		// can follow — the try body for the FIRST catch, the previous catch's body for every later
		// one. Absent (`@:fmt(bareBodyBreaks)` with no args) keeps the unconditional hardline.
		final barePolicyFields: Array<String> = starNode.fmtReadStringArgs('bareBodyBreaks') ?? [];
		final softSeam: Bool = starNode.fmtHasFlag('constructFitSep');
		final shapeAware: Bool = blockShapeAware || bareShapeAware;
		// `bareBodyBreaks` includes blockShape opt-in ctors (e.g.
		// `UntypedBlockStmt`) — they end with `}` and should be
		// treated as block for the catch-separator decision while
		// staying non-block in `bodyPolicyWrap`'s strict block-ctor
		// override path.
		final blockPatterns: Array<Expr> = sameLineName != null && prevBareRefBody != null && shapeAware
			? (
				bareShapeAware
					? collectBlockShapeEquivalentPatterns(prevBareRefBody.typePath)
					: collectBlockCtorPatterns(prevBareRefBody.typePath)
			)
			: [];
		final elemBodyField: Null<String> = sameLineName != null && blockPatterns.length > 0
			? findElementBodyField(elemRefName, prevBareRefBody.typePath)
			: null;
		final blockKeepsInlineBranch: Expr = blockBodyKeepsInlineBranch(starNode);
		final firstSepOverride: Null<Expr> = if (blockPatterns.length == 0)
			closeTrailingFirstOverride;
		else {
			final fallback: Expr = closeTrailingFirstOverride ?? sepExpr;
			final blockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : fallback;
			final bareBranch: Expr = blockShapeAware ? fallback : bareSepBreak(barePolicyFields[0], sepExpr, softSeam);
			final cases: Array<Case> = [
				{ values: blockPatterns, expr: blockBranch, guard: null },
				{ values: [macro _], expr: bareBranch, guard: null }
			];
			{ expr: ESwitch(prevBareRefBody.access, cases, null), pos: Context.currentPos() };
		};
		final subsequentSepOverride: Null<Expr> = if (elemBodyField == null)
			null;
		else {
			final prevElemBodyAccess: Expr = {
				expr: EField(macro _arr[_si - 1].node, elemBodyField),
				pos: Context.currentPos()
			};
			final blockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
			final bareBranch: Expr = blockShapeAware ? sepExpr : bareSepBreak(barePolicyFields[1], sepExpr, softSeam);
			final cases: Array<Case> = [
				{ values: blockPatterns, expr: blockBranch, guard: null },
				{ values: [macro _], expr: bareBranch, guard: null }
			];
			{ expr: ESwitch(prevElemBodyAccess, cases, null), pos: Context.currentPos() };
		};
		return { firstSepOverride: firstSepOverride, subsequentSepOverride: subsequentSepOverride };
	}

	/**
	 * Trivia `@:tryparse` Star dispatch (the `if (starNode.hasMeta(':tryparse'))`
	 * branch of `emitWriterStarField`). Reads the per-construct `@:fmt` flags and
	 * sep-override switches, then pushes the `triviaTryparseStarExpr` emit onto
	 * `parts`. Extracted so the orchestrator stays under the complexity gate.
	 */
	@:access(anyparse.macro.TriviaTryparseLowering)
	private function emitTriviaTryparseStar(c: TriviaStarCtx, parts: Array<Expr>): Void {
		// noqa: complexity
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final elemRefName: String = c.elemRefName;
		final isLastField: Bool = c.isLastField;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final prevBareRefBody: Null<PrevBodyInfo> = c.prevBareRefBody;
		final prevTrailFieldName: Null<String> = c.prevTrailFieldName;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		final trailBAAccess: Null<Expr> = c.trailBAAccess;
		if (closeText != null) Context.fatalError('WriterLowering: @:trivia + @:tryparse must not have @:trail', Context.currentPos());
		// Non-last-field @:trivia @:tryparse is supported only when
		// the Star is bare (no `@:lead`). The emitted Doc then
		// stands alone (empty array → `_de()`), and the next
		// sibling's leading separator in `lowerStruct` already gates
		// on `prevAnyStarNonEmpty` via the bare-tryparse-Star
		// tracker, so the space between Star output and next
		// field never leaks when the Star was empty. Required by
		// `HxMemberDecl.modifiers` (not last — `member` follows).
		//
		// `@:lead` on a non-last bare-tryparse Star would emit the
		// lead text unconditionally even on empty input, leaking
		// the literal across an otherwise-empty member position.
		// Reject loudly until a grammar needs it AND the empty-
		// input case is gated.
		if (!isLastField && openText != null)
			Context.fatalError('WriterLowering: non-last @:trivia @:tryparse Star must be bare (no @:lead)', Context.currentPos());
		if (openText != null) parts.push(macro _dt($v{openText}));
		// sameLine-annotated Stars (catches against try body) emit
		// the separator before EVERY element — it's the boundary
		// with the preceding struct field. Non-sameLine Stars
		// (case / default bodies) emit it only between elements,
		// matching the plain-mode tryparse writer.
		final sameLineName: Null<String> = starNode.fmtReadString('sameLine');
		final sepExpr: Expr = if (sameLineName != null) {
			final optFlag: Expr = optFieldAccess(sameLineName);
			sameLinePolicySwitch(optFlag, macro _dt(' '));
		} else {
			macro _dt(' ');
		};
		final nestBody: Bool = starNode.fmtHasFlag('nestBody');
		// ω-cond-comp-branch-trail: conditional branch bodies (`@:fmt(padTrailing)`
		// tryparse Stars) also carry orphan trailing trivia before `#end`/`#else`
		// (the parser captures it on element-parse failure, same as nestBody). The
		// slots stay empty for every other padTrailing Star, so the emit is
		// byte-inert until the parser writes them.
		final branchTrail: Bool = starNode.fmtHasFlag('padTrailing');
		// Trailing slots carry orphan trivia when nestBody (case/default bodies)
		// or padTrailing (conditional branch bodies) is on — the parser gates
		// capture on the same flags. Otherwise zero; forward null to keep the
		// writer path byte-identical.
		final tryparseTrailBB: Null<Expr> = nestBody || branchTrail ? trailBBAccess : null;
		final tryparseTrailLC: Null<Expr> = nestBody || branchTrail ? trailLCAccess : null;
		final tryparseTrailBA: Null<Expr> = nestBody ? trailBAAccess : null;
		// ω-close-trailing-alt: when prev field was a bare-Ref to a
		// trivia-bearing type whose Alt has close-trailing branches
		// (currently `HxStatement.BlockStmt`), build a runtime
		// override on the FIRST element's separator. `BlockStmt(_, ct)`
		// with `ct != null` means the body's writer already
		// terminated its output with `\n` after the trailing line
		// comment — the normal space sep would leak ` ` between the
		// indent and the next sibling (e.g. `catch`). The override
		// emits `_de()` instead; non-matching ctors fall through.
		final sepOverrides: TryparseSepOverrides = buildTryparseSepOverrides(starNode, sameLineName, prevBareRefBody, elemRefName, sepExpr);
		final firstSepOverride: Null<Expr> = sepOverrides.firstSepOverride;
		final subsequentSepOverride: Null<Expr> = sepOverrides.subsequentSepOverride;
		// ω-case-body-policy / ω-case-body-keep:
		// `@:fmt(bodyPolicy('flag1', 'flag2', ...))` on a
		// `nestBody` Star opts the body field into runtime
		// single-stmt-flat emission. The runtime ORs all named
		// `BodyPolicy` flags across two predicates:
		//  - ANY flag == `Same` → flatten unconditionally (override).
		//  - ANY flag == `Keep` → flatten IFF the source had the
		//    body's first element on the same line as the lead
		//    (read off `Trivial<T>.newlineBefore`).
		// Either path gates on the body holding exactly one element
		// with no leading / orphan-trailing trivia; multi-stmt and
		// trivia-bearing bodies stay multiline. Consumed by
		// `HxCaseBranch.body` and `HxDefaultBranch.stmts` to
		// switch between `case X:\n\tstmt;` (Next) and
		// `case X: stmt;` (Same / Keep+sameLine).
		final caseBodyFlagNames: Array<String> = starNode.fmtReadStringArgs('bodyPolicy') ?? [];
		// ω-expression-case-flat-fanout: when `@:fmt(flatChildOpt('A=B', …))`
		// is present, parse each `'from=to'` arg into a [from, to] pair so
		// `triviaTryparseStarExpr` can emit a `Reflect.copy(opt)` + per-pair
		// override block in the runtime flat-case branch.
		final flatChildOptRaw: Null<Array<String>> = starNode.fmtReadStringArgs('flatChildOpt');
		final flatChildOptPairs: Array<Array<String>> = if (flatChildOptRaw == null)
			[]
		else {
			final out: Array<Array<String>> = [];
			for (raw in flatChildOptRaw) {
				final eq: Int = raw.indexOf('=');
				if (eq <= 0 || eq >= raw.length - 1)
					Context.fatalError(
						'WriterLowering: @:fmt(flatChildOpt(...)) arg must be "from=to", got "${raw}"', Context.currentPos()
					);
				out.push([raw.substr(0, eq), raw.substr(eq + 1)]);
			}
			out;
		};
		// ω-cond-mod-pad: `@:fmt(padLeading)`/`@:fmt(padTrailing)` on
		// a `@:trivia @:tryparse` Star emit a leading/trailing space
		// when non-empty (matches the non-trivia padLeading/padTrailing
		// branch), with the leading slot SWITCHING to `_dhl()` when
		// the source had a newline before the first element. Used by
		// `HxConditionalMod.body` so V1–V3 (single-line `#if X mods #end`)
		// stay on one line and V4 (newline-separated cond/mods/`#end`)
		// breaks all three pad slots together — the trail-side pad
		// follows the leading-side decision because the parser does
		// not capture a body→`#end` newline slot, but in legal source
		// shapes the two newlines are correlated.
		// ω-splice-op-fill: `@:fmt(fillItems)` hands the gap BEFORE the first
		// element to the enclosing struct's `@:fmt(fillParts)` run, so the
		// Star's own leading pad must not fire in trivia mode — including on
		// the comment fallback, which emits the ordinary Star body and would
		// otherwise spend a second separator on the same gap (`#if flash  'b'`,
		// measured). The PLAIN writer keeps the pad: it has no fill to take
		// the gap from it.
		final tryparsePadLeading: Bool = starNode.fmtHasFlag('padLeading') && !starNode.fmtHasFlag('fillItems');
		final tryparsePadTrailing: Bool = starNode.fmtHasFlag('padTrailing');
		// ω-cond-indent-policy: `@:fmt(conditionalBodyIndent)` on a
		// `@:trivia @:tryparse` cond-comp body / elseBody / elseif-body
		// Star opts the body content into the runtime
		// `opt.conditionalPolicy` indent rule. When the policy is
		// `AlignedIncrease`, the body content (leading pad hardline +
		// each body element) is wrapped in `_dn(_cols, …)` so it sits
		// one level deeper than the `#if`/`#else`/`#end` markers, while
		// the trailing pad hardline (the `\n` before `#else`/`#end`)
		// is emitted OUTSIDE the nest so the close marker stays at the
		// surrounding statement indent. Nesting accumulates per
		// conditional depth (a nested `#if` body re-enters the same
		// `_dn`). DEFAULT `Aligned` → the runtime gate is false → the
		// pre-policy `else` branch fires → byte-identical. Only the
		// cond-comp body Stars carry this flag, so every other tryparse
		// Star consumer is untouched.
		final tryparseCondBodyIndent: Bool = starNode.fmtHasFlag('conditionalBodyIndent');
		// ω-issue-423-mech-a: `@:fmt(propagateExprPosition)` on a
		// `@:trivia @:tryparse` Star marks the body as an expression-
		// position frame for descendants. The runtime block emits an
		// always-copy of `opt` with `_inExprPosition = true` set, so
		// the dual-flag `bodyPolicy('A','B')` flat-gate in nested
		// case-body sites picks the expression-position policy
		// (`expressionCase`) instead of the statement-position one
		// (`caseBody`). Mirrors fork's `isReturnExpression` walk-up
		// heuristic — currently wired only by `HxCaseBranch.body` /
		// `HxDefaultBranch.stmts` so a case nested in another case's
		// body inherits expression context.
		final propagateExprPosition: Bool = starNode.fmtHasFlag('propagateExprPosition');
		// ω-value-yielded-if-tail-barrier (case-body extension of SI-2):
		// `@:fmt(clearExprPositionNonTail)` on a case / default body Star
		// (paired with `propagateExprPosition`) clears `_inExprPosition`
		// for every NON-tail body statement, so a discarded statement-if
		// reverts to the statement-position `ifBody` policy while the
		// body's yielded tail keeps the expression frame. False → byte-
		// identical (every other tryparse-Star consumer is untouched).
		final clearExprPositionNonTail: Bool = starNode.fmtHasFlag('clearExprPositionNonTail');
		// ω-issue-423-mech-b: `@:fmt(refuseFlatOnComplexExpr)` AND-s the
		// runtime `_flatCase` gate with the generated typed
		// `caseBodyRefusesFlat` predicate of the build's AST family
		// (addressed by naming convention — the engine never references
		// the grammar plugin by name; a grammar carrying the meta must
		// provide the marker classes). Wired on `HxCaseBranch.body` /
		// `HxDefaultBranch.stmts` to mirror fork's
		// `MarkSameLine.markExpressionCase` body-shape check.
		final refuseFlatOnComplex: Bool = starNode.fmtHasFlag('refuseFlatOnComplexExpr');
		// omega-case-body-controlflow-glue: `@:fmt(refuseGlueOnControlFlowRoot)`
		// tells the `FitLine` case-body path to REFUSE the glue outcome when
		// the body's single statement is keyword-led control flow (the
		// generated `caseBodyControlFlowRoot` predicate of the build's AST
		// family). Such a construct's continuation lines are siblings of its
		// head, so glued they render at the head's indent, which under
		// `alignInlineSwitchCaseBody` is the LABEL's. Wired on
		// `HxCaseBranch.body` / `HxDefaultBranch.stmts` alongside
		// `refuseFlatOnComplexExpr`.
		//
		// The SAME meta gates the accompanying sibling FORCE in the case-LIST
		// Star's pre-pass - `caseSiblingControlFlowFnExpr` reads it back off this
		// body Star through `elemBodyStarHasFlag`, so the two halves cannot be
		// enabled apart. Flag off => byte-identical on BOTH.
		final refuseGlueOnControlFlow: Bool = starNode.fmtHasFlag('refuseGlueOnControlFlowRoot');
		// ω-metadata-line-end-function: `@:fmt(metaLineEndPolicy('<optField>'))`
		// on a `@:trivia @:tryparse` Star wires inter-element + post-Star
		// separator dispatch through `opt.<optField>:MetadataLineEndPolicy`.
		// Default `None` (and absent flag) is byte-identical to pre-slice.
		final metaLineEndOptField: Null<String> = starNode.fmtReadString('metaLineEndPolicy');
		// ω-bug-2c-inner-star — read the same cascade `@:fmt(blankLines*)`
		// metas that the EOF-Star branch reads, so an inner Star (e.g.
		// `HxConditionalDecl.body`) opted in via the metas drives the
		// blank-line cascade between its sibling elements.
		final cascadeInfos: CascadeInfos = readCascadeInfosFromStar(starNode, elemRefName);
		// ω-trivia-tryparse-linelength: when the Star carries
		// `@:fmt(lineLengthAwareSeps)`, swap inter-element + padLeading
		// hard spaces for `_dile` probes + wrap in `_dn(_cols, ...)`.
		// Sister to the non-trivia bare-Star `padLeading||padTrailing`
		// branch's lineLengthAware path.
		final tryparseLineLengthAware: Bool = starNode.fmtHasFlag('lineLengthAwareSeps');
		// B4 ω-implements-extends-wrap: `@:fmt(heritageWrap)` on a
		// `@:trivia @:tryparse` Star (HxClassDecl.heritage /
		// HxInterfaceDecl.heritage) routes a MULTI-clause heritage list
		// (`extends A implements B …`) through the fork's
		// `wrapping.implementsExtends` FillLine layout: when the full
		// glued decl line is long, pack clauses from the front and break
		// the overflow clause(s) at additionalIndent 2 (8 spaces). The
		// single-clause path stays on the existing `lineLengthAwareSeps`
		// 1-tab break-before-keyword (matches fork single-clause +
		// `extends_break_before_keyword_not_type_params`). Abstract
		// `clauses` (from/to) never carries this flag — its
		// `lineLengthAwareSeps` behaviour is untouched.
		final tryparseHeritageWrap: Bool = starNode.fmtHasFlag('heritageWrap');
		// ω-slice-45 / issue_626: `@:fmt(forceInlineSep)` on a `@:trivia
		// @:tryparse` Star collapses every source linebreak between
		// consecutive elements to a single space. First consumers are
		// the modifier Stars on `HxMemberDecl.modifiers` and
		// `HxTopLevelDecl.modifiers` so multi-line `static\n\toverload`
		// round-trips as `static overload`. Comment trivia between
		// elements is out of scope — flag's contract is "treat
		// inter-element whitespace trivia as one space".
		final tryparseForceInlineSep: Bool = starNode.fmtHasFlag('forceInlineSep');
		// ω-cond-comp-elseif-double-newline: set on the cond-comp `elseifs`
		// Stars (HxConditional*.elseifs) whose HxElseif* elements self-terminate
		// with a padTrailing newline. See triviaTryparseStarExpr's
		// elemSelfTrailsNewline param.
		final tryparseElemSelfTrailsNewline: Bool = starNode.fmtHasFlag('elemSelfTrailsNewline');
		// ω-typedef-intersection-operand-break: `@:fmt(
		// operandBreakAfterMultilineBrace)` on a `@:trivia @:tryparse`
		// Star makes each element whose PRECEDING element rendered
		// multi-line and ended with a close brace receive a per-element
		// opt copy with `_intersectionOperandBreak = true`. Consumer:
		// `HxTypedefDecl.intersections` (the `& Type` clause Star).
		final tryparseOperandBreakAfterMultilineBrace: Bool = starNode.fmtHasFlag('operandBreakAfterMultilineBrace');
		// ω-trivia-tryparse-prior-after-trail: when the PREV sibling
		// field has a synthesised `<priorField>AfterTrail:Null<String>`
		// slot (mandatory Ref with `@:trail` in trivia-bearing mode),
		// thread its access so the Star can inline-emit the captured
		// trail-of-prev-field comment cuddled to the prev token.
		final tryparsePriorAfterTrailExpr: Null<Expr> = prevTrailFieldName == null ? null : {
			expr: EField(macro value, prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-blockended-trivia-tryparse (Session 3): thread the Star's
		// `@:sep('text', tailRelax, blockEnded)` annotation into
		// `triviaTryparseStarExpr` so the helper can inject `;`
		// between two non-`}`-ending elements. Non-blockEnded
		// tryparse Stars (every existing consumer) pass null sepText
		// and the helper splices a no-op.
		final tryparseSepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final tryparseBlockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		final tryparseSepFaithful: Bool = starNode.annotations['lit.sepFaithful'] == true;
		// ω-sep-faithful: re-emit a source-captured LEADING sep
		// (`#if X, elem #end`) from the `<field>SepBefore` slot — the trivia
		// twin of the plain path's sepBeforeOptActive pad swap.
		final tryparseSepBeforeAccess: Null<Expr> = tryparseSepFaithful && starNode.fmtHasFlag('sepBeforeOpt')
			? switch fieldAccess.expr {
				case EField(b, n): { expr: EField(b, '${n}SepBefore'), pos: fieldAccess.pos };
				case _: null;
			}
			: null;
		// Typed nested-conditional element probe (alignedNestedIncrease
		// span lift + blockEnded sep suppression): built HERE, where the
		// Star's element rule is known, as the mode-family
		// `elementIsConditional_<ElemRule>` fn-ref. Built only for the
		// Stars whose emission paths can consult it (conditionalBodyIndent
		// / blockEnded) — the grammar generates the per-rule variants for
		// exactly those element rules. Formats without generated
		// predicates pass null and both consumer sites emit their inert
		// `false`.
		final tryparseElemCondFn: Null<Expr> = _formatInfo.astPreds && (tryparseCondBodyIndent || tryparseBlockEnded)
			? AstPredLowering.predFnExpr(_shape.root, true, false, 'elementIsConditional_${simpleName(c.elemRefName)}')
			: null;
		// omega-cond-expr-fit: `@:fmt(condExprFitBreak)` on the tryparse Star
		// (the expression-scope cond-comp `elseifs`) swaps its inter-element
		// and trailing-pad spaces for knob-gated soft `Line(' ')` seps.
		final tryparseCondExprFit: Bool = starNode.fmtHasFlag('condExprFitBreak');
		// ω-splice-op-fill: `@:fmt(fillItems)` routes the Star to the fill
		// bypass — soft `Line(' ')` between elements, no pad, source newlines
		// ignored. Sole consumer: `HxCondSpliceOpExpr.terms`.
		final tryparseFillItems: Bool = starNode.fmtHasFlag('fillItems');
		parts.push(TriviaTryparseLowering.triviaTryparseStarExpr(
			tryCatchesSymmetryWrap(starNode, fieldAccess, elemRefName), elemFn, sepExpr, sameLineName != null, nestBody, tryparseTrailBB,
			tryparseTrailLC, tryparseTrailBA, firstSepOverride, subsequentSepOverride, caseBodyFlagNames, flatChildOptPairs,
			tryparsePadLeading, tryparsePadTrailing, propagateExprPosition, refuseFlatOnComplex, cascadeInfos.afterCtorInfos,
			cascadeInfos.beforeCtorInfos, cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos, cascadeInfos.headCtorInfos,
			metaLineEndOptField, cascadeInfos.betweenSameCtorIfNotInfos, tryparseLineLengthAware, tryparsePriorAfterTrailExpr,
			tryparseForceInlineSep, tryparseBlockEnded || tryparseSepFaithful ? tryparseSepText : null, tryparseBlockEnded,
			tryparseSepFaithful, tryparseHeritageWrap, tryparseCondBodyIndent, tryparseOperandBreakAfterMultilineBrace,
			clearExprPositionNonTail, tryparseSepBeforeAccess, tryparseElemSelfTrailsNewline, tryparseCondExprFit, tryparseElemCondFn,
			refuseGlueOnControlFlow, tryparseFillItems
		));
	}

	/**
	 * Trivia close-peek (`@:trail`) Star dispatch (the `if (closeText != null)`
	 * branch of the `isTriviaStar` block in `emitWriterStarField`). Routes the
	 * Star through `triviaSepStarExpr` (sep-bearing) or `triviaBlockStarExpr`
	 * (block) and pushes onto `parts`. Extracted to keep the orchestrator under
	 * the complexity gate.
	 * Trivia block-mode (`@:trail`, no flat sep) Star dispatch — the fall-through
	 * tail of `emitTriviaCloseStar` after the sep dispatch returns. Reads the
	 * block-layout `@:fmt` flags and pushes the `triviaBlockStarExpr` emit onto
	 * `parts`. Extracted to keep the helper under the complexity gate.
	 * Resolves the three classify-info builders (`interMemberInfo` /
	 * `staticVarSubdivInfo` / `condLeadingDocInfo`) read off a block-mode trivia
	 * Star, bundled for `emitTriviaBlockStarDispatch`. Extracted to keep that
	 * helper under the complexity gate.
	 */
	private function buildTriviaBlockInfos(starNode: ShapeNode, elemRefName: String, beforeDocComments: Bool): TriviaBlockInfos {
		final interMemberArgs: Null<Array<String>> = starNode.fmtReadStringArgs('interMemberBlankLines');
		// ω-interblank-cond-lookthrough: opt-in `@:fmt(interMember
		// CondLookThrough('<classifierField>', '<condCtor>',
		// '<bodyField>'))` makes `buildInterMemberClassifyInfo` classify
		// a `#if … #end` member by its FIRST inner member's kind instead
		// of the flat `0` ("other"). Mirrors `beforeDocCondLookThrough`'s
		// doc-comment look-through so two consecutive function-bearing
		// conditional members get a `betweenFunctions` blank. Inert unless
		// `interMemberBlankLines` is also present (the policy it widens).
		final interMemberCondArgs: Null<Array<String>> = starNode.fmtReadStringArgs('interMemberCondLookThrough');
		final interMemberInfo: Null<InterMemberClassifyInfo> = interMemberArgs == null
			? null
			: buildInterMemberClassifyInfo(elemRefName, interMemberArgs, interMemberCondArgs);
		// `fmtHasFlag` accepts both bare-identifier (`staticVarSubdivision`)
		// and call form (`staticVarSubdivision('modifiers', 'Static',
		// 'afterStaticVars')`) — `fmtReadStringArgs` is null in the
		// bare form and only carries args when the call form is used.
		final staticVarSubdiv: Bool = starNode.fmtHasFlag('staticVarSubdivision');
		final staticVarSubdivArgs: Null<Array<String>> = staticVarSubdiv ? starNode.fmtReadStringArgs('staticVarSubdivision') : null;
		final staticVarSubdivInfo: Null<StaticVarSubdivisionInfo> = staticVarSubdiv && interMemberInfo != null
			? buildStaticVarSubdivisionInfo(elemRefName, staticVarSubdivArgs ?? [])
			: null;
		// ω-cond-leading-doc-lookthrough: only meaningful alongside
		// `beforeDocCommentEmptyLines` (the policy whose doc-comment scan
		// it widens). Inert otherwise — the resolved info is dropped.
		final condLeadingDocArgs: Null<Array<String>> = starNode.fmtReadStringArgs('beforeDocCondLookThrough');
		final condLeadingDocInfo: Null<CondLeadingDocLookThroughInfo> = condLeadingDocArgs != null && beforeDocComments
			? buildCondLeadingDocLookThroughInfo(elemRefName, condLeadingDocArgs)
			: null;
		return {
			interMemberInfo: interMemberInfo,
			staticVarSubdivInfo: staticVarSubdivInfo,
			condLeadingDocInfo: condLeadingDocInfo
		};
	}

	/**
	 * Trivia block-mode (`@:trail`, no flat sep) Star dispatch — the fall-through
	 * tail of `emitTriviaCloseStar` after the sep dispatch returns. Reads the
	 * block-layout `@:fmt` flags and pushes the `triviaBlockStarExpr` emit onto
	 * `parts`. Extracted to keep the helper under the complexity gate.
	 */
	@:access(anyparse.macro.TriviaBlockLowering)
	private function emitTriviaBlockStarDispatch(c: TriviaStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final elemRefName: String = c.elemRefName;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		final trailCloseAccess: Null<Expr> = c.trailCloseAccess;
		final trailOpenAccess: Null<Expr> = c.trailOpenAccess;
		final blockEndedFlag: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		// `openText ?? ''` (was `?? '{'` through ω₅) — when a
		// close-peek Star has no `@:lead`, the surrounding Seq
		// emits the open delimiter before this field, so the Star
		// itself contributes nothing at the open position. Empty
		// string → `_dt('')` is a no-op, and `emptyText = '' +
		// closeText` stays format-neutral (invariant #5).
		final afterDocComments: Bool = starNode.fmtHasFlag('afterFieldsWithDocComments');
		final keepBetweenFields: Bool = starNode.fmtHasFlag('existingBetweenFields');
		final beforeDocComments: Bool = starNode.fmtHasFlag('beforeDocCommentEmptyLines');
		final indentCaseLabelsGate: Bool = starNode.fmtHasFlag('indentCaseLabels');
		final emptyCurlyBreak: Bool = starNode.fmtHasFlag('emptyCurlyBreak');
		// ω-blockempty: call-form `@:fmt(emptyCurlyBreak('<knob>'))`
		// names a per-construct EmptyCurly opt field. The bare form
		// returns null and falls back to `_inAnonFnBody` dispatch
		// inside `triviaBlockStarExpr`.
		final emptyCurlyKnob: Null<String> = fmtFirstStringArg(starNode, 'emptyCurlyBreak');
		final beginEndType: Bool = starNode.fmtHasFlag('beginEndType');
		// ω-enum-begin-end: `@:fmt(beginEndType('a', 'b'))` names the begin/end
		// opt knobs to read (default class-scoped `beginType` / `endType`), so
		// `HxEnumDecl.ctors` reads its own `enumBeginType` / `enumEndType`.
		final beginEndKnobArgs: Null<Array<String>> = starNode.fmtReadStringArgs('beginEndType');
		final beginTypeKnob: String = beginEndKnobArgs != null && beginEndKnobArgs.length >= 2 ? beginEndKnobArgs[0] : 'beginType';
		final endTypeKnob: String = beginEndKnobArgs != null && beginEndKnobArgs.length >= 2 ? beginEndKnobArgs[1] : 'endType';
		final keepCurlyBlanks: Bool = starNode.fmtHasFlag('keepCurlyBlanks');
		final lineCommentTrailBlank: Bool = starNode.fmtHasFlag('blankBeforeOrphanLineCommentTrail');
		final blankBeforeFinalDocInLeading: Bool = starNode.fmtHasFlag('blankBeforeFinalDocCommentInLeading');
		// ω-* classify-info builders resolved in buildTriviaBlockInfos.
		final infos: TriviaBlockInfos = buildTriviaBlockInfos(starNode, elemRefName, beforeDocComments);
		final interMemberInfo: Null<InterMemberClassifyInfo> = infos.interMemberInfo;
		final staticVarSubdivInfo: Null<StaticVarSubdivisionInfo> = infos.staticVarSubdivInfo;
		final condLeadingDocInfo: Null<CondLeadingDocLookThroughInfo> = infos.condLeadingDocInfo;
		final betweenMultilineCommentsBlanks: Bool = starNode.fmtHasFlag('betweenMultilineCommentsBlanks');
		// ω-blank-around-multiline-members: `@:fmt(blankAroundMultilineMembers('<optField>'))`
		// names the `WriteOptions` Int knob holding the blank count. Absent → the
		// three splice points are `macro {}` and the loop generates byte-identical.
		final blankAroundOptField: Null<String> = fmtSingleStringArg(starNode, 'blankAroundMultilineMembers');
		final uniformBetweenOptField: Null<String> = fmtSingleStringArg(starNode, 'uniformBetween');
		final anonFnClear: Bool = starNode.fmtHasFlag('leftCurlyAnonFnOverride');
		// ω-blockright-curly: call-form `@:fmt(rightCurly('<knob>'))`
		// on a Seq-struct Star names a per-construct
		// RightCurlyPlacement opt field. Sister to `emptyCurlyKnob`
		// — when null, dispatch falls back to unconditional
		// `_dhl()` before close inside `triviaBlockStarExpr`.
		final rightCurlyKnob: Null<String> = fmtFirstStringArg(starNode, 'rightCurly');
		// ω-anonfunction-right-curly: call-form
		// `@:fmt(rightCurlyAnonFnOverride('<knob>'))` on a Seq-struct
		// Star names a RightCurlyPlacement opt field read only when
		// `_inAnonFnBody=true`. Used by `HxFnBlock.stmts` to route
		// anon-fn body closes through `opt.anonFunctionRightCurly`
		// while keeping `HxFnDecl.body` / `HxUntypedFnBody.block`
		// (same `HxFnBlock` Star, `_inAnonFnBody=false`) on the
		// pre-slice `_dhl()` path.
		final rightCurlyAnonFnKnob: Null<String> = fmtFirstStringArg(starNode, 'rightCurlyAnonFnOverride');
		// ω-anon-fn-body-stmt-position: HxFnExpr / HxFnDecl / HxUntypedFnBody
		// bodies share HxFnBlock.stmts; when it carries
		// @:fmt(clearExprPositionNonTail) (mirroring HxExpr.BlockExpr) the block
		// clears the leaked expression-position frame for its statements, so a
		// statement `if` in an anon-fn body inlines via `ifBody` instead of
		// `expressionIf`. Struct-block Stars without the flag stay byte-identical.
		final clearExprPositionNonTail: Bool = starNode.fmtHasFlag('clearExprPositionNonTail');
		// ω-uniform-statement-blanks: opt-in on statement-block Stars
		// (`HxExpr.BlockExpr.stmts`, `HxFnBlock.stmts`). Drives the
		// `_uniformCollapse` pre-pass + per-element blank suppression.
		final uniformStmtBlanks: Bool = starNode.fmtHasFlag('uniformStmtBlanks');
		// omega-condswitchopen-cases-nest: `HxCondSpliceSwitchOpen.cases` (the shared
		// switch case list of a `#if for { switch { #else ... #end` region) sits
		// TWO block levels below the enclosing statement - the region's outer
		// block AND the switch - but a block Star's body Doc carries only one
		// `_dn` level. This flag wraps the whole field emit in one extra
		// `_dn(_cols, ...)` so the case labels land at statement+2 and the
		// switch-closing `}` at statement+1, matching a physically-nested
		// `for (..) { switch (..) { case .. } }`. Byte-inert for every other
		// block Star (the flag is unique to that one field).
		final condSwitchOpenCasesNest: Bool = starNode.fmtHasFlag('condSwitchOpenCasesNest');
		final emptyBlockBreak: Bool = starNode.fmtHasFlag('emptyBlockBreak');
		final caseSymArgs: Null<Array<String>> = starNode.fmtReadStringArgs('caseSiblingSymmetry');
		final caseSiblingUnitsFn: Null<Expr> = caseSiblingUnitsFnExpr(caseSymArgs, elemRefName);
		final caseSiblingStructuralFn: Null<Expr> = caseSiblingStructuralFnExpr(caseSymArgs, elemRefName);
		final caseSiblingControlFlowFn: Null<Expr> = caseSiblingControlFlowFnExpr(caseSymArgs, elemRefName);
		final blockStar: Expr = TriviaBlockLowering.triviaBlockStarExpr(
			fieldAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn, openText ?? '', closeText, false,
			afterDocComments, keepBetweenFields, beforeDocComments, interMemberInfo, indentCaseLabelsGate, emptyCurlyBreak, beginEndType,
			keepCurlyBlanks, lineCommentTrailBlank, blankBeforeFinalDocInLeading, staticVarSubdivInfo, betweenMultilineCommentsBlanks,
			uniformBetweenOptField, anonFnClear, emptyCurlyKnob, rightCurlyKnob, rightCurlyAnonFnKnob, blockEndedFlag ? sepText : null,
			blockEndedFlag, blockEndedFlag ? (starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE]: Null<String>) : null,
			blockEndedFlag ? _formatInfo.schemaTypePath : null, condLeadingDocInfo, clearExprPositionNonTail, beginTypeKnob, endTypeKnob,
			uniformStmtBlanks, emptyBlockBreak, caseSymArgs, caseSiblingUnitsFn, caseSiblingStructuralFn, caseSiblingControlFlowFn,
			blankAroundOptField
		);
		final blockStarNested: Expr = macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			_dn(_cols, $blockStar);
		};
		parts.push(condSwitchOpenCasesNest ? blockStarNested : blockStar);
	}

	/**
	 * Trivia close-peek (`@:trail`) Star dispatch (the `if (closeText != null)`
	 * branch of the `isTriviaStar` block in `emitWriterStarField`). Emits the
	 * leftCurly separator, routes a flat-sep Star through `triviaSepStarExpr`, else
	 * falls through to `emitTriviaBlockStarDispatch`. Extracted to keep the
	 * orchestrator under the complexity gate.
	 */
	@:access(anyparse.macro.TriviaSepLowering)
	private function emitTriviaCloseStar(c: TriviaStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final isFirstField: Bool = c.isFirstField;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailNLAccess: Null<Expr> = c.trailNLAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		final trailCloseAccess: Null<Expr> = c.trailCloseAccess;
		final trailOpenAccess: Null<Expr> = c.trailOpenAccess;
		final trailPresentAccess: Null<Expr> = c.trailPresentAccess;
		// First-field Star with knob-form `@:fmt(leftCurly('<knob>'))`
		// (e.g. `HxObjectLit.fields`) fires the leftCurly switch
		// even at first-field position — its outer caller already
		// emits the inter-token space via `_dop(' ')`, so the
		// `Same` branch is `_de()` and `Next` is `_dhl()` (drops
		// the pending OptSpace and writes a hardline).
		final knobLeftCurly: Null<String> = starNode.fmtReadString('leftCurly');
		final hasKnobLeftCurly: Bool = knobLeftCurly != null;
		// ω-objectlit-leftCurly-cascade: when the Star carries BOTH
		// `@:fmt(wrapRules(...))` AND `@:fmt(leftCurly('<knob>'))`,
		// leftCurly emission moves INSIDE `triviaSepStarExpr` so the
		// no-trivia branch can wire `IfBreak(_dhl(), _de())` into the
		// wrap engine's Group — short literals stay cuddled even when
		// the knob is `Next`. Trivia-bearing branch keeps the
		// pre-slice unconditional `_dhl()`/`_de()`. Outer site keeps
		// emitting `leftCurlySeparator` for the no-wrap-rules case
		// (legacy bare-flag callers and future knob-form callers
		// without wrap-rules).
		final wrapRulesField: Null<String> = starNode.fmtReadString('wrapRules');
		final leftCurlyOwnedBySep: Bool = hasKnobLeftCurly && wrapRulesField != null;
		// Head -> body seam: a close-peek Star opens the construct's body
		// (`HxSwitchStmt.cases`), and when the preceding sibling is a Ref
		// with `@:trail` its `<field>AfterTrail` slot holds the same-line
		// comment cuddled to that closer (`switch (v) // c` + newline `{`).
		// Only the tryparse-Star path consumed that slot, so here the
		// comment was captured and then dropped. Emitting it guarded turns
		// the following `leftCurlySeparator` default (`_dossh`, drops after
		// a hardline) into the Allman `{` placement the comment forces.
		if (c.prevTrailFieldName != null) {
			final afterTrailAccess: Expr = {
				expr: EField(macro value, c.prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX),
				pos: Context.currentPos()
			};
			parts.push(macro {
				final _atSeam: Null<String> = $afterTrailAccess;
				_atSeam != null ? trailingCommentDocGuarded(_atSeam, opt) : _de();
			});
		}
		if (!leftCurlyOwnedBySep && (!isFirstField || hasKnobLeftCurly) && isSpacedLead(openText))
			parts.push(leftCurlySeparator(starNode, isFirstField && hasKnobLeftCurly));
		// ω-trivia-sep: sep-Star with @:trivia routes to a
		// dedicated helper that drives multi-line vs flat layout
		// from per-element `newlineBefore` / comment trivia.
		//
		// ω-wraprules-objlit: when the Star carries
		// `@:fmt(wrapRules('<field>'))`, the no-trivia branch of
		// `triviaSepStarExpr` defers to the runtime
		// `WrapList.emit` engine so the cascade picks the layout
		// shape (NoWrap / OnePerLine / FillLine / …). The
		// trivia-bearing branch still forces multi-line — when
		// inline / leading / trailing comments are present, the
		// list cannot collapse to a single line regardless of
		// what the cascade would say.
		// ω-blockended-trivia (Session 3): `@:sep('text', tailRelax,
		// blockEnded)` on a block-mode trivia Star (HxFnBlock.stmts
		// / HxBlockExpr.stmts / HxBlockStmt.stmts) keeps the
		// per-element hardlined block layout — sep emit moves
		// INSIDE `triviaBlockStarExpr` (extended), NOT through the
		// flat-or-multi `triviaSepStarExpr`. Detect the flag here
		// and skip the sep dispatch so the fall-through reaches
		// the block dispatch with sepText/blockEnded threaded.
		final blockEndedFlag: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		if (sepText != null && !blockEndedFlag) {
			// ω-cascade-emits-comments: emit the funcParamParens /
			// typeParamOpen space inside the @:trivia + sep
			// dispatch — the @:trivia path returns BEFORE the
			// no-trivia branch at `:3504-3510` that owns the
			// equivalent emit, so without this mirror the
			// `function foo ()` space (and sister knobs) is
			// silently dropped when the Star becomes @:trivia.
			// First-field Stars skip (matches the no-trivia path's
			// `!isFirstField` gate).
			if (!isFirstField) {
				final triviaParamSpace: Null<Expr> = openDelimPolicySpace(starNode, ['funcParamParens', 'typeParamOpen']);
				if (triviaParamSpace != null) parts.push(triviaParamSpace);
			}
			// ω-objectlit-source-trail-comma: when the Star also
			// carries `@:fmt(trailingComma('<knob>'))`, thread the
			// knob's field name into `triviaSepStarExpr` so its
			// no-trivia branch can `forceExceeds` on the wrap engine
			// when the source had a trailing separator AND the knob
			// is on. Null knob → behaves identically to pre-slice
			// (cascade evaluates exceeds=false / =true symmetrically).
			final trailingCommaField: Null<String> = starNode.fmtReadString('trailingComma');
			// ω-objectlit-right-curly: struct-Star path now threads
			// `@:fmt(rightCurly('<knob>'))` (e.g.
			// `rightCurly('objectLiteralRightCurly')` on
			// `HxObjectLit.fields`) into `triviaSepStarExpr`'s 12th
			// param. Null (no opt-in) preserves pre-slice
			// unconditional `_dhl()` before close.
			final knobRightCurly: Null<String> = starNode.fmtReadString('rightCurly');
			// ω-typedef-anon-force-multi: when the sep-Star carries
			// `@:fmt(forceMultiInTypedef)` (currently only
			// `HxType.Anon.fields`), thread the flag into
			// `triviaSepStarExpr` so its no-trivia branch emits a
			// runtime `opt._inTypedefBody ? WrapMode.OnePerLine :
			// null` as `WrapList.emit`'s `forceMode` option.
			// Bypasses the cascade only when the typedef-RHS
			// context is active — non-typedef anon consumers
			// (var-type-hint, fn-return-type) stay cascade-driven.
			final forceMultiTypedef: Bool = starNode.fmtHasFlag('forceMultiInTypedef');
			final bodyAware: Bool = starNode.fmtHasFlag('bodyAwareCompactIndent');
			// ω-group-rest-probe slice 2: struct-Star path reader for
			// `@:fmt(groupRestProbe)`. Mirrors the lowerStruct plain-
			// path read (added at the lowerStruct dispatch site).
			// Trivia-path dual-dispatch closure per
			// [[feedback-wraprules-dispatch-dual-path]].
			final groupRestProbe: Bool = starNode.fmtHasFlag('groupRestProbe');
			// ω-cascade-emits-comments: struct-Star path reader for
			// `@:fmt(ignoreSourceNewlinesForWrap)`. Intrinsic
			// per-construct opt-in to fork's `Ignore` semantic —
			// drops `Trivial<T>.newlineBefore` signal, routes
			// per-element block-trailing + leading comments
			// through the cascade no-trivia branch. Currently
			// `HxFnDecl.params`.
			final ignoreSourceNewlines: Bool = starNode.fmtHasFlag('ignoreSourceNewlinesForWrap');
			// ω-array-reflow: struct-Star path reader for
			// `@:fmt(reflowSourceMultiline)`. Sister to the enum-Alt
			// read; threads into `triviaSepStarExpr`'s `_smlKeep`
			// gate. No struct-Star consumer opts in yet (first
			// consumer `HxExpr.ArrayExpr` is enum-Alt) — present for
			// dual-dispatch symmetry.
			final reflowSourceMultilineStar: Bool = starNode.fmtHasFlag('reflowSourceMultiline');
			// ω-arraymatrix-wrap: struct-Star path reader for
			// `@:fmt(arrayMatrixWrap)`. Sister to the enum-Alt read;
			// no struct-Star consumer opts in yet (first consumer
			// `HxExpr.ArrayExpr` is enum-Alt) — present for dual-
			// dispatch symmetry. `bracketKindPad` is not read on this
			// path (passed false) so matrix slots in after it.
			final matrixWrapStar: Bool = starNode.fmtHasFlag('arrayMatrixWrap');
			// ω-expressionif-collapse (mechanism A): the struct-Star
			// trivia path must not pass literal `null, null` for
			// the inside-of-delimiter spacing slots — else a Star carrying
			// `@:fmt(objectLiteralBracesOpen, objectLiteralBracesClose)`
			// (HxObjectLit.fields) gets no `{ x }` padding. Read
			// the policy Doc the same way the plain `@:sep` path
			// (~5560) and the enum-Alt path (~2363) do —
			// `delimInsidePolicySpace` returns null when no delim
			// policy flag is present, so every other struct-Star stays
			// byte-identical.
			final openInsideStar: Null<Expr> = delimInsidePolicySpace(starNode, ['typeParamOpen', 'objectLiteralBracesOpen'], false);
			final closeInsideStar: Null<Expr> = delimInsidePolicySpace(starNode, ['typeParamClose', 'objectLiteralBracesClose'], true);
			// ω-expressionif-collapse (mechanism B read-site):
			// `@:fmt(reflowInExprPosition)` (HxObjectLit.fields) opts
			// the Star into source-newline ignore — but only at runtime
			// when `opt._inValueIfBranch` is set (the immediate value of
			// a value-if branch). Default false → byte-inert.
			final reflowInExprBranchStar: Bool = starNode.fmtHasFlag('reflowInExprPosition');
			// ω-multiline-trailing-comma-remove / ω-uniform-element-blanks:
			// struct-Star path readers. `trailingCommaRemovable` is live here
			// (`HxObjectLit.fields`, `HxNewExpr.args`); `uniformStmtBlanks` has
			// no struct-Star consumer yet (first consumer `HxExpr.ArrayExpr` is
			// enum-Alt) — read for dual-dispatch symmetry.
			final trailingCommaRemovableStar: Bool = starNode.fmtHasFlag('trailingCommaRemovable');
			final uniformStmtBlanksStar: Bool = starNode.fmtHasFlag('uniformStmtBlanks');
			// ω-complex-item-count: struct-Star path reader for
			// `@:fmt(complexItems)` — the per-element AST classification behind
			// the `complexItemCount >= n` cascade condition and the fill-mode
			// chunk policy. Live here for `HxNewExpr.args`; the array literal
			// opts in through the enum-Alt reader.
			final complexItemsStar: Bool = starNode.fmtHasFlag('complexItems');
			// ω-mapwrap: struct-Star reader, dual-dispatch twin of the enum-Alt
			// one in `triviaSepStarBuild`. This is the OTHER trivia sep-Star
			// entry point, and it is the only other one: the two plain-path
			// `wrapRules` sites build their own `WrapList.emit` call and never
			// reach `triviaSepStarExpr`, so a Star naming a map cascade there
			// would be ignored — but no Star can, since `@:trivia` is what routes
			// a sep-Star here and `HxExpr.ArrayExpr` carries it.
			//
			// No struct-Star names a map cascade today, so this reads null and the
			// emitted call is byte-identical. It is wired rather than hardcoded
			// null because the read alone is what the next Star to carry the meta
			// on this path will need. Such a Star would also have to hold `HxExpr`
			// elements — `mapWrapFor` hands `_arr[0].node` to a predicate whose
			// parameter is `Null<HxExpr>`, so a Star of anything else is a
			// macro-time type error rather than a silent misclassification.
			final mapWrapStar: Null<SepStarMapWrap> = mapWrapFor(starNode.fmtReadString('mapWrapRules'));
			parts.push(TriviaSepLowering.triviaSepStarExpr(
				fieldAccess, trailBBAccess, trailLCAccess, trailCloseAccess, trailOpenAccess, elemFn, openText ?? '', closeText, sepText,
				wrapRulesField, leftCurlyOwnedBySep ? knobLeftCurly : null, knobRightCurly, trailPresentAccess, trailingCommaField,
				openInsideStar, closeInsideStar, false, forceMultiTypedef, bodyAware, groupRestProbe, ignoreSourceNewlines,
				reflowSourceMultilineStar, matrixWrapStar, trailNLAccess, false, false, reflowInExprBranchStar, trailingCommaRemovableStar,
				uniformStmtBlanksStar, complexItemsStar, mapWrapStar
			));
			return;
		}
		emitTriviaBlockStarDispatch(c, parts);
	}

	/**
	 * Trivia EOF Star dispatch (the `else if (isLastField)` branch of the
	 * `isTriviaStar` block in `emitWriterStarField`). Reads the cascade infos and
	 * file-header / line-comment blank flags, then pushes the `triviaEofStarExpr`
	 * emit onto `parts`. Extracted to keep the orchestrator under the complexity
	 * gate.
	 */
	@:access(anyparse.macro.TriviaEofLowering)
	private function emitTriviaEofStar(c: TriviaStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemFn: String = c.elemFn;
		final elemRefName: String = c.elemRefName;
		final openText: Null<String> = c.openText;
		final trailBBAccess: Null<Expr> = c.trailBBAccess;
		final trailLCAccess: Null<Expr> = c.trailLCAccess;
		if (openText != null) parts.push(macro _dt($v{openText}));
		// ω-measured-multiline-decl — this is the ONE Star kind whose scaffold
		// declares `_measMulti`, so this is the one caller that may hand the
		// cascade an accessor into it.
		final measuredMultiline: Bool = starNode.fmtHasFlag('measuredMultilineDecls');
		final cascadeInfos: CascadeInfos = readCascadeInfosFromStar(
			starNode, elemRefName, measuredMultiline ? (macro _measMulti[_si]) : null
		);
		final lineCommentTrailBlank: Bool = starNode.fmtHasFlag('blankBeforeOrphanLineCommentTrail');
		final lineCommentLedAddBlank: Bool = starNode.fmtHasFlag('blankBeforeLineCommentLed');
		final afterFileHeaderCommentBlanks: Bool = starNode.fmtHasFlag('afterFileHeaderCommentBlanks');
		final betweenMultilineCommentsBlanks: Bool = starNode.fmtHasFlag('betweenMultilineCommentsBlanks');
		parts.push(TriviaEofLowering.triviaEofStarExpr(
			fieldAccess, trailBBAccess, trailLCAccess, elemFn, cascadeInfos.afterCtorInfos, cascadeInfos.beforeCtorInfos,
			cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos, cascadeInfos.headCtorInfos, lineCommentTrailBlank,
			lineCommentLedAddBlank, afterFileHeaderCommentBlanks, betweenMultilineCommentsBlanks, cascadeInfos.betweenSameCtorIfNotInfos,
			measuredMultiline
		));
	}

	/**
	 * Plain-mode block-ended sep Star dispatch (the
	 * `closeText != null && sepText != null && blockEnded` branch of
	 * `emitWriterStarField`). Emits the blockBody-shape multiline layout with the
	 * `;`/`}`-terminator + format-predicate sep suppression. Extracted to keep the
	 * orchestrator under the complexity gate.
	 */
	private function emitBlockEndedPlainStar(c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		final predicateName: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE];
		final predicateCheck: Expr = blockEndedPredCheck(predicateName, macro _arr[_si]);
		// Phase G2 (Session 10) — trail-emit-on-last for plain mode.
		// Mirror of between-element gate below, queried on the last
		// element. Required when per-stmt `@:trailOpt(';')` is removed
		// from a ctor (Session 10 migration) — the element's Doc no
		// longer bakes `;`, so the Star owns trailing emit. Mirrors
		// trivia mode's `blockTrailSepEmitExpr` (L7002-7009) minus the
		// source-fidelity `sepAfter` gate (plain mode has no per-pair
		// state — always emit when non-block-ended).
		final lastPredicateCheck: Expr = blockEndedPredCheck(predicateName, macro _arr[_arr.length - 1]);
		parts.push(macro {
			final _arr = $fieldAccess;
			if (_arr.length == 0) {
				_dc([_dt($v{openText ?? ''}), _dt($v{closeText})]);
			} else {
				final _items: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				var _lastElemDoc: Null<anyparse.core.Doc> = null;
				while (_si < _arr.length) {
					final _elemDoc: anyparse.core.Doc = $elemCall;
					_items.push(_dhl());
					_items.push(_elemDoc);
					if (_si < _arr.length - 1 && !anyparse.core.DocMeasure.endsWithSemi(_elemDoc) && !($predicateCheck)) {
						_items.push(_dt($v{sepText}));
					}
					_lastElemDoc = _elemDoc;
					_si++;
				}
				if (_lastElemDoc != null && !anyparse.core.DocMeasure.endsWithSemi(_lastElemDoc) && !($lastPredicateCheck)) {
					_items.push(_dt($v{sepText}));
				}
				final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				_dc([_dt($v{openText ?? ''}), _dn(_cols, _dc(_items)), _dhl(), _dt($v{closeText})]);
			}
		});
	}

	/**
	 * Plain-mode EOF Star dispatch (the final `else` branch of
	 * `emitWriterStarField`). Emits the lead then the double-hardline-separated
	 * element list. Extracted to keep the orchestrator under the complexity gate.
	 */
	private function emitEofPlainStar(c: PlainStarCtx, parts: Array<Expr>): Void {
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final openText: Null<String> = c.openText;
		// EOF mode. Emit lead if present.
		if (openText != null) parts.push(macro _dt($v{openText}));
		parts.push(macro {
			final _arr = $fieldAccess;
			if (_arr.length == 0)
				_de()
			else {
				final _docs: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				while (_si < _arr.length) {
					if (_si > 0) {
						_docs.push(_dhl());
						_docs.push(_dhl());
					}
					_docs.push($elemCall);
					_si++;
				}
				_dc(_docs);
			}
		});
	}

	/**
	 * Plain-mode sep Star dispatch (the `closeText != null && sepText != null`
	 * branch of `emitWriterStarField`). Routes the list through sepList / fillList
	 * / WrapList per the wrap `@:fmt` flags and emits the first-field pattern-list
	 * keep. Extracted to keep the orchestrator under the complexity gate.
	 * Plain-mode sep Star list emission — the tail of `emitSepStar` after the
	 * `\n`-join and leading-space handling. Builds the sepList / fillList /
	 * WrapList call and the first-field pattern-list keep, then pushes onto
	 * `parts`. Extracted to keep the helper under the complexity gate.
	 */
	private function emitSepStarList(c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final isFirstField: Bool = c.isFirstField;
		final typePath: String = c.typePath;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		final tcExpr: Expr = trailingCommaExpr(starNode);
		final openInsideExpr: Expr = delimInsidePolicySpace(starNode, ['typeParamOpen', 'objectLiteralBracesOpen'], false) ?? macro _de();
		final closeInsideExpr: Expr = delimInsidePolicySpace(starNode, ['typeParamClose', 'objectLiteralBracesClose'], true) ?? macro _de();
		final keepInnerExpr: Expr = keepInnerWhenEmptyExpr(starNode);
		// ω-fill-primitive: `@:fmt(fill)` on the Star routes the list
		// through `fillList` (Wadler fillSep) instead of `sepList`,
		// packing items inline up to the line budget and breaking the
		// separator before each overflow item at the list's indent.
		//
		// ω-wraprules-objlit: `@:fmt(wrapRules('<optionFieldName>'))`
		// supersedes both above paths — routes the list through the
		// runtime `WrapList.emit` engine driven by the named
		// `WrapRules` cascade on `opt`. The cascade picks one of
		// `NoWrap` / `OnePerLine` / `OnePerLineAfterFirst` /
		// `FillLine` per call from item count, max/total flat width
		// and an `exceedsMaxLineLength` flag — the engine evaluates
		// the cascade twice (`exceeds=false` + `exceeds=true`) and
		// emits `Group(IfBreak(brkDoc, flatDoc))` when the two runs
		// disagree, so the renderer's flat/break decision picks the
		// right mode at layout time. First consumer is `HxObjectLit`
		// (`objectLiteralWrap`); future slices wire `arrayWrap`,
		// `anonTypeWrap`, `callParameterWrap`, … through the same
		// engine. `@:fmt(fill)` / `@:fmt(fillDoubleIndent)` are
		// orthogonal — they continue to drive `fillList` for sites
		// that opt into Wadler fillSep without per-construct rules.
		final wrapRulesField: Null<String> = starNode.fmtReadString('wrapRules');
		final useFill: Bool = starNode.fmtHasFlag('fill');
		final fillDouble: Bool = starNode.fmtHasFlag('fillDoubleIndent');
		// ω-functionsignature-body-aware-indent: `@:fmt(bodyAwareCompactIndent)`
		// on the Star threads `true` into `WrapList.emit`'s `compactContinuation`
		// param for EVERY function-signature wrap. Such signatures carry
		// `ignoreSourceNewlinesForWrap`, so their ONLY break source is the
		// cascade leading-break, which lands at `calcIndent + additionalIndent`
		// (the additional-only continuation regime) — the same indent the
		// multi-param one-per-line path uses. Threading `opt._fnSigBodyEmpty`
		// here was too narrow: a NON-empty single-param signature (cascade
		// `itemCount <= 1 -> noWrap`, its default fillLineWithLeadingBreak
		// owning the overflow break) then took the fit-driven `1 + additional`
		// paren-bump regime and gained an extra indent level. Fields without
		// the flag pass `false` so only the opt-in site reacts. That slot had no
		// other reader, and its producer `@:fmt(propagateFnBodyEmpty)` is gone, so
		// re-narrowing now means re-deriving the emptiness, not reading an opt field.
		final bodyAware: Bool = starNode.fmtHasFlag('bodyAwareCompactIndent');
		// ω-group-rest-probe slice 2: `@:fmt(groupRestProbe)` opt-in for
		// Star fields whose outer Group should bias toward MBreak when
		// significant same-line content trails (typedef LHS typeParams,
		// followed by ` = Rhs<…>;`). Mirrors fork's `lengthAfter` rule
		// at Group layer. Non-trivia-dispatch `groupRestProbe` option of
		// `WrapList.emit`; trivia path mirror lives in `triviaSepStarExpr`
		// (dual-dispatch per [[feedback-wraprules-dispatch-dual-path]]).
		final groupRestProbe: Bool = starNode.fmtHasFlag('groupRestProbe');
		// ω-pattern-rest-probe (T169): gated at RUNTIME, like the trivia mirror
		// in `TriviaSepLowering` and the postfix-Star `Call` site — the
		// suppression is a property of the DESCENT (a case pattern is a matching
		// shape and never owns the line's overflow), not of the Star. The
		// backlog note that stood here called this gap plain-only and therefore
		// invisible to `fmt`; that was wrong. 14 of the 18 struct-field Star
		// carriers have no `@:trivia` (every declare-site `<T, …>` list plus
		// `HxNewExpr.params`, `HxTypeRef.params` and `HxArrowFnType.args`) and
		// this is their ONLY dispatch in BOTH writers, so
		// `case (x : Map<A, B>) if (…):` exploded its type parameters in the
		// trivia writer too. Census and per-assertion killers:
		// `HxGroupRestProbeStructStarTest`. Reading `opt._suppressPatternRestProbe`
		// couples the emit to a grammar that DECLARES that option — the same
		// coupling the postfix gate already carries, and it binds only for a Star
		// that opted into `groupRestProbe`, which no grammar but Haxe does.
		//
		// STILL OPEN, and the other half of the note that stood here: this call
		// passes 3 of the ~15 options its trivia mirror does, `complexItemKinds`
		// among them — the same plain/trivia asymmetry one option over.
		final groupRestProbeExpr: Expr = groupRestProbe ? (macro !opt._suppressPatternRestProbe) : (macro false);
		final listCall: Expr = if (wrapRulesField != null) {
			final rulesExpr: Expr = optFieldAccess(wrapRulesField);
			final compactContExpr: Expr = macro $v{bodyAware};
			macro anyparse.format.wrap.WrapList.emit(
				$v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $openInsideExpr, $closeInsideExpr, $keepInnerExpr, $rulesExpr, {
					appendTrailingComma: $tcExpr,
					compactContinuation: $compactContExpr,
					groupRestProbe: $groupRestProbeExpr
				}
			);
		} else if (useFill) {
			macro fillList(
				$v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, $keepInnerExpr,
				$v{fillDouble}
			);
		} else {
			macro sepList(
				$v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, $keepInnerExpr,
				false
			);
		};
		// ω-casepattern-keep: a FIRST-field bare Star that opts into
		// `@:fmt(beforeNewlineSlotFirst)` (only `HxCaseBranch.patterns`)
		// reads the synth `<field>BeforeNewline:Bool` slot. When the
		// source broke right after the parent `case` keyword AND
		// `opt.leftCurly == Next` (the `lineEnds.leftCurly: before`/`both`
		// configs where fork puts a line-end before the pattern's `{`),
		// wrap the pattern list Doc in `_dn(_cols, _dc([_dhl, …]))` so
		// `case\n\t{pattern}` round-trips verbatim. The body field follows
		// on the `:`-glued line, governed by its own `caseBody`/
		// `expressionCase` keep. Gated on trivia + bearing + the opt-in
		// flag so every non-bearing / plain-mode emit (no slot) keeps the
		// unconditional glued list; gated on `leftCurly == Next` at
		// runtime so `Same` configs and the absent-newline source shape
		// (`case {pattern}`) stay byte-identical. The parent
		// `HxSwitchCase.CaseBranch` ctor carries `@:fmt(deferKwSpace)`, so
		// the `case ` trailing space drops cleanly before the hardline.
		// Mirrors the bare-Ref first-field channel (`HxTryCatchStmt.body`
		// / `bodyPolicyWrap` Next branch `_dn(_cols, [_dhl, body])`).
		final firstStarNlKeep: Bool = isFirstField && _ctx.trivia && isTriviaBearing(typePath)
			&& starNode.fmtHasFlag(BEFORE_NEWLINE_SLOT_FIRST);
		final patternListExpr: Expr = if (firstStarNlKeep) {
			final nlFieldName: String = starNode.annotations[AnnotationKeys.BASE_FIELD_NAME];
			final beforeNlAccess: Expr = {
				expr: EField(macro value, nlFieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX),
				pos: Context.currentPos()
			};
			macro {
				final _patListDoc: anyparse.core.Doc = $listCall;
				final _patBeforeNl: Bool = $beforeNlAccess && opt.leftCurly == anyparse.format.BracePlacement.Next;
				final _patCols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				_patBeforeNl ? _dn(_patCols, _dc([_dhl(), _patListDoc])) : _patListDoc;
			};
		} else
			macro $listCall;
		parts.push(macro {
			final _arr = $fieldAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			var _si: Int = 0;
			while (_si < _arr.length) {
				_docs.push($elemCall);
				_si++;
			}
			$patternListExpr;
		});
	}

	/**
	 * Plain-mode sep Star dispatch (the `closeText != null && sepText != null`
	 * branch of `emitWriterStarField`). Handles the `\n`-join shortcut and the
	 * leading-space placement, then delegates the list emission to
	 * `emitSepStarList`. Extracted to keep the orchestrator under the complexity
	 * gate.
	 */
	private function emitSepStar(c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final isFirstField: Bool = c.isFirstField;
		final isRaw: Bool = c.isRaw;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		final sepText: Null<String> = c.sepText;
		// Newline as separator — semantically a hardline between
		// elements, not a soft-fit-or-break token. `sepList` uses a
		// soft-line (space-in-flat / newline-in-break) which doesn't
		// match "newlines are structure." Route `@:sep('\n')` to a
		// flat hardline-join emission: `open + \n + item + \n + … + \n + close`.
		// No Nest — enclosing scope's indent reaches interior lines
		// unchanged. Format-neutral — any grammar using `@:sep('\n')`
		// gets this layout.
		if (sepText == '\n') {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [_dt($v{openText ?? ''})];
				var _si: Int = 0;
				while (_si < _arr.length) {
					if (_si > 0) _docs.push(_dhl());
					_docs.push($elemCall);
					_si++;
				}
				_docs.push(_dt($v{closeText}));
				_dc(_docs);
			});
			return;
		}
		// ω-E-whitespace: spaced leads (`{`) get a plain leading space;
		// a Star with `@:fmt(funcParamParens)` opts into a runtime-
		// switched space before its open delim. The two branches are
		// structurally exclusive so a grammar site that ever combined
		// them (spaced-lead `{` with a funcParamParens-style flag)
		// cannot produce a double space.
		//
		// ω-typeparam-spacing: `@:fmt(typeParamOpen)` extends the same
		// outside-before-open path — `Before`/`Both` on `<` emit a
		// space before the delim (`Foo <Int>`). `After`/`Both` on
		// `<` and `Before`/`Both` on `>` route through `delimInsidePolicySpace`
		// below to splice padding INSIDE the delimiters via `sepList`'s
		// `openInside` / `closeInside` Doc args.
		if (!isFirstField && !isRaw) {
			if (isSpacedLead(openText)) {
				parts.push(macro _dt(' '));
			} else {
				final paramSpace: Null<Expr> = openDelimPolicySpace(starNode, ['funcParamParens', 'typeParamOpen']);
				if (paramSpace != null) parts.push(paramSpace);
			}
		}
		emitSepStarList(c, parts);
	}

	/**
	 * Plain-mode close-peek (`@:trail`, no sep) Star dispatch (the
	 * `else if (closeText != null)` branch of `emitWriterStarField`). Emits the
	 * leftCurly separator then the `blockBody` layout. Extracted to keep the
	 * orchestrator under the complexity gate.
	 */
	private function emitClosePlainStar(c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final isFirstField: Bool = c.isFirstField;
		final isRaw: Bool = c.isRaw;
		final openText: Null<String> = c.openText;
		final closeText: Null<String> = c.closeText;
		// Mirror of the trivia-path gate: knob-form leftCurly fires
		// even on a first-field Star (outer-side OptSpace owns the
		// inter-token space; see leftCurlySeparator's `_de()` branch).
		final hasKnobLeftCurly2: Bool = starNode.fmtReadString('leftCurly') != null;
		if ((!isFirstField || hasKnobLeftCurly2) && !isRaw && isSpacedLead(openText)) parts.push(leftCurlySeparator(starNode));
		parts.push(macro {
			final _arr = $fieldAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			var _si: Int = 0;
			while (_si < _arr.length) {
				_docs.push($elemCall);
				_si++;
			}
			blockBody($v{openText ?? '{'}, $v{closeText}, _docs, opt);
		});
	}

	/**
	 * Plain-mode try-parse / pad Star dispatch (the
	 * `else if (!isLastField || @:tryparse)` branch of `emitWriterStarField`).
	 * Handles the `@:fmt(sameLine)` block-shape separator path and the
	 * `padLeading` / `padTrailing` / `softFill` / `lineLengthAwareSeps` pad paths.
	 * Extracted to keep the orchestrator under the complexity gate.
	 * Plain-mode try-parse `@:fmt(sameLine)` block-shape separator path (the
	 * `sameLineName != null` branch of `emitTryparseOrPadStar`). Emits the
	 * per-element runtime-conditional separator with the block-ctor / bare-body
	 * shape switch. Extracted to keep the helper under the complexity gate.
	 */
	private function emitTryparseSameLineStar(c: PlainStarCtx, sameLineName: String, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final elemRefName: String = c.elemRefName;
		final prevBareRefBody: Null<PrevBodyInfo> = c.prevBareRefBody;
		// @:fmt(sameLine(...)) on a try-parse Star: each element is preceded by
		// a runtime-conditional separator (space or hardline), so the
		// first element's leading separator acts as the boundary with
		// the preceding struct field (τ₁ — catches against try body).
		// Per-element shape is not captured today, so `Keep` degrades
		// to `Same` at this site (ω-keep-policy).
		final optFlag: Expr = optFieldAccess(sameLineName);
		final sepExpr: Expr = sameLinePolicySwitch(optFlag, macro _dt(' '));
		// ω-block-shape-aware: when the Star carries
		// `@:fmt(blockBodyKeepsInline)` AND the prev struct field's
		// body has block ctors AND the element type carries a same-
		// typed body field, force `_dt(' ')` for any iteration whose
		// preceding body was a block ctor. Mirrors the trivia path;
		// the plain path's element access drops the `.node`
		// indirection.
		//
		// ω-statement-bare-break: dual flag `@:fmt(bareBodyBreaks)`
		// inverts the cases — block bodies fall through to `sepExpr`
		// (policy-driven), bare bodies force `_dhl()`. See trivia-
		// path comment for rationale.
		final blockShapeAware: Bool = starNode.fmtHasFlag('blockBodyKeepsInline');
		final bareShapeAware: Bool = starNode.fmtHasFlag('bareBodyBreaks');
		final shapeAware: Bool = blockShapeAware || bareShapeAware;
		final blockPatterns: Array<Expr> = prevBareRefBody != null && shapeAware
			? (
				bareShapeAware
					? collectBlockShapeEquivalentPatterns(prevBareRefBody.typePath)
					: collectBlockCtorPatterns(prevBareRefBody.typePath)
			)
			: [];
		final elemBodyField: Null<String> = blockPatterns.length > 0 ? findElementBodyField(elemRefName, prevBareRefBody.typePath) : null;
		if (blockPatterns.length == 0) {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				while (_si < _arr.length) {
					_docs.push($sepExpr);
					_docs.push($elemCall);
					_si++;
				}
				_dc(_docs);
			});
		} else {
			final blockKeepsInlineBranch: Expr = blockBodyKeepsInlineBranch(starNode);
			final firstBlockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
			final firstBareBranch: Expr = blockShapeAware ? sepExpr : (macro _dhl());
			final firstShapeCases: Array<Case> = [
				{ values: blockPatterns, expr: firstBlockBranch, guard: null },
				{ values: [macro _], expr: firstBareBranch, guard: null }
			];
			final firstSepShape: Expr = {
				expr: ESwitch(prevBareRefBody.access, firstShapeCases, null),
				pos: Context.currentPos()
			};
			final subsequentSepExpr: Expr = if (elemBodyField == null)
				sepExpr;
			else {
				final prevElemBodyAccess: Expr = {
					expr: EField(macro _arr[_si - 1], elemBodyField),
					pos: Context.currentPos()
				};
				final subBlockBranch: Expr = blockShapeAware ? blockKeepsInlineBranch : sepExpr;
				final subBareBranch: Expr = blockShapeAware ? sepExpr : (macro _dhl());
				final cases: Array<Case> = [
					{ values: blockPatterns, expr: subBlockBranch, guard: null },
					{ values: [macro _], expr: subBareBranch, guard: null }
				];
				{ expr: ESwitch(prevElemBodyAccess, cases, null), pos: Context.currentPos() };
			};
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				while (_si < _arr.length) {
					_docs.push(_si == 0 ? $firstSepShape : $subsequentSepExpr);
					_docs.push($elemCall);
					_si++;
				}
				_dc(_docs);
			});
		}
	}

	/**
	 * Plain-mode try-parse pad path (the `else` branch of
	 * `emitTryparseOrPadStar`). Handles `@:fmt(padLeading)` / `padTrailing` /
	 * `softFill` / `lineLengthAwareSeps` / `sepBeforeOpt` inter-element + edge
	 * spacing. Extracted to keep the helper under the complexity gate.
	 * Plain-mode try-parse pad emission (the `if (padLeading || padTrailing)`
	 * block of `emitTryparsePadStar`). Emits the lineLengthAware / sepBeforeOpt /
	 * softFill / plain inter-element + edge layouts per the resolved `PadFlags`.
	 * Extracted to keep the helper under the complexity gate.
	 * Plain-mode try-parse pad emission, non-lineLengthAware path (the inner
	 * `else` of `emitTryparsePadEmit`). Resolves the leading / trailing pad pushes
	 * (`sepBeforeOpt` aware) and emits the `softFill` or plain inter-element
	 * layout. Extracted to keep the helper under the complexity gate.
	 */
	private function emitTryparsePadSepEmit(
		c: PlainStarCtx, padLeading: Bool, padTrailing: Bool, sepBeforeOptActive: Bool, softFill: Bool, parts: Array<Expr>
	): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final leadingPush: Expr = if (sepBeforeOptActive) {
			final fieldName: String = starNode.annotations[AnnotationKeys.BASE_FIELD_NAME];
			final sepBeforeAccess: Expr = {
				expr: EField(macro value, fieldName + TriviaTypeSynth.SEP_BEFORE_SUFFIX),
				pos: Context.currentPos()
			};
			final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
			final sepLeadText: String = '${sepText ?? ','} ';
			macro _docs.push($sepBeforeAccess ? _dt($v{sepLeadText}) : _dt(' '));
		} else if (padLeading)
			macro _docs.push(_dt(' '));
		else
			macro {};
		final trailingPush: Expr = padTrailing ? macro _docs.push(_dt(' ')) : macro {};
		// ω-condcomp-body-inter-sep: the default inter-element
		// separator for this branch is `_dt(' ')` — designed for
		// sep-less Stars where elements pack with one space (e.g.
		// modifier runs). Sep-bearing Stars (e.g.
		// `HxConditionalParam.body` / `HxConditionalObjectField.body`
		// with `@:sep(',')`) emit their actual sep + space so multi-
		// element bodies round-trip the source comma. Falls back to
		// `' '` when sepText is absent.
		final sepTextForInter: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final interSepText: String = sepTextForInter != null ? '$sepTextForInter ' : ' ';
		if (softFill) {
			// ω-condcomp-body-softfill: route inter-element sep
			// through `Fill(items, Concat([Text(sep), Line(' ')]))`.
			// Flat mode renders the sep identically to the
			// pre-softFill `Text(interSepText)` path (`, ` for
			// sep-bearing Stars, ` ` for sep-less). Break mode
			// emits `sep` + newline+indent before each overflow
			// item — Fill picks per-item flat/break against the
			// current Renderer budget.
			final interSepLit: String = sepTextForInter ?? '';
			parts.push(macro {
				final _arr = $fieldAccess;
				if (_arr.length == 0)
					_de()
				else {
					final _docs: Array<anyparse.core.Doc> = [];
					$leadingPush;
					final _items: Array<anyparse.core.Doc> = [];
					var _si: Int = 0;
					while (_si < _arr.length) {
						_items.push($elemCall);
						_si++;
					}
					_docs.push(_dfill(_items, _dc([_dt($v{interSepLit}), _dl()])));
					$trailingPush;
					_dc(_docs);
				}
			});
		} else
			parts.push(macro {
				final _arr = $fieldAccess;
				if (_arr.length == 0)
					_de()
				else {
					final _docs: Array<anyparse.core.Doc> = [];
					$leadingPush;
					var _si: Int = 0;
					while (_si < _arr.length) {
						_docs.push($elemCall);
						if (_si < _arr.length - 1) _docs.push(_dt($v{interSepText}));
						_si++;
					}
					$trailingPush;
					_dc(_docs);
				}
			});
	}

	private function emitTryparsePadEmit(c: PlainStarCtx, f: PadFlags, parts: Array<Expr>): Void {
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final padLeading: Bool = f.padLeading;
		final padTrailing: Bool = f.padTrailing;
		final lineLengthAwareSeps: Bool = f.lineLengthAwareSeps;
		final sepBeforeOptActive: Bool = f.sepBeforeOptActive;
		final softFill: Bool = f.softFill;
		if (padLeading || padTrailing) {
			if (lineLengthAwareSeps) {
				final leadingPush: Expr = padLeading ? macro _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' '))) : macro {};
				final trailingPush: Expr = padTrailing ? macro _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' '))) : macro {};
				parts.push(macro {
					final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					final _arr = $fieldAccess;
					if (_arr.length == 0)
						_de()
					else {
						final _docs: Array<anyparse.core.Doc> = [];
						$leadingPush;
						var _si: Int = 0;
						while (_si < _arr.length) {
							_docs.push($elemCall);
							if (_si < _arr.length - 1) _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' ')));
							_si++;
						}
						$trailingPush;
						_dn(_cols, _dc(_docs));
					}
				});
			} else {
				emitTryparsePadSepEmit(c, padLeading, padTrailing, sepBeforeOptActive, softFill, parts);
			}
		} else {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					if (_si < _arr.length - 1) _docs.push(_dt(' '));
					_si++;
				}
				_dc(_docs);
			});
		}
	}

	private function emitTryparsePadStar(c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		// `@:fmt(padLeading)` / `@:fmt(padTrailing)` — when the Star
		// is bracketed by surrounding tokens emitted OUTSIDE this
		// struct (an outer enum ctor's kwLead / trailText, or a
		// sibling Ref before it) AND has no own `@:lead`/`@:trail`
		// to carry the space, the internal-only sep leaves
		// `prevTok<elem1 elem2>nextTok` glued together. Opting into
		// `padLeading` emits a leading space when the array is non-
		// empty (`prevTok elem1 elem2>nextTok`); `padTrailing` does
		// the same on the trailing side; combine for the symmetric
		// `prevTok elem1 elem2 nextTok` shape (used by
		// `HxConditionalMod.body` to fence between `#if cond`/`#end`).
		// Empty arrays still degrade to `_de()` (no padding, no
		// stray space). Format-neutral — any grammar nesting a
		// padded Star inside a surrounding-token sandwich can adopt
		// either flag without touching the macro.
		final padLeading: Bool = starNode.fmtHasFlag('padLeading');
		final padTrailing: Bool = starNode.fmtHasFlag('padTrailing');
		// ω-abstract-clauses-linewrap: when a bare-Star with padLeading
		// (and/or padTrailing) opts in via `@:fmt(lineLengthAwareSeps)`,
		// replace each hard padding/inter-element space with an
		// `IfLineExceeds(opt.lineWidth, _dhl(), _dt(' '))` probe and
		// wrap the body in `Nest(_cols, ...)` so break-mode hardlines
		// indent +1 from the enclosing decl. Mirrors fork's
		// `wrapAfter` + `CodeLine.applyWrapping` mechanism for
		// `abstract <T>(...) [from X]*` clauses (MarkWhitespace.hx:79
		// + codedata/CodeLine.hx:47). Single-clause and short-multi-
		// clause cases decide correctly without a multi-pass marker
		// because `IfLineExceeds`'s rest-of-stack walker sees the
		// trailing same-line content (members `{}` + close-trailing
		// comment). First consumer is `HxAbstractDecl.clauses`.
		final lineLengthAwareSeps: Bool = starNode.fmtHasFlag('lineLengthAwareSeps');
		// ω-condcomp-body-leading-sep: read the runtime
		// `<field>SepBefore:Bool` slot synthesised by
		// `TriviaTypeSynth.isSepBeforeOptStarField`. When true at
		// write time, prepend the sep literal to the leading pad
		// (`_dt(', ')` in place of `_dt(' ')`). Requires `padLeading`
		// — the leading pad is the only Doc slot in this branch that
		// fires adjacent to the enclosing kw (`#if cond`). Combining
		// with `lineLengthAwareSeps` is rejected at macro time (no
		// current consumer; the line-wrap probe would have to
		// swallow the comma into the breakable probe, which the
		// fork semantics for `#if cond, body` does NOT do).
		//
		// The slot lives on the trivia-paired typedef only (sister
		// gate in `Lowering.lowerStruct` skips the plain-mode
		// struct literal). Plain writer keeps the
		// `_dt(' ')` pad — no slot
		// to read.
		final sepBeforeOpt: Bool = starNode.fmtHasFlag('sepBeforeOpt');
		if (sepBeforeOpt && !padLeading)
			Context.fatalError('WriterLowering: @:fmt(sepBeforeOpt) requires @:fmt(padLeading)', Context.currentPos());
		if (sepBeforeOpt && lineLengthAwareSeps)
			Context.fatalError(
				'WriterLowering: @:fmt(sepBeforeOpt) is not compatible with @:fmt(lineLengthAwareSeps)', Context.currentPos()
			);
		final sepBeforeOptActive: Bool = sepBeforeOpt && _ctx.trivia;
		// ω-condcomp-body-softfill: plain-mode
		// `@:sep + @:tryparse` Star with `@:fmt(padLeading[, padTrailing])`
		// can opt into Wadler `Fill(items, sep)` inter-element layout via
		// `@:fmt(softFill)`. Items pack inline up to the current line
		// budget and break the sep before any overflow item at the
		// surrounding Nest's indent. Handles
		// `#if air, p1, p2, …, pN #end` inside an outer function-
		// signature Star whose source wraps the body across multiple
		// lines. The flat sep is `Concat([Text(sepText), Line(' ')])` —
		// flat=`,` + ` `, break=`,` + newline+indent. The current
		// outer-Group Nest from `wrapRules('functionSignatureWrap')`
		// supplies the break-mode indent (matches `#if`'s column in
		// every fork-corpus shape observed for cond-comp params).
		// Mutually exclusive with `lineLengthAwareSeps` — the latter
		// owns its own break primitive and the two would double-decide
		// the wrap.
		final softFill: Bool = starNode.fmtHasFlag('softFill');
		if (softFill && lineLengthAwareSeps)
			Context.fatalError('WriterLowering: @:fmt(softFill) is not compatible with @:fmt(lineLengthAwareSeps)', Context.currentPos());
		if (softFill && !(padLeading || padTrailing))
			Context.fatalError('WriterLowering: @:fmt(softFill) requires @:fmt(padLeading) or @:fmt(padTrailing)', Context.currentPos());
		final padFlags: PadFlags = {
			padLeading: padLeading,
			padTrailing: padTrailing,
			lineLengthAwareSeps: lineLengthAwareSeps,
			sepBeforeOptActive: sepBeforeOptActive,
			softFill: softFill
		};
		emitTryparsePadEmit(c, padFlags, parts);
	}

	/**
	 * Plain-mode try-parse / pad Star dispatch (the
	 * `else if (!isLastField || @:tryparse)` branch of `emitWriterStarField`).
	 * Emits the lead, then routes to the `@:fmt(sameLine)` block-shape path or the
	 * pad path. Extracted to keep the orchestrator under the complexity gate.
	 */
	private function emitTryparseOrPadStar(c: PlainStarCtx, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final openText: Null<String> = c.openText;
		// Try-parse mode. Emit lead if present (e.g. ':' in default:).
		if (openText != null) parts.push(macro _dt($v{openText}));
		final sameLineName: Null<String> = starNode.fmtReadString('sameLine');
		if (sameLineName != null) {
			emitTryparseSameLineStar(c, sameLineName, parts);
		} else {
			emitTryparsePadStar(c, parts);
		}
	}

	/**
	 * `@:trivia` Star dispatch (the whole `if (isTriviaStar)` block of
	 * `emitWriterStarField`). Validates the trivia sep/raw/tryparse combinations,
	 * builds the trailing-slot accessors + `TriviaStarCtx`, then routes to the
	 * tryparse / close / EOF trivia emit helper. Extracted to keep the orchestrator
	 * under the complexity gate.
	 * Builds the trailing-slot accessors + the `TriviaStarCtx` for a `@:trivia`
	 * Star, from the resolved `StarFieldArgs`.
	 */
	private function buildTriviaStarCtx(args: StarFieldArgs): TriviaStarCtx {
		final starNode: ShapeNode = args.starNode;
		final fieldAccess: Expr = args.fieldAccess;
		final elemFn: String = args.elemFn;
		final elemRefName: String = args.elemRefName;
		final isFirstField: Bool = args.isFirstField;
		final isLastField: Bool = args.isLastField;
		final typePath: String = args.typePath;
		final openText: Null<String> = args.openText;
		final closeText: Null<String> = args.closeText;
		final sepText: Null<String> = args.sepText;
		final prevBareRefBody: Null<PrevBodyInfo> = args.prevBareRefBody;
		final prevTrailFieldName: Null<String> = args.prevTrailFieldName;
		final fieldName: Null<String> = starNode.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final trailBBAccess: Null<Expr> = fieldName == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_BLANK_BEFORE_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-keep-fnsig-newline: accessor for the close-newline slot, threaded
		// into `triviaSepStarExpr` for the `_keepEmit` close placement.
		final trailNLAccess: Null<Expr> = fieldName == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_NEWLINE_BEFORE_SUFFIX),
			pos: Context.currentPos()
		};
		final trailLCAccess: Null<Expr> = fieldName == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX),
			pos: Context.currentPos()
		};
		final trailCloseAccess: Null<Expr> = fieldName == null || closeText == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_CLOSE_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-open-trailing: same-line `// comment` captured right after
		// the open literal. Synthesised only when the Star carries
		// `@:lead` AND not `@:tryparse` (parallel to TrailingClose's
		// `@:trail` gate; tryparse writer helper does not consume the
		// slot, and the synth gate omits it for tryparse Stars — see
		// `TriviaTypeSynth.buildStarTrailingSlots`).
		final trailOpenAccess: Null<Expr> = fieldName == null || openText == null || starNode.hasMeta(':tryparse') ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_OPEN_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-trail-blank-after: synth slot is only present on tryparse +
		// nestBody Stars. Forward null elsewhere so the slot access
		// doesn't reference a non-existent field.
		final trailBAAccess: Null<Expr> =
			fieldName == null || !starNode.hasMeta(':tryparse') || !starNode.fmtHasFlag('nestBody') ? null : {
				expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_BLANK_AFTER_SUFFIX),
				pos: Context.currentPos()
			};
		// ω-objectlit-source-trail-comma: synth slot is only present on
		// sep-Stars with a close literal. Forward null elsewhere so the
		// slot access doesn't reference a non-existent field. Mirrors
		// the `@:trail` / `@:sep` parser-side gate in TriviaTypeSynth.
		final trailPresentAccess: Null<Expr> = fieldName == null || sepText == null || closeText == null ? null : {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX),
			pos: Context.currentPos()
		};
		return {
			starNode: starNode,
			fieldAccess: fieldAccess,
			elemFn: elemFn,
			elemRefName: elemRefName,
			isFirstField: isFirstField,
			isLastField: isLastField,
			typePath: typePath,
			openText: openText,
			closeText: closeText,
			sepText: sepText,
			prevBareRefBody: prevBareRefBody,
			prevTrailFieldName: prevTrailFieldName,
			fieldName: fieldName,
			trailBBAccess: trailBBAccess,
			trailNLAccess: trailNLAccess,
			trailLCAccess: trailLCAccess,
			trailCloseAccess: trailCloseAccess,
			trailOpenAccess: trailOpenAccess,
			trailBAAccess: trailBAAccess,
			trailPresentAccess: trailPresentAccess
		};
	}

	/**
	 * `@:trivia` Star dispatch (the whole `if (isTriviaStar)` block of
	 * `emitWriterStarField`). Validates the trivia sep/raw/tryparse combinations,
	 * builds the `TriviaStarCtx` via `buildTriviaStarCtx`, then routes to the
	 * tryparse / close / EOF trivia emit helper. Extracted to keep the orchestrator
	 * under the complexity gate.
	 */
	private function emitTriviaStar(args: StarFieldArgs, parts: Array<Expr>): Void {
		final starNode: ShapeNode = args.starNode;
		final isLastField: Bool = args.isLastField;
		final isRaw: Bool = args.isRaw;
		final closeText: Null<String> = args.closeText;
		final sepText: Null<String> = args.sepText;
		if (isRaw) Context.fatalError('WriterLowering: @:trivia Star does not support @:raw', Context.currentPos());
		// ω-blockended-trivia-tryparse (Session 3): @:trivia + @:sep +
		// @:tryparse is now allowed when the `blockEnded` flag is
		// present (sole consumer: HxCaseBranch.body / HxDefaultBranch.stmts).
		// EOF mode (closeText == null, no @:tryparse) still rejects.
		final writerBlockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		// ω-sep-faithful: valid alternative to blockEnded — sep re-emission
		// keyed purely on the captured per-element `sepAfter`.
		final writerSepFaithful: Bool = starNode.annotations['lit.sepFaithful'] == true;
		if (sepText != null && closeText == null && !starNode.hasMeta(':tryparse'))
			Context.fatalError('WriterLowering: @:trivia + @:sep requires close-peek (@:trail) or @:tryparse', Context.currentPos());
		if (sepText != null && starNode.hasMeta(':tryparse') && !writerBlockEnded && !writerSepFaithful)
			Context.fatalError(
				'WriterLowering: @:trivia + @:sep + @:tryparse requires blockEnded flag (@:sep(text, tailRelax, blockEnded)) '
				+ 'or sepFaithful',
				Context.currentPos()
			);
		// ω-orphan-trivia / ω-close-trailing: Seq-struct call sites
		// drive the trailing slots synthesised on the paired type.
		// Alt-branch Star call sites (`HxStatement.BlockStmt`) have
		// no synth slots and pass null — writer falls back to pre-
		// slice behaviour. `TrailingClose` is only synthesised for
		// close-peek Stars (those with `lit.trailText`); EOF-mode
		// Stars forward null to preserve the post-loop emission
		// shape without a dangling slot access.
		final triviaCtx: TriviaStarCtx = buildTriviaStarCtx(args);
		if (starNode.hasMeta(':tryparse')) {
			emitTriviaTryparseStar(triviaCtx, parts);
			return;
		}
		if (closeText != null) {
			emitTriviaCloseStar(triviaCtx, parts);
		} else if (isLastField) {
			emitTriviaEofStar(triviaCtx, parts);
		} else {
			Context.fatalError('WriterLowering: @:trivia Star without @:trail must be the last field', Context.currentPos());
		}
	}

	private function emitWriterStarField(
		starNode: ShapeNode, fieldAccess: Expr, parts: Array<Expr>, isLastField: Bool, typePath: String, isFirstField: Bool, isRaw: Bool,
		?prevBareRefBody: PrevBodyInfo, ?prevTrailFieldName: String
	): Void {
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) Context.fatalError('WriterLowering: Star struct field must contain a Ref', Context.currentPos());

		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = writeFnFor(elemRefName);
		final openText: Null<String> = starNode.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final closeText: Null<String> = starNode.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final isTriviaStar: Bool = _ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		final args: StarFieldArgs = {
			starNode: starNode,
			fieldAccess: fieldAccess,
			elemFn: elemFn,
			elemRefName: elemRefName,
			isFirstField: isFirstField,
			isLastField: isLastField,
			isRaw: isRaw,
			typePath: typePath,
			openText: openText,
			closeText: closeText,
			sepText: sepText,
			prevBareRefBody: prevBareRefBody,
			prevTrailFieldName: prevTrailFieldName
		};

		// Trivia Star: the Array element type is Trivial<elemT>, and the
		// write call targets `_t.node` instead of the raw array element.
		// Leading/trailing comments and blank-line markers attach around
		// each element via the generated layout below. Sep / @:raw
		// combinations with @:trivia are rejected by the parser side
		// upstream — valid modes are block (close + no sep), EOF (no
		// close, last field), and try-parse (no close, last field,
		// `@:tryparse`).
		if (isTriviaStar) {
			emitTriviaStar(args, parts);
			return;
		}

		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro _arr[_si], macro opt]),
			pos: Context.currentPos()
		};
		final plainCtx: PlainStarCtx = {
			starNode: starNode,
			fieldAccess: fieldAccess,
			elemCall: elemCall,
			elemFn: elemFn,
			elemRefName: elemRefName,
			isFirstField: isFirstField,
			isLastField: isLastField,
			isRaw: isRaw,
			typePath: typePath,
			openText: openText,
			closeText: closeText,
			sepText: sepText,
			prevBareRefBody: prevBareRefBody
		};

		// @:raw types (string content): concatenate items with no whitespace,
		// wrapping in lead/trail if present. No block/sep layout.
		if (isRaw && closeText != null && sepText == null) {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [_dt($v{openText ?? ''})];
				var _si: Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					_si++;
				}
				_docs.push(_dt($v{closeText}));
				_dc(_docs);
			});
			return;
		}

		// Block-ended exemption (Session 2 pilot → Session 8 layout fix +
		// writer-side predicate consultation). When the Star carries
		// `@:sep(<text>, tailRelax, blockEnded[('<predicate>')])`,
		// between-element sep is suppressed when EITHER:
		//   (a) the prior element's rendered Doc ends with `}` OR `;`
		//       (per-stmt `@:trail/@:trailOpt(';')` baked terminator —
		//       `DocMeasure.endsWithStmtTerminator` one-walk check), OR
		//   (b) the blockEnded predicate (generated typed for astPreds
		//       formats, schema-instance for pilots) returns true on the
		//       prior element's AST (Session 7 option b2 — e.g.
		//       `HxStatement.Conditional(#if…#end)` ends `#end`
		//       byte-wise so (a) misses, but the predicate accepts the
		//       AST shape).
		// Mirrors the parser-side blockEnded branch in
		// `Lowering.emitStarFieldSteps`: byte-check `}`∪`;` (or-extended
		// `b == '}'.code || b == ';'.code || $predicateCall`). Predicate
		// is omitted iff `lit.sepBlockEndedPredicate` is absent — the
		// `false` fallback keeps the byte-check fast path untouched.
		//
		// Layout mirrors `blockBody` (WriterCodegen.hx:730-758): empty →
		// flat `open+close`; non-empty → `_dc([_dt(open), _dn(cols,
		// _dc([_dhl, item, [sep?]]*)), _dhl, _dt(close)])`. This replaces
		// the prior flat `_dc([open, item, _dt(' '), item, …, close])`
		// that had no multiline primitive — Session 7's HxFnBlock.stmts
		// smoke test regressed 35 unit tests because function bodies
		// collapsed to one line; the blockBody-shape layout restores
		// parity with the non-`@:sep` path at L3981.
		final blockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		if (closeText != null && sepText != null && blockEnded) {
			emitBlockEndedPlainStar(plainCtx, parts);
			return;
		}

		if (closeText != null && sepText != null) {
			emitSepStar(plainCtx, parts);
		} else if (closeText != null) {
			emitClosePlainStar(plainCtx, parts);
		} else if (!isLastField || starNode.hasMeta(':tryparse')) {
			emitTryparseOrPadStar(plainCtx, parts);
		} else {
			emitEofPlainStar(plainCtx, parts);
		}
	}

	// -------- terminal rule --------

	/**
	 * `@:writeNormalize('reindentBlock')` on a `@:rawString` terminal: emit the captured bytes as
	 * a run of LINES at the writer's own indent instead of one `_dt` whose embedded newlines
	 * splice the SOURCE indentation verbatim.
	 *
	 * A raw multi-line capture is byte-exact only while it stays where it was written. The one
	 * construct that needs it — a self-terminating `#if … ; #end` region that is the value of a
	 * `return` (`HxCondSpliceClosedRaw`) — MOVES: the writer glues the `#if` onto the `return`,
	 * which shifts every following line of the region one level left. Verbatim re-emission then
	 * leaves the body indented as if the `#if` were still on its own line, which is how admitting
	 * the shape turned the fork's `sameline/issue_54_return_sharp_multiple_passes` fixture from
	 * SKIP_PARSE into a round-trip FAIL.
	 *
	 * The transform keeps the first line verbatim (it follows the `#if` keyword on the same line)
	 * and re-emits each later line at the CURRENT indent plus its own indentation RELATIVE to the
	 * region: the longest common leading-whitespace prefix of those lines is the region's own base
	 * and is stripped, so `#elseif` / `#else` / `#end` land at the writer's indent and a branch
	 * body one deeper — exactly the fork's layout. Tab / space mixes are safe because the base is
	 * a common PREFIX, never a computed width. A blank line contributes no indentation evidence and
	 * is emitted empty, so it cannot leave trailing whitespace behind.
	 *
	 * A single-line capture is returned unchanged, which is every other site of this terminal.
	 */
	private function reindentBlockEmit(): Expr {
		return macro {
			final _s: String = (cast value: String);
			if (_s.indexOf('\n') < 0) return _dt(_s);
			final _lines: Array<String> = _s.split('\n');
			var _base: Null<String> = null;
			for (_li in 1..._lines.length) {
				final _line: String = _lines[_li];
				var _w: Int = 0;
				while (_w < _line.length && (_line.charCodeAt(_w) == ' '.code || _line.charCodeAt(_w) == '\t'.code)) _w++;
				if (_w == _line.length) continue;
				final _ws: String = _line.substr(0, _w);
				final _seen: Null<String> = _base;
				if (_seen == null)
					_base = _ws
				else {
					var _k: Int = 0;
					while (_k < _seen.length && _k < _ws.length && _seen.charCodeAt(_k) == _ws.charCodeAt(_k)) _k++;
					_base = _seen.substr(0, _k);
				}
			}
			final _prefix: String = _base == null ? '' : _base;
			final _docs: Array<anyparse.core.Doc> = [_dt(_lines[0])];
			for (_li in 1..._lines.length) {
				final _line: String = _lines[_li];
				_docs.push(_dhl());
				_docs.push(_dt(StringTools.startsWith(_line, _prefix) ? _line.substr(_prefix.length) : StringTools.ltrim(_line)));
			}
			return _dc(_docs);
		};
	}

	private function lowerTerminal(node: ShapeNode): Expr {
		final underlying: String = node.annotations['base.underlying'];
		final unescape: Bool = node.hasMeta(':unescape');
		final unescapeMode: Null<String> = node.readMetaString(':unescape');
		final raw: Bool = node.hasMeta(':rawString');

		if (unescape) {
			if (unescapeMode == 'raw' || unescapeMode == 'singleQuoteRaw') {
				// @:unescape("raw"):           escape without quote wrap,
				//                              using the format's `escapeChar`
				//                              (double-quote-aware table).
				// @:unescape("singleQuoteRaw"): same, but uses
				//                              `escapeSingleQuoteChar` —
				//                              the format's single-quote-
				//                              aware escape table (escapes
				//                              `'`, `$`, `\\` but leaves
				//                              `"` bare). Used by
				//                              `HxStringLitSegment` so that
				//                              literal `"` inside Haxe
				//                              `'...'` strings round-trips
				//                              bare instead of being
				//                              over-escaped to `\\"`.
				final fmtParts: Array<String> = _formatInfo.schemaTypePath.split('.');
				final escapeCall: Expr = unescapeMode == 'singleQuoteRaw'
					? macro $p{fmtParts}.instance.escapeSingleQuoteChar(_c)
					: macro $p{fmtParts}.instance.escapeChar(_c);
				return macro {
					final _s: String = (cast value: String);
					final _buf: StringBuf = new StringBuf();
					var _ci: Int = 0;
					while (_ci < _s.length) {
						final _c: Null<Int> = _s.charCodeAt(_ci);
						if (_c != null) _buf.add($e{escapeCall});
						_ci++;
					}
					return _dt(_buf.toString());
				};
			}
			// @:unescape (bare): wrap in "..." and escape
			return macro return _dt(escapeString(value));
		}

		if (!raw) return switch underlying {
			case 'Float': macro return _dt(formatFloat(value));
			case 'Int': macro return _dt('$value');
			case 'Bool': macro return _dt(value ? 'true' : 'false');
			case 'String': macro return _dt(value);
			case _:
				Context.fatalError('WriterLowering: no encoder for underlying type "$underlying"', Context.currentPos());
				throw 'unreachable';
		};
		// ω-numeric-normalize-suffix: `@:writeNormalize('<id>')`
		// on a `@:rawString` terminal wraps the emit through a built-in
		// normalisation transform before `_dt`. Currently one variant —
		// `'stripSuffixUnderscore'` — drops the optional underscore that
		// precedes a Haxe 5 typed numeric suffix (`_i32` → `i32`,
		// `_f64` → `f64`), matching haxe-formatter's canonicalisation
		// convention: source-form `12_0_i32` round-trips as `12_0i32`,
		// `1_2.3_4_f64` as `1_2.3_4f64`. Source-fidelity loss is the
		// trade — haxe-formatter normalises here.
		// Generic enough
		// for future numeric-shape canonicalisations; the registry is
		// the switch below, keep it small.
		final normalize: Null<String> = node.readMetaString(':writeNormalize');
		// omega-cond-directive-binop: the SECOND config-driven normalisation - unlike its
		// two siblings this one reads a knob (`opt.condDirectiveOpSpacing`), so its default
		// value is what keeps the terminal byte-identical rather than the absence of the meta.
		return switch (normalize) {
			case 'reindentBlock': reindentBlockEmit();
			case 'condOperatorSpacing': macro return _dt(
				anyparse.format.DirectiveCondition.spaceOperators((cast value: String), opt.condDirectiveOpSpacing)
			);
			case 'stripSuffixUnderscore': macro {
				var _s: String = (cast value: String);
				final _re = ~/_([iuf](?:8|16|32|64))$/;
				if (_re.match(_s)) _s = _s.substr(0, _re.matchedPos().pos) + _re.matched(1);
				return _dt(_s);
			};
			case _: macro return _dt(value);
		};
	}

	// -------- helpers --------

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
	private function sameLineSeparator(child: ShapeNode, prevBody: Null<PrevBodyInfo>, typePath: String, ?prevPadTrailing: Expr): Expr {
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
		final hasKeepSlot: Bool = _ctx.trivia && isTriviaBearing(typePath) && fieldName != null && child.kind == Ref
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
		final blockPatterns: Array<Expr> = collectBlockCtorPatterns(prevBody.typePath);
		if (blockPatterns.length == 0) return withPadTrailingDrop(prevPadTrailing, flagBased);
		final cases: Array<Case> = [
			{ values: blockPatterns, expr: flagBased, guard: null },
			{ values: [macro _], expr: macro _dhl(), guard: null }
		];
		final shapeAwareSwitch: Expr = { expr: ESwitch(prevBody.access, cases, null), pos: Context.currentPos() };
		return sameLineSeparatorShapeAware({
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
	private function beforeKwSeparator(
		useTriviaGap: Bool, fieldName: String, child: ShapeNode, prevBodyField: Null<PrevBodyInfo>, typePath: String,
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
		final sepBaseExpr: Expr = sameLineSeparator(child, prevBodyField, typePath, prevPadTrailing);
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
		return child.fmtHasFlag(ARROW_VALUE_IF_SITE) ? valueIfFitSeam(prevBodyField, sepExpr) : sepExpr;
	}

	/**
	 * The pre-`else` gap of an `arrowValueIfReflowSite`: a soft `Line(" ")` under either re-flow gate,
	 * so the chain has ONE break axis its enclosing `Group` decides. `_vifFit` is ignored when the
	 * PREVIOUS body is a block ctor -- see the call site; `_aifReflow` overrides in both arms, which
	 * is what keeps the arrow knob byte-identical.
	 */
	private function valueIfFitSeam(prevBody: Null<PrevBodyInfo>, sepExpr: Expr): Expr {
		final blockPatterns: Array<Expr> = prevBody == null ? [] : collectBlockCtorPatterns(prevBody.typePath);
		if (blockPatterns.length == 0) return macro (_aifReflow || _vifFit ? _dl() : $sepExpr);
		final cases: Array<Case> = [
			{ values: blockPatterns, expr: macro (_aifReflow ? _dl() : $sepExpr), guard: null },
			{ values: [macro _], expr: macro (_aifReflow || _vifFit ? _dl() : $sepExpr), guard: null }
		];
		return { expr: ESwitch(prevBody.access, cases, null), pos: Context.currentPos() };
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
	private function valueIfGapExpr(softGap: Bool, bodyRef: Expr): Expr {
		return softGap ? macro (_vifFit && anyparse.format.wrap.WrapList.flatLength($bodyRef) >= 0 ? _dl() : _dhl()) : macro _dhl();
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
	private function padTrailingDoc(parent: ShapeNode, child: ShapeNode, typePath: String): Expr {
		if (!_ctx.trivia || !isTriviaBearing(typePath)) return macro _dt(' ');
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
	 * ω-cond-comp-expr-multiline — walk the children of `parent`
	 * that follow `child`, collecting one `(guard, signal)` pair
	 * per downstream field whose presence is runtime-guarded AND
	 * whose leading-newline source-shape was captured by the
	 * trivia parser. Stops at the first mandatory non-transparent
	 * field — that field always emits visible content, so any
	 * further signal is irrelevant to `child`'s pad-emit site.
	 *
	 * Slot precedence (matches `TriviaTypeSynth`): a field that
	 * is BOTH `@:trivia` Star AND optional-kw routes through the
	 * opt-kw branch — `BeforeKwNewline` describes the kw-position
	 * newline (the boundary `child`'s pad is closing), while the
	 * Star's first-element `newlineBefore` describes a post-kw
	 * boundary one layer deeper.
	 *
	 * Optional fields (Ref or Star) without `@:kw` and without
	 * `@:trivia` carry no captured-newline slot — they're walked
	 * past as "transparent if absent" but contribute no entry; a
	 * downstream signal-bearing field still gets to win when the
	 * intervening transparent field is empty/absent at runtime.
	 */
	private function collectFollowingNewlineSignals(parent: ShapeNode, child: ShapeNode): Array<{ guard: Expr, signal: Expr }> {
		final out: Array<{ guard: Expr, signal: Expr }> = [];
		final startIdx: Int = parent.children.indexOf(child);
		if (startIdx < 0) return out;
		for (i in (startIdx + 1) ... parent.children.length) {
			final next: ShapeNode = parent.children[i];
			final nextFieldName: Null<String> = next.annotations[AnnotationKeys.BASE_FIELD_NAME];
			if (nextFieldName == null) continue;
			final nextAccess: Expr = { expr: EField(macro value, nextFieldName), pos: Context.currentPos() };
			final isOptional: Bool = next.annotations[AnnotationKeys.BASE_OPTIONAL] == true;
			final isOptKw: Bool = (next.kind == Ref || next.kind == Star) && isOptional && next.readMetaString(':kw') != null;
			if (isOptKw) {
				final slotAccess: Expr = {
					expr: EField(macro value, nextFieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX),
					pos: Context.currentPos()
				};
				out.push({ guard: macro $nextAccess != null, signal: slotAccess });
				continue;
			}
			final isTriviaStar: Bool = next.kind == Star && next.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
			if (isTriviaStar) {
				final firstNl: Expr = macro $nextAccess[0].newlineBefore;
				final guard: Expr = isOptional ? macro $nextAccess != null && $nextAccess.length > 0 : macro $nextAccess.length > 0;
				out.push({ guard: guard, signal: firstNl });
				continue;
			}
			// Non-signal field. Optional/transparent kinds without a
			// captured-newline slot fall through to the next iteration —
			// when absent at runtime they contribute no signal, when
			// present they emit visible content and the boundary is
			// theirs (a downstream signal would describe a different
			// boundary). Mandatory non-transparent fields stop the walk
			// outright.
			if (!isOptional && next.kind != Star) break;
		}
		// ω-cond-comp-expr-multiline (sub-slice 5): terminal-fallback
		// signal on `child` itself when opted in via
		// `@:fmt(captureSourceNewlineAfter)`. The signal describes the
		// newline AFTER `child`'s last token — used when every preceding
		// downstream signal is absent at runtime (Star empty + optional
		// Refs all null), i.e. when the boundary is `child → parent
		// trail-literal`. Always-on guard (`macro true`) — a runtime
		// ternary `g₀ ? s₀ : (g₁ ? s₁ : … (true ? s_n : false))`
		// folds to `(present ? signal : … : s_n)`, so this entry is
		// the chain's tail and only fires when no earlier guard
		// matched a present downstream field.
		final childFieldName: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		if (childFieldName != null && child.kind == Ref && child.fmtHasFlag('captureSourceNewlineAfter')) {
			final terminalSlot: Expr = {
				expr: EField(macro value, childFieldName + TriviaTypeSynth.NEWLINE_AFTER_SUFFIX),
				pos: Context.currentPos()
			};
			// Always-on guard. For an optional `child` the slot stores
			// whatever `collectTrivia` saw at the post-rewind position
			// when absent, which still describes the gap that `child`'s
			// pad-trailing emit site is closing.
			out.push({ guard: macro true, signal: terminalSlot });
		}
		return out;
	}

	/**
	 * ω-expression-try-body-break — build a runtime switch over
	 * `opt.<sameLineFlag>:SameLinePolicy` that wraps the body
	 * `writeCall` with an extra Nest level on the `Next` branch so the
	 * body content sits one indent deeper than the surrounding `try` /
	 * `catch (...)` keyword line. `Same` (and the default) emits the
	 * existing `' ' + body` shape; `Next` emits `_dn(_cols, _dc([_dhl(),
	 * body]))` — hardline + nested-indent + body, mirroring
	 * `bodyPolicyWrap`'s `Next` layout. `Keep` falls back to `Same`
	 * because no per-field source-shape slot exists at this site.
	 *
	 * Used by `@:fmt(bodyBreak('flagName'))` on a bare-Ref body field —
	 * `HxTryCatchExpr.body` (first field; Case 3 strips the `try` kw's
	 * trailing space so the wrap's `Same` ` ` is the sole separator) and
	 * `HxCatchClauseExpr.body` (last field; replaces the fixed
	 * `_dt(' ')` between `)` and the catch body).
	 *
	 * ω-block-shape-aware (block-body shape-awareness): when the field
	 * also carries `@:fmt(blockBodyKeepsInline)` AND the body's type has
	 * block ctors (collected via `collectBlockCtorPatterns`), an outer
	 * ctor switch suppresses the `opt.<flag>` body-break policy for those
	 * ctors — block bodies have their own visual structure (`{ ... }`),
	 * so a policy body-break would emit `try \n\t{ ... }` instead of the
	 * brace-paired layout. The block branch instead defers to
	 * `opt.blockLeftCurly` (ω-block-allman-leftcurly): `Same` cuddles the
	 * brace inline (`try { ... }`), `Next` (Allman, `lineEnds.leftCurly =
	 * "both"`) breaks it onto its own line at the statement base indent
	 * (`try\n{ ... }`). Non-block ctors still honour the policy switch.
	 * Opt-in via the flag because statement-form siblings
	 * (`HxTryCatchStmt.body` etc.) want the OPPOSITE — `} catch` breaks
	 * to `}\ncatch` on `Next` regardless of body shape (see
	 * `testSameLineCatchAppliesToEveryCatch` for the upstream
	 * haxe-formatter contract).
	 */
	private function bodyBreakWrap(flagName: String, writeCall: Expr, bodyAccess: Expr, bodyTypePath: String, shapeAware: Bool): Expr {
		final optFlag: Expr = optFieldAccess(flagName);
		final sameLayoutExpr: Expr = macro _dc([_dt(' '), $writeCall]);
		final nextLayoutExpr: Expr = macro _dn(_cols, _dc([_dhl(), $writeCall]));
		final flagSwitch: Expr = buildPolicySwitch(['anyparse', 'format', 'SameLinePolicy'], optFlag, [
			{ values: ['Next'], expr: nextLayoutExpr },
			{ values: ['Keep'], expr: sameLayoutExpr }
		], sameLayoutExpr);
		final blockPatterns: Array<Expr> = shapeAware ? collectBlockCtorPatterns(bodyTypePath) : [];
		// ω-block-allman-leftcurly: when the body's runtime ctor is a block,
		// the inline `' ' + body` layout cuddles the brace (`try { … }`). That
		// is correct under `blockLeftCurly = Same`, but Allman (`Next`,
		// `lineEnds.leftCurly = "both"`) wants the brace on its own line at the
		// statement's base indent (`try\n{ … }`). `BlockExpr`'s own
		// `@:fmt(leftCurly('blockLeftCurly'))` separator is owned by this body
		// field, not emitted by the writeCall, so the gate lives here. `_dhl()`
		// (plain hardline, current indent — no extra Nest) mirrors
		// `leftCurlySeparator`'s `Next` branch so the brace sits at the same
		// column as the keyword, matching haxe-formatter's expression-form
		// try-catch Allman layout.
		final blockLayoutExpr: Expr = {
			final brace: Expr = optFieldAccess('blockLeftCurly');
			final braceNextPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
			final allmanLayoutExpr: Expr = macro _dc([_dhl(), $writeCall]);
			final braceCases: Array<Case> = [{ values: [braceNextPat], expr: allmanLayoutExpr, guard: null }];
			{ expr: ESwitch(brace, braceCases, sameLayoutExpr), pos: Context.currentPos() };
		};
		final wrapExpr: Expr = if (blockPatterns.length == 0)
			flagSwitch
		else {
			final shapeCases: Array<Case> = [
				{ values: blockPatterns, expr: blockLayoutExpr, guard: null },
				{ values: [macro _], expr: flagSwitch, guard: null }
			];
			{ expr: ESwitch(bodyAccess, shapeCases, null), pos: Context.currentPos() };
		};
		// `_dn(_cols, …)` in the Next branch needs a per-call `_cols` binding —
		// mirrors `bodyPolicyWrap`'s tail block (line 1721) and the Star
		// `_dn(_cols, _dc(_docs))` site at line 2337.
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$wrapExpr;
		};
	}

	/**
	 * ω-statement-bare-break — wrap a bare-Ref body field with a runtime
	 * ctor switch that forces a multi-line break for non-block bodies and
	 * keeps the inline single-space layout for block bodies. No policy
	 * involvement: the layout is decided purely by the body's enum ctor.
	 *
	 * Block ctors (`collectBlockCtorPatterns(bodyTypePath)`) → `_dc([_dt(' '),
	 * body])` (inline space + body). Catch-all → `_dn(_cols, _dc([_dhl(),
	 * body]))` (hardline + nested-indent + body, mirroring `bodyBreakWrap`'s
	 * Next layout).
	 *
	 * Used by `@:fmt(bareBodyBreaks)` on a bare-Ref body field —
	 * `HxTryCatchStmt.body` (first field; Case 3 strips the `try` kw's
	 * trailing space so the wrap's inline `' '` is the sole separator) and
	 * `HxCatchClause.body` (last field; replaces the fixed `_dt(' ')`
	 * between `)` and the catch body). The semantic is the inverse of
	 * `blockBodyKeepsInline` on `bodyBreakWrap` — that flag forces inline
	 * for blocks regardless of an existing `Next` policy; this flag forces
	 * break for bare bodies with no policy at all. The two flags address
	 * the opposite haxe-formatter conventions for expression-position
	 * (`expressionTry=Next` rare; bare bodies stay inline) versus
	 * statement-position try-catch (default `sameLineCatch=Same`; bare
	 * bodies always break).
	 *
	 * If `bodyTypePath` has no block ctors the helper degrades to an
	 * unconditional `nextLayoutExpr` — a fallback that should never fire
	 * in practice (statement-form bodies are `HxStatement` which carries
	 * `BlockStmt`); kept defensive so the macro doesn't fatal-error on a
	 * future grammar that adds the flag without a block alternative.
	 */
	private function bareBodyBreakWrap(
		writeCall: Expr, bodyAccess: Expr, bodyTypePath: String, policyField: Null<String>, constructFitBody: Bool
	): Expr {
		final sameLayoutExpr: Expr = macro _dc([_dt(' '), $writeCall]);
		final breakLayoutExpr: Expr = macro _dn(_cols, _dc([_dhl(), $writeCall]));
		// omega-try-brace-symmetry: the hardline was unconditional, which is haxe-formatter's
		// statement-context convention and stays the default. A form that names a `BodyPolicy` knob
		// gains the FitLine escape: the bare body keeps the header line while the whole line fits and
		// takes the old break when it does not. Without that escape the de-brace direction is a
		// DOWNGRADE — `try f() catch (e) g();` would render across four lines — and worse, the
		// de-braced statement form re-parses as the bare one, so a second `fmt` pass would explode
		// what the first collapsed and `fmt` would stop being a fixed point.
		final nextLayoutExpr: Expr = if (policyField == null)
			breakLayoutExpr
		else {
			final policy: Expr = optFieldAccess(policyField);
			// Under `@:fmt(constructFitBody)` the escape is ONE soft line owned by the enclosing
			// construct group (see WrapBodyOpts.constructFitBody) — the body drops to its own indented
			// line with the same break the `catch` seam takes, instead of answering for its own line
			// and gluing to the head. Without the flag the width probe stays per-line.
			final fitEscape: Expr = constructFitBody
				? macro _dn(_cols, _dc([_dl(), $writeCall]))
				: macro _dfle(opt.lineWidth, $breakLayoutExpr, $sameLayoutExpr);
			macro $policy == anyparse.format.BodyPolicy.FitLine ? $fitEscape : $breakLayoutExpr;
		};
		final blockPatterns: Array<Expr> = collectBlockCtorPatterns(bodyTypePath);
		final wrapExpr: Expr = if (blockPatterns.length == 0)
			nextLayoutExpr
		else {
			final shapeCases: Array<Case> = [
				{ values: blockPatterns, expr: sameLayoutExpr, guard: null },
				{ values: [macro _], expr: nextLayoutExpr, guard: null }
			];
			{ expr: ESwitch(bodyAccess, shapeCases, null), pos: Context.currentPos() };
		};
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$wrapExpr;
		};
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
	private function indentValueIfCtorWrap(
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
	private function breakAfterLeadOnOverflowWrap(leadText: String, writeCall: Expr, typeFieldName: String): Expr {
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
	private function maybeIndentValueIfCtor(rawWriteCall: Expr, fieldAccess: Expr, child: ShapeNode): Expr {
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

	/**
	 * Find the branch of an Alt-rule whose first source-character is `{`.
	 * Used by the Ref-field leftCurly emission path to gate the runtime
	 * BracePlacement separator on the brace-bearing variant — sibling
	 * branches like `HxFnBody.NoBody` (`@:lit(';')`) leave the separator
	 * suppressed so `function f():Void;` round-trips without an inserted
	 * space.
	 *
	 * Two shapes are recognised:
	 *  - Direct: branch carries `@:lead('{')` itself (Case 4 Star ctor).
	 *  - Indirect via Seq typedef: branch is Case 3 single-Ref wrapping a
	 *    Seq whose first field's `@:lead` opens with `{` (e.g.
	 *    `BlockBody(block:HxFnBlock)` where `HxFnBlock.stmts` carries the
	 *    `@:lead('{')`).
	 *
	 * Returns the ctor's simple name (`'BlockBody'`) or `null` when the
	 * rule is not an Alt or no branch surfaces a `{` lead.
	 */
	private function leftCurlyTargetCtors(refName: String): Array<String> {
		final result: Array<String> = [];
		final node: Null<ShapeNode> = _shape.rules[refName];
		if (node == null || node.kind != Alt) return result;
		for (branch in node.children) {
			final ctor: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctor == null) continue;
			final lead: Null<String> = branch.annotations.get(AnnotationKeys.LIT_LEAD_TEXT);
			if (lead != null && lead == '{') {
				result.push(ctor);
				continue;
			}
			if (branch.children.length != 1 || branch.children[0].kind != Ref) continue;
			final innerName: Null<String> = branch.children[0].annotations.get(AnnotationKeys.BASE_REF);
			final innerNode: Null<ShapeNode> = innerName == null ? null : _shape.rules[innerName];
			if (innerNode == null || innerNode.kind != Seq || innerNode.children.length <= 0) continue;
			final firstField: ShapeNode = innerNode.children[0];
			final firstLead: Null<String> = firstField.annotations[AnnotationKeys.LIT_LEAD_TEXT] ?? firstField.readMetaString(':lead');
			if (firstLead != null && firstLead.charAt(0) == '{') result.push(ctor);
		}
		return result;
	}

	/**
	 * List Alt branches of `refName` whose writer output begins with a
	 * sub-rule write (no `@:lit`, no `@:lead`, no `@:kw` lead, and not the
	 * brace-bearing branch already handled by `leftCurlyTargetCtor`).
	 *
	 * Such branches need an inserted ` ` separator at the parent Ref-field
	 * site so the kw of the surrounding rule doesn't butt up against the
	 * sub-rule's first token. The parser's Case 3 (single-Ref, optional
	 * `@:trail`) already inserts `skipWs` before the sub-call; the writer
	 * must produce the symmetric output.
	 *
	 * First consumer: `HxFnBody.ExprBody(expr:HxExpr) @:trail(';')` —
	 * `function foo() trace("hi");`. The space sits between `()` and the
	 * expression. `BlockBody`'s ` `/`\n\t` is owned by `leftCurlySeparator`;
	 * `NoBody`'s `;` wants no preceding space (suppressed via `_de()` in
	 * the runtime switch's default branch).
	 */
	private function spacePrefixCtors(refName: String, lcCtorNames: Array<String>): Array<String> {
		final ctors: Array<String> = [];
		final node: Null<ShapeNode> = _shape.rules[refName];
		if (node == null || node.kind != Alt) return ctors;
		for (branch in node.children) {
			final ctor: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctor == null || lcCtorNames.indexOf(ctor) != -1) continue;
			if (branch.annotations.get(AnnotationKeys.LIT_LIT_LIST) != null) continue;
			if (branch.annotations.get(AnnotationKeys.LIT_LEAD_TEXT) != null) continue;
			if (branch.annotations.get(AnnotationKeys.KW_LEAD_TEXT) != null) continue;
			if (branch.annotations.get(AnnotationKeys.PREFIX_OP) != null) continue;
			if (branch.annotations.get(AnnotationKeys.POSTFIX_OP) != null) continue;
			if (branch.annotations.get(AnnotationKeys.PRATT_PREC) != null) continue;
			if (branch.annotations.get(AnnotationKeys.TERNARY_OP) != null) continue;
			if (branch.children.length != 1 || branch.children[0].kind != Ref) continue;
			ctors.push(ctor);
		}
		return ctors;
	}

	/**
	 * Return `true` when the named ctor of `refName`'s Alt enum carries a
	 * ctor-level `@:fmt(bodyPolicy(<flag>))`. Consumed by the Case 5
	 * (Ref + `@:fmt(leftCurly)`) emission site to suppress the parent's
	 * fixed `_dt(' ')` separator for sibling ctors whose own writer
	 * (Case 3 path) wraps the body in `bodyPolicyWrap` and supplies the
	 * kw→body separator runtime-switchably.
	 *
	 * First consumer: `HxFnBody.ExprBody`'s `@:fmt(bodyPolicy('functionBody'))`
	 * (ω-functionBody-policy).
	 */
	private function ctorHasBodyPolicy(refName: String, ctorName: String): Bool {
		final node: Null<ShapeNode> = _shape.rules[refName];
		if (node == null || node.kind != Alt) return false;
		for (branch in node.children) if (branch.annotations.get(AnnotationKeys.BASE_CTOR) == ctorName)
			return branch.fmtReadStringArgs('bodyPolicy') != null;
		return false;
	}

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
	private function bodyPolicyWrap(opts: WrapBodyOpts): Expr {
		final writeCall: Expr = buildBodyWriteCall(opts);
		final optFlag: Expr = resolveBodyOptFlag(opts);
		final hasKwSlots: Bool = opts.afterKwExpr != null && opts.kwLeadingExpr != null;
		final kwSep: { kwPolicyInlineSep: Null<Expr>, sameSepNb: Expr } = buildBodyKwSep(opts, hasKwSlots);
		final shared: BodyWrapShared = {
			writeCall: writeCall,
			sameSepNb: kwSep.sameSepNb,
			kwPolicyInlineSep: kwSep.kwPolicyInlineSep,
			hasKwSlots: hasKwSlots
		};
		final sameLayoutExpr: Expr = buildBodySameLayout(opts, shared);
		final nextLayoutExpr: Expr = buildBodyNextLayout(opts, shared);
		final blockLayoutExpr: Expr = buildBodyBlockLayout(opts, shared);
		final fitExpr: Expr = buildBodyFitExpr(opts, shared);
		final layouts: BodyLayouts = {
			sameLayoutExpr: sameLayoutExpr,
			nextLayoutExpr: nextLayoutExpr,
			blockLayoutExpr: blockLayoutExpr,
			fitExpr: fitExpr,
			elseIfSameLayoutExpr: buildElseIfCommentReflowLayout(opts, shared, sameLayoutExpr)
		};
		final blockSplit: { tagged: Array<Expr>, untagged: Array<Expr> } = collectBlockCtorPatternsByLeftCurly(opts.bodyTypePath);
		final ifStmtPattern: Null<Expr> = opts.hasElseIf
			? (findCtorPattern(opts.bodyTypePath, 'IfStmt') ?? findCtorPattern(opts.bodyTypePath, 'IfExpr'))
			: null;
		final keepLayoutExpr: Expr = buildBodyKeepLayout(opts, layouts, blockSplit, ifStmtPattern);
		final coreWrapExpr: Expr = buildBodyCoreWrap(opts, optFlag, layouts, keepLayoutExpr, blockSplit, ifStmtPattern);
		final wrapExpr: Expr = wrapBodyAfterTrail(opts, coreWrapExpr, writeCall, blockSplit);
		final finalWrapExpr: Expr = wrapBodyAllman(opts, wrapExpr, writeCall);
		final mbgWrapExpr: Expr = wrapBodyMetaBlockGlue(opts, finalWrapExpr, sameLayoutExpr);
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$mbgWrapExpr;
		};
	}

	/**
	 * Walk `bodyTypePath`'s rule (expected to be an `Alt`) and collect
	 * `case` patterns for branches that render via `blockBody` — i.e.
	 * enum ctors declared with `@:lead(open) @:trail(close)` on a single
	 * `Star` child. Returns an empty array when `bodyTypePath` is not an
	 * enum, has no such branches, or is absent from the shape map.
	 */
	private function collectBlockCtorPatterns(bodyTypePath: String): Array<Expr> {
		final rule: Null<ShapeNode> = _shape.rules[bodyTypePath];
		return rule == null || rule.kind != Alt ? [] : [
			for (branch in rule.children) if (isBlockCtorBranch(branch)) branchCtorPattern(bodyTypePath, branch)
		];
	}

	private function collectBlockShapeEquivalentPatterns(bodyTypePath: String): Array<Expr> {
		final rule: Null<ShapeNode> = _shape.rules[bodyTypePath];
		return rule == null || rule.kind != Alt ? [] : [
			for (branch in rule.children) if (isBlockShapeEquivalentBranch(branch)) branchCtorPattern(bodyTypePath, branch)
		];
	}

	/**
	 * ω-block-shape-aware — find the field name of the bare-Ref child on
	 * `elemTypePath`'s Seq rule whose Ref points at `bodyTypePath`. Used by
	 * the Star sameLine handler to wire shape-awareness on subsequent
	 * iterations: each catch element after the first checks the previous
	 * element's body shape (`_arr[_si - 1].<field>`) against the prev
	 * body's block ctors. Returns `null` when the element is not a Seq,
	 * has no matching Ref child, or the matching child is not a bare Ref
	 * (Star / optional fields are skipped — they don't carry the body
	 * directly).
	 */
	private function findElementBodyField(elemTypePath: String, bodyTypePath: String): Null<String> {
		final rule: Null<ShapeNode> = _shape.rules[elemTypePath];
		if (rule == null || rule.kind != Seq) return null;
		for (child in rule.children) if (child.kind == Ref && child.annotations.get(AnnotationKeys.BASE_OPTIONAL) != true) {
			final ref: Null<String> = child.annotations.get(AnnotationKeys.BASE_REF);
			if (ref == bodyTypePath) return child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
		}
		return null;
	}

	/**
	 * ω-close-trailing-alt — runtime override for a Star's first-element
	 * separator when the immediately preceding struct field was a bare
	 * Ref to a trivia-bearing type. Iterates the prev body's Alt branches
	 * looking for close-trailing branches (Star + `@:trail` + `@:trivia`)
	 * — currently only `HxStatement.BlockStmt`. For each, emits a case
	 * `BlockStmt(_, _ct)` with guard `_ct != null` mapping to `_de()`
	 * (the body's writer already terminated with `\n`, so any sep would
	 * leak ` ` between the indent and the next sibling). The default
	 * case falls through to `sepExpr`. Returns `null` when no override
	 * is needed (no prev body, non-bearing target, or no close-trailing
	 * branches in the Alt) so the caller skips the override path.
	 */
	private function buildCloseTrailingFirstSepOverride(prevBareRefBody: Null<PrevBodyInfo>, sepExpr: Expr): Null<Expr> {
		if (prevBareRefBody == null) return null;
		final rule: Null<ShapeNode> = _shape.rules[prevBareRefBody.typePath];
		if (rule == null || rule.kind != Alt) return null;
		final cases: Array<Case> = [];
		for (branch in rule.children) if (TriviaTypeSynth.isAltCloseTrailingBranch(branch)) {
			final ctorName: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			final ctorPath: Array<String> = ruleCtorPath(prevBareRefBody.typePath, ctorName);
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
			// Pattern arity: child shape (1 Star) + the closeTrailing slot
			// (which we BIND as `_ct`) + any further synth extras
			// (currently only openTrailing for `:lead` branches; trailOpt /
			// captureSource predicates are disjoint from the close-trailing
			// shape, but the helper covers them for forward compatibility).
			final extras: Int = branchSynthExtraArity(prevBareRefBody.typePath, branch);
			final patternArgs: Array<Expr> = [macro _, macro _ct];
			for (_ in 0...extras - 1) patternArgs.push(macro _);
			final pattern: Expr = {
				expr: ECall(ctorRef, patternArgs),
				pos: Context.currentPos()
			};
			cases.push({ values: [pattern], guard: macro _ct != null, expr: macro _de() });
		}
		if (cases.length == 0) return null;
		cases.push({ values: [macro _], guard: null, expr: sepExpr });
		return { expr: ESwitch(prevBareRefBody.access, cases, null), pos: Context.currentPos() };
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
	private function collectBlockCtorPatternsByLeftCurly(bodyTypePath: String): { tagged: Array<Expr>, untagged: Array<Expr> } {
		final rule: Null<ShapeNode> = _shape.rules[bodyTypePath];
		if (rule == null || rule.kind != Alt) return { tagged: [], untagged: [] };
		final tagged: Array<Expr> = [];
		final untagged: Array<Expr> = [];
		for (branch in rule.children) if (isCurlyBlockCtorBranch(branch)) {
			final pattern: Expr = branchCtorPattern(bodyTypePath, branch);
			if (branch.fmtHasFlag('leftCurly'))
				tagged.push(pattern);
			else
				untagged.push(pattern);
		}
		return { tagged: tagged, untagged: untagged };
	}

	private function branchCtorPattern(bodyTypePath: String, branch: ShapeNode): Expr {
		final ctorName: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final arity: Int = branch.children.length + branchSynthExtraArity(bodyTypePath, branch);
		final ctorPath: Array<String> = ruleCtorPath(bodyTypePath, ctorName);
		final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
		return if (arity == 0)
			ctorRef
		else {
			final args: Array<Expr> = [for (_ in 0...arity) macro _];
			{ expr: ECall(ctorRef, args), pos: Context.currentPos() };
		};
	}

	/**
	 * Synth-pair Alt branches grow positional args beyond `children.length`
	 * in trivia mode (closeTrailing, openTrailing, trailPresent, sourceText).
	 * Wildcard patterns must include matching `_` slots for each, otherwise
	 * arity mismatches the synth ctor at compile time. Returns 0 when the
	 * body is not trivia-bearing or the branch shape adds no extra args.
	 */
	private function branchSynthExtraArity(bodyTypePath: String, branch: ShapeNode): Int {
		if (!isTriviaBearing(bodyTypePath)) return 0;
		var extras: Int = 0;
		if (TriviaTypeSynth.isAltCloseTrailingBranch(branch)) {
			extras++;
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) extras++;
		}
		if (TriviaTypeSynth.isAltTrailOptBranch(branch)) extras++;
		if (TriviaTypeSynth.isCaptureSourceBranch(branch)) extras++;
		return extras;
	}

	/**
	 * ω-region-prefix-blank — the runtime test behind
	 * `@:fmt(keepBlankAfterStarCtor(starField, ctorName))`: the named sibling
	 * Star's LAST element is `ctorName`, AND every Star declared between it and
	 * this field is empty. The second half is what keeps the rule honest — with a
	 * non-empty `modifiers` run in between, the blank the source held sits after
	 * the MODIFIERS, and a blank there is collapsed like any other.
	 *
	 * The gate exists because the fork's two answers for this gap disagree: the
	 * blank after an ordinary metadata prefix is DELETED
	 * (`emptylines/issue_384_macro_classes_with_metadata`), while a `#if … #end`
	 * region is its own entity and keeps a blank on its far side
	 * (`emptylines/after_vars_before_conditionals` moves one there). The parser
	 * folds a member-prefix region into the metadata Star, so only the ctor tells
	 * the two apart. Null when the field did not opt in — every existing field.
	 */
	private function buildKeepBlankAfterCtorGate(child: ShapeNode, node: ShapeNode, typePath: String): Null<Expr> {
		final args: Null<Array<String>> = child.fmtReadStringArgs('keepBlankAfterStarCtor');
		if (args == null) return null;
		if (args.length != 2)
			Context.fatalError(
				'WriterLowering: @:fmt(keepBlankAfterStarCtor) expects 2 string args (starField, ctorName), got ${args.length}',
				Context.currentPos()
			);
		final starField: String = args[0];
		final ctorName: String = args[1];
		final pos: Position = Context.currentPos();
		var starChild: Null<ShapeNode> = null;
		final betweenStars: Array<String> = [];
		for (c in node.children) {
			if (c == child) break;
			final fn: Null<String> = c.annotations[AnnotationKeys.BASE_FIELD_NAME];
			if (fn == starField) {
				starChild = c;
				continue;
			}
			if (starChild != null && c.kind == Star) betweenStars.push(fn);
		}
		if (starChild == null || starChild.kind != Star || starChild.children.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(keepBlankAfterStarCtor) needs "$starField" to be a Star field declared BEFORE "'
				+ '${child.annotations[AnnotationKeys.BASE_FIELD_NAME]}" of $typePath',
				Context.currentPos()
			);
		final elemRefName: String = starChild.children[0].annotations[AnnotationKeys.BASE_REF];
		final pattern: Null<Expr> = findCtorPattern(elemRefName, ctorName);
		if (pattern == null)
			Context.fatalError(
				'WriterLowering: @:fmt(keepBlankAfterStarCtor) ctor "$ctorName" not found in enum $elemRefName', Context.currentPos()
			);
		final starAccess: Expr = { expr: EField(macro value, starField), pos: pos };
		final lastElem: Expr = _ctx.trivia && isTriviaBearing(typePath)
			? macro $starAccess[$starAccess.length - 1].node
			: macro $starAccess[$starAccess.length - 1];
		var gate: Expr = macro $starAccess.length > 0 && $lastElem.match($pattern);
		for (fn in betweenStars) {
			final acc: Expr = { expr: EField(macro value, fn), pos: pos };
			gate = macro $gate && $acc.length == 0;
		}
		return gate;
	}

	/**
	 * Build a wildcard `case` pattern for the named ctor of a polymorphic
	 * enum type. Returns `null` when the type is not an enum in the shape
	 * map or has no branch with the requested name — the caller then
	 * skips the ctor-specific override.
	 *
	 * Used by the ψ₈ `@:fmt(elseIf)` path to target the `IfStmt(_)` ctor of
	 * `HxStatement` when rendering the `else` body of `HxIfStmt`.
	 */
	private function findCtorPattern(bodyTypePath: String, ctorName: String): Null<Expr> {
		final rule: Null<ShapeNode> = _shape.rules[bodyTypePath];
		if (rule == null || rule.kind != Alt) return null;
		for (branch in rule.children) {
			final branchCtor: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (branchCtor != ctorName) continue;
			final arity: Int = branch.children.length + branchSynthExtraArity(bodyTypePath, branch);
			final ctorPath: Array<String> = ruleCtorPath(bodyTypePath, branchCtor);
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
			return if (arity == 0)
				ctorRef
			else {
				final args: Array<Expr> = [for (_ in 0...arity) macro _];
				{ expr: ECall(ctorRef, args), pos: Context.currentPos() };
			};
		}
		return null;
	}

	/**
	 * True when the given lead-open string is declared by the format as
	 * taking a preceding space (e.g. Haxe's `{` block-opens). All other
	 * open-delimiters (`(`, `[`, etc.) stay tight against the preceding
	 * token. Evaluated at macro time against `formatInfo.spacedLeads`.
	 */
	private function isSpacedLead(openText: Null<String>): Bool {
		return openText != null && _formatInfo.spacedLeads.indexOf(openText) != -1;
	}

	/**
	 * True when the given optional `@:lead(...)` text is declared by the
	 * format as tight — no leading separator before it, no trailing
	 * space after it. Used by the optional-Ref code path so Haxe's
	 * `:Type` annotation stays compact instead of being wrapped in
	 * spaces like keyword leads (`else`, `catch`).
	 */
	private function isTightLead(leadText: Null<String>): Bool {
		return leadText != null && _formatInfo.tightLeads.indexOf(leadText) != -1;
	}

	/**
	 * The first child field of the Seq (struct) rule named `refName`, or null
	 * when `refName` is not a Seq rule or the Seq has no fields. Shared prologue
	 * of the `subStructStartsWith*` predicates.
	 */
	private function firstFieldOfSubSeq(refName: String): Null<ShapeNode> {
		final subNode: Null<ShapeNode> = _shape.rules[refName];
		if (subNode == null || subNode.kind != Seq) return null;
		final children: Array<ShapeNode> = subNode.children;
		return children.length == 0 ? null : children[0];
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
	private function subStructStartsWithBodyPolicy(refName: String): Bool {
		final first: Null<ShapeNode> = firstFieldOfSubSeq(refName);
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
	private function subStructStartsWithBodyBreak(refName: String): Bool {
		final first: Null<ShapeNode> = firstFieldOfSubSeq(refName);
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
	private function subStructStartsWithBareBodyBreaks(refName: String): Bool {
		final first: Null<ShapeNode> = firstFieldOfSubSeq(refName);
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
	private function subStructStartsWithTightLead(refName: String): Bool {
		final first: Null<ShapeNode> = firstFieldOfSubSeq(refName);
		return first != null && isTightLead(first.readMetaString(':lead'));
	}

	// -------- trivia-mode helpers (ω₅) --------

	/**
	 * True when `ctx.trivia` is active AND the rule at `refName` carries
	 * `trivia.bearing=true`. The rule-lookup guard returns false for
	 * non-grammar refs (format primitives the Writer still expects to
	 * call through their plain `writeXxx` functions).
	 */
	private function isTriviaBearing(refName: String): Bool {
		if (!_ctx.trivia) return false;
		final node: Null<ShapeNode> = _shape.rules[refName];
		return node != null && node.annotations.get(AnnotationKeys.TRIVIA_BEARING) == true;
	}

	/** `write<name>T` when trivia-bearing, else `write<name>` — every ref fn-name site goes through this. */
	private function writeFnFor(refName: String): String {
		final simple: String = simpleName(refName);
		return isTriviaBearing(refName) ? 'write${simple}T' : 'write$simple';
	}

	/** Paired `*T` ComplexType in the synth module for bearing rules; plain TPath otherwise. */
	private function ruleValueCT(refName: String): ComplexType {
		final simple: String = simpleName(refName);
		return isTriviaBearing(refName)
			? TPath({
				pack: packOf(refName).concat(['trivia']),
				name: 'Pairs',
				sub: '${simple}T',
				params: []
			})
			: TPath({ pack: packOf(refName), name: simple, params: [] });
	}

	/** Enum-constructor field-path segments for `toFieldExpr` — routes through the synth module for bearing enums. */
	private function ruleCtorPath(typePath: String, ctor: String): Array<String> {
		final simple: String = simpleName(typePath);
		return isTriviaBearing(typePath)
			? packOf(typePath).concat(['trivia', 'Pairs', '${simple}T', ctor])
			: packOf(typePath).concat([simple, ctor]);
	}

	/**
	 * ω-interblank — resolve the `@:fmt(interMemberBlankLines(fieldName,
	 * varCtor, fnCtor))` meta into the classify-switch shape that
	 * `triviaBlockStarExpr` splices into its per-element loop.
	 *
	 * Inspects the element Seq rule's named field to locate the
	 * classifier enum rule, then builds one `case <Ctor>(_):` pattern
	 * per variant in that enum, mapping the configured `varCtor` name to
	 * kind `1`, `fnCtor` to kind `2`, and every other variant to kind
	 * `0`. Iterating every variant (instead of emitting a wildcard
	 * default) keeps the switch exhaustive without relying on Haxe's
	 * unused-pattern warnings for the single-grammar two-variant case.
	 *
	 * ω-interblank-cond-lookthrough — when `condArgs` is non-null (the
	 * Star also carried `@:fmt(interMemberCondLookThrough('<classifier
	 * Field>', '<condCtor>', '<bodyField>'))`), the `<condCtor>` variant's
	 * top-level case classifies the member by its FIRST inner member's
	 * kind, read from a nested switch on
	 * `_inner.<bodyField>[0].node.<classifierField>` (the body Star is
	 * trivia-collected, so its elements carry the `.node` raw accessor).
	 * An empty body falls back to `0`.
	 *
	 * The look-through is FUNCTION-ONLY: only a `fnCtor` inner member maps
	 * to kind `2`; var-family inner members (and a nested `<condCtor>`)
	 * map to `0`. This is the byte-safe subset of the fork's
	 * `markClassFieldEmptyLines`, which pairs the REAL inner fields across
	 * the `#if … #end` boundary with full static-ness / visibility
	 * arbitration and doc-comment-policy override. anyparse classifies a
	 * whole conditional MEMBER as one outer-loop unit, so a var-bearing
	 * conditional cannot reproduce that field-vs-field arbitration and
	 * over-fires the static-var subdivision cascade (`afterStaticVars`) and
	 * the `none`-doc-comment strip. Functions carry no member-scope
	 * subdivision and surfaced no doc-comment-strip conflict in the corpus,
	 * so two consecutive function-bearing conditional members get a
	 * `betweenFunctions` blank and nothing else changes. (See the inner-case
	 * builder comment for the regression detail.)
	 */
	private function buildInterMemberClassifyInfo(
		elemRefName: String, args: Array<String>, ?condArgs: Array<String>
	): InterMemberClassifyInfo {
		if (args.length != 3 && args.length != 6)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) expects 3 or 6 string args (classifierField, varCtor, fnCtor ['
				+ ', betweenVarsField, betweenFunctionsField, afterVarsField]), got ${args.length}',
				Context.currentPos()
			);
		final fieldName: String = args[0];
		// The var-ctor arg accepts a `|`-separated set so grammars whose
		// element enum splits the "var" family across multiple ctors (Haxe:
		// `VarMember` for `var x`, `FinalMember` for `final x` / `static
		// final x`) classify every member of that family as kind 1. Mirrors
		// the fork's `FieldUtils.getFieldType`, which folds `Kwd(KwdFinal)`
		// into the same `Var(...)` field kind as `Kwd(KwdVar)`.
		final varCtors: Array<String> = args[1].split('|');
		// The fn-ctor arg also accepts a `|`-separated set, symmetric with the
		// var-ctor set, so a grammar whose "function" family spans multiple
		// ctors (Haxe: `FnMember` for `function f()`, `FinalModifiedMember` for
		// the `final`-modifier form `final static function f()`) classifies
		// every member of that family as kind 2. Mirrors the fork's
		// `FieldUtils.getFieldType`, which classifies a `final`-modified
		// `function` as the same `Function(...)` kind as a plain `function`.
		final fnCtors: Array<String> = args[2].split('|');
		final betweenVarsField: String = args.length == 6 ? args[3] : 'betweenVars';
		final betweenFunctionsField: String = args.length == 6 ? args[4] : 'betweenFunctions';
		final afterVarsField: String = args.length == 6 ? args[5] : 'afterVars';
		// ω-interblank-cond-lookthrough: validate + unpack the optional
		// look-through config. The classifier field must match
		// `interMemberBlankLines`'s — both switches read the same enum.
		final condArgsResolved: Null<Array<String>> = condArgs != null && condArgs.length > 0 ? condArgs : null;
		if (condArgsResolved != null) {
			if (condArgsResolved.length != 3)
				Context.fatalError(
					'WriterLowering: @:fmt(interMemberCondLookThrough) expects exactly 3 string args ('
					+ 'classifierField, condCtor, bodyField), got ${condArgsResolved.length}',
					Context.currentPos()
				);
			if (condArgsResolved[0] != fieldName)
				Context.fatalError(
					'WriterLowering: @:fmt(interMemberCondLookThrough) classifierField "${condArgsResolved[0]}'
					+ '" must match interMemberBlankLines classifierField "$fieldName"',
					Context.currentPos()
				);
		}
		final condCtor: Null<String> = condArgsResolved != null ? condArgsResolved[1] : null;
		final bodyField: Null<String> = condArgsResolved != null ? condArgsResolved[2] : null;
		final enumRule: ShapeNode = resolveInterMemberEnumRule(elemRefName, fieldName);
		final cases: Array<Case> = buildInterMemberClassifyCases({
			enumRule: enumRule,
			varCtors: varCtors,
			fnCtors: fnCtors,
			condCtor: condCtor,
			bodyField: bodyField,
			fieldName: fieldName
		});
		return {
			classifierFieldName: fieldName,
			classifyCases: cases,
			betweenVarsField: betweenVarsField,
			betweenFunctionsField: betweenFunctionsField,
			afterVarsField: afterVarsField
		};
	}

	/**
	 * ω-cond-leading-doc-lookthrough — resolve
	 * `@:fmt(beforeDocCondLookThrough('<classifierField>', '<condCtor>',
	 * '<bodyField>'))` into the case pattern + body field name that
	 * `triviaBlockStarExpr` uses to look through a `#if … #end` member to
	 * its first inner member's leading doc-comment.
	 *
	 * Inspects the element Seq rule's named classifier field to locate the
	 * member-dispatch enum, verifies the named `<condCtor>` variant exists
	 * with exactly one arg (the conditional-body wrapper), and builds the
	 * `case <condCtor>(_inner):` pattern. `<bodyField>` is taken on trust as
	 * a Star field on that wrapper — its `[0].leadingComments` shape matches
	 * every trivia-collected Star element, so no per-shape validation beyond
	 * the ctor existence is needed.
	 */
	private function buildCondLeadingDocLookThroughInfo(elemRefName: String, args: Array<String>): CondLeadingDocLookThroughInfo {
		if (args.length != 3)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) expects exactly 3 string args (classifierField, condCtor, bodyField), got '
				+ args.length,
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final condCtor: String = args[1];
		final bodyField: String = args[2];
		final elemRule: Null<ShapeNode> = _shape.rules[elemRefName];
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) requires element rule $elemRefName to be a Seq struct',
				Context.currentPos()
			);
		final classifierNode: Null<ShapeNode> = elemRule.children.find(child ->
			child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == fieldName
		);
		if (classifierNode == null || classifierNode.kind != Ref)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) classifier field "$fieldName" must be a plain Ref to an enum rule on '
				+ elemRefName,
				Context.currentPos()
			);
		final enumRuleName: Null<String> = classifierNode.annotations.get(AnnotationKeys.BASE_REF);
		final enumRule: Null<ShapeNode> = enumRuleName == null ? null : _shape.rules[enumRuleName];
		if (enumRule == null || enumRule.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) classifier target for "$fieldName" must be an Alt (enum)',
				Context.currentPos()
			);
		final condBranch: Null<ShapeNode> = enumRule.children.find(branch -> branch.annotations.get(AnnotationKeys.BASE_CTOR) == condCtor);
		if (condBranch == null)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) condCtor "$condCtor" not found on enum $enumRuleName',
				Context.currentPos()
			);
		if (condBranch.children.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(beforeDocCondLookThrough) condCtor "$condCtor'
				+ '" must take exactly one arg (the conditional-body wrapper), got ${condBranch.children.length}',
				Context.currentPos()
			);
		final pos: Position = Context.currentPos();
		final condCasePattern: Expr = {
			expr: ECall({ expr: EConst(CIdent(condCtor)), pos: pos }, [macro _inner]),
			pos: pos
		};
		return {
			classifierFieldName: fieldName,
			condCasePattern: condCasePattern,
			bodyFieldName: bodyField
		};
	}

	/**
	 * ω-class-static-var-cascade — resolve `@:fmt(staticVarSubdivision)` /
	 * `@:fmt(staticVarSubdivision('<modifierField>', '<staticCtor>',
	 * '<afterStaticVarsField>' [, '<betweenStaticFunctionsField>']))` into
	 * the data the per-iteration kind switch reads to promote kind `1`
	 * (instance var) to kind `3` (static var) and kind `2` (function) to
	 * kind `4` (static function). The zero-arg form defaults to the
	 * `('modifiers', 'Static', 'afterStaticVars', 'betweenStaticFunctions')`
	 * quadruple — matches the canonical `HxMemberDecl.modifiers` Star +
	 * `HxMemberModifier.Static` ctor + the matching `HxModuleWriteOptions`
	 * knobs.
	 *
	 * ω-abstract-static-fn-cascade — the optional 4th arg names the
	 * `betweenStaticFunctions` opt knob consulted at a (4,4) static-fn pair.
	 *
	 * The companion meta is read alongside `@:fmt(interMemberBlankLines)`;
	 * `@:fmt(staticVarSubdivision)` without `interMemberBlankLines` is
	 * inert (the cascade arms are written by `triviaBlockStarExpr` and
	 * gated on the interMember presence). Validates that the named
	 * modifier field exists on the element Seq rule and that it's a Star.
	 */
	private function buildStaticVarSubdivisionInfo(elemRefName: String, args: Array<String>): StaticVarSubdivisionInfo {
		if (args.length != 0 && args.length != 3 && args.length != 4)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) expects 0, 3 or 4 string args ('
				+ 'modifierField, staticCtor, afterStaticVarsField [, betweenStaticFunctionsField]), got ${args.length}',
				Context.currentPos()
			);
		final modifierField: String = args.length >= 3 ? args[0] : 'modifiers';
		final staticCtor: String = args.length >= 3 ? args[1] : 'Static';
		final afterStaticVarsField: String = args.length >= 3 ? args[2] : 'afterStaticVars';
		final betweenStaticFunctionsField: String = args.length == 4 ? args[3] : 'betweenStaticFunctions';
		validateStaticVarSubdivision(elemRefName, modifierField, staticCtor);
		return {
			modifierFieldName: modifierField,
			staticCtorName: staticCtor,
			afterStaticVarsField: afterStaticVarsField,
			betweenStaticFunctionsField: betweenStaticFunctionsField
		};
	}

	/**
	 * ω-bug-2c-inner-star — read every cascade `@:fmt(blankLines*)` meta
	 * off a `@:trivia` Star ShapeNode and resolve them into the four
	 * info arrays consumed by `buildCascadeEmit`. Centralises the meta-read + transparent-merge + cross-validation block shared by the EOF-Star branch of `lowerStruct` and the inner-Star branch (`triviaTryparseStarExpr` consumers).
	 *
	 * Recognised metas:
	 *  - `blankLinesAfterCtor` / `blankLinesAfterCtorIf`
	 *  - `blankLinesBeforeCtor` / `blankLinesBeforeCtorIf`
	 *  - `blankLinesBetweenSameCtorByLevel`
	 *  - `blankLinesBetweenSameCtorTailTransparent`
	 *  - `blankLinesBetweenSameCtorHeadTransparent`
	 *  - `blankLinesBetweenSameCtorIfNot`
	 *  - `blankLinesOnTransitionAcross`
	 *
	 * Tail/head transparent metas are merged per-classifier-field into a
	 * shared adapter pair, fed to BOTH the between-ctor and transition
	 * cascades (single shared head/tail walker per Star+classifier). Any
	 * transparent meta whose classifier has no matching between/transition
	 * meta is rejected at compile time as dead code.
	 */
	private function readCascadeInfosFromStar(starNode: ShapeNode, elemRefName: String, ?measuredMultilineExpr: Expr): CascadeInfos {
		// ω-leading-trivia-multiline — `@:fmt(multilineWhenLeadingTriviaSpansLines(
		// '<metaField>', '<declField>'))` on the Star builds a per-element
		// `_t`-scoped boolean OR-ed into the `'multiline'` predicate of every
		// predicate-gated blank rule below (afterMultilineDecl /
		// beforeMultilineDecl / betweenSingleLineTypes). The element is treated
		// as multi-line when its leading-trivia slot holds a comment (covers a
		// leading doc-comment before an otherwise single-line decl) OR the named
		// meta Star is non-empty AND the source broke before the dispatch
		// keyword (`<declField>BeforeNewline` synth slot — meta-on-own-line).
		// The inter-decl blank SEPARATOR (`_t.blankBefore` / `_t.newlineBefore`)
		// is deliberately NOT consulted — a pure-blank leading gap is still
		// single-line, mirroring fork `getTypeInfo`'s `findLowestIndex` span
		// which counts only the type's own leading comment + leading meta.
		// Absent flag → null → byte-identical to pre-slice.
		final triviaMultilineExpr: Null<Expr> = buildTriviaMultilineExpr(starNode);
		// ω-measured-multiline-decl — `@:fmt(measuredMultilineDecls)` on the Star
		// opts the two `multiline`-predicated blank rules (afterMultilineDecl /
		// beforeMultilineDecl) into the RENDERED channel: a per-element boolean
		// read out of `_measMulti`, the array `TriviaEofLowering` fills once per
		// module from each element's built Doc. Deliberately NOT threaded into
		// `blankLinesBetweenSameCtorIfNot` for the same reason the trivia flag is
		// not — that rule OWNS the pair blank when `betweenSingleLineTypes > 0`,
		// and flipping an element to not-single-line there would SUPPRESS the
		// user-configured count rather than replace it with `betweenTypes`.
		// Absent flag → null → byte-identical to pre-slice.
		//
		// The accessor is the CALLER's to supply, because only the EOF-mode Star
		// declares `_measMulti`. This function has two callers — the EOF branch
		// and the inner-Star (`@:tryparse`) branch — and reading the flag here
		// would let the inner one emit a reference to an identifier its own
		// scaffold never declares, failing as `Unknown identifier _measMulti`
		// inside generated code with nothing naming the flag. The guard below
		// turns that into the diagnostic it should be.
		if (starNode.fmtHasFlag('measuredMultilineDecls') && measuredMultilineExpr == null)
			Context.fatalError(
				'WriterLowering: @:fmt(measuredMultilineDecls) is supported only on an EOF-mode @:trivia Star (the one that declares '
				+ '`_measMulti`); this Star is lowered through another path',
				Context.currentPos()
			);
		final afterCtorAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAfterCtor');
		final afterCtorInfos: Array<AfterCtorBlankInfo> = [
			for (args in afterCtorAllArgs) buildAfterCtorBlankInfo(elemRefName, args, null)
		];
		// NB: the trivia-multiline override is intentionally NOT threaded into
		// `blankLinesAfterCtorIf` (afterMultilineDecl). Fork `betweenTypes`
		// inserts the blank in the gap BEFORE a leading-comment / meta-on-own-
		// line type (its multi-line span is its LEADING layout), so only the
		// before-side and the inverted between-single-line-types rule consume
		// it. Firing it on the AFTER side too would insert a spurious blank
		// after a doc-commented type whose successor is single-line and whose
		// source gap the writer otherwise tightens
		// (lineends/issue_216_typedef_without_semicolon_unstable_comments).
		final afterCtorIfAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAfterCtorIf');
		for (args in afterCtorIfAllArgs) afterCtorInfos.push(buildAfterCtorBlankInfoIf(elemRefName, args, measuredMultilineExpr));
		// ω-after-conditional-block — tail-leaf-gated after-ctor override.
		final afterCtorIfTailNullAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAfterCtorIfTailLeafNull');
		for (args in afterCtorIfTailNullAllArgs) afterCtorInfos.push(buildAfterCtorBlankInfoIfTailLeafNull(elemRefName, args));
		final beforeCtorAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBeforeCtor');
		final beforeCtorInfos: Array<BeforeCtorBlankInfo> = [
			for (args in beforeCtorAllArgs) buildBeforeCtorBlankInfo(elemRefName, args, null)
		];
		final beforeCtorIfAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBeforeCtorIf');
		for (args in beforeCtorIfAllArgs) beforeCtorInfos.push(buildBeforeCtorBlankInfoIf(elemRefName, args));
		final beforeCtorIfPrevNotAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBeforeCtorIfPrevNot');
		for (args in beforeCtorIfPrevNotAllArgs)
			beforeCtorInfos.push(buildBeforeCtorBlankInfoIfPrevNot(elemRefName, args, triviaMultilineExpr, measuredMultilineExpr));
		final betweenCtorAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorByLevel');
		final tailTransparentAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorTailTransparent');
		final headTransparentAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorHeadTransparent');
		final transparentByClassifier: Map<String, TransparentEntry> = [];
		for (args in tailTransparentAllArgs)
			ingestTransparentArg(transparentByClassifier, args, true, 'blankLinesBetweenSameCtorTailTransparent');
		for (args in headTransparentAllArgs)
			ingestTransparentArg(transparentByClassifier, args, false, 'blankLinesBetweenSameCtorHeadTransparent');
		final transitionAcrossAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesOnTransitionAcross');
		final ctorBlankInfos: {
			between: Array<BetweenCtorBlankInfo>,
			transition: Array<TransitionAcrossInfo>
		} = buildCtorBlankInfos(elemRefName, betweenCtorAllArgs, transitionAcrossAllArgs, transparentByClassifier);
		final headCtorAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAtHeadIfCtor');
		final headCtorInfos: Array<HeadCtorBlankInfo> = [
			for (args in headCtorAllArgs) buildHeadCtorBlankInfo(elemRefName, args)
		];
		// NB: the trivia-multiline override is intentionally NOT threaded into
		// `blankLinesBetweenSameCtorIfNot` (betweenSingleLineTypes, inverted).
		// That rule's blank between two single-line type pairs is OWNED by it
		// when `opt > 0`; flipping a leading-comment / meta-on-own-line type to
		// NOT-single-line there would SUPPRESS the user-configured
		// `betweenSingleLineTypes` blank (the fork still emits a blank for the
		// pair, just via `betweenTypes` instead). The before-side rule, which
		// sits one priority step BELOW it in the cascade, supplies the
		// multi-line blank when `betweenSingleLineTypes` falls through (opt 0),
		// so both fork paths are covered without double-counting
		// (lineends/issue_216_…_empty_lines: betweenSingleLineTypes=1 keeps the
		// blank around the doc-commented type pair).
		final betweenSameCtorIfNotAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorIfNot');
		final betweenSameCtorIfNotInfos: Array<BetweenSameCtorIfNotInfo> = [
			for (args in betweenSameCtorIfNotAllArgs) buildBetweenSameCtorBlankInfoIfNot(elemRefName, args)
		];
		return {
			afterCtorInfos: afterCtorInfos,
			beforeCtorInfos: beforeCtorInfos,
			betweenCtorInfos: ctorBlankInfos.between,
			transitionAcrossInfos: ctorBlankInfos.transition,
			headCtorInfos: headCtorInfos,
			betweenSameCtorIfNotInfos: betweenSameCtorIfNotInfos
		};
	}

	/**
	 * ω-before-package — resolve
	 * `@:fmt(blankLinesAtHeadIfCtor(classifierField, CtorName1,
	 * [CtorName2, …], optField))` into a `HeadCtorBlankInfo`. Same
	 * single-axis classify-switch shape as `buildAfterCtorBlankInfo`
	 * (1 if matched, 0 otherwise) — semantic divergence is at the cascade
	 * splice point: head-of-Star override fires once on `_arr[0].node`,
	 * not per-iteration. Reuses `resolveCtorBlankArgs` for arity
	 * validation, classifier-enum resolution, and synth-arity-aware case
	 * pattern emission.
	 */
	private function buildHeadCtorBlankInfo(elemRefName: String, args: Array<String>): HeadCtorBlankInfo {
		final r: CtorBlankResolution = resolveCtorBlankArgs(elemRefName, args, 'blankLinesAtHeadIfCtor', null);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField
		};
	}

	/**
	 * ω-after-package — resolve `@:fmt(blankLinesAfterCtor(classifierField,
	 * CtorName1, [CtorName2, …], optField))` into a binary classify-switch
	 * (`1` for any matching ctor, `0` otherwise) plus the option-field
	 * name read at runtime to pick the forced-minimum blank-line count.
	 *
	 * Mirrors `buildInterMemberClassifyInfo` but with arity ≥ 3
	 * (classifierField, ≥ 1 ctor name, optField) and a single-axis
	 * yes/no classification instead of var/fn/other. Reusable for any
	 * "blank line after ctor X" slice — the args list defines which
	 * ctors trigger and which `HxModuleWriteOptions` Int field is
	 * consulted.
	 */
	private function buildAfterCtorBlankInfo(elemRefName: String, args: Array<String>, predicateAdapter: Null<String>): AfterCtorBlankInfo {
		final r: CtorBlankResolution = resolveCtorBlankArgs(elemRefName, args, 'blankLinesAfterCtor', predicateAdapter);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField
		};
	}

	/**
	 * ω-after-multiline — predicate-gated variant of
	 * `buildAfterCtorBlankInfo`. Args shape: `(classifierField,
	 * predicateAdapter, CtorName1, …, optField)`. The runtime kind-=1
	 * path runs `opt.<predicateAdapter>(_t.node)` after the ctor match
	 * succeeds; kind stays `0` when the adapter returns false (or when
	 * the adapter field on `opt` is null). Lets a single ctor set fire
	 * a blank-line override only on shape-relevant elements (e.g.
	 * "blank line around any multi-line type decl") instead of bare
	 * ctor name (which would force the blank around empty-body decls
	 * too, e.g. `class C<T> {}`).
	 */
	private function buildAfterCtorBlankInfoIf(elemRefName: String, args: Array<String>, ?measuredMultilineExpr: Expr): AfterCtorBlankInfo {
		if (args.length < 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesAfterCtorIf) expects ≥ 4 string args (classifierField, predicateAdapter, CtorName1, ['
				+ 'CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final reduced: Array<String> = [args[0]].concat(args.slice(2));
		final r: CtorBlankResolution = resolveCtorBlankArgs(
			elemRefName, reduced, 'blankLinesAfterCtorIf', args[1], false, null, measuredMultilineExpr
		);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField
		};
	}

	/**
	 * ω-after-conditional-block — resolve
	 * `@:fmt(blankLinesAfterCtorIfTailLeafNull(classifierField, CtorName,
	 * tailAdapterField, optField))` (arity exactly 4). Like
	 * `blankLinesAfterCtor` it forces `opt.<optField>` blank lines after a
	 * previous element matching `CtorName`, but the override is gated at
	 * runtime on the previous element's tail-leaf classify (run via the
	 * named `WriteOptions` adapter on the matched ctor's first positional
	 * arg, bound as `_v0`) returning null — i.e. the wrapper's tail leaf is
	 * NOT one of the adapter's recognised ctors. The single matched case
	 * binds `_v0`; every other ctor stays kind `0` with the plain wildcard
	 * pattern. Used to mirror fork's module-level `#if … #end → type`
	 * boundary: a conditional whose tail is an import / using keeps the
	 * source blank (adapter returns non-null → override suppressed → source-
	 * driven count), every other tail (error, metadata, expression)
	 * collapses to `opt.afterConditionalBlock` (=0). Only one ctor name is
	 * accepted — the tail-leaf gate is meaningful only for a transparent
	 * wrapper ctor (`Conditional`).
	 */
	private function buildAfterCtorBlankInfoIfTailLeafNull(elemRefName: String, args: Array<String>): AfterCtorBlankInfo {
		if (args.length != 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesAfterCtorIfTailLeafNull) expects exactly 4 string args ('
				+ 'classifierField, CtorName, tailAdapterField, optField), got ${args.length}',
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final ctorName: String = args[1];
		final tailAdapterField: String = args[2];
		final optField: String = args[3];
		final r: { enumRule: ShapeNode, enumRuleName: String } = resolveClassifierEnum(
			elemRefName, fieldName, 'blankLinesAfterCtorIfTailLeafNull'
		);
		final enumRule: ShapeNode = r.enumRule;
		final enumRuleName: String = r.enumRuleName;
		final pos: Position = Context.currentPos();
		final cases: Array<Case> = [];
		var matched: Bool = false;
		for (branch in enumRule.children) {
			final branchCtor: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (branchCtor == null) continue;
			final arity: Int = branch.children.length + branchSynthExtraArity(enumRuleName, branch);
			final ctorIdent: Expr = { expr: EConst(CIdent(branchCtor)), pos: pos };
			final isMatch: Bool = branchCtor == ctorName;
			if (isMatch) {
				matched = true;
				if (arity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesAfterCtorIfTailLeafNull) ctor "$ctorName" must have arity ≥ 1 ('
						+ 'first arg is the wrapper payload bound to _v0 and passed to the tail-leaf classifier adapter); got arity $arity',
						Context.currentPos()
					);
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				final pattern: Expr = { expr: ECall(ctorIdent, binders), pos: pos };
				cases.push({ values: [pattern], guard: null, expr: macro 1 });
			} else {
				final pattern: Expr = arity == 0 ? ctorIdent : {
					expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]),
					pos: pos
				};
				cases.push({ values: [pattern], guard: null, expr: macro 0 });
			}
		}
		// ω-orphan-prefix-decl: the null arm, kind `0` — see
		// `resolveCtorBlankArgs`. `emitAfterCompute` rewrites every non-`1` case
		// into the zero body, so this arm needs no shape of its own.
		cases.push({ values: [macro null], guard: null, expr: macro 0 });
		if (!matched)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesAfterCtorIfTailLeafNull) ctor "$ctorName" not found in enum $enumRuleName',
				Context.currentPos()
			);
		return {
			classifierFieldName: fieldName,
			classifyCases: cases,
			optField: optField,
			tailAdapterOptField: tailAdapterField
		};
	}

	/**
	 * ω-imports-using-blank — resolve `@:fmt(blankLinesBeforeCtor(classifierField,
	 * CtorName1, [CtorName2, …], optField))` — symmetric mirror of
	 * `buildAfterCtorBlankInfo`. Same arity (≥ 3 string args), same
	 * single-axis yes/no classification on the named ctors. The runtime
	 * gate (in `triviaEofStarExpr`) fires when the CURRENT element matches
	 * AND the previous element did NOT match the same set, driving
	 * "blank line before first X group" semantics (e.g. `import → using`
	 * transition) independently of the after-ctor knob.
	 */
	private function buildBeforeCtorBlankInfo(
		elemRefName: String, args: Array<String>, predicateAdapter: Null<String>
	): BeforeCtorBlankInfo {
		final r: CtorBlankResolution = resolveCtorBlankArgs(elemRefName, args, 'blankLinesBeforeCtor', predicateAdapter);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
			prevExcludeCases: null
		};
	}

	/**
	 * Predicate-gated variant of `buildBeforeCtorBlankInfo`. Same arg
	 * shape and adapter semantics as `buildAfterCtorBlankInfoIf` — the
	 * runtime gate at consumption keeps the existing "curr matches AND
	 * prev did NOT match" semantics, so the predicate-gated kind feeds
	 * both sides of the comparison. A single decl pair is governed by
	 * at most one override, and the cascade still picks after-ctor
	 * entries before before-ctor entries.
	 */
	private function buildBeforeCtorBlankInfoIf(elemRefName: String, args: Array<String>): BeforeCtorBlankInfo {
		if (args.length < 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBeforeCtorIf) expects ≥ 4 string args (classifierField, predicateAdapter, CtorName1, ['
				+ 'CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final reduced: Array<String> = [args[0]].concat(args.slice(2));
		final r: CtorBlankResolution = resolveCtorBlankArgs(elemRefName, reduced, 'blankLinesBeforeCtorIf', args[1]);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
			prevExcludeCases: null
		};
	}

	/**
	 * ω-before-multiline-prev-not — predicate-gated `blankLinesBeforeCtor`
	 * variant that ALSO suppresses the override when the previous sibling
	 * matched an excluded ctor. Args shape:
	 * `(classifierField, predicateName, TargetCtor1, …, '|', ExcludeCtor1,
	 * …, optField)`. The `'|'` separator splits the target set (left) from
	 * the excluded-prev set (right). The target side resolves exactly like
	 * `buildBeforeCtorBlankInfoIf` (predicate-gated kind tracker); the
	 * excluded side builds a second binary classify-switch on the SAME
	 * classifier field (kind=1 for any excluded ctor) stored in
	 * `prevExcludeCases`. The cascade consumer (`buildCascadeEmit`) adds a
	 * `&& _prevKindPrevExcl != 1` guard so the override falls through to the
	 * source-driven blank count when the prev sibling was excluded.
	 *
	 * Drives the "do not force a blank before a multiline type decl when
	 * the preceding sibling is a cond-comp `#if … #end` with no source
	 * blank" rule (issue_298): `Conditional`-prev → respect source.
	 */
	private function buildBeforeCtorBlankInfoIfPrevNot(
		elemRefName: String, args: Array<String>, ?triviaMultilineExpr: Expr, ?measuredMultilineExpr: Expr
	): BeforeCtorBlankInfo {
		final sepIdx: Int = args.indexOf('|');
		if (args.length < 5 || sepIdx < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBeforeCtorIfPrevNot) expects ≥ 5 string args (classifierField, predicateName, '
				+ 'TargetCtor1, …, "|", ExcludeCtor1, …, optField) with a "|" separator, got ${args.length}',
				Context.currentPos()
			);
		final classifier: String = args[0];
		final predicateName: String = args[1];
		final optField: String = args[args.length - 1];
		final targetCtors: Array<String> = args.slice(2, sepIdx);
		final excludeCtors: Array<String> = args.slice(sepIdx + 1, args.length - 1);
		if (targetCtors.length == 0 || excludeCtors.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBeforeCtorIfPrevNot) requires ≥ 1 target ctor before "|" and ≥ 1 excluded ctor after it',
				Context.currentPos()
			);
		// Target side: predicate-gated kind tracker, same resolution as
		// `buildBeforeCtorBlankInfoIf` (classifier + ctors + optField, with
		// the predicate name threaded in).
		final targetArgs: Array<String> = [classifier].concat(targetCtors).concat([optField]);
		final target: CtorBlankResolution = resolveCtorBlankArgs(
			elemRefName, targetArgs, 'blankLinesBeforeCtorIfPrevNot', predicateName, false, triviaMultilineExpr, measuredMultilineExpr
		);
		// Excluded side: bare binary classify-switch on the same classifier
		// field — no predicate, kind=1 for any excluded ctor. `optField` is
		// reused only to satisfy the resolver arity; its result is discarded.
		final excludeArgs: Array<String> = [classifier].concat(excludeCtors).concat([optField]);
		final exclude: CtorBlankResolution = resolveCtorBlankArgs(elemRefName, excludeArgs, 'blankLinesBeforeCtorIfPrevNot', null);
		return {
			classifierFieldName: target.fieldName,
			classifyCases: target.cases,
			optField: target.optField,
			prevExcludeCases: exclude.cases
		};
	}

	/**
	 * ω-between-single-line-types — resolve
	 * `@:fmt(blankLinesBetweenSameCtorIfNot(classifierField,
	 * predicateName, CtorName1, [CtorName2, …], optField))` into a
	 * `BetweenSameCtorIfNotInfo`. Same arg shape as
	 * `blankLinesAfterCtorIf` (≥ 4 string args, predicate name at args[1])
	 * but the resolver runs with `predicateInvert=true`, so the kind
	 * tracker fires `1` when the ctor matches AND the predicate is FALSE
	 * (i.e. the ctor's payload is single-line per the grammar-derived
	 * `multiline` predicate). The cascade-emit phase consults BOTH prev
	 * and curr trackers — fires `opt.<optField>` blank lines only when
	 * both sides of the consecutive pair land in kind=1.
	 *
	 * Currently only `'multiline'` is registered as a predicate name (via
	 * `buildPredicateGatedKind`). Untagged / empty-body / no-payload
	 * ctors bucket into kind=1 (single-line by default), so adding new
	 * ctors to the named set without tagging their payload type with
	 * `@:fmt(multilineWhen…)` is safe — they fire the rule whenever they
	 * appear next to another matched ctor.
	 */
	private function buildBetweenSameCtorBlankInfoIfNot(elemRefName: String, args: Array<String>): BetweenSameCtorIfNotInfo {
		if (args.length < 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorIfNot) expects ≥ 4 string args ('
				+ 'classifierField, predicateName, CtorName1, [CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final reduced: Array<String> = [args[0]].concat(args.slice(2));
		final r: CtorBlankResolution = resolveCtorBlankArgs(elemRefName, reduced, 'blankLinesBetweenSameCtorIfNot', args[1], true);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField
		};
	}

	/**
	 * ω-imports-using-between — resolve
	 * `@:fmt(blankLinesBetweenSameCtorByLevel(classifierField,
	 * CtorName1, [CtorName2, …], levelOptField, countOptField,
	 * pathDifferFQN))` into a `BetweenCtorBlankInfo`. Validates the
	 * classifier resolves to an enum and that every named ctor exists
	 * with arity ≥ 1 (the first positional arg is the path payload
	 * read at runtime). Patterns for matched ctors bind `_v0` to the
	 * first arg; unmatched ctors use bare wildcards.
	 *
	 * Reuses the classifier resolution path from `resolveCtorBlankArgs`
	 * (probe Seq element rule → find Ref field → walk to enum target →
	 * enumerate Alt branches) but builds its own case-pattern set
	 * because (a) the runtime case body assigns BOTH a kind flag AND a
	 * path String at index-dependent ident names, generated at cascade-
	 * emit time, and (b) the matched arity-≥1 requirement is stricter
	 * than the existing builder's optional `_v0` binding.
	 */
	private function buildBetweenCtorBlankInfo(
		elemRefName: String, args: Array<String>, transparentCtorNames: Array<String>, tailAdapterOptField: Null<String>,
		headAdapterOptField: Null<String>
	): BetweenCtorBlankInfo {
		if (args.length < 5)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) expects ≥ 5 string args (classifierField, CtorName1, ['
				+ 'CtorName2, …], levelOptField, countOptField, adapterOptField), got ${args.length}',
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final adapterOptField: String = args[args.length - 1];
		final countOptField: String = args[args.length - 2];
		final levelOptField: String = args[args.length - 3];
		final ctorNames: Array<String> = args.slice(1, args.length - 3);
		if (ctorNames.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) '
				+ 'requires at least one ctor name between the classifier field and the level/count/adapter tail',
				Context.currentPos()
			);
		// ω-cond-comp-tail-transparency — sanity-check no overlap between
		// matched and transparent sets. A ctor in both lists would be
		// ambiguous (kind=1/path=_v0 wins or transparent adapter call?).
		// Reject at compile time so the grammar author resolves it.
		for (name in ctorNames) if (transparentCtorNames.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: ctor "$name" appears both in @:fmt(blankLinesBetweenSameCtorByLevel) matched set and in '
				+ '@:fmt(blankLinesBetweenSameCtorTailTransparent) transparent set on the same Star — must be one or the other',
				Context.currentPos()
			);
		final r: { enumRule: ShapeNode, enumRuleName: String } = resolveClassifierEnum(
			elemRefName, fieldName, 'blankLinesBetweenSameCtorByLevel'
		);
		final enumRule: ShapeNode = r.enumRule;
		final enumRuleName: String = r.enumRuleName;
		final pos: Position = Context.currentPos();
		final built: {
			patterns: Array<BetweenCtorPattern>,
			matched: Array<String>,
			transparentMatched: Array<String>
		} = buildBetweenCtorPatterns(enumRule, ctorNames, transparentCtorNames, pos);
		for (name in ctorNames) if (built.matched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		for (name in transparentCtorNames) if (built.transparentMatched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorTailTransparent) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		return {
			classifierFieldName: fieldName,
			ctorPatterns: built.patterns,
			matchedCtorNames: ctorNames.copy(),
			levelOptField: levelOptField,
			countOptField: countOptField,
			adapterOptField: adapterOptField,
			tailAdapterOptField: tailAdapterOptField,
			headAdapterOptField: headAdapterOptField,
			transparentCtorNames: transparentCtorNames.copy()
		};
	}

	/**
	 * ω-imports-using-transition — lower one
	 * `@:fmt(blankLinesOnTransitionAcross(classifierField, CtorA1,
	 * [CtorA2, …], '|', CtorB1, [CtorB2, …], countOptField))` into a
	 * `TransitionAcrossInfo`. The `'|'` literal in the args list separates
	 * subset A (left) from subset B (right). Each subset must be non-
	 * empty; ctors must exist in the classifier's target enum.
	 *
	 * Transparent-ctor support is inherited from sibling
	 * `blankLinesBetweenSameCtor{Tail,Head}Transparent` metas via the
	 * pre-merged `transparentByClassifier` map (caller).
	 */
	private function buildTransitionAcrossInfo(
		elemRefName: String, args: Array<String>, transparentCtorNames: Array<String>, tailAdapterOptField: Null<String>,
		headAdapterOptField: Null<String>
	): TransitionAcrossInfo {
		if (args.length < 5)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) expects ≥ 5 string args (classifierField, CtorA1, ['
				+ 'CtorA2, …], "|", CtorB1, [CtorB2, …], countOptField), got ${args.length}',
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final countOptField: String = args[args.length - 1];
		final split: TransitionAcrossSplit = splitTransitionAcrossCtors(args, transparentCtorNames);
		final ctorNamesA: Array<String> = split.ctorNamesA;
		final ctorNamesB: Array<String> = split.ctorNamesB;
		final r: { enumRule: ShapeNode, enumRuleName: String } = resolveClassifierEnum(
			elemRefName, fieldName, 'blankLinesOnTransitionAcross'
		);
		final enumRule: ShapeNode = r.enumRule;
		final enumRuleName: String = r.enumRuleName;
		final built: TransitionAcrossPatterns = buildTransitionAcrossPatterns({
			enumRule: enumRule,
			enumRuleName: enumRuleName,
			ctorNamesA: ctorNamesA,
			ctorNamesB: ctorNamesB,
			transparentCtorNames: transparentCtorNames
		});
		for (name in ctorNamesA) if (built.matchedA.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) subset A ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		for (name in ctorNamesB) if (built.matchedB.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) subset B ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		for (name in transparentCtorNames) if (built.transparentMatched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtor{Tail,Head}Transparent) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		return {
			classifierFieldName: fieldName,
			ctorPatterns: built.patterns,
			matchedCtorNamesA: ctorNamesA.copy(),
			matchedCtorNamesB: ctorNamesB.copy(),
			countOptField: countOptField,
			tailAdapterOptField: tailAdapterOptField,
			headAdapterOptField: headAdapterOptField,
			transparentCtorNames: transparentCtorNames.copy()
		};
	}

	/**
	 * Shared classifier-lookup path for the `blankLines{After,Before,
	 * BetweenSameCtorByLevel}Ctor[*]` meta family. Validates that the
	 * Seq element rule has a Ref field matching `fieldName`, that the
	 * Ref points at an Alt rule, and returns `(enumRule, enumRuleName)`
	 * for downstream branch enumeration. Centralising this stops the
	 * five fatalError messages from drifting out of sync across builders.
	 */
	private function resolveClassifierEnum(
		elemRefName: String, fieldName: String, metaName: String
	): { enumRule: ShapeNode, enumRuleName: String } {
		final elemRule: Null<ShapeNode> = _shape.rules[elemRefName];
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) requires element rule $elemRefName to be a Seq struct', Context.currentPos()
			);
		final classifierNode: Null<ShapeNode> = elemRule.children.find(c -> c.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == fieldName);
		if (classifierNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier field "$fieldName" not found on element rule $elemRefName',
				Context.currentPos()
			);
		if (classifierNode.kind != Ref)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier field "$fieldName" must be a plain Ref to an enum rule', Context.currentPos()
			);
		final enumRuleName: Null<String> = classifierNode.annotations.get(AnnotationKeys.BASE_REF);
		if (enumRuleName == null)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier field "$fieldName" has no base.ref annotation', Context.currentPos()
			);
		final enumRule: Null<ShapeNode> = _shape.rules[enumRuleName];
		if (enumRule == null || enumRule.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier target $enumRuleName must be an Alt (enum)', Context.currentPos()
			);
		return { enumRule: enumRule, enumRuleName: enumRuleName };
	}

	/**
	 * Shared resolver for `@:fmt(blankLinesAfterCtor(...))` and
	 * `@:fmt(blankLinesBeforeCtor(...))` — both metas accept the same
	 * `(classifierField, CtorName1, …, optField)` arg shape and produce
	 * the same single-axis classify-switch (`1` for any matching ctor,
	 * `0` otherwise) plus an opt-field name. The two metas diverge only
	 * at runtime: after-ctor consults the previous element's kind,
	 * before-ctor consults the current element's kind paired with a
	 * `prev != curr` gate. Centralising the parse/validation here keeps
	 * both knobs in sync on shape-validation messages and the classifier
	 * lookup path.
	 */
	private function resolveCtorBlankArgs(
		elemRefName: String, args: Array<String>, metaName: String, predicateName: Null<String>, predicateInvert: Bool = false,
		?triviaMultilineExpr: Expr, ?measuredMultilineExpr: Expr
	): CtorBlankResolution {
		if (args.length < 3)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) expects ≥ 3 string args (classifierField, CtorName1, [CtorName2, …], optField), got '
				+ args.length,
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final optField: String = args[args.length - 1];
		final ctorNames: Array<String> = args.slice(1, args.length - 1);
		if (ctorNames.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) requires at least one ctor name between the classifier field and the opt field',
				Context.currentPos()
			);
		final r: { enumRule: ShapeNode, enumRuleName: String } = resolveClassifierEnum(elemRefName, fieldName, metaName);
		final enumRule: ShapeNode = r.enumRule;
		final enumRuleName: String = r.enumRuleName;
		final pos: Position = Context.currentPos();
		final cases: Array<Case> = [];
		final matched: Array<String> = [];
		for (branch in enumRule.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			// Synth-aware arity: in trivia mode, ctors carrying `@:trailOpt` /
			// `@:lead` close-trailing / `@:fmt(captureSource)` etc. grow
			// positional args on the paired synth ctor. The wildcard / `_v0`
			// pattern must size to the full synth arity or Haxe rejects with
			// "Not enough arguments" at the generated switch.
			final arity: Int = branch.children.length + branchSynthExtraArity(enumRuleName, branch);
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			final pattern: Expr = arity == 0 ? ctorIdent : {
				expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]),
				pos: pos
			};
			final isMatch: Bool = ctorNames.indexOf(ctorName) >= 0;
			if (isMatch) matched.push(ctorName);
			final kindExpr: Expr = if (!isMatch)
				macro 0;
			else if (predicateName == null)
				macro 1;
			else
				buildPredicateGatedKind(branch, predicateName, metaName, predicateInvert, triviaMultilineExpr, measuredMultilineExpr);
			// When a predicate gate is active, the case pattern must bind the
			// first arg as `_v0` so the predicate can reference it. Plain
			// (non-predicated) and zero-arg ctors keep the original wildcard
			// pattern.
			final patternFinal: Expr = if (isMatch && predicateName != null && arity >= 1) {
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				{ expr: ECall(ctorIdent, binders), pos: pos };
			} else
				pattern;
			cases.push({ values: [patternFinal], guard: null, expr: kindExpr });
		}
		// ω-orphan-prefix-decl: a classifier field declared `@:optional` —
		// `HxTopLevelDecl.decl`, absent for a module-scope declaration that is
		// nothing but its own `#if X #end` prefix — reaches this switch as null.
		// The case list above is exhaustive over the enum's CTORS only, so
		// without an explicit arm strict null-safety rejects the subject. Kind
		// `0` is the same answer every unmatched ctor gets, so a declaration
		// that is only a prefix takes part in no blank-line cascade. Mirrors
		// `buildInterMemberClassifyCases`'s member-scope arm.
		cases.push({ values: [macro null], guard: null, expr: macro 0 });
		for (name in ctorNames) if (matched.indexOf(name) < 0)
			Context.fatalError('WriterLowering: @:fmt($metaName) ctor "$name" not found in enum $enumRuleName', Context.currentPos());
		return {
			fieldName: fieldName,
			cases: cases,
			optField: optField
		};
	}

	/**
	 * ω-after-multiline — build the kind-=1 case body for a
	 * predicate-gated `blankLines{After,Before}CtorIf` ctor match.
	 * `predicateName` is currently only `'multiline'`; resolves to a
	 * grammar-derived structural check via `buildMultilinePredicate`
	 * applied to the ctor's first arg (bound as `_v0` in the case
	 * pattern). Returns `macro 0` when the ctor's payload type carries
	 * no relevant `@:fmt(multilineWhen...)` meta, so adding new ctors to
	 * the gated set without tagging their target type silently keeps
	 * them at kind=0 (same as the bare ctor not being in the set).
	 *
	 * Recursive design: `multilineWhenFieldNonEmpty(<arrayField>)` on a
	 * struct typedef → `_v0.<field>.length > 0`.
	 * `multilineWhenFieldShape(<refField>)` → recurse into the field's
	 * target type's predicate. On enum types, switch over each ctor
	 * and apply `multilineCtor`-tagged ctor's arg-type predicate;
	 * untagged ctors emit `false`.
	 */
	private function buildPredicateGatedKind(
		branch: ShapeNode, predicateName: String, metaName: String, invert: Bool = false, ?triviaMultilineExpr: Expr,
		?measuredMultilineExpr: Expr
	): Expr {
		if (predicateName != 'multiline')
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) predicate "$predicateName" is not registered (currently only "multiline" is supported)',
				Context.currentPos()
			);
		// ω-between-single-line-types — `invert=true` flips the kind polarity:
		// kind=1 when predicate is FALSE (i.e. the ctor matches AND is NOT
		// multi-line). Used by `blankLinesBetweenSameCtorIfNot` to track
		// "single-line side of the pair". Untagged ctors (no relevant
		// `multilineWhen…` meta on payload type) return `null` predicate
		// → kind=1 unconditionally under invert (single-line by default).
		//
		// ω-leading-trivia-multiline — when the Star carries
		// `@:fmt(multilineWhenLeadingTriviaSpansLines(...))`, `triviaMultilineExpr`
		// is a per-element `_t`-scoped boolean (leading comment present OR
		// meta-on-own-line). It OR-folds into the structural predicate so a
		// payload that renders single-line by its own shape is still treated
		// as multi-line when its leading layout crosses source lines (fork
		// `getTypeInfo` includes leading comment + leading meta in the
		// `oneLine` span). Null → byte-identical to the pre-slice paths.
		final structPred: Null<Expr> = if (branch.children.length == 0)
			null
		else {
			final argNode: ShapeNode = branch.children[0];
			final argTypeName: Null<String> = argNode.annotations[AnnotationKeys.BASE_REF];
			if (argTypeName == null)
				null
			else
				buildMultilinePredicate(argTypeName, macro _v0);
		}
		// ω-measured-multiline-decl — the RENDERED channel. `structPred` answers
		// from the payload's SHAPE (a class is multi-line iff it declares
		// members), which is blind to a header that renders across lines on its
		// own: an empty-bodied `class C extends B implements … {}` whose heritage
		// clauses wrap is structurally single-line and physically three. Fork
		// `MarkEmptyLines.getTypeInfo` asks `isSameLine`, which reads the
		// whitespace `MarkWrapping` already committed — a rendering property, not
		// a source one — so the honest analogue is to measure the built Doc. The
		// caller supplies a per-element boolean (`_measMulti[_si]`, computed once
		// per module in `TriviaEofLowering`); null keeps every pre-slice path
		// byte-identical.
		final rendered: Null<Expr> = if (triviaMultilineExpr != null && measuredMultilineExpr != null)
			macro ($triviaMultilineExpr || $measuredMultilineExpr);
		else if (triviaMultilineExpr != null)
			triviaMultilineExpr;
		else
			measuredMultilineExpr;
		final cond: Null<Expr> = if (structPred != null && rendered != null)
			macro ($structPred || $rendered);
		else if (structPred != null)
			structPred;
		else if (rendered != null)
			rendered;
		else
			null;
		return if (cond == null)
			invert ? macro 1 : macro 0
		else if (invert)
			macro ($cond ? 0 : 1)
		else
			macro ($cond ? 1 : 0);
	}

	/**
	 * ω-after-multiline — recursively build the multi-line predicate
	 * for `typeName` applied to `accessExpr`. Returns `null` when the
	 * type carries no multi-line meta — caller substitutes `macro 0`
	 * (or `macro false`).
	 *
	 * Reads three `@:fmt(...)` flag forms from the grammar shape:
	 *  - typedef-level `multilineWhenFieldNonEmpty('field')` →
	 *    `accessExpr.field.length > 0`. Used when the type's multi-line
	 *    nature is determined by a Star field's emptiness (Class /
	 *    Iface / Abstract members, EnumDecl ctors, FnBlock stmts).
	 *  - typedef-level `multilineWhenFieldShape('field')` → recurse
	 *    into the named field's target type, applied to
	 *    `accessExpr.field`. Used when the type defers its multi-line
	 *    decision to a sub-rule (HxFnDecl → body).
	 *  - ctor-level `multilineCtor` (on enum branches) → switch over
	 *    every ctor of the enum; the tagged ctor binds its first arg
	 *    and recurses into the arg's type predicate; untagged ctors
	 *    emit `false`. Used for enum types whose multi-line nature
	 *    depends on which variant is present (HxFnBody → BlockBody
	 *    multi-line iff its block is, NoBody / ExprBody never).
	 *  - typedef-level `multilineWhenFieldCtorAndOpt('<field>', '<ctorName>',
	 *    '<optField>', '<optEnumExpr>')` (4-arg form) →
	 *    `Type.enumConstructor(accessExpr.<field>) == ctorName
	 *    && opt.<optField> == <optEnumExpr>`. The 4th arg is parsed as
	 *    a Haxe expression (via `Context.parse`) so the compared value
	 *    can be a fully-qualified `enum abstract` constructor like
	 *    `anyparse.format.BracePlacement.Next` — `Type.enumConstructor`
	 *    on the opt side would not compile for `enum abstract` knobs.
	 *    Use when the structural ctor match alone isn't enough — the
	 *    bound type may render flat or multi-line depending on a runtime
	 *    layout knob. Currently used by `HxTypedefDecl` to mark itself
	 *    multi-line only when `type` is `Anon` AND `anonTypeLeftCurly`
	 *    is `Next` (Allman): under `Same` the same source emits single-
	 *    line so the predicate stays false. The full path on the 4th
	 *    arg keeps the macro free of grammar-specific imports.
	 *  - typedef-level `multilineWhenStarFieldWrapsCascade('<starField>',
	 *    '<cascadeKnob>', '<itemNameField>')` (3-arg form) — predicate
	 *    fires when the named Star field's wrap cascade would resolve
	 *    to a non-`NoWrap` mode. The macro emits a runtime mirror of
	 *    `WrapList.emit`'s width arithmetic (sum/max with `(n-1)*2`
	 *    inter-item sep correction for `, `), reads `opt.<cascadeKnob>`
	 *    as a `WrapRules`, and calls `WrapList.decideWithLineLengthState`
	 *    with layout-blind inputs (`exceeds=false`, no `LineLengthLargerThan`
	 *    firing). Per-item width approximated as `item.<itemNameField>.length`
	 *    — sufficient when items are dominated by a single bare-name field
	 *    (e.g. `HxTypeParamDecl.name`, no constraint). Used by
	 *    `HxTypedefDecl` to detect typedefs whose declare-site typeParams
	 *    overflow `totalItemLength`/`anyItemLength` thresholds.
	 *
	 * Multiple struct-level meta entries OR-fold into one predicate:
	 * each matching meta contributes a clause, and the predicate fires
	 * when any clause fires. Enables composing structural conditions
	 * (Anon-Allman binding) with rendering-aware conditions (wrap-cascade
	 * fires on a Star field) on the same typedef. Previously first-match-
	 * wins-returns precluded this composition.
	 */
	private function buildMultilinePredicate(typeName: String, accessExpr: Expr): Null<Expr> {
		final node: Null<ShapeNode> = _shape.rules[typeName];
		if (node == null) return null;
		final meta: Null<Metadata> = node.annotations.get(AnnotationKeys.BASE_META);
		if (meta != null) {
			final folded: Null<Expr> = buildMultilineMetaPredicate(node, typeName, accessExpr, meta);
			if (folded != null) return folded;
		}
		// Enum dispatch: switch over each ctor's `multilineCtor` flag.
		return node.kind == Alt ? buildMultilineEnumPredicate(node, accessExpr) : null;
	}

	/**
	 * Trivia-mode extra positional args a paired Alt ctor carries beyond
	 * its declared children. The per-slot inventory and push-order
	 * documentation live with the formula in
	 * `TriviaTypeSynth.extraAltArgs`, next to the `buildEnumCtor` blocks
	 * it mirrors; the writer reads specific slots via `argNames[<i>]` /
	 * `altSlotAccess` (see the per-slot ω-comments there). Plain mode
	 * keeps the declared arity.
	 */
	private function branchExtraArgs(branch: ShapeNode): Int {
		return _ctx.trivia ? TriviaTypeSynth.extraAltArgs(branch) : 0;
	}

	/**
	 * The second wrap cascade a trivia sep-Star named through
	 * `@:fmt(mapWrapRules('<field>'))`, paired with the runtime test that selects
	 * it — `null` for the Stars that named none, which is all but one.
	 *
	 * The test is the grammar's OWN `arrayBracketKind` predicate, the same one
	 * `@:fmt(bracketKindPad)` consults for inner-bracket padding, so a list cannot
	 * be a map to one knob and an array to the other. It is built HERE rather than
	 * inside `TriviaSepLowering` because resolving the predicate's class needs
	 * `_shape` and `_ctx`, and it is built ONCE rather than at each of the two
	 * sep-Star entry points because the argument expression and the length guard
	 * are exactly the part that must not drift.
	 *
	 * `_arr[0].node` is an identifier bound by the block `triviaSepStarExpr`
	 * emits — the same unhygienic coupling the `bracketKindPad` override Docs
	 * have. Unlike those, this expression IS reachable with an empty list: the
	 * Star's empty short-circuit also requires no close-trailing trivia, so a `[]`
	 * carrying a line comment still runs the keep / ignore / noWrap checks. The
	 * length guard is what stands between that and reading `.node` of nothing.
	 */
	private function mapWrapFor(field: Null<String>): Null<SepStarMapWrap> {
		if (field == null) return null;
		final kind: Expr = AstPredLowering.predCallExpr(_shape.root, _ctx.trivia, false, ARRAY_BRACKET_KIND_PRED, [macro _arr[0].node]);
		return {
			field: field,
			isMapLiteralExpr: macro (_arr.length > 0 && $kind == 1)
		};
	}

	@:access(anyparse.macro.TriviaSepLowering)
	private function triviaSepStarBuild(c: EnumStarCtx, slots: TriviaAltSlots): Expr {
		final branch: ShapeNode = c.branch;
		final wrapRulesField: Null<String> = branch.fmtReadString('wrapRules');
		// ω-mapwrap: enum-Alt branch reader for `@:fmt(mapWrapRules('<field>'))`
		// (`HxExpr.ArrayExpr`) — a MAP literal goes to `wrapping.mapWrap`, every
		// other bracket list to `wrapping.arrayWrap`, mirroring the fork's
		// `arrayWrapping` split on `getBkOpenType == MapLiteral`. Null on every
		// other Star.
		final mapWrap: Null<SepStarMapWrap> = mapWrapFor(branch.fmtReadString('mapWrapRules'));
		// ω-arraylit-trailing-comma-dispatch: enum-Alt branches
		// (e.g. `HxExpr.ArrayExpr`) carry `@:fmt(trailingComma(
		// '<knob>'))` but the trivia-mode emit at this site
		// must thread the knob into `triviaSepStarExpr`'s
		// 13th/14th params (hardcoded `null, null` ignores it). Sister
		// dispatch-dual-path gap —
		// the struct-Star path at `lowerStruct`
		// already threads `trailingCommaField`. Companion sibling
		// `ω-arraylit-source-trail-comma` adds the 13th param's
		// counterpart via a synth-side positional `trailPresent:
		// Bool` slot (no `<field>TrailPresent` named struct field —
		// Alt ctors are positional, so synth pushes the slot under
		// the `isAltCloseTrailingBranch + @:lead + !@:tryparse +
		// @:sep` gate; writer binds it via `argNames[5]` as
		// `sepTrailPresentAccess` below). With both, the trivia-
		// sep helper's `appendTrailingCommaExpr` engages identically
		// to the struct-Star path: `trailPresent || knob`.
		final trailingCommaField: Null<String> = branch.fmtReadString('trailingComma');
		// ω-trivia-sep-anontype-braces (Phase B1): forward the
		// `anonTypeBracesOpen/Close` policy via
		// `delimInsidePolicySpace` so the trivia-mode emit honours
		// inside-brace whitespace exactly like the non-trivia
		// branch (line ~1257). Branches without the flag get null
		// → helper falls back to `_de()` (no spaces inside).
		// ω-bracket-config: `@:fmt(bracketKindPad)` (`HxExpr.ArrayExpr`)
		// supersedes the static `anonTypeBraces*` path — the inside-space
		// depends on the first element's bracket kind, decided at runtime
		// by the generated typed classifier. Both override Docs reference
		// `_arr[0].node` — an identifier BOUND by the block that
		// `triviaSepStarExpr` emits (unhygienic cross-function coupling,
		// same as every other `_arr`/`_docs` splice fed to it) — which is
		// safe everywhere they are spliced: the empty-`[]` form
		// short-circuits before any emit that uses them
		// (`_arr.length == 0` guard near the `triviaSepStarExpr` tail and
		// `WrapList.emit`'s own `items.length == 0` guard).
		final bracketKindPadAlt: Bool = branch.fmtHasFlag('bracketKindPad');
		final openInsideExpr: Null<Expr> = bracketKindPadAlt
			? arrayBracketInsidePolicySpace(macro _arr[0].node, false)
			: delimInsidePolicySpace(branch, ['anonTypeBracesOpen'], false);
		final closeInsideExpr: Null<Expr> = bracketKindPadAlt
			? arrayBracketInsidePolicySpace(macro _arr[0].node, true)
			: delimInsidePolicySpace(branch, ['anonTypeBracesClose'], true);
		// ω-trivia-sep-doc-comment-cascade (Phase B2): forward the
		// `beforeDocCommentEmptyLines` flag so sep-Stars opt into
		// the cascade (currently only `HxType.Anon.fields`).
		final beforeDocComments: Bool = branch.fmtHasFlag('beforeDocCommentEmptyLines');
		// ω-anontype-left-curly: forward `@:fmt(leftCurly('<knob>'))`
		// from the enum-Alt branch so `HxType.Anon` honours per-
		// construct `anonTypeLeftCurly`. When `Next`, the helper's
		// trivia branch prepends `_doh()` (OptHardline) before the
		// `{`, and the no-trivia branch feeds the same Doc into
		// `WrapList.emit`'s `(leadFlat=_de(), leadBreak=_doh())`
		// pair so the wrap engine's flat/break decision picks
		// cuddled vs Allman per the anon-type's measured shape.
		// Mirrors the struct-Star `lowerStruct` path at
		// `HxObjectLit.fields`.
		final knobLeftCurly: Null<String> = branch.fmtReadString('leftCurly');
		// ω-anontype-right-curly: call-form `@:fmt(rightCurly('<knob>'))`
		// names a per-construct `RightCurlyPlacement` opt field that
		// the trivia branch of `triviaSepStarExpr` reads. Currently
		// consumed by `HxType.Anon` for `anonTypeRightCurly`. Null
		// (no opt-in or bare flag) falls back to unconditional
		// `_dhl()` before close.
		final knobRightCurly: Null<String> = branch.fmtReadString('rightCurly');
		// ω-typedef-anon-force-multi: enum-Alt branch reader for
		// `@:fmt(forceMultiInTypedef)` on `HxType.Anon`. Threads the
		// flag into `triviaSepStarExpr` so the no-trivia branch
		// emits a runtime `opt._inTypedefBody ? WrapMode.OnePerLine
		// : null` as `WrapList.emit`'s `forceMode` option. Closes
		// the `issue_301` typedef-anon source-flat → fork-multi
		// shape gap by forcing OnePerLine when the parent
		// `HxTypedefDecl.type` Ref has flipped `_inTypedefBody=true`
		// via `propagateTypedefContext`. Non-typedef anon callers
		// (var-type-hint, fn-return-type) stay cascade-driven.
		final forceMultiTypedef: Bool = branch.fmtHasFlag('forceMultiInTypedef');
		final bodyAware: Bool = branch.fmtHasFlag('bodyAwareCompactIndent');
		// ω-group-rest-probe slice 2: enum-Alt branch reader for
		// `@:fmt(groupRestProbe)`. Trivia-path mirror of the plain-
		// path read at lowerStruct's Star dispatch. Dual-dispatch
		// per [[feedback-wraprules-dispatch-dual-path]].
		final groupRestProbe: Bool = branch.fmtHasFlag('groupRestProbe');
		// ω-cascade-emits-comments: enum-Alt branch reader for
		// `@:fmt(ignoreSourceNewlinesForWrap)` — intrinsic
		// per-construct opt-in to fork's `Ignore` policy
		// (drop source newline signal, inline cascade-emittable
		// trivia). Currently no enum-Alt consumer opts in;
		// reader present for symmetry with the struct-path
		// dual-dispatch.
		final ignoreSourceNewlines: Bool = branch.fmtHasFlag('ignoreSourceNewlinesForWrap');
		// ω-typedef-between-fields: enum-Alt branch reader for
		// `@:fmt(typedefBodyBlanks)` (currently `HxType.Anon`).
		// When set AND the descendant anon sees
		// `opt._inTypedefBody == true`, the force-multi branch in
		// `triviaSepStarExpr` injects `opt.typedefBeginType` blanks
		// after `{` and `opt.typedefBetweenFields` blanks between
		// adjacent fields. Inline anon-type uses never carry the
		// flag, staying byte-identical to pre-slice.
		final typedefBodyBlanksAlt: Bool = branch.fmtHasFlag('typedefBodyBlanks');
		// ω-array-reflow: enum-Alt branch reader for
		// `@:fmt(reflowSourceMultiline)` — opt-in for source-
		// multiline lists (currently `HxExpr.ArrayExpr`) re-flowed
		// by the wrap cascade instead of forced one-per-line.
		// Threads into `triviaSepStarExpr`'s `_smlKeep` gate.
		final reflowSourceMultilineAlt: Bool = branch.fmtHasFlag('reflowSourceMultiline');
		// ω-arraymatrix-wrap: enum-Alt branch reader for
		// `@:fmt(arrayMatrixWrap)` (`HxExpr.ArrayExpr`). Marks the
		// Star as matrix-eligible so `triviaSepStarExpr` attempts a
		// source-grid layout before the wrap cascade.
		final matrixWrapAlt: Bool = branch.fmtHasFlag('arrayMatrixWrap');
		// ω-value-yielded-if-tail-barrier (array-element expr-position):
		// `@:fmt(propagateExprPosition)` on the ArrayExpr ctor flags each
		// element as expression-position so a value-if array element stays
		// glued (`expressionIfBody`). False on every other enum-Alt sep-Star.
		final propagateExprPositionAlt: Bool = branch.fmtHasFlag('propagateExprPosition');
		// ω-multiline-trailing-comma-remove / ω-uniform-element-blanks: enum-Alt
		// branch readers for the two `HxExpr.ArrayExpr` opt-ins — the first lets
		// `wrapping.trailingComma = remove` drop the break-mode trailing `,`, the
		// second extends `emptyLines.uniformStatementBlanks` to element gaps.
		final trailingCommaRemovableAlt: Bool = branch.fmtHasFlag('trailingCommaRemovable');
		final uniformStmtBlanksAlt: Bool = branch.fmtHasFlag('uniformStmtBlanks');
		// ω-complex-item-count: enum-Alt branch reader for `@:fmt(complexItems)`
		// (`HxExpr.ArrayExpr`) — classify each element (call / `new`,
		// call-bearing container literal, neither) so the cascade can send an
		// array of constructor calls one-per-line on a SEMANTIC counter rather
		// than a width proxy (which would also mangle `case [A, _]` patterns).
		final complexItemsAlt: Bool = branch.fmtHasFlag('complexItems');
		return TriviaSepLowering.triviaSepStarExpr(
			c.argsAccess, slots.trailBBAccess, slots.trailLCAccess, slots.trailCloseAccess, slots.trailOpenAccess, c.elemFn, c.leadText,
			c.trailText, c.sepText, wrapRulesField, knobLeftCurly, knobRightCurly, slots.sepTrailPresentAccess, trailingCommaField,
			openInsideExpr, closeInsideExpr, beforeDocComments, forceMultiTypedef, bodyAware, groupRestProbe, ignoreSourceNewlines,
			reflowSourceMultilineAlt, matrixWrapAlt, null, typedefBodyBlanksAlt, propagateExprPositionAlt, false,
			trailingCommaRemovableAlt, uniformStmtBlanksAlt, complexItemsAlt, mapWrap
		);
	}

	@:access(anyparse.macro.TriviaBlockLowering)
	private function triviaBlockStarBuild(c: EnumStarCtx, slots: TriviaAltSlots, altBlockEndedFlag: Bool): Expr {
		final branch: ShapeNode = c.branch;
		final sepText: Null<String> = c.sepText;
		// ω-bropen-keep: forward `@:fmt(keepCurlyBlanks)` from the
		// enum-Case branch so non-type block bodies (BlockStmt,
		// BlockExpr) honour `opt.afterLeftCurly` /
		// `opt.beforeRightCurly` Keep policy. Sister to the
		// struct-Star path's read at the `lowerStruct` call site.
		final keepCurlyBlanks: Bool = branch.fmtHasFlag('keepCurlyBlanks');
		// ω-arrow-lambda-body-context: forward the override-meta
		// presence so the helper clears `_inAnonFnBody` for the
		// per-element write — see helper docstring for rationale.
		final anonFnClear: Bool = branch.fmtHasFlag('leftCurlyAnonFnOverride');
		// ω-blockempty: enum-Case branch may opt into empty-curly
		// break dispatch via `@:fmt(emptyCurlyBreak)` (bare or with
		// knob-name arg). Used by `HxStatement.BlockStmt` and
		// `HxExpr.BlockExpr` to route empty bodies through
		// `opt.blockEmptyCurly`.
		final emptyCurlyBreak: Bool = branch.fmtHasFlag('emptyCurlyBreak');
		final emptyCurlyKnobArgs: Null<Array<String>> = branch.fmtReadStringArgs('emptyCurlyBreak');
		final emptyCurlyKnob: Null<String> = emptyCurlyKnobArgs != null && emptyCurlyKnobArgs.length >= 1 ? emptyCurlyKnobArgs[0] : null;
		// ω-blockright-curly: call-form `@:fmt(rightCurly('<knob>'))`
		// names a per-construct RightCurlyPlacement opt field. The
		// bare form returns null and falls back to unconditional
		// `_dhl()` before close inside `triviaBlockStarExpr`.
		final rightCurlyKnobArgs: Null<Array<String>> = branch.fmtReadStringArgs('rightCurly');
		final rightCurlyKnob: Null<String> = rightCurlyKnobArgs != null && rightCurlyKnobArgs.length >= 1 ? rightCurlyKnobArgs[0] : null;
		// ω-anonfunction-right-curly: call-form
		// `@:fmt(rightCurlyAnonFnOverride('<knob>'))` names a
		// RightCurlyPlacement opt field that the dispatch reads
		// only when `_inAnonFnBody=true`. Sister to
		// `leftCurlyAnonFnOverride`. Pre-slice (no opt-in) falls
		// through to `_dhl()` for non-anon-fn contexts.
		final rightCurlyAnonFnArgs: Null<Array<String>> = branch.fmtReadStringArgs('rightCurlyAnonFnOverride');
		final rightCurlyAnonFnKnob: Null<String> = rightCurlyAnonFnArgs != null && rightCurlyAnonFnArgs.length >= 1
			? rightCurlyAnonFnArgs[0]
			: null;
		return TriviaBlockLowering.triviaBlockStarExpr(
			c.argsAccess, slots.trailBBAccess, slots.trailLCAccess, slots.trailCloseAccess, slots.trailOpenAccess, c.elemFn, c.leadText,
			c.trailText, true, false, false, false, null, false, emptyCurlyBreak, false, keepCurlyBlanks, false, false, null, false, null,
			anonFnClear, emptyCurlyKnob, rightCurlyKnob, rightCurlyAnonFnKnob, altBlockEndedFlag ? sepText : null, altBlockEndedFlag,
			altBlockEndedFlag ? (branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE]: Null<String>) : null,
			altBlockEndedFlag ? _formatInfo.schemaTypePath : null, null, branch.fmtHasFlag('clearExprPositionNonTail'), 'beginType',
			'endType', branch.fmtHasFlag('uniformStmtBlanks')
		);
	}

	private function lowerEnumStarTrivia(c: EnumStarCtx): Expr {
		final branch: ShapeNode = c.branch;
		final argNames: Array<String> = c.argNames;
		final sepText: Null<String> = c.sepText;
		// ω-close-trailing-alt: same-line trailing comment captured
		// after the close literal (`} // catch`). The synth ctor
		// grew a positional arg (`closeTrailing`) and `argNames[1]`
		// is its writer-side binding. Plain mode keeps the pre-slice
		// null path (no extra arg, no extra binding).
		//
		// ω-open-trailing-alt: parallel slot for the same-line trailing
		// comment captured AFTER the open literal (`[ /* foo */]` for
		// empty arrays, `{ // foo` before first stmt). Synth appends
		// `openTrailing:Null<String>` as `argNames[2]` when the branch
		// also carries `@:lead`. Without this, an inline comment in an
		// otherwise-empty close-peek Star is dropped at parse — the
		// loop's terminal `_lead` is discarded on close-peek break, and
		// `collectTrivia`'s newline-anchored scan skips same-line
		// comments after the open lit anyway.
		final hasOrphan: Bool = TriviaTypeSynth.isAltCloseTrailingBranch(branch) && branch.readMetaString(':lead') != null
			&& !branch.hasMeta(':tryparse');
		final trailCloseAccess: Null<Expr> = TriviaTypeSynth.isAltCloseTrailingBranch(branch) ? macro $i{argNames[1]} : null;
		final trailOpenAccess: Null<Expr> = hasOrphan ? macro $i{argNames[2]} : null;
		// ω-orphan-trivia-alt: orphan trivia between the last Star
		// element and the close literal (e.g. trailing line comment
		// inside `try { p(); /* dropped */ }`). Synth grew two
		// positional args (`trailingBlankBefore` at `argNames[3]`,
		// `trailingLeading` at `argNames[4]`) for `isAltCloseTrailingBranch`
		// branches with `@:lead`. The Lowering Case 4 trivia loop
		// captures `_lead.blankBefore` / `_lead.leadingComments` on
		// close-peek break and forwards them. Without this, an inner
		// `// foo` between the last stmt and `}` is dropped at parse —
		// `collectTrivia` runs on the final iteration but its result is
		// discarded on the break.
		final trailBBAccess: Null<Expr> = hasOrphan ? macro $i{argNames[3]} : null;
		final trailLCAccess: Null<Expr> = hasOrphan ? macro $i{argNames[4]} : null;
		// ω-arraylit-source-trail-comma: enum-Alt sep+trail+lead+@:trivia
		// branches grow a 6th positional `trailPresent:Bool` (synth pushes
		// it inside the `isAltCloseTrailingBranch + @:lead + !@:tryparse`
		// block when `branch.readMetaString(':sep') != null`). Bind here so
		// the trivia branch of `triviaSepStarExpr` can preserve a source
		// trailing comma via `appendTrailingCommaExpr = trailPresent ||
		// knob`. Sister to struct-Star `<field>TrailPresent` binding in
		// `lowerStruct`.
		final hasSepTrailPresent: Bool = hasOrphan && sepText != null;
		final sepTrailPresentAccess: Null<Expr> = hasSepTrailPresent ? macro $i{argNames[5]} : null;
		final slots: TriviaAltSlots = {
			trailCloseAccess: trailCloseAccess,
			trailOpenAccess: trailOpenAccess,
			trailBBAccess: trailBBAccess,
			trailLCAccess: trailLCAccess,
			sepTrailPresentAccess: sepTrailPresentAccess
		};
		// ω-trivia-sep: sep-Star Alt branches (e.g. `HxExpr.ArrayExpr`)
		// route to the dedicated sep helper. Block-style (no sep)
		// stays on the always-multi-line path.
		//
		// ω-arraylit-wraprules: forward `@:fmt(wrapRules('<field>'))`
		// from the enum-Case branch to the helper so the no-trivia
		// branch can defer layout to `WrapList.emit` (mirrors the
		// struct-Star path in `lowerStruct`). First Alt-branch
		// consumer is `HxExpr.ArrayExpr.elems` (`arrayLiteralWrap`).
		// ω-blockended-trivia (Session 3): enum-Alt mirror — when the
		// trivia-mode `@:sep+@:lead+@:trail` branch carries the
		// `blockEnded` flag (HxStatement.BlockStmt / HxExpr.BlockExpr
		// after Session 3 migration), skip the `triviaSepStarExpr`
		// flat-or-multi dispatch and fall through to the block-mode
		// dispatch with sepText/blockEnded threaded into
		// `triviaBlockStarExpr`.
		final altBlockEndedFlag: Bool = branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		return sepText != null && !altBlockEndedFlag ? triviaSepStarBuild(c, slots) : triviaBlockStarBuild(c, slots, altBlockEndedFlag);
	}

	private function lowerEnumStarPlain(c: EnumStarCtx): Expr {
		final branch: ShapeNode = c.branch;
		final sepText: Null<String> = c.sepText;
		final argsAccess: Expr = c.argsAccess;
		final elemCall: Expr = c.elemCall;
		final leadText: String = c.leadText;
		final trailText: String = c.trailText;
		final starNode: ShapeNode = c.starNode;
		if (sepText != null && branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true) {
			// Block-ended exemption (Session 2 pilot — mirror of
			// `emitWriterStarField`). Suppress between-element sep
			// emission when EITHER:
			//   (a) the prior element's rendered Doc ends with `}` or `;`
			//       (`DocMeasure.endsWithStmtTerminator` — Session 8 widened
			//       from `endsWithCloseBrace` to include `;` so per-stmt
			//       `@:trail/@:trailOpt(';')` baked terminators suppress
			//       sep too), OR
			//   (b) the blockEnded predicate (generated typed for astPreds
			//       formats; schema-instance for pilots, e.g. `Atom('end')`
			//       in MiniBlockStrict) returns true on the prior element's
			//       AST (Session 7 option b2 — `HxStatement.Conditional(#if…#end)`
			//       whose byte-end `d` misses (a) but the predicate matches
			//       the AST shape).
			// Mirrors the struct-field plain-mode site at L3845-3880 and
			// the parser-side blockEnded branch in `Lowering.emitStarFieldSteps`
			// (`b == '}'.code || b == ';'.code || $predicateCall`).
			// Strictly opt-in via `@:sep('text', tailRelax, blockEnded[('pred'[, sepStartsElement])])`.
			final predicateName: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE];
			final predicateCheckPrior: Expr = blockEndedPredCheck(predicateName, macro _args[_i - 1]);
			return macro {
				final _args = $argsAccess;
				final _docs: Array<anyparse.core.Doc> = [_dt($v{leadText})];
				var _i: Int = 0;
				while (_i < _args.length) {
					final _elemDoc: anyparse.core.Doc = $elemCall;
					if (_i > 0) {
						final _priorDoc: anyparse.core.Doc = _docs[_docs.length - 1];
						final _priorEnds: Bool = anyparse.core.DocMeasure.endsWithSemi(_priorDoc) || $predicateCheckPrior;
						if (!_priorEnds) {
							_docs.push(_dt($v{sepText}));
							_docs.push(_dt(' '));
						}
					}
					_docs.push(_elemDoc);
					_i++;
				}
				_docs.push(_dt($v{trailText}));
				_dc(_docs);
			};
		}
		if (sepText == null) return macro {
			final _args = $argsAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			var _i: Int = 0;
			while (_i < _args.length) {
				_docs.push($elemCall);
				_i++;
			}
			blockBody($v{leadText}, $v{trailText}, _docs, opt);
		};
		// See `emitWriterStarField` — `@:sep('\n')` routes to a flat
		// hardline-join emission (format-neutral).
		if (sepText == '\n') {
			return macro {
				final _args = $argsAccess;
				final _docs: Array<anyparse.core.Doc> = [_dt($v{leadText})];
				var _i: Int = 0;
				while (_i < _args.length) {
					if (_i > 0) _docs.push(_dhl());
					_docs.push($elemCall);
					_i++;
				}
				_docs.push(_dt($v{trailText}));
				_dc(_docs);
			};
		}
		final tcExpr: Expr = trailingCommaExpr(branch);
		// ω-bracket-config: `@:fmt(bracketKindPad)` (`HxExpr.ArrayExpr`,
		// plain-mode `sepList` path) overrides the static anonTypeBraces
		// inside-space with a runtime dispatch on the first element's
		// bracket kind. Reads `_args[0]` (the plain `HxExpr` element,
		// bound just below at the `final _args = $argsAccess` site).
		// The generated classifier's own `case null` arm answers the
		// default `ArrayLiteral` for an empty `[]`'s `_args[0]` → `_de()`,
		// keeping empty brackets tight.
		final bracketKindPad: Bool = branch.fmtHasFlag('bracketKindPad');
		final openInsideExpr: Expr = bracketKindPad
			? arrayBracketInsidePolicySpace(macro _args[0], false)
			: (delimInsidePolicySpace(branch, ['anonTypeBracesOpen'], false) ?? macro _de());
		final closeInsideExpr: Expr = bracketKindPad
			? arrayBracketInsidePolicySpace(macro _args[0], true)
			: (delimInsidePolicySpace(branch, ['anonTypeBracesClose'], true) ?? macro _de());
		// ω-anontype-wraprules: forward `@:fmt(wrapRules('<field>'))`
		// to `WrapList.emit` for non-trivia-collecting Alt-Star
		// nodes only. `@:trivia`-annotated branches (e.g.
		// `HxExpr.ArrayExpr`) keep the renderer-driven `sepList`
		// path here — their wrapRules dispatch already runs
		// through `triviaSepStarExpr` in trivia mode, and
		// switching the plain-mode path to `WrapList.emit` would
		// lose renderer-driven flat/break for callers that rely
		// on `lineWidth`-based natural breaking (verified by
		// `HxTrailingCommaOptionsTest.testArrayTrailingCommaOnBreak`,
		// which uses plain-mode `HxModuleWriter`). Type-position
		// nodes (`HxType.Anon.fields`) don't carry trivia, so the
		// plain-path dispatch is their only wrapRules surface —
		// a `@:trivia` flip would synthesize unused machinery.
		final isTriviaCollecting: Bool = starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		final wrapRulesField: Null<String> = isTriviaCollecting ? null : branch.fmtReadString('wrapRules');
		final listCall: Expr = if (wrapRulesField != null) {
			final rulesExpr: Expr = optFieldAccess(wrapRulesField);
			macro anyparse.format.wrap.WrapList.emit(
				$v{leadText}, $v{trailText}, $v{sepText}, _docs, opt, $openInsideExpr, $closeInsideExpr, false, $rulesExpr,
				{ appendTrailingComma: $tcExpr }
			);
		} else {
			macro sepList(
				$v{leadText}, $v{trailText}, $v{sepText}, _docs, opt, $tcExpr, $openInsideExpr, $closeInsideExpr, false,
				$v{branch.fmtHasFlag('cuddle')}
			);
		};
		return macro {
			final _args = $argsAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			var _i: Int = 0;
			while (_i < _args.length) {
				_docs.push($elemCall);
				_i++;
			}
			$listCall;
		};
	}

	/**
	 * Validate the modifier Star → enum → static-ctor chain that
	 * `@:fmt(staticVarSubdivision)` relies on. Fatal-errors on any
	 * misconfiguration; returns normally when the shape is sound.
	 *
	 */
	private function validateStaticVarSubdivision(elemRefName: String, modifierField: String, staticCtor: String): Void {
		final elemRule: Null<ShapeNode> = _shape.rules[elemRefName];
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) requires element rule $elemRefName to be a Seq struct', Context.currentPos()
			);
		final modifierNode: Null<ShapeNode> = elemRule.children.find(child ->
			child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == modifierField
		);
		if (modifierNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" not found on element rule $elemRefName',
				Context.currentPos()
			);
		if (modifierNode.kind != Star)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" must be a Star', Context.currentPos()
			);
		// `base.ref` lives on the Star's element child (the Ref node), not the
		// Star itself — `ShapeBuilder.shapeFieldType` builds `Array<T>` as a
		// Star with `children = [shapeFieldType(T)]` and only the inner Ref
		// carries `base.ref`.
		if (modifierNode.children.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" must have exactly one Star child',
				Context.currentPos()
			);
		final modifierEnumName: Null<String> = modifierNode.children[0].annotations.get(AnnotationKeys.BASE_REF);
		if (modifierEnumName == null)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier field "$modifierField" has no base.ref annotation',
				Context.currentPos()
			);
		final modifierEnum: Null<ShapeNode> = _shape.rules[modifierEnumName];
		if (modifierEnum == null || modifierEnum.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) modifier target $modifierEnumName must be an Alt (enum)', Context.currentPos()
			);
		var staticBranchFound: Bool = false;
		for (branch in modifierEnum.children) if (branch.annotations.get(AnnotationKeys.BASE_CTOR) == staticCtor) {
			staticBranchFound = true;
			break;
		}
		if (!staticBranchFound)
			Context.fatalError(
				'WriterLowering: @:fmt(staticVarSubdivision) static ctor "$staticCtor" not found on enum $modifierEnumName',
				Context.currentPos()
			);
	}

	/**
	 * Shape-aware tail of `sameLineSeparator`: given the shape-aware
	 * switch and `flagBased` sep, layer the body-policy inline probe and
	 * the `semicolonNextLineElse` `;`-tail discriminator on top, then wrap
	 * via `withPadTrailingDrop`. Extracted to keep `sameLineSeparator`
	 * below the complexity gate.
	 */
	private function sameLineSeparatorShapeAware(c: SameLineShapeAwareCtx): Expr {
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
		final inlineSep: Expr = if (_ctx.trivia && c.child.fmtHasFlag('semicolonNextLineElse')) {
			final prevWriteFn: String = writeFnFor(c.prevBody.typePath);
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
	 * ω-leading-trivia-multiline — build the per-element `_t`-scoped
	 * boolean for `@:fmt(multilineWhenLeadingTriviaSpansLines('<metaField>',
	 * '<declField>'))`, OR-ed into the `'multiline'` predicate of every
	 * predicate-gated blank rule. Returns null when the flag is absent.
	 */
	private function buildTriviaMultilineExpr(starNode: ShapeNode): Null<Expr> {
		final triviaMultilineArgs: Null<Array<String>> = starNode.fmtReadStringArgs('multilineWhenLeadingTriviaSpansLines');
		if (triviaMultilineArgs == null) return null;
		if (triviaMultilineArgs.length != 2)
			Context.fatalError(
				'WriterLowering: @:fmt(multilineWhenLeadingTriviaSpansLines) expects exactly 2 string args (metaField, declField), got '
				+ triviaMultilineArgs.length,
				Context.currentPos()
			);
		final pos: Position = Context.currentPos();
		final metaField: String = triviaMultilineArgs[0];
		final declField: String = triviaMultilineArgs[1];
		final metaAccess: Expr = { expr: EField(macro _t.node, metaField), pos: pos };
		final beforeNlAccess: Expr = { expr: EField(macro _t.node, declField + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX), pos: pos };
		return macro (_t.leadingComments.length > 0 || ($metaAccess.length > 0 && $beforeNlAccess));
	}

	/**
	 * Fold one `@:fmt(blankLinesBetweenSameCtor{Tail,Head}Transparent)`
	 * arg-triple (classifierField, ctorName, adapterOptField) into the
	 * per-classifier `transparentByClassifier` accumulator, validating
	 * arity and one-shared-adapter-per-side.
	 */
	private function ingestTransparentArg(
		transparentByClassifier: Map<String, TransparentEntry>, args: Array<String>, isTail: Bool, metaName: String
	): Void {
		if (args.length != 3)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) expects exactly 3 string args (classifierField, ctorName, adapterOptField), got '
				+ args.length,
				Context.currentPos()
			);
		final cf: String = args[0];
		final ctor: String = args[1];
		final adapter: String = args[2];
		var entry: Null<TransparentEntry> = transparentByClassifier[cf];
		if (entry == null) {
			entry = { ctors: [], tailAdapter: null, headAdapter: null };
			transparentByClassifier[cf] = entry;
		}
		if (entry.ctors.indexOf(ctor) < 0) entry.ctors.push(ctor);
		if (isTail) {
			if (entry.tailAdapter != null && entry.tailAdapter != adapter)
				Context.fatalError(
					'WriterLowering: @:fmt($metaName) adapter mismatch for classifier "$cf" — got "${entry.tailAdapter}" and "$adapter'
					+ '"; one shared tail adapter per Star+classifier',
					Context.currentPos()
				);
			entry.tailAdapter = adapter;
		} else {
			if (entry.headAdapter != null && entry.headAdapter != adapter)
				Context.fatalError(
					'WriterLowering: @:fmt($metaName) adapter mismatch for classifier "$cf" — got "${entry.headAdapter}" and "$adapter'
					+ '"; one shared head adapter per Star+classifier',
					Context.currentPos()
				);
			entry.headAdapter = adapter;
		}
	}

	/**
	 * Build the `betweenCtorInfos` + `transitionAcrossInfos` lists from
	 * their arg-lists, threading each classifier's transparent-ctor entry,
	 * then verify every accumulated transparent classifier has a matching
	 * between/transition rule on the same Star.
	 */
	private function buildCtorBlankInfos(
		elemRefName: String, betweenCtorAllArgs: Array<Array<String>>, transitionAcrossAllArgs: Array<Array<String>>,
		transparentByClassifier: Map<String, TransparentEntry>
	): { between: Array<BetweenCtorBlankInfo>, transition: Array<TransitionAcrossInfo> } {
		final betweenCtorInfos: Array<BetweenCtorBlankInfo> = [
			for (args in betweenCtorAllArgs) {
				final classifier: String = args[0];
				final tt: Null<TransparentEntry> = transparentByClassifier[classifier];
				buildBetweenCtorBlankInfo(elemRefName, args, tt != null ? tt.ctors : [], tt?.tailAdapter, tt?.headAdapter);
			}
		];
		final transitionAcrossInfos: Array<TransitionAcrossInfo> = [
			for (args in transitionAcrossAllArgs) {
				final classifier: String = args[0];
				final tt: Null<TransparentEntry> = transparentByClassifier[classifier];
				buildTransitionAcrossInfo(elemRefName, args, tt != null ? tt.ctors : [], tt?.tailAdapter, tt?.headAdapter);
			}
		];
		for (cf in transparentByClassifier.keys()) {
			final hasBetween: Bool = betweenCtorInfos.exists(info -> info.classifierFieldName == cf);
			final hasTransition: Bool = transitionAcrossInfos.exists(info -> info.classifierFieldName == cf);
			if (!hasBetween && !hasTransition)
				Context.fatalError(
					'WriterLowering: @:fmt(blankLinesBetweenSameCtor{Tail,Head}Transparent) classifier "$cf'
					+ '" has no matching @:fmt(blankLinesBetweenSameCtorByLevel) or @:fmt(blankLinesOnTransitionAcross) on the same Star',
					Context.currentPos()
				);
		}
		return { between: betweenCtorInfos, transition: transitionAcrossInfos };
	}

	/**
	 * Struct-level `@:fmt(multiline*)` flag path of `buildMultilinePredicate`:
	 * collect every matching multiline flag on `meta` and OR-fold them into
	 * one predicate (null when none match). Extracted to keep
	 * `buildMultilinePredicate` below the complexity gate.
	 */
	private function buildMultilineMetaPredicate(node: ShapeNode, typeName: String, accessExpr: Expr, meta: Metadata): Null<Expr> {
		final pos: Position = Context.currentPos();
		// Collect every matching struct-level multiline flag and OR-fold
		// them into one predicate. Single first-match-wins precluded
		// composing structural conditions (Anon-Allman binding) with
		// rendering-aware conditions (wrap-cascade fires on a Star field),
		// so a typedef whose body type stays simple but whose declare-site
		// typeParams overflow into a wrap could not be detected as
		// multi-line. Closes the `wrapping/issue_494_type_parameter`
		// boundary between a flat typedef and a typeParam-wrapping typedef.
		final preds: Array<Expr> = [];
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case ECall({ expr: EConst(CIdent('multilineWhenFieldNonEmpty')) }, [{ expr: EConst(CString(field, _)) }]):
					final fieldExpr: Expr = { expr: EField(accessExpr, field), pos: pos };
					preds.push(macro $fieldExpr.length > 0);
				case ECall({ expr: EConst(CIdent('multilineWhenFieldShape')) }, [{ expr: EConst(CString(field, _)) }]):
					final fieldNode: Null<ShapeNode> = findFieldByName(node, field);
					if (fieldNode == null)
						Context.fatalError(
							'WriterLowering: @:fmt(multilineWhenFieldShape) field "$field" not found on $typeName', Context.currentPos()
						);
					final targetType: Null<String> = fieldNode.annotations.get(AnnotationKeys.BASE_REF);
					if (targetType == null) continue;
					final fieldExpr: Expr = { expr: EField(accessExpr, field), pos: pos };
					final inner: Null<Expr> = buildMultilinePredicate(targetType, fieldExpr);
					if (inner != null) preds.push(inner);
				// ω-typedef-between-blank: 4-arg runtime ctor match on a
				// named field PLUS an opt-side runtime equality with a
				// fully-qualified enum literal. Emits
				// `Type.enumConstructor(<accessExpr>.<field>) == <ctorName>
				// && opt.<optField> == <optEnumExpr>`.
				// The opt-gate distinguishes layout modes that drive
				// whether a structurally-bound type renders multi-line
				// — e.g. `HxTypedefDecl` is "multi-line in output" only
				// when the bound type is `Anon` AND `anonTypeLeftCurly`
				// is `BracePlacement.Next` (issue_301 boundary). Avoids
				// spurious blanks under Same / other placements where the
				// same source emits single-line. The 4th arg is parsed
				// as a Haxe expression so `enum abstract` knobs (which
				// fail `Type.enumConstructor`) can be compared directly
				// against their declared constructor.
				case ECall({ expr: EConst(CIdent('multilineWhenFieldCtorAndOpt')) }, [
					{ expr: EConst(CString(field, _)) },
					{ expr: EConst(CString(ctorName, _)) },
					{ expr: EConst(CString(optField, _)) },
					{ expr: EConst(CString(optEnumExprStr, _)) }
				]):
					final fieldExpr: Expr = { expr: EField(accessExpr, field), pos: pos };
					final optAccess: Expr = optFieldAccess(optField);
					final optEnumExpr: Expr = Context.parse(optEnumExprStr, pos);
					preds.push(macro Type.enumConstructor($fieldExpr) == $v{ctorName} && $optAccess == $optEnumExpr);
				// ω-typedef-typeparam-multiline: 3-arg cascade probe on a
				// Star field. Mirror of `WrapList.decideWithLineLengthState`
				// at predicate-eval time, approximating per-item width via
				// `<itemNameField>.length` and the same `(n-1)*(sep+space)`
				// inter-item correction `WrapList.emit` applies. Predicate
				// fires when the cascade would resolve to any non-NoWrap
				// mode, i.e. the typedef's declare-site type parameters
				// would render multi-line. Hardcodes sep width to fork-
				// standard `, ` (2 chars) — every Haxe wrap cascade uses
				// comma separators, so this matches the runtime that
				// `shapeNoWrap` / `shapeFillLine` produce.
				case ECall({ expr: EConst(CIdent('multilineWhenStarFieldWrapsCascade')) }, [
					{ expr: EConst(CString(field, _)) },
					{ expr: EConst(CString(cascadeKnob, _)) },
					{ expr: EConst(CString(itemNameField, _)) }
				]):
					final fieldExpr: Expr = { expr: EField(accessExpr, field), pos: pos };
					final cascadeAccess: Expr = optFieldAccess(cascadeKnob);
					final itemFieldExpr: Expr = { expr: EField(macro _p, itemNameField), pos: pos };
					preds.push(buildStarWrapsCascadePred(fieldExpr, cascadeAccess, itemFieldExpr));
				case _:
			}
		}
		if (preds.length == 0) return null;
		var folded: Expr = preds[0];
		for (i in 1...preds.length) {
			final next: Expr = preds[i];
			folded = macro $folded || $next;
		}
		return folded;
	}

	/**
	 * Enum-dispatch path of `buildMultilinePredicate` (Alt nodes): a switch
	 * over each ctor's `multilineCtor` flag, recursing into the first arg's
	 * type for the multi-line probe. Returns null when no branch is tagged.
	 * Extracted to keep `buildMultilinePredicate` below the complexity gate.
	 */
	private function buildMultilineEnumPredicate(node: ShapeNode, accessExpr: Expr): Null<Expr> {
		final pos: Position = Context.currentPos();
		final cases: Array<Case> = [];
		var anyTagged: Bool = false;
		for (branch in node.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			final arity: Int = branch.children.length;
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			final tagged: Bool = ctorBranchHasFlag(branch, 'multilineCtor');
			final pattern: Expr = if (tagged && arity >= 1) {
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v : macro _];
				{ expr: ECall(ctorIdent, binders), pos: pos };
			} else if (arity == 0) {
				ctorIdent;
			} else {
				{ expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]), pos: pos };
			};
			final body: Expr = if (!tagged)
				macro false;
			else {
				anyTagged = true;
				final argNode: ShapeNode = branch.children[0];
				final argTypeName: Null<String> = argNode.annotations[AnnotationKeys.BASE_REF];
				final inner: Null<Expr> = argTypeName == null ? null : buildMultilinePredicate(argTypeName, macro _v);
				inner ?? macro false;
			};
			cases.push({ values: [pattern], guard: null, expr: body });
		}
		return !anyTagged ? null : { expr: ESwitch(accessExpr, cases, null), pos: pos };
	}

	/**
	 * ω-typedef-typeparam-multiline: build the runtime cascade-probe Expr
	 * for `@:fmt(multilineWhenStarFieldWrapsCascade)` — mirrors
	 * `WrapList.emit`'s width arithmetic (`, ` sep = +2 per non-last item)
	 * over the Star field, firing when `WrapList.decideWithLineLengthState`
	 * resolves to any non-NoWrap mode.
	 */
	private function buildStarWrapsCascadePred(fieldExpr: Expr, cascadeAccess: Expr, itemFieldExpr: Expr): Expr {
		// Width arithmetic mirrors `WrapList.measureItems`: each non-last item
		// contributes `name + sep + space` (= +2 for fork-standard `, `), the last
		// item contributes just `name`. Applied to EVERY measurement the cascade
		// reads — `_sum` (`totalItemLength`), `_maxLen` (`anyItemLength >= n` /
		// `allItemLengths <= n`), `_minLen` (`anyItemLength <= n` /
		// `allItemLengths >= n`) and `_equalLens` (`equalItemLengths`, with the
		// same last-item allowance `measureItems` spells, since that item carries
		// no separator) — so the predicate's answers match `WrapList.emit`'s at
		// runtime. Without sep in maxLen the predicate could undershoot on
		// item-length boundary cases (e.g. item of exactly 49 chars vs threshold
		// 50: predicate false, emit true).
		//
		// The `+ 2` is literal because this predicate's only consumer is a
		// comma-separated Star; a Star with a wider separator would need it
		// threaded, and would silently measure short until then.
		return macro {
			final _arr = $fieldExpr;
			if (_arr == null || _arr.length == 0)
				false;
			else {
				var _sum: Int = 0;
				var _maxLen: Int = 0;
				var _minLen: Int = anyparse.format.wrap.WrapList.MAX_ITEM_LEN;
				var _firstLen: Int = -1;
				var _equalLens: Bool = true;
				final _lastIdx: Int = _arr.length - 1;
				for (_i in 0..._arr.length) {
					final _p = _arr[_i];
					final _raw: Int = ($itemFieldExpr: String).length;
					final _w: Int = _i < _lastIdx ? _raw + 2 : _raw;
					_sum += _w;
					if (_w > _maxLen) _maxLen = _w;
					if (_w < _minLen) _minLen = _w;
					if (_firstLen < 0)
						_firstLen = _w;
					else if (_w != _firstLen && !(_i == _lastIdx && _w + 2 == _firstLen))
						_equalLens = false;
				}
				anyparse.format.wrap.WrapList.decideWithLineLengthState(
					$cascadeAccess, _arr.length, _maxLen, _sum, false, false, _ -> false, 0, _minLen, _equalLens
				) != anyparse.format.wrap.WrapMode.NoWrap;
			}
		};
	}

	/**
	 * Resolve the classifier enum (Alt) rule reached from the element Seq
	 * rule's `fieldName` Ref. Walks the elemRule -> classifierNode -> enumRuleName -> enumRule chain
	 * with its validation gates.
	 */
	private function resolveInterMemberEnumRule(elemRefName: String, fieldName: String): ShapeNode {
		final elemRule: Null<ShapeNode> = _shape.rules[elemRefName];
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) requires element rule $elemRefName to be a Seq struct', Context.currentPos()
			);
		final classifierNode: Null<ShapeNode> = elemRule.children.find(child ->
			child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == fieldName
		);
		if (classifierNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier field "$fieldName" not found on element rule $elemRefName',
				Context.currentPos()
			);
		if (classifierNode.kind != Ref)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier field "$fieldName" must be a plain Ref to an enum rule',
				Context.currentPos()
			);
		final enumRuleName: Null<String> = classifierNode.annotations.get(AnnotationKeys.BASE_REF);
		if (enumRuleName == null)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier field "$fieldName" has no base.ref annotation',
				Context.currentPos()
			);
		final enumRule: Null<ShapeNode> = _shape.rules[enumRuleName];
		if (enumRule == null || enumRule.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt(interMemberBlankLines) classifier target $enumRuleName must be an Alt (enum)', Context.currentPos()
			);
		return enumRule;
	}

	/**
	 * Build the per-ctor switch patterns for a transition-across classifier.
	 * The per-branch loop that
	 * assigns each enum ctor to subset 1 (A) / 2 (B) / 3 (transparent) / 0
	 * (other), binding the first synth arg to `_v0` for matched/transparent
	 * ctors. Instance because `branchSynthExtraArity` reads `isTriviaBearing`.
	 */
	private function buildTransitionAcrossPatterns(c: TransitionAcrossPatternsCtx): TransitionAcrossPatterns {
		final pos: Position = Context.currentPos();
		final patterns: Array<TransitionAcrossPattern> = [];
		final matchedA: Array<String> = [];
		final matchedB: Array<String> = [];
		final transparentMatched: Array<String> = [];
		for (branch in c.enumRule.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			final shapeArity: Int = branch.children.length;
			// In trivia mode, ctors with `@:trailOpt` / `@:lead` close-trailing /
			// `@:fmt(captureSource)` carry a synthesized positional arg appended
			// to the synth ctor (`HxDeclT.TypedefDecl(decl, trailPresent)`). The
			// pattern arity must match the synth ctor's full arity, otherwise
			// the generated switch fails with "Not enough arguments". Helper
			// returns 0 outside trivia mode or for non-bearing enums.
			final arity: Int = shapeArity + branchSynthExtraArity(c.enumRuleName, branch);
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			final inA: Bool = c.ctorNamesA.indexOf(ctorName) >= 0;
			final inB: Bool = !inA && c.ctorNamesB.indexOf(ctorName) >= 0;
			final isTransparent: Bool = !inA && !inB && c.transparentCtorNames.indexOf(ctorName) >= 0;
			if (inA) {
				matchedA.push(ctorName);
				patterns.push({ pattern: transitionPattern(ctorIdent, arity, true, pos), subset: 1 });
			} else if (inB) {
				matchedB.push(ctorName);
				patterns.push({ pattern: transitionPattern(ctorIdent, arity, true, pos), subset: 2 });
			} else if (isTransparent) {
				if (shapeArity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesOnTransitionAcross) transparent ctor "$ctorName'
						+ '" must have arity ≥ 1 (first arg is the wrapper payload bound to _v0 and passed to the head/tail-leaf '
						+ 'classifier adapters); got arity $shapeArity',
						Context.currentPos()
					);
				transparentMatched.push(ctorName);
				patterns.push({
					pattern: { expr: ECall(ctorIdent, [for (i in 0...arity) i == 0 ? macro _v0 : macro _]), pos: pos },
					subset: 3
				});
			} else {
				patterns.push({ pattern: transitionPattern(ctorIdent, arity, false, pos), subset: 0 });
			}
		}
		return {
			patterns: patterns,
			matchedA: matchedA,
			matchedB: matchedB,
			transparentMatched: transparentMatched
		};
	}

	/**
	 * Build the args-list emission call for a postfix Star — the three-way
	 * dispatch between the runtime `WrapList.emit` cascade (`@:fmt(wrapRules)`,
	 * with a hand-built `Keep`-mode Doc for trivia Stars), the Wadler
	 * `fillList` (`@:fmt(fill)`), and the default `sepList`. Instance method because `optFieldAccess` reads `ctx`.
	 */
	private function lowerPostfixSepListCall(c: PostfixStarCtx): Expr {
		// ω-callarg-own-line-comment: a LINE comment anywhere in the list pre-empts
		// the cascade (see `lowerPostfixForceMultiDoc`). Trivia-only — plain mode's
		// `_args` carry no comment slots and `_forceArgMulti` is a constant false.
		final cascade: Expr = lowerPostfixCascadeCall(c);
		if (!c.isTriviaStar) return cascade;
		final forceMulti: Expr = lowerPostfixForceMultiDoc(c);
		return macro _forceArgMulti ? $forceMulti : $cascade;
	}

	/** The wrap-cascade arm of `lowerPostfixSepListCall` (`WrapList.emit` / `fillList` / `sepList`). */
	private function lowerPostfixCascadeCall(c: PostfixStarCtx): Expr {
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
				_shape.root, _ctx.trivia, false, COMPLEX_ITEM_KINDS_PRED, [macro cast _args]
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
	 * Compute the call-arg `(`/`)` inner-padding Docs for a postfix Star.
	 * Honours `@:fmt(callParensInside)` (runtime `callParensInsideOpen` /
	 * `callParensInsideClose`) and, for a `(`-open ctor, the
	 * compress-successive-parenthesis policy (a runtime space before a
	 * leading object-literal arg). Instance method because `policyInsideSpace` reads `ctx`.
	 */
	private function lowerPostfixCallInside(branch: ShapeNode, postfixOp: String, isTriviaStar: Bool): { open: Expr, close: Expr } {
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

	/**
	 * Build the body's writeCall, optionally wrapping it in the
	 * `inlineBlockBodyIfFlag` runtime flatten (ω-expression-if-with-blocks).
	 *
	 */
	private function buildBodyWriteCall(opts: WrapBodyOpts): Expr {
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
		return foldSsbTrailingComment(base, opts.ssbTrailCommentExpr);
	}

	/**
	 * Resolve the runtime body-policy flag Expr — the four-stage chain:
	 * expr-position dual-flag (ω-issue-257), single-line-vs-multi (ω-return-
	 * body-single-line), per-ctor policy overrides (ω-untyped-body-stmt-
	 * override), and the no-sibling fallback (ω-expression-if-next).
	 */
	private function resolveBodyOptFlag(opts: WrapBodyOpts): Expr {
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
	private function arrowValueIfPolicy(opts: WrapBodyOpts, resolved: Expr, samePat: Expr): Expr {
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
	 * Wrap a body Expr in the conditional value-expr `Nest(_cols, body)` per
	 * `@:fmt(indentValueIfCtor('<ctor>', '<optField>'))` — the ω-issue-257
	 * return-same-indent-value-expr / ω-value-if-block-body-no-indent rule.
	 * Returns `bodyExpr` unchanged when `ifExprIndentArgs` is null.
	 */
	private function wrapIfExprNest(bodyExpr: Expr, ifExprIndentArgs: Null<Array<String>>, bodyValueExpr: Expr): Expr {
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
	 * Build the `Same`-policy kw→body inline separator (ω-issue-316 / ω-tryBody
	 * kwOwnsInlineSpace). Returns the `kwPolicyInlineSep` (null when no
	 * `kwPolicy` knob) and `sameSepNb` (kwGapDoc with kw-trivia slots, the
	 * kw-policy switch, or the default `_dop(' ')`).
	 */
	private function buildBodyKwSep(opts: WrapBodyOpts, hasKwSlots: Bool): { kwPolicyInlineSep: Null<Expr>, sameSepNb: Expr } {
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
	private function buildElseIfCommentReflowLayout(opts: WrapBodyOpts, shared: BodyWrapShared, sameLayoutExpr: Expr): Expr {
		final afterKwExpr: Null<Expr> = opts.afterKwExpr;
		final kwLeadingExpr: Null<Expr> = opts.kwLeadingExpr;
		if (opts.elseIfCommentReflow != true || !_ctx.trivia || afterKwExpr == null || kwLeadingExpr == null) return sameLayoutExpr;
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
	 * Build the `Same`-policy layout Expr (ω-returnbody-widthaware + the
	 * value-expr Nest wrap).
	 */
	private function buildBodySameLayout(opts: WrapBodyOpts, shared: BodyWrapShared): Expr {
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
	private function buildBodyNextLayout(opts: WrapBodyOpts, shared: BodyWrapShared): Expr {
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
	private function buildBodyBlockLayout(opts: WrapBodyOpts, shared: BodyWrapShared): Expr {
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
	private function buildBodyFitExpr(opts: WrapBodyOpts, shared: BodyWrapShared): Expr {
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
		final fitInnerExpr: Expr = if (opts.constructFitBody == true)
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
	 * Build the `Keep`-policy layout Expr (ω-keep-policy) — runtime-dispatched
	 * between same and next layouts via the parser's `bodyOnSameLine` slot,
	 * with the block-ctor `blockLayoutExpr` route (ω-D8-keep-block-trivia) and
	 * the `elseIf == Next` override (ω-D8-keep-elseif-override).
	 */
	private function buildBodyKeepLayout(
		opts: WrapBodyOpts, layouts: BodyLayouts, blockSplit: { tagged: Array<Expr>, untagged: Array<Expr> }, ifStmtPattern: Null<Expr>
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
		final tests: { same: Null<Expr>, next: Null<Expr> } = buildElseSwitchTests(opts);
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
	private function buildBodyCoreWrap(
		opts: WrapBodyOpts, optFlag: Expr, layouts: BodyLayouts, keepLayoutExpr: Expr,
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
		final tests: { same: Null<Expr>, next: Null<Expr> } = buildElseSwitchTests(opts);
		final esSame: Null<Expr> = tests.same;
		final esNext: Null<Expr> = tests.next;
		final effPolicy: Expr = esSame == null ? optFlag : macro ($esSame ? $samePat : ($esNext ? $nextPat : $optFlag));
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
	private function wrapBodyAfterTrail(
		opts: WrapBodyOpts, coreWrapExpr: Expr, writeCall: Expr, blockSplit: { tagged: Array<Expr>, untagged: Array<Expr> }
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
	private function wrapBodyAllman(opts: WrapBodyOpts, wrapExpr: Expr, writeCall: Expr): Expr {
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
	private function wrapBodyMetaBlockGlue(opts: WrapBodyOpts, finalWrapExpr: Expr, sameLayoutExpr: Expr): Expr {
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
	private function wrapLoopBodyIfElseNext(opts: WrapBodyOpts, fitInnerExpr: Expr): Expr {
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
	 * Ternary branch (`@:fmt`-driven `ternary.op`): dispatch to the
	 * chain-emit engine with a degenerate 3-item / 2-op chain. Like the infix
	 * dispatch it CONSUMES `_callArgChainNest` (see the body) — but it never
	 * suppresses its OWN Nest, so the flag is cleared, not honoured.
	 */
	private function lowerTernaryBranch(c: LowerBranchCtx): Expr {
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
		final condTrailAccess: Null<Expr> = _ctx.trivia ? altSlotAccess(branch, branch.children.length, argNames, TernaryCondTrail) : null;
		final thenTrailAccess: Null<Expr> = _ctx.trivia ? altSlotAccess(branch, branch.children.length, argNames, TernaryThenTrail) : null;
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

	/**
	 * Prefix branch (`prefix.op`): `op operand`.
	 */
	private function lowerPrefixBranch(c: LowerBranchCtx): Expr {
		final prefixOp: String = c.branch.annotations.get(AnnotationKeys.PREFIX_OP);
		final operandCall: Expr = makeWriteCall(c.writeFnName, macro $i{c.argNames[0]}, c.hasPratt, c.precPostfix);
		return macro _dc([_dt($v{prefixOp}), $operandCall]);
	}

	/**
	 * Postfix branch (`postfix.op`): unary postfix (`x++`), bracketed
	 * access (`arr[i]`), suffix-Ref, or Star-suffix forms.
	 */
	private function lowerPostfixBranch(c: LowerBranchCtx): Expr {
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
			return lowerPostfixStar(branch, typePath, writeFnName, hasPratt, argNames, operandCall);
		if (children.length == 2) {
			final suffixRef: String = children[1].annotations.get(AnnotationKeys.BASE_REF);
			final suffixFn: String = writeFnFor(suffixRef);
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
			final opSpaceAccess: Null<Expr> = _ctx.trivia ? altSlotAccess(branch, children.length, argNames, PostfixOpSpace) : null;
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
	 * Infix branch (`pratt.prec`): binary operator emit. Resolves the
	 * operator shape (tight / assign / chain / group-wrap) and dispatches
	 * to the matching sub-builder; the group/line/nest fallback stays
	 * inline.
	 */
	private function lowerInfixBranch(c: LowerBranchCtx): Expr {
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
		if (isTight || isAssign) return lowerInfixTightAssign(c);
		if (isChainBool || isChainAddSub || isChainNullCoal) return lowerInfixChain(c);
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
			? makeWriteCall(writeFnFor(rightRef), macro $i{argNames[1]}, false, -1, rightOptExpr)
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
		final rhsTrailAccess: Null<Expr> = _ctx.trivia ? altSlotAccess(branch, children.length, argNames, ChainRhsTrail) : null;
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
	 * Infix tight / assign sub-builder: tight operators (`...`, arrow
	 * type) and assignment-class operators (prec 0) keep flat emission.
	 *
	 */
	private function lowerInfixTightAssign(c: LowerBranchCtx): Expr {
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
			? makeWriteCall(writeFnFor(rightRef), macro $i{argNames[1]}, false, -1, rightOptExpr)
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
			assignEmitExpr(c, opText, isAsymmetric, leftCtx, rightCtx, leftCall, rightOptExpr, rightEmit)
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
	private function assignEmitExpr(
		c: LowerBranchCtx, opText: String, isAsymmetric: Bool, leftCtx: Int, rightCtx: Int, leftCall: Expr, rightOptExpr: Null<Expr>,
		rightEmit: Expr
	): Expr {
		final plainExpr: Expr = macro _dc([
			$leftCall,
			_dt(' '),
			_dt($v{opText}),
			_dop(' '),
			$rightEmit,
		]);
		if (opText != '=' || isAsymmetric) return plainExpr;
		final argTypeCT: ComplexType = ruleValueCT(c.typePath);
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
	 * Infix chain sub-builder (ω-binop-wraprules): `||`/`&&`
	 * (opBoolChain) and `+`/`-` (opAddSubChain) gather the full
	 * same-class subtree into a flat `(items, ops)` pair, run the cascade
	 * once, and emit one `BinaryChainEmit` shape. The `_gather` switch is
	 * built inline (vs an external helper) so its `case Or(...)` /
	 * `case Add(...)` patterns resolve against the current writer's value
	 * type (`HxExpr` plain / `HxExprT` trivia).
	 */
	private function lowerInfixChain(c: LowerBranchCtx): Expr {
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
		final argTypeCT: ComplexType = ruleValueCT(typePath);
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
		final outerChainNl: Null<Expr> = _ctx.trivia ? altSlotAccess(branch, children.length, argNames, ChainNewline) : null;
		// All four chain ctors (Or/And/Add/Sub) carry `captureChainNewline`,
		// so `outerChainNl` is non-null in Trivia mode; the `!= null` guard
		// keeps `_breaks` declaration and the gatherSwitch's `_breaks.push`
		// strictly in lockstep (no half-wired state).
		final threadBreaks: Bool = _ctx.trivia && outerChainNl != null;
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
		final outerAfterComment: Null<Expr> = _ctx.trivia ? altSlotAccess(branch, children.length, argNames, ChainAfterComment) : null;
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
		final outerLeadComment: Null<Expr> = _ctx.trivia ? altSlotAccess(branch, children.length, argNames, ChainLeadComment) : null;
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
	 * Builds the `_gather` switch body for `lowerInfixChain`: walks the
	 * same-class chain ctors (Or/And or Add/Sub), pushing operators (and
	 * per-operand source-newline breaks in Trivia mode) and recursing on
	 * operands. Leaf operands fall through to `$leafCall`. Inlined as a
	 * macro Expr so its `case Or(...)` patterns resolve against the
	 * current writer's value type.
	 */
	private function infixChainGatherSwitch(isChainBool: Bool, isChainNullCoal: Bool, threadBreaks: Bool, leafCall: Expr): Expr {
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
	 * Case 3 — single-arg Ref branch (kw-led `T(value:Ref)`): the largest
	 * enum-branch shape. Resolves the sub-call opt frame, the bodyPolicy /
	 * indent wrap, the body-source-capture gate, the kw / lead / trail
	 * parts, the `@:wrap` paren shape, and the conditional-marker scope.
	 *
	 */
	private function lowerKwRefBranch(c: LowerBranchCtx): Expr {
		final branch: ShapeNode = c.branch;
		final typePath: String = c.typePath;
		final hasPratt: Bool = c.hasPratt;
		final argNames: Array<String> = c.argNames;
		final children: Array<ShapeNode> = branch.children;
		final refName: String = children[0].annotations.get(AnnotationKeys.BASE_REF);
		final subFn: String = writeFnFor(refName);
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
		final kwNewlineExpr: Null<Expr> = _ctx.trivia && isTriviaBearing(typePath)
			? altSlotAccess(branch, children.length, argNames, KwNewline)
			: null;
		final ctorOptArg: Expr = kwRefCtorOptArg(c, kwNewlineExpr);
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
		final bodyOnSameLineExpr: Null<Expr> = _ctx.trivia && isTriviaBearing(typePath)
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
		final wrapOpenNewlineExpr: Null<Expr> = _ctx.trivia && isTriviaBearing(typePath)
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
			? bodyPolicyWrap({
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
		final bodyExpr: Expr = kwRefBodyExpr(c, policyWrapped, subCall, indentArgs);

		// Resolve the kw-trailing-space behaviour (strip vs runtime-switched
		// space) and assemble the kw / lead / body / trail parts — see
		// kwRefKwTrailSpace and kwRefParts for the per-flag detail.
		final kwTrail: { strip: Bool, space: Null<Expr> } = kwRefKwTrailSpace(c, refName, ctorBodyPolicyFlag);
		final parts: Array<Expr> = kwRefParts(c, bodyExpr, kwTrail.space, kwTrail.strip);
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
		final wrapDoc: Null<Expr> = kwRefWrapShape(c, parts, wrapOpenNewlineExpr);
		return wrapDoc ?? kwRefFinalDoc(c, parts);
	}

	/**
	 * Lit / kw zero-or-one-arg branches (Cases 0/1/2): zero-arg kw
	 * (`@:kw` no children), zero-arg single lit, and the multi-lit Bool
	 * (`true`/`false` pair). Returns the matched Doc Expr, or null when
	 * the branch is none of these (the dispatcher then falls through to
	 * the Star / Ref / wrap shapes).
	 */
	private function lowerLitKwBranch(c: LowerBranchCtx): Null<Expr> {
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
	 * `@:wrap(open, close)` paren shape (Case 3 sub-branch): a no-kw
	 * branch with both lead and trail set renders as a Group whose break
	 * shape lands the close delimiter on its own line. Returns the wrap
	 * Doc Expr, or null when the branch is not the wrap shape (the caller
	 * then falls through to the plain Case-3 concat).
	 */
	private function kwRefWrapShape(c: LowerBranchCtx, parts: Array<Expr>, wrapOpenNewlineExpr: Null<Expr>): Null<Expr> {
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
	private function kwRefWrapHardFlatten(leadDoc: Expr, innerDoc: Expr, trailDoc: Expr, wrapOpenNewlineExpr: Null<Expr>): Expr {
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
	private function kwRefWrapSourceNewline(leadDoc: Expr, innerDoc: Expr, trailDoc: Expr, wrapOpenNewlineExpr: Null<Expr>): Expr {
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
	private function kwRefCtorOptArg(c: LowerBranchCtx, kwNewlineExpr: Null<Expr>): Expr {
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
				_shape.root, _ctx.trivia, false, 'operandIsBlockExpr', [operandAccess]
			);
			optExpr = macro ($operandIsBlock ? _clearExprPosition($optExpr, opt) : $optExpr);
		}
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
		if (parenHardFlatten && _ctx.trivia) optExpr = macro _setKeepChainInParen($optExpr, true, opt);
		return kwNewlineExpr != null ? macro _setVarKwNewline($optExpr, $kwNewlineExpr, opt) : optExpr;
	}

	/**
	 * Reads + arity-splits the ctor's `@:fmt(indentValueIfCtor(...))`
	 * entries (Case 3): the 3-arg form `(ctorName, optField,
	 * leftCurlyField)` feeds the ObjectLit-indent path, the 2-arg form
	 * `(ctorName, optField)` feeds the IfExpr-indent path. At most one of
	 * each per ctor (else a macro fatalError).
	 */
	private function kwRefIndentEntries(branch: ShapeNode): { indentArgs: Null<Array<String>>, ifExprIndentArgs: Null<Array<String>> } {
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
	private function kwRefKwTrailSpace(
		c: LowerBranchCtx, refName: String, ctorBodyPolicyFlag: Null<String>
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
		final stripKwTrailingSpace: Bool = ctorBodyPolicyFlag != null || subStructStartsWithBodyPolicy(refName)
			|| subStructStartsWithBodyBreak(refName) || subStructStartsWithBareBodyBreaks(refName) || subStructStartsWithTightLead(refName)
			|| branch.fmtHasFlag('tightKw') || (leadText != null && !leadIsWord && !branch.fmtHasFlag('spaceBeforeLead'));
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
	private function kwRefParts(c: LowerBranchCtx, bodyExpr: Expr, kwTrailSpace: Null<Expr>, stripKwTrailingSpace: Bool): Array<Expr> {
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
						_shape.root, _ctx.trivia, false, 'condSpliceRawWrapsCases', [rawAccess]
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
			final isTriviaTrailOpt: Bool = _ctx.trivia && TriviaTypeSynth.isAltTrailOptBranch(branch);
			final trailEmit: String = branch.fmtHasFlag('spaceBeforeTrail') ? ' $trailText' : trailText;
			final trailExpr: Expr = if (isTriviaTrailOpt) {
				final flagAccess: Expr = macro $i{argNames[1]};
				optionalSemicolonWrap(branch, trailEmit, argNames[0], flagAccess) ?? macro $flagAccess ? _dt($v{trailEmit}) : _de();
			} else {
				trailOptShapeGateWrap(branch, trailEmit, argNames[0]) ?? macro _dt($v{trailEmit});
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
	private function kwRefBodyExpr(c: LowerBranchCtx, policyWrapped: Expr, subCall: Expr, indentArgs: Null<Array<String>>): Expr {
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
		final captureSourceOpt: Null<String> = _ctx.trivia ? branch.fmtReadString('captureSource') : null;
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
	private function kwRefFinalDoc(c: LowerBranchCtx, parts: Array<Expr>): Expr {
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
		final case3Doc: Expr = c.branch.fmtHasFlag('condExprFitGroup') && _ctx.trivia
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
	 * omega-arrow-value-if-reflow - struct-level wrap for a type carrying
	 * `@:fmt(arrowValueIfReflow('<knobField>', '<spineField>', '<spineCtor>'))`
	 * (sole consumer: `HxIfExpr`).
	 *
	 * Emits two things around the struct's assembled Doc:
	 *
	 *  - the gate locals, declared BEFORE the Doc is built so the field-level
	 *    sites inside it (`arrowValueIfPolicy` on both branches, the pre-`else`
	 *    gap in `beforeKwSeparator`, `arrowValueIfBlockOpt` on both branch
	 *    opt-fanouts) read one runtime answer. `_aifReflow` fires when the
	 *    config knob is on, the node sits in an arrow-lambda body
	 *    (`opt._inArrowLambdaBody`), no ANCESTOR member of the chain already
	 *    refused (`opt._arrowValueIfBlocked`), and no member from here DOWN the
	 *    `else`-spine carries a captured comment;
	 *  - a `Group` around the whole node, which turns the soft `Line` before
	 *    each `else` into the chain's single flat-vs-broken decision.
	 *
	 * The Group is gated on `!opt._inValueIfBranch`, which is what
	 * distinguishes the OUTERMOST chain member from the nested `else if (...)`
	 * ones: the arrow body's opt has the flag cleared (`_setExprPosition` runs
	 * on the way in), while every `else`-branch descent sets it via
	 * `propagateValueIfBranch`. So one group spans the whole chain and the
	 * nested members contribute only their soft `Line`s - nested groups would
	 * let an inner `else if ... else ...` tail re-join while the outer broke.
	 *
	 * The group is NOT additionally gated on the Doc being able to render flat.
	 * A body that cannot (a `{ ... }` branch) makes the group commit to its
	 * break branch, which is the same output the bare soft `Line`s would give -
	 * while skipping the group would ALSO skip nothing, since the forced-`Same`
	 * policies and the soft separators are already in the Doc by then. The
	 * earlier `flatLength != -1` conjunct was measured to cost `} else {`
	 * cuddling on block-bodied branches for no gain.
	 *
	 * Returns `dcExpr` untouched for every type without the meta.
	 */
	private function arrowValueIfReflowWrap(node: ShapeNode, dcExpr: Expr): Expr {
		final args: Null<Array<String>> = node.fmtReadStringArgs('arrowValueIfReflow');
		if (args == null) return dcExpr;
		if (args.length != 3 && args.length != FIT_KNOB_ARG_COUNT)
			Context.fatalError(
				'WriterLowering: @:fmt(arrowValueIfReflow) expects 3 or 4 string args (knobField, spineField, spineCtor'
				+ ', [fitKnobField]), got ${args.length}',
				Context.currentPos()
			);
		final knobAccess: Expr = optFieldAccess(args[0]);
		// omega-value-if-fit: the optional 4th arg names the sibling knob that re-flows EVERY
		// value-if rather than only an arrow body. Absent, the local folds to a constant `false` and
		// every expression below collapses to the arrow-only shape, so a 3-arg site stays byte-inert.
		final fitAccess: Expr = args.length == FIT_KNOB_ARG_COUNT ? optFieldAccess(args[3]) : macro false;
		final spineCleanExpr: Expr = arrowValueIfSpineCleanExpr(node, args[1], args[2]);
		final branchCapExpr: Expr = arrowValueIfBranchCapExpr(node, args[1], args[2]);
		return macro {
			final _aifGate: Bool = $knobAccess && opt._inArrowLambdaBody;
			// The arrow gate is checked FIRST and excludes the fit gate: a chain in an arrow body
			// under both knobs keeps the arrow shape (branch values glued to their conditions),
			// the more specific answer for that position.
			final _vifGate: Bool = !_aifGate && $fitAccess && opt._inExprPosition;
			final _anyGate: Bool = _aifGate || _vifGate;
			// ONE spine walk for both gates -- short-circuited by `_anyGate`, so a file compiled with
			// neither knob never runs it. `_aifReflow` keeps its exact old value when the fit knob is
			// off, since `_vifGate` is then false and `_anyGate` collapses to `_aifGate`.
			final _aifClean: Bool = _anyGate && !opt._arrowValueIfBlocked && !opt._arrowValueIfElemTrailComment && $spineCleanExpr;
			final _aifReflow: Bool = _aifGate && _aifClean;
			// The cap refuses the chain as a WHOLE: `_aifBlocked` below turns a refusal here into a
			// refusal for every nested member, so a capped 3-branch chain cannot render with its
			// 2-branch tail collapsed and its head in policy layout.
			final _vifFit: Bool = _vifGate && _aifClean && $branchCapExpr;
			// Two comment positions live outside the node: one on the branch
			// VALUE's own slot (a call's `closeTrailing`), which the spine walk
			// now asks for, and one on the enclosing list element, which arrives
			// as `_arrowValueIfElemTrailComment`. Both sit after the chain's LAST
			// value, where the node has no field of its own left to carry them.
			//
			// The refusal is chain-wide in BOTH directions: the spine walk above
			// covers a comment on this member or any member below it, and
			// `_aifBlocked` (read by `arrowValueIfBlockOpt` on the branch
			// descents) carries the verdict down to members the walk already
			// judged, so an ANCESTOR's comment reaches them too. Only ever true
			// with the knob ON, so the OFF path is byte-inert.
			final _aifBlocked: Bool = _anyGate && !_aifReflow && !_vifFit;
			final _aifDoc: anyparse.core.Doc = $dcExpr;
			(_aifReflow || _vifFit) && !opt._inValueIfBranch ? _dg(_aifDoc) : _aifDoc;
		};
	}

	/**
	 * omega-arrow-value-if-reflow - the no-comment gate, decided over the whole
	 * `else`-SPINE rather than over this node alone.
	 *
	 * A comment sits on ONE member of an `else if` chain, but each member runs
	 * its own copy of this gate, so a per-node answer splits the chain: the
	 * member holding the comment keeps its policy shape while the rest re-flows,
	 * and the output carries both forms at once. The model already carries the
	 * spine - the optional `<spineField>` is the next member wrapped in the
	 * `<spineCtor>` constructor - so the walk asks every member from here down
	 * and folds one answer.
	 *
	 * Emitted as an iterative walk rather than a recursive helper because the
	 * generated writer has no place to hang a per-type static: the cursor starts
	 * at `value` and the spine constructor's payload has that same type, so the
	 * reassignment types itself with no annotation. `break` inside the `switch`
	 * leaves the LOOP (Haxe `switch` has no fallthrough), which is how a
	 * non-`<spineCtor>` tail ends the walk.
	 *
	 * Plain (non-trivia) mode captures no comments and synthesises no slots, so
	 * `arrowValueIfNoCommentExpr` degrades to `true` and the walk with it.
	 */
	private function arrowValueIfSpineCleanExpr(node: ShapeNode, spineField: String, spineCtor: String): Expr {
		final ownClean: Expr = arrowValueIfNoCommentExpr(node, macro _aifCur);
		final spineNode: Null<ShapeNode> = findFieldByName(node, spineField);
		if (spineNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt(arrowValueIfReflow) spineField "$spineField" not found on the struct', Context.currentPos()
			);
		final spineRef: Null<String> = spineNode.annotations.get(AnnotationKeys.BASE_REF);
		final capture: Null<Expr> = spineRef == null ? null : ctorCapturePattern(spineRef, spineCtor, '_aifInner');
		if (capture == null) return macro {
			final _aifCur = value;
			$ownClean;
		};
		final spineAccess: Expr = { expr: EField(macro _aifCur, spineField), pos: Context.currentPos() };
		final stepCases: Array<Case> = [
			{ values: [capture], expr: macro _aifCur = _aifInner, guard: null },
			{ values: [macro _], expr: macro break, guard: null }
		];
		final stepSwitch: Expr = { expr: ESwitch(macro _aifNext, stepCases, null), pos: Context.currentPos() };
		return macro {
			var _aifCur = value;
			var _aifClean: Bool = true;
			while (true) {
				if (!$ownClean) {
					_aifClean = false;
					break;
				}
				final _aifNext = $spineAccess;
				if (_aifNext == null) break;
				$stepSwitch;
			}
			_aifClean;
		};
	}

	/**
	 * omega-value-if-fit branch cap - the runtime gate `_vifFit` folds in: true when no cap is
	 * configured, else the chain's branch count measured against it.
	 *
	 * A SECOND spine walk, deliberately not folded into `arrowValueIfSpineCleanExpr` -- that one runs
	 * under `_anyGate` (either knob), while the count must run only when the fit knob is on AND a cap
	 * is set, which the `||` short-circuit here gives it for free. Folding them would pay the count on
	 * every arrow-knob file for an answer nothing reads.
	 */
	private function arrowValueIfBranchCapExpr(node: ShapeNode, spineField: String, spineCtor: String): Expr {
		final countExpr: Expr = arrowValueIfBranchCountExpr(node, spineField, spineCtor);
		return macro opt.expressionIfFitMaxBranches <= 0 || $countExpr <= opt.expressionIfFitMaxBranches;
	}

	/**
	 * omega-value-if-fit branch cap - counts the VALUE BRANCHES of an `else`-spine: `if (c) a else b`
	 * is 2, `if (c) a else if (d) b else e` is 3, and a trailing-`else`-less `if (c) a else if (d) b`
	 * is 2 as well.
	 *
	 * Same iterative spine walk as `arrowValueIfSpineCleanExpr` (see there for why it is emitted
	 * inline rather than as a per-type static): one member per `if` keyword, plus one for the final
	 * `else` value when the innermost member has an `else` that is not itself a chain member. A
	 * grammar whose spine field cannot be captured answers from the direct sibling alone, which is
	 * the no-chain shape and therefore the layout-preserving direction.
	 */
	private function arrowValueIfBranchCountExpr(node: ShapeNode, spineField: String, spineCtor: String): Expr {
		final spineNode: Null<ShapeNode> = findFieldByName(node, spineField);
		if (spineNode == null) return macro 1;
		final spineAccess: Expr = { expr: EField(macro _vifCur, spineField), pos: Context.currentPos() };
		final spineRef: Null<String> = spineNode.annotations.get(AnnotationKeys.BASE_REF);
		final capture: Null<Expr> = spineRef == null ? null : ctorCapturePattern(spineRef, spineCtor, '_vifInner');
		if (capture == null) {
			final directAccess: Expr = { expr: EField(macro value, spineField), pos: Context.currentPos() };
			return macro $directAccess != null ? 2 : 1;
		}
		final stepCases: Array<Case> = [
			{
				values: [capture],
				expr: macro {
					_vifCur = _vifInner;
					_vifN++;
				},
				guard: null
			},
			{ values: [macro _], expr: macro break, guard: null }
		];
		final stepSwitch: Expr = { expr: ESwitch(macro _vifNext, stepCases, null), pos: Context.currentPos() };
		return macro {
			var _vifCur = value;
			var _vifN: Int = 1;
			while (true) {
				final _vifNext = $spineAccess;
				if (_vifNext == null) break;
				$stepSwitch;
			}
			$spineAccess != null ? _vifN + 1 : _vifN;
		};
	}

	/**
	 * omega-arrow-value-if-reflow - `findCtorPattern` with a BINDING in the
	 * first constructor slot instead of a wildcard, so the spine walk can step
	 * onto the payload it just matched. Every remaining slot stays `_`.
	 */
	private function ctorCapturePattern(bodyTypePath: String, ctorName: String, captureName: String): Null<Expr> {
		final rule: Null<ShapeNode> = _shape.rules[bodyTypePath];
		if (rule == null || rule.kind != Alt) return null;
		for (branch in rule.children) {
			final branchCtor: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (branchCtor != ctorName) continue;
			final arity: Int = branch.children.length + branchSynthExtraArity(bodyTypePath, branch);
			if (arity == 0) return null;
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ruleCtorPath(bodyTypePath, branchCtor));
			final ctorArgs: Array<Expr> = [macro $i{captureName}].concat([for (_ in 1...arity) macro _]);
			return { expr: ECall(ctorRef, ctorArgs), pos: Context.currentPos() };
		}
		return null;
	}

	/**
	 * omega-arrow-value-if-reflow - the no-comment half of the `_aifReflow`
	 * gate: an AND-fold over every trivia slot of `node` that can hold a
	 * captured comment, so a chain carrying one refuses the reflow.
	 *
	 * The slot set is derived from the same three predicates
	 * `TriviaTypeSynth` gates the slots themselves on, rather than from a
	 * hand-listed field name per grammar: an optional-kw field owns the four
	 * kw-gap slots (`AfterKw` / `KwLeading` / `BeforeKwLeading` /
	 * `BeforeKwTrailing`), a bare non-first Ref owns `BeforeLeading`, and a
	 * `@:trail`-bearing Ref owns `AfterTrail`. For `HxIfExpr` that is exactly
	 * the six places a `//` can sit inside `if (c) a else b`.
	 *
	 * Plain (non-trivia) mode captures no comments and synthesises no slots,
	 * so the fold degrades to `true`.
	 */
	private function arrowValueIfNoCommentExpr(node: ShapeNode, rootExpr: Expr): Expr {
		if (!_ctx.trivia) return macro true;
		final pos: Position = Context.currentPos();
		var pred: Expr = macro true;
		for (child in node.children) {
			final fieldName: Null<String> = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			if (fieldName == null) continue;
			for (slot in arrowValueIfCommentSlots(child, node)) {
				final access: Expr = { expr: EField(rootExpr, fieldName + slot.suffix), pos: pos };
				pred = slot.isList ? macro $pred && $access.length == 0 : macro $pred && $access == null;
			}
			final valueClean: Expr = arrowValueIfValueTrailCleanExpr(child, rootExpr);
			pred = macro $pred && $valueClean;
		}
		return pred;
	}

	/**
	 * omega-arrow-value-if-reflow - the comment position the slot fold above
	 * cannot reach: one captured on the branch VALUE itself
	 * (`else tokenError() // handlers`).
	 *
	 * A trailing comment lands on the LAST node that can hold it, so which
	 * slot owns it depends on what the branch value is. A literal owns none,
	 * and the comment travels up to the enclosing list element - that half is
	 * `_arrowValueIfElemTrailComment`'s. A call owns one: the `closeTrailing`
	 * synth param every trivia-collecting postfix Star gets, which its own
	 * writer re-emits through `trailingCommentDocGuarded`. The `if` node holds
	 * only the branch's Ref, so this half asks the VALUE.
	 *
	 * Emitted as a switch over the branch type's Alt, one case per ctor that
	 * owns the slot (`Call` alone, for `HxExpr`) - the ctor arity comes from
	 * the shape, so a synth-param change is a compile error here rather than a
	 * silent wrong-slot read. Degrades to `true` for a non-Alt / non-trivia
	 * branch and for plain mode, which synthesises no slots at all.
	 */
	@:access(anyparse.macro.TriviaTypeSynth)
	private function arrowValueIfValueTrailCleanExpr(child: ShapeNode, rootExpr: Expr): Expr {
		final fieldName: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final refPath: Null<String> = child.kind == Ref ? child.annotations[AnnotationKeys.BASE_REF] : null;
		if (fieldName == null || refPath == null || !isTriviaBearing(refPath)) return macro true;
		final rule: Null<ShapeNode> = _shape.rules[refPath];
		if (rule == null || rule.kind != Alt) return macro true;
		final pos: Position = Context.currentPos();
		final cases: Array<Case> = [];
		for (branch in rule.children) {
			final trailIndex: Int = altCloseTrailingParamIndex(branch);
			if (trailIndex < 0) continue;
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ruleCtorPath(refPath, branch.annotations.get(AnnotationKeys.BASE_CTOR)));
			final arity: Int = branch.children.length + TriviaTypeSynth.countAltExtras(branch);
			final args: Array<Expr> = [for (i in 0...arity) i == trailIndex ? macro _aifValueTrail : macro _];
			cases.push({
				values: [{ expr: ECall(ctorRef, args), pos: pos }],
				expr: macro _aifValueTrail == null,
				guard: null
			});
		}
		if (cases.length == 0) return macro true;
		final access: Expr = { expr: EField(rootExpr, fieldName), pos: pos };
		final switchExpr: Expr = { expr: ESwitch(access, cases, macro true), pos: pos };
		// An optional branch is `Null<T>`, and a `case _` default does NOT catch
		// null - the guard is what keeps the switch off a null subject.
		return macro $access == null ? true : $switchExpr;
	}

	/**
	 * omega-arrow-value-if-reflow - index of the `closeTrailing:Null<String>`
	 * synth param on an Alt branch, or `-1` when the branch owns none. The slot
	 * exists exactly for a postfix Star that collects trivia (the gate
	 * `lowerPostfixTailExpr` reads it under), and the synth params follow the
	 * declared ones, so the first of them sits at the child count.
	 */
	private function altCloseTrailingParamIndex(branch: ShapeNode): Int {
		final postfixOp: Null<String> = branch.annotations[AnnotationKeys.POSTFIX_OP];
		if (postfixOp == null || branch.children.length == 0) return -1;
		final star: ShapeNode = branch.children[branch.children.length - 1];
		return star.kind != Star || star.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] != true ? -1 : branch.children.length;
	}

	/**
	 * omega-arrow-value-if-reflow - the comment-bearing trivia slots `child`
	 * owns, as `(suffix, isList)` pairs. `isList` picks the emptiness test:
	 * an `Array<String>` slot is empty at `length == 0`, a `Null<String>` one
	 * at `null`. Mirrors `TriviaTypeSynth`'s own synth gates.
	 */
	@:access(anyparse.macro.TriviaTypeSynth)
	private function arrowValueIfCommentSlots(child: ShapeNode, node: ShapeNode): Array<{ suffix: String, isList: Bool }> {
		final slots: Array<{ suffix: String, isList: Bool }> = [];
		if (TriviaTypeSynth.isOptionalKw(child)) {
			slots.push({ suffix: TriviaTypeSynth.AFTER_KW_SUFFIX, isList: false });
			slots.push({ suffix: TriviaTypeSynth.KW_LEADING_SUFFIX, isList: true });
			slots.push({ suffix: TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX, isList: true });
			slots.push({ suffix: TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX, isList: false });
		}
		if (TriviaTypeSynth.isBareNonFirstRef(child, node)) slots.push({ suffix: TriviaTypeSynth.BEFORE_LEADING_SUFFIX, isList: true });
		if (TriviaTypeSynth.isTrailRef(child)) slots.push({ suffix: TriviaTypeSynth.AFTER_TRAIL_SUFFIX, isList: false });
		return slots;
	}

	/**
	 * omega-arrow-value-if-reflow - branch opt-fanout arm for a body field
	 * carrying `@:fmt(arrowValueIfReflowSite)`.
	 *
	 * The spine walk gives each member a verdict over ITSELF AND EVERYTHING
	 * BELOW it, which settles a comment on a DESCENDANT. A comment on an
	 * ANCESTOR is the other direction and the model has no upward link, so the
	 * refusing member stamps `_arrowValueIfBlocked` on its branch writes and
	 * every deeper member reads it. With both halves the chain has exactly one
	 * verdict wherever the comment sits.
	 *
	 * The signal is its own opt field: clearing the shared `_inArrowLambdaBody`
	 * instead would also switch off the object-literal arrow knobs inside the
	 * refused branch, which is a different feature answering a different
	 * question.
	 *
	 * Returns `optExpr` unchanged for every field without the flag, and
	 * `_aifBlocked` is only ever true with the knob on, so both the flagless
	 * sites and the default config are byte-inert.
	 *
	 * `optExpr` MUST be a chain rooted at the generated writer function's own
	 * `opt` — the shim is passed `opt` as its `chainBaseArg`, which lets it
	 * mutate an already-cloned link in place. A caller that hands in a chain
	 * rooted anywhere else would let it mutate an opt someone else still holds.
	 */
	private function arrowValueIfBlockOpt(child: ShapeNode, optExpr: Expr): Expr {
		return child.fmtHasFlag(ARROW_VALUE_IF_SITE) ? macro (_aifBlocked ? _setArrowValueIfBlocked($optExpr, opt) : $optExpr) : optExpr;
	}

	/**
	 * Emit the separator + writeCall for a bare-Ref NON-FIRST struct body field
	 * (kw-less, lead-less, non-raw). Covers `@:fmt(allmanIndentForCtor)`,
	 * `@:fmt(nestBodyOnSourceNewline)`, and the ω-issue-48-v2 BeforeNewline /
	 * ω-598 leading-comment sep cascade. Pushes onto `parts`.
	 */
	private function emitBareRefNonFirstBody(
		child: ShapeNode, parts: Array<Expr>, fieldName: String, typePath: String, fieldAccess: Expr, writeCall: Expr,
		prevAnyStarNonEmpty: Null<Expr>, prevPadTrailing: Null<Expr>
	): Void {
		// ω-meta-allman-objectlit: `@:fmt(allmanIndentForCtor('<ctor>'))`
		// on a bare-Ref non-first field forces an Allman-style
		// brace placement plus one indent step when the field's
		// runtime value matches the named ctor. The default
		// `_dt(' ')` separator is suppressed and the writer call
		// is wrapped in `Nest(_cols, [hardline, writeCall])` —
		// the hardline lands at indent base + _cols (Nest bumps
		// the current indent), so the value's own opening
		// literal sits one indent step deeper than the parent
		// and the value's body picks up another step from its
		// own internal Nest. Non-matching ctors fall through to
		// the default `_dt(' ') + writeCall` layout.
		//
		// First (and currently only) consumer: `HxMetaExpr.expr`
		// with `('ObjectLit')` so `@meta { ... }` round-trips
		// the haxe-formatter convention of placing `{` on its
		// own line at indent +1 regardless of the global
		// `objectLiteralLeftCurly` knob — the meta-prefixed
		// brace placement is structural, not configurable.
		//
		// Trivia-mode `BeforeNewline` signal is bypassed when
		// the flag fires — the runtime ctor check is
		// structurally definitive for the brace-form layout
		// and source-newline preservation would only matter
		// for non-brace alternatives that already fall through
		// to the default sep path.
		final allmanCtor: Null<String> = child.fmtReadString('allmanIndentForCtor');
		if (allmanCtor != null) {
			final ctorMatchExpr: Expr = macro Type.enumConstructor($fieldAccess) == $v{allmanCtor};
			// Non-matching ctor falls through to the same
			// BeforeNewline-aware separator the plain
			// bare-Ref non-first branch uses below
			// (ω-issue-48-v2 mechanism). In trivia mode the
			// synth slot `<f>BeforeNewline` records whether
			// source had a newline before this field's
			// first token; preserve it so `@:m if (…)` etc.
			// honour source-side line breaks the same way
			// the rest of the writer does. Plain mode (no
			// trivia signal) keeps the unconditional space.
			final sepExpr: Expr = _ctx.trivia && isTriviaBearing(typePath)
				? macro ${beforeNewlineAccess(fieldName)} ? _dhl() : _dt(' ')
				: macro _dt(' ');
			parts.push(macro {
				final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
				final _doc: anyparse.core.Doc = $writeCall;
				$ctorMatchExpr ? _dn(_cols, _dc([_dhl(), _doc])) : _dc([$sepExpr, _doc]);
			});
		} else if (child.fmtHasFlag('nestBodyOnSourceNewline') && _ctx.trivia && isTriviaBearing(typePath)) {
			// ω-cond-comp-expr-body-nest: source-shape-driven
			// body break+nest. The bare-Ref non-first slot
			// `<f>BeforeNewline:Bool` (synth via
			// `TriviaTypeSynth.isBareNonFirstRef`) records
			// whether the source had a newline before this
			// field's first token. When true the wrapper
			// emits `Nest(_cols, [hardline, body])` so the
			// body sits one indent step deeper than the
			// preceding `#if`/`#elseif` keyword line; when
			// false the wrapper emits `' ' + body` for
			// inline single-line cond-comp expressions.
			// Currently consumed by `HxConditionalExpr.expr`
			// and `HxElseifExpr.expr`.
			final nlSignal: Expr = beforeNewlineAccess(fieldName);
			parts.push(nestBodyOnSourceNewlineWrap(writeCall, nlSignal));
		} else {
			// ω-issue-48-v2: in trivia mode the bare Ref field
			// grew a `<field>BeforeNewline:Bool` slot (see
			// `TriviaTypeSynth.isBareNonFirstRef`). Consult it
			// to emit a hardline when the parser captured a
			// source newline in the gap — this is the only
			// signal available when a preceding bare-tryparse
			// Star (e.g. `HxMemberDecl.modifiers`) is empty,
			// since that Star has no first element whose
			// `newlineBefore` could be read.
			parts.push(buildBareRefLeadingSep(child, fieldName, typePath, prevAnyStarNonEmpty, prevPadTrailing));
			parts.push(writeCall);
		}
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
	private function buildBareRefLeadingSep(
		child: ShapeNode, fieldName: String, typePath: String, prevAnyStarNonEmpty: Null<Expr>, prevPadTrailing: Null<Expr>,
		?keepBlankGate: Null<Expr>
	): Expr {
		// ω-issue-48-v2: in trivia mode the bare Ref field grew a
		// `<field>BeforeNewline:Bool` slot (see `TriviaTypeSynth.isBareNonFirstRef`).
		// Consult it to emit a hardline when the parser captured a source newline
		// in the gap — this is the only signal available when a preceding
		// bare-tryparse Star (e.g. `HxMemberDecl.modifiers`) is empty, since that
		// Star has no first element whose `newlineBefore` could be read.
		if (_ctx.trivia && isTriviaBearing(typePath)) {
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

	/**
	 * ω-598-member-leading-comment: wrap a bare non-first Ref field's trivia
	 * separator so own-line comments the parser captured in the gap (e.g. a
	 * block comment between a member modifier and the `var` keyword) are emitted
	 * glued to the preceding line, each followed by a hardline. Returns the
	 * unmodified separator when the field is not a Ref (no `BeforeLeading` slot)
	 * or the slot is empty.
	 */
	private function buildBeforeLeadingSep(child: ShapeNode, fieldName: String, triviaSepExpr: Expr): Expr {
		// Gated on `child.kind == Ref` to match `TriviaTypeSynth.isBareNonFirstRef`,
		// the only host that grows the `BeforeLeading` slot.
		return child.kind == Ref ? {
			final leadAccess: Expr = beforeLeadingAccess(fieldName);
			macro {
				final _sep598: anyparse.core.Doc = $triviaSepExpr;
				final _leadCm598: Array<String> = $leadAccess;
				if (_leadCm598.length == 0)
					_sep598;
				else {
					final _p598: Array<anyparse.core.Doc> = [_sep598];
					for (_ci598 in 0..._leadCm598.length) {
						_p598.push(leadingCommentDocRun(_leadCm598, _ci598, opt));
						_p598.push(_dhl());
					}
					_dc(_p598);
				}
			}
		} : triviaSepExpr;
	}

	/**
	 * ω-condition-wrap-wiring: emit a single-Ref `@:fmt(condWrap('<knob>'))` field
	 * as a runtime `WrapList.emitCondition` call (replacing the bare lead+value+
	 * trail pushes). Threads the chain-mode / paren-in-condition / cond-keep
	 * shadows and the inner-pad / source-open-newline args, then pushes onto
	 * `parts`.
	 */
	private function emitCondWrapSingleRef(
		child: ShapeNode, parts: Array<Expr>, condWrapArgs: Array<String>, typePath: String, fieldName: String, leadText: Null<String>,
		trailText: Null<String>, writeCall: Expr
	): Void {
		final condKnobAccess: Expr = optFieldAccess(condWrapArgs[0]);
		// ω-before-trail: a `@:fmt(condWrap)` field's close paren is emitted by
		// `WrapList.emitCondition`, not by `emitMandatoryRefTrail`, so a comment
		// captured just before it has to ride INSIDE the condition Doc or it
		// lands after the `)`. Appending to `writeCall` is what keeps
		// `if (cond /* c *\/)` where the author wrote it.
		final condBeforeTrail: Null<Expr> = beforeTrailSlotAccess(child, macro value.$fieldName, false, trailText, typePath);
		final writeCall: Expr = condBeforeTrail == null
			? writeCall
			: macro {
				final _cbt: Null<String> = $condBeforeTrail;
				_cbt == null ? $writeCall : _dc([$writeCall, trailingCommentDocVerbatim(_cbt, opt)]);
			};
		// ω-condition-parens (Stage C): `@:fmt(condParensInside(
		// '<insideOpenKnob>', '<insideCloseKnob>'))` on the
		// condWrap cond field pads the FLAT `( cond )` shape via
		// `opt.<knob>:WhitespacePolicy`. Null when absent →
		// `_de()` inner Docs → tight `(cond)` byte-identical.
		final condInsideArgs: Null<Array<String>> = child.fmtReadStringArgs('condParensInside');
		final condInsideOpen: Expr = condInsideArgs != null && condInsideArgs.length == 2
			? policyInsideSpace(condInsideArgs[0], false)
			: macro _de();
		final condInsideClose: Expr = condInsideArgs != null && condInsideArgs.length == 2
			? policyInsideSpace(condInsideArgs[1], true)
			: macro _de();
		// ω-condition-wrap-keep: read the `<field>CondOpenNewline:Bool`
		// synth slot (populated by `Lowering` when the source broke
		// right after the open paren) and thread it into
		// `emitCondition`'s `sourceOpenNewline` arg. Under
		// `WrapMode.Keep` the engine forces `brkShape` so the
		// author's post-`(` break round-trips. Gated on trivia +
		// bearing + the field opting in via
		// `@:fmt(captureCondOpenNewline)`; otherwise the slot does
		// not exist, so we pass a literal `false` → byte-inert
		// (plain mode, non-keep modes, non-opted condWrap fields).
		final hasCondOpenNewlineSlot: Bool = _ctx.trivia && isTriviaBearing(typePath) && child.fmtHasFlag('captureCondOpenNewline');
		final condOpenNewlineExpr: Expr = hasCondOpenNewlineSlot ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.CONDITION_OPEN_NEWLINE_SUFFIX),
			pos: Context.currentPos()
		} : macro false;
		// ω-condition-wrap-keep: only the trivia-bearing Haxe cond
		// path (slot present) sets `_keepChainInParen` — the
		// `_setKeepChainInParen` helper exists only on opt types that
		// declare `_keepChainInParen` (Haxe `HxModuleWriteOptions`). A
		// generic `@:fmt(condWrap)` grammar without the slot emits the
		// plain opt shadow → no reference to the Haxe-only helper. The
		// runtime `sourceOpenNewline` + Keep gate further narrows the
		// flag to force-broken keep conds.
		final condKeepChainInParen: Expr = hasCondOpenNewlineSlot
			? macro {
				final _condKeepBrk: Bool = $condOpenNewlineExpr && _condMode == anyparse.format.wrap.WrapMode.Keep;
				final opt = _condKeepBrk ? _setKeepChainInParen(opt, true) : opt;
				opt;
			}
			: macro opt;
		parts.push(macro {
			final _condRules: anyparse.format.wrap.WrapRules = $condKnobAccess;
			final _condMode: anyparse.format.wrap.WrapMode = _condRules.defaultMode;
			final _chainOvr: Null<anyparse.format.wrap.WrapMode> = _condMode == anyparse.format.wrap.WrapMode.NoWrap ? null : _condMode;
			// ω-expr-paren-in-condition (cond F2): mark the condition
			// content so an expression paren INSIDE it routes its inner
			// chain through `expressionWrapping` (fillLine) instead of
			// the unconditional HardFlatten collapse — the fork applies
			// `expressionWrapping` to expr parens regardless of context.
			// The flag is consumed ONLY at the `ParenExpr` lowering (it
			// threads the fillLine `_chainModeOverride` into the paren's
			// OWN inner chain and clears the flag), so the condition's
			// top-level chain (`a && b`) is untouched. Byte-inert for
			// the universal default `expressionWrappingWrap`
			// (`{rules: [], defaultMode: NoWrap}` → false).
			final _parenCond: Bool = anyparse.format.wrap.WrapList.effectiveExpressionWrapMode(opt.expressionWrappingWrap) != null;
			final opt = _setParenInCondition(_setChainModeOverride(opt, _chainOvr), _parenCond, opt);
			// ω-condition-wrap-keep: when the cond paren is force-broken
			// (source newline after `(` + Keep mode → `emitCondition`
			// returns `brkShape`), the `brkShape`'s `Nest(cols, condDoc)`
			// already supplies the +cols paren indent. Mark the cond
			// chain's opt `_keepChainInParen` so its OWN continuation
			// `Nest` is suppressed (chain operators co-indent with the
			// head at outer+cols, not compounding to outer+2cols) AND its
			// own `_headBreak` is dropped (`brkShape`'s leading `Line`
			// already put the head operand on its own line). Reuses the
			// `_keepChainInParen` channel (gated there on the
			// chain config being Keep). `condKeepChainInParen` is a
			// macro-time no-op (`opt`) for non-Haxe / non-bearing grammars
			// so the Haxe-only `_setKeepChainInParen` helper is never
			// referenced there.
			final opt = $condKeepChainInParen;
			anyparse.format.wrap.WrapList.emitCondition(
				$v{leadText}, $v{trailText}, $writeCall, opt, $condKnobAccess, $condInsideOpen, $condInsideClose, $condOpenNewlineExpr
			);
		});
	}

	/**
	 * ω-fnbody-keep: fold a repeatable `@:fmt(bodyPolicyForCtor('<ctor>',
	 * '<flagName>'))` pair list into a runtime ternary chain — each pair routes
	 * its matched runtime ctor to a `bodyPolicyWrap`, falling through to the
	 * `_dc([sepExpr, writeCall])` default for every unpaired ctor. Iterates in
	 * reverse so the first-declared pair sits at the chain head. Shared by the
	 * mandatory `case Ref` leftCurly path (with metaBlockGlue / BeforeNewline
	 * slot) and the optional-Ref leftCurly path (null both).
	 */
	private function buildBodyPolicyForCtorChain(
		pairs: Array<Array<String>>, ctorExpr: Expr, sepExpr: Expr, writeCall: Expr, bodyValueExpr: Expr, refName: String,
		wrapBodyOnSameLineExpr: Null<Expr>, metaBlockGlueArgs: Null<Array<String>>
	): Expr {
		final defaultPair: Expr = macro _dc([$sepExpr, $writeCall]);
		// Fold the pairs into a ternary chain. Iterate in reverse
		// so the first-declared pair sits at the chain head
		// (tested first at runtime).
		var chain: Expr = defaultPair;
		var i: Int = pairs.length - 1;
		while (i >= 0) {
			final pair: Array<String> = pairs[i];
			if (pair.length != 2)
				Context.fatalError(
					'WriterLowering: @:fmt(bodyPolicyForCtor(...)) requires (ctorName, flagName), got ${pair.length} args',
					Context.currentPos()
				);
			final wrapCtorName: String = pair[0];
			final wrapFlagName: String = pair[1];
			final wrapMetaBlockGlue: Null<Array<String>> = metaBlockGlueArgs != null && metaBlockGlueArgs[0] == wrapCtorName
				? metaBlockGlueArgs
				: null;
			final wrapOutput: Expr = bodyPolicyWrap({
				flagName: wrapFlagName,
				writeCall: writeCall,
				bodyValueExpr: bodyValueExpr,
				bodyTypePath: refName,
				hasElseIf: false,
				elseFieldName: null,
				bodyOnSameLineExpr: wrapBodyOnSameLineExpr,
				metaBlockGlueArgs: wrapMetaBlockGlue
			});
			chain = macro $ctorExpr == $v{wrapCtorName} ? $wrapOutput : $chain;
			i--;
		}
		return chain;
	}

	/**
	 * Emit a bare-Ref body field carrying `@:fmt(bodyPolicy(...))` (kw-less,
	 * lead-less, non-raw — the `case Ref` non-first / first-field body site).
	 * Reads the kwPolicy / after-trail / before-leading / before-newline /
	 * policy-override / allman / inline-block companion metas, threads them into a
	 * single `bodyPolicyWrap`, pushes onto `parts`, and returns the
	 * `justWrappedBody` PrevBodyInfo.
	 */
	private function emitBodyPolicyBareRef(
		child: ShapeNode, parts: Array<Expr>, prevTrailFieldName: Null<String>, isFirstField: Bool, fieldName: String,
		bodyPolicyFlag: String, bodyPolicyExprFlag: Null<String>, writeCall: Expr, fieldAccess: Expr, refName: String, hasElseIf: Bool,
		elseFieldName: Null<String>, indentObjArgs: Null<Array<String>>, fallbackFlag: Null<String>, condFitGroup: Bool,
		ssbTrailCommentExpr: Null<Expr>
	): PrevBodyInfo {
		final kwPolicyFlag: Null<String> = child.fmtReadString('kwPolicy');
		// ω-trivia-after-trail: when the IMMEDIATELY preceding
		// sibling is a mandatory Ref carrying `@:trail` in
		// trivia-bearing mode, read its synth slot
		// `value.<priorField>AfterTrail:Null<String>` and
		// thread it into `bodyPolicyWrap`. The wrap prepends
		// ` //<comment>` (cuddled to the prior trail token) +
		// forces the body onto its own line at +cols indent
		// regardless of the runtime bodyPolicy. Currently
		// fired by `HxIfStmt.thenBody` after `cond`'s `)`
		// trail. Plain mode and non-bearing rules see a null
		// `prevTrailFieldName` and skip the threading.
		final afterTrailExpr: Null<Expr> = prevTrailFieldName == null ? null : {
			expr: EField(macro value, prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX),
			pos: Context.currentPos()
		};
		// ω-556-then-body-leading-comment: the bare non-first Ref
		// body grows a `<field>BeforeLeading:Array<String>` slot
		// (`isBareNonFirstRef`, same host as the BeforeNewline
		// signal below). Thread it into `bodyPolicyWrap` so own-line
		// comments captured between the preceding token (the cond's
		// `)` trail / the prior body terminator) and the body's
		// first token survive round-trip. The kw-led else-body path
		// already has this via `kwLeadingExpr`; this closes the
		// bare-Ref then-body asymmetry. Gated on the same
		// `(!isFirstField || firstFieldNlOptIn)` predicate the parser
		// uses for `hasBeforeLeadingSlot`; null off the slot path →
		// byte-inert. (`firstFieldNlOptIn` is declared just below
		// alongside `bodyOnSameLineExpr` — both share the gate.)
		// Slice ω-expr-body-keep: `BodyPolicy.Keep` on bare-Ref
		// body fields reads the source-shape signal from the
		// existing `<field>BeforeNewline:Bool` synth slot
		// (created by `isBareNonFirstRef` in TriviaTypeSynth) —
		// `BodyOnSameLine` is its inverse, no separate slot
		// needed. First-field bodyPolicy paths (Case 3) have no
		// BeforeNewline slot, so the !isFirstField gate keeps
		// the pre-slice null fallback there. Without ctx.trivia
		// the slot doesn't exist either; null falls back to the
		// `Same` layout inside `bodyPolicyWrap` (matches the
		// pre-slice plain-mode behaviour for Keep).
		//
		// ω-untyped-keep-trybody: `@:fmt(beforeNewlineSlotFirst)`
		// opt-in extends slot reading to first-field bodyPolicy
		// paths. Pairs with parent Alt-branch
		// `@:fmt(forwardNewlineForBody)` (Case 3 omits post-kw
		// `skipWs`) and `TriviaTypeSynth.isBareNonFirstRef` /
		// `Lowering.hasBeforeNewlineSlot` first-field allowances.
		// Currently consumed by `HxTryCatchStmt.body` for
		// `untypedBody=Keep` source-shape preservation.
		final firstFieldNlOptIn: Bool = isFirstField && child.fmtHasFlag(BEFORE_NEWLINE_SLOT_FIRST);
		final bodyOnSameLineExpr: Null<Expr> = _ctx.trivia && (!isFirstField || firstFieldNlOptIn)
			? beforeNewlineNotAccess(fieldName)
			: null;
		// ω-556-then-body-leading-comment: own-line leading-comment
		// slot, same gate as `bodyOnSameLineExpr` (the BeforeNewline
		// sibling shares the `isBareNonFirstRef` host).
		final beforeLeadingExpr: Null<Expr> = _ctx.trivia && (!isFirstField || firstFieldNlOptIn) ? beforeLeadingAccess(fieldName) : null;
		// ω-untyped-body-stmt-override: forward all
		// `@:fmt(bodyPolicyOverride('<ctor>', '<flag>'))`
		// entries on this field to bodyPolicyWrap. Each entry
		// flips the parent's own bodyPolicy flag to the named
		// replacement when the body's runtime ctor matches —
		// e.g. `HxTryCatchStmt.body` reads `untypedBody`
		// instead of `tryBody` when the value is
		// `HxStatement.UntypedBlockStmt`. Multiple entries
		// cascade through a runtime ternary chain.
		final policyOverrides: Array<Array<String>> = child.fmtReadStringArgsAll('bodyPolicyOverride');
		// ω-issue-168: `@:fmt(bodyAllmanIndentForCtor('<ctor>',
		// '<optField>', '<lcField>'))` runtime-overrides the
		// policy-decided layout when the body's runtime ctor
		// matches `<ctor>` AND `opt.<optField>` is true AND
		// `opt.<lcField>` is `Next` AND the body's writeCall
		// emits internal hardlines (multi-line). The override
		// places the body in Allman position with extra
		// `+cols` indent on contents, regardless of Keep/Same/
		// Next/FitLine policy. Currently consumed by
		// `HxForExpr.body` for the `[for (x in xs) {<multi>}]`
		// shape; HxIfExpr.thenBranch deliberately does NOT
		// carry this meta because fork keeps `if (cond) {`
		// cuddled.
		final bodyAllmanIndentArgs: Null<Array<String>> = child.fmtReadStringArgs('bodyAllmanIndentForCtor');
		// ω-expression-if-with-blocks: `@:fmt(inlineBlockBodyIfFlag(
		// '<flagName>'))` reads `opt.<flagName>:Bool` at runtime;
		// when true AND body's runtime ctor is `BlockExpr`, wrap
		// the body's writeCall result in `D.flatten(…)` to collapse
		// `{<hardline>stmt;<hardline>}` to `{stmt;}` regardless of
		// width. Mirrors fork's `expressionIfWithBlocks` knob
		// (`MarkSameLine.markBody` with `includeBrOpen=true` →
		// `markBlockBody` Same-policy collapse). Currently consumed
		// by `HxIfExpr.thenBranch` / `elseBranch`. Non-BlockExpr
		// bodies and flag-false fall through to the regular policy
		// cascade.
		final inlineBlockBodyArgs: Null<Array<String>> = child.fmtReadStringArgs('inlineBlockBodyIfFlag');
		// ω-loop-body-if-else-next: `@:fmt(loopBodyIfElseNext('<optField>',
		// '<ifCtor>', '<elseField>'))` on a LOOP body field forwards the three
		// names to `bodyPolicyWrap`, which degrades the `FitLine` layout to
		// `Next` when the knob is on and the body is an `if` that owns an
		// `else`. Currently consumed by `HxForStmt.body` / `HxWhileStmt.body`.
		final loopBodyIfElseArgs: Null<Array<String>> = child.fmtReadStringArgs('loopBodyIfElseNext');
		parts.push(bodyPolicyWrap({
			flagName: bodyPolicyFlag,
			exprFlagName: bodyPolicyExprFlag,
			writeCall: writeCall,
			bodyValueExpr: fieldAccess,
			bodyTypePath: refName,
			hasElseIf: hasElseIf,
			elseFieldName: elseFieldName,
			bodyOnSameLineExpr: bodyOnSameLineExpr,
			kwPolicyFlagName: kwPolicyFlag,
			afterTrailExpr: afterTrailExpr,
			beforeLeadingExpr: beforeLeadingExpr,
			indentObjArgs: indentObjArgs,
			policyOverrides: policyOverrides,
			bodyAllmanIndentArgs: bodyAllmanIndentArgs,
			fallbackFlagName: fallbackFlag,
			inlineBlockBodyArgs: inlineBlockBodyArgs,
			condFitGroup: condFitGroup,
			constructFitBody: child.fmtHasFlag('constructFitBody'),
			ssbTrailCommentExpr: ssbTrailCommentExpr,
			arrowValueIfSite: child.fmtHasFlag(ARROW_VALUE_IF_SITE),
			loopBodyIfElseArgs: loopBodyIfElseArgs,
			elseSwitchArgs: child.fmtReadStringArgs('elseSwitch')
		}));
		return { access: fieldAccess, typePath: refName };
	}

	/**
	 * ω-orphan-prefix-decl: read + validate `@:fmt(setBoolFlagFromStarCtor(optField,
	 * starField, ctorName))` off one field. Shared by the mandatory-Ref and the
	 * optional-Ref writer seats — the flag is a property of the FIELD, not of its
	 * optionality, and reading it in only one seat is how `HxTopLevelDecl.decl`
	 * going `@:optional @:absentOnEof` silently stopped suppressing extern-class
	 * blank lines.
	 */
	private function readBoolFlagStarCtorArgs(child: ShapeNode): Null<Array<String>> {
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
	 * ω-extern-class-no-blanks: build the mandatory-Ref writeCall when
	 * `@:fmt(setBoolFlagFromStarCtor(optField, starField, ctorName))` is present —
	 * a block that allocates a fresh opt copy, probes the sibling Star for the
	 * named ctor, sets `_wo.<optField>`, then issues `baseRawWriteCall`. Returns
	 * `baseRawWriteCall` unchanged when the meta is absent.
	 */
	private function buildBoolFlagRawWriteCall(
		boolFlagArgs: Null<Array<String>>, baseRawWriteCall: Expr, typePath: String, propagateExpr: Bool
	): Expr {
		if (boolFlagArgs == null) return baseRawWriteCall;
		final pos: Position = Context.currentPos();
		final optField: String = boolFlagArgs[0];
		final starField: String = boolFlagArgs[1];
		final ctorName: String = boolFlagArgs[2];
		final starAccess: Expr = { expr: EField(macro value, starField), pos: pos };
		final flagAccess: Expr = { expr: EField(macro _c, optField), pos: pos };
		final flagOnOpt: Expr = { expr: EField(macro opt, optField), pos: pos };
		final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
		final useNodeAccess: Bool = _ctx.trivia && isTriviaBearing(typePath);
		final probeBody: Expr = useNodeAccess
			? macro for (_m in $starAccess)
				if (_m.node.match($ctorIdent)) {
					_f = true;
					break;
				}
			: macro for (_m in $starAccess) if (_m.match($ctorIdent)) {
				_f = true;
				break;
			};
		final propagateExprStmt: Expr = propagateExpr ? (macro _c._inExprPosition = true) : (macro {});
		// ω-optclone-chain-fusion: the probe runs against the SHARED `opt` and
		// the 210-field copy is taken only when a field actually changes, so a
		// class WITHOUT the probed modifier — the overwhelming majority — reads
		// its flag off `opt` and allocates nothing (7 630 -> ~0 copies on a real
		// tree).
		var unchangedExpr: Expr = macro $flagOnOpt == _f;
		if (propagateExpr) unchangedExpr = macro $unchangedExpr && opt._inExprPosition;
		// Each `macro …` reification in an array literal must be
		// parenthesised — bare `macro` after `[…,` mis-parses as
		// "Keyword macro cannot be used as variable name". Plain
		// identifiers (`propagateExprStmt`, `baseRawWriteCall`)
		// are fine as-is.
		final block: Array<Expr> = [
			(macro var _f: Bool = false),
			probeBody,
			(macro final _wo = $unchangedExpr ? opt : {
				final _c = _copyOpt(opt);
				$propagateExprStmt;
				$flagAccess = _f;
				_c;
			}),
			baseRawWriteCall
		];
		return { expr: EBlock(block), pos: pos };
	}

	/**
	 * ω-condition-parens (Stage C): build the mandatory-Ref writeCall when
	 * `@:fmt(sharpCondParensInside('<openKnob>', '<closeKnob>'))` is present — a
	 * runtime rewrite of the verbatim `#if (cond)` string that injects inner
	 * parens padding per the named WhitespacePolicy knobs. Returns `rawWriteCall`
	 * unchanged when the meta is absent.
	 */
	private function buildSharpInsideWriteCall(sharpInsideArgs: Null<Array<String>>, fieldAccess: Expr, rawWriteCall: Expr): Expr {
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
	 * Emit the lead + value + trail of an optional `@:lead`-bearing Ref struct
	 * field into `optParts` (the `case Ref if (isOptional)` `leadText != null`
	 * arm). Handles tight leads, `@:fmt(tightLead)`, `@:fmt(typeParamDefaultEquals)`,
	 * the ω-N-break-after-eq bundle, and the optional-ref-trail / trailOpt pushes.
	 *
	 */
	private function emitOptionalRefLead(
		child: ShapeNode, optParts: Array<Expr>, leadText: String, writeCall: Expr, prevBodyField: Null<PrevBodyInfo>, typePath: String,
		prevPadTrailing: Null<Expr>, trailText: Null<String>, trailOptText: Null<String>, hasStructFieldTrailOptSlot: Bool,
		structTrailOptAccess: Null<Expr>
	): Void {
		// ω-N-break-after-eq: when the meta-gated helper bundles the
		// lead + RHS together (via the natural-first-line probe), the
		// post-branch unconditional `optParts.push(writeCall)` must be
		// skipped — the RHS is already inside the bundled Doc.
		var breakAfterEqEmitted: Bool = false;
		final isFieldTight: Bool = child.fmtHasFlag('tightLead');
		if (isTightLead(leadText)) {
			// ω-E-whitespace: `@:fmt(typeHintColon)` on
			// optional-Ref tight leads routes through the same
			// WhitespacePolicy helper as mandatory leads.
			// Without the flag the `None` default keeps the
			// tight `_dt(leadText)` byte-identical to the pre-
			// flag path (`f():Void`).
			optParts.push(whitespacePolicyLead(child, leadText, ['typeHintColon']));
		} else if (isFieldTight) {
			// Per-field `@:fmt(tightLead)`: opts an
			// optional Ref's `@:lead` into tight emission
			// without joining the format-level `tightLeads`
			// list. No leading separator, no trailing
			// `_dop(' ')` — bare `_dt(leadText)` only.
			// Consumer: `HxVarDecl.access` (`@:lead('(')` for
			// property accessor clause). Format-level
			// `tightLeads` can't carry `(` because other
			// `@:lead('(')` sites (`HxFnDecl.params`,
			// `HxIfStmt.cond`, etc.) have distinct handlers.
			optParts.push(macro _dt($v{leadText}));
		} else if (firstFmtFlag(child, ['typeParamDefaultEquals']) != null) {
			// ω-typeparam-default-equals: optional non-tight lead with
			// `@:fmt(typeParamDefaultEquals)` collapses the
			// pre-slice `sameLineSeparator + leadText + ' '` pair
			// into a single `whitespacePolicyLead` switch so
			// `WhitespacePolicy.None` can produce a tight
			// `<T=Int>` (matching `whitespace.binopPolicy: "none"`).
			// The default `Both` branch emits ` = ` — byte-
			// identical to the previous pair when the field has
			// no `@:fmt(sameLine(...))` companion.
			optParts.push(whitespacePolicyLead(child, leadText, ['typeParamDefaultEquals']));
		} else {
			optParts.push(sameLineSeparator(child, prevBodyField, typePath, prevPadTrailing));
			// ω-N-break-after-eq: `@:fmt(breakAfterLeadOnOverflow('type'))`
			// (today: `HxVarDecl.init`) bundles the lead + RHS through
			// the natural-first-line probe so the `=`-break only fires
			// when the RHS's NATURAL first line still overflows (a
			// NoWrap-pinned RHS), NOT when the RHS wraps its own
			// call-args. The bundled Doc already contains the RHS, so
			// the post-branch unconditional `writeCall` push is skipped.
			final breakAfterEqArg: Null<String> = child.fmtReadString('breakAfterLeadOnOverflow');
			if (breakAfterEqArg != null && !isTightLead(leadText)) {
				optParts.push(breakAfterLeadOnOverflowWrap(leadText, writeCall, breakAfterEqArg));
				breakAfterEqEmitted = true;
			} else {
				// Trailing space after a non-tight optional lead
				// is split into a literal `_dt(leadText)` plus an
				// `_dop(' ')`. The optional space is dropped by
				// the renderer when the value emits a leading
				// hardline (e.g. `var x = {…}` with
				// `leftCurly=Next` on the object literal),
				// producing `var x =\n{…}` cleanly. For all
				// other values the rendering is byte-identical
				// to the pre-slice `_dt(leadText + ' ')` path.
				optParts.push(macro _dt($v{leadText}));
				optParts.push(macro _dop(' '));
			}
		}
		if (!breakAfterEqEmitted) optParts.push(writeCall);
		// ω-optional-ref-trail: bracket-pair close for an
		// `@:optional @:lead(<open>) @:trail(<close>)` Ref.
		// Pushed INSIDE optParts so the trail rides the
		// `_optVal != null` runtime gate (absent value
		// suppresses both lead and trail). Bracket-tight by
		// design — no separator before the close, mirroring
		// the mandatory-Ref trail emit (`!isOptional` arm
		// below). First consumer: `HxAbstractDecl.
		// underlyingType` (`(T)` group) for the bare-abstract
		// shape.
		if (trailText != null)
			optParts.push(macro _dt($v{trailText}));
		// ω-struct-trailopt-source-track:
		// optional Ref + kw/lead + `@:trailOpt(LIT)` lands here
		// as a parallel push (`trailText` covers `@:trail`,
		// `trailOptText` covers `@:trailOpt`; the two are
		// mutually exclusive in the same field). Gate on
		// `hasStructFieldTrailOptSlot` (trivia mode + bearing)
		// so plain mode and non-bearing rules preserve pre-
		// Phase-4 silent-drop behaviour for now (no slot to
		// consult, no canonical answer either — earlier code
		// simply never reached this trail at all). The
		// `<field>TrailPresent` slot is `null` only on raw->
		// paired upcasts from `Converters.rawToPaired_*`; the
		// `==false` test degrades safely there — null falls
		// through to canonical emit.
		else if (hasStructFieldTrailOptSlot && trailOptText != null)
			optParts.push(macro $structTrailOptAccess == false ? _de() : _dt($v{trailOptText}));
	}

	/**
	 * Build the per-ctor leftCurly separator ternary chain for a Ref-to-enum body
	 * field: space-prefix ctors get `_dt(' ')` (or `_de()` when the ctor carries
	 * its own bodyPolicy), leftCurly ctors get the runtime `BracePlacement`
	 * switch, everything else stays `_de()`. Returns the folded `sepExpr`. Shared
	 * by the mandatory and optional `case Ref` leftCurly paths in `lowerStruct`.
	 */
	private function buildLeftCurlySepExpr(refName: String, lcCtors: Array<String>, ctorExpr: Expr, lcSep: Expr): Expr {
		final spaceCtors: Array<String> = spacePrefixCtors(refName, lcCtors);
		var sepExpr: Expr = macro _de();
		for (sc in spaceCtors) {
			final scSep: Expr = ctorHasBodyPolicy(refName, sc) ? macro _de() : macro _dt(' ');
			sepExpr = macro $ctorExpr == $v{sc} ? $scSep : $sepExpr;
		}
		for (lc in lcCtors) sepExpr = macro $ctorExpr == $v{lc} ? $lcSep : $sepExpr;
		return sepExpr;
	}

	/**
	 * Emit an optional close-peek Star struct field (first consumer:
	 * `HxTypeRef.params`). Builds the inner Star emission against a narrowed
	 * `_optVal`, optionally splices the kw-led sep + kw-trivia layers, and pushes
	 * a `_optVal != null` runtime gate onto `parts`. The caller owns the post-push
	 * accumulator resets.
	 */
	private function emitOptionalStarField(
		child: ShapeNode, parts: Array<Expr>, node: ShapeNode, typePath: String, isFirstField: Bool, isRaw: Bool,
		stalePrevBareRefBody: Null<PrevBodyInfo>, prevTrailFieldName: Null<String>, kwLead: Null<String>, fieldName: String,
		prevBodyField: Null<PrevBodyInfo>, prevPadTrailing: Null<Expr>, fieldAccess: Expr
	): Void {
		final innerParts: Array<Expr> = [];
		emitWriterStarField(
			child, macro _optVal, innerParts, child == node.children[node.children.length - 1], typePath, isFirstField, isRaw,
			stalePrevBareRefBody, prevTrailFieldName
		);
		// ω-typeparam-spacing: when the typeParamOpen=Before/Both
		// path injects a leading-space Doc into innerParts, the
		// list grows to two elements. EBlock would evaluate to
		// the last Doc only and silently drop the space — use
		// `_dc([...])` so the writer concatenates both pieces.
		final innerExpr: Expr = innerParts.length == 1 ? innerParts[0] : dcCall(innerParts);
		if (kwLead != null) {
			// ω-cond-comp-engine: kw-led optional Star writer
			// mirror. Splices the kw-Ref optional path's
			// inter-field sep + kw-trivia layers (sameLineSeparator
			// + kwBeforeDoc + kwBeforeTrailingDoc) with the Star
			// body emitted by `emitWriterStarField`. The Star
			// helper already honours `@:fmt(padLeading, padTrailing)`
			// against the narrowed `_optVal:Array<T>`, so the gap
			// between the kw and the first body element comes
			// from the pad logic — no need for a literal trailing
			// space on the kw token. Empty body degrades to `_de()`
			// inside the helper, mirroring `HxConditionalMod.body`'s
			// non-optional precedent. First consumer:
			// `HxConditionalDecl.elseBody`.
			final useTriviaGap: Bool = _ctx.trivia;
			final sepWithBeforeKwTrailingExpr: Expr = beforeKwSeparator(
				useTriviaGap, fieldName, child, prevBodyField, typePath, prevPadTrailing
			);
			final kwOptParts: Array<Expr> = [
				sepWithBeforeKwTrailingExpr,
				macro _dt($v{kwLead}),
				innerExpr
			];
			final kwOptBody: Expr = dcCall(kwOptParts);
			parts.push(macro {
				final _optVal = $fieldAccess;
				if (_optVal != null)
					$kwOptBody
				else
					_de();
			});
		} else {
			parts.push(macro {
				final _optVal = $fieldAccess;
				if (_optVal != null)
					$innerExpr
				else
					_de();
			});
		}
	}

	/**
	 * ω-member-meta: build the inter-Star leading separator Doc for a non-first
	 * bare-tryparse Star that follows another bare-tryparse Star. Gated at runtime
	 * on `prev && this.length > 0`; in trivia mode picks `_dhl()` / `_dt(' ')`
	 * from the first element's `newlineBefore` (suppressing a doubled hardline
	 * before a leading doc-comment), plain mode emits a space. Wrapped via
	 * `withPadTrailingDrop`.
	 */
	private function buildInterStarSep(
		prevAnyStarNonEmpty: Expr, fieldAccess: Expr, prevPadTrailing: Null<Expr>, ?keepBlankGate: Null<Expr>
	): Expr {
		final prev: Expr = prevAnyStarNonEmpty;
		// ω-region-prefix-blank: this seam already READS `_next[0].blankBefore` to
		// decide the leading-comment suppression, so keeping the blank needs no
		// new slot here — only the ctor gate that tells a `#if … #end` prefix from
		// an ordinary metadata one. Off (`false`) for every field that did not opt
		// in, which collapses the arm to the pre-slice `_dhl()`.
		final blankGate: Expr = keepBlankGate ?? macro false;
		final blankBreak: Expr = dcCall([macro _dhl(), macro _dhl()]);
		final baseExpr: Expr = _ctx.trivia
			? macro {
				final _next = $fieldAccess;
				if ($prev && _next.length > 0) {
					if (_next[0].newlineBefore) {
						// ω-meta-leading-doc-no-blank: when the next bare-
						// tryparse Star's first element carries a leading
						// comment (e.g. a `/** */` doc-comment) directly after
						// the prior Star with NO source blank line between
						// them, suppress this inter-Star separator hardline.
						// The Star's own leading-comment emit already pushes a
						// single `_dhl()` before the comment; emitting both
						// here produces a spurious blank line (issue_578:
						// `@:jsRequire(...)\n/**` → `@:jsRequire(...)\n\n/**`).
						// Source-faithful: a real authored blank
						// (`blankBefore`) keeps the separator so the blank
						// round-trips. No leading comment → unchanged
						// `_dhl()` (the common meta→modifiers newline path).
						if (_next[0].leadingComments.length > 0 && !_next[0].blankBefore)
							_de();
						else if (_next[0].blankBefore && $blankGate)
							$blankBreak;
						else
							_dhl();
					} else
						_dt(' ');
				} else
					_de();
			}
			: macro $prev && $fieldAccess.length > 0 ? _dt(' ') : _de();
		return withPadTrailingDrop(prevPadTrailing, baseExpr);
	}

	/**
	 * D61: emit the kw prefix for a kw-led mandatory struct field — leading
	 * separator (unless first / raw) then the kw token. `@:fmt(leftCurly)`,
	 * `@:fmt(anonFuncParens)`, and the `catchParensGap` / `whilePolicy` kw-after
	 * knobs each split the kw-trailing space into a runtime policy switch;
	 * otherwise the kw carries a literal trailing space. Pushes onto `parts`.
	 *
	 */
	private function emitKwPrefix(
		child: ShapeNode, parts: Array<Expr>, kwLead: String, isFirstField: Bool, isRaw: Bool, prevBodyField: Null<PrevBodyInfo>,
		typePath: String, prevPadTrailing: Null<Expr>, prevAnyStarNonEmpty: Null<Expr>
	): Void {
		if (!isFirstField && !isRaw) {
			final sep: Expr = sameLineSeparator(child, prevBodyField, typePath, prevPadTrailing);
			// ω-final-modified-member-double-space: when every preceding field was
			// an empty bare-tryparse Star, drop this kw's leading separator, else a
			// stray space leaks (`final  function` when `HxFinalModifierMember.modifiers`
			// is empty). Mirrors the bare-Ref path's `prevAnyStarNonEmpty` gate in
			// `emitBareRefNonFirstBody`. Null tracker (no preceding Star) is byte-identical.
			if (prevAnyStarNonEmpty != null) {
				final prev: Expr = prevAnyStarNonEmpty;
				parts.push(macro $prev ? $sep : _de());
			} else
				parts.push(sep);
		}
		if (child.fmtHasFlag('leftCurly')) {
			// `leftCurlySeparator` (default `optSpaceUpstream=false`)
			// handles both forms identically at this site: bare-flag
			// reads `opt.leftCurly`, knob-form reads
			// `opt.<knobName>` — `Same` emits `_dt(' ')`
			// (byte-identical to the unsplit `kwLead + ' '` form) and
			// `Next` emits `_dhl()`. First knob-form consumer here:
			// `HxUntypedFnBody.block` with
			// `leftCurly('blockLeftCurly')` (slice
			// ω-blockcurly-broader) so the kw→`{` gap honors the
			// per-construct `Block` knob alongside the global
			// cascade.
			parts.push(macro _dt($v{kwLead}));
			parts.push(leftCurlySeparator(child));
		} else if (child.fmtHasFlag('anonFuncParens')) {
			// `@:fmt(anonFuncParens)` on a kw-led mandatory Ref
			// routes the kw-trailing space slot through the
			// runtime `WhitespacePolicy` knob (paren-side
			// semantics — `Before` / `Both` emit a space, `None`
			// / `After` collapse it). First consumer is
			// `HxExpr.FnExpr` (`@:kw('function')` Ref to
			// `HxFnExpr`) — default `None` keeps
			// `function<T>(...)` / `function(...)` tight, and
			// `whitespace.parenConfig.anonFuncParamParens.openingPolicy:
			// "before"` flips both to `function <T>(...)` /
			// `function (...)`. Mirrors the haxe-formatter
			// convention where `function`-led parens (also when
			// reached inside an `@:overload(...)` metadata arg)
			// track `anonFuncParamParens` (see
			// `MarkWhitespace.determinePOpenPolicy` default
			// fall-through).
			parts.push(macro _dt($v{kwLead}));
			final policySpace: Null<Expr> = kwTrailingSpacePolicyParenSide(child, ['anonFuncParens']);
			if (policySpace != null) parts.push(policySpace);
		} else if (firstFmtFlag(child, ['catchParensGap', 'whilePolicy']) != null) {
			// ω-condition-parens (Stage C): kw-led struct-field cond
			// whose `kw`→`(` gap tracks a kw-after `WhitespacePolicy`
			// knob. `catchParensGap` (`HxCatchClause.param`,
			// `@:kw('catch')`) and `whilePolicy` (`HxDoWhileStmt.cond`,
			// `@:kw('while')` — the trailing `while` of a `do … while`)
			// both use kw-after semantics (`After`/`Both` → space,
			// `None` → tight). Defaults keep `catch (` / `} while (`
			// byte-identical; fed from
			// `parenConfig.{catch|while}ConditionParens.openingPolicy`
			// (flipped to the kw-after axis) in `applyConditionParens`.
			parts.push(macro _dt($v{kwLead}));
			final policySpace: Null<Expr> = kwTrailingSpacePolicy(child, ['catchParensGap', 'whilePolicy']);
			if (policySpace != null) parts.push(policySpace);
		} else {
			parts.push(macro _dt($v{kwLead + ' '}));
		}
	}

	/**
	 * D61: emit a mandatory (non-optional, non-condWrap) `@:lead` literal — tight
	 * by default, routed through `whitespacePolicyLead` for the configurable-
	 * spacing leads (objectFieldColon / typeHintColon / typedefAssign / …). The
	 * `@:fmt(typedefIntersectionBreak)` field makes the `&`→operand whitespace a
	 * runtime `opt._intersectionOperandBreak` decision. Pushes onto `parts`.
	 *
	 */
	private function emitMandatoryLead(child: ShapeNode, parts: Array<Expr>, leadText: String, fieldAccess: Expr): Void {
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
	 * ω-condwrap-forstmt: scan a struct's children for a span-mode condWrap
	 * pair — `@:fmt(condWrap('<knob>'))` on a starting field plus a later
	 * sibling carrying the `@:fmt(condWrapEnd)` sentinel flag. Returns the
	 * matched span (start/end indices, the `(` / `)` literals from the start
	 * field's `@:lead` and the end field's `@:trail`, and the knob) or `null`
	 * when no end-field sentinel pairs with a start condWrap (single-Ref
	 * consumers run the existing path). Extracted verbatim from `lowerStruct`.
	 */
	private function detectCondWrapSpan(node: ShapeNode): Null<{
		startIdx: Int,
		endIdx: Int,
		leadText: String,
		trailText: String,
		knob: String
	}> {
		var startIdx: Int = -1;
		var startKnob: Null<String> = null;
		var startLead: Null<String> = null;
		for (i in 0...node.children.length) {
			final c: ShapeNode = node.children[i];
			final cw: Null<Array<String>> = c.fmtReadStringArgs('condWrap');
			if (cw != null && startIdx == -1) {
				startIdx = i;
				startKnob = cw[0];
				startLead = c.readMetaString(':lead');
			} else if (c.fmtHasFlag('condWrapEnd') && startIdx != -1) {
				final endTrail: Null<String> = c.readMetaString(':trail');
				if (startLead == null || endTrail == null)
					Context.fatalError(
						'WriterLowering: @:fmt(condWrap)/@:fmt(condWrapEnd) '
						+ 'span requires @:lead on the start field and @:trail on the end field',
						Context.currentPos()
					);
				if (startKnob == null) Context.fatalError('WriterLowering: @:fmt(condWrap) requires a knob arg', Context.currentPos());
				if (c.kind != Ref || c.annotations[AnnotationKeys.BASE_OPTIONAL] == true)
					Context.fatalError(
						'WriterLowering: @:fmt(condWrapEnd) is supported only on bare mandatory Ref fields', Context.currentPos()
					);
				return {
					startIdx: startIdx,
					endIdx: i,
					leadText: startLead,
					trailText: endTrail,
					knob: startKnob
				};
			}
		}
		return null;
	}

	/**
	 * ω-condition-wrap-wiring: validate a field carrying `@:fmt(condWrap('<knob>'))`.
	 * Enforces a single string arg, a mandatory `@:lead`, a `@:trail` in single-Ref
	 * mode (or a sibling `@:fmt(condWrapEnd)` for span mode, signalled by `hasSpan`),
	 * a bare mandatory Ref kind, and no same-field `@:kw` in single-Ref mode. Throws
	 * via `Context.fatalError` on any violation.
	 */
	private function validateCondWrap(
		condWrapArgs: Array<String>, leadText: Null<String>, trailText: Null<String>, kwLead: Null<String>, hasSpan: Bool,
		isOptional: Bool, isStar: Bool, childKind: ShapeKind
	): Void {
		if (condWrapArgs.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(condWrap(\'<knob>\')) requires 1 string arg, got ${condWrapArgs.length}', Context.currentPos()
			);
		if (leadText == null) Context.fatalError('WriterLowering: @:fmt(condWrap) requires @:lead on the field', Context.currentPos());
		// Span mode: trail literal lives on the matched `@:fmt(condWrapEnd)`
		// sibling; single-Ref mode: trail required on the same field.
		if (!hasSpan && trailText == null)
			Context.fatalError(
				'WriterLowering: @:fmt(condWrap) requires @:trail on the field (or a sibling @:fmt(condWrapEnd) for span mode)',
				Context.currentPos()
			);
		if (isOptional || isStar || childKind != Ref)
			Context.fatalError('WriterLowering: @:fmt(condWrap) is supported only on bare mandatory Ref fields', Context.currentPos());
		if (!hasSpan && kwLead != null)
			Context.fatalError(
				'WriterLowering: @:fmt(condWrap) (single-Ref mode) does not support @:kw on the same field', Context.currentPos()
			);
	}

	/**
	 * ω-pad-trailing-ref / ω-metadata-line-end-function: compute the
	 * non-optional Star field's `thisPadTrailing` runtime expr (or `null`
	 * when the field fires no trailing pad). A `@:fmt(padTrailing)` Star
	 * pads when `_arr.length > 0` OR (ω-line-comment-directive-break) when it
	 * is EMPTY but its orphan trail ends in a `//` comment, since the Star then
	 * emits a break of its own; a `@:fmt(metaLineEndPolicy('<optField>'))`
	 * Star pads when the array is non-empty AND the runtime knob is non-None.
	 *
	 * The empty-arm disjunct is gated on `@:tryparse`: the break it stands for
	 * is emitted by `triviaTryparseStarExpr`, so a `@:fmt(padTrailing)` Star
	 * outside that path would drop its parent's separator with nothing in its
	 * place. Every `padTrailing` Star in the grammar is `@:tryparse` today.
	 */
	private function starPadTrailing(child: ShapeNode, fieldAccess: Expr, typePath: String): Null<Expr> {
		if (child.fmtHasFlag('padTrailing')) {
			final lineTrail: Null<Expr> = child.hasMeta(':tryparse') ? starTrailEndsLineExpr(child, typePath) : null;
			return lineTrail == null ? (macro $fieldAccess.length > 0) : (macro $fieldAccess.length > 0 || $lineTrail);
		}
		final metaLineEndField: Null<String> = child.fmtReadString('metaLineEndPolicy');
		if (metaLineEndField == null) return null;
		final optAccess: Expr = optFieldAccess(metaLineEndField);
		return macro $fieldAccess.length > 0 && $optAccess != 0;
	}

	/**
	 * ω-line-comment-directive-break: runtime "this trivia Star's orphan trail
	 * ends in a `//` comment", or `null` when the `<field>TrailingLeading` slot
	 * does not exist (plain mode, non-trivia-bearing rule, or a Star that does
	 * not collect trivia). The gate keys on `TRIVIA_STAR_COLLECTS`, the same
	 * annotation `TriviaTypeSynth.isTriviaStarField` synthesises the slot from -
	 * a bare `:trivia` meta check would miss the Stars that inherit it from an
	 * enclosing enum branch or from `@:postfix`.
	 *
	 * An EMPTY arm carrying only comments emits no `padTrailing` pad, so the
	 * parent used to follow it with the leading separator of the next field -
	 * a space. Once the Star terminates its own line comment (it must; a `#`
	 * directive glued after `//` becomes comment text) that space lands AFTER
	 * the break and indents the directive by one column. Folding this into the
	 * field's `padTrailing` signal drops the separator through the existing
	 * `withPadTrailingDrop` path. Block-comment trails leave the signal false,
	 * so their same-line separator is untouched.
	 */
	private function starTrailEndsLineExpr(child: ShapeNode, typePath: String): Null<Expr> {
		final fieldName: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		final collectsTrivia: Bool = child.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		if (fieldName == null || !_ctx.trivia || !isTriviaBearing(typePath) || !collectsTrivia) return null;
		final access: Expr = {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX),
			pos: Context.currentPos()
		};
		return macro {
			final _tlc: Array<String> = $access;
			_tlc.length > 0 && StringTools.startsWith(_tlc[_tlc.length - 1], '//');
		};
	}

	/**
	 * ω-member-meta: OR this bare-tryparse Star's `_arr.length > 0` runtime
	 * check into the cumulative `prevAnyStarNonEmpty` signal (or seed it when
	 * no prior Star contributed).
	 */
	private function orStarNonEmpty(prev: Null<Expr>, fieldAccess: Expr): Expr {
		final thisNonEmpty: Expr = macro $fieldAccess.length > 0;
		if (prev == null) return thisNonEmpty;
		final prevExpr: Expr = prev;
		return macro $prevExpr || $thisNonEmpty;
	}

	/**
	 * ω-multivar-wrap: gate every `parts` entry pushed for the `<moreField>`
	 * Star (indices `[start, parts.length)`) on the runtime `_suppressMore`
	 * entry flag, so a head-only recursive self-call drops the Star to
	 * `_de()`. Rewrites the slice in place.
	 */
	private function gateMultiVarMoreParts(parts: Array<Expr>, start: Int): Void {
		for (i in start ... parts.length) {
			final entry: Expr = parts[i];
			parts[i] = macro _suppressMoreEntry ? _de() : $entry;
		}
	}

	/**
	 * ω-absent-on: emit the optional-Ref body for a field with no `@:kw` /
	 * `@:lead`. Pushes only the `writeCall` by default, but when
	 * `@:fmt(leftCurly)` is present mirrors the mandatory-Ref runtime ctor
	 * switch (Allman `\n{` for BlockBody, ` ` for ExprBody) and routes
	 * `@:fmt(bodyPolicyForCtor(...))` pairs through `buildBodyPolicyForCtorChain`.
	 * Pushes into `optParts`.
	 */
	private function emitOptionalAbsentOnBody(
		child: ShapeNode, optParts: Array<Expr>, refName: String, writeCall: Expr, bareSep: Null<Expr>
	): Void {
		// ω-orphan-prefix-member: `@:fmt(bareRefSepWhenPresent)` opt-in — the
		// mandatory bare-Ref leading separator, emitted only on the present
		// branch (this whole body sits inside the field's `_optVal != null`
		// check). Absent by default, so the OTHER two `@:absentOn` consumers are
		// byte-unchanged: `HxFnExpr.body` reaches this function without the flag,
		// and `HxCatchClause.body` never reaches it at all (its
		// `@:fmt(bodyPolicy('catchBody'))` routes it to `emitOptionalBodyPolicyOnly`
		// — which is also why the caller refuses the flag on that path).
		if (bareSep != null) optParts.push(bareSep);
		final lcSep: Null<Expr> = child.fmtHasFlag('leftCurly') ? leftCurlySeparator(child) : null;
		final lcCtors: Array<String> = lcSep == null ? [] : leftCurlyTargetCtors(refName);
		// ω-anonfnbody-keep: optional-Ref mirror of the
		// mandatory-Ref `bodyPolicyForCtor` chain (see the
		// `HxFnDecl.body` site below, ω-fnbody-keep). When
		// `@:fmt(bodyPolicyForCtor('<ctor>', '<flagName>'))` pairs
		// are present, route each matched runtime ctor through
		// `bodyPolicyWrap` (which owns the signature→body
		// separator AND the body emission) and fall through to the
		// per-ctor `sep + writeCall` default for every other ctor.
		// Consumer: `HxFnExpr.body` for `('ExprBody',
		// 'anonFunctionBody')` — the bare-expr anon-fn body. The
		// gap-at-parent rationale matches the mandatory-Ref path:
		// the signature→body source-newline gap is consumed by the
		// parent struct's pre-field `skipWs` before this branch's
		// sub-rule probes, so the `Keep`-policy slot must be read
		// at the parent (`<field>BeforeNewline`), NOT inside the
		// kw-less `ExprBody` branch (which grows no slot). Default
		// `anonFunctionBody=Same` reproduces the prior ExprBody
		// `_dt(' ')` cuddle byte-for-byte, so this is inert until
		// the knob is set to `Next` / `Keep`.
		final bodyPolicyForCtorPairs: Array<Array<String>> = child.fmtReadStringArgsAll('bodyPolicyForCtor');
		if (lcSep != null && lcCtors.length > 0) {
			final ctorExpr: Expr = macro Type.enumConstructor(_optVal);
			final sepExpr: Expr = buildLeftCurlySepExpr(refName, lcCtors, ctorExpr, lcSep);
			if (bodyPolicyForCtorPairs.length > 0) {
				// The `<field>BeforeNewline` Keep-dispatch slot is
				// synthesised only for NON-optional bare Refs
				// (`TriviaTypeSynth.isBareNonFirstRef` excludes
				// `@:optional`). This optional-Ref path therefore has
				// no slot — pass `null`, so `Same` / `Next` work and
				// `Keep` degrades to the no-slot default. Supporting
				// `Keep` here would require extending slot synthesis
				// to optional Refs (a separate, larger change — the
				// `sourceMultilineKeep` wall noted in ω-fnbody-keep).
				final wrapBodyOnSameLineExpr: Null<Expr> = null;
				optParts.push(buildBodyPolicyForCtorChain(
					bodyPolicyForCtorPairs, ctorExpr, sepExpr, writeCall, macro _optVal, refName, wrapBodyOnSameLineExpr, null
				));
				// (ternary-chain fold lives in buildBodyPolicyForCtorChain)
			} else {
				optParts.push(sepExpr);
				optParts.push(writeCall);
			}
		} else
			optParts.push(writeCall);
	}

	/**
	 * Emit the optional-kw Ref body (the `@:optional @:kw(...)` path, e.g.
	 * `HxIfExpr.elseBranch`). Computes the leading separator (augmented with
	 * captured before-kw trivia in trivia mode) then dispatches the kw→body
	 * emission on `@:fmt(bodyPolicy(...))` (→ `bodyPolicyWrap`),
	 * `@:fmt(nestBodyOnSourceNewline)` (→ source-newline break+nest), or the
	 * default `_dt(kwLead + ' ') + writeCall`. The ω-issue-316 kw-trivia slots
	 * (`<field>AfterKw` / `KwLeading` / `BodyOnSameLine` / `BeforeKwLeading` /
	 * `BeforeKwTrailing`) are read off `value` here in trivia mode. Pushes into
	 * `optParts`.
	 */
	private function emitOptionalKwBody(
		child: ShapeNode, optParts: Array<Expr>, kwLead: String, fieldName: String, bodyPolicyFlag: Null<String>,
		bodyPolicyExprFlag: Null<String>, writeCall: Expr, refName: String, hasElseIf: Bool, elseFieldName: Null<String>,
		prevBodyField: Null<PrevBodyInfo>, typePath: String, prevPadTrailing: Null<Expr>, indentObjArgs: Null<Array<String>>
	): Void {
		// ω-issue-316: in Trivia mode, `@:optional @:kw(...)` Ref
		// children grow per-parent sibling slots `<field>AfterKw`
		// / `<field>KwLeading` holding captured trivia from the
		// gap between the kw and the body. Read them off `value`
		// (the parent struct) and forward to `bodyPolicyWrap`
		// which injects them into the kw→body separator.
		final useTriviaGap: Bool = _ctx.trivia;
		final afterKwExpr: Null<Expr> = useTriviaGap ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.AFTER_KW_SUFFIX),
			pos: Context.currentPos()
		} : null;
		final kwLeadingExpr: Null<Expr> = useTriviaGap ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.KW_LEADING_SUFFIX),
			pos: Context.currentPos()
		} : null;
		// ω-keep-policy: `<field>BodyOnSameLine:Bool` drives the
		// `Keep` branch of `bodyPolicyWrap` / policySwitch.
		final bodyOnSameLineExpr: Null<Expr> = useTriviaGap ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BODY_ON_SAME_LINE_SUFFIX),
			pos: Context.currentPos()
		} : null;
		final sepWithBeforeKwTrailingExpr: Expr = beforeKwSeparator(
			useTriviaGap, fieldName, child, prevBodyField, typePath, prevPadTrailing
		);
		optParts.push(sepWithBeforeKwTrailingExpr);
		if (bodyPolicyFlag != null) {
			optParts.push(macro _dt($v{kwLead}));
			// ω-expression-if-with-blocks: sister read of
			// `@:fmt(inlineBlockBodyIfFlag(...))` on optional-kw
			// body field path (e.g. `HxIfExpr.elseBranch`'s
			// `@:optional @:kw('else')` form). Threaded into the
			// same `bodyPolicyWrap` plumbing as the bare-Ref path
			// below; the runtime override fires at writeCall-swap
			// time before policy dispatch.
			final inlineBlockBodyArgs: Null<Array<String>> = child.fmtReadStringArgs('inlineBlockBodyIfFlag');
			optParts.push(bodyPolicyWrap({
				flagName: bodyPolicyFlag,
				exprFlagName: bodyPolicyExprFlag,
				writeCall: writeCall,
				bodyValueExpr: macro _optVal,
				bodyTypePath: refName,
				hasElseIf: hasElseIf,
				elseFieldName: elseFieldName,
				afterKwExpr: afterKwExpr,
				kwLeadingExpr: kwLeadingExpr,
				bodyOnSameLineExpr: bodyOnSameLineExpr,
				indentObjArgs: indentObjArgs,
				inlineBlockBodyArgs: inlineBlockBodyArgs,
				arrowValueIfSite: child.fmtHasFlag(ARROW_VALUE_IF_SITE),
				elseIfCommentReflow: child.fmtHasFlag('elseIfCommentReflow'),
				elseSwitchArgs: child.fmtReadStringArgs('elseSwitch')
			}));
		} else if (child.fmtHasFlag('nestBodyOnSourceNewline') && bodyOnSameLineExpr != null) {
			// ω-cond-comp-expr-body-nest: optional-kw-Ref body
			// break+nest based on the captured `<f>BodyOnSameLine`
			// slot. When the slot is false (source had a newline
			// between the kw and the body) the wrapper emits
			// `Nest(_cols, [hardline, body])` so the body sits
			// one indent step deeper than the kw line. When true
			// the wrapper emits `' ' + body` for inline single-
			// line shape. Currently consumed by `HxConditionalExpr.elseExpr`.
			optParts.push(macro _dt($v{kwLead}));
			final invertedSignal: Expr = macro !$bodyOnSameLineExpr;
			optParts.push(nestBodyOnSourceNewlineWrap(writeCall, invertedSignal));
		} else {
			optParts.push(macro _dt($v{kwLead + ' '}));
			optParts.push(writeCall);
		}
	}

	/**
	 * ω-absent-on-bodypolicy: emit the optional-Ref body for a field with no
	 * `@:kw` / `@:lead` but `@:fmt(bodyPolicy(...))` — mirrors the mandatory-Ref
	 * `bodyPolicyWrap` path so the `)`→body separator survives; the surrounding
	 * `_optVal != null` guard drops the absent case to `_de()`. First consumer:
	 * `HxCatchClause.body` (bodyless `catch (e:T)`). Pushes into `optParts`.
	 *
	 */
	private function emitOptionalBodyPolicyOnly(
		child: ShapeNode, optParts: Array<Expr>, bodyPolicyFlag: String, bodyPolicyExprFlag: Null<String>, writeCall: Expr,
		refName: String, hasElseIf: Bool, elseFieldName: Null<String>, indentObjArgs: Null<Array<String>>, prevTrailFieldName: Null<String>
	): Void {
		final inlineBlockBodyArgs: Null<Array<String>> = child.fmtReadStringArgs('inlineBlockBodyIfFlag');
		// Head -> body seam, mirror of the mandatory-Ref path in
		// `emitBodyPolicyBareRef`: when the preceding sibling is a Ref with
		// `@:trail` in trivia mode, its `<field>AfterTrail` slot holds the
		// same-line comment cuddled to that closer. `HxCatchClause.body` is
		// the `@:optional` twin of `HxIfStmt.thenBody`, so without this the
		// comment in `} catch (e:T) // c` + newline `{` was captured and
		// then silently dropped.
		final afterTrailExpr: Null<Expr> = prevTrailFieldName == null ? null : {
			expr: EField(macro value, prevTrailFieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX),
			pos: Context.currentPos()
		};
		optParts.push(bodyPolicyWrap({
			flagName: bodyPolicyFlag,
			exprFlagName: bodyPolicyExprFlag,
			writeCall: writeCall,
			bodyValueExpr: macro _optVal,
			bodyTypePath: refName,
			hasElseIf: hasElseIf,
			elseFieldName: elseFieldName,
			afterTrailExpr: afterTrailExpr,
			indentObjArgs: indentObjArgs,
			inlineBlockBodyArgs: inlineBlockBodyArgs,
			constructFitBody: child.fmtHasFlag('constructFitBody'),
			elseSwitchArgs: child.fmtReadStringArgs('elseSwitch')
		}));
	}

	/**
	 * Emit a bare mandatory Ref body field (no `@:kw` / `@:lead`) that carries
	 * no `@:fmt(bodyPolicy(...))` — the non-bodyPolicy dispatch. Routes through
	 * `@:fmt(leftCurly)` runtime BracePlacement ctor switch (+ optional
	 * `bodyPolicyForCtor` chain), `@:fmt(bodyBreak)` / `@:fmt(bareBodyBreaks)`
	 * shape wraps, the bare-Ref non-first-body cascade, span-mode / single-Ref
	 * `@:fmt(condWrap)`, the `@:fmt(arrowBodyLineWrap)` line-fit break, or the
	 * default bare writeCall. Pushes into `parts`.
	 */
	private function emitBareRefNonBodyPolicy(
		child: ShapeNode, parts: Array<Expr>, refName: String, fieldName: String, typePath: String, fieldAccess: Expr, writeCall: Expr,
		isFirstField: Bool, isRaw: Bool, kwLead: Null<String>, leadText: Null<String>, hasCondWrap: Bool,
		condWrapArgs: Null<Array<String>>, spanInfoPresent: Bool, trailText: Null<String>, prevAnyStarNonEmpty: Null<Expr>,
		prevPadTrailing: Null<Expr>
	): Void {
		// `@:fmt(leftCurly)` on a bare Ref field (e.g.
		// `HxFnDecl.body:HxFnBody`) routes the inter-field
		// space through the runtime BracePlacement switch —
		// same separator the Star path uses when the `{`
		// open lives on the field. The Ref points at an
		// enum (BlockBody / NoBody); the separator must be
		// suppressed when the runtime branch is the
		// `;`-terminated NoBody — emitting `_dt(' ')` ahead
		// of `;` would round-trip as `function f():Void ;`.
		// Detect the brace-bearing branch by `@:lead('{')`
		// at macro time; gate emission on enum-ctor identity
		// at runtime via `Type.enumConstructor`.
		final lcSep: Null<Expr> = child.fmtHasFlag('leftCurly') ? leftCurlySeparator(child) : null;
		final lcCtors: Array<String> = lcSep == null ? [] : leftCurlyTargetCtors(refName);
		final lcCtor: Null<String> = lcCtors.length == 0 ? null : lcCtors[0];
		final bodyBreakFlag: Null<String> = child.fmtReadString('bodyBreak');
		final bareBodyBreaksFlag: Bool = child.fmtHasFlag('bareBodyBreaks');
		final noLeadNoRaw: Bool = kwLead == null && leadText == null && !isRaw;
		if (lcSep != null && lcCtor != null) {
			// Sibling no-lead branches (e.g. `HxFnBody.ExprBody`) need a
			// ` ` separator between the parent kw and the sub-rule's
			// first token — Case 3 generic single-Ref branches whose
			// writer emits `subCall` first. `;`-led siblings (NoBody)
			// stay on the `_de()` default so `function f():Void;`
			// round-trips with no inserted space ahead of `;`.
			//
			// ω-functionBody-policy: a sibling ctor carrying ctor-level
			// `@:fmt(bodyPolicy(...))` has its own bodyPolicyWrap inside
			// the sub-rule writer (Case 3 path) which provides the
			// kw→body separator (`_dt(' ')` for Same, hardline+Nest for
			// Next). The parent must therefore emit `_de()` for that
			// ctor, otherwise we get a doubled space (Same) or a
			// trailing space ahead of the hardline (Next). The
			// per-sibling separator decision lives at the parent here
			// because only the parent knows the runtime ctor.
			emitLeftCurlyBody(
				child, parts, refName, fieldName, typePath, fieldAccess, writeCall, isFirstField, kwLead, leadText, lcSep, lcCtors
			);
			// (bodyPolicyForCtor ternary chain + metaBlockGlue descent live in emitLeftCurlyBody)
		} else if (bodyBreakFlag != null && noLeadNoRaw) {
			// ω-expression-try-body-break: wrap the body field in a
			// SameLinePolicy switch — `Same` emits ` ` + body, `Next`
			// emits hardline + Nest + body so the body sits one indent
			// deeper than the surrounding kw line. Used by
			// `HxTryCatchExpr.body` (first field; Case 3 strips the
			// `try` kw's trailing space so the wrap's `Same` ` ` is the
			// sole separator) and by `HxCatchClauseExpr.body` (last
			// field; replaces the fixed `_dt(' ')` between `)` and the
			// catch body).
			parts.push(bodyBreakWrap(bodyBreakFlag, writeCall, fieldAccess, refName, child.fmtHasFlag('blockBodyKeepsInline')));
		} else if (bareBodyBreaksFlag && noLeadNoRaw) {
			// ω-statement-bare-break: shape-only wrap — block body
			// emits inline ` ` + body, bare body emits hardline +
			// Nest + body. No policy involvement, so the layout is
			// independent of `sameLineCatch` (block bodies still get
			// their `} catch` placement controlled by the catches
			// Star sameLine knob; bare bodies always break). Used by
			// `HxTryCatchStmt.body` (first field; Case 3 strips the
			// `try` kw's trailing space) and `HxCatchClause.body`
			// (last field; replaces the default `_dt(' ')` separator
			// between `)` and the catch body).
			parts.push(bareBodyBreakWrap(
				writeCall, fieldAccess, refName, child.fmtReadString('bareBodyBreaks'), child.fmtHasFlag('constructFitBody')
			));
		} else if (noLeadNoRaw && !isFirstField) {
			// Bare-Ref non-first body: allmanIndentForCtor / nestBodyOnSourceNewline /
			// ω-issue-48-v2 sep cascade — see emitBareRefNonFirstBody.
			emitBareRefNonFirstBody(child, parts, fieldName, typePath, fieldAccess, writeCall, prevAnyStarNonEmpty, prevPadTrailing);
		} else if (hasCondWrap && spanInfoPresent) {
			// ω-condwrap-forstmt: span mode — defer the
			// `emitCondition` wrap to the end-field
			// iteration. Push writeCall directly so
			// inter-field separators / kw text /
			// trailing-field writeCall accumulate in
			// `parts` for splicing at the end. The
			// `_setChainModeOverride` shadow is also
			// applied lazily (inside the end-field's
			// splice block) so the inner writeCalls see
			// the overridden cascade.
			parts.push(writeCall);
		} else if (hasCondWrap) {
			// ω-condition-wrap-wiring / ω-chain-fillline-in-condwrap: single-Ref condWrap
			// emit — see emitCondWrapSingleRef.
			emitCondWrapSingleRef(child, parts, condWrapArgs, typePath, fieldName, leadText, trailText, writeCall);
			// (condParensInside / ω-condition-wrap-keep detail lives in emitCondWrapSingleRef)
		} else if (child.fmtHasFlag('arrowBodyLineWrap')) {
			// ω-arrow-body-line-wrap: when the line containing
			// the lambda body — `(params) -> body` plus rest of
			// stack — would exceed `opt.lineWidth`, break after
			// `->` (or `=>`) and indent the body one level. The
			// preceding lead emission via `whitespacePolicyLead`
			// terminates with `_dop(' ')` (OptSpace); the brk
			// side's leading hardline triggers the renderer's
			// `pendingOptSpace` clear so the post-arrow space
			// drops cleanly without leaving a trailing token.
			// Flat side is the bare writeCall — byte-identical
			// to the pre-slice default branch below.
			//
			// Mirrors fork's `MarkWrapping.applyArrowWrapping`
			// (`MarkWrapping.hx:985-1041`): collect arrows whose
			// flat line exceeds `maxLineLength`, apply break
			// after `->`, try collapse, restore on still-exceed.
			// Our `_dilr` IS the collapse — flat side fires
			// when the line fits, brk side fires when it does
			// not, both decided at render time.
			//
			// Wrapped in `_dwb` (WrapBoundary) so a sister probe
			// in `WrapList.shapeFillLine` 1-item path can detect
			// the arrow-body-line-wrap signature structurally
			// and route the outer Call's close paren to its own
			// line (mirrors fork's parent-walk close-paren mark
			// in `applyArrowWrapping`'s `lineEndBefore(pClose)`).
			// Slice-2 follow-up extends `isChainOPLBreak`.
			//
			// Currently consumed by `HxThinParenLambda.body`
			// (`->` form) and `HxParenLambda.body` (`=>` form)
			// for symmetric coverage of the canonical and
			// legacy lambda-body syntaxes.
			parts.push(arrowBodyLineWrapExpr(writeCall));
		} else {
			parts.push(writeCall);
		}
	}

	/**
	 * Emit the `@:fmt(leftCurly)` bare-Ref body path — a runtime BracePlacement
	 * ctor switch (`buildLeftCurlySepExpr`) between the parent kw and the body's
	 * first token, optionally routing matched `@:fmt(bodyPolicyForCtor(...))`
	 * ctors through `buildBodyPolicyForCtorChain` (with `@:fmt(metaBlockGlue)`
	 * descent naming). Pushes into `parts`.
	 */
	private function emitLeftCurlyBody(
		child: ShapeNode, parts: Array<Expr>, refName: String, fieldName: String, typePath: String, fieldAccess: Expr, writeCall: Expr,
		isFirstField: Bool, kwLead: Null<String>, leadText: Null<String>, lcSep: Expr, lcCtors: Array<String>
	): Void {
		final ctorExpr: Expr = macro Type.enumConstructor($fieldAccess);
		final sepExpr: Expr = buildLeftCurlySepExpr(refName, lcCtors, ctorExpr, lcSep);
		// ω-untyped-keep / ω-fnbody-keep: `@:fmt(bodyPolicyForCtor('<ctor>',
		// '<flagName>'))` (repeatable) runtime-replaces the per-ctor
		// `sep + writeCall` pair with a `bodyPolicyWrap` for each matched
		// runtime ctor, built as a ternary chain falling through to the
		// per-ctor default. The `<field>BeforeNewline` Keep-dispatch slot is
		// read at the parent (where it IS captured, see `hasBeforeNewlineSlot`
		// in `Lowering.lowerStruct`), NOT inside the kw-less branch. Consumers:
		// `HxFnDecl.body` for `('UntypedBlockBody', 'untypedBody')` and
		// `('ExprBody', 'functionBody')`. Same/Next output stays byte-identical
		// to the pre-slice inner-branch emission.
		final bodyPolicyForCtorPairs: Array<Array<String>> = child.fmtReadStringArgsAll('bodyPolicyForCtor');
		if (bodyPolicyForCtorPairs.length > 0) {
			final hasBeforeNlSlot: Bool = _ctx.trivia && isTriviaBearing(typePath) && !isFirstField && kwLead == null && leadText == null;
			final wrapBodyOnSameLineExpr: Null<Expr> = hasBeforeNlSlot ? beforeNewlineNotAccess(fieldName) : null;
			// ω-fnbody-meta-block-glue: `@:fmt(metaBlockGlue('<exprBodyCtor>',
			// '<metaCtor>', '<blockCtor>'))` names the runtime descent so
			// `bodyPolicyWrap` can route a metadata-wrapped block body
			// (`@:meta { … }`) to the glued layout. Consumer: `HxFnDecl.body`
			// with `('ExprBody', 'MetaExpr', 'BlockExpr')`.
			final metaBlockGlueArgs: Null<Array<String>> = child.fmtReadStringArgs('metaBlockGlue');
			if (metaBlockGlueArgs != null && metaBlockGlueArgs.length != 3)
				Context.fatalError(
					'WriterLowering: @:fmt(metaBlockGlue(...)) requires (exprBodyCtor, metaCtor, blockCtor), got '
					+ '${metaBlockGlueArgs.length} args',
					Context.currentPos()
				);
			parts.push(buildBodyPolicyForCtorChain(
				bodyPolicyForCtorPairs, ctorExpr, sepExpr, writeCall, fieldAccess, refName, wrapBodyOnSameLineExpr, metaBlockGlueArgs
			));
			// (ternary-chain fold lives in buildBodyPolicyForCtorChain)
		} else {
			parts.push(sepExpr);
			parts.push(writeCall);
		}
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
	private function subPositionSuppressOpt(child: ShapeNode, e: Expr): Expr {
		var out: Expr = e;
		if (child.fmtHasFlag('suppressCallRestProbe')) out = macro _setSuppressCallRestProbe($out, true, opt);
		if (child.fmtHasFlag('suppressPatternRestProbe')) out = macro _setSuppressPatternRestProbe($out, opt);
		return child.fmtHasFlag('suppressComplexItems') ? macro _setSuppressComplexItems($out, opt) : out;
	}

	/**
	 * Build the mandatory-Ref body field's runtime `writeCall` Expr. Reads the
	 * opt-fanout flags (`propagateExprPosition` / `propagateAnonFnContext` /
	 * `propagateTypedefContext` / `switchSubjectNoWrap` / `propagateValueIfBranch`
	 * / `setBoolFlagFromStarCtor`) to assemble the descendant writer's `opt`
	 * argument, then layers `@:fmt(sharpCondParensInside)` and the
	 * `@:fmt(indentValueIfCtor)` additive-Nest wrap (skipped when a same-field
	 * `@:fmt(bodyPolicy)` routes it through the subtractive channel instead).
	 *
	 */
	private function buildMandatoryRefWriteCall(
		child: ShapeNode, fieldAccess: Expr, typePath: String, writeFn: String, bodyPolicyFlag: Null<String>,
		indentObjArgs: Null<Array<String>>, ?ssbSuppressCond: Expr
	): Expr {
		// ω-issue-423-mech-a / ω-arrow-lambda-body-context /
		// ω-typedef-anon-force-multi: opt-fanout flags wrapping the descendant
		// writer's `opt` arg in `_setExprPosition` / `_setAnonFnBody` /
		// `_setTypedefBody` so the descendant sees the matching context flag.
		final propagateExpr: Bool = child.fmtHasFlag('propagateExprPosition');
		final propagateAnonFn: Bool = child.fmtHasFlag('propagateAnonFnContext');
		final propagateTypedef: Bool = child.fmtHasFlag('propagateTypedefContext');
		// ω-enumabstract-begin-end: `@:fmt(propagateEnumAbstractContext)` on
		// `EnumAbstractDecl(decl)` flags the inner `HxAbstractDecl` opt so its
		// body reads the `enumAbstractBeginType` / `enumAbstractEndType` knobs.
		final propagateEnumAbstract: Bool = child.fmtHasFlag('propagateEnumAbstractContext');
		// ω-extern-class-no-blanks: `@:fmt(setBoolFlagFromStarCtor(optField,
		// starField, ctorName))` allocates a fresh opt copy and sets
		// `_wo.<optField> = true` iff the sibling `<starField>` Star contains
		// `<ctorName>`. Consumer: `HxTopLevelDecl.decl` (`_classExtern`).
		final boolFlagArgs: Null<Array<String>> = readBoolFlagStarCtorArgs(child);
		// ω-switch-subject-nowrap: the fork never wraps a switch subject —
		// thread `_setChainModeOverride(opt, NoWrap)` so a top-level chain in
		// the subject stays flat. Carried by `HxSwitchStmt(Bare).expr`.
		final switchSubjectNoWrap: Bool = child.fmtHasFlag('switchSubjectNoWrap');
		// ω-expressionif-collapse (mechanism B set-site): `@:fmt(propagateValueIfBranch)`
		// on a mandatory Ref (HxIfExpr.thenBranch) opts into the value-if-branch frame.
		final propagateValueIfBranch: Bool = child.fmtHasFlag('propagateValueIfBranch');
		// ω-elseif-body-break: `@:fmt(clearElseIfBranch)` on the inner `if`'s
		// then-body (HxIfStmt.thenBody) drops the one-level else-branch signal
		// before rendering the body content, so a statement nested inside the
		// else-if body is not itself treated as an else-branch.
		final clearElseIfBranch: Bool = child.fmtHasFlag('clearElseIfBranch');
		// ω-arrow-body-objlit-pad: `@:fmt(propagateArrowLambdaBody)` on an
		// arrow-lambda body Ref (HxThinParenLambda.body) flags the immediate
		// body write so its leftmost-leaf object literal drops the open pad.
		// Wrapped AFTER `_setExprPosition` so the descent clear inside it does
		// not wipe the just-set flag.
		final propagateArrowLambdaBody: Bool = child.fmtHasFlag('propagateArrowLambdaBody');
		// omega-condsplice-tail-nest: `@:fmt(chainNestSuppress)` on a mandatory Ref
		// (HxCondSpliceExpr.tail) suppresses the descendant chain's OWN continuation
		// Nest so a `#if … #end` token-splice tail co-indents with the ENCLOSING chain
		// instead of compounding a second indent level. Reuses the call-arg chain-nest
		// channel (`_setCallArgChainNest` → `_chainNestSuppress`); the flag is consumed
		// and cleared at the tail's outermost chain, so only a bare-ternary tail could
		// reach the sister `ternaryRestAware` coupling — and that tail CLEARS without
		// suppressing (`lowerTernaryBranch`: a ternary always keeps its own `?` / `:`
		// Nest), so the co-indent this flag buys never reaches a bare-ternary tail.
		final chainNestSuppress: Bool = child.fmtHasFlag('chainNestSuppress');
		final optArgExpr: Expr = if (boolFlagArgs != null) {
			macro _wo;
		} else {
			var e: Expr = macro opt;
			if (propagateExpr) e = macro _setExprPosition($e, opt);
			// ω-single-stmt-braces: dangling-else suppress frame — when the
			// enclosing `if` has an `else` at runtime AND its then-body renders
			// WITHOUT braces, the whole then-body write runs with `_ssbSuppress` so
			// nested `dropSingleStmtBraces` unwraps are gated by the same
			// trailing-spine test as the direct dangling-else gate (they could
			// otherwise expose a trailing braceless `if` that captures the outer
			// `else`). A brace-bearing then-body seals its subtree with its own `}`
			// and never arms the frame. Null cond (no meta / no else sibling /
			// plain mode) is byte-inert.
			if (ssbSuppressCond != null) e = macro ($ssbSuppressCond ? _setSsbSuppress($e, opt) : $e);
			// ω-single-stmt-braces CHAIN symmetry: a body's OWN content must NOT
			// inherit the else-if chain-suppress flag — an independent if-chain
			// nested inside this branch still de-braces on its own merits. Clear it
			// on the descendant opt (trivia mode only; the flag exists on the
			// HxModuleWriteOptions typedef the dropSingleStmtBraces bodies use).
			if (_ctx.trivia && child.fmtHasFlag('dropSingleStmtBraces')) e = macro _setSsbChainSuppress($e, false, opt);
			// Set AFTER `_setExprPosition` so its descent-clear does not wipe the
			// just-set flag (mirrors the `propagateArrowLambdaBody` ordering).
			e = subPositionSuppressOpt(child, e);
			if (chainNestSuppress) e = macro _setCallArgChainNest($e, opt);
			if (propagateArrowLambdaBody) e = macro _setArrowLambdaBody($e, opt);
			if (propagateAnonFn) e = macro _setAnonFnBody($e, opt);
			if (propagateTypedef) e = macro _setTypedefBody($e, opt);
			if (propagateEnumAbstract) e = macro _setEnumAbstract($e, opt);
			if (switchSubjectNoWrap) e = macro _setChainModeOverride($e, anyparse.format.wrap.WrapMode.NoWrap, opt);
			// The helper gates on `opt._inExprPosition` so only a value-if
			// branch (not a statement-`if`) flips the narrow flag.
			if (propagateValueIfBranch) e = macro _setValueIfBranch($e, opt);
			if (clearElseIfBranch) e = macro _clearElseIfBranch($e, opt);
			e = arrowValueIfBlockOpt(child, e);
			e;
		};
		final baseRawWriteCall: Expr = {
			expr: ECall(macro $i{writeFn}, [fieldAccess, optArgExpr]),
			pos: Context.currentPos()
		};
		final rawWriteCall: Expr = buildBoolFlagRawWriteCall(boolFlagArgs, baseRawWriteCall, typePath, propagateExpr);
		// ω-condition-parens (Stage C): `@:fmt(sharpCondParensInside('<openKnob>',
		// '<closeKnob>'))` injects inner-paren pad into the verbatim `#if (cond)`
		// capture (`HxConditionalStmt.cond`). Null policies → byte-identical.
		final sharpInsideArgs: Null<Array<String>> = child.fmtReadStringArgs('sharpCondParensInside');
		final effRawWriteCall: Expr = buildSharpInsideWriteCall(sharpInsideArgs, fieldAccess, rawWriteCall);
		// ω-indent-objectliteral / ω-expr-body-indent-objectliteral: the additive
		// `maybeIndentValueIfCtor` Nest is SKIPPED when a same-field
		// `@:fmt(bodyPolicy)` routes `indentValueIfCtor` through the subtractive
		// `bodyPolicyWrap.indentObjArgs` channel instead (avoids double-indent).
		return bodyPolicyFlag != null && indentObjArgs != null
			? effRawWriteCall
			: maybeIndentValueIfCtor(effRawWriteCall, fieldAccess, child);
	}

	/**
	 * Emit a mandatory-Ref field's trail. Pushes the `@:trail` literal (routed
	 * through `whitespacePolicyTrail` for the catch / switch / while
	 * cond-parens-inside-close knobs) and, in trivia-bearing mode, the
	 * `@:trailOpt(LIT)` source-presence gate (`<field>TrailPresent` slot: `false`
	 * -> `_de()`, else emit). Both are skipped inside a condWrap span. Pushes into
	 * `parts`.
	 */
	private function emitMandatoryRefTrail(
		child: ShapeNode, parts: Array<Expr>, isOptional: Bool, trailText: Null<String>, trailOptText: Null<String>, hasCondWrap: Bool,
		hasCondWrapEnd: Bool, hasStructFieldTrailOptSlot: Bool, structTrailOptAccess: Null<Expr>, fieldAccess: Expr, typePath: String
	): Void {
		// ω-before-trail: a BLOCK comment the source wrote between this field's
		// last token and the trail literal (`switch (subject /* c *\/)`). Emitted
		// BEFORE the trail dispatch below so it also survives the
		// `switchSubjectParensStrip` arm, which drops the close literal entirely.
		// A missing slot / null value contributes nothing. A `@:fmt(condWrap)`
		// field does not emit its trail here at all — `emitCondWrapSingleRef`
		// owns both parens, so it appends the comment to the condition Doc
		// itself; emitting here too would print it twice.
		final beforeTrailAccess: Null<Expr> = hasCondWrap || hasCondWrapEnd
			? null
			: beforeTrailSlotAccess(child, fieldAccess, isOptional, trailText, typePath);
		if (beforeTrailAccess != null) parts.push(macro {
			final _bt: Null<String> = $beforeTrailAccess;
			_bt == null ? _de() : trailingCommentDocVerbatim(_bt, opt);
		});
		// ω-condition-parens (Stage C): `@:fmt(catchParensInsideClose)` on
		// a mandatory-Ref `@:trail(')')` field routes the close literal
		// through `opt.catchParensInsideClose` (`Before`/`Both` → inner
		// ` )` pad). No flag → tight `_dt(trailText)` byte-identical.
		if (!isOptional && trailText != null && !hasCondWrap && !hasCondWrapEnd) {
			final trailDoc: Expr = whitespacePolicyTrail(child, trailText, [
				'catchParensInsideClose',
				'switchCondParensInsideClose',
				'whileCondParensInsideClose'
			]);
			// ω-switch-subject-parens: drop the switch-subject close `)` under the
			// same condition as the open `(` (see switchParensStripCond); nothing
			// replaces it — the cases block `{` follows directly.
			if (child.fmtHasFlag('switchSubjectParensStrip')) {
				final cond: Expr = switchParensStripCond(fieldAccess);
				parts.push(macro $cond ? _de() : $trailDoc);
			} else
				parts.push(trailDoc);
		}
		// ω-struct-trailopt-source-track: mandatory-
		// Ref `@:trailOpt(LIT)` field gates the trail emission on the
		// synth slot `<field>TrailPresent:Null<Bool>` so the writer
		// preserves source presence (true -> `;`, false -> ``) rather
		// than always re-emitting the canonical trail. Gate on
		// `hasStructFieldTrailOptSlot` (trivia mode + bearing) so plain
		// mode and non-bearing rules preserve pre-Phase-4 silent-drop
		// behaviour for now. `null` on `<field>TrailPresent` is reserved
		// for raw->paired upcasts from `Converters.rawToPaired_*` and
		// falls through to canonical emit via the `==false` test.
		// omega-ssb-trailopt-drop: a field whose braces may be dropped
		// (`@:fmt(dropSingleStmtBraces)` — `HxIfStmt.thenBody` / `HxForStmt.body` /
		// `HxWhileStmt.body` / `HxDoWhileStmt.body`) never re-emits this slot: a
		// STATEMENT owns its own terminator (`if (c) g();` puts the `;` inside the
		// inner `ExprStmt`), so the slot can only ever hold a REDUNDANT `;`
		// (`for (…) { x; };`). Canonicalising it away removes the `for (…) x;;`
		// hazard at the root instead of defending against it with a keep-braces
		// gate, and matches what the optional `elseBody` path has always done.
		if (
			!hasStructFieldTrailOptSlot || isOptional || hasCondWrap || hasCondWrapEnd || trailOptText == null
			|| child.fmtHasFlag('dropSingleStmtBraces')
		)
			return;
		final sourcePresent: Expr = macro $structTrailOptAccess == false ? _de() : _dt($v{trailOptText});
		parts.push(semicolonBeforeSiblingWrap(child, trailOptText, fieldAccess, sourcePresent) ?? sourcePresent);
	}

	/**
	 * omega-semi-before-else: `@:fmt(semicolonBeforeSibling('<field>'))` routes a mandatory-Ref
	 * `@:trailOpt(LIT)` slot through `opt.semicolonBeforeElse` INSTEAD of plain source presence,
	 * but only for the shape where the named sibling field is present.
	 *
	 * The one consumer is `HxIfExpr.thenBranch`, whose slot holds the `;` Haxe accepts before an
	 * `else` (`final x = if (c) a; else b;`). That `;` is inert -- verified against the compiler,
	 * both `if (c) var x = 1 else var y = 2` and a semicolon-less value-`if` chain compile -- so
	 * `Never` may drop it. The sibling gate is not a refinement but the correctness condition:
	 * with NO `else`, the same slot can hold the terminator of the ENCLOSING statement, which the
	 * grammar has no other place to park, and dropping it would emit code that does not compile.
	 *
	 * Distinct from `optionalSemicolon` (the `}`-terminated statement's own `;`) because a config
	 * legitimately wants opposite answers for the two: TM writes every statement terminator and
	 * no `;` before `else`. Returns null -- caller keeps plain source presence -- for every field
	 * without the meta, so the whole path is byte-inert unless a grammar opts in.
	 */
	private function semicolonBeforeSiblingWrap(
		child: ShapeNode, trailOptText: String, fieldAccess: Expr, sourcePresent: Expr
	): Null<Expr> {
		final args: Null<Array<String>> = child.fmtReadStringArgs('semicolonBeforeSibling');
		if (args == null) return null;
		if (args.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(semicolonBeforeSibling) expects 1 string arg (siblingField), got ${args.length}',
				Context.currentPos()
			);
		final siblingAccess: Null<Expr> = switch fieldAccess.expr {
			case EField(base, _): { expr: EField(base, args[0]), pos: fieldAccess.pos };
			case _: null;
		};
		return siblingAccess == null
			? null
			: macro {
				final _sbeSibling: Bool = $siblingAccess != null;
				switch opt.semicolonBeforeElse {
					case anyparse.format.OptionalSemicolon.Never:
						_sbeSibling ? _de() : $sourcePresent;
					case anyparse.format.OptionalSemicolon.Always:
						_sbeSibling ? _dt($v{trailOptText}) : $sourcePresent;
					case _:
						$sourcePresent;
				}
			};
	}

	/**
	 * The `value.<field>BeforeTrail` access for a mandatory Ref carrying `@:trail`
	 * in a trivia-bearing rule, or null when the field has no such slot. Gate and
	 * host set mirror `Lowering.hasBeforeTrailSlotField` /
	 * `TriviaTypeSynth.isBeforeTrailRef` — the three must agree or the generated
	 * writer reads a field the parser never pushed.
	 */
	private function beforeTrailSlotAccess(
		child: ShapeNode, fieldAccess: Expr, isOptional: Bool, trailText: Null<String>, typePath: String
	): Null<Expr> {
		if (trailText == null || isOptional || child.kind != Ref || !_ctx.trivia || !isTriviaBearing(typePath)) return null;
		return switch fieldAccess.expr {
			case EField(base, name): { expr: EField(base, name + TriviaTypeSynth.BEFORE_TRAIL_SUFFIX), pos: fieldAccess.pos };
			case _: null;
		};
	}

	/**
	 * ω-condwrap-forstmt: at the end of a span-mode condWrap iteration, splice
	 * the accumulated cond-span Doc parts (from `spanStartPartsIdx` to the end of
	 * `parts`) out and replace them with a single `WrapList.emitCondition` call —
	 * the `(` / `)` literals and knob come from `spanInfo`, the inner condDoc is a
	 * runtime `_dc([...])` composite. Rewrites `parts` in place.
	 */
	private function spliceCondWrapEnd(parts: Array<Expr>, spanStartPartsIdx: Int, knob: String, leadStr: String, trailStr: String): Void {
		final spanLen: Int = parts.length - spanStartPartsIdx;
		final spanBuf: Array<Expr> = parts.slice(spanStartPartsIdx, parts.length);
		parts.splice(spanStartPartsIdx, spanLen);
		final innerDoc: Expr = spanBuf.length == 1 ? spanBuf[0] : dcCall(spanBuf);
		final condKnobAccess: Expr = optFieldAccess(knob);
		parts.push(macro {
			final _condRules: anyparse.format.wrap.WrapRules = $condKnobAccess;
			final _condMode: anyparse.format.wrap.WrapMode = _condRules.defaultMode;
			final _chainOvr: Null<anyparse.format.wrap.WrapMode> = _condMode == anyparse.format.wrap.WrapMode.NoWrap ? null : _condMode;
			final opt = _setChainModeOverride(opt, _chainOvr);
			anyparse.format.wrap.WrapList.emitCondition($v{leadStr}, $v{trailStr}, $innerDoc, opt, $condKnobAccess);
		});
	}

	/**
	 * ω-multivar-wrap: build the `@:fmt(multiVarWrap('<knob>', '<moreField>'))`
	 * fold Expr (sole consumer: `HxVarDecl`). Brackets the assembled `parts` so
	 * the `<moreField>` Star gate and head-only recursive self-calls resolve: a
	 * `_suppressMoreEntry` snapshot drops the more-field to `_de()`, the head
	 * binding plus each right-recursion link become head-only item Docs spliced
	 * into one `WrapList.emit('', '', ',', …)` under the `<knob>` cascade; absent
	 * the more-field it falls back to the plain `_dc([parts])`.
	 */
	private function buildMultiVarWrapFold(parts: Array<Expr>, typePath: String, knobName: String, moreFieldName: String): Expr {
		final headPlusMore: Expr = dcCall(parts);
		final knobAccess: Expr = optFieldAccess(knobName);
		final selfFn: String = writeFnFor(typePath);
		final selfIdent: Expr = { expr: EConst(CIdent(selfFn)), pos: Context.currentPos() };
		final moreAccess: Expr = { expr: EField(macro value, moreFieldName), pos: Context.currentPos() };
		final linkMoreAccess: Expr = { expr: EField(macro _link.decl, moreFieldName), pos: Context.currentPos() };
		// In trivia mode the Star collects `Trivial<HxVarMoreT>` so the
		// element is reached via `.node`; in plain mode the Star holds the
		// raw `HxVarMore` directly. Both yield a value whose `.decl` is the
		// next `HxVarDecl(T)` link, so the rest of the walk is identical.
		final linkBind: Expr = _ctx.trivia ? (macro final _link = _ml[0].node) : (macro final _link = _ml[0]);
		// ω-keep-newline-after-sep (increment 1): when this fold's
		// `WrapList.emit` resolves to `WrapMode.Keep`, the engine reproduces
		// each comma-link's source break iff the source placed a newline AFTER
		// the comma (`,\n  next`). That signal lives on the trivia Star
		// element's `Trivial.newlineAfterSep` slot, only available in trivia
		// mode. ω-keep-kw-newline (increment 1b): the HEAD break (`_breaks[0]`)
		// reproduces the source `var`→head newline, threaded onto
		// `opt._varKwNewline` by the `HxStatement.VarStmt` writer. In plain
		// mode `_breaks` stays null and Keep falls back to `shapeNoWrap` glue.
		final breakDecl: Expr = _ctx.trivia
			? (macro final _breaks: Array<Bool> = [_varKwNewlineHead])
			: (macro final _breaks: Null<Array<Bool>> = null);
		final breakStepPush: Expr = _ctx.trivia ? (macro _breaks.push(_ml[0].newlineAfterSep == true)) : (macro {});
		return macro {
			final _suppressMoreEntry: Bool = opt._suppressMore;
			final _varKwNewlineHead: Bool = opt._varKwNewline;
			final opt = _clearSuppressMore(_clearVarKwNewline(opt));
			final _headPlusMore: anyparse.core.Doc = $headPlusMore;
			if (!_suppressMoreEntry && $moreAccess.length > 0) {
				final _items: Array<anyparse.core.Doc> = [$selfIdent(value, _setSuppressMore(opt))];
				$breakDecl;
				var _ml = $moreAccess;
				while (_ml.length > 0) {
					$linkBind;
					$breakStepPush;
					_items.push($selfIdent(_link.decl, _setSuppressMore(opt)));
					_ml = $linkMoreAccess;
				}
				anyparse.format.wrap.WrapList.emit(
					'', '', ',', _items, opt, anyparse.core.Doc.Empty, anyparse.core.Doc.Empty, false, $knobAccess, {
						trailBreak: anyparse.core.Doc.Empty,
						sourceBreakBefore: _breaks
					}
				);
			} else
				_headPlusMore;
		};
	}

	/**
	 * Emit a Star struct field (the `if (isStar)` branch of `lowerStruct`).
	 * Dispatches the optional close-peek Star (`emitOptionalStarField`) vs the
	 * bare / `@:tryparse` Star (inter-Star separator + `emitWriterStarField` +
	 * multiVar gate), then folds this field's padTrailing / metaLineEnd pad and
	 * transparent guard into `prevPadTrailing` and recomputes the cumulative
	 * `prevAnyStarNonEmpty` signal. Pushes into `parts`; returns the two
	 * recomputed loop accumulators (the caller resets `prevBodyField` /
	 * `prevTrailFieldName` to null and `isFirstField` to false).
	 */
	private function emitStarField(
		child: ShapeNode, parts: Array<Expr>, node: ShapeNode, typePath: String, isFirstField: Bool, isRaw: Bool,
		stalePrevBareRefBody: Null<PrevBodyInfo>, prevTrailFieldName: Null<String>, kwLead: Null<String>, fieldName: String,
		prevBodyField: Null<PrevBodyInfo>, prevPadTrailing: Null<Expr>, fieldAccess: Expr, prevAnyStarNonEmpty: Null<Expr>,
		multiVarMoreField: Null<String>, isOptional: Bool, afterAlwaysEmits: Bool = false
	): { prevAnyStarNonEmpty: Null<Expr>, prevPadTrailing: Null<Expr> } {
		if (isOptional) {
			// Optional close-peek Star (first consumer: `HxTypeRef.params`).
			// Empty Doc (`_de()`) is the absent shape.
			emitOptionalStarField(
				child, parts, node, typePath, isFirstField, isRaw, stalePrevBareRefBody, prevTrailFieldName, kwLead, fieldName,
				prevBodyField, prevPadTrailing, fieldAccess
			);
			// ω-pad-trailing-ref: optional Star with @:fmt(padTrailing) fires
			// its trailing-pad ONLY when both `_optVal != null` AND
			// `_optVal.length > 0`; it is transparent when absent OR empty.
			// ω-line-comment-directive-break: no empty-arm disjunct here (unlike
			// the non-optional path below). The only consumers are the cond-comp
			// `elseBody` fields, and `elseBody` is the LAST field of every
			// conditional rule - no sibling separator follows it, so an empty
			// comment-only `#else` arm has nothing to suppress. Add the disjunct
			// if a kw-led optional padTrailing Star ever gains a follower.
			final thisPadTrailing: Null<Expr> = child.fmtHasFlag('padTrailing')
				? (macro $fieldAccess != null && $fieldAccess.length > 0)
				: null;
			final thisTransparent: Expr = macro $fieldAccess == null || $fieldAccess.length == 0;
			return {
				prevAnyStarNonEmpty: null,
				prevPadTrailing: composePadTrailing(prevPadTrailing, thisPadTrailing, thisTransparent)
			};
		}
		// ω-member-meta: inter-Star separator — a non-first bare-tryparse Star
		// following another that may have emitted content gets a leading
		// separator double-gated on prev non-empty AND this non-empty (drops
		// the next field's leading sep when prev fired padTrailing).
		if (isBareTryparseStar(child) && !isFirstField && prevAnyStarNonEmpty != null)
			parts.push(
				buildInterStarSep(prevAnyStarNonEmpty, fieldAccess, prevPadTrailing, buildKeepBlankAfterCtorGate(child, node, typePath))
			);
		// ω-multivar-wrap: gate the `<moreField>` Star emit on the runtime
		// `_suppressMore` entry flag (a head-only recursive self-call drops it
		// to `_de()`).
		final isMultiVarMoreField: Bool = multiVarMoreField != null && fieldName == multiVarMoreField;
		final multiVarPartsStart: Int = parts.length;
		emitWriterStarField(
			child, fieldAccess, parts, child == node.children[node.children.length - 1], typePath, isFirstField, isRaw,
			stalePrevBareRefBody, prevTrailFieldName
		);
		if (isMultiVarMoreField) gateMultiVarMoreParts(parts, multiVarPartsStart);
		// ω-pad-trailing-ref / ω-metadata-line-end-function: non-optional Star
		// pad fires when non-empty (and, for metaLineEndPolicy, the knob is
		// non-None); the Star is transparent when empty.
		final thisPadTrailing: Null<Expr> = starPadTrailing(child, fieldAccess, typePath);
		final thisTransparent: Expr = macro $fieldAccess.length == 0;
		// ω-metastmt-sep: a bare-tryparse Star right after a mandatory Ref
		// seeds the cumulative signal with `true` — the Ref's content is
		// already on the line, so the NEXT bare Ref's separator must fire
		// even when this Star is empty (`@:nullSafety(Off) if` keeps its
		// space). Seeding in the RETURN (not before the inter-Star
		// separator above) keeps that separator quiet for this Star.
		return {
			prevAnyStarNonEmpty: !isBareTryparseStar(child)
				? null
				: afterAlwaysEmits ? (macro true) : orStarNonEmpty(prevAnyStarNonEmpty, fieldAccess),
			prevPadTrailing: composePadTrailing(prevPadTrailing, thisPadTrailing, thisTransparent)
		};
	}

	/**
	 * Emit an optional Ref struct field (the `case Ref if (isOptional)` arm of
	 * `lowerStruct`). Builds the descendant writeCall (opt-fanout flags +
	 * indentValueIfCtor), dispatches the optional body emission across the kw-led
	 * / lead-led / bodyPolicy-only / absent-on arms into `optParts`, appends the
	 * optional-Ref `@:fmt(padTrailing)` pad, and pushes the `_optVal != null ?
	 * optBody : _de()` guard onto `parts`. Returns this field's `thisPadTrailing`
	 * runtime expr (or null).
	 */
	private function emitOptionalRefField(
		child: ShapeNode, parts: Array<Expr>, node: ShapeNode, typePath: String, fieldName: String, fieldAccess: Expr,
		kwLead: Null<String>, leadText: Null<String>, trailText: Null<String>, trailOptText: Null<String>, bodyPolicyFlag: Null<String>,
		bodyPolicyExprFlag: Null<String>, hasElseIf: Bool, elseFieldName: Null<String>, prevBodyField: Null<PrevBodyInfo>,
		prevPadTrailing: Null<Expr>, hasStructFieldTrailOptSlot: Bool, structTrailOptAccess: Null<Expr>, prevTrailFieldName: Null<String>,
		bareSep: Null<Expr>
	): Null<Expr> {
		final refName: String = child.annotations[AnnotationKeys.BASE_REF];
		final writeFn: String = writeFnFor(refName);
		// ω-single-stmt-braces CHAIN symmetry: runtime force-keep for this else's
		// chain. Mid-chain it is already true via `opt._ssbChainSuppress`; at the
		// chain root it is the spine scan over then + else-if bodies. Reused by the
		// unwrap gate (terminal else block) AND the else-if writeCall propagation.
		// `macro false` off-path (plain mode / non-dropSingleStmtBraces field).
		final elseChainSuppressExpr: Expr = buildElseChainSuppressExpr(node, child, fieldAccess);
		final dropElseBraces: Bool = _ctx.trivia && child.fmtHasFlag('dropSingleStmtBraces');
		final thenSiblingKeepsExpr: Expr = dropElseBraces ? buildThenSiblingKeepsProbe(node, typePath) : macro false;
		// ω-single-stmt-braces trailing-comment hoist for the else-body: same gate args as
		// its `unwrapStmt` splice below (elseFollows=false, hasTrailingSemi=false, isThenBody=false)
		// so the hoisted comment fires exactly when the de-brace does.
		final elseTrailCommentExpr: Null<Expr> = dropElseBraces
			? macro anyparse.format.SingleStmtBraces.hoistTrailingComment(
				$fieldAccess, opt.dropSingleStmtBraces, opt._ssbSuppress, false, false, $thenSiblingKeepsExpr || $elseChainSuppressExpr,
				false
			)
			: null;
		// ω-orphan-prefix-decl: same opt-fanout seat the mandatory-Ref path has —
		// `@:fmt(setBoolFlagFromStarCtor(...))` hands the descendant a `_wo` copy
		// carrying the flag the sibling Star's ctor set decides. Without it,
		// `HxTopLevelDecl.decl` going optional dropped `_classExtern` and two
		// corpus fixtures (`emptylines/issue_65_extern_class`,
		// `issue_147_between_fields_with_comments`) went byte-fail.
		final boolFlagArgs: Null<Array<String>> = readBoolFlagStarCtorArgs(child);
		final optArgExpr: Expr = boolFlagArgs != null ? (macro _wo) : optionalRefOptArgExpr(child, refName, elseChainSuppressExpr);
		final rawWriteCall: Expr = buildBoolFlagRawWriteCall(boolFlagArgs, {
			expr: ECall(macro $i{writeFn}, [macro _optVal, optArgExpr]),
			pos: Context.currentPos()
		}, typePath, child.fmtHasFlag('propagateExprPosition'));
		// ω-indent-objectliteral / ω-expr-body-indent-objectliteral: the additive
		// `maybeIndentValueIfCtor` Nest is SKIPPED when a same-field
		// `@:fmt(bodyPolicy)` routes `indentValueIfCtor` through the subtractive
		// `bodyPolicyWrap.indentObjArgs` channel instead.
		final indentObjArgs: Null<Array<String>> = child.fmtReadStringArgs('indentValueIfCtor');
		final writeCall: Expr = foldSsbTrailingComment(
			bodyPolicyFlag != null && indentObjArgs != null ? rawWriteCall : maybeIndentValueIfCtor(rawWriteCall, macro _optVal, child),
			elseTrailCommentExpr
		);
		// Leading separator is runtime-conditional when @:fmt(sameLine(...)) is
		// present; @:fmt(bodyPolicy(...)) replaces the final ' ' before the body
		// with a runtime-switched separator. The per-parent kw-trivia slots are
		// read off `value` and threaded into the kw→body separator inside
		// emitOptionalKwBody.
		final optParts: Array<Expr> = [];
		// ω-N-break-after-eq: lead+RHS bundle handled in emitOptionalRefLead.
		if (kwLead != null)
			emitOptionalKwBody(
				child, optParts, kwLead, fieldName, bodyPolicyFlag, bodyPolicyExprFlag, writeCall, refName, hasElseIf, elseFieldName,
				prevBodyField, typePath, prevPadTrailing, indentObjArgs
			);
		else if (leadText != null)
			emitOptionalRefLead(
				child, optParts, leadText, writeCall, prevBodyField, typePath, prevPadTrailing, trailText, trailOptText,
				hasStructFieldTrailOptSlot, structTrailOptAccess
			);
		else if (bodyPolicyFlag != null)
			emitOptionalBodyPolicyOnly(
				child, optParts, bodyPolicyFlag, bodyPolicyExprFlag, writeCall, refName, hasElseIf, elseFieldName, indentObjArgs,
				prevTrailFieldName
			);
		else
			emitOptionalAbsentOnBody(child, optParts, refName, writeCall, bareSep);
		// ω-pad-trailing-ref: optional-Ref `@:fmt(padTrailing)` pushes a trailing
		// space INSIDE optParts so the pad is emitted only when `_optVal != null`;
		// the tracker expr `$fieldAccess != null` matches that runtime presence
		// guard one-to-one. First consumer: `HxConditionalExpr.elseExpr`.
		final thisPadTrailing: Null<Expr> = child.fmtHasFlag('padTrailing') ? {
			optParts.push(padTrailingDoc(node, child, typePath));
			macro $fieldAccess != null;
		} : null;
		final optBody: Expr = optParts.length == 1 ? optParts[0] : dcCall(optParts);
		// ω-single-stmt-braces: an optional body field carrying
		// `@:fmt(dropSingleStmtBraces)` (trivia mode only — `HxIfStmt.elseBody`)
		// substitutes `_optVal` at its single binding site, so every downstream
		// consumer (writeCall, elseIf ctor pattern, propagateElseIfBranch switch)
		// sees the unwrapped statement. An else-body is never followed by a
		// further `else` at its own level, so `elseFollows` is `false`; ancestor
		// dangling-else frames still apply via `opt._ssbSuppress`. Unwrapping
		// `else { if (c) x; }` yields the `else if` form by construction.
		// `hasTrailingSemi` is `false`: an else-body's own writer path already drops a
		// redundant trailing `;` (`else { x; };` → `else x;`, no `;;`), so — unlike the
		// for / while / then-body splice — de-bracing is always safe and never gated.
		// ω-single-stmt-braces symmetry (gate 7): an else-body must keep its braces whenever
		// the sibling then-body keeps its own (see buildThenSiblingKeepsProbe).
		final optValInit: Expr = dropElseBraces
			? macro {
				var _sv = $fieldAccess;
				if (_sv != null)
					_sv = cast anyparse.format.SingleStmtBraces.unwrapStmt(
						_sv, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, false, false,
						$thenSiblingKeepsExpr || $elseChainSuppressExpr, false
					);
				_sv;
			}
			: valueBraceSymmetryWrap(child, fieldAccess);
		parts.push(macro {
			final _optVal = $optValInit;
			if (_optVal != null)
				$optBody
			else
				_de();
		});
		return thisPadTrailing;
	}

	/**
	 * Locate the mandatory bodyPolicy sibling carrying `dropSingleStmtBraces`
	 * (the then-body) and build its `value.<then>` field-access expr. Shared by
	 * both if/else-body brace-symmetry probes; `null` when there is no such
	 * sibling (a for / while / do body has none).
	 */
	private function findThenSiblingAccess(node: ShapeNode): Null<{ sibling: ShapeNode, name: String, access: Expr }> {
		final thenSibling: Null<ShapeNode> = node.children.find(c ->
			c.annotations.get(AnnotationKeys.BASE_OPTIONAL) != true && c.fmtHasFlag('dropSingleStmtBraces')
		);
		final thenName: Null<String> = thenSibling?.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
		return thenSibling == null || thenName == null ? null : {
			sibling: thenSibling,
			name: thenName,
			access: { expr: EField(macro value, thenName), pos: Context.currentPos() }
		};
	}

	/**
	 * ω-single-stmt-braces gate-7 symmetry probe for an else-body splice. Reaches the
	 * sibling then-body (the mandatory bodyPolicy field carrying `dropSingleStmtBraces`)
	 * and builds a runtime `keepsBraces(value.<then>, ...)` expr so the else keeps its
	 * braces whenever the then keeps its own. Mirrors the then splice's own unwrap args
	 * exactly: `elseFollows=true` (an `else` is present in this branch) plus the then's
	 * real `@:trailOpt(';')` slot. `macro false` (no constraint) when there is no such
	 * sibling.
	 */
	private function buildThenSiblingKeepsProbe(node: ShapeNode, typePath: String): Expr {
		final found: Null<{ sibling: ShapeNode, name: String, access: Expr }> = findThenSiblingAccess(node);
		if (found == null) return macro false;
		final thenAccess: Expr = found.access;
		final trailSlot: String = found.name + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX;
		final thenTrailAccess: Expr = { expr: EField(macro value, trailSlot), pos: Context.currentPos() };
		final thenTrail: Expr = found.sibling.annotations.get(AnnotationKeys.LIT_TRAIL_OPTIONAL) == true && isTriviaBearing(typePath)
			? macro ($thenTrailAccess == true)
			: macro false;
		// The probed sibling IS an if-then-body, so the omega-ssb-wrap arm applies
		// (a bare `if` there renders braced) - pass `isIfThenBody=true`.
		return macro anyparse.format.SingleStmtBraces.keepsBraces(
			$thenAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, true, $thenTrail, true
		);
	}

	/**
	 * ω-single-stmt-braces CHAIN-symmetry runtime force-keep for an else-body
	 * splice. `opt._ssbChainSuppress || chainForcesBraces(value.<then>,
	 * value.<else>, …)` — true mid-chain (propagated from the root) or when THIS
	 * `if` is the chain root and the spine scan finds a brace-keeping branch.
	 * Reaches the sibling then-body via `findThenSiblingAccess`;
	 * `macro opt._ssbChainSuppress` alone when there is no such sibling. Returns
	 * `macro false` off-path (plain mode, or a field without
	 * `@:fmt(dropSingleStmtBraces)`) so the flag is never referenced where the opt
	 * typedef may lack it.
	 */
	private function buildElseChainSuppressExpr(node: ShapeNode, child: ShapeNode, fieldAccess: Expr): Expr {
		if (!_ctx.trivia || !child.fmtHasFlag('dropSingleStmtBraces')) return macro false;
		final found: Null<{ sibling: ShapeNode, name: String, access: Expr }> = findThenSiblingAccess(node);
		if (found == null) return macro opt._ssbChainSuppress;
		final thenAccess: Expr = found.access;
		return macro (opt._ssbChainSuppress
			|| anyparse.format.SingleStmtBraces.chainForcesBraces(
				$thenAccess, $fieldAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress
			));
	}

	/**
	 * ω-single-stmt-braces CHAIN symmetry: wrap an else-body writeCall's opt to
	 * propagate `_ssbChainSuppress` DOWN an else-if spine. SET on an else-if
	 * continuation (its own then-body keeps braces and the signal reaches the next
	 * link), CLEAR on a non-if terminal else so an if-chain nested inside that
	 * block de-braces on its own merits. `e` unchanged off-path (plain mode /
	 * non-dropSingleStmtBraces field / target with no `IfStmt` ctor).
	 *
	 * `e` MUST be a chain rooted at the generated writer function's own `opt` —
	 * the shim is passed `opt` as its `chainBaseArg`, which lets it mutate an
	 * already-cloned link in place instead of copying the 210-field record
	 * again. A chain rooted anywhere else would let it mutate an opt someone
	 * else still holds.
	 */
	private function wrapElseChainSuppress(e: Expr, child: ShapeNode, refName: String, chainSuppressExpr: Expr): Expr {
		if (!_ctx.trivia || !child.fmtHasFlag('dropSingleStmtBraces')) return e;
		final ifPat: Null<Expr> = findCtorPattern(refName, 'IfStmt');
		if (ifPat == null) return e;
		final setExpr: Expr = macro _setSsbChainSuppress($e, $chainSuppressExpr, opt);
		final clearExpr: Expr = macro _setSsbChainSuppress($e, false, opt);
		return {
			expr: ESwitch(macro _optVal, [{ values: [ifPat], expr: setExpr, guard: null }], clearExpr),
			pos: Context.currentPos()
		};
	}

	/**
	 * Finalise a non-Star struct field after its body emission: push the trail
	 * (`emitMandatoryRefTrail`), fold the mandatory-Ref `@:fmt(padTrailing)` pad
	 * and the optional-Ref transparent guard into `prevPadTrailing`, publish the
	 * `@:trail` field name for the next sibling's `AfterTrail` slot, and splice a
	 * span-mode condWrap end. Pushes into `parts`; returns the recomputed loop
	 * accumulators (`prevBodyField` / `prevPadTrailing` / `prevTrailFieldName`).
	 * The caller resets `prevAnyStarNonEmpty` to null and `isFirstField` to false.
	 * `isStar` is always false here (Star fields
	 * early-continue before this block).
	 */
	private function finalizeNonStarField(
		child: ShapeNode, parts: Array<Expr>, node: ShapeNode, typePath: String, fieldName: String, fieldAccess: Expr, isOptional: Bool,
		trailText: Null<String>, trailOptText: Null<String>, hasCondWrap: Bool, hasCondWrapEnd: Bool, hasStructFieldTrailOptSlot: Bool,
		structTrailOptAccess: Null<Expr>, thisPadTrailing: Null<Expr>, prevPadTrailing: Null<Expr>, justWrappedBody: Null<PrevBodyInfo>,
		spanInfo: Null<{
			startIdx: Int,
			endIdx: Int,
			leadText: String,
			trailText: String,
			knob: String
		}>,
		spanStartPartsIdx: Int
	): { prevBodyField: Null<PrevBodyInfo>, prevPadTrailing: Null<Expr>, prevTrailFieldName: Null<String> } {
		emitMandatoryRefTrail(
			child, parts, isOptional, trailText, trailOptText, hasCondWrap, hasCondWrapEnd, hasStructFieldTrailOptSlot,
			structTrailOptAccess, fieldAccess, typePath
		);
		// ω-pad-trailing-ref: bare-Ref `@:fmt(padTrailing)` — mandatory Ref
		// always fires, so push a trailing space unconditionally and set the
		// tracker to a constant `true`. (Optional-Ref padTrailing was pushed
		// inside the optParts wrap; Star fields early-continue.)
		final thisPad: Null<Expr> = if (!isOptional && child.fmtHasFlag('padTrailing')) {
			parts.push(padTrailingDoc(node, child, typePath));
			macro true;
		} else
			thisPadTrailing;
		// `thisTransparent` is null for mandatory bare Ref (always emits visible
		// content), `$fieldAccess == null` for optional Ref (transparent when
		// absent — lets a prev pad signal propagate across an absent middle field).
		final thisTransparent: Null<Expr> = isOptional ? (macro $fieldAccess == null) : null;
		// ω-trivia-after-trail: a mandatory Ref with `@:trail` in trivia-bearing
		// mode publishes its name so the NEXT field's `bodyPolicyWrap` can read
		// `value.<name>AfterTrail`. Optional Refs with `@:lead + @:trail`
		// also publish (mirror of the parser-side `hasAfterTrailSlot` extension).
		final newPrevTrailFieldName: Null<String> = trailText != null && _ctx.trivia && isTriviaBearing(typePath) ? fieldName : null;
		// ω-condwrap-forstmt: end of span-mode iteration — splice the accumulated
		// cond-span Doc parts into a single `WrapList.emitCondition`.
		if (hasCondWrapEnd && spanInfo != null)
			spliceCondWrapEnd(parts, spanStartPartsIdx, spanInfo.knob, spanInfo.leadText, spanInfo.trailText);
		return {
			prevBodyField: justWrappedBody,
			prevPadTrailing: composePadTrailing(prevPadTrailing, thisPad, thisTransparent),
			prevTrailFieldName: newPrevTrailFieldName
		};
	}

	/**
	 * Read one struct field's per-iteration metadata (literal / kind / condWrap /
	 * trailOpt-slot facts) used by the field-emit branches of `lowerStruct`.
	 * Validates a `@:fmt(condWrap)` field via `validateCondWrap` (throws on
	 * violation). Pure w.r.t. loop state — the caller applies `isSpanStart` to
	 * `spanStartPartsIdx`.
	 */
	private function readFieldMeta(
		child: ShapeNode, spanInfo: Null<{
			startIdx: Int,
			endIdx: Int,
			leadText: String,
			trailText: String,
			knob: String
		}>,
		fieldIdx: Int, typePath: String
	): FieldMeta {
		final fieldName: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		if (fieldName == null) Context.fatalError('WriterLowering: struct field missing base.fieldName', Context.currentPos());
		final kwLead: Null<String> = child.readMetaString(':kw');
		final leadText: Null<String> = child.readMetaString(':lead');
		final trailText: Null<String> = child.readMetaString(':trail');
		// `@:trailOpt(LIT)` sets `lit.trailText` + `lit.trailOptional=true` in
		// `strategy/Lit.hx`; the writer reads it as a separate `trailOptText` to
		// keep the raw-`@:trail`-only consumers untouched.
		final trailOptText: Null<String> = child.annotations[AnnotationKeys.LIT_TRAIL_OPTIONAL] == true
			? (child.annotations[AnnotationKeys.LIT_TRAIL_TEXT]: Null<String>)
			: null;
		final isStar: Bool = child.kind == Star;
		final isOptional: Bool = child.annotations[AnnotationKeys.BASE_OPTIONAL] == true;
		// ω-condition-wrap-wiring: `@:fmt(condWrap('<knob>'))` on a bare mandatory
		// Ref routes lead+value+trail through the runtime `WrapList.emitCondition`
		// cascade. First consumers: `HxIfStmt.cond`, `HxWhileStmt.cond`.
		final condWrapArgs: Null<Array<String>> = child.fmtReadStringArgs('condWrap');
		final isSpanStart: Bool = spanInfo != null && fieldIdx == spanInfo.startIdx;
		final hasCondWrapEnd: Bool = spanInfo != null && fieldIdx == spanInfo.endIdx;
		if (condWrapArgs != null)
			validateCondWrap(condWrapArgs, leadText, trailText, kwLead, spanInfo != null, isOptional, isStar, child.kind);
		final fieldAccess: Expr = { expr: EField(macro value, fieldName), pos: Context.currentPos() };
		// ω-struct-trailopt-source-track: a trivia-bearing
		// struct-typedef Ref field carrying `@:trailOpt(LIT)` reads
		// `value.<field>TrailPresent:Null<Bool>` (synth slot) so the writer
		// preserves source presence of the trail rather than always re-emitting it.
		final hasStructFieldTrailOptSlot: Bool = !isStar && child.kind == Ref
			&& child.annotations[AnnotationKeys.LIT_TRAIL_OPTIONAL] == true && _ctx.trivia && isTriviaBearing(typePath);
		final structTrailOptAccess: Null<Expr> = hasStructFieldTrailOptSlot ? {
			expr: EField(macro value, fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX),
			pos: Context.currentPos()
		} : null;
		return {
			fieldName: fieldName,
			kwLead: kwLead,
			leadText: leadText,
			trailText: trailText,
			trailOptText: trailOptText,
			isStar: isStar,
			isOptional: isOptional,
			hasElseIf: child.fmtHasFlag('elseIf'),
			condWrapArgs: condWrapArgs,
			isSpanStart: isSpanStart,
			hasCondWrapEnd: hasCondWrapEnd,
			hasCondWrap: condWrapArgs != null,
			fieldAccess: fieldAccess,
			hasStructFieldTrailOptSlot: hasStructFieldTrailOptSlot,
			structTrailOptAccess: structTrailOptAccess
		};
	}

	/**
	 * Emit a bare mandatory Ref struct field (the `case Ref` arm of
	 * `lowerStruct`). Builds the descendant writeCall, then dispatches the body
	 * emission to `emitBodyPolicyBareRef` (when a bare-Ref `@:fmt(bodyPolicy)`
	 * fires) or `emitBareRefNonBodyPolicy` (leftCurly / bodyBreak / non-first-body
	 * / condWrap / arrowBodyLineWrap), and records the bare-Ref body tracker.
	 * Pushes into `parts`; returns the `justWrappedBody` body-info (or null) and
	 * the `prevBareRefBody` tracker.
	 */
	private function emitMandatoryRefField(
		child: ShapeNode, parts: Array<Expr>, typePath: String, fieldAccess: Expr, fieldName: String, bodyPolicyFlag: Null<String>,
		bodyPolicyExprFlag: Null<String>, kwLead: Null<String>, leadText: Null<String>, isRaw: Bool, isFirstField: Bool, hasElseIf: Bool,
		elseFieldName: Null<String>, fallbackFlag: Null<String>, hasCondWrap: Bool, condWrapArgs: Null<Array<String>>,
		spanInfoPresent: Bool, trailText: Null<String>, prevTrailFieldName: Null<String>, prevAnyStarNonEmpty: Null<Expr>,
		prevPadTrailing: Null<Expr>, condFitGroup: Bool
	): { justWrappedBody: Null<PrevBodyInfo>, prevBareRefBody: PrevBodyInfo } {
		final refName: String = child.annotations[AnnotationKeys.BASE_REF];
		final writeFn: String = writeFnFor(refName);
		// (opt-fanout / writeCall assembly lives in buildMandatoryRefWriteCall.)
		final indentObjArgs: Null<Array<String>> = child.fmtReadStringArgs('indentValueIfCtor');
		final deBraced = deBraceBodyAccess(child, fieldAccess, elseFieldName);
		final effAccess: Expr = deBraced.effAccess;
		final ssbSuppressCond: Null<Expr> = deBraced.ssbSuppressCond;
		final ssbTrailCommentExpr: Null<Expr> = deBraced.ssbTrailCommentExpr;
		final writeCall: Expr = buildMandatoryRefWriteCall(
			child, effAccess, typePath, writeFn, bodyPolicyFlag, indentObjArgs, ssbSuppressCond
		);
		// bodyPolicy on a first field: the parent enum-branch Case 3 strips its
		// kwLead trailing space so the separator here is the sole transition
		// token. Non-first-field case (HxIfStmt.thenBody after cond's `)` trail):
		// the trail emits the token literally and bodyPolicyWrap replaces the
		// default ` ` separator.
		final justWrappedBody: Null<PrevBodyInfo> = if (bodyPolicyFlag != null && kwLead == null && leadText == null && !isRaw)
			// Bare-Ref body with @:fmt(bodyPolicy(...)) — see emitBodyPolicyBareRef.
			emitBodyPolicyBareRef(
				child, parts, prevTrailFieldName, isFirstField, fieldName, bodyPolicyFlag, bodyPolicyExprFlag, writeCall, effAccess,
				refName, hasElseIf, elseFieldName, indentObjArgs, fallbackFlag, condFitGroup, ssbTrailCommentExpr
			);
		else {
			// Bare-Ref body without @:fmt(bodyPolicy) — leftCurly / bodyBreak /
			// bareBodyBreaks / non-first-body / condWrap / arrowBodyLineWrap
			// dispatch lives in emitBareRefNonBodyPolicy.
			emitBareRefNonBodyPolicy(
				child, parts, refName, fieldName, typePath, effAccess, writeCall, isFirstField, isRaw, kwLead, leadText, hasCondWrap,
				condWrapArgs, spanInfoPresent, trailText, prevAnyStarNonEmpty, prevPadTrailing
			);
			null;
		};
		// ω-close-trailing-alt / ω-block-shape-aware: track ANY bare-Ref body so
		// the next field can react to its runtime closeTrailing slot; block-shape
		// consumers degrade to a no-op when the target has no block ctors.
		return { justWrappedBody: justWrappedBody, prevBareRefBody: { access: effAccess, typePath: refName } };
	}

	/**
	 * Emit a non-Star field's lead-in before its value: the kw prefix
	 * (`emitKwPrefix`, when `@:kw` is present on a non-optional field — incl. the
	 * `@:fmt(leftCurly)` BracePlacement split) and the mandatory `@:lead` literal
	 * (`emitMandatoryLead`, when present on a non-optional, non-condWrap field).
	 * Pushes into `parts`.
	 */
	private function emitFieldLeadIn(
		child: ShapeNode, parts: Array<Expr>, kwLead: Null<String>, leadText: Null<String>, isOptional: Bool, isFirstField: Bool,
		isRaw: Bool, prevBodyField: Null<PrevBodyInfo>, typePath: String, prevPadTrailing: Null<Expr>, hasCondWrap: Bool,
		hasCondWrapEnd: Bool, prevAnyStarNonEmpty: Null<Expr>, fieldAccess: Expr
	): Void {
		// D61: kw prefix — space before kw (unless first), kw text with trailing
		// space. @:fmt(sameLine(...)) switches the leading space to a hardline;
		// @:fmt(leftCurly) splits the kw emission for a runtime BracePlacement.
		if (kwLead != null && !isOptional)
			emitKwPrefix(child, parts, kwLead, isFirstField, isRaw, prevBodyField, typePath, prevPadTrailing, prevAnyStarNonEmpty);
		// D61: non-optional lead — no space before lead. The end-field of a
		// condWrap span cannot push its own `@:lead` (the open paren is owned by
		// the start field and emitted via the splice's emitCondition wrap).
		if (leadText != null && !isOptional && !hasCondWrap && !hasCondWrapEnd) emitMandatoryLead(child, parts, leadText, fieldAccess);
	}

	/**
	 * ω-single-stmt-braces: compute the body field's runtime access after the
	 * `@:fmt(dropSingleStmtBraces)` de-brace transform, plus the suppress-frame
	 * condition the writeCall opt needs. Extracted verbatim from
	 * `emitMandatoryRefField` (its sole caller) so that function stays under the
	 * cyclomatic-complexity ceiling; off-path (flag absent or plain mode) the
	 * returned `effAccess` is byte-identical to `fieldAccess` and `ssbSuppressCond`
	 * is null.
	 */
	private function deBraceBodyAccess(
		child: ShapeNode, fieldAccess: Expr, elseFieldName: Null<String>
	): { effAccess: Expr, ssbSuppressCond: Null<Expr>, ssbTrailCommentExpr: Null<Expr> } {
		// ω-single-stmt-braces: a body field carrying `@:fmt(dropSingleStmtBraces)`
		// (trivia mode only) substitutes its runtime value with
		// `SingleStmtBraces.unwrapStmt(value.<field>, …)` BEFORE any writeCall /
		// layout / shape dispatch, so a `{ single; }` block body is seen (and laid
		// out) as the bare inner statement everywhere downstream — incl. the next
		// sibling's shape-aware `else` separator and the `semicolonNextLineElse`
		// re-render (both consume the substituted access via `prevBareRefBody`).
		// `elseFollows` (an `else` sibling is present at runtime) arms the
		// dangling-else gate inside the helper; the same condition (narrowed to a
		// then-body that renders WITHOUT braces) wraps the writeCall's opt in
		// `_setSsbSuppress` so unwraps nested deeper in the then-body
		// (e.g. `if (a) while (c) { if (b) x; } else y`) are gated too.
		// `elseFieldName` is non-null only for `HxIfStmt.thenBody` (via
		// `fitLineIfWithElse`'s optionalBodyFieldName channel); for / while bodies
		// pass `false`. Off-path (`dropSingleStmtBraces` absent or plain mode) the
		// access is byte-identical to pre-slice.
		final dropBraces: Bool = _ctx.trivia && child.fmtHasFlag('dropSingleStmtBraces');
		final elseAccess: Null<Expr> = dropBraces && elseFieldName != null ? {
			expr: EField(macro value, elseFieldName),
			pos: Context.currentPos()
		} : null;
		final elseFollowsExpr: Expr = elseAccess == null ? macro false : macro $elseAccess != null;
		// The body's own `@:trailOpt(';')` slot (`value.<field>TrailPresent`): a redundant
		// trailing `;` (`for (…) { x; };`) would become `for (…) x;;` once de-braced — invalid
		// to the Haxe compiler — so it fails the unwrap closed (braces kept).
		// omega-ssb-trailopt-drop: always `false` — the trail slot of a brace-droppable
		// field is no longer emitted (see `emitMandatoryRefTrail`), so the `for (…) x;;`
		// shape the keep-braces gate defended against cannot occur. The gate itself stays
		// as a fail-closed guard for any FUTURE field that both drops braces and emits a trail.
		final trailSemiExpr: Expr = macro false;
		// ω-single-stmt-braces symmetry (gate 7): probe whether the `else` sibling would
		// KEEP its braces. If it does, this then-body keeps its own too - an if/else must
		// de-brace both branches or neither. The else-body's own splice unwraps with
		// `elseFollows=false, hasTrailingSemi=false`, so the probe mirrors those exactly.
		final elseSiblingKeepsExpr: Expr = elseAccess == null
			? macro false
			: macro ($elseAccess != null
				&& anyparse.format.SingleStmtBraces.keepsBraces(
					$elseAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, false, false, false
				));
		// ω-single-stmt-braces CHAIN symmetry: force this then-body to keep its
		// braces when we are mid-chain (`opt._ssbChainSuppress`, propagated from
		// the root) OR when THIS `if` is the chain root and the spine scan finds a
		// keeper. Folded into `siblingKeepsBraces` alongside the immediate-pair
		// probe. For / while / do bodies (no `else` sibling) never force.
		final thenChainSuppressExpr: Expr = elseAccess == null
			? macro false
			: macro (opt._ssbChainSuppress
				|| anyparse.format.SingleStmtBraces.chainForcesBraces(
					$fieldAccess, $elseAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress
				));
		// omega-ssb-wrap: `isIfThenBody` is a MACRO-time discriminator - `elseFieldName`
		// is non-null only for `HxIfStmt.thenBody` (the fitLineIfWithElse
		// optionalBodyFieldName channel), so for / while / do bodies pass `false` and
		// stay exempt from gate 8 and the wrap direction.
		final isThenBodyExpr: Expr = elseFieldName != null ? macro true : macro false;
		final effAccess: Expr = dropBraces
			? macro {
				var _sv = $fieldAccess;
				_sv = cast anyparse.format.SingleStmtBraces.unwrapStmt(
					_sv, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, $elseFollowsExpr, $trailSemiExpr,
					$elseSiblingKeepsExpr || $thenChainSuppressExpr, $isThenBodyExpr
				);
				_sv;
			}
			: tryBraceSymmetryWrap(
				// omega-try-brace-symmetry composes here rather than in a branch of its own: a field
				// carries at most ONE of the two symmetry metas, so each wrap is inert for the other's
				// fields and the pair is byte-identical to the pre-slice access without either.
				child,
				valueBraceSymmetryWrap(child, fieldAccess)
			);
		// The runtime gate includes `opt.dropSingleStmtBraces` so the default-off
		// path never allocates a suppress-frame opt copy (byte-inert AND
		// allocation-inert).
		// omega-ssb-span-precision: the frame is armed ONLY when the then-body renders
		// WITHOUT braces. A brace-bearing then-body ends on its own `}`, which seals the
		// whole subtree from the trailing `else` - nothing inside it can be on the
		// then-body's trailing spine, so suppressing there is pure over-keeping.
		// `keepsBraces` mirrors the then splice's own arguments; it answers `false` for a
		// branch that gate 7 would WRAP, which arms the frame needlessly but never
		// disarms it wrongly (fail closed).
		final ssbSuppressCond: Null<Expr> = elseAccess == null
			? null
			: macro ($elseAccess != null && opt.dropSingleStmtBraces
				&& !anyparse.format.SingleStmtBraces.keepsBraces(
					$fieldAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, true, $trailSemiExpr, true
				));
		// ω-single-stmt-braces trailing-comment hoist: when the de-brace fires AND the
		// single statement carries a same-line trailing comment, `hoistTrailingComment`
		// returns it (else null) so `buildBodyWriteCall` folds it after the bare
		// statement's own `;`. Same gate args as the `unwrapStmt` splice above.
		final ssbTrailCommentExpr: Null<Expr> = dropBraces
			? macro anyparse.format.SingleStmtBraces.hoistTrailingComment(
				$fieldAccess, opt.dropSingleStmtBraces, opt._ssbSuppress, $elseFollowsExpr, $trailSemiExpr,
				$elseSiblingKeepsExpr || $thenChainSuppressExpr, $isThenBodyExpr
			)
			: null;
		return { effAccess: effAccess, ssbSuppressCond: ssbSuppressCond, ssbTrailCommentExpr: ssbTrailCommentExpr };
	}

	/**
	 * ω-bracket-config: runtime-dispatched sibling of
	 * `delimInsidePolicySpace` for the `HxExpr.ArrayExpr` `[…]` Star,
	 * whose ONE ctor covers three fork bracket kinds (array-literal /
	 * map-literal / comprehension). The kind is decided at write time by
	 * the generated `arrayBracketKind(<first element>)` classifier (on
	 * the first element's enum ctor: `Arrow`→map, `ForExpr`/`WhileExpr`→
	 * comprehension, else array-literal). The resolved kind selects one of
	 * the three `{arrayLiteral|mapLiteral|comprehension}Brackets<Open|
	 * Close>` policy fields, then the same open→After/Both / close→Before/
	 * Both → `_dt(' ')` collapse as `delimInsidePolicySpace` produces the
	 * inside-space Doc.
	 *
	 * `firstAccess` is the runtime Expr reading the first Star element
	 * (`_arr[0].node` in trivia mode, `_args[0]` in plain mode — the
	 * bare element enum either way). Emitted as a block so the
	 * classifier runs once per side. Default `None` on every kind keeps
	 * the tight `[1]` / `[1 => "a"]` / `[for …]` byte-identical to the
	 * pre-slice layout. Empty `[]` never reaches this helper — both emit
	 * paths short-circuit `items.length == 0` before padding.
	 */
	private function arrayBracketInsidePolicySpace(firstAccess: Expr, isClose: Bool): Expr {
		final suffix: String = isClose ? 'Close' : 'Open';
		final mapField: Expr = optFieldAccess('mapLiteralBrackets$suffix');
		final comprField: Expr = optFieldAccess('comprehensionBrackets$suffix');
		final arrayField: Expr = optFieldAccess('arrayLiteralBrackets$suffix');
		final kindCases: Array<Case> = [
			{ values: [macro 1], expr: mapField, guard: null },
			{ values: [macro 2], expr: comprField, guard: null }
		];
		final policyExpr: Expr = { expr: ESwitch(macro _abk, kindCases, arrayField), pos: Context.currentPos() };
		final spaceSwitch: Expr = buildPolicySwitch(['anyparse', 'format', 'WhitespacePolicy'], macro _abp, [
			{ values: isClose ? ['Before', 'Both'] : ['After', 'Both'], expr: macro _dt(' ') }
		], macro _de());
		// The classifier is the generated typed predicate of this build's
		// AST family (`AstPreds.arrayBracketKind` plain, `AstPredsT.…`
		// trivia — see `AstPredLowering.predClassParts`); a grammar that
		// opts into `bracketKindPad` must provide the marker classes.
		// Kind 0 (ArrayLiteral) is the predicate's own null/other default,
		// so the `arrayLiteralBrackets` policy applies — its `None`
		// default keeps the tight `[1]` form.
		final predCall: Expr = AstPredLowering.predCallExpr(_shape.root, _ctx.trivia, false, ARRAY_BRACKET_KIND_PRED, [firstAccess]);
		return macro {
			final _abk: Int = $predCall;
			final _abp: anyparse.format.WhitespacePolicy = $policyExpr;
			$spaceSwitch;
		};
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
	private function trailOptShapeGateWrap(branch: ShapeNode, trailText: String, rootArg: String): Null<Expr> {
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
		final gateCall: Expr = AstPredLowering.predCallExpr(_shape.root, _ctx.trivia, false, predName, [pathExpr]);
		return macro ($gateCall ? _de() : _dt($v{trailText}));
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
	private function optionalSemicolonWrap(branch: ShapeNode, trailText: String, rootArg: String, presentFlag: Expr): Null<Expr> {
		final args: Null<Array<String>> = branch.fmtReadStringArgs('optionalSemicolon');
		if (args == null || args.length != 1) return null;
		final gateCall: Expr = AstPredLowering.predCallExpr(_shape.root, _ctx.trivia, false, args[0], [macro $i{rootArg}]);
		return macro switch opt.optionalSemicolon {
			case anyparse.format.OptionalSemicolon.Always: _dt($v{trailText});
			case anyparse.format.OptionalSemicolon.Never: $gateCall ? _de() : _dt($v{trailText});
			case _: $presentFlag ? _dt($v{trailText}) : _de();
		};
	}

	/**
	 * ω-switch-subject-parens: the runtime condition under which the switch
	 * subject's parens are dropped — the `dropSwitchSubjectParens` knob is on
	 * AND the subject is not a leading-brace expression (object literal / block,
	 * kept so a brace-first subject never abuts the cases brace). Shared by the
	 * `@:lead('(')` and `@:trail(')')` emit sites of `HxSwitchStmt.expr`
	 * (`@:fmt(switchSubjectParensStrip)`).
	 */
	private function switchParensStripCond(fieldAccess: Expr): Expr {
		return macro opt.dropSwitchSubjectParens && {
			final _sc: String = Type.enumConstructor(cast $fieldAccess);
			_sc != 'ObjectLit' && _sc != 'BlockExpr';
		};
	}

	/**
	 * ω-single-stmt-braces trailing-comment hoist: fold a de-braced single
	 * statement's same-line trailing comment (`ssbTrailCommentExpr`, a runtime
	 * `Null<String>`) after the body's `;` via `foldTrailingIntoBodyGroup`, so it
	 * enters the body's fit/break measurement. Null off the dropSingleStmtBraces
	 * path -> the base writeCall is returned unchanged (byte-inert).
	 */
	private function foldSsbTrailingComment(base: Expr, ssbTrailCommentExpr: Null<Expr>): Expr {
		return ssbTrailCommentExpr == null
			? base
			: macro {
				final _ssbBodyDoc: anyparse.core.Doc = $base;
				final _ssbTc: Null<String> = $ssbTrailCommentExpr;
				_ssbTc != null ? foldTrailingIntoBodyGroup(_ssbBodyDoc, trailingCommentDocVerbatim(_ssbTc, opt)) : _ssbBodyDoc;
			};
	}

	/**
	 * The `<namePrefix>_<ElemRule>` fn-ref a block Star's case-symmetry
	 * pre-pass consumes, or null when the Star does not opt into
	 * `caseSiblingSymmetry` (⇒ `caseSiblingWidthProbeExpr` yields `macro -1`
	 * and no pre-pass runs) or the format generates no AST predicates (⇒ that
	 * builder fatal-errors: the flattener and the structural verdict are
	 * mandatory for an opted-in Star, the same loud failure every other
	 * predicate-only `@:fmt` feature gives - carrying a second,
	 * never-exercised copy of the pre-pass is exactly the drift those features
	 * refuse). The control-flow verdict is the one OPTIONAL member of the
	 * family: it is gated on a second meta and its absence drops an arm rather
	 * than failing (see `caseSiblingControlFlowFnExpr`).
	 *
	 * Resolved from the Star's ELEMENT rule — the same seam as
	 * `tryparseElemCondFn`, though the grammar generates all of these for
	 * `HxSwitchCase` alone, so a `caseSiblingSymmetry` Star over any other
	 * element rule fails at macro time with an unresolved field. Split out of
	 * `emitTriviaBlockStarDispatch` to keep that helper under the complexity
	 * gate.
	 */
	private function casePredFnExpr(caseSymArgs: Null<Array<String>>, elemRefName: String, namePrefix: String): Null<Expr> {
		return !_formatInfo.astPreds || caseSymArgs == null || caseSymArgs.length != 2
			? null
			: AstPredLowering.predFnExpr(_shape.root, true, false, '${namePrefix}_${simpleName(elemRefName)}');
	}

	/**
	 * omega-case-body-controlflow-glue: the CONTROL-FLOW verdict — whether a
	 * unit holds exactly one body statement and that statement is keyword-led
	 * control flow. Paired with the pre-pass's own `flatLength == -1`
	 * measurement, since the statement KIND alone cannot tell an inline-able
	 * `case X: if (c) x();` from a refused `case X: if (c) { x(); }`.
	 */
	private function caseSiblingControlFlowFnExpr(caseSymArgs: Null<Array<String>>, elemRefName: String): Null<Expr> {
		return !elemBodyStarHasFlag(elemRefName, 'refuseGlueOnControlFlowRoot')
			? null
			: casePredFnExpr(caseSymArgs, elemRefName, 'caseUnitControlFlowBody');
	}

	/**
	 * True iff the case-list Star's ELEMENT rule reaches a body Star carrying
	 * `@:fmt(<flag>)` - the macro-time link that keeps the two halves of the
	 * glue refusal gated by ONE meta.
	 *
	 * The refusal itself is read off `HxCaseBranch.body` /
	 * `HxDefaultBranch.stmts` inside the body Star's own emit; the sibling
	 * FORCE that must accompany it is emitted in the case-LIST Star's pre-pass,
	 * a different rule with a different meta. Left ungated, a grammar opting
	 * into `caseSiblingSymmetry` without the body flag would spread every
	 * sibling for a body that then GLUED to its label - the exact contradiction
	 * the symmetry rule exists to prevent.
	 *
	 * The walk is bounded to ONE rule hop on purpose: the element rule's own
	 * Star fields, plus those of the rules its direct `Ref` children name (for
	 * an `Alt` element rule that is each ctor's payload - `CaseBranch` ->
	 * `HxCaseBranch`). Following refs transitively would answer "does the flag
	 * exist ANYWHERE in the grammar", which is true as soon as it is declared
	 * once and would gate nothing.
	 */
	private function elemBodyStarHasFlag(elemRefName: String, flag: String): Bool {
		final elem: Null<ShapeNode> = _shape.rules[elemRefName];
		return elem != null && (ownStarHasFlag(elem, flag) || elem.children.exists(branch -> refStarHasFlag(branch, flag)));
	}

	/** Any direct `Star` child of `node` carrying `@:fmt(<flag>)`. */
	private function ownStarHasFlag(node: ShapeNode, flag: String): Bool {
		return node.children.exists(c -> c.kind == Star && c.fmtHasFlag(flag));
	}

	/** `ownStarHasFlag` on the rules named by `node`'s own direct `Ref` children (one hop, no recursion). */
	private function refStarHasFlag(node: ShapeNode, flag: String): Bool {
		for (child in node.children) {
			final ref: Null<String> = child.annotations.get(AnnotationKeys.BASE_REF);
			if (ref == null) continue;
			final target: Null<ShapeNode> = _shape.rules[ref];
			if (target != null && ownStarHasFlag(target, flag)) return true;
		}
		return false;
	}

	/**
	 * The `opt` argument expression for an optional-Ref field's descendant writer: the
	 * opt-fanout wraps composed in declaration order, the `arrowValueIfBlockOpt` step,
	 * the `propagateElseIfBranch` runtime-ctor switch, and the else-chain suppress
	 * wrap.
	 */
	private function optionalRefOptArgExpr(child: ShapeNode, refName: String, elseChainSuppressExpr: Expr): Expr {
		// ω-issue-423-mech-a / ω-anonfunction-empty-curly /
		// ω-expressionif-collapse: opt-fanout flags wrapping the descendant
		// writer's `opt` arg in `_setExprPosition` / `_setAnonFnBody` /
		// `_setValueIfBranch`.
		final propagateExpr: Bool = child.fmtHasFlag('propagateExprPosition');
		final propagateAnonFn: Bool = child.fmtHasFlag('propagateAnonFnContext');
		final propagateValueIfBranch: Bool = child.fmtHasFlag('propagateValueIfBranch');
		// ω-elseif-body-break: `@:fmt(propagateElseIfBranch)` on `HxIfStmt.elseBody`
		// flags the else-branch recursion's opt with `_inElseIfBranch` — but ONLY
		// when the else-branch runtime ctor is `IfStmt` (an `else if`), matched via
		// the same trivia-aware ctor pattern as the elseIf glue. A block / simple
		// else-branch leaves the flag untouched, so a fitting `if` nested inside an
		// else-block body still keeps its own body inline.
		final propagateElseIfBranch: Bool = child.fmtHasFlag('propagateElseIfBranch');
		var e: Expr = macro opt;
		if (propagateExpr) e = macro _setExprPosition($e, opt);
		if (propagateAnonFn) e = macro _setAnonFnBody($e, opt);
		if (propagateValueIfBranch) e = macro _setValueIfBranch($e, opt);
		e = arrowValueIfBlockOpt(child, e);
		if (propagateElseIfBranch) {
			final ifPat: Null<Expr> = findCtorPattern(refName, 'IfStmt');
			if (ifPat != null) {
				// else-if -> set; a non-if else-branch (block / simple stmt) must
				// CLEAR the flag it may have inherited from a preceding chain link
				// (`if {} else if {} else { … }`) — the block is not an else-branch-if.
				final setExpr: Expr = macro _setElseIfBranch($e, opt);
				final clearExpr: Expr = macro _clearElseIfBranch($e, opt);
				e = {
					expr: ESwitch(macro _optVal, [{ values: [ifPat], expr: setExpr, guard: null }], clearExpr),
					pos: Context.currentPos()
				};
			}
		}
		return wrapElseChainSuppress(e, child, refName, elseChainSuppressExpr);
	}

	/**
	 * The construct-level cond-fit group for a body field carrying an optional `else` sibling --
	 * `BodyGroup` with no else, `Group` with one. On a node carrying `@:fmt(arrowValueIfReflow)` the
	 * `Group` arm is additionally suppressed while the value-if re-flow is active (see the call site);
	 * `_vifFit` exists only on such a node, and is false unless its knob is on, so every other struct
	 * is byte-identical.
	 */
	private function fitGroupExpr(node: ShapeNode, elseAcc: Expr, grpInner: Expr): Expr {
		final grouped: Expr = node.fmtReadStringArgs('arrowValueIfReflow') == null
			? macro _dg($grpInner)
			: macro (_vifFit ? $grpInner : _dg($grpInner));
		return macro $elseAcc == null ? _dbg($grpInner) : $grouped;
	}

	/**
	 * omega-value-brace-symmetry: `@:fmt(valueBraceSymmetry('<siblingField>', '<blockCtor>', '<stmtCtor>',
	 * '<skipCtor>'…))` gives a VALUE-position branch the brace symmetry `SingleStmtBraces` gate 7 gives a
	 * statement one — when the sibling branch is a `{ … }` block, this branch is wrapped in a synthesized
	 * single-statement block of its own.
	 *
	 * The statement gate cannot reach here: it keys on the statement block kind, and a braced branch of a
	 * value-`if` is a block EXPRESSION. What was left is the shape this closes — `if (c) { … } else -1`.
	 *
	 * The block is SYNTHESIZED rather than drawn as braces around the branch's Doc, for the reason gate 8
	 * synthesizes one: the real writer then renders it, so a second format pass over the result produces the
	 * same bytes. A Doc-level wrap would have to reproduce that rendering exactly or `fmt` would stop being
	 * idempotent, with nothing to catch the drift. `SingleStmtBraces.wrapInBlock` builds it — the same
	 * constructor the statement side uses, given the block ctor and a typed `lift` that raises the branch
	 * EXPRESSION into the block's element type.
	 *
	 * Gated on trivia mode (the ctor arity differs in plain mode) and on `opt.dropSingleStmtBraces`, the knob
	 * that already owns the statement-side symmetry: the two are the repair directions of ONE policy.
	 * Returns `fieldAccess` untouched for every field without the meta.
	 */
	private function valueBraceSymmetryWrap(child: ShapeNode, fieldAccess: Expr): Expr {
		final args: Null<Array<String>> = child.fmtReadStringArgs('valueBraceSymmetry');
		if (args == null || !_ctx.trivia) return fieldAccess;
		if (args.length < VALUE_BRACE_SYMMETRY_MIN_ARGS)
			Context.fatalError(
				'WriterLowering: @:fmt(valueBraceSymmetry) expects at least 3 string args (siblingField, blockCtor'
				+ ', stmtCtor, [skipCtor…]), got ${args.length}',
				Context.currentPos()
			);
		final valuePath: Null<String> = child.annotations[AnnotationKeys.BASE_REF];
		if (valuePath == null) return fieldAccess;
		final stmtPath: Null<String> = starElementTypePath(valuePath, args[1]);
		if (stmtPath == null) return fieldAccess;
		final siblingAccess: Expr = { expr: EField(macro value, args[0]), pos: Context.currentPos() };
		final stmtRef: Expr = MacroStringTools.toFieldExpr(ruleCtorPath(stmtPath, args[2]));
		// `$a{…}` in a call-argument position SPLICES its elements as separate arguments — build the
		// array literal itself, so the callee receives ONE `Array<String>`.
		final skipArray: Expr = {
			expr: EArrayDecl([for (c in args.slice(VALUE_BRACE_SYMMETRY_MIN_ARGS)) macro $v{c}]),
			pos: Context.currentPos()
		};
		final blockCtor: String = args[1];
		return macro {
			final _vbsVal = $fieldAccess;
			anyparse.format.SingleStmtBraces.symmetryNeedsValueWrap(
				_vbsVal, $siblingAccess, opt.dropSingleStmtBraces || opt.singleStmtBraceSymmetry, $v{blockCtor}, $skipArray
			)
				? cast anyparse.format.SingleStmtBraces.wrapInBlock(
					cast _vbsVal, $v{blockCtor}, _vbsInner -> $stmtRef(cast _vbsInner, true)
				)
				: _vbsVal;
		};
	}

	/**
	 * The ELEMENT type path of `ctor`'s single Star child in the rule at `typePath`, or null when it has none.
	 *
	 * The element ref sits one level BELOW the Star — `branch → Star → inner Ref` — the same walk
	 * `emitWriterStarField` makes to name its per-element write function. Reading `BASE_REF` off the Star
	 * itself answers null, which is what a value-`if` block ctor looks like from the outside.
	 */
	private function starElementTypePath(typePath: String, ctor: String): Null<String> {
		final rule: Null<ShapeNode> = _shape.rules[typePath];
		if (rule == null || rule.kind != Alt) return null;
		for (branch in rule.children) if (branch.annotations.get(AnnotationKeys.BASE_CTOR) == ctor) {
			final star: Null<ShapeNode> = branch.children.length == 1 && branch.children[0].kind == Star ? branch.children[0] : null;
			return star == null || star.children.length == 0 ? null : star.children[0].annotations.get(AnnotationKeys.BASE_REF);
		}
		return null;
	}

	/**
	 * The Ref target of `fieldName` on `typePath`'s Seq rule, or null when the rule is not a Seq, has
	 * no such field, or the field is not a bare Ref. Mirror of `findElementBodyField`, which answers
	 * the opposite question (which FIELD holds a known type).
	 */
	private function seqFieldRefTarget(typePath: String, fieldName: String): Null<String> {
		final rule: Null<ShapeNode> = _shape.rules[typePath];
		if (rule == null || rule.kind != Seq) return null;
		for (child in rule.children) if (child.kind == Ref && child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == fieldName)
			return child.annotations.get(AnnotationKeys.BASE_REF);
		return null;
	}

	/**
	 * The `lift` closure `SingleStmtBraces.wrapInBlock` takes when the block's ELEMENT type differs
	 * from the wrapped value's — a value form wraps an EXPRESSION into a block expression whose
	 * elements are statements, so the expression has to be raised into one. `macro null` when no lift
	 * is wanted (a statement body wraps into a block of statements, same type) or the element type
	 * cannot be resolved.
	 */
	private function blockElemLift(valuePath: Null<String>, blockCtor: String, stmtCtor: Null<String>): Expr {
		if (valuePath == null || stmtCtor == null) return macro null;
		final stmtPath: Null<String> = starElementTypePath(valuePath, blockCtor);
		if (stmtPath == null) return macro null;
		final stmtRef: Expr = MacroStringTools.toFieldExpr(ruleCtorPath(stmtPath, stmtCtor));
		return macro (_tbsInner -> $stmtRef(cast _tbsInner, true));
	}

	/**
	 * omega-try-brace-symmetry: `@:fmt(tryBraceSymmetry('<catchesField>', '<blockCtor>', '<stmtCtor>'))`
	 * on a try/catch BODY field gives the construct the brace symmetry `SingleStmtBraces` gate 7 gives
	 * an if/else — one verdict for the try body and every `catch` body together, so a construct is
	 * never left braced on one side and bare on the other. `@:fmt(tryDeBrace)` alongside it opts the
	 * form into the DE-brace half; without it the meta only ever adds braces, which is how
	 * `valueBraceSymmetry` treats a value-position branch and why the value forms carry it bare.
	 *
	 * The third arg is optional and names the ctor that raises the wrapped value into the block's
	 * element type — needed by the value forms, absent for the statement one (block of statements).
	 *
	 * Gated on trivia mode (the ctor arity differs in plain mode) and, at runtime, on
	 * `opt.dropSingleStmtBraces`: the same knob already owns both if/else directions, and try/catch is
	 * the third pair of directions of that ONE policy. Returns `fieldAccess` untouched without the meta.
	 */
	private function tryBraceSymmetryWrap(child: ShapeNode, fieldAccess: Expr): Expr {
		final args: Null<Array<String>> = child.fmtReadStringArgs('tryBraceSymmetry');
		if (args == null || !_ctx.trivia) return fieldAccess;
		if (args.length < 2)
			Context.fatalError(
				'WriterLowering: @:fmt(tryBraceSymmetry) expects at least 2 string args (catchesField, blockCtor'
				+ ', [stmtCtor]), got ${args.length}',
				Context.currentPos()
			);
		final catchesAccess: Expr = { expr: EField(macro value, args[0]), pos: Context.currentPos() };
		final blockCtor: String = args[1];
		final liftExpr: Expr = blockElemLift(child.annotations[AnnotationKeys.BASE_REF], blockCtor, args[2]);
		final deBrace: Bool = child.fmtHasFlag('tryDeBrace');
		return macro {
			var _tbs = $fieldAccess;
			_tbs = cast anyparse.format.SingleStmtBraces.trySymmetryBody(
				_tbs, $catchesAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, $v{blockCtor}, $v{deBrace},
				$liftExpr
			);
			_tbs;
		};
	}

	/**
	 * The catches-Star half of `tryBraceSymmetryWrap`:
	 * `@:fmt(tryCatchBraceSymmetry('<bodyField>', '<blockCtor>', '<stmtCtor>'))` on the `catches` Star
	 * substitutes the ARRAY with one whose clause bodies carry the same group verdict the try body got.
	 *
	 * The two metas live on sibling fields of the SAME struct on purpose: only the parent can see both
	 * halves of the group, so neither an opt-flag frame (`_ssbSuppress`) nor a probe from inside a
	 * clause writer is needed — a catch clause's own writer has no way to reach the try body.
	 */
	private function tryCatchesSymmetryWrap(starNode: ShapeNode, fieldAccess: Expr, elemRefName: String): Expr {
		final args: Null<Array<String>> = starNode.fmtReadStringArgs('tryCatchBraceSymmetry');
		if (args == null || !_ctx.trivia) return fieldAccess;
		if (args.length < 2)
			Context.fatalError(
				'WriterLowering: @:fmt(tryCatchBraceSymmetry) expects at least 2 string args (bodyField, blockCtor'
				+ ', [stmtCtor]), got ${args.length}',
				Context.currentPos()
			);
		final bodyAccess: Expr = { expr: EField(macro value, args[0]), pos: Context.currentPos() };
		final blockCtor: String = args[1];
		final liftExpr: Expr = blockElemLift(seqFieldRefTarget(elemRefName, args[0]), blockCtor, args[2]);
		final deBrace: Bool = starNode.fmtHasFlag('tryDeBrace');
		return macro {
			var _tcs = $fieldAccess;
			_tcs = cast anyparse.format.SingleStmtBraces.trySymmetryCatches(
				_tcs, $bodyAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, $v{blockCtor}, $v{deBrace},
				$liftExpr
			);
			_tcs;
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
	private function buildElseSwitchTests(opts: WrapBodyOpts): { same: Null<Expr>, next: Null<Expr> } {
		final cases: Array<Case> = buildElseSwitchCases(opts, macro true, macro false);
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
	private function buildElseSwitchCases(opts: WrapBodyOpts, sameLayoutExpr: Expr, nextLayoutExpr: Expr): Array<Case> {
		final args: Null<Array<String>> = opts.elseSwitchArgs;
		if (args == null) return [];
		if (args.length < 2)
			Context.fatalError(
				'WriterLowering: @:fmt(elseSwitch) expects a knob field name and at least one ctor name, got ${args.length} arg(s)',
				Context.currentPos()
			);
		final patterns: Array<Expr> = [];
		for (i in 1...args.length) {
			final pat: Null<Expr> = findCtorPattern(opts.bodyTypePath, args[i]);
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
	 * Build the field-access Expr `opt.<fieldName>` — used everywhere the
	 * generated writer reads a `WriteOptions` knob (cascade rules, body
	 * policy flags, leftCurly placement, etc.). Replaces 4-line inline
	 * `optFieldAccess(name)`
	 * boilerplate at ~46 sites.
	 *
	 * The sites that build the access with a non-`Context.currentPos()`
	 * position (the `interMemberInfo` / `staticVarSubdivInfo` per-info
	 * loops, now in `TriviaBlockLowering`) stay inline — the helper
	 * assumes `Context.currentPos()`.
	 */
	private static inline function optFieldAccess(fieldName: String): Expr {
		return { expr: EField(macro opt, fieldName), pos: Context.currentPos() };
	}

	/**
	 * Build the field-access Expr `value.<fieldName><BEFORE_NEWLINE_SUFFIX>`
	 * for a trivia-bearing struct field's `<field>BeforeNewline:Bool` synth slot
	 * (created by `TriviaTypeSynth.isBareNonFirstRef`). The slot reads `true`
	 * when the parser captured a source newline in the gap before the field.
	 *
	 * Used by `lowerStruct` for source-newline preservation paths
	 * (issue_48-v2 bare-ref hardline) — also see `beforeNewlineNotAccess` for
	 * the `bodyOnSameLine` inverse used by `bodyPolicyWrap` consumers.
	 */
	private static inline function beforeNewlineAccess(fieldName: String): Expr {
		return {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX),
			pos: Context.currentPos()
		};
	}

	/** ω-region-prefix-blank — `value.<field>BeforeBlank`, sibling of `beforeNewlineAccess`. */
	private static inline function beforeBlankAccess(fieldName: String): Expr {
		return {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_BLANK_SUFFIX),
			pos: Context.currentPos()
		};
	}

	/**
	 * ω-598-member-leading-comment — build `value.<fieldName>BeforeLeading`,
	 * the `Array<String>` of verbatim comments the parser captured in the gap
	 * before a bare non-first Ref field (synth via
	 * `TriviaTypeSynth.isBareNonFirstRef`). Non-empty only when a comment was
	 * dropped between the preceding content (e.g. a member modifier) and the
	 * field's first token; emitted by the bare-Ref non-first separator.
	 */
	private static inline function beforeLeadingAccess(fieldName: String): Expr {
		return {
			expr: EField(macro value, fieldName + TriviaTypeSynth.BEFORE_LEADING_SUFFIX),
			pos: Context.currentPos()
		};
	}

	/**
	 * Build `!value.<fieldName><BEFORE_NEWLINE_SUFFIX>` — the `bodyOnSameLine`
	 * inverse of the trivia BeforeNewline slot, used by `bodyPolicyWrap`'s
	 * `Keep`-policy dispatch and the `bodyPolicyForCtor` runtime wrap.
	 */
	private static inline function beforeNewlineNotAccess(fieldName: String): Expr {
		return {
			expr: EUnop(OpNot, false, beforeNewlineAccess(fieldName)),
			pos: Context.currentPos()
		};
	}

	/** `AstPredsT.<name>(<args>)` — trivia-family predicate call for the static trivia emit helpers. */
	private static function astPredCallT(name: String, args: Array<Expr>): Expr {
		if (_predRootStatic == '')
			Context.fatalError('WriterLowering: predicate mirrors not initialised (astPredCallT before generate())', Context.currentPos());
		return AstPredLowering.predCallExpr(_predRootStatic, true, false, name, args);
	}

	/**
	 * Read a `name(<expr>)` arg from any `@:fmt(...)` entry on the node
	 * and return the inner expression unchanged. Mirror of
	 * `fmtReadString` for cases where the arg should stay a real Haxe
	 * expression (function reference, identifier path) so the macro
	 * can splice it directly into generated code, type-checked by the
	 * compiler. Returns null when the meta is absent or the arg shape
	 * is not exactly `name(<single-expr>)`.
	 */
	private static function fmtReadCall(node: ShapeNode, name: String): Null<Expr> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case ECall({ expr: EConst(CIdent(id)) }, [arg]) if (id == name):
					return arg;
				case _:
			}
		}
		return null;
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
	 * Return the first flag name from `flagNames` that is present on
	 * `node` as an `@:fmt(...)` argument, or `null` if none match.
	 * Shared lookup for ω-E-whitespace's writer helpers.
	 */
	private static function firstFmtFlag(node: ShapeNode, flagNames: Array<String>): Null<String> {
		return flagNames.find(name -> node.fmtHasFlag(name));
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
	 * `isBlockCtorBranch` narrowed to genuine curly-brace block bodies:
	 * the branch must be a block-ctor shape (lead + trail + single `Star`)
	 * AND its `@:lead` literal must open a curly brace (`{`). Bracket
	 * list ctors (`[ … ]`) and any other delimiter are excluded. Used by
	 * the body-placement block-split so `[for …]`-style value lists follow
	 * the resolved body policy instead of the keyword-glue override.
	 */
	private static function isCurlyBlockCtorBranch(branch: ShapeNode): Bool {
		if (!isBlockCtorBranch(branch)) return false;
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		return leadText != null && StringTools.startsWith(leadText, '{');
	}

	private static function isBlockCtorBranch(branch: ShapeNode): Bool {
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		return leadText != null && trailText != null && (branch.children.length == 1 && branch.children[0].kind == Star);
	}

	/**
	 * Sister predicate to `isBlockCtorBranch`: includes `@:fmt(blockShape)`
	 * opt-in ctors that wrap a block via an inner Ref but emit visually as
	 * `kw … { … }` (e.g. `UntypedBlockStmt(body:HxUntypedFnBody)` →
	 * `untyped { … }`). Used ONLY by shape-aware writers that care about
	 * "ends with a `}`" — e.g. `bareBodyBreaks` on a Star where the prev
	 * sibling body decides whether to force a hardline before the next
	 * element. `bodyPolicyWrap`'s body-placement override uses the strict
	 * `isBlockCtorBranch` so per-ctor overrides like
	 * `bodyPolicyOverride('UntypedBlockStmt', 'untypedBody')` still fire.
	 */
	private static function isBlockShapeEquivalentBranch(branch: ShapeNode): Bool {
		return isBlockCtorBranch(branch) || branch.fmtHasFlag('blockShape');
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

	/**
	 * True when the given Star struct field has no `@:lead` / `@:trail`
	 * / `@:sep`, so its emitted Doc is empty whenever the runtime array
	 * is empty. The next bare-Ref field's leading separator must then
	 * be gated on `field.length > 0`, otherwise the writer emits a
	 * dangling space (`\t function` instead of `\tfunction` when
	 * `HxMemberDecl.modifiers` is empty).
	 */
	private static function isBareTryparseStar(child: ShapeNode): Bool {
		if (child.kind != Star) return false;
		final leadText: Null<String> = child.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = child.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = child.annotations[AnnotationKeys.LIT_SEP_TEXT];
		return leadText == null && trailText == null && sepText == null;
	}

	/**
	 * ω-bug-2c-inner-star — extract the cascade emit machinery shared by
	 * `triviaEofStarExpr` (top-level EOF-terminated Star) and
	 * `triviaTryparseStarExpr` (inner tryparse-terminated Star, e.g.
	 * `HxConditionalDecl.body`). Returns five Exprs ready to splice into
	 * the consumer's runtime block:
	 *
	 *  - `initPrev`   — single EVars statement declaring all `_prev*`
	 *                   trackers (placed once, in the outer scope, before
	 *                   the while loop).
	 *  - `initCurr`   — single EVars statement declaring all `_curr*`
	 *                   trackers (placed inside the while body, before
	 *                   `currCompute`).
	 *  - `currCompute`— single EBlock of assignments computing `_curr*`
	 *                   from `_t.node` classifier values.
	 *  - `trackPrev`  — single EBlock of `_prev* = _curr*` assignments
	 *                   (end of iteration).
	 *  - `blanksCount`— Int-typed cascade ternary, fallback
	 *                   `(_t.blankBefore ? 1 : 0)`. Empty info arrays leave
	 *                   only the fallback, so consumers without cascade
	 *                   metas behave byte-identically (the `(0|1)` count
	 *                   matches the existing `if (blankBefore) push(\\n)`
	 *                   path).
	 *
	 * The emitted Exprs reference runtime locals defined in the consumer's
	 * scope: `_t` (per-iteration `_arr[_si]` binding), `opt` (writer
	 * options parameter), and `_v0` (bound by ctor pattern inside switch
	 * cases — local to each pattern body via `BetweenCtorPattern` /
	 * `TransitionAcrossPattern`).
	 *
	 * Sister to `readCascadeInfosFromStar`, which reads the
	 * `@:fmt(blankLines*)` metas off the Star ShapeNode and produces the
	 * info arrays consumed here. The two helpers together let any Star
	 * emit kind opt in to the cascade machinery without duplicating its
	 * implementation.
	 */
	private static function buildCascadeEmit(
		afterInfos: Array<AfterCtorBlankInfo>, beforeInfos: Array<BeforeCtorBlankInfo>, betweenInfos: Array<BetweenCtorBlankInfo>,
		transitionInfos: Array<TransitionAcrossInfo>, headInfos: Array<HeadCtorBlankInfo>,
		?betweenSameIfNotInfos: Array<BetweenSameCtorIfNotInfo>
	): CascadeEmit {
		final betweenIfNotInfos: Array<BetweenSameCtorIfNotInfo> = betweenSameIfNotInfos ?? [];
		final pos: Position = Context.currentPos();

		final acc: CascadeAccum = {
			prevVars: [],
			currVars: [],
			currCompute: [],
			trackPrev: []
		};

		emitAfterCompute(acc, afterInfos, pos);
		emitBeforeCompute(acc, beforeInfos, pos);
		emitBetweenCompute(acc, betweenInfos, pos);
		emitBetweenIfNotCompute(acc, betweenIfNotInfos, pos);
		emitTransitionCompute(acc, transitionInfos, pos);

		// Build cascade ternary from innermost (source-driven) outward —
		// before in reverse, then between in reverse, then transition in
		// reverse, then after in reverse. Final priority (outermost wins
		// first): after[0..N] > between[0..N] > transition[0..N] >
		// before[0..N] > source-driven `(_t.blankBefore ? 1 : 0)`.
		var blanksCountExpr: Expr = macro (_t.blankBefore ? 1 + (_t.blankBefore2 ?? 0) : 0);
		blanksCountExpr = foldBeforeCascade(blanksCountExpr, beforeInfos, pos);
		blanksCountExpr = foldBetweenIfNotCascade(blanksCountExpr, betweenIfNotInfos, pos);
		blanksCountExpr = foldBetweenCascade(blanksCountExpr, betweenInfos, pos);
		blanksCountExpr = foldTransitionCascade(blanksCountExpr, transitionInfos, pos);
		blanksCountExpr = foldAfterCascade(blanksCountExpr, afterInfos, pos);

		final headEmit: Expr = buildHeadEmit(headInfos, pos);
		final initPrev: Expr = acc.prevVars.length > 0 ? { expr: EVars(acc.prevVars), pos: pos } : (macro {});
		final initCurr: Expr = acc.currVars.length > 0 ? { expr: EVars(acc.currVars), pos: pos } : (macro {});
		final currComputeExpr: Expr = acc.currCompute.length > 0 ? { expr: EBlock(acc.currCompute), pos: pos } : (macro {});
		final trackPrevExpr: Expr = acc.trackPrev.length > 0 ? { expr: EBlock(acc.trackPrev), pos: pos } : (macro {});
		return {
			initPrev: initPrev,
			initCurr: initCurr,
			currCompute: currComputeExpr,
			trackPrev: trackPrevExpr,
			blanksCount: blanksCountExpr,
			headEmit: headEmit
		};
	}

	/**
	 * Build the Doc expression for a try-parse trivia Star field
	 * (last field, no `@:trail`, `@:tryparse`). Mirrors the plain-mode
	 * tryparse layout but threads `Trivial<T>` unwrapping through the
	 * loop: when an element carries leading comments, the normal
	 * separator (`sepExpr`) is suppressed in favour of a hardline
	 * followed by each comment on its own line — line-style comments
	 * cannot share a line with trailing content. Between elements
	 * without leading comments the separator runs unchanged.
	 *
	 * Without `@:fmt(nestBody)`, trailing slots are not consulted —
	 * `@:tryparse` rewinds on parse failure so orphan trivia flows
	 * outward to the enclosing Star (matches `HxTryCatchStmt.catches`
	 * behaviour where a comment after the last catch belongs to the
	 * next statement's leading, not to the catches list).
	 *
	 * When `nestBody` is true (`@:fmt(nestBody)`), the whole body Doc
	 * is wrapped in `_dn(_cols, ...)` — one extra indent level — and
	 * every element is preceded by a hardline so the body drops to a
	 * fresh line at inner indent after the preceding field's content
	 * (e.g. a `case X:` pattern). The parser co-captures trailing
	 * orphan comments (own-line comments after the last element, with
	 * no blank-line separator) into the synth trailing slots; the
	 * writer renders them at body-indent right after the last element.
	 * Empty bodies with no trailing orphans emit nothing (no stray
	 * hardline, no dangling nest).
	 * Build a per-flag flat-gate predicate for the case-body
	 * `bodyPolicy` mechanism: `opt.<flag> == Same || (opt.<flag> ==
	 * Keep && !_arr[0].newlineBefore)`. The emitted Expr references
	 * the runtime block's local `_arr` (bound by the outer
	 * `final _arr = $fieldAccess`).
	 *
	 * Used by `triviaTryparseStarExpr.flatGateExpr` for both single-
	 * flag callers (e.g. `bodyPolicy('returnBody')`) and the dual-flag
	 * case-body form (`bodyPolicy('caseBody', 'expressionCase')` on
	 * `HxCaseBranch.body` / `HxDefaultBranch.stmts`). The dual form
	 * dispatches at runtime on `opt._inExprPosition` to pick which
	 * predicate fires; this helper just builds the predicate body for
	 * one flag at a time.
	 * ω-issue-257-else-in-return-switch — read the dual-flag form of
	 * `@:fmt(bodyPolicy('<stmtFlag>')` or `@:fmt(bodyPolicy('<stmtFlag>',
	 * '<exprFlag>'))` from a grammar node. Single-flag form returns
	 * `{stmt, expr: null}`; dual-flag form returns both names. Arity
	 * outside [1, 2] is a fatal error mirroring the policy in
	 * `triviaTryparseStarExpr` for case-body Star fields. Centralised so
	 * the four reader sites (ctor-level branch, optional-Ref shared
	 * branch, mandatory-Ref shared branch, `sameLineSeparator`) stay in
	 * lockstep on validation rules.
	 */
	private static function readBodyPolicyDual(node: ShapeNode): { stmt: Null<String>, expr: Null<String> } {
		final args: Null<Array<String>> = node.fmtReadStringArgs('bodyPolicy');
		if (args == null) return { stmt: null, expr: null };
		if (args.length < 1 || args.length > 2)
			Context.fatalError('WriterLowering: @:fmt(bodyPolicy(...)) takes 1 or 2 args, got ${args.length}', Context.currentPos());
		return { stmt: args[0], expr: args.length == 2 ? args[1] : null };
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

	/** Build `_dc([elem1, elem2, ...])` from a macro-time array of Exprs. */
	private static function dcCall(parts: Array<Expr>): Expr {
		final arr: Expr = { expr: EArrayDecl(parts), pos: Context.currentPos() };
		return macro _dc($arr);
	}

	private static function makeWriteCall(writeFnName: String, valueExpr: Expr, hasPratt: Bool, ctxPrec: Int, ?optExpr: Expr): Expr {
		// ω-value-yielded-if-tail-barrier (SI-1): callers may override the opt
		// arg threaded into the sub-call (e.g. `_setExprPosition(opt)` for the
		// infix `->`/`=>` `.right` operand). Null → the historic `macro opt`,
		// keeping non-overriding callers byte-identical.
		final optArg: Expr = optExpr ?? macro opt;
		final args: Array<Expr> = [valueExpr, optArg];
		if (hasPratt) args.push(macro $v{ctxPrec});
		return {
			expr: ECall(macro $i{writeFnName}, args),
			pos: Context.currentPos()
		};
	}

	private static function getOperatorText(branch: ShapeNode): String {
		return (branch.annotations[AnnotationKeys.PRATT_OP]: Null<String>) ?? branch.annotations[AnnotationKeys.TERNARY_OP];
	}

	private static function hasPrattBranch(node: ShapeNode): Bool {
		return node.children.exists(
			branch -> branch.annotations.get(AnnotationKeys.PRATT_PREC) != null || branch.annotations.get(AnnotationKeys.TERNARY_OP) != null
		);
	}

	private static function hasPostfixBranch(node: ShapeNode): Bool {
		return node.children.exists(branch -> branch.annotations.get(AnnotationKeys.POSTFIX_OP) != null);
	}

	private static function simpleName(typePath: String): String {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	/**
	 * `true` when `s` is a non-empty string whose first character is a
	 * Haxe identifier-start (`a-zA-Z_`). Used by Case 3 single-Ref
	 * emission to detect word-keyword `@:lead` (e.g. `var`, `final`,
	 * `function`) — these are second keywords that need spacing on both
	 * sides, unlike symbol leads (`(`, `{`, `<`, `:`, `?`, `->`, `${`).
	 */
	private static function isWordStart(s: String): Bool {
		if (s == null || s.length == 0) return false;
		final c: Int = s.fastCodeAt(0);
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
	}

	private static function packOf(typePath: String): Array<String> {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}

	private static function findFieldByName(node: ShapeNode, name: String): Null<ShapeNode> {
		return node.children.find(child -> child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == name);
	}

	private static function ctorBranchHasFlag(branch: ShapeNode, flag: String): Bool {
		final meta: Null<Metadata> = branch.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return false;
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case EConst(CIdent(id)) if (id == flag):
					return true;
				case _:
			}
		}
		return false;
	}

	/**
	 * Resolves the positional argument access expression for a synth-ctor
	 * Alt slot, given the slot kind. Returns `null` when the branch does
	 * not carry that slot (synth ctor wasn't extended with the matching
	 * positional arg). Callers must additionally gate on `ctx.trivia &&
	 * isTriviaBearing(typePath)` since these slots only exist on
	 * trivia-mode bearing ctors.
	 *
	 * The slot order mirrors `TriviaTypeSynth.buildEnumCtor` push order:
	 *   CloseTrailing (+ 3 conditional `:lead && !:tryparse` slots) →
	 *   TrailOpt → CaptureSource → BodyPolicyKw → WrapOpenNewline →
	 *   KwNewline → ChainNewline.
	 *
	 * Centralising this walker keeps idx accounting in lockstep with
	 * `buildEnumCtor`; future slot additions become a single chain extend
	 * here instead of touching every consumer.
	 */
	private static function altSlotAccess(branch: ShapeNode, baseIdx: Int, argNames: Array<String>, slot: AltSlot): Null<Expr> {
		// noqa: complexity
		if (!altSlotHasSlot(branch, slot)) return null;
		var idx: Int = baseIdx;
		if (slot == CloseTrailing) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltCloseTrailingBranch(branch)) {
			idx++;
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) idx += 3; // noqa: magic-number
		}
		if (slot == TrailOpt) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltTrailOptBranch(branch)) idx++;
		if (slot == CaptureSource) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isCaptureSourceBranch(branch)) idx++;
		if (slot == BodyPolicyKw) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltBodyPolicyKwBranch(branch)) idx++;
		if (slot == WrapOpenNewline) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltWrapOpenNewlineBranch(branch)) idx++;
		if (slot == KwNewline) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltKwNewlineBranch(branch)) idx++;
		if (slot == ChainNewline) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltChainNewlineBranch(branch)) idx++;
		if (slot == ChainLeadComment) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isAltChainNewlineBranch(branch)) idx++;
		if (slot == ChainAfterComment) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isInfixChainBranch(branch)) idx++;
		if (slot == ChainRhsTrail) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isRhsTrailBranch(branch)) idx++;
		if (slot == TernaryCondTrail) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isTernaryTrailBranch(branch)) idx++;
		if (slot == TernaryThenTrail) return macro $i{argNames[idx]};
		if (TriviaTypeSynth.isTernaryTrailBranch(branch)) idx++;
		return macro $i{argNames[idx]};
	}

	/**
	 * Build the per-branch `BetweenCtorPattern` list for
	 * `@:fmt(blankLinesBetweenSameCtorByLevel)`, classifying each enum
	 * branch as matched / tail-transparent / inert and binding `_v0` on
	 * the payload arg. Returns the patterns plus the matched and
	 * transparent-matched ctor-name sets the caller verifies against.
	 *
	 */
	private static function buildBetweenCtorPatterns(
		enumRule: ShapeNode, ctorNames: Array<String>, transparentCtorNames: Array<String>, pos: Position
	): { patterns: Array<BetweenCtorPattern>, matched: Array<String>, transparentMatched: Array<String> } {
		final patterns: Array<BetweenCtorPattern> = [];
		final matched: Array<String> = [];
		final transparentMatched: Array<String> = [];
		for (branch in enumRule.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			final arity: Int = branch.children.length;
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			final isMatch: Bool = ctorNames.indexOf(ctorName) >= 0;
			final isTransparent: Bool = !isMatch && transparentCtorNames.indexOf(ctorName) >= 0;
			if (isMatch) {
				if (arity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) ctor "$ctorName'
						+ '" must have arity ≥ 1 (first arg is the path payload bound to _v0); got arity $arity',
						Context.currentPos()
					);
				matched.push(ctorName);
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				patterns.push({
					pattern: { expr: ECall(ctorIdent, binders), pos: pos },
					isMatch: true,
					isTransparent: false
				});
			} else if (isTransparent) {
				if (arity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesBetweenSameCtorTailTransparent) ctor "$ctorName" must have arity ≥ 1 ('
						+ 'first arg is the wrapper payload bound to _v0 and passed to the tail-leaf classifier adapter); got arity $arity',
						Context.currentPos()
					);
				transparentMatched.push(ctorName);
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				patterns.push({
					pattern: { expr: ECall(ctorIdent, binders), pos: pos },
					isMatch: false,
					isTransparent: true
				});
			} else {
				final pattern: Expr = arity == 0 ? ctorIdent : {
					expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]),
					pos: pos
				};
				patterns.push({ pattern: pattern, isMatch: false, isTransparent: false });
			}
		}
		return { patterns: patterns, matched: matched, transparentMatched: transparentMatched };
	}

	/**
	 * Whether `branch` carries the synth trivia slot for `slot`, per the
	 * matching `TriviaTypeSynth.isAlt*Branch` predicate.
	 */
	private static function altSlotHasSlot(branch: ShapeNode, slot: AltSlot): Bool {
		return switch slot {
			case CloseTrailing: TriviaTypeSynth.isAltCloseTrailingBranch(branch);
			case TrailOpt: TriviaTypeSynth.isAltTrailOptBranch(branch);
			case CaptureSource: TriviaTypeSynth.isCaptureSourceBranch(branch);
			case BodyPolicyKw: TriviaTypeSynth.isAltBodyPolicyKwBranch(branch);
			case WrapOpenNewline: TriviaTypeSynth.isAltWrapOpenNewlineBranch(branch);
			case KwNewline: TriviaTypeSynth.isAltKwNewlineBranch(branch);
			case ChainNewline, ChainLeadComment: TriviaTypeSynth.isAltChainNewlineBranch(branch);
			case PostfixOpSpace: TriviaTypeSynth.isPostfixOpSpaceBranch(branch);
			case ChainAfterComment: TriviaTypeSynth.isInfixChainBranch(branch);
			case ChainRhsTrail: TriviaTypeSynth.isRhsTrailBranch(branch);
			case TernaryCondTrail, TernaryThenTrail: TriviaTypeSynth.isTernaryTrailBranch(branch);
		};
	}

	/**
	 * Build the top-level classify switch cases for an inter-member-blank-
	 * lines classifier. The `kindFor`/`patternFor` local builders plus the look-through `innerCases`
	 * and the per-ctor `cases` loop.
	 */
	private static function buildInterMemberClassifyCases(c: InterMemberCasesCtx): Array<Case> {
		final enumRule: ShapeNode = c.enumRule;
		final varCtors: Array<String> = c.varCtors;
		final fnCtors: Array<String> = c.fnCtors;
		final condCtor: Null<String> = c.condCtor;
		final bodyField: Null<String> = c.bodyField;
		final fieldName: String = c.fieldName;
		final pos: Position = Context.currentPos();
		// Base var/fn/other kind mapping for the TOP-level classify switch:
		// var family → `1`, fn → `2`, everything else → `0`.
		inline function kindFor(ctorName: String): Expr {
			return if (varCtors.contains(ctorName))
				macro 1;
			else if (fnCtors.contains(ctorName))
				macro 2;
			else
				macro 0;
		}
		// `case <Ctor>(_, …):` pattern for one enum variant, binding the
		// single ctor arg to `_inner` when `bindInner` (the look-through
		// ctor needs the wrapper to reach its body Star).
		inline function patternFor(branch: ShapeNode, ctorName: String, bindInner: Bool): Expr {
			final arity: Int = branch.children.length;
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			return arity == 0 ? ctorIdent : {
				expr: ECall(ctorIdent, [for (i in 0...arity) bindInner && i == 0 ? macro _inner : macro _]),
				pos: pos
			};
		}
		// Nested classify cases for the look-through switch. The look-through
		// is deliberately FUNCTION-ONLY: an inner `fnCtor` member yields kind
		// `2`, EVERYTHING else (including var-family ctors and a nested
		// `condCtor`) yields `0`. The fork's `markClassFieldEmptyLines` pairs
		// the REAL inner fields across the `#if … #end` boundary, factoring in
		// each field's static-ness and visibility (afterStaticVars /
		// afterPrivateVars), and lets the doc-comment policy override the
		// field-type blank for doc-comment-led members. anyparse classifies a
		// whole conditional MEMBER as one outer-loop unit, so promoting a
		// var-bearing conditional to kind `1`/`3` cannot reproduce that
		// field-vs-field static/visibility/doc-comment arbitration and instead
		// over-fires the static-var subdivision cascade (afterStaticVars) and
		// the `none`-doc-comment strip. The function family carries no such
		// subdivision at member scope (afterStaticFunctions etc. are not
		// modelled here) and no doc-comment-strip conflict surfaced in the
		// corpus, so fn-only is the byte-safe subset: two consecutive
		// function-bearing conditional members get a `betweenFunctions` blank,
		// nothing else changes.
		final innerCases: Array<Case> = condCtor == null ? [] : [
			for (branch in enumRule.children) if (branch.annotations.get(AnnotationKeys.BASE_CTOR) != null) {
				final ctorName: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
				{ values: [patternFor(branch, ctorName, false)], guard: null, expr: fnCtors.contains(ctorName) ? macro 2 : macro 0 };
			}
		];
		// A classifier field declared `@:optional` (Haxe `HxMemberDecl.member`,
		// absent for a prefix-only member such as a member-position `#if X #end`
		// region with nothing after it) reaches the switch as null. Without an
		// explicit arm the emitted switch is exhaustive over the ctors only and
		// strict null-safety rejects the subject. Kind `0` is the same answer
		// every non-var / non-fn ctor gets, so a member with no declaration
		// takes part in no blank-line cascade.
		if (condCtor != null) innerCases.push({ values: [macro null], guard: null, expr: macro 0 });
		final cases: Array<Case> = [];
		for (branch in enumRule.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			final isLookThrough: Bool = condCtor != null && ctorName == condCtor;
			final pattern: Expr = patternFor(branch, ctorName, isLookThrough);
			final kindExpr: Expr = if (isLookThrough) {
				// `_inner.<bodyField>[0].node.<classifierField>` — the body
				// Star is trivia-collected so `[0]` is a trivia wrapper with
				// a `.node` raw accessor; `.node.<classifierField>` is the
				// inner member's classifier enum.
				final innerBodyAccess: Expr = { expr: EField(macro _inner, bodyField), pos: pos };
				final innerClassifier: Expr = {
					expr: EField({ expr: EField(macro $innerBodyAccess[0], 'node'), pos: pos }, fieldName),
					pos: pos
				};
				final innerSwitch: Expr = { expr: ESwitch(innerClassifier, innerCases, null), pos: pos };
				macro ($innerBodyAccess.length > 0 ? $innerSwitch : 0);
			} else {
				kindFor(ctorName);
			}
			cases.push({ values: [pattern], guard: null, expr: kindExpr });
		}
		cases.push({ values: [macro null], guard: null, expr: macro 0 });
		return cases;
	}

	/**
	 * Split the `@:fmt(blankLinesOnTransitionAcross)` arg list into subset A
	 * and subset B around the `"|"` separator and run the pre-loop validation
	 * gates (separator position, non-empty sides, A/B disjointness, and
	 * matched-vs-transparent disjointness).
	 */
	private static function splitTransitionAcrossCtors(args: Array<String>, transparentCtorNames: Array<String>): TransitionAcrossSplit {
		final pipeIdx: Int = args.indexOf('|');
		if (pipeIdx < 2 || pipeIdx > args.length - 3)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) requires a "|" separator between subset A and subset B ('
				+ 'with at least one ctor on each side); got args $args',
				Context.currentPos()
			);
		final ctorNamesA: Array<String> = args.slice(1, pipeIdx);
		final ctorNamesB: Array<String> = args.slice(pipeIdx + 1, args.length - 1);
		if (ctorNamesA.length == 0 || ctorNamesB.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) requires at least one ctor on each side of "|"', Context.currentPos()
			);
		for (name in ctorNamesA) if (ctorNamesB.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) ctor "$name'
				+ '" appears in both subset A and subset B — must be in exactly one',
				Context.currentPos()
			);
		for (name in ctorNamesA) if (transparentCtorNames.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) ctor "$name'
				+ '" appears both as a matched (subset A) and transparent ctor on the same Star — must be one or the other',
				Context.currentPos()
			);
		for (name in ctorNamesB) if (transparentCtorNames.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) ctor "$name'
				+ '" appears both as a matched (subset B) and transparent ctor on the same Star — must be one or the other',
				Context.currentPos()
			);
		return { ctorNamesA: ctorNamesA, ctorNamesB: ctorNamesB };
	}

	/**
	 * Build one transition-across switch pattern: a bare ctor ident for arity
	 * 0, else `Ctor(<arg0>, _, …)` where `arg0` is `_v0` when `bindFirst`
	 * (matched subsets A/B bind the first payload) and `_` otherwise (subset
	 * 0 ignores it).
	 */
	private static function transitionPattern(ctorIdent: Expr, arity: Int, bindFirst: Bool, pos: Position): Expr {
		if (arity == 0) return ctorIdent;
		final binders: Array<Expr> = [for (i in 0...arity) bindFirst && i == 0 ? macro _v0 : macro _];
		return { expr: ECall(ctorIdent, binders), pos: pos };
	}

	/**
	 * ω-callarg-own-line-comment: the postfix Star's force-multi shape — one
	 * argument per indented line, each followed by its separator, with an
	 * after-separator trailing comment cuddled onto that separator
	 * (`arg, // note`) and the next hardline terminating it.
	 *
	 * The wrap cascade cannot produce this. Its shapes own the separator, and
	 * `FillLineWithLeadingBreak` builds ONE shared separator Doc reused at every
	 * gap — there is no seam to move a single comma across, and no per-gap flag
	 * (`sepBeforeFlags`) reaches that shape. So a list holding a LINE comment
	 * bypasses the cascade the same way a sep-Star's force-multi branch does: a
	 * `//` runs to the newline, which leaves exactly one legal layout anyway.
	 *
	 * Structurally `lowerPostfixKeepDoc` with an unconditional hardline per
	 * element instead of the source-newline probe. Reads the trailing slots
	 * directly (not `_docs`) because the element loop deliberately leaves an
	 * after-separator comment out of the element's own Doc — its position is a
	 * property of the gap, not of the element.
	 *
	 * The separator is SOURCE-faithful, not positional: `Trivial.sepAfter` says
	 * whether the source actually wrote one. A conditional group that absorbed
	 * the comma (`g(true #if F, false #end, x)`) elides it at that gap, and
	 * emitting one anyway produces `g(true, , x)` once the branch is off — code
	 * that no longer parses, and that the comment-loss guard cannot see because
	 * every comment survived. Same signal the cascade path threads to
	 * `WrapList.emit` as `sepBeforeFlags`.
	 */
	private static function lowerPostfixForceMultiDoc(c: PostfixStarCtx): Expr {
		final tcExpr: Expr = c.tcExpr;
		return macro {
			final _mInner: Array<anyparse.core.Doc> = [];
			var _mj: Int = 0;
			while (_mj < _docs.length) {
				_mInner.push(_dhl());
				_mInner.push(_docs[_mj]);
				final _mTc: Null<String> = _args[_mj].trailingComment;
				final _mAfterSep: Null<String> = _args[_mj].trailingBeforeSep ? null : _mTc;
				// Between elements only when the source wrote a separator there; on the
				// last element when the config asks for a trailing one OR the source
				// itself put one (which is what an after-separator comment proves).
				final _mLast: Bool = _mj == _docs.length - 1;
				if ((!_mLast && _args[_mj].sepAfter) || (_mLast && $tcExpr) || _mAfterSep != null) _mInner.push(_dt($v{c.elemSep}));
				if (_mAfterSep != null) _mInner.push(trailingCommentDocVerbatim(_mAfterSep, opt));
				_mj++;
			}
			final _mCols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			_dwb(_dc([_dt($v{c.postfixOp}), _dn(_mCols, _dc(_mInner)), _dhl(), _dt($v{c.postfixClose})]));
		};
	}

	/**
	 * Build the source-faithful `Keep`-mode args-list Doc for a trivia
	 * postfix Star. The `ω-D9A-keep-callargs` per-arg hand-built layout (`_dhl()` where source
	 * had a newline before the next arg, `_dt(' ')` otherwise) plus the
	 * `argsOpenNewline` leading/trailing hardlines.
	 */
	private static function lowerPostfixKeepDoc(c: PostfixStarCtx): Expr {
		final postfixOp: String = c.postfixOp;
		final postfixClose: String = c.postfixClose;
		final elemSep: String = c.elemSep;
		final tcExpr: Expr = c.tcExpr;
		// ω-D9A-keep-callargs: when the wrap-rules' runtime config
		// sets `defaultMode == WrapMode.Keep`, bypass the cascade
		// and build the args list Doc by hand — `_dhl()` between
		// args when source had `\n` before the next arg
		// (`Trivial<T>.newlineBefore`), `_dt(' ')` otherwise.
		//
		// ω-D9A-keep-callargs-v2: args[0]'s leading source-vertical
		// signal is captured by a dedicated parser slot
		// `argsOpenNewline` (positional `argNames[3]`, sibling of
		// `closeTrailing` at `argNames[2]`). `Trivial<T>.newlineBefore`
		// for args[0] is unreliable because upstream kw-Ref rules
		// (e.g. `catch (e:E)\n\t\ttrace(e);`) drain `ctx.pendingTrivia`
		// into the first `collectTrivia`. The slot is captured BEFORE
		// the per-iter `skipWs(ctx)` so the post-open `\n` is
		// preserved verbatim. Inter-arg signals (i ≥ 1) stay on
		// `Trivial.newlineBefore` — captured by the loop's
		// `collectTrivia(ctx)` AFTER the previous sep, where
		// pendingTrivia is already drained.
		//
		// When `argsOpenNewline=true` the emit also adds a trailing
		// `_dhl()` between the last arg and the close lit so the
		// source-vertical fixture's `\n)` shape round-trips. Sister
		// to `triviaSepStarExpr`'s `ω-keep-objectlit` per-element
		// source-aware leading.
		//
		// JSON-driven: the loader maps `"defaultWrap": "keep"` on
		// the named wrap-rules section → `Keep`. Default
		// `NoWrap` cascades route to `wrapListExpr` (legacy
		// byte-identical).
		final argsOpenNewlineExpr: Expr = { expr: EConst(CIdent(c.argNames[3])), pos: Context.currentPos() };
		return macro {
			final _kArgsOpenNewline: Bool = $argsOpenNewlineExpr;
			final _kInner: Array<anyparse.core.Doc> = [];
			var _kj: Int = 0;
			while (_kj < _docs.length) {
				if (_kj > 0)
					_kInner.push(_args[_kj].newlineBefore ? _dhl() : _dt(' '));
				else if (_kArgsOpenNewline)
					_kInner.push(_dhl());
				_kInner.push(_docs[_kj]);
				final _kIsLast: Bool = _kj == _docs.length - 1;
				if (!_kIsLast)
					_kInner.push(_dt($v{elemSep}));
				else if ($tcExpr)
					_kInner.push(_dt($v{elemSep}));
				_kj++;
			}
			final _kCols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _kOuter: Array<anyparse.core.Doc> = [
				_dt($v{postfixOp}),
				_dn(_kCols, _dc(_kInner)),
			];
			if (_kArgsOpenNewline) _kOuter.push(_dhl());
			_kOuter.push(_dt($v{postfixClose}));
			_dwb(_dc(_kOuter));
		};
	}

	/**
	 * Build the per-iteration `_docs.push(...)` statement for a postfix Star.
	 * In trivia mode it appends the element's verbatim `trailingComment` after
	 * the element Doc; plain mode pushes the bare element.
	 */
	private static function lowerPostfixPushElem(c: PostfixStarCtx): Expr {
		final elemCall: Expr = c.elemCall;
		return c.isTriviaStar
			? macro {
				final _elem: anyparse.core.Doc = $elemCall;
				final _tc: Null<String> = _args[_i].trailingComment;
				// ω-callarg-after-sep-comment: the parser routes a same-line LINE
				// comment that followed the separator into THIS element's trailing
				// slot with `trailingBeforeSep == false`. The separator itself belongs
				// to the layout engine — and one of its shapes
				// (`FillLineWithLeadingBreak`) builds ONE shared separator Doc for
				// every gap, so it cannot be told to move or skip a single one. Such a
				// comment therefore does not go into this element's Doc at all: it is
				// read straight from the slot by `lowerPostfixForceMultiDoc`, which
				// owns both the separator and the line break around it.
				//
				// Scope: this Doc feeds the plain-call path. A call that is a
				// METHOD-CHAIN segment is re-assembled by `wrapWithChainDispatch`'s
				// own per-argument builder, which appends the trailing slot
				// unconditionally and never consults `_forceArgMulti` — so a chained
				// call keeps the pre-separator placement (`m(1 // c\n, 2).n()`).
				// Parseable, idempotent, and strictly better than the refusal it
				// replaces, but not the same shape; moving the chain emitter onto this
				// rule is its own slice.
				final _tcAfterSep: Bool = _tc != null && !_args[_i].trailingBeforeSep;
				if (_tcAfterSep) _forceArgMulti = true;
				// `trailingCommentDocGuarded` already prepends ' ' to
				// the captured content, so the per-arg Doc is just
				// `_elem ++ trailingDoc` — no extra `_dt(' ')`.
				// Group-closer seam: this Star owns the whole `(args)` postfix,
				// so its close paren is emitted on the SAME Doc line as the last
				// argument. A LINE comment cuddled there terminates at `\n` and
				// swallows the `)` (and every token after it up to the source
				// newline), which is why `g(\n\ta // c\n);` used to re-emit as
				// `g(a // c);` - a file that no longer parses. The guarded
				// emitter appends an `OptHardlineSkipBeforeHardline`, which both
				// refuses the flat fit (so the `)` lands on its own line) and
				// drops when the next emit is already a hardline. Inside a
				// force-flat region the renderer DROPS it instead, so
				// `WrapList.shapeNoWrap` skips its `Flatten` marker for a
				// guard-bearing body - the two halves together keep the `)` off
				// the comment's line under ANY wrap cascade. Every sound seam
				// stays byte-identical, and a block comment keeps its legal glue.
				// A BEFORE-separator trailing comment is NOT a force-multi trigger:
				// `trailingCommentDocGuarded`'s render-time break already keeps the
				// following token off its line, whatever shape the cascade picked.
				// Widening the trigger to it would re-wrap every `arg // noqa` call
				// in the tree for no correctness gain.
				var _elemDoc: anyparse.core.Doc = _tc != null && !_tcAfterSep ? _dc([_elem, trailingCommentDocGuarded(_tc, opt)]) : _elem;
				// ω-callarg-leading-comment: glue a captured inline block leading
				// comment before the argument (`/* c */ arg`).
				// ω-callarg-own-line-comment: a LINE comment (or a multi-line block)
				// cannot share the argument's line — it is emitted above the argument
				// with a hardline between, and the list goes force-multi so the open
				// delimiter can never end up glued in front of it. Before this it had
				// nowhere to go and was DROPPED.
				final _lc: Array<String> = _args[_i].leadingComments;
				if (_lc.length > 0) {
					final _leadParts: Array<anyparse.core.Doc> = [];
					// Index-based: `leadingCommentDocRun` is run-aware (it needs the
					// entry's neighbours to compute a run-wide common indent).
					for (_ci in 0..._lc.length) {
						final _c: String = _lc[_ci];
						final _inlineBlock: Bool = StringTools.startsWith(_c, '/*') && _c.indexOf('\n') < 0;
						if (!_inlineBlock) _forceArgMulti = true;
						_leadParts.push(leadingCommentDocRun(_lc, _ci, opt));
						_leadParts.push(_inlineBlock ? _dt(' ') : _dhl());
					}
					_leadParts.push(_elemDoc);
					_elemDoc = _dc(_leadParts);
				}
				_docs.push(_elemDoc);
			}
			: macro _docs.push($elemCall);
	}

	/**
	 * Build the postfix Star's tail expression — the final Doc value of the
	 * generated body. In trivia mode it appends the synth `closeTrailing`
	 * slot's verbatim same-line comment after the assembled call Doc; plain
	 * mode returns the call Doc directly.
	 */
	private static function lowerPostfixTailExpr(c: PostfixStarCtx, dcExpr: Expr): Expr {
		// ω-postfix-call-trailing: when the synth pair grew a
		// `closeTrailing:Null<String>` slot (gated by `isTriviaStar`,
		// which is the same predicate as `isPostfixCloseTrailingBranch`
		// at this site), append `trailingCommentDocGuarded(_trailClose,
		// opt)` after the call's emitted Doc when non-null. The slot
		// holds a same-line trailing `// c` / `/* c */` between `)` and
		// the next expression boundary — captured by Lowering's
		// `lowerPostfixLoop` Star-suffix trivia branch. For chain Calls
		// the chain extractor (`wrapWithChainDispatch`) handles the same
		// slot per segment via its own dispatch; this default-path
		// emission covers non-chain single Calls.
		//
		// Group-closer seam: whatever follows the call on the same Doc line
		// - the statement `;`, an infix tail (`+ 2`), an enclosing call's
		// `)` - is swallowed by a LINE comment emitted here. `return g(1) //
		// c` + newline + `+ 2;` re-emitted as `return g(1) // c + 2;`, which
		// still PARSES and silently drops the `+ 2`. The guarded emitter
		// forces the break; it drops before an already-hardline next emit
		// (the chain-segment `.n()` case), so sound seams stay byte-identical.
		if (!c.isTriviaStar) return dcExpr;
		final closeTrailRef: Expr = {
			expr: EConst(CIdent(c.argNames[2])),
			pos: Context.currentPos()
		};
		return macro {
			final _dcResult: anyparse.core.Doc = $dcExpr;
			final _trailClose: Null<String> = $closeTrailRef;
			_trailClose != null ? _dc([_dcResult, trailingCommentDocGuarded(_trailClose, opt)]) : _dcResult;
		};
	}

	/**
	 * Locate the Call-shaped sibling branch (a postfix Star carrying
	 * `@:fmt(methodChain(...))`) within an enum node, erroring if absent.
	 *
	 */
	private static function locateChainCallBranch(node: ShapeNode): ShapeNode {
		final callBranch: Null<ShapeNode> = node.children.find(b ->
			b.fmtReadString('methodChain') != null && b.children.length == 2 && b.children[1].kind == Star
		);
		if (callBranch == null)
			Context.error(
				'WriterLowering.methodChain: expected a sibling postfix-Star ctor with @:fmt(methodChain(...))', Context.currentPos()
			);
		return callBranch;
	}

	/**
	 * Build the trivia-mode method-chain walk body for `wrapWithChainDispatch`.
	 * Walks the Call/FieldAccess spine right-to-left collecting per-segment
	 * Docs (and parallel source-newline `_breaks` for `Keep` round-trip),
	 * glues bare leading `.field` accesses, captures the receiver's dot-gap
	 * trailing comment, and dispatches to `MethodChainEmit.emit` for a
	 * 2+-segment chain whose receiver ends in a Call (`)`).
	 */
	private static function wrapChainTriviaBody(c: ChainDispatchCtx): Expr {
		final argsListExpr: Expr = c.argsListExpr;
		final argDocsExpr: Expr = c.argDocsExpr;
		final chainRulesExpr: Expr = c.chainRulesExpr;
		final writeIdent: Expr = c.writeIdent;
		final precExpr: Expr = c.precExpr;
		final segCallLeadingBreakExpr: Expr = c.segCallLeadingBreakExpr;
		final body: Expr = c.body;
		// The pattern names `Call` and `FieldAccess` resolve against the
		// switch value's enum (`HxExprT` in trivia mode, `HxExpr` in
		// plain mode). The macro emits the same unqualified ctor names
		// for both modes — Haxe's typer resolves to whichever sibling
		// ctor lives on the `value` parameter's enum.
		//
		// ω-postfix-call-trailing: trivia-mode Call ctor grew a
		// positional `closeTrailing:Null<String>` slot (see
		// `TriviaTypeSynth.isPostfixCloseTrailingBranch`); the trivia
		// branch's pattern matches three args and embeds `_trailClose`
		// into the segment's Doc when non-null. Plain-mode pattern stays
		// 2-arg. Both branches share the rest of the chain walk.
		// ω-methodchain-prev-pclose-gate: mirror fork's
		// `MarkWrapping.markMethodChaining` chain-start rule — a Dot
		// counts as a chain start only when it is preceded by `)` in
		// source. In AST terms: at least one segment in the chain must
		// have a `_prev` that is a Call ctor (which renders ending with
		// `)`). Pure-prefix paths like `haxe.Json.parse(s)` have NO dot
		// after `)` → fork does not mark a chain → no
		// OnePerLineAfterFirst wrap. Without this gate we activate
		// `MethodChainEmit` on every 2+-segment Call/FieldAccess
		// sequence, which over-wraps short type-path chains inside a
		// long enclosing line (the `IfFullLineExceeds` probe sees the
		// rest-of-stack and forces BREAK mode). The gate is
		// conservative — it matches PClose only; `(a + b).foo()` and
		// `a[i].foo()` still fall through to default emission, matching
		// fork's `isDotAfterPClose` PClose-only test (`MarkWrapping.hx:2299`).
		return macro {
			final _segs: Array<anyparse.core.Doc> = [];
			// ω-keep-chain (increment 9): `_breaks` is parallel to `_segs`
			// — entry `i` is whether the source had a newline in the gap
			// before segment `i`'s `.field` lead (the FieldAccess ctor's
			// captured `chainNewline` synth slot). Built in lockstep with
			// `_segs.unshift` so a `WrapMode.Keep` method-chain round-trips
			// the source per-segment dot-boundary line breaks via
			// `MethodChainEmit.shapeKeep`. Trivia-mode only; Plain keeps the
			// 2-arg ctor patterns below and threads no `_breaks` (null →
			// shapeNoWrap, byte-inert).
			final _breaks: Array<Bool> = [];
			var _cursor = value;
			var _receiver = value;
			var _hasCallPrev: Bool = false;
			// ω-methodchain-all-or-nothing / isDotAfterPClose: did the dot that
			// leads the INNERMOST collected segment follow a `)`? The walk runs
			// right-to-left, so the last write is that segment's answer. `false`
			// means the segment is not a chain item at all (fork
			// `MarkWrapping.isDotAfterPClose`) and belongs to the head, which
			// `MethodChainEmit.emit` renders by keeping it glued.
			var _seg0AfterCall: Bool = false;
			// ω-keep-chain-receiver-comment: the inner-most FieldAccess carries
			// its operand's dot-gap trailing comment in the synth
			// `chainLeadComment` slot. When that operand IS the chain receiver
			// (a bare value, the `case _:` of the `switch _prev` below), stash
			// the comment so it can be reattached to the receiver Doc after the
			// walk — a `Keep` chain would otherwise drop it when the per-segment
			// break replaces the source `owner // test` layout.
			var _recTrail: Null<String> = null;
			while (true) {
				switch _cursor {
					// ω-keep-callclose-newline: trivia Call ctor grew a 5th
					// positional `argsCloseNewline`; the chain walk ignores it
					// here (close placement is decided by the outer call's
					// `lowerPostfixStar`, not the per-segment chain emit).
					case Call(_op, _args, _trailClose, _, _, _):
						switch _op {
							case FieldAccess(_prev, _fld, _nl, _opTrail):
								final _argDocs: Array<anyparse.core.Doc> = $argDocsExpr;
								final _argsDoc: anyparse.core.Doc = $argsListExpr;
								final _segDoc: anyparse.core.Doc = _trailClose != null
									? _dc([_dt('.' + _fld), _argsDoc, trailingCommentDocVerbatim(_trailClose, opt)])
									: _dc([_dt('.' + _fld), _argsDoc]);
								_segs.unshift(_segDoc);
								_breaks.unshift(_nl);
								switch _prev {
									case Call(_, _, _, _, _, _):
										_hasCallPrev = true;
										_seg0AfterCall = true;
									case _:
										_seg0AfterCall = false;
										if (_opTrail != null) _recTrail = _opTrail;
								}
								_cursor = _prev;
							case _:
								_receiver = _cursor;
								break;
						}
					case FieldAccess(_prev, _fld, _nl, _opTrail):
						// ω-methodchain-glue-bare-field: a bare `.field`
						// access that precedes an already-collected segment
						// (a Call to its right) is NOT its own chain
						// break-item — it glues onto that segment's lead,
						// mirroring fork `MarkWrapping.isDotAfterPClose` (a
						// `.` counts as a chain item only when its previous
						// token is `)`). So `holder.firstField.inner
						// .filter(args)` stays ONE item, not three. When
						// `_segs` is empty the bare field is a trailing
						// access (its own item per fork's PClose-after rule
						// for `a().b`); keep current shape. Without this glue
						// every leading bare FieldAccess over-segments the
						// chain and inflates the cascade item count.
						//
						// ω-keep-chain: when the bare field glues onto
						// `_segs[0]` it becomes that segment's NEW leading
						// dot, so its source-newline (`_nl`) REPLACES the
						// existing `_breaks[0]` (the break-before now refers
						// to the glued lead). When `_segs` is empty the bare
						// field is its own segment → push its `_nl` parallel.
						if (_segs.length > 0) {
							_segs[0] = _dc([_dt('.' + _fld), _segs[0]]);
							_breaks[0] = _nl;
						} else {
							_segs.unshift(_dt('.' + _fld));
							_breaks.unshift(_nl);
						}
						switch _prev {
							case Call(_, _, _, _, _, _):
								_hasCallPrev = true;
								_seg0AfterCall = true;
							case _:
								_seg0AfterCall = false;
								if (_opTrail != null) _recTrail = _opTrail;
						}
						_cursor = _prev;
					case _:
						_receiver = _cursor;
						break;
				}
			}
			if (_segs.length >= 1 && _hasCallPrev) {
				final _recBaseDoc: anyparse.core.Doc = $writeIdent(_receiver, opt, $precExpr);
				// ω-keep-chain-receiver-comment: glue the receiver's captured
				// trailing comment (`owner // test`) to its Doc before the first
				// forced segment break. `trailingCommentDocVerbatim` prepends the
				// leading space, so `_dc([recv, ' // test'])` reproduces the source.
				final _recDoc: anyparse.core.Doc = _recTrail != null
					? _dc([_recBaseDoc, trailingCommentDocVerbatim(_recTrail, opt)])
					: _recBaseDoc;
				// ω-methodchain-reeval-after-callparam nest-suppress prereq:
				// a chain that is itself a CALL ARGUMENT (`_callArgChainNest`)
				// keeps its own dot-break — fork
				// `reEvaluateMethodChainAfterCallParam` never strips chain
				// breaks for a chain inside a breaking outer call
				// (`method_chain_single_arg_break_parens`). Mirror the
				// `BinaryChainEmit` `_chainNestSuppress` gate.
				return anyparse.format.wrap.MethodChainEmit.emit(
					_recDoc, _segs, opt, $chainRulesExpr, _breaks, opt._callArgChainNest, $segCallLeadingBreakExpr, _seg0AfterCall
				);
			}
			$body;
		};
	}

	/**
	 * Build the plain-mode method-chain walk body for `wrapWithChainDispatch`
	 * — the no-trivia twin of `wrapChainTriviaBody` (2-arg Call/FieldAccess
	 * ctor patterns, no `_breaks` / receiver-comment slots).
	 */
	private static function wrapChainPlainBody(c: ChainDispatchCtx): Expr {
		final argsListExpr: Expr = c.argsListExpr;
		final argDocsExpr: Expr = c.argDocsExpr;
		final chainRulesExpr: Expr = c.chainRulesExpr;
		final writeIdent: Expr = c.writeIdent;
		final precExpr: Expr = c.precExpr;
		final segCallLeadingBreakExpr: Expr = c.segCallLeadingBreakExpr;
		final body: Expr = c.body;
		return macro {
			final _segs: Array<anyparse.core.Doc> = [];
			var _cursor = value;
			var _receiver = value;
			var _hasCallPrev: Bool = false;
			// ω-methodchain-all-or-nothing / isDotAfterPClose (plain-mode twin of
			// the trivia walk's tracker): did the innermost collected segment's
			// dot follow a `)`?
			var _seg0AfterCall: Bool = false;
			while (true) {
				switch _cursor {
					case Call(_op, _args):
						switch _op {
							case FieldAccess(_prev, _fld):
								final _argDocs: Array<anyparse.core.Doc> = $argDocsExpr;
								final _argsDoc: anyparse.core.Doc = $argsListExpr;
								_segs.unshift(_dc([_dt('.' + _fld), _argsDoc]));
								switch _prev {
									case Call(_, _):
										_hasCallPrev = true;
										_seg0AfterCall = true;
									case _:
										_seg0AfterCall = false;
								}
								_cursor = _prev;
							case _:
								_receiver = _cursor;
								break;
						}
					case FieldAccess(_prev, _fld):
						// ω-methodchain-glue-bare-field (plain-mode twin of
						// the trivia branch above): glue a bare leading
						// `.field` onto the already-collected segment to its
						// right rather than over-segmenting the chain.
						if (_segs.length > 0)
							_segs[0] = _dc([_dt('.' + _fld), _segs[0]]);
						else
							_segs.unshift(_dt('.' + _fld));
						switch _prev {
							case Call(_, _):
								_hasCallPrev = true;
								_seg0AfterCall = true;
							case _:
								_seg0AfterCall = false;
						}
						_cursor = _prev;
					case _:
						_receiver = _cursor;
						break;
				}
			}
			if (_segs.length >= 1 && _hasCallPrev) {
				final _recDoc: anyparse.core.Doc = $writeIdent(_receiver, opt, $precExpr);
				// ω-methodchain-reeval-after-callparam nest-suppress prereq
				// (plain-mode twin): pass `sourceBreakBefore = null` then the
				// `_callArgChainNest` gate.
				return anyparse.format.wrap.MethodChainEmit.emit(
					_recDoc, _segs, opt, $chainRulesExpr, null, opt._callArgChainNest, $segCallLeadingBreakExpr, _seg0AfterCall
				);
			}
			$body;
		};
	}

	/**
	 * After-ctor cascade compute — single-axis kind tracker per info (plus a
	 * tail-null tracker for tail-adapter infos). Appends to `acc`.
	 */
	private static function emitAfterCompute(acc: CascadeAccum, afterInfos: Array<AfterCtorBlankInfo>, pos: Position): Void {
		for (i => info in afterInfos) {
			acc.prevVars.push({ name: '_prevKindAfter$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currKindAfter$i', type: macro :Int, expr: macro 0 });
			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final kindIdent: Expr = { expr: EConst(CIdent('_currKindAfter$i')), pos: pos };
			if (info.tailAdapterOptField == null) {
				final switchExpr: Expr = { expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos };
				acc.currCompute.push(macro $kindIdent = $switchExpr);
			} else {
				// ω-after-conditional-block — additionally track whether the
				// matched element's tail-leaf classify returns null (tail is NOT
				// import / using). The matched classify case binds `_v0` (the
				// wrapper payload); run the adapter on it inside that case body so
				// both trackers are set from one switch. `info.classifyCases` has
				// `expr: 1` on the matched (`_v0`-binding) case and `expr: 0`
				// elsewhere — rewrite each into a `{kind = …; tailNull = …}` block.
				acc.currVars.push({ name: '_currTailNullAfter$i', type: macro :Int, expr: macro 0 });
				acc.prevVars.push({ name: '_prevTailNullAfter$i', type: macro :Int, expr: macro 0 });
				final tailNullIdent: Expr = { expr: EConst(CIdent('_currTailNullAfter$i')), pos: pos };
				final adapterCall: Expr = astPredCallT(info.tailAdapterOptField, [macro _v0]);
				final dualCases: Array<Case> = [
					for (c in info.classifyCases) {
						// The builder marks the single matched (`_v0`-binding) case
						// with `expr: macro 1`; every non-matched case is `macro 0`.
						final isMatchCase: Bool = switch (c.expr != null ? c.expr.expr : null) {
							case EConst(CInt('1', _)): true;
							case _: false;
						};
						{
							values: c.values,
							guard: c.guard,
							expr: isMatchCase
								? macro {
									$kindIdent = 1;
									$tailNullIdent = $adapterCall == null ? 1 : 0;
								}
								: macro {
									$kindIdent = 0;
									$tailNullIdent = 0;
								}
						}
					}
				];
				acc.currCompute.push({ expr: ESwitch(classifierAccess, dualCases, null), pos: pos });
				final tnLhs: Expr = { expr: EConst(CIdent('_prevTailNullAfter$i')), pos: pos };
				final tnRhs: Expr = { expr: EConst(CIdent('_currTailNullAfter$i')), pos: pos };
				acc.trackPrev.push(macro $tnLhs = $tnRhs);
			}
			final tlhs: Expr = { expr: EConst(CIdent('_prevKindAfter$i')), pos: pos };
			final trhs: Expr = { expr: EConst(CIdent('_currKindAfter$i')), pos: pos };
			acc.trackPrev.push(macro $tlhs = $trhs);
		}
	}

	/**
	 * Before-ctor cascade compute — same single-axis shape as after-ctor with
	 * separate idents, plus an optional `prevExcludeCases` binary tracker.
	 * Appends to `acc`.
	 */
	private static function emitBeforeCompute(acc: CascadeAccum, beforeInfos: Array<BeforeCtorBlankInfo>, pos: Position): Void {
		for (i => info in beforeInfos) {
			acc.prevVars.push({ name: '_prevKindBefore$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currKindBefore$i', type: macro :Int, expr: macro 0 });
			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final switchExpr: Expr = { expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos };
			final lhs: Expr = { expr: EConst(CIdent('_currKindBefore$i')), pos: pos };
			acc.currCompute.push(macro $lhs = $switchExpr);
			final tlhs: Expr = { expr: EConst(CIdent('_prevKindBefore$i')), pos: pos };
			final trhs: Expr = { expr: EConst(CIdent('_currKindBefore$i')), pos: pos };
			acc.trackPrev.push(macro $tlhs = $trhs);
			// ω-before-multiline-prev-not — second binary classify-switch on
			// the same classifier field, tracking whether the element matched
			// an excluded-prev ctor (e.g. `Conditional`). Only built when the
			// info carries `prevExcludeCases`; the ternary below adds a
			// `_prevKindPrevExcl != 1` guard so the override is suppressed when
			// the previous sibling was excluded (falls through to source).
			final prevExcludeCases: Null<Array<Case>> = info.prevExcludeCases;
			if (prevExcludeCases == null) continue;
			acc.prevVars.push({ name: '_prevKindPrevExcl$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currKindPrevExcl$i', type: macro :Int, expr: macro 0 });
			final exclSwitch: Expr = { expr: ESwitch(classifierAccess, prevExcludeCases, null), pos: pos };
			final exclLhs: Expr = { expr: EConst(CIdent('_currKindPrevExcl$i')), pos: pos };
			acc.currCompute.push(macro $exclLhs = $exclSwitch);
			final exclTlhs: Expr = { expr: EConst(CIdent('_prevKindPrevExcl$i')), pos: pos };
			final exclTrhs: Expr = { expr: EConst(CIdent('_currKindPrevExcl$i')), pos: pos };
			acc.trackPrev.push(macro $exclTlhs = $exclTrhs);
		}
	}

	/**
	 * Between-ctor cascade compute — kind+path trackers on head AND tail axes,
	 * transparent-wrapper support via the shared head/tail adapter pair.
	 * Appends to `acc`.
	 */
	private static function emitBetweenCompute(acc: CascadeAccum, betweenInfos: Array<BetweenCtorBlankInfo>, pos: Position): Void {
		for (i => info in betweenInfos) {
			acc.prevVars.push({ name: '_prevTailKindBetween$i', type: macro :Int, expr: macro 0 });
			acc.prevVars.push({ name: '_prevTailPathBetween$i', type: macro :String, expr: macro '' });
			acc.currVars.push({ name: '_currTailKindBetween$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currTailPathBetween$i', type: macro :String, expr: macro '' });
			acc.currVars.push({ name: '_currHeadKindBetween$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currHeadPathBetween$i', type: macro :String, expr: macro '' });

			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final tailKindIdent: Expr = { expr: EConst(CIdent('_currTailKindBetween$i')), pos: pos };
			final tailPathIdent: Expr = { expr: EConst(CIdent('_currTailPathBetween$i')), pos: pos };
			final headKindIdent: Expr = { expr: EConst(CIdent('_currHeadKindBetween$i')), pos: pos };
			final headPathIdent: Expr = { expr: EConst(CIdent('_currHeadPathBetween$i')), pos: pos };

			final ctorNameMatch: Expr = {
				var acc2: Expr = macro false;
				for (cn in info.matchedCtorNames) {
					final lit: Expr = { expr: EConst(CString(cn)), pos: pos };
					acc2 = macro $acc2 || _r.ctorName == $lit;
				}
				acc2;
			};
			final tailBody: Expr = if (info.tailAdapterOptField == null)
				macro {
					$tailKindIdent = 0;
					$tailPathIdent = '';
				}
			else {
				final adapterCall: Expr = astPredCallT(info.tailAdapterOptField, [macro _v0]);
				macro {
					final _r = $adapterCall;
					if (_r != null && $ctorNameMatch) {
						$tailKindIdent = 1;
						$tailPathIdent = _r.path;
					} else {
						$tailKindIdent = 0;
						$tailPathIdent = '';
					}
				};
			}
			final headBody: Expr = if (info.headAdapterOptField == null)
				macro {
					$headKindIdent = 0;
					$headPathIdent = '';
				}
			else {
				final adapterCall: Expr = astPredCallT(info.headAdapterOptField, [macro _v0]);
				macro {
					final _r = $adapterCall;
					if (_r != null && $ctorNameMatch) {
						$headKindIdent = 1;
						$headPathIdent = _r.path;
					} else {
						$headKindIdent = 0;
						$headPathIdent = '';
					}
				};
			}
			final transparentBody: Expr = macro {
				$tailBody;
				$headBody;
			};
			// ω-orphan-prefix-decl: the null arm — same zero body an unmatched
			// ctor gets. See `resolveCtorBlankArgs` for why it is mandatory once
			// the classifier field can be absent.
			final noMatchBody: Expr = macro {
				$tailKindIdent = 0;
				$tailPathIdent = '';
				$headKindIdent = 0;
				$headPathIdent = '';
			};
			final cases: Array<Case> = [
				for (cp in info.ctorPatterns)
					{
						values: [cp.pattern],
						guard: null,
						expr: cp.isMatch
							? macro {
								// `_v0` is the matched ctor's first positional
								// arg. For ctors whose first arg is a leaf path
								// terminal (`HxTypeName` / `HxWildPath` abstracts
								// over `String`), `_v0` IS the path string and
								// `Reflect.hasField` returns false. For ctors
								// whose first arg is a struct sub-rule carrying
								// a `.path` field (`HxImportAlias`), the lookup
								// extracts the dotted-ident path. Multi-arg
								// enum branches are unsupported by the PEG
								// lowering so this is the only struct-payload
								// shape the cascade has to recognise.
								final _v0Path: String = Reflect.hasField(_v0, 'path') ? Std.string(Reflect.field(_v0, 'path')) : '$_v0';
								$tailKindIdent = 1;
								$tailPathIdent = _v0Path;
								$headKindIdent = 1;
								$headPathIdent = _v0Path;
							}
							: cp.isTransparent ? transparentBody : noMatchBody
					}
			];
			cases.push({ values: [macro null], guard: null, expr: noMatchBody });
			acc.currCompute.push({ expr: ESwitch(classifierAccess, cases, null), pos: pos });

			final pkLhs: Expr = { expr: EConst(CIdent('_prevTailKindBetween$i')), pos: pos };
			final pkRhs: Expr = { expr: EConst(CIdent('_currTailKindBetween$i')), pos: pos };
			final ppLhs: Expr = { expr: EConst(CIdent('_prevTailPathBetween$i')), pos: pos };
			final ppRhs: Expr = { expr: EConst(CIdent('_currTailPathBetween$i')), pos: pos };
			acc.trackPrev.push(macro $pkLhs = $pkRhs);
			acc.trackPrev.push(macro $ppLhs = $ppRhs);
		}
	}

	/**
	 * Between-same-ctor-if-not cascade compute — single-axis kind tracker per
	 * info (ω-between-single-line-types). Appends to `acc`.
	 */
	private static function emitBetweenIfNotCompute(
		acc: CascadeAccum, betweenIfNotInfos: Array<BetweenSameCtorIfNotInfo>, pos: Position
	): Void {
		for (i => info in betweenIfNotInfos) {
			acc.prevVars.push({ name: '_prevKindBetweenIfNot$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currKindBetweenIfNot$i', type: macro :Int, expr: macro 0 });
			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final switchExpr: Expr = { expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos };
			final lhs: Expr = { expr: EConst(CIdent('_currKindBetweenIfNot$i')), pos: pos };
			acc.currCompute.push(macro $lhs = $switchExpr);
			final tlhs: Expr = { expr: EConst(CIdent('_prevKindBetweenIfNot$i')), pos: pos };
			final trhs: Expr = { expr: EConst(CIdent('_currKindBetweenIfNot$i')), pos: pos };
			acc.trackPrev.push(macro $tlhs = $trhs);
		}
	}

	/**
	 * Build the `(_r != null && (_r.ctorName == "A" || …)) ? 1 : 0` adapter
	 * match Expr for the transition cascade — `macro 0` when no adapter is
	 * wired.
	 */
	private static function transitionAdapterMatchExpr(adapterField: Null<String>, names: Array<String>, pos: Position): Expr {
		if (adapterField == null) return macro 0;
		var acc: Expr = macro false;
		for (cn in names) {
			final lit: Expr = { expr: EConst(CString(cn)), pos: pos };
			acc = macro $acc || _r.ctorName == $lit;
		}
		return macro _r != null && $acc ? 1 : 0;
	}

	/**
	 * Cross-subset transition cascade compute — A/B subset trackers on head
	 * AND tail axes, transparent-wrapper support via the head/tail adapter
	 * pair. Appends to `acc`.
	 */
	private static function emitTransitionCompute(acc: CascadeAccum, transitionInfos: Array<TransitionAcrossInfo>, pos: Position): Void {
		for (i => info in transitionInfos) {
			acc.prevVars.push({ name: '_prevTailKindAcrossA$i', type: macro :Int, expr: macro 0 });
			acc.prevVars.push({ name: '_prevTailKindAcrossB$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currTailKindAcrossA$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currTailKindAcrossB$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currHeadKindAcrossA$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currHeadKindAcrossB$i', type: macro :Int, expr: macro 0 });

			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final tkaIdent: Expr = { expr: EConst(CIdent('_currTailKindAcrossA$i')), pos: pos };
			final tkbIdent: Expr = { expr: EConst(CIdent('_currTailKindAcrossB$i')), pos: pos };
			final hkaIdent: Expr = { expr: EConst(CIdent('_currHeadKindAcrossA$i')), pos: pos };
			final hkbIdent: Expr = { expr: EConst(CIdent('_currHeadKindAcrossB$i')), pos: pos };
			final tailAdapterCall: Null<Expr> = info.tailAdapterOptField == null
				? null
				: astPredCallT(info.tailAdapterOptField, [macro _v0]);
			final headAdapterCall: Null<Expr> = info.headAdapterOptField == null
				? null
				: astPredCallT(info.headAdapterOptField, [macro _v0]);
			final tailMatchA: Expr = transitionAdapterMatchExpr(info.tailAdapterOptField, info.matchedCtorNamesA, pos);
			final tailMatchB: Expr = transitionAdapterMatchExpr(info.tailAdapterOptField, info.matchedCtorNamesB, pos);
			final headMatchA: Expr = transitionAdapterMatchExpr(info.headAdapterOptField, info.matchedCtorNamesA, pos);
			final headMatchB: Expr = transitionAdapterMatchExpr(info.headAdapterOptField, info.matchedCtorNamesB, pos);
			final transparentBody: Expr = if (tailAdapterCall == null && headAdapterCall == null)
				macro {
					$tkaIdent = 0;
					$tkbIdent = 0;
					$hkaIdent = 0;
					$hkbIdent = 0;
				}
			else if (headAdapterCall == null)
				macro {
					final _r = $tailAdapterCall;
					$tkaIdent = $tailMatchA;
					$tkbIdent = $tailMatchB;
					$hkaIdent = 0;
					$hkbIdent = 0;
				}
			else if (tailAdapterCall == null)
				macro {
					final _r = $headAdapterCall;
					$hkaIdent = $headMatchA;
					$hkbIdent = $headMatchB;
					$tkaIdent = 0;
					$tkbIdent = 0;
				}
			else
				macro {
					final _r = $tailAdapterCall;
					$tkaIdent = $tailMatchA;
					$tkbIdent = $tailMatchB;
					{
						final _r = $headAdapterCall;
						$hkaIdent = $headMatchA;
						$hkbIdent = $headMatchB;
					}
				};
			// ω-orphan-prefix-decl: the null arm — same zero body an unmatched
			// ctor gets. See `resolveCtorBlankArgs` for why it is mandatory once
			// the classifier field can be absent.
			final noMatchBody: Expr = macro {
				$tkaIdent = 0;
				$tkbIdent = 0;
				$hkaIdent = 0;
				$hkbIdent = 0;
			};
			final cases: Array<Case> = [
				for (cp in info.ctorPatterns)
					{
						values: [cp.pattern],
						guard: null,
						expr: switch cp.subset {
							case 1: macro {
								$tkaIdent = 1;
								$tkbIdent = 0;
								$hkaIdent = 1;
								$hkbIdent = 0;
							};
							case 2: macro {
								$tkaIdent = 0;
								$tkbIdent = 1;
								$hkaIdent = 0;
								$hkbIdent = 1;
							};
							case 3: transparentBody; // noqa: magic-number
							case _: noMatchBody;
						}
					}
			];
			cases.push({ values: [macro null], guard: null, expr: noMatchBody });
			acc.currCompute.push({ expr: ESwitch(classifierAccess, cases, null), pos: pos });

			final pkaLhs: Expr = { expr: EConst(CIdent('_prevTailKindAcrossA$i')), pos: pos };
			final pkaRhs: Expr = { expr: EConst(CIdent('_currTailKindAcrossA$i')), pos: pos };
			final pkbLhs: Expr = { expr: EConst(CIdent('_prevTailKindAcrossB$i')), pos: pos };
			final pkbRhs: Expr = { expr: EConst(CIdent('_currTailKindAcrossB$i')), pos: pos };
			acc.trackPrev.push(macro $pkaLhs = $pkaRhs);
			acc.trackPrev.push(macro $pkbLhs = $pkbRhs);
		}
	}

	/**
	 * Fold the before-ctor cascade ternaries onto `blanksCountExpr` (reverse
	 * order so info[0] is outermost). Optional `prevExcludeCases` adds a
	 * `_prevKindPrevExcl != 1` guard.
	 */
	private static function foldBeforeCascade(blanksCountExpr: Expr, beforeInfos: Array<BeforeCtorBlankInfo>, pos: Position): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...beforeInfos.length) {
			final idx: Int = beforeInfos.length - 1 - i;
			final info: BeforeCtorBlankInfo = beforeInfos[idx];
			final beforeAccess: Expr = { expr: EField(macro opt, info.optField), pos: pos };
			final currIdent: Expr = { expr: EConst(CIdent('_currKindBefore$idx')), pos: pos };
			final prevIdent: Expr = { expr: EConst(CIdent('_prevKindBefore$idx')), pos: pos };
			final fallback: Expr = result;
			// ω-before-multiline-prev-not — gate construction: when the info
			// carries `prevExcludeCases`, the fire condition gains a
			// `_prevKindPrevExcl != 1` guard so the override falls through to
			// the source-driven fallback when the previous sibling matched an
			// excluded ctor (e.g. a cond-comp `#if … #end`). Without
			// `prevExcludeCases` the gate is the original two-term form —
			// byte-identical for every existing `blankLinesBeforeCtor{,If}`.
			final gate: Expr = if (info.prevExcludeCases == null)
				macro $currIdent == 1 && $prevIdent != 1;
			else {
				final prevExclIdent: Expr = { expr: EConst(CIdent('_prevKindPrevExcl$idx')), pos: pos };
				macro $currIdent == 1 && $prevIdent != 1 && $prevExclIdent != 1;
			}
			result = macro ($gate ? $beforeAccess : $fallback);
		}
		return result;
	}

	/**
	 * Fold the between-same-ctor-if-not cascade ternaries onto
	 * `blanksCountExpr` — fires `opt.<f>` blanks when both prev and curr
	 * trackers report 1 AND `opt > 0` (ω-between-single-line-types,
	 * insertion-only).
	 */
	private static function foldBetweenIfNotCascade(
		blanksCountExpr: Expr, betweenIfNotInfos: Array<BetweenSameCtorIfNotInfo>, pos: Position
	): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...betweenIfNotInfos.length) {
			final idx: Int = betweenIfNotInfos.length - 1 - i;
			final info: BetweenSameCtorIfNotInfo = betweenIfNotInfos[idx];
			final optAccess: Expr = { expr: EField(macro opt, info.optField), pos: pos };
			final currIdent: Expr = { expr: EConst(CIdent('_currKindBetweenIfNot$idx')), pos: pos };
			final prevIdent: Expr = { expr: EConst(CIdent('_prevKindBetweenIfNot$idx')), pos: pos };
			final fallback: Expr = result;
			result = macro ($currIdent == 1 && $prevIdent == 1 && $optAccess > 0 ? $optAccess : $fallback);
		}
		return result;
	}

	/**
	 * Fold the between-ctor cascade ternaries onto `blanksCountExpr` —
	 * head/tail kind+path match with a null-guarded `differ` adapter call and
	 * the keep-source-blank-across-conditional widening.
	 */
	private static function foldBetweenCascade(blanksCountExpr: Expr, betweenInfos: Array<BetweenCtorBlankInfo>, pos: Position): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...betweenInfos.length) {
			final idx: Int = betweenInfos.length - 1 - i;
			final info: BetweenCtorBlankInfo = betweenInfos[idx];
			final countAccess: Expr = { expr: EField(macro opt, info.countOptField), pos: pos };
			final levelAccess: Expr = { expr: EField(macro opt, info.levelOptField), pos: pos };
			final adapterAccess: Expr = { expr: EField(macro opt, info.adapterOptField), pos: pos };
			final currKindIdent: Expr = { expr: EConst(CIdent('_currHeadKindBetween$idx')), pos: pos };
			final prevKindIdent: Expr = { expr: EConst(CIdent('_prevTailKindBetween$idx')), pos: pos };
			final currPathIdent: Expr = { expr: EConst(CIdent('_currHeadPathBetween$idx')), pos: pos };
			final prevPathIdent: Expr = { expr: EConst(CIdent('_prevTailPathBetween$idx')), pos: pos };
			final differCall: Expr = { expr: ECall(adapterAccess, [prevPathIdent, currPathIdent, levelAccess]), pos: pos };
			final fallback: Expr = result;
			// Null-guard the adapter call — `WriteOptions.<adapterOptField>` is
			// declared `Null<(String,String,Int)->Bool>`, and the consuming
			// writer files (HxModuleWriter / HaxeModuleTriviaWriter, both
			// `@:nullSafety(Strict)`) reject a bare `opt.f(...)` call. The `&&`
			// short-circuit on `$adapterAccess != null` keeps the path inert
			// when no adapter is wired (cascade falls through to the fallback /
			// source-driven blank count).
			//
			// ω-D12-keep-source-blank-across-conditional — when
			// `opt.keepSourceBlankAcrossConditional` is opt-in `true` AND the
			// current item has a captured source blank (`_t.blankBefore`), the
			// emitted count is widened to `max(countAccess, 1)` so a real
			// source blank around `(prevImport, #if … importB; #end)` survives
			// the head/tail-transparency override path with `betweenImports=0`.
			// Default `false` preserves fork byte-identical behaviour — the
			// override emits `$countAccess` unchanged.
			final betweenChosen: Expr = macro (
				opt.keepSourceBlankAcrossConditional && _t.blankBefore && $countAccess < 1 ? 1 : $countAccess
			);
			result = macro (
				$currKindIdent == 1 && $prevKindIdent == 1 && $adapterAccess != null && $differCall ? $betweenChosen : $fallback
			);
		}
		return result;
	}

	/**
	 * Fold the cross-subset transition cascade ternaries onto
	 * `blanksCountExpr` — fires `opt.<count>` blanks on an A→B or B→A
	 * head/tail transition.
	 */
	private static function foldTransitionCascade(
		blanksCountExpr: Expr, transitionInfos: Array<TransitionAcrossInfo>, pos: Position
	): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...transitionInfos.length) {
			final idx: Int = transitionInfos.length - 1 - i;
			final info: TransitionAcrossInfo = transitionInfos[idx];
			final countAccess: Expr = { expr: EField(macro opt, info.countOptField), pos: pos };
			final currHKAIdent: Expr = { expr: EConst(CIdent('_currHeadKindAcrossA$idx')), pos: pos };
			final currHKBIdent: Expr = { expr: EConst(CIdent('_currHeadKindAcrossB$idx')), pos: pos };
			final prevTKAIdent: Expr = { expr: EConst(CIdent('_prevTailKindAcrossA$idx')), pos: pos };
			final prevTKBIdent: Expr = { expr: EConst(CIdent('_prevTailKindAcrossB$idx')), pos: pos };
			final fallback: Expr = result;
			result = macro (
				($currHKAIdent == 1 && $prevTKBIdent == 1) || ($currHKBIdent == 1 && $prevTKAIdent == 1) ? $countAccess : $fallback
			);
		}
		return result;
	}

	/**
	 * Fold the after-ctor cascade ternaries onto `blanksCountExpr` — fires
	 * `opt.<f>` blanks when the previous element matched the ctor (tail-adapter
	 * infos additionally require the tail leaf was NOT import/using).
	 */
	private static function foldAfterCascade(blanksCountExpr: Expr, afterInfos: Array<AfterCtorBlankInfo>, pos: Position): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...afterInfos.length) {
			final idx: Int = afterInfos.length - 1 - i;
			final info: AfterCtorBlankInfo = afterInfos[idx];
			final afterAccess: Expr = { expr: EField(macro opt, info.optField), pos: pos };
			final prevIdent: Expr = { expr: EConst(CIdent('_prevKindAfter$idx')), pos: pos };
			final fallback: Expr = result;
			// ω-after-conditional-block — tail-adapter infos gain a
			// `_prevTailNullAfter != 0` guard so the override fires only when
			// the previous element matched the ctor AND its tail leaf was NOT
			// an import / using (adapter returned null). Plain after-ctor infos
			// keep the bare `_prevKind == 1` gate, byte-identical.
			final gate: Expr = if (info.tailAdapterOptField == null)
				macro $prevIdent == 1;
			else {
				final prevTailNullIdent: Expr = { expr: EConst(CIdent('_prevTailNullAfter$idx')), pos: pos };
				macro $prevIdent == 1 && $prevTailNullIdent == 1;
			}
			result = macro ($gate ? $afterAccess : $fallback);
		}
		return result;
	}

	/**
	 * Build the head-of-Star blank-line emit block (ω-before-package). Each
	 * info contributes a `_arr[0].node.<classifier>` switch; the cascade picks
	 * the first matching `opt.<optField>` (source order = priority). Empty
	 * `headInfos` → `macro {}`.
	 */
	private static function buildHeadEmit(headInfos: Array<HeadCtorBlankInfo>, pos: Position): Expr {
		var headBlanksExpr: Expr = macro 0;
		for (i in 0...headInfos.length) {
			final idx: Int = headInfos.length - 1 - i;
			final info: HeadCtorBlankInfo = headInfos[idx];
			final classifierAccess: Expr = { expr: EField(macro _arr[0].node, info.classifierFieldName), pos: pos };
			final switchExpr: Expr = { expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos };
			final optAccess: Expr = { expr: EField(macro opt, info.optField), pos: pos };
			final fallback: Expr = headBlanksExpr;
			headBlanksExpr = macro ($switchExpr == 1 ? $optAccess : $fallback);
		}
		return headInfos.length == 0
			? (macro {})
			: (macro if (_arr.length > 0) {
				final _hb: Int = $headBlanksExpr;
				var _hbi: Int = 0;
				while (_hbi < _hb) {
					_docs.push(_dhl());
					_hbi++;
				}
			});
	}

	/**
	 * ω-uniform-statement-blanks / ω-uniform-element-blanks: pre-pass Expr
	 * declaring `_uniformCollapse` over the captured element array — shared by
	 * the block-Star (statement list) and sep-Star (array literal) emitters.
	 * `true` when the runtime knob is `Collapse` AND every interior gap between
	 * adjacent elements is blank AND no INTERIOR element carries a leading
	 * comment. Uniformity is measured over INTERIOR gaps only, so the edge blank
	 * right after the open delimiter never participates.
	 *
	 * A leading comment bails from an INTERIOR element only, because only there
	 * can a blank line detach it from the element above and make it a group
	 * header — and under uniformity that blank is always present. Element 0 has
	 * nothing above it but the open delimiter, so its comment annotates its own
	 * element and carries no grouping intent; the blank it may hold
	 * (`blankAfterLeadingComments`) is stripped by `triviaBalcEmitExpr`.
	 *
	 * Declared as a bare `EVars` so the var lands in the enclosing emit scope the
	 * per-element blank guard reads. `macro {}` (no declaration) for every
	 * non-opted Star, keeping the pre-slice emit byte-identical.
	 *
	 * The declare/read pair now spans three modules: this declaration is spliced
	 * by `TriviaSepLowering.triviaSepDispatchExpr` and
	 * `TriviaBlockLowering.triviaBlockElseBody`, and `_uniformCollapse` is read by
	 * the blank guards in both. Parity is held only by every one of those sites
	 * passing the same `uniformStmtBlanks` flag — gate one side and not the other
	 * and the generated writer either reads an undeclared local or declares a dead
	 * one, with nothing in any module's types to catch it.
	 */
	private static function triviaUniformCollapseInitExpr(uniformStmtBlanks: Bool): Expr {
		return !uniformStmtBlanks
			? macro {}
			: macro var _uniformCollapse: Bool = opt.uniformStatementBlanks == anyparse.format.UniformStatementBlanksPolicy.Collapse && {
				var _ok: Bool = true;
				var _uci: Int = 0;
				while (_uci < _arr.length) {
					if (_uci > 0 && (!_arr[_uci].blankBefore || _arr[_uci].leadingComments.length > 0)) {
						_ok = false;
						break;
					}
					_uci++;
				}
				_ok;
			};
	}

	/**
	 * ω-uniform-statement-blanks / ω-uniform-element-blanks: the
	 * `blankAfterLeadingComments` emit, shared by the block-Star and sep-Star
	 * force-multi loops. A collapsed element list must also drop the blank a
	 * leading comment holds before its own element — the pre-pass only lets a
	 * comment through at element 0, so this reaches exactly the "note glued to
	 * the open delimiter, then a stray blank" shape and never an interior group
	 * header. The pre-slice expression for every non-opted Star.
	 */
	private static function triviaBalcEmitExpr(uniformStmtBlanks: Bool): Expr {
		return uniformStmtBlanks ? macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0 && !_uniformCollapse)
			_inner.push(_dhl()) : macro if (_t.blankAfterLeadingComments && _t.leadingComments.length > 0) _inner.push(_dhl());
	}

	/**
	 * ω-blank-around-multiline-members — the three fragments that force a blank
	 * line into the gap between two adjacent members when either of them renders
	 * across more than one line.
	 *
	 * Why it cannot reuse the `multiline` predicate the module level already
	 * has: that one is resolved STRUCTURALLY at macro time from
	 * `@:fmt(multilineWhen…)` on the payload type, and a member has no such
	 * shape — `final a = ['x'];` and `final a = [… twenty …];` are the same
	 * node and differ only by width. So the question is asked of the built Doc
	 * instead, which forces the split into three splice points: the gap's
	 * position is known BEFORE the element is written, the answer only AFTER.
	 *
	 * `mark` records the insert index (ahead of the element's leading comments,
	 * so a doc-comment stays attached to its member); `seen` notes whether the
	 * source-driven rules already filled the gap, so the pass tops up to the
	 * knob rather than adding to it; `apply` measures both neighbours and
	 * splices the hardlines in at the recorded index.
	 *
	 * The width side compares against ONE indent level. That is exact for a
	 * top-level type and under-counts for a nested one, which can only cost a
	 * blank that a stricter measure would have added — never a spurious one.
	 */
	private static function blankAroundMultilineExprs(optField: Null<String>): {
		final markExpr: Expr;
		final seenExpr: Expr;
		final applyExpr: Expr;
	} {
		if (optField == null) return { markExpr: macro {}, seenExpr: macro {}, applyExpr: macro {} };
		final knob: Expr = { expr: EField(macro opt, optField), pos: Context.currentPos() };
		return {
			// ONE `EVars` node, not `macro { var …; var …; }` — a reified block
			// is an `EBlock`, i.e. its own scope, and the two sibling splices
			// below would not see the vars.
			markExpr: {
				expr: EVars([
					{ name: '_bamAt', type: macro :Int, expr: macro _inner.length },
					{ name: '_bamHad', type: macro :Bool, expr: macro false }
				]),
				pos: Context.currentPos()
			},
			seenExpr: macro _bamHad = _inner.length > _bamAt,
			applyExpr: macro {
				if (_si > 0 && !_bamHad && $knob > 0) {
					final _bamCols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					inline function _bamMulti(_d: anyparse.core.Doc): Bool {
						return anyparse.core.DocMeasure.hasForcedBreak(_d)
							|| _bamCols + anyparse.core.DocMeasure.flatTokenWidth(_d) > opt.lineWidth;
					}
					if (_bamMulti(_elem) || (_priorElemDoc != null && _bamMulti(_priorElemDoc))) {
						var _bami: Int = 0;
						while (_bami < $knob) {
							_inner.insert(_bamAt, _dhl());
							_bami++;
						}
					}
				}
			}
		};
	}

	/**
	 * ω-blank2: emit `_t.blankBefore2` extra hardlines — the blank lines
	 * beyond the first (already emitted for `blankBefore`) — via `pushExpr`.
	 * `blankBefore2` is `@:optional` on the trivia struct, so a construction
	 * site that never set it reads `null`, treated as zero. The Renderer caps
	 * the run at `opt.maxConsecutiveBlanks`, so an over-emit collapses back;
	 * this only widens a >1 source blank gap up to the configured maximum.
	 * References the runtime `_t`; splice right after the `blankBefore` push.
	 */
	private static function blankBefore2ExtrasExpr(pushExpr: Expr): Expr {
		return macro {
			final _bb2: Int = _t.blankBefore2 ?? 0;
			var _bbi: Int = 0;
			while (_bbi < _bb2) {
				$pushExpr;
				_bbi++;
			}
		};
	}

	/**
	 * ω-case-sibling-symmetry — build the per-SWITCH placement pre-pass for a
	 * case-list Star, or `macro -1` when the Star does not opt in.
	 *
	 * THE PROBLEM: each case body's `FitLine` placement is decided
	 * independently, so one body that lands below its label leaves its short
	 * siblings inline. The user-visible ask is per-SWITCH symmetry — if ANY
	 * body renders below its label, all of them do.
	 *
	 * THE RULE, in one sentence: a switch is TRIGGERED when some unit is
	 * below-label STRUCTURALLY, and otherwise when the widest unit's flat
	 * width does not fit or some unit is both unmeasurable and refused the
	 * glue. Every channel reaches the same output slot
	 * (`_caseSiblingFlatWidth`, consumed by `BodyFit.fitLineLayout` as an
	 * `IfIndentWidthExceeds` probe width), so nothing downstream has to know
	 * which one fired.
	 *
	 * STRUCTURAL CHANNEL. The generated
	 * `caseUnitStructuralBreak_<ElemRule>` predicate answers, per expanded
	 * unit, whether its body sits below its label at ANY budget: a body of two
	 * or more statements, a single statement `caseBodyRefusesFlat` refuses, or
	 * a `CondSpliceCase` label-splice region, whose shared body is mandatory
	 * and always renders below the labels it was split from. Two shapes
	 * deliberately do not trigger: an EMPTY body (nothing to place, and
	 * nothing a forced break could move) and a GLUED body (a lambda / block /
	 * object literal — its FIRST line shares the label line, so it is not a
	 * below-label placement). A glued body still MOVES under someone else's
	 * trigger; it just never leads.
	 *
	 * WHAT THE CHANNEL COSTS. The first `true` sets
	 * `BodyFit.SIBLING_FORCE_BREAK` and the measuring loop is SKIPPED — so a
	 * TRIGGERED switch now costs ONE write per element instead of the
	 * pre-pass's two. A switch that does NOT trigger pays the other side of
	 * that trade: the predicate walk visits every unit before the measuring
	 * loop begins, an O(N) pass the width-only pre-pass did not make. It reads
	 * AST fields and allocates nothing, so it is cheap against the writes it
	 * exists to avoid — but it is not free.
	 *
	 * WIDTH CHANNEL (the original slice, now the fallback). With no structural
	 * unit, the pre-pass writes each element once with the coordination
	 * suppressed and takes the maximum `WrapList.flatLength`. Elements that
	 * answer `-1` (glued bodies, and the shapes below) contribute nothing to
	 * that maximum. All negative ⇒ `SIBLING_NONE` and the emit stays
	 * uncoordinated, which is what keeps an all-glued switch (a comparator
	 * table of `case X: (a, b) -> { … }`) exactly as it renders without this
	 * slice.
	 *
	 * THE CONTROL-FLOW VERDICT rides that loop rather than the structural pass
	 * (omega-case-body-controlflow-glue). `BodyFit.fitLineLayout` refuses the
	 * glue for a body whose single statement is keyword-led control flow, so
	 * such a body renders below its label and must lead like a structural
	 * one — but only when it CANNOT render flat, and `case X: if (c) x();` and
	 * `case X: if (c) { x(); }` have the same statement kind. Kind alone
	 * therefore cannot decide it; the loop asks
	 * `caseUnitControlFlowBody_<ElemRule>` exactly on the units that measured
	 * `-1`, and the first `true` substitutes `SIBLING_FORCE_BREAK`. The arm is
	 * emitted ONLY for an element rule whose body Star carries
	 * `@:fmt(refuseGlueOnControlFlowRoot)` (resolved at macro time by
	 * `elemBodyStarHasFlag`), so the spread and the placement it accompanies
	 * can never be enabled apart.
	 *
	 * That verdict also reaches PAST the shape it was written for, and
	 * correctly so: it reads the statement KIND and never the trivia, so a
	 * COMMENT-refused body - one a leading comment on its element, or a
	 * trailing comment captured on its label, already pushed below its label -
	 * leads the spread too when its single statement is control-flow. It
	 * measures `-1` for the comment's sake and answers true for the
	 * statement's, and both point the same way.
	 *
	 * THE RESIDUALS — shapes that DO render below their label and still cannot
	 * LEAD. One is render-time: a glue that `BodyFit.glueLayout` turns into a
	 * break. That verdict is reached at the LIVE PEN COLUMN — the header is
	 * already emitted and only the renderer knows how wide it came out — so no
	 * emitter-side walk can predict it, and the switch it belongs to is not
	 * triggered by it. Pinned by
	 * `HxGlueWidthSliceTest.testGlueTurnedBreakIsNotASiblingSymmetryTrigger`.
	 * The other is a COMMENT-refused body whose single statement is NOT
	 * control-flow - the paragraph above closes the control-flow half of that
	 * class, not the class. Its tree is perfectly readable; the obstacle is
	 * that one predicate NAME emits one predicate BODY, shared by the plain /
	 * trivia / spans AST families, and the slots holding those comments are
	 * trivia-family-specific - see
	 * `HxCasePredLowering.caseUnitStructuralBreakField` for the full argument.
	 *
	 * A body Star with ORPHAN trailing comments used to be a third such shape;
	 * since omega-case-trail-comment-inline it flattens instead, so it is no
	 * longer below its label. It still contributes no WIDTH — its element Doc
	 * carries the comment run's hardline, so the pre-pass measures it `-1`,
	 * exactly as it measures a glued body — which means it never leads a
	 * spread by WIDTH and always follows one. That is deliberate: the rule the
	 * owner asked for is about whether the BODY can share its label line, and
	 * the comment sits outside the `BodyGroup` the fit path wraps the body in,
	 * so an over-wide such body still breaks on its own at render time.
	 *
	 * WHAT A DIRECTIVE REGION CONTRIBUTES (ω-if-leader-case-symmetry): not one
	 * element, but its inner case UNITS. A `#if`-guarded region projects as ONE
	 * Star element whose Doc carries directive hardlines, so measured whole it
	 * is always `-1` — it could FOLLOW a plain sibling's break and never LEAD
	 * one. The Star's `caseSiblingUnits_<ElemRule>` flattener expands the
	 * region into the inner case elements of EVERY branch (`#if` / `#elseif` /
	 * `#else` are alternatives — only one is ever compiled — so the maximum
	 * over all of them is the conservative trigger), and every channel then runs
	 * per inner unit: an over-wide guarded body leads by width, a
	 * multi-statement one leads structurally. The one-element short-circuit
	 * moved with it: what must exceed 1 is the UNIT count, so a switch whose
	 * only element is a region holding several cases still coordinates. A
	 * `CondSpliceCase` region is the exception that does NOT expand — its
	 * labels are byte-verbatim, so there is no inner case list — but it stays
	 * one unit that LEADS, because the structural channel answers true for it
	 * outright.
	 *
	 * The flattener and the structural verdict are MANDATORY for an opted-in
	 * Star: a format carrying the meta without generated AST predicates is a
	 * macro-time error here, not a silent fallback - carrying a second,
	 * never-exercised copy of this pre-pass is exactly the drift the trivia
	 * web's predicate-only `@:fmt` features refuse. The control-flow verdict is
	 * the one OPTIONAL member, because it belongs to a second, independently
	 * declared meta.
	 *
	 * `WrapList.flatLength` is the width measure specifically because it
	 * DESCENDS `BodyGroup` where `Renderer.fitsFlat` defers it — the T16b
	 * lesson: anything that reads render-time group state makes the verdict
	 * depend on the source's line shape, and `fmt` then needs a second pass to
	 * settle.
	 *
	 * WHY THE PRE-PASS DOES NOT NEST (ω-case-sym-linear): writing an element
	 * twice — once to measure, once to emit — costs 2x per switch LEVEL, so a
	 * switch nested d deep cost 2^d. The recursion is pure waste, because
	 * `flatLength` forwards `IfIndentWidthExceeds` to its FLAT branch: a nested
	 * switch's own coordination is INVISIBLE to the measurement that contains
	 * it. The `SIBLING_PROBING` marker therefore rides down the whole subtree —
	 * every Star already inside a pre-pass returns it unchanged instead of
	 * running its own — so each level is measured once and emitted once.
	 * Depth-15 nesting went from ~6s to flat.
	 *
	 * The knob gate keeps the double write off every config that cannot use it:
	 * the pre-pass runs only when the policy the case bodies will actually
	 * consult (`opt._inExprPosition` selects which of the two) is `FitLine`.
	 * Under `Same` / `Keep` / `Next` the elements are written exactly once, as
	 * before.
	 */
	private static function caseSiblingWidthProbeExpr(
		elemFn: String, knobs: Null<Array<String>>, ?unitsFn: Expr, ?structuralFn: Expr, ?controlFlowFn: Expr
	): Expr {
		if (knobs == null) return macro -1;
		final fitPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BodyPolicy', 'FitLine']);
		final stmtAccess: Expr = optFieldAccess(knobs[0]);
		final exprAccess: Expr = optFieldAccess(knobs[1]);
		final policyGate: Expr = macro (opt._inExprPosition ? $exprAccess : $stmtAccess) == $fitPat;
		// `caseSiblingSymmetry` is a predicate-only feature with no legacy
		// runtime channel, so it follows the trivia web's rule for such metas:
		// fail LOUDLY rather than carry a second, untestable copy of the
		// pre-pass for a grammar that opts in without generating predicates.
		// Both predicates are mandatory: without the flattener a `#if` region
		// could not lead, and without the structural verdict the rule would
		// silently degrade to the width-only one it replaced. The message names
		// the one that is missing, so it points at the gap it found.
		if (unitsFn == null || structuralFn == null) {
			final missing: String = unitsFn == null ? 'caseSiblingUnits_* flattener' : 'caseUnitStructuralBreak_* verdict';
			Context.fatalError('WriterLowering: caseSiblingSymmetry needs the generated $missing', Context.currentPos());
			throw 'unreachable';
		}
		final expandExpr: Expr = caseSiblingUnitExpandExpr(unitsFn);
		final structuralCall: Expr = { expr: ECall(structuralFn, [macro _csUnits[_csS]]), pos: Context.currentPos() };
		final unitProbeCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro _csUnits[_csK], macro _csOpt]),
			pos: Context.currentPos()
		};
		// omega-case-body-controlflow-glue: emitted ONLY when the element rule's
		// body Star carries `@:fmt(refuseGlueOnControlFlowRoot)` - the same meta
		// that turns the glue into a break. Null (flag absent) drops the arm, so
		// the pre-pass is byte-identical to the width-only one.
		final controlFlowForce: Expr = controlFlowFn == null ? macro {} : {
			final call: Expr = { expr: ECall(controlFlowFn, [macro _csUnits[_csK]]), pos: Context.currentPos() };
			macro if (_csFlat == -1 && $call) {
				_csMax = anyparse.format.BodyFit.SIBLING_FORCE_BREAK;
				break;
			};
		};
		return macro {
			var _csMax: Int = anyparse.format.BodyFit.SIBLING_PROBING;
			if (opt._caseSiblingFlatWidth != anyparse.format.BodyFit.SIBLING_PROBING) {
				_csMax = anyparse.format.BodyFit.SIBLING_NONE;
				if (_arr.length > 0 && $policyGate) {
					final _csUnits = $expandExpr;
					// A one-UNIT list cannot be asymmetric. The pre-slice gate
					// read `_arr.length > 1`; the count is now over EXPANDED
					// units, so a switch whose only element is a `#if` region
					// holding several cases still coordinates.
					if (_csUnits.length > 1) {
						// Structural pass FIRST, and it writes nothing: one unit
						// already below its own label settles the whole switch,
						// so the measuring loop (two writes per element) is
						// skipped entirely for a triggered switch.
						var _csForce: Bool = false;
						var _csS: Int = 0;
						while (_csS < _csUnits.length) {
							if ($structuralCall) {
								_csForce = true;
								break;
							}
							_csS++;
						}
						if (_csForce)
							_csMax = anyparse.format.BodyFit.SIBLING_FORCE_BREAK;
						else {
							final _csOpt = _setCaseSiblingWidth(opt, anyparse.format.BodyFit.SIBLING_PROBING);
							var _csK: Int = 0;
							while (_csK < _csUnits.length) {
								final _csFlat: Int = anyparse.format.wrap.WrapList.flatLength($unitProbeCall);
								// omega-case-body-controlflow-glue: a unit that
								// cannot render flat AND holds a single
								// control-flow statement is refused the glue by
								// `BodyFit.fitLineLayout`, so it renders below its
								// own label — the same verdict the structural pass
								// reaches, but only measurable here.
								$controlFlowForce;
								if (_csFlat > _csMax) _csMax = _csFlat;
								_csK++;
							}
						}
					}
				}
			}
			_csMax;
		};
	}

	/**
	 * ω-if-leader-case-symmetry: the case-UNIT expansion spliced into the
	 * widest-sibling pre-pass. Walks the Star's elements once and yields the
	 * flat unit list — an element the flattener does not recognise (`null`)
	 * stands for itself, a `#if`-guarded region contributes the inner case
	 * elements of every one of its branches.
	 *
	 * `unitsFn` is the generated `caseSiblingUnits_<ElemRule>` predicate. It
	 * answers `null` on the hot path (every plain case of every switch), so
	 * the walk allocates nothing per element and the expansion stays a
	 * single linear AST pass — it re-enters neither the writer nor the
	 * pre-pass, so ω-case-sym-linear is unaffected.
	 */
	private static function caseSiblingUnitExpandExpr(unitsFn: Expr): Expr {
		final unitsCall: Expr = { expr: ECall(unitsFn, [macro _csNode]), pos: Context.currentPos() };
		return macro {
			final _csU = [];
			var _csI: Int = 0;
			while (_csI < _arr.length) {
				final _csNode = _arr[_csI].node;
				final _csNested = $unitsCall;
				if (_csNested == null)
					_csU.push(_csNode);
				else {
					var _csJ: Int = 0;
					while (_csJ < _csNested.length) {
						_csU.push(_csNested[_csJ]);
						_csJ++;
					}
				}
				_csI++;
			}
			_csU;
		};
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
	 * The `arrowBodyLineWrap` emit for a lambda body: wrap `bodyCall` in the
	 * `_dwb(_dilr(...))` arrow-body marker, so at render time the body either stays
	 * glued to the arrow (when `BodyFit.arrowGlueThreshold` holds), or — under
	 * `opt.fitLineBodyGlue` on a hardline-free body — is rescued onto the
	 * continuation by `BodyFit.continuationRescuesArrowBody`, or else breaks after
	 * the arrow and nests one level.
	 *
	 * Shared verbatim by the Pratt infix `->` branch (`lowerInfixTightAssign`) and the
	 * bare-Ref field path (`emitBareRefNonBodyPolicy`).
	 */
	private static function arrowBodyLineWrapExpr(bodyCall: Expr): Expr {
		return macro {
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _doc: anyparse.core.Doc = $bodyCall;
			final _flat: Int = anyparse.format.wrap.WrapList.flatLength(_doc);
			_dwb(_dilr(
				anyparse.format.BodyFit.arrowGlueThreshold(_doc, opt.lineWidth),
				opt.fitLineBodyGlue && _flat >= 0
					? anyparse.format.BodyFit.continuationRescuesArrowBody(_cols, _doc, _flat, opt.lineWidth)
					: _dn(_cols, _dc([_dhl(), _doc])),
				_doc
			));
		};
	}

	/**
	 * The first string argument of a call-form `@:fmt(<flag>(...))` on `starNode`, or
	 * null when the flag is absent or bare (no argument at all).
	 */
	private static function fmtFirstStringArg(starNode: ShapeNode, flag: String): Null<String> {
		final args: Null<Array<String>> = starNode.fmtReadStringArgs(flag);
		return args != null && args.length >= 1 ? args[0] : null;
	}

	/**
	 * The single string argument of a call-form `@:fmt(<flag>('<optField>'))` on
	 * `starNode`, or null when the flag is absent. A present flag carrying any
	 * other arity is a grammar-author error and aborts the build.
	 */
	private static function fmtSingleStringArg(starNode: ShapeNode, flag: String): Null<String> {
		final args: Null<Array<String>> = starNode.fmtReadStringArgs(flag);
		if (args != null && args.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt($flag) expects exactly 1 string arg (optField), got ${args.length}', Context.currentPos()
			);
		return args != null ? args[0] : null;
	}

	/**
	 * The `opt` expression threaded into the RIGHT operand's write call of a Pratt
	 * infix branch, or null when the branch flags no fanout.
	 *
	 * ω-arrow-body-objlit-pad: `@:fmt(propagateArrowLambdaBody)` on the infix `->`
	 * branch (HxExpr.ThinArrow) flags the RIGHT operand write. Composed outside
	 * `_setExprPosition` so its descent clear does not wipe the just-set flag. Left
	 * operand passes `opt` unchanged, so the flag survives leftmost descents —
	 * replicating the fork's token-adjacency (`{` directly after `->`) for free.
	 */
	private static function rightOperandOptExpr(branch: ShapeNode): Null<Expr> {
		final rightOptBase: Null<Expr> = branch.fmtHasFlag('propagateExprPosition') ? macro _setExprPosition(opt) : null;
		return branch.fmtHasFlag('propagateArrowLambdaBody') ? macro _setArrowLambdaBody(${rightOptBase ?? macro opt}, opt) : rightOptBase;
	}

	/**
	 * omega-try-brace-symmetry: the leading separator a `catch` takes after a NON-block body. The
	 * unconditional `_dhl()` is haxe-formatter's statement-context convention and stays the default;
	 * naming a `BodyPolicy` knob adds the FitLine escape, so `} catch` cuddles while the line fits and
	 * breaks when it does not — the separator answering the same width question the body's own policy
	 * answers, so the two agree about whether the construct rendered flat.
	 */
	private static function bareSepBreak(policyField: Null<String>, sepExpr: Expr, softSeam: Bool): Expr {
		if (policyField == null) return macro _dhl();
		final policy: Expr = optFieldAccess(policyField);
		// Under `@:fmt(constructFitSep)` the seam is a SOFT line owned by the enclosing construct
		// group, so it breaks with the body's own seam rather than answering for itself. Asking here
		// is what put a flat ` catch` after a body that had already broken, which then squeezed the
		// body's call into a width it had to wrap inside.
		final flatSeam: Expr = softSeam ? macro _dl() : macro _dfle(opt.lineWidth, _dhl(), $sepExpr);
		return macro $policy == anyparse.format.BodyPolicy.FitLine ? $flatSeam : _dhl();
	}

}

/** Output of WriterLowering for one rule. */
typedef WriterRule = {
	fnName: String,
	valueCT: ComplexType,
	body: Expr,
	hasCtxPrec: Bool,
	isBinary: Bool
};

/**
 * Carries the runtime-access expression and enum type path of the
 * immediately preceding bare-Ref struct field whose body was wrapped
 * via `bodyPolicyWrap`. Consumed by `sameLineSeparator` (ψ₉) to emit
 * a shape-aware leading separator on the following `@:fmt(sameLine(...))`
 * keyword: block ctors respect the flag, non-block ctors force a
 * hardline.
 */
typedef PrevBodyInfo = {
	access: Expr,
	typePath: String
};
/**
 * One struct field's per-iteration metadata, produced by `readFieldMeta` and
 * consumed by `lowerStruct`'s field-emit branches.
 */
typedef FieldMeta = {
	fieldName: String,
	kwLead: Null<String>,
	leadText: Null<String>,
	trailText: Null<String>,
	trailOptText: Null<String>,
	isStar: Bool,
	isOptional: Bool,
	hasElseIf: Bool,
	condWrapArgs: Null<Array<String>>,
	isSpanStart: Bool,
	hasCondWrapEnd: Bool,
	hasCondWrap: Bool,
	fieldAccess: Expr,
	hasStructFieldTrailOptSlot: Bool,
	structTrailOptAccess: Null<Expr>
};
/**
 * Per-classifier transparent-ctor accumulator used while reading
 * `@:fmt(blankLinesBetweenSameCtor{Tail,Head}Transparent)` args in
 * `readCascadeInfosFromStar`.
 */
typedef TransparentEntry = {
	final ctors: Array<String>;
	var tailAdapter: Null<String>;
	var headAdapter: Null<String>;
};
/**
 * Shared inputs for `sameLineSeparatorShapeAware` — the shape-aware
 * tail extracted from `sameLineSeparator`. Bundles the >5 scalars the
 * tail needs into one context struct.
 */
typedef SameLineShapeAwareCtx = {
	final child: ShapeNode;
	final prevBody: PrevBodyInfo;
	final prevPadTrailing: Null<Expr>;
	final flagBased: Expr;
	final shapeAwareSwitch: Expr;
	final hasKeepSlot: Bool;
	final fieldName: Null<String>;
};

/**
 * ω-bodyPolicyWrap-struct-arg — option struct for `WriterLowering.bodyPolicyWrap`.
 *
 * Refactored from a 17-positional-arg signature (5 mandatory + 12 optional) into
 * a single struct-arg form so call sites are readable and forwarding-only fields
 * don't need long `null, null, null` runs. The 6 fields without `?` are required
 * (every call site passes them explicitly today); the rest are forwarding flags
 * for one of the runtime overrides documented in `bodyPolicyWrap`'s body.
 *
 * Field semantics — see `bodyPolicyWrap` body comments for full detail:
 *   - `flagName`            — name of the `BodyPolicy` field on `opt` driving the layout switch.
 *   - `exprFlagName`        — optional 2nd `BodyPolicy` field name (expr-position dispatch when `opt._inExprPosition`).
 *   - `writeCall`           — pre-built `Doc` expression that emits the body's bytes.
 *   - `bodyValueExpr`       — runtime access to the body value (used for `Type.enumConstructor` checks).
 *   - `bodyTypePath`        — fully qualified Haxe type path of the body's enum (for ctor-pattern lookup).
 *   - `hasElseIf`           — `true` for `HxIfExpr.thenBranch`-style sites that elide `{}` when followed by `if`.
 *   - `elseFieldName`       — name of the sibling `else`-side field on `value`; `null` when no peer.
 *   - `afterKwExpr`         — runtime access to captured after-kw trivia (`kwGapDoc` source).
 *   - `kwLeadingExpr`       — runtime access to captured kw-leading trivia.
 *   - `bodyOnSameLineExpr`  — runtime `Bool` driving the `Keep` branch's flat-vs-break choice.
 *   - `kwPolicyFlagName`    — name of a sibling `WhitespacePolicy` knob driving the `Same` separator (kw-policy mode).
 *   - `afterTrailExpr`      — runtime access to captured after-kw trailing comment (forces `Next` shape).
 *   - `beforeLeadingExpr`   — runtime access to the `Array<String>` of own-line comments captured before a bare-Ref body (forces `Next` shape; composes with `afterTrailExpr`).
 *   - `indentObjArgs`       — `(ctorName, optField, lcField)` triple for the `indentObjGuardedNext` rule.
 *   - `policyOverrides`     — list of `(ctorName, flagName)` pairs cascading the runtime body-policy override.
 *   - `bodyAllmanIndentArgs`— `(ctorName, optField)` pair for the multi-line Allman+indent override.
 *   - `widthAware`          — when `true`, the `Same` branch routes through `IfWidthExceeds` for line-fit-aware break.
 *   - `ifExprIndentArgs`    — `(ctorName, optField)` pair for the IfExpr-as-value RHS-style indent in flat path.
 *   - `fallbackFlagName`    — name of a fallback `BodyPolicy` flag activated when the sibling `else` is absent.
 *   - `inlineBlockBodyArgs` — `(flagName)` 1-tuple for the inline-collapse override on `BlockExpr` bodies (ω-expression-if-with-blocks).
 *   - `singleLineFlagName`  — name of the `BodyPolicy` knob used when the value is NOT a control-flow / block ctor (ω-return-body-single-line).
 *   - `singleLineMultiCtors`— value ctor names treated as multi-line (keep the base policy); all other ctors read `singleLineFlagName`.
 */
typedef WrapBodyOpts = {
	flagName: String,
	?exprFlagName: Null<String>,
	writeCall: Expr,
	bodyValueExpr: Expr,
	bodyTypePath: String,
	hasElseIf: Bool,
	elseFieldName: Null<String>,
	?afterKwExpr: Null<Expr>,
	?kwLeadingExpr: Null<Expr>,
	?bodyOnSameLineExpr: Null<Expr>,
	?kwPolicyFlagName: Null<String>,
	?afterTrailExpr: Null<Expr>,
	?beforeLeadingExpr: Null<Expr>,
	?indentObjArgs: Array<String>,
	?policyOverrides: Array<Array<String>>,
	?bodyAllmanIndentArgs: Array<String>,
	?widthAware: Bool,
	?ifExprIndentArgs: Array<String>,
	?fallbackFlagName: String,
	?inlineBlockBodyArgs: Array<String>,
	?singleLineFlagName: Null<String>,
	?singleLineMultiCtors: Null<Array<String>>,
	// ω-condwrap-fitline-construct-group — true when lowerStruct wraps the
	// preceding condWrap cond + this body into ONE construct-level BodyGroup.
	// The FitLine layout then becomes the classic soft line (`Line(' ')` +
	// body under Nest): flat when the WHOLE construct fits the line, broken
	// when it does not — which also fires when the condition committed to
	// its wrapped shape (its hardlines fail the group's fitsFlat), matching
	// the fork's "body on the same line iff the whole statement fits" rule.
	// Replaces the body-only `_dinfle` probe whose post-`)` column reset
	// glued `) return x;` after a wrapped condition. Null/false → byte-inert.
	?condFitGroup: Bool,
	// omega-try-brace-symmetry: `@:fmt(constructFitBody)` on a body field inside a
	// `constructFitGroup`. Its `FitLine` layout becomes ONE soft line owned by that group, so the
	// body sits on the header line while the whole construct fits and drops to its own indented line
	// the moment the group breaks — the shape an `if` with an `else` produces, which is what a
	// try/catch has to match: a `catch` always follows, exactly as an `else` does. Without it the
	// FitLine body answers for its own line and GLUES, leaving `try body` on the head while the
	// `catch` seam below it has already broken.
	?constructFitBody: Bool,
	// ω-keep-chain (increment: opadd_chain_keep) — runtime `Bool` access to the
	// ctor's captured `return`→value source newline (the `captureKwNewline` synth
	// slot, ReturnStmt only). When true AND the body is already-multiline
	// (`flatLength == -1`, e.g. a `WrapMode.Keep` chain nested in `1 * (…)`), the
	// FitLine return path breaks `return\n\t<body>` instead of gluing — preserving
	// the source's head newline at the VALUE level (the inner chain has had its
	// own `_headBreak` suppressed by the enclosing ParenExpr's `_setKeepChainInParen`).
	// Null in plain mode / non-bearing ctors → byte-inert (legacy glue).
	?kwNewlineExpr: Null<Expr>,
	// ω-fnbody-meta-block-glue — when true, the body-placement override
	// detects an `ExprBody` whose inner expression is a metadata-wrapped
	// BLOCK (`@:meta { … }`, runtime shape `ExprBody(MetaExpr(_, BlockExpr))`,
	// nested metas unwrapped) and routes it to the glued `sameLayoutExpr`
	// (` ` + body) instead of the policy switch. The metadata + block then
	// stay cuddled to the signature line (`):Ret @:privateAccess {`) and the
	// block's own internal Nest supplies the single body-indent step — the
	// `functionBody`/`untypedBody` policy never breaks the metadata onto its
	// own line and never adds the spurious extra Nest. Non-block metadata
	// bodies (`@:meta return x`) and every non-meta body keep the policy
	// dispatch unchanged. The ctor names (`ExprBody`/`MetaExpr`/`BlockExpr`)
	// are passed declaratively from the grammar flag to keep the macro
	// format-neutral. Null/false → byte-inert.
	?metaBlockGlueArgs: Null<Array<String>>,
	// ω-single-stmt-braces trailing-comment hoist: runtime Null<String> comment to
	// fold after a de-braced body's `;` (hoistTrailingComment result). Null off the
	// dropSingleStmtBraces path so buildBodyWriteCall skips the fold (byte-inert).
	?ssbTrailCommentExpr: Null<Expr>,
	// omega-arrow-value-if-reflow: true for a body field carrying
	// `@:fmt(arrowValueIfReflowSite)` (HxIfExpr.thenBranch / elseBranch).
	// The resolved BodyPolicy is then overridden to `Same` whenever the
	// struct-level gate local `_aifReflow` is set at runtime, so every
	// branch value glues to its own condition and the enclosing
	// `Group` owns the one flat-vs-broken decision for the whole chain.
	// False everywhere else -> byte-inert.
	?arrowValueIfSite: Bool,
	// omega-elseif-comment-reflow: true for the body field carrying
	// `@:fmt(elseIfCommentReflow)` (HxIfStmt.elseBody). On the `elseIf`-ctor
	// `Same` arm ONLY, and only when `opt.elseIfCommentReflow` is set and the
	// kw-trivia slots hold exactly one `//` comment, the `kwGapDoc` separator
	// is swapped for a plain space and that comment is spliced onto the nested
	// `if`'s head line by `ElseIfCommentReflow.insertHeadTrail`. Every other
	// arm, and a splice that finds no anchor, keep the untouched layout.
	// False everywhere else -> byte-inert.
	?elseIfCommentReflow: Bool,
	// ω-loop-body-if-else-next: the three declarative names from
	// `@:fmt(loopBodyIfElseNext('<optField>', '<ifCtor>', '<elseField>'))` on a
	// LOOP body field (`HxForStmt.body` / `HxWhileStmt.body`). When
	// `opt.<optField>` is set AND the body value is an `<ifCtor>` whose head
	// carries a non-null `<elseField>`, the `FitLine` layout degrades to the
	// `Next` one — the loop header keeps its own line and the whole `if`/`else`
	// moves one indent step in, so the `else` lines up with its `if` instead of
	// with the loop. An `if` WITHOUT an `else` keeps gluing: `for (x in xs) if
	// (c) f(x);` is a deliberate idiom, which is why this cannot be a body
	// policy (`forBody: next` moves that one too). Sibling of the
	// `fitLineIfWithElse` escape one storey down, which asks about the placed
	// node's own `else` field rather than about the CHILD's shape. Null → byte-inert.
	?loopBodyIfElseArgs: Null<Array<String>>,
	// omega-else-switch: the declarative names from
	// `@:fmt(elseSwitch('<optField>', '<ctor>'…))` on an else-body field - the
	// `KeywordPlacement` knob field first, then one or more body ctors that
	// spell a keyword-headed `switch` else-body (`HxIfStmt.elseBody` names both
	// the parenthesised and the bare `switch` statement ctor). The core macro
	// therefore spells no grammar ctor of its own here, unlike the older
	// `elseIf` flag beside it, which still hardcodes `IfStmt`/`IfExpr`.
	// Null → byte-inert.
	?elseSwitchArgs: Null<Array<String>>
};

/**
 * Runtime-built Exprs shared across the `bodyPolicyWrap` layout-primitive
 * helpers (`buildBodySameLayout` etc.): the resolved writeCall, the
 * `Same`-mode kw→body separator, the kw-policy inline separator, and
 * whether kw-trivia slots were forwarded.
 */
typedef BodyWrapShared = {
	final writeCall: Expr;
	final sameSepNb: Expr;
	final kwPolicyInlineSep: Null<Expr>;
	final hasKwSlots: Bool;
};

/**
 * The five resolved body-layout Exprs (one per `BodyPolicy` axis plus the
 * block-ctor variant) threaded into `bodyPolicyWrap`'s policy/outer
 * dispatch and Keep arm.
 */
typedef BodyLayouts = {
	final sameLayoutExpr: Expr;
	final nextLayoutExpr: Expr;
	final blockLayoutExpr: Expr;
	final fitExpr: Expr;

	/**
	 * omega-elseif-comment-reflow: the `Same` layout the `elseIf`-ctor arm
	 * uses. Identical to `sameLayoutExpr` unless the field carries
	 * `@:fmt(elseIfCommentReflow)`, in which case it is that layout behind a
	 * runtime gate that first tries the glued form with the interposed
	 * comment spliced onto the nested `if`'s head line.
	 */
	final elseIfSameLayoutExpr: Expr;
};

/**
 * ω-interblank — resolved data for `@:fmt(interMemberBlankLines(...))`.
 * Produced by `WriterLowering.buildInterMemberClassifyInfo` and spliced
 * into the `triviaBlockStarExpr` per-element loop to classify each
 * element as a var (kind `1`), a function (kind `2`), or other
 * (kind `0`). `classifyCases` is a ready-to-use `ESwitch` case list —
 * one entry per enum variant, exhaustive, no wildcard.
 *
 * `betweenVarsField` / `betweenFunctionsField` / `afterVarsField` name
 * the `HxModuleWriteOptions` Int fields read at runtime to gate each
 * blank-line slot (ω-iface-interblank). The 3-arg meta form defaults
 * them to the shared `betweenVars` / `betweenFunctions` / `afterVars`
 * (used by class + abstract); the 6-arg form lets a grammar route to
 * its own dedicated fields (e.g. interface uses
 * `interfaceBetweenVars` / `interfaceBetweenFunctions` /
 * `interfaceAfterVars` so its defaults stay independent of the
 * class/abstract knobs).
 */
typedef InterMemberClassifyInfo = {
	classifierFieldName: String,
	classifyCases: Array<Case>,
	betweenVarsField: String,
	betweenFunctionsField: String,
	afterVarsField: String
};

/**
 * Parameters for `buildInterMemberClassifyCases` — the enum (Alt) rule
 * whose ctors map to classify kinds plus the var/fn ctor sets and the
 * optional `condCtor`/`bodyField` look-through config. Bundled to keep
 * the case-builder helper under the >5-scalar threshold.
 */
typedef InterMemberCasesCtx = {
	final enumRule: ShapeNode;
	final varCtors: Array<String>;
	final fnCtors: Array<String>;
	final condCtor: Null<String>;
	final bodyField: Null<String>;
	final fieldName: String;
};

/**
 * ω-class-static-var-cascade — resolved data for
 * `@:fmt(staticVarSubdivision)` /
 * `@:fmt(staticVarSubdivision('<modifierField>', '<staticCtor>',
 * '<afterStaticVarsField>'))`. Produced by
 * `WriterLowering.buildStaticVarSubdivisionInfo`. When present alongside
 * `interMemberInfo`, `triviaBlockStarExpr` augments the per-iteration
 * `_currKind` switch with a sibling-Star scan: when the base switch
 * yields kind `1` (instance var) AND the `<modifierField>` Star contains
 * a `<staticCtor>`-ctor element, `_currKind` is promoted to `3` (static
 * var). The cascade then routes (1,3)/(3,1) transitions to the
 * `<afterStaticVarsField>` opt knob, leaving (1,1)/(3,3)/(2,2)/var↔fn
 * arms on the existing `betweenVars` / `betweenFunctions` / `afterVars`.
 *
 * ω-abstract-static-fn-cascade — the same sibling-Star scan also promotes
 * base kind `2` (function) to kind `4` (static function) on encountering
 * the `<staticCtor>` modifier. A (4,4) pair routes to the
 * `<betweenStaticFunctionsField>` opt knob; kinds `2` and `4` are both
 * treated as the "function" family for the var↔fn `afterVars` arm, and a
 * (2,4)/(4,2) static-difference falls back to `betweenFunctions` (fork's
 * `afterStaticFunctions` default equals `betweenFunctions` — `1` — so no
 * separate knob is modelled until a fixture distinguishes them).
 *
 * Class and abstract members opt in; interface members do NOT — fork's
 * `InterfaceFieldsEmptyLinesConfig` lacks `afterStaticVars` and treats
 * static-var transitions as plain `betweenVars`. Skipping the meta on
 * `HxInterfaceDecl.members` keeps that behaviour without a separate
 * interface-side knob.
 */
typedef StaticVarSubdivisionInfo = {
	modifierFieldName: String,
	staticCtorName: String,
	afterStaticVarsField: String,
	betweenStaticFunctionsField: String
};

/**
 * ω-cond-leading-doc-lookthrough — resolved data for
 * `@:fmt(beforeDocCondLookThrough('<classifierField>', '<condCtor>',
 * '<bodyField>'))`. Produced by
 * `WriterLowering.buildCondLeadingDocLookThroughInfo`. When present on a
 * trivia-bearing member Star that also opted into
 * `@:fmt(beforeDocCommentEmptyLines)`, `triviaBlockStarExpr`'s
 * `_currHasDocComment` scan looks THROUGH a preprocessor `#if … #end`
 * member (the `<condCtor>` ctor on the `<classifierField>` classifier enum)
 * to the FIRST element of its `<bodyField>` Star: when that inner member's
 * leading trivia starts with `/**`, the Conditional is treated as
 * doc-comment-led for the `beforeDocCommentEmptyLines` policy.
 *
 * Mirrors fork's `MarkEmptyLines`, which makes a conditional wrapper
 * transparent for doc-comment adjacency: `beforeDocCommentEmptyLines = None`
 * then strips the source blank between a field and a `#if` whose body opens
 * with a documented member (issue_188, the class-member analogue of the
 * issue_298 `#end → type-decl` transparency). The Conditional's OWN leading
 * never carries the inner doc-comment (the `/**` belongs to the inner
 * member, not the `#if` directive), so the plain `_t.leadingComments` scan
 * misses it without this look-through.
 *
 * `condCasePattern` is a ready-to-use `case <condCtor>(_inner):` pattern
 * binding the single ctor arg; `bodyFieldName` is the trivia Star field on
 * that arg whose `[0].leadingComments` is scanned.
 */
typedef CondLeadingDocLookThroughInfo = {
	classifierFieldName: String,
	condCasePattern: Expr,
	bodyFieldName: String
};

/**
 * ω-after-package — resolved data for
 * `@:fmt(blankLinesAfterCtor(classifierField, CtorName1, [CtorName2, …], optField))`.
 * Produced by `WriterLowering.buildAfterCtorBlankInfo` and spliced
 * into `triviaEofStarExpr`'s per-element loop to override the source-
 * captured blank-line count when the previous element's classifier
 * matches one of the named ctors.
 *
 * `classifyCases` is a ready-to-use exhaustive `ESwitch` case list:
 * each enum variant present in the classifier target enum maps to
 * either kind `1` (matches one of the configured ctor names) or
 * kind `0` (no match). The runtime gate then reads
 * `_prevKindAfter == 1 ? opt.<optField> : (_t.blankBefore ? 1 : 0)` —
 * a hard override on match (the source-captured count is discarded),
 * source-driven otherwise. `0` strips an existing blank line, higher
 * counts insert that many regardless of source.
 *
 * `optField` is the `HxModuleWriteOptions` Int field name read at
 * runtime (e.g. `afterPackage`). The Star may carry multiple
 * `@:fmt(blankLinesAfterCtor(...))` entries (ω-after-typedecl) — each
 * produces its own `AfterCtorBlankInfo` with a disjoint ctor set and
 * its own `optField`. The runtime cascade walks them in source order:
 * the first matching kind-tracker wins, falling through to `beforeCtor`
 * infos and finally the source-driven `blankBefore` flag. Authors
 * order entries by priority (e.g. `afterPackage` before `afterTypeDecl`).
 */
typedef AfterCtorBlankInfo = {
	classifierFieldName: String,
	classifyCases: Array<Case>,
	optField: String,
	// ω-after-conditional-block — when non-null, the after-ctor override is
	// ADDITIONALLY gated on the previous element's tail-leaf classify
	// returning null. The string names a generated typed
	// `<payload> -> Null<{ctorName, path}>` leaf walker on the trivia
	// predicate class (e.g. `AstPredsT.tailLeafKeepsBlankAfterConditional`
	// — the meta arg is the function name), run on the matched ctor's
	// first positional arg (`_v0`); a null result means the wrapper's
	// tail leaf is NOT one of the recognised ctors (import / using), so
	// the override fires. Non-null (tail IS an import / using) suppresses
	// the override and the cascade falls through to the source-driven
	// blank count. The matched classify case binds `_v0` so the walker
	// has the payload. Null for every plain `blankLinesAfterCtor{,If}` —
	// those keep the original bare `_prevKind == 1` gate, byte-identical.
	// (The field name keeps its historical `OptField` suffix from the
	// retired `WriteOptions` adapter era for diff locality; unlike
	// `BetweenCtorBlankInfo.adapterOptField`, it no longer names an opt
	// field.)
	?tailAdapterOptField: Null<String>
};

/**
 * ω-before-package — resolved data for
 * `@:fmt(blankLinesAtHeadIfCtor(classifierField, CtorName1, [CtorName2, …],
 * optField))`. Produced by `WriterLowering.buildHeadCtorBlankInfo` and
 * spliced into the start of `triviaEofStarExpr` / `triviaTryparseStarExpr`
 * elseBody (after `_docs` init, before any element emit). Fires
 * `opt.<optField>` blank lines at the START of the Star body when the
 * FIRST element matches one of the named ctors. Source-driven blank
 * suppression / extension does not apply — this is a pure override
 * tied to the structural shape of the head element.
 *
 * Mirrors `AfterCtorBlankInfo` shape exactly (single-axis classify-
 * switch + opt field), with two semantic differences: (a) classifier is
 * read off `_arr[0].node.<field>`, not the per-element `_t.node`;
 * (b) consumed once at the head, not per-iteration. Multiple infos on
 * the same Star are walked in source order, first matching wins —
 * remaining infos are inert. Reusable for any future "blank lines at
 * head before ctor X" slice (e.g. file-leading-comment normalisation
 * before a typedef header) by pointing at a different opt field.
 *
 * No `Before` mirror is needed at the cascade level: head and "before
 * first" are the same boundary at a Star's head, and the source-driven
 * binary blank-line slot does not apply at index 0 either way.
 */
typedef HeadCtorBlankInfo = {
	classifierFieldName: String,
	classifyCases: Array<Case>,
	optField: String
};

/**
 * ω-between-single-line-types — resolved data for
 * `@:fmt(blankLinesBetweenSameCtorIfNot(classifierField, predicateName,
 * CtorName1, [CtorName2, …], optField))`. Produced by
 * `WriterLowering.buildBetweenSameCtorBlankInfoIfNot` and spliced into
 * `triviaEofStarExpr` / `triviaTryparseStarExpr`'s per-element loop
 * alongside the after/before/between/transition families.
 *
 * Shape mirrors `AfterCtorBlankInfo` / `BeforeCtorBlankInfo` exactly
 * (single-axis classify-switch returning `1` for any matching ctor
 * whose `predicateName` evaluates to FALSE on its payload, `0`
 * otherwise) plus an opt-field name. The two diverge from after / before
 * at the cascade gate: this family fires when BOTH prev and curr have
 * kind=1 — i.e. consecutive pair where both ends fall in the matching
 * ctor set AND neither side matches the predicate.
 *
 * Used to drive haxe-formatter's `emptyLines.betweenSingleLineTypes`
 * semantic (1 blank between any pair of single-line typedef / class /
 * interface / abstract / enum decls). The predicate is grammar-derived
 * via `buildMultilinePredicate` (same one driving `afterMultilineDecl` /
 * `beforeMultilineDecl`) but with inverted polarity at kind-emission
 * time, so untagged / empty-body decls bucket into "single-line" and
 * non-empty type-body decls bucket into "multi-line" automatically.
 *
 * Cascade priority: after-ctor > between-ctor (path-aware) > transition
 * > between-same-ctor-if-not > before-ctor > source-driven. Sits below
 * the path-aware between family (Imports/Usings) because that family
 * also gates on both sides and would conflict otherwise; sits above
 * before-ctor so a single-line typedef → single-line typedef pair
 * still fires `betweenSingleLineTypes` even when an unrelated
 * before-ctor rule would otherwise apply.
 */
typedef BetweenSameCtorIfNotInfo = {
	classifierFieldName: String,
	classifyCases: Array<Case>,
	optField: String
};
/**
 * Shared parser-context locals bundled for the `lowerEnumBranch`
 * per-shape emission helpers (ternary / infix / prefix / postfix /
 * kw-Ref). Replaces a >5-scalar helper signature with one context
 * struct, mirroring `TryparseStarCtx`.
 */
typedef LowerBranchCtx = {
	final branch: ShapeNode;
	final typePath: String;
	final writeFnName: String;
	final hasPratt: Bool;
	final argNames: Array<String>;
	final precPostfix: Int;
};

/**
 * Aggregated cascade info arrays read off a `@:trivia` Star ShapeNode
 * by `WriterLowering.readCascadeInfosFromStar`. Each array is the
 * resolved form of one `@:fmt(blankLines*)` meta family on the same
 * Star — see the per-Info typedefs for shape semantics. Both the EOF
 * Star branch (`triviaEofStarExpr`) and the tryparse Star branch
 * (`triviaTryparseStarExpr`) consume this struct unchanged.
 *
 * `headCtorInfos` is the head-of-Star override family
 * (`blankLinesAtHeadIfCtor`); spliced once at the start of the Star
 * body. Empty array → no head emit, byte-identical to non-opt-in
 * consumers.
 */
typedef CascadeInfos = {
	afterCtorInfos: Array<AfterCtorBlankInfo>,
	beforeCtorInfos: Array<BeforeCtorBlankInfo>,
	betweenCtorInfos: Array<BetweenCtorBlankInfo>,
	transitionAcrossInfos: Array<TransitionAcrossInfo>,
	headCtorInfos: Array<HeadCtorBlankInfo>,
	betweenSameCtorIfNotInfos: Array<BetweenSameCtorIfNotInfo>
};

/**
 * Output of `WriterLowering.buildCascadeEmit` — six Exprs ready to
 * splice into the consumer's runtime block. `initPrev` / `initCurr`
 * are single combined `EVars` statements (folded across all infos);
 * `currCompute` / `trackPrev` are `EBlock`s of pure assignments;
 * `blanksCount` is the cascade ternary with fallback
 * `(_t.blankBefore ? 1 : 0)`. `headEmit` is the head-of-Star block
 * (head cascade ternary + push loop, guarded on `_arr.length > 0`)
 * spliced once at the start of the Star body, after `_docs` init.
 * Empty info arrays produce `macro {}` placeholders so non-cascade-
 * bearing consumers stay byte-identical.
 * Shared setup locals bundled for the `triviaEofStarExpr` emission
 * helpers (`triviaEofWhileExpr` / `triviaEofElseBody` + the per-flag
 * leaf Expr builders). Replaces a >5-scalar helper signature with one
 * context struct.
 * Shared setup locals + derived flags bundled for the `triviaBlockStarExpr`
 * emission helpers (the blank-before / begin-end / between / blockEnded-sep
 * builders + the main orchestrator). Replaces a >5-param helper signature
 * with one context struct (mirrors EofStarCtx / SepStarCtx).
 * The per-flag init / track / wrap leaf Exprs bundled for the orchestrator,
 * built once by `triviaBlockLeafExprs`. Replaces a multi-value return with one
 * struct.
 */
typedef BlockLeafExprs = {
	final initDocCommentExpr: Expr;
	final initCurrDocCommentExpr: Expr;
	final initCurrSplitLeadingExpr: Expr;
	final initPrevKindExpr: Expr;
	final initCurrKindExpr: Expr;
	final trackPrevKindExpr: Expr;
	final trackDocCommentExpr: Expr;
	final innerWrapExpr: Expr;
	final extraInnerTrailBlankExpr: Expr;
};
typedef BlockStarCtx = {
	final fieldAccess: Expr;
	final openText: String;
	final closeText: String;
	final emptyText: String;
	final triviaElemCall: Expr;
	final emptyDocExpr: Expr;
	final beforeCloseHardlineExpr: Expr;
	final trailBB: Expr;
	final trailLC: Expr;
	final trailClose: Expr;
	final trailOpen: Expr;
	final trailFollowExpr: Expr;
	final emptyTrailExpr: Expr;
	final blankBeforeExpr: Expr;
	final trackDocCommentExpr: Expr;
	final initDocCommentExpr: Expr;
	final initCurrDocCommentExpr: Expr;
	final initCurrSplitLeadingExpr: Expr;
	final initPrevKindExpr: Expr;
	final initCurrKindExpr: Expr;
	final trackPrevKindExpr: Expr;
	final innerWrapExpr: Expr;
	final beginTypeExpr: Expr;
	final endTypeExpr: Expr;
	final leadingSplitGateExpr: Expr;
	final extraInnerTrailBlankExpr: Expr;
	final blockLeadingBetweenExpr: Expr;
	final blockTrailBetweenExpr: Expr;
	final blockSepBeforeHardlineExpr: Expr;
	final blockTrailSepEmitExpr: Expr;
	final afterFieldsWithDocComments: Bool;
	final existingBetweenFields: Bool;
	final beforeDocCommentEmptyLines: Bool;
	final condLeadingDocInfo: Null<CondLeadingDocLookThroughInfo>;
	final interMember: Bool;
	final interMemberInfo: Null<InterMemberClassifyInfo>;
	final staticVarSubdiv: Bool;
	final staticVarSubdivInfo: Null<StaticVarSubdivisionInfo>;
	final uniformBetween: Bool;
	final uniformBetweenOptField: Null<String>;
	final anyEmptyLinesFlag: Bool;
	final uniformStmtBlanks: Bool;

	/** ω-case-sibling-symmetry: `final _csW: Int = …;` widest-sibling pre-pass, or `macro -1` when the Star has no `caseSiblingSymmetry` meta. */
	final caseSiblingWidthExpr: Expr;

	/** ω-blank-around-multiline-members: records where this gap's blank would go; `macro {}` without the flag. */
	final blankAroundMarkExpr: Expr;

	/** ω-blank-around-multiline-members: notes whether the source-driven rules already filled the gap. */
	final blankAroundSeenExpr: Expr;

	/** ω-blank-around-multiline-members: inserts the blank once both neighbours' Docs are known; `macro {}` without the flag. */
	final blankAroundApplyExpr: Expr;
};
typedef EofStarCtx = {
	final fieldAccess: Expr;
	final triviaElemCall: Expr;

	/**
	 * ω-measured-multiline-decl — the Star carries
	 * `@:fmt(measuredMultilineDecls)`, so the loop pre-builds every element's
	 * Doc into `_elemDocs` and its rendered-multiline verdict into
	 * `_measMulti`, which the cascade's `multiline` predicate reads.
	 */
	final measuredMultiline: Bool;

	/** Per-element write call with the comprehension binder `_e` as receiver — feeds the `_elemDocs` pre-pass. */
	final measuredElemCall: Expr;
	final trailBB: Expr;
	final trailLC: Expr;
	final emit: CascadeEmit;
	final pos: Position;
	final lineCommentTrailBlank: Bool;
	final lineCommentLedAddBlank: Bool;
	final afterFileHeaderCommentBlanks: Bool;
	final betweenMultilineCommentsBlanks: Bool;
};
/**
 * Shared spliced-Expr fragments + compile-time text/flags bundled for the
 * `triviaSepStarExpr` tail emission helpers (force-multi loop, predicate
 * scan, branch dispatch). Replaces a >5-param helper signature with one
 * context struct (mirrors EofStarCtx).
 */
typedef SepStarCtx = {
	final openText: String;
	final closeText: String;
	final sepText: String;
	final triviaElemCall: Expr;
	final initCurrDocCommentExpr: Expr;
	final keepCurlyBeginExpr: Expr;
	final keepCurlyEndExpr: Expr;
	final typedefBeginExpr: Expr;
	final typedefEndExpr: Expr;
	final typedefBetweenExpr: Expr;
	final blankBeforeExpr: Expr;
	final appendTrailingCommaExpr: Expr;
	final triviaLeadDoc: Expr;
	final triviaTrailDocKeepAware: Expr;
	final keepMatrixComputeExpr: Expr;
	final noTriviaBranch: Expr;
	final reflowSourceMultiline: Bool;
	final matrixWrap: Bool;
	final uniformStmtBlanks: Bool;
};
/**
 * Output bundle of `triviaSepTypedefBlanksExprs` — the seven spliced Expr
 * fragments the sep-Star force-multi loop and `_sepCtx` consume.
 */
typedef SepStarBlanks = {
	final keepCurlyBeginExpr: Expr;
	final keepCurlyEndExpr: Expr;
	final typedefBeginExpr: Expr;
	final typedefEndExpr: Expr;
	final typedefBetweenExpr: Expr;
	final blankBeforeExpr: Expr;
	final initCurrDocCommentExpr: Expr;
};
/**
 * Output bundle of `triviaSepKeepCurlyExprs` — the five `typedefBodyBlanks`-
 * gated keepCurly / typedef-RHS blank-insert Expr fragments.
 */
typedef SepStarKeepCurly = {
	final keepCurlyBeginExpr: Expr;
	final keepCurlyEndExpr: Expr;
	final typedefBeginExpr: Expr;
	final typedefEndExpr: Expr;
	final typedefBetweenExpr: Expr;
};
/**
 * Output bundle of `triviaSepKeepCurlyOpenClose` — the open/close-side
 * Keep-mode curly-blank Expr fragments.
 */
typedef SepStarKeepCurlyOC = {
	final keepCurlyBeginExpr: Expr;
	final keepCurlyEndExpr: Expr;
};
/**
 * Output bundle of `triviaSepTypedefBlankInserts` — the typedef-RHS forced
 * blank-insert Expr fragments (begin/end/between).
 */
typedef SepStarTypedefInserts = {
	final typedefBeginExpr: Expr;
	final typedefEndExpr: Expr;
	final typedefBetweenExpr: Expr;
};
/**
 * Input bundle for `triviaSepDispatchExpr` — the spliced Expr fragments +
 * compile-time flags the non-empty-list dispatch block needs to derive the
 * keep/ignore/noWrap/forceMulti predicates and pick the emit branch.
 */
typedef SepStarDispatchCtx = {
	final reflowSourceMultiline: Bool;
	final matrixWrap: Bool;
	final uniformStmtBlanks: Bool;
	final keepCheckExpr: Expr;
	final ignoreCheckExpr: Expr;
	final noWrapFlatCheckExpr: Expr;
	final predicateScanExpr: Expr;
	final matrixSucceedsExpr: Expr;
	final keepMatrixComputeExpr: Expr;
	final forceMultiExpr: Expr;
	final noTriviaBranch: Expr;
};
/**
 * Input bundle for `triviaSepNoTriviaBranch` — the spliced Expr fragments +
 * compile-time text/flags the no-trivia (wrap-cascade) branch builder needs.
 */
typedef SepStarNoTriviaCtx = {
	final openText: String;
	final closeText: String;
	final sepText: String;
	final wrapRulesField: Null<String>;
	final mapWrap: Null<SepStarMapWrap>;
	final bodyAwareCompactIndent: Bool;
	final matrixWrap: Bool;
	final groupRestProbe: Bool;
	final triviaElemCall: Expr;
	final openInsideDoc: Expr;
	final closeInsideDoc: Expr;
	final appendTrailingCommaExpr: Expr;
	final wrapLeadFlatDoc: Expr;
	final wrapLeadBreakDoc: Expr;
	final forceExceedsExpr: Expr;
	final wrapTrailBreakDoc: Expr;
	final forceModeExpr: Expr;
	final flatTrailingCommaExpr: Expr;
	final reflowSourceMultiline: Bool;

	/**
	 * ω-complex-item-count: the Star carries `@:fmt(complexItems)`, so the
	 * no-trivia branch classifies each element at the AST layer and threads the
	 * per-element codes into `WrapList.emit` as `complexItemKinds`. False on
	 * every other Star → no classification runs and the emit call is
	 * byte-identical.
	 */
	final complexItems: Bool;
};

/**
 * The second wrap cascade a sep-Star can name, and the runtime test that
 * chooses it — `@:fmt(mapWrapRules('<field>'))` on `HxExpr.ArrayExpr`, where a
 * MAP literal reads `wrapping.mapWrap` and everything else `wrapping.arrayWrap`.
 *
 * The two travel together because neither is usable alone: the field name
 * without the test would pick a cascade for every list, and the test without
 * the name has nothing to pick. `isMapLiteralExpr` is a spliced `Expr` rather than a predicate name because the class it calls depends on the build (`AstPreds` plain, `AstPredsT` trivia), which only the lowering that owns `_shape` and `_ctx` can resolve — `WriterLowering.mapWrapFor` builds both halves.
 */
typedef SepStarMapWrap = {
	final field: String;
	final isMapLiteralExpr: Expr;
};
/**
 * Output bundle of `triviaSepTrailExprs` — the source-trailing-comma /
 * force-exceeds / force-mode / keep-matrix Expr fragments the sep-Star tail
 * consumes (`_sepCtx`'s appendTrailingComma + keepMatrix, and
 * `WrapList.emit`'s forceExceeds/forceMode/flatTrailingComma args).
 */
typedef SepStarTrailExprs = {
	final forceExceedsExpr: Expr;
	final appendTrailingCommaExpr: Expr;
	final flatTrailingCommaExpr: Expr;
	final keepMatrixComputeExpr: Expr;
	final forceModeExpr: Expr;
};
/**
 * Output bundle of `triviaSepCheckExprs` — the keep/ignore/noWrap runtime
 * checks plus the leftCurly/rightCurly placement Docs the sep-Star tail
 * consumes (`_keepEmit`/`_ignoreEmit`/`_noWrapFlat`, `_sepCtx`'s lead/trail
 * Docs, and `WrapList.emit`'s lead-flat/lead-break/trail-break args).
 */
typedef SepStarChecks = {
	final keepCheckExpr: Expr;
	final ignoreCheckExpr: Expr;
	final noWrapFlatCheckExpr: Expr;
	final triviaLeadDoc: Expr;
	final wrapLeadFlatDoc: Expr;
	final wrapLeadBreakDoc: Expr;
	final wrapTrailBreakDoc: Expr;
	final triviaTrailDocKeepAware: Expr;
};
/**
 * Shared setup locals bundled for the `triviaTryparseStarExpr` emission
 * helpers (`triviaTryparseHeritageExpr` / `triviaTryparseMainExpr` + the
 * per-element while-loop / assembly sub-builders). Replaces a >5-scalar
 * helper signature with one context struct, mirroring `EofStarCtx`.
 */
typedef TryparseStarCtx = {
	final fieldAccess: Expr;
	final trailBB: Expr;
	final trailLC: Expr;
	final trailBA: Expr;
	final sepBeforeFirstExpr: Expr;
	final nestBodyExpr: Expr;
	final shapeRefusalExpr: Expr;
	final glueRefusalExpr: Expr;
	final flatGateExpr: Expr;
	final fitGateExpr: Expr;
	final writerOptExpr: Expr;
	final padLeadingExpr: Expr;
	final padTrailingExpr: Expr;
	final metaPolicyExpr: Expr;
	final condIncreaseGateExpr: Expr;
	final condNestedIncreaseGateExpr: Expr;
	final cascadeInitPrev: Expr;
	final cascadeInitCurr: Expr;
	final cascadeCurrCompute: Expr;
	final cascadeTrackPrev: Expr;
	final cascadeHeadEmit: Expr;
	final cascadeBlanksCount: Expr;
	final priorAfterTrailEmit: Expr;
	final priorAfterTrailRaw: Expr;
	final padLeadingSpaceDoc: Expr;
	final subsequentSepDoc: Expr;
	final firstSepExpr: Expr;
	final triviaElemCall: Expr;
	final triviaElemCallMaybeBreak: Expr;
	final elemOptInit: Expr;
	final tryparseBlockEndedSepEmit: Expr;
	final tryparseBlockEndedTrailEmit: Expr;
	final lastTrailTerminatorEmit: Expr;
	final finalWrapDocs: Expr;
	final forceInlineSep: Bool;
	final elemSelfTrailsNewline: Bool;

	/**
	 * omega-cond-expr-fit: the trailing-pad SPACE Doc - `_dt(' ')` for every
	 * ordinary Star, the knob-gated soft `Line(' ')` for a Star carrying
	 * `@:fmt(condExprFitBreak)` (the expression-scope cond-comp `elseifs`).
	 */
	final trailPadSpaceDoc: Expr;

	/** Typed nested-conditional element probe fn-ref (`AstPredsT.elementIsConditional_<ElemRule>`), or null when the format has no generated predicates. */
	final elemCondFn: Null<Expr>;
};
typedef CascadeEmit = {
	initPrev: Expr,
	initCurr: Expr,
	currCompute: Expr,
	trackPrev: Expr,
	blanksCount: Expr,
	headEmit: Expr
};

/**
 * Mutable accumulators threaded through the `buildCascadeEmit` per-axis
 * compute helpers (`emitAfterCompute` etc.). Each helper appends its
 * `prev`/`curr` tracker var decls, its per-element compute statements, and
 * its prev-tracking assignments. Bundled so the helpers take one
 * destination param (the "pass the destination" pattern) instead of four.
 */
typedef CascadeAccum = {
	final prevVars: Array<Var>;
	final currVars: Array<Var>;
	final currCompute: Array<Expr>;
	final trackPrev: Array<Expr>;
};

/**
 * ω-imports-using-blank — resolved data for
 * `@:fmt(blankLinesBeforeCtor(classifierField, CtorName1, [CtorName2, …], optField))`.
 * Produced by `WriterLowering.buildBeforeCtorBlankInfo` and spliced into
 * `triviaEofStarExpr`'s per-element loop. Shape mirrors
 * `AfterCtorBlankInfo` exactly — same single-axis classify-switch
 * (`1` for any matching ctor, `0` otherwise) plus an opt-field name —
 * the two diverge only at the runtime gate. After-ctor's gate fires on
 * `_prevKindAfter == 1`; before-ctor's gate fires on
 * `_currKindBefore == 1 && _prevKindBefore != 1`, which gives the
 * "first X after a non-X" transition semantics (e.g. force a blank
 * line at `import → using`, no force between consecutive `using` decls).
 *
 * Cascade priority in `triviaEofStarExpr`: after-ctor entries (in
 * source order) win first, then before-ctor entries (in source order,
 * each gated on `prev != curr` for that entry's set), then source-
 * driven `blankBefore`. A single decl pair is governed by at most one
 * override; no double-counting. Multiple before-ctor entries on the
 * same Star are supported (ω-after-typedecl) — same shape as
 * `AfterCtorBlankInfo`, evaluated independently per entry.
 */
typedef BeforeCtorBlankInfo = {
	classifierFieldName: String,
	classifyCases: Array<Case>,
	optField: String,
	// ω-before-multiline-prev-not — when non-null, a second binary
	// classify-switch (kind=1 if the element's classifier ctor is in the
	// excluded-prev set, e.g. `Conditional`). The before-ctor cascade
	// ternary gains an extra `&& _prevKindPrevExcl != 1` guard so the
	// override is suppressed when the previous sibling matched an excluded
	// ctor — the cascade then falls through to the source-driven
	// `_t.blankBefore` count. Closes the spurious-blank-after-`#end` bug
	// (issue_298): a cond-comp `#if … #end` immediately before a multiline
	// class no longer forces `beforeMultilineDecl` regardless of source.
	// Null for the plain `blankLinesBeforeCtor{,If}` builders → no extra
	// tracker, byte-identical cascade.
	?prevExcludeCases: Null<Array<Case>>
};

/**
 * ω-imports-using-between — resolved data for
 * `@:fmt(blankLinesBetweenSameCtorByLevel(classifierField, CtorName1,
 * [CtorName2, …], levelOptField, countOptField, adapterOptField))`.
 * Produced by `WriterLowering.buildBetweenCtorBlankInfo` and spliced
 * into `triviaEofStarExpr`'s per-element loop alongside the
 * after/before-ctor families. Shape diverges from those two: the
 * runtime tracks both a kind flag (1 for any matching ctor, 0 otherwise)
 * AND a path String (first ctor arg of the matched ctor, e.g. the
 * `HxTypeName`/`HxWildPath` payload of `ImportDecl(path)`). The cascade
 * ternary fires `opt.<countOptField>` blank lines when both prev and
 * curr match the same set AND
 * `opt.<adapterOptField>(prevPath, currPath, opt.<levelOptField>)`
 * returns `true`.
 *
 * `ctorPatterns` carries one entry per enum variant in the classifier
 * target — `pattern` is a ready-to-use ESwitch case pattern (matched
 * ctors bind their first positional arg as `_v0`; unmatched ctors use
 * a wildcard for every arg). The case body is generated at cascade-
 * emit time inside `triviaEofStarExpr` because it needs to reference
 * the per-info `_currTailKindBetween<i>` / `_currTailPathBetween<i>` ident
 * names, which depend on the info's index in the cascade.
 *
 * `adapterOptField` names a function-typed field on `WriteOptions`
 * (e.g. `betweenImportsPathDiffers:Null<(String, String, Int) -> Bool>`)
 * default-wired by the grammar plugin. Engine emits a pure
 * `opt.<adapterOptField>(...)` EField call — no FQN parsing, no
 * grammar-package coupling baked into the macro core. Cascade
 * priority: after-ctor entries (outermost) > between entries >
 * before-ctor entries > source-driven `blankBefore`.
 *
 * `tailAdapterOptField` (ω-cond-comp-tail-transparency) and
 * `headAdapterOptField` (ω-imports-using-transition) name generated
 * typed leaf walkers on the trivia predicate class
 * (e.g. `AstPredsT.betweenImportsTailLeafClassify` /
 * `betweenImportsHeadLeafClassify`, each
 * `<payload> -> Null<{ctorName, path}>` — the meta arg is the
 * function name; the `OptField` suffix survives from the retired
 * `WriteOptions` adapter era, unlike the sibling `adapterOptField`
 * which still names a real opt field). When non-null, ctors
 * named in `transparentCtorNames` are routed through the matching
 * direction's walker at runtime: tail walks the wrapper payload (e.g.
 * `HxConditionalDecl`) to its LAST-branch / LAST-element leaf decl,
 * head walks to FIRST-branch / FIRST-element. Each walker returns
 * `{ctorName, path}`; the engine runs a runtime
 * `_r.ctorName == 'CtorA' || _r.ctorName == 'CtorB'` filter against
 * the per-info `matchedCtorNames` list — so a single shared walker
 * pair can feed multiple between infos on the same Star (one walker
 * pair drives both Imports and Usings infos on `HxModule.decls`).
 * Tail feeds the next iteration's prev-side via the track-step;
 * head feeds THIS iteration's curr-side at cascade fire. Either or
 * both walker fields may be null: the absent direction zeros out
 * its kind/path for transparent ctors (same as the unmatched bucket)
 * while the wired direction's classification still drives the
 * cascade. With both null, transparent ctors fall fully into the
 * unmatched bucket.
 *
 * `transparentCtorNames` lists the wrapper ctor names (e.g.
 * `Conditional`) collected from
 * `@:fmt(blankLinesBetweenSameCtorTailTransparent(classifierField,
 * ctorName, adapterOptField))` and
 * `@:fmt(blankLinesBetweenSameCtorHeadTransparent(...))` metas with
 * matching classifier field — merged across both directions, so any
 * ctor that appears in EITHER meta becomes transparent. Validated
 * arity ≥ 1 (first positional arg is the wrapper payload passed to
 * the adapter pair).
 */
typedef BetweenCtorBlankInfo = {
	classifierFieldName: String,
	ctorPatterns: Array<BetweenCtorPattern>,
	matchedCtorNames: Array<String>,
	levelOptField: String,
	countOptField: String,
	adapterOptField: String,
	tailAdapterOptField: Null<String>,
	headAdapterOptField: Null<String>,
	transparentCtorNames: Array<String>
};

/**
 * One ESwitch case pattern with its matched/unmatched/transparent flag,
 * used by `BetweenCtorBlankInfo`. Matched-ctor patterns bind `_v0` to
 * the ctor's first positional arg so the cascade-emit phase can read
 * the import / using path String at runtime. Transparent-ctor patterns
 * also bind `_v0` (the wrapper payload, e.g. `HxConditionalDecl`) so
 * the emit phase can pass it to the tail-leaf classifier adapter.
 * Unmatched-ctor patterns use a wildcard for every arg.
 *
 * `isMatch` and `isTransparent` are mutually exclusive — at most one
 * is `true`. `isMatch=true` → kind=1/path=_v0 case body. `isTransparent
 * =true` → adapter-call case body filtered by per-info ctorNames.
 * Both `false` → kind=0/path='' (unmatched fallback).
 */
typedef BetweenCtorPattern = {
	pattern: Expr,
	isMatch: Bool,
	isTransparent: Bool
};

/**
 * ω-imports-using-transition — resolved data for
 * `@:fmt(blankLinesOnTransitionAcross(classifierField, CtorA1,
 * [CtorA2, …], '|', CtorB1, [CtorB2, …], countOptField))`. Produced by
 * `WriterLowering.buildTransitionAcrossInfo` and spliced into
 * `triviaEofStarExpr`'s per-element loop alongside the
 * `BetweenCtorBlankInfo` family.
 *
 * Fires `opt.<countOptField>` blank lines when prev's tail-classified
 * kind and curr's head-classified kind fall into DIFFERENT subsets
 * (subset A vs subset B): `(prevTailA==1 && currHeadB==1) || (prevTailB
 * ==1 && currHeadA==1) → fire`. Mirrors fork's `MarkEmptyLines.markImports`
 * cross-kind emit (`prevInfo.isImport != newInfo.isImport →
 * emit beforeUsing`).
 *
 * Transparent-ctor support is inherited from the same Star's
 * `blankLinesBetweenSameCtor{Tail,Head}Transparent` metas — the merged
 * `transparentByClassifier` map's adapter pair feeds both the betweenCtor
 * and transitionAcross runtime classifiers, so a single pair of
 * head/tail walkers covers all classifiers on the same Star.
 *
 * `ctorPatterns` carries one entry per enum variant in the classifier
 * target. `subset` selects the case-body shape: 1 for subset A match,
 * 2 for subset B match, 3 for transparent (calls head + tail adapters
 * and sets each direction's A/B flags by ctorName lookup), 0 for
 * unmatched (zero out all flags). Matched-ctor patterns bind `_v0` to
 * the ctor's first positional arg (currently unused at this cascade,
 * reserved for parity with `BetweenCtorBlankInfo` and possible future
 * path-aware transition rules); transparent-ctor patterns also bind
 * `_v0` (the wrapper payload passed to the adapter pair); unmatched
 * patterns wildcard every arg.
 */
typedef TransitionAcrossInfo = {
	classifierFieldName: String,
	ctorPatterns: Array<TransitionAcrossPattern>,
	matchedCtorNamesA: Array<String>,
	matchedCtorNamesB: Array<String>,
	countOptField: String,
	tailAdapterOptField: Null<String>,
	headAdapterOptField: Null<String>,
	transparentCtorNames: Array<String>
};

/**
 * One ESwitch case pattern with its subset tag for `TransitionAcrossInfo`.
 * `subset`: 1 = matched in subset A, 2 = matched in subset B, 3 =
 * transparent wrapper, 0 = unmatched.
 */
typedef TransitionAcrossPattern = {
	pattern: Expr,
	subset: Int
};

/**
 * The two ctor subsets split out of the `@:fmt(blankLinesOnTransitionAcross)`
 * arg list (around the `"|"` separator) after pre-loop validation, returned
 * by `splitTransitionAcrossCtors`.
 */
typedef TransitionAcrossSplit = {
	final ctorNamesA: Array<String>;
	final ctorNamesB: Array<String>;
};

/**
 * Parameters for `buildTransitionAcrossPatterns` — the classifier enum
 * (Alt) plus the three ctor-name subsets that drive the per-branch
 * pattern build. Bundled to keep the helper under the >5-scalar threshold.
 */
typedef TransitionAcrossPatternsCtx = {
	final enumRule: ShapeNode;
	final enumRuleName: String;
	final ctorNamesA: Array<String>;
	final ctorNamesB: Array<String>;
	final transparentCtorNames: Array<String>;
};

/**
 * Result of `buildTransitionAcrossPatterns` — the assembled switch
 * patterns plus the ctor-name sets actually matched in each subset
 * (used by the orchestrator's post-loop "not found in enum" validation).
 */
typedef TransitionAcrossPatterns = {
	final patterns: Array<TransitionAcrossPattern>;
	final matchedA: Array<String>;
	final matchedB: Array<String>;
	final transparentMatched: Array<String>;
};

/**
 * Internal result type shared by `buildAfterCtorBlankInfo` and
 * `buildBeforeCtorBlankInfo` — both metas accept the same arg shape
 * and produce the same classify-switch + optField pair, then wrap it
 * into their respective Info typedef. Centralising the resolution in
 * one helper keeps shape-validation messages and the classifier-lookup
 * path in sync between the two knobs.
 */
typedef CtorBlankResolution = {
	fieldName: String,
	cases: Array<Case>,
	optField: String
};
/**
 * Shared setup locals bundled for the `lowerEnumStar` emission helpers
 * (`lowerEnumStarTrivia` / `lowerEnumStarPlain`). Replaces a >5-scalar
 * helper signature with one context struct.
 */
typedef EnumStarCtx = {
	final branch: ShapeNode;
	final argNames: Array<String>;
	final argsAccess: Expr;
	final elemFn: String;
	final elemCall: Expr;
	final leadText: String;
	final trailText: String;
	final sepText: Null<String>;
	final starNode: ShapeNode;
};

/**
 * Shared setup locals bundled for the `lowerPostfixStar` emission helpers
 * (`lowerPostfixSepListCall` / `lowerPostfixPushElem` / `lowerPostfixTailExpr`).
 * Replaces a >5-scalar helper signature with one context struct (mirrors
 * `EnumStarCtx`).
 */
typedef PostfixStarCtx = {
	final branch: ShapeNode;
	final postfixOp: String;
	final postfixClose: String;
	final elemSep: String;
	final isTriviaStar: Bool;
	final argNames: Array<String>;
	final tcExpr: Expr;
	final callInsideOpen: Expr;
	final callInsideClose: Expr;
	final wrapRulesField: Null<String>;
	final methodChainField: Null<String>;
	final elemCall: Expr;
};

/**
 * Spliced sub-Exprs shared by the two `wrapWithChainDispatch` chain-walk
 * macro bodies (`wrapChainTriviaBody` / `wrapChainPlainBody`). Bundled to
 * keep each body helper under the >5-scalar threshold.
 */
typedef ChainDispatchCtx = {
	final argsListExpr: Expr;
	final argDocsExpr: Expr;
	final chainRulesExpr: Expr;
	final writeIdent: Expr;
	final precExpr: Expr;
	final segCallLeadingBreakExpr: Expr;
	final body: Expr;
};

/**
 * Trivia-mode synth-ctor positional-arg writer bindings derived once in
 * `lowerEnumStarTrivia` and threaded into both `triviaSepStarBuild` and
 * `triviaBlockStarBuild`.
 */
typedef TriviaAltSlots = {
	final trailCloseAccess: Null<Expr>;
	final trailOpenAccess: Null<Expr>;
	final trailBBAccess: Null<Expr>;
	final trailLCAccess: Null<Expr>;
	final sepTrailPresentAccess: Null<Expr>;
};
/**
 * Shared trivia-Star setup locals bundled for the `emitTrivia*Star`
 * dispatch helpers split out of `emitWriterStarField`. Replaces a >5-param
 * helper signature with one context struct (mirrors the static `*StarCtx`
 * structs the per-helper emit code consumes).
 */
typedef TriviaStarCtx = {
	final starNode: ShapeNode;
	final fieldAccess: Expr;
	final elemFn: String;
	final elemRefName: String;
	final isFirstField: Bool;
	final isLastField: Bool;
	final typePath: String;
	final openText: Null<String>;
	final closeText: Null<String>;
	final sepText: Null<String>;
	final prevBareRefBody: Null<PrevBodyInfo>;
	final prevTrailFieldName: Null<String>;
	final fieldName: Null<String>;
	final trailBBAccess: Null<Expr>;
	final trailNLAccess: Null<Expr>;
	final trailLCAccess: Null<Expr>;
	final trailCloseAccess: Null<Expr>;
	final trailOpenAccess: Null<Expr>;
	final trailBAAccess: Null<Expr>;
	final trailPresentAccess: Null<Expr>;
};
/**
 * Shared plain-mode (non-`@:trivia`) Star setup locals bundled for the
 * `emit*Star` plain dispatch helpers split out of `emitWriterStarField`.
 * `elemCall` is the per-element write-call Expr threaded into every branch.
 */
typedef PlainStarCtx = {
	final starNode: ShapeNode;
	final fieldAccess: Expr;
	final elemCall: Expr;
	final elemFn: String;
	final elemRefName: String;
	final isFirstField: Bool;
	final isLastField: Bool;
	final isRaw: Bool;
	final typePath: String;
	final openText: Null<String>;
	final closeText: Null<String>;
	final sepText: Null<String>;
	final prevBareRefBody: Null<PrevBodyInfo>;
};
/**
 * The resolved per-call Star locals of `emitWriterStarField` bundled into one
 * struct so the `emitTriviaStar` dispatch (and the plain-mode ctx build) take a
 * single param instead of the full 13-scalar set.
 */
typedef StarFieldArgs = {
	final starNode: ShapeNode;
	final fieldAccess: Expr;
	final elemFn: String;
	final elemRefName: String;
	final isFirstField: Bool;
	final isLastField: Bool;
	final isRaw: Bool;
	final typePath: String;
	final openText: Null<String>;
	final closeText: Null<String>;
	final sepText: Null<String>;
	final prevBareRefBody: Null<PrevBodyInfo>;
	final prevTrailFieldName: Null<String>;
};
/**
 * The resolved `@:fmt` pad flags of `emitTryparsePadStar` bundled for the
 * `emitTryparsePadEmit` emission helper, so it takes one param instead of the
 * five-bool set.
 */
typedef PadFlags = {
	final padLeading: Bool;
	final padTrailing: Bool;
	final lineLengthAwareSeps: Bool;
	final sepBeforeOptActive: Bool;
	final softFill: Bool;
};
/**
 * The three classify-info results resolved by
 * `WriterLowering.buildTriviaBlockInfos`, bundled so the block-mode trivia
 * dispatch takes one value instead of three separate locals.
 */
typedef TriviaBlockInfos = {
	final interMemberInfo: Null<InterMemberClassifyInfo>;
	final staticVarSubdivInfo: Null<StaticVarSubdivisionInfo>;
	final condLeadingDocInfo: Null<CondLeadingDocLookThroughInfo>;
};
/**
 * The first / subsequent element separator overrides resolved by
 * `WriterLowering.buildTryparseSepOverrides`, bundled so the tryparse dispatch
 * takes one value instead of two separate locals.
 */
typedef TryparseSepOverrides = {
	final firstSepOverride: Null<Expr>;
	final subsequentSepOverride: Null<Expr>;
};

/**
 * Synth-ctor positional-arg slot kind for `altSlotAccess`. Order MUST
 * mirror `TriviaTypeSynth.buildEnumCtor`'s push order — the walker
 * relies on declaration order to skip slots preceding the requested one.
 */
enum abstract AltSlot(Int) {

	final CloseTrailing = 0;
	final TrailOpt = 1;
	final CaptureSource = 2;
	final BodyPolicyKw = 3;
	final WrapOpenNewline = 4;
	final KwNewline = 5;
	final ChainNewline = 6;
	final ChainLeadComment = 7;
	final PostfixOpSpace = 8;
	final ChainAfterComment = 9;
	final ChainRhsTrail = 10;
	final TernaryCondTrail = 11;
	final TernaryThenTrail = 12;

}
#end
