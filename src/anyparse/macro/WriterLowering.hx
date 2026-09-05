package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.macro.WriterTriviaSlotLowering.*;
import anyparse.macro.WriterStarPadLowering.*;
import anyparse.macro.WriterRefLeadLowering.*;
import anyparse.macro.WriterCondWrapLowering.*;
import anyparse.macro.WriterBraceSymmetryLowering.*;
import anyparse.macro.PrattMeta.*;
import anyparse.macro.WriterBlankLowering.*;
import anyparse.macro.WriterCascadeLowering.*;
import anyparse.macro.WriterPolicyLowering.*;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterChainLowering.*;
import anyparse.macro.MacroNames.*;

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
 * The writer lowering is SEVERAL modules, split four ways.
 *
 * FIVE are LAYERS, one responsibility each — `WriterLoweringSupport` (the
 * shared field-access / name / `@:fmt`-argument vocabulary),
 * `WriterPolicyLowering` (the `hxformat.json` policy separators),
 * `WriterCascadeLowering` (the `@:fmt(blankLines*)` cascade),
 * `WriterChainLowering` (`@:fmt(methodChain)`) and `WriterBlankLowering`
 * (the shared source-fidelity probes). Their members are reached
 * UNQUALIFIED from here — a wildcard import plus the class-level
 * `@:access` — which is what let them move without touching a call site,
 * and is why they stayed private.
 *
 * FOUR carry a trivia Star emit family each — `TriviaTryparseLowering`,
 * `TriviaEofLowering`, `TriviaSepLowering` and `TriviaBlockLowering`. Each
 * is entered from one or two members here under `@:access`, calls back
 * into the shared lowering utilities (`optFieldAccess`, `astPredCallT`,
 * `buildCascadeEmit`, `blankBefore2ExtrasExpr`, …) the same way, and types
 * its parameters with this module's sub-module typedefs, which stayed
 * behind.
 *
 * SIX carry a SHAPE FAMILY each — one region of this module's call graph,
 * moved whole: `WriterPrattLowering` (`@:ternary` / `@:infix` / `@:prefix`
 * / `@:postfix` branches), `WriterKwRefLowering` (the keyword-plus-`Ref`
 * enum branches), `WriterBodyPolicyLowering` (`@:fmt(bodyPolicy)` and its
 * five layouts), `WriterArrowValueIfLowering`
 * (`@:fmt(arrowValueIfReflow)`), `WriterCtorBlankLowering` (the
 * `@:fmt(blankLines*)` INFO readers) and `WriterTriviaStarDispatch` (the
 * close-peek trivia Star dispatch). These differ from the nine above in
 * one way that matters: their members were INSTANCE methods here, so the
 * extraction had to hand each family the build state explicitly. Each got
 * a ctx-bundle typedef of its own, built once in the constructor
 * (`_pratt`, `_kwRef`, `_bodyPolicy`, `_arrowValueIf`, `_ctorBlank`,
 * `_triviaStar`) and passed as the first argument; the bundle IS the
 * family's dependency surface, so widening one is a visible edit here.
 * Nothing else about the class made that possible or hard: `_shape`,
 * `_formatInfo` and `_ctx` are set once in the constructor and never
 * written, so every member is already a pure function of the three.
 *
 * FIVE are PURITY modules, and they came from a different question: not
 * which shape family a member belongs to, but what state it reads. A
 * census of the 127 members found 25 that touch none of `_shape`,
 * `_formatInfo`, `_ctx` or the six bundles, directly or through a callee —
 * pure functions of their arguments. For those, `private function` becomes
 * `private static function` in a sibling module at no call-site cost, so
 * `WriterCondWrapLowering`, `WriterStarPadLowering`,
 * `WriterTriviaSlotLowering`, `WriterRefLeadLowering` and
 * `WriterBraceSymmetryLowering` each took one QUESTION worth of them, and
 * `reindentBlockEmit` joined `WriterBlankLowering`. The axis stops there:
 * the other 102 members read build state, and moving one of those is a
 * signature change at every call site. `astPredCallT` is the 25th and
 * stayed anyway — it is pure, but five sibling modules call it QUALIFIED
 * at 11 sites, and it reads the process-scoped `_predRootStatic` that
 * `generate` writes.
 *
 * ONE more went to `WriterBraceSymmetryLowering`, and it is a different
 * axis again — the STATE-CARRYING half of a family whose pure half had
 * already left. Re-running the census over the 121 members that remained,
 * but recording the SLICE each member needs rather than a yes/no, says
 * something the pure/impure split cannot: 50 members / 2482 lines reach
 * the instance only through `_ctx.trivia` and `_shape.rules` — one `Bool`
 * and one `Map`. That is one call graph, not a decomposition (it is
 * everything reachable from `isTriviaBearing`), but it prices the families
 * inside it, and the prices differ by twenty-five times. The trivia-paired
 * NAMING vocabulary — `isTriviaBearing`, `writeFnFor`, `ruleCtorPath`,
 * `ruleValueCT` — is the CHEAPEST to free and the WORST to move: 42 lines
 * behind 33 inbound call sites, because `isTriviaBearing` is the hub
 * (fan-in 19) and a hub is what everything else is impure THROUGH. The
 * ctor-pattern lookups are 218 lines behind 25 sites. Brace symmetry is
 * 382 lines behind SEVEN, so brace symmetry moved: twelve members plus
 * `VALUE_BRACE_SYMMETRY_MIN_ARGS`, each now `private static` with a
 * `BraceSymmetryCtx` bundle (`_braceSym`) as its first argument.
 *
 * That the move is byte-inert is not an inference. This module is
 * `#if macro`, so nothing here reaches a JS target's output — only the
 * writer it GENERATES does. A build of the moved tree hashes into the same
 * four-md5 float set an unmoved tree produces, which is the same `cmp`
 * proof the purity moves had.
 *
 * ⚠️ Star emission FORKS across FOUR sites — `Lowering.emitStarFieldSteps`
 * and its `lowerEnumBranch` Case 4 branch on the parse side,
 * `emitWriterStarField` and `lowerEnumStar` here. Both writer forks stayed
 * in this module deliberately: an extraction that took one and left the
 * other would put the pair in two files with nothing naming the other
 * half. `WriterStarPadLowering` holds plain-Star LEAF emitters taken out
 * from under `emitWriterStarField`; none of them is reachable from
 * `lowerEnumStar` (measured on the call graph), so neither fork half was
 * separated from its twin.
 *
 * Generated code references `_dt`, `_dc`, `_dhl`, `_de` etc. — thin
 * wrappers over `Doc` constructors emitted by `WriterCodegen` on the
 * same class. This avoids direct enum constructor calls in `macro {}`
 * blocks, which trigger macro-time type checking.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterBraceSymmetryLowering, anyparse.macro.WriterCascadeLowering,
	anyparse.macro.WriterChainLowering, anyparse.macro.WriterCondWrapLowering, anyparse.macro.WriterLoweringSupport,
	anyparse.macro.WriterPolicyLowering, anyparse.macro.WriterRefLeadLowering, anyparse.macro.WriterStarPadLowering,
	anyparse.macro.WriterTriviaSlotLowering)
class WriterLowering {

	/**
	 * omega-arrow-value-if-reflow - the per-field opt-in flag read at four
	 * unrelated lowering sites (body policy, pre-kw separator, both branch
	 * opt-fanouts). Named once so a rename cannot desynchronise them; the
	 * class has no other flag-name constants, so this is the convention's
	 * first member rather than an existing group.
	 */
	private static inline final ARROW_VALUE_IF_SITE: String = 'arrowValueIfReflowSite';

	/**
	 * omega-strict-fitline-body: the field flag that makes a `FitLine` body policy answer
	 * for the WHOLE body rather than for its first line. Read at the three
	 * `bodyPolicyWrap` seats a body field can arrive through, for the same reason
	 * `ARROW_VALUE_IF_SITE` is named once.
	 */
	private static inline final STRICT_FIT_LINE_BODY: String = 'strictFitLineBody';

	/** omega-bracket-body-glue: the `@:fmt` entry naming the knob that hugs a `[` body to its branch head. */
	private static inline final BRACKET_BODY_GLUE: String = 'bracketBodyGlueIfFlag';

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

	/**
	 * The Pratt branch family's ctx bundle — see `WriterPrattLowering`.
	 *
	 * Built here rather than per call because it is the whole of what that
	 * module may read: change the family's dependency surface and this
	 * literal is what has to grow.
	 */
	private final _pratt: anyparse.macro.WriterPrattLowering.PrattLoweringCtx;

	/** The close-peek trivia Star dispatch's ctx bundle — see `WriterTriviaStarDispatch`. */
	private final _triviaStar: anyparse.macro.WriterTriviaStarDispatch.TriviaStarDispatchCtx;

	/** The blank-line cascade INFO builders' ctx bundle — see `WriterCtorBlankLowering`. */
	private final _ctorBlank: anyparse.macro.WriterCtorBlankLowering.CtorBlankCtx;

	/** The keyword-plus-Ref enum branch family's ctx bundle — see `WriterKwRefLowering`. */
	private final _kwRef: anyparse.macro.WriterKwRefLowering.KwRefCtx;

	/** The body-policy family's ctx bundle — see `WriterBodyPolicyLowering`. */
	private final _bodyPolicy: anyparse.macro.WriterBodyPolicyLowering.BodyPolicyCtx;

	/** The arrow-value-`if` family's ctx bundle — see `WriterArrowValueIfLowering`. */
	private final _arrowValueIf: anyparse.macro.WriterArrowValueIfLowering.ArrowValueIfCtx;

	/** The brace-symmetry family's ctx bundle — see `WriterBraceSymmetryLowering`. */
	private final _braceSym: anyparse.macro.WriterBraceSymmetryLowering.BraceSymmetryCtx;

	public function new(shape: ShapeBuilder.ShapeResult, formatInfo: FormatReader.FormatInfo, ctx: LoweringCtx) {
		_shape = shape;
		_formatInfo = formatInfo;
		_ctx = ctx;
		_pratt = {
			shape: shape,
			ctx: ctx,
			ruleValueCT: ruleValueCT,
			writeFnFor: writeFnFor
		};
		_bodyPolicy = {
			shape: shape,
			ctx: ctx,
			branchCtorPattern: branchCtorPattern,
			buildBracketBodyGlueTest: buildBracketBodyGlueTest,
			findCtorPattern: findCtorPattern,
			foldSsbTrailingComment: foldSsbTrailingComment
		};
		_ctorBlank = { shape: shape, branchSynthExtraArity: branchSynthExtraArity };
		_triviaStar = {
			shape: shape,
			formatInfo: formatInfo,
			isSpacedLead: isSpacedLead,
			mapWrapFor: mapWrapFor
		};
		_kwRef = {
			shape: shape,
			ctx: ctx,
			bodyPolicy: _bodyPolicy,
			isTightLead: isTightLead,
			isTriviaBearing: isTriviaBearing,
			writeFnFor: writeFnFor
		};
		_arrowValueIf = {
			shape: shape,
			ctx: ctx,
			isTriviaBearing: isTriviaBearing,
			ruleCtorPath: ruleCtorPath,
			branchSynthExtraArity: branchSynthExtraArity
		};
		_braceSym = {
			shape: shape,
			ctx: ctx,
			findCtorPattern: findCtorPattern,
			isTriviaBearing: isTriviaBearing,
			ruleCtorPath: ruleCtorPath
		};
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

	@:access(anyparse.macro.WriterKwRefLowering, anyparse.macro.WriterPrattLowering)
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
		if (ternaryOp != null) return WriterPrattLowering.lowerTernaryBranch(_pratt, c);

		// ---- Infix ----
		if (prattPrec != null) return WriterPrattLowering.lowerInfixBranch(_pratt, c);

		// ---- Prefix ----
		if (prefixOp != null) return WriterPrattLowering.lowerPrefixBranch(c);

		// ---- Postfix ----
		if (postfixOp != null) return WriterPrattLowering.lowerPostfixBranch(_pratt, c);

		// ---- Cases 0/1/2: zero-arg kw / zero-arg lit / multi-lit Bool ----
		final litKwDoc: Null<Expr> = WriterKwRefLowering.lowerLitKwBranch(_kwRef, c);
		if (litKwDoc != null) return litKwDoc;

		// ---- Case 4: single-arg Star with lead/trail ----
		if (leadText != null && trailText != null && children.length == 1 && children[0].kind == Star)
			return lowerEnumStar(branch, typePath, writeFnName, hasPratt, argNames);

		// ---- Case 3: single-arg Ref ----
		if (litList == null && children.length == 1 && children[0].kind == Ref) return WriterKwRefLowering.lowerKwRefBranch(_kwRef, c);

		Context.fatalError('WriterLowering: unsupported enum branch shape for ${simpleName(typePath)}', Context.currentPos());
		throw 'unreachable';
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

	@:access(anyparse.macro.WriterArrowValueIfLowering)
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
		final wrapped: Expr = WriterArrowValueIfLowering.arrowValueIfReflowWrap(_arrowValueIf, node, dcExpr);
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
	@:access(anyparse.macro.TriviaTryparseLowering, anyparse.macro.WriterCtorBlankLowering)
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
		final cascadeInfos: CascadeInfos = WriterCtorBlankLowering.readCascadeInfosFromStar(_ctorBlank, starNode, elemRefName);
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
			tryCatchesSymmetryWrap(_braceSym, starNode, fieldAccess, elemRefName), elemFn, sepExpr, sameLineName != null, nestBody,
			tryparseTrailBB, tryparseTrailLC, tryparseTrailBA, firstSepOverride, subsequentSepOverride, caseBodyFlagNames,
			flatChildOptPairs, tryparsePadLeading, tryparsePadTrailing, propagateExprPosition, refuseFlatOnComplex,
			cascadeInfos.afterCtorInfos, cascadeInfos.beforeCtorInfos, cascadeInfos.betweenCtorInfos, cascadeInfos.transitionAcrossInfos,
			cascadeInfos.headCtorInfos, metaLineEndOptField, cascadeInfos.betweenSameCtorIfNotInfos, tryparseLineLengthAware,
			tryparsePriorAfterTrailExpr, tryparseForceInlineSep, tryparseBlockEnded || tryparseSepFaithful ? tryparseSepText : null,
			tryparseBlockEnded, tryparseSepFaithful, tryparseHeritageWrap, tryparseCondBodyIndent, tryparseOperandBreakAfterMultilineBrace,
			clearExprPositionNonTail, tryparseSepBeforeAccess, tryparseElemSelfTrailsNewline, tryparseCondExprFit, tryparseElemCondFn,
			refuseGlueOnControlFlow, tryparseFillItems
		));
	}

	/**
	 * Trivia EOF Star dispatch (the `else if (isLastField)` branch of the
	 * `isTriviaStar` block in `emitWriterStarField`). Reads the cascade infos and
	 * file-header / line-comment blank flags, then pushes the `triviaEofStarExpr`
	 * emit onto `parts`. Extracted to keep the orchestrator under the complexity
	 * gate.
	 */
	@:access(anyparse.macro.TriviaEofLowering, anyparse.macro.WriterCtorBlankLowering)
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
		final cascadeInfos: CascadeInfos = WriterCtorBlankLowering.readCascadeInfosFromStar(
			_ctorBlank, starNode, elemRefName, measuredMultiline ? (macro _measMulti[_si]) : null
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
	 * builds the `TriviaStarCtx` via `buildTriviaStarCtx`, then routes to the
	 * tryparse / close / EOF trivia emit helper. Extracted to keep the orchestrator
	 * under the complexity gate.
	 */
	@:access(anyparse.macro.WriterTriviaStarDispatch)
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
			WriterTriviaStarDispatch.emitTriviaCloseStar(_triviaStar, triviaCtx, parts);
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
		// omega-bracket-body-glue CLOSE side: the gap before a keyword whose PRECEDING
		// sibling is a body the knob hugs to its head. `HxIfExpr.elseBranch` is the one
		// consumer — `sameLineExpressionElse` resolves to `Keep` under
		// `expressionIf: next`, so the gap answers from the source, and a source that
		// wrote `];` on its own line keeps `else` on the next one forever. Turning the
		// knob on is the explicit statement that this shape closes with `] else`, the
		// mirror of the `if (c) [` it already opens with. Layered OUTSIDE
		// `sameLineSeparator` so the `Keep` slot, the `shapeAware` switch and the
		// `padTrailing` drop keep their exact bytes for every other field, and INSIDE the
		// comment layers below so a captured own-line comment still replaces the gap.
		final sepPlainExpr: Expr = sameLineSeparator(child, prevBodyField, typePath, prevPadTrailing);
		final glueTest: Null<Expr> = prevBodyField == null
			? null
			: buildBracketBodyGlueTest(child.fmtReadStringArgs(BRACKET_BODY_GLUE), prevBodyField.typePath, prevBodyField.access);
		final sepBaseExpr: Expr = glueTest == null ? sepPlainExpr : {
			final glued: Expr = withPadTrailingDrop(prevPadTrailing, macro _dt(' '));
			macro ($glueTest ? $glued : $sepPlainExpr);
		};
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
		for (branch in rule.children) if (TriviaPairAltCtor.isAltCloseTrailingBranch(branch)) {
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
	 * omega-bracket-body-glue: the BRACKET counterpart of
	 * `collectBlockCtorPatternsByLeftCurly` — every `[ … ]` block ctor of
	 * `bodyTypePath`, as `case` patterns. Unsplit, because the `leftCurly`
	 * knob has no bracket sibling: a `[` body has exactly one placement, glued
	 * to the head, and the FLAG decides whether it is taken at all.
	 */
	private function collectBracketBlockCtorPatterns(bodyTypePath: String): Array<Expr> {
		final rule: Null<ShapeNode> = _shape.rules[bodyTypePath];
		return rule == null || rule.kind != Alt ? [] : [
			for (branch in rule.children) if (isBracketBlockCtorBranch(branch)) branchCtorPattern(bodyTypePath, branch)
		];
	}

	/**
	 * omega-bracket-body-glue: the runtime test that substitutes `Same` for the
	 * resolved policy — `opt.<flagName>` AND the body's runtime ctor is one of
	 * the body type's `[ … ]` block ctors. Null when the field carries no
	 * `@:fmt(bracketBodyGlueIfFlag(...))`, or when the body type has no bracket
	 * block ctor at all, so every other grammar and every other field keep their
	 * bytes.
	 *
	 * One core for all THREE seams the knob owns — the body placement
	 * (`bodyPolicyWrap`), the branch terminator (`semicolonBeforeSiblingWrap`) and
	 * the pre-`else` gap (`beforeKwSeparator`) — so a grammar that opts one field
	 * in cannot get a different answer from another. The last two are the CLOSE
	 * side of the hug: a `[` glued to its branch head is only half a shape while
	 * the matching `]` is left alone on its line by a `;` the source wrote and a
	 * source-preserving `Keep` gap.
	 */
	private function buildBracketBodyGlueTest(args: Null<Array<String>>, bodyTypePath: Null<String>, bodyValueExpr: Expr): Null<Expr> {
		if (args == null || bodyTypePath == null) return null;
		if (args.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt($BRACKET_BODY_GLUE) requires 1 string arg (flagName), got ${args.length} args', Context.currentPos()
			);
		final patterns: Array<Expr> = collectBracketBlockCtorPatterns(bodyTypePath);
		if (patterns.length == 0) return null;
		final flagAccess: Expr = optFieldAccess(args[0]);
		final ctorTest: Expr = {
			expr: ESwitch(bodyValueExpr, [{ values: patterns, expr: macro true, guard: null }], macro false),
			pos: Context.currentPos()
		};
		return macro $flagAccess && $ctorTest;
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
		if (TriviaPairAltCtor.isAltCloseTrailingBranch(branch)) {
			extras++;
			if (branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse')) extras++;
		}
		if (TriviaPairAltCtor.isAltTrailOptBranch(branch)) extras++;
		if (TriviaPairAltCtor.isCaptureSourceBranch(branch)) extras++;
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
	 * Trivia-mode extra positional args a paired Alt ctor carries beyond
	 * its declared children. The per-slot inventory and push-order
	 * documentation live with the formula in
	 * `TriviaTypeSynth.extraAltArgs`, next to the `buildEnumCtor` blocks
	 * it mirrors; the writer reads specific slots via `argNames[<i>]` /
	 * `altSlotAccess` (see the per-slot ω-comments there). Plain mode
	 * keeps the declared arity.
	 */
	private function branchExtraArgs(branch: ShapeNode): Int {
		return _ctx.trivia ? TriviaPairAltCtor.extraAltArgs(branch) : 0;
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
		final hasOrphan: Bool = TriviaPairAltCtor.isAltCloseTrailingBranch(branch) && branch.readMetaString(':lead') != null
			&& !branch.hasMeta(':tryparse');
		final trailCloseAccess: Null<Expr> = TriviaPairAltCtor.isAltCloseTrailingBranch(branch) ? macro $i{argNames[1]} : null;
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
	@:access(anyparse.macro.WriterBodyPolicyLowering)
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
			final wrapOutput: Expr = WriterBodyPolicyLowering.bodyPolicyWrap(_bodyPolicy, {
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
	@:access(anyparse.macro.WriterBodyPolicyLowering)
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
		parts.push(WriterBodyPolicyLowering.bodyPolicyWrap(_bodyPolicy, {
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
			strictFitLine: child.fmtHasFlag(STRICT_FIT_LINE_BODY),
			bracketBodyGlueArgs: child.fmtReadStringArgs(BRACKET_BODY_GLUE),
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
	@:access(anyparse.macro.WriterBodyPolicyLowering)
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
			optParts.push(WriterBodyPolicyLowering.bodyPolicyWrap(_bodyPolicy, {
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
				strictFitLine: child.fmtHasFlag(STRICT_FIT_LINE_BODY),
				bracketBodyGlueArgs: child.fmtReadStringArgs(BRACKET_BODY_GLUE),
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
	@:access(anyparse.macro.WriterBodyPolicyLowering)
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
		optParts.push(WriterBodyPolicyLowering.bodyPolicyWrap(_bodyPolicy, {
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
			strictFitLine: child.fmtHasFlag(STRICT_FIT_LINE_BODY),
			bracketBodyGlueArgs: child.fmtReadStringArgs(BRACKET_BODY_GLUE),
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
	 * Build the mandatory-Ref body field's runtime `writeCall` Expr. Reads the
	 * opt-fanout flags (`propagateExprPosition` / `propagateAnonFnContext` /
	 * `propagateTypedefContext` / `switchSubjectNoWrap` / `propagateValueIfBranch`
	 * / `setBoolFlagFromStarCtor`) to assemble the descendant writer's `opt`
	 * argument, then layers `@:fmt(sharpCondParensInside)` and the
	 * `@:fmt(indentValueIfCtor)` additive-Nest wrap (skipped when a same-field
	 * `@:fmt(bodyPolicy)` routes it through the subtractive channel instead).
	 *
	 */
	@:access(anyparse.macro.WriterArrowValueIfLowering)
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
			e = WriterArrowValueIfLowering.arrowValueIfBlockOpt(child, e);
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
		final emit: Expr = semicolonBeforeSiblingWrap(child, trailOptText, fieldAccess, sourcePresent) ?? sourcePresent;
		parts.push(valueBraceSymmetryTrailDrop(_braceSym, child, fieldAccess, emit));
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
		if (siblingAccess == null) return null;
		final policyDispatch: Expr = macro switch opt.semicolonBeforeElse {
			case anyparse.format.OptionalSemicolon.Never:
				_sbeSibling ? _de() : $sourcePresent;
			case anyparse.format.OptionalSemicolon.Always:
				_sbeSibling ? _dt($v{trailOptText}) : $sourcePresent;
			case _:
				$sourcePresent;
		};
		// omega-bracket-body-glue CLOSE side: a branch value the knob hugs to its head
		// (`if (c) [`) has to close the same way (`] else`), and `];` cannot cuddle. So
		// when the glue fires AND a sibling follows, the slot is dropped whatever
		// `semicolonBeforeElse` says — the knob is the narrower, explicit statement.
		final glueTest: Null<Expr> = buildBracketBodyGlueTest(
			child.fmtReadStringArgs(BRACKET_BODY_GLUE), child.annotations[AnnotationKeys.BASE_REF], fieldAccess
		);
		final emit: Expr = glueTest == null ? policyDispatch : macro (_sbeSibling && $glueTest ? _de() : $policyDispatch);
		return macro {
			final _sbeSibling: Bool = $siblingAccess != null;
			$emit;
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
		final elseChainSuppressExpr: Expr = buildElseChainSuppressExpr(_braceSym, node, child, fieldAccess);
		final dropElseBraces: Bool = _ctx.trivia && child.fmtHasFlag('dropSingleStmtBraces');
		final thenSiblingKeepsExpr: Expr = dropElseBraces ? buildThenSiblingKeepsProbe(_braceSym, node, typePath) : macro false;
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
			: valueBraceSymmetryWrap(_braceSym, child, fieldAccess);
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
		final deBraced = deBraceBodyAccess(_braceSym, child, fieldAccess, elseFieldName);
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
	 * The `opt` argument expression for an optional-Ref field's descendant writer: the
	 * opt-fanout wraps composed in declaration order, the `arrowValueIfBlockOpt` step,
	 * the `propagateElseIfBranch` runtime-ctor switch, and the else-chain suppress
	 * wrap.
	 */
	@:access(anyparse.macro.WriterArrowValueIfLowering)
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
		e = WriterArrowValueIfLowering.arrowValueIfBlockOpt(child, e);
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
		return wrapElseChainSuppress(_braceSym, e, child, refName, elseChainSuppressExpr);
	}

	/** `AstPredsT.<name>(<args>)` — trivia-family predicate call for the static trivia emit helpers. */
	private static function astPredCallT(name: String, args: Array<Expr>): Expr {
		if (_predRootStatic == '')
			Context.fatalError('WriterLowering: predicate mirrors not initialised (astPredCallT before generate())', Context.currentPos());
		return AstPredLowering.predCallExpr(_predRootStatic, true, false, name, args);
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
	?elseSwitchArgs: Null<Array<String>>,
	// omega-strict-fitline-body: true for a body field carrying
	// `@:fmt(strictFitLineBody)` (`HxForExpr.body` / `HxForReif.body`). Its
	// `FitLine` layout then answers for the WHOLE body rather than for the
	// body's FIRST line: a body that renders flat stays on the head line while
	// it fits, and a body that cannot render flat goes to the next line one
	// indent deeper instead of gluing its first line to the head. That is the
	// `refuseGlue` arm of `BodyFit.fitLineLayout`, reached here by a field flag
	// rather than by the case-body caller's control-flow verdict. False
	// everywhere else -> byte-inert.
	?strictFitLine: Bool,
	// omega-bracket-body-glue: the runtime flag name from
	// `@:fmt(bracketBodyGlueIfFlag('<flagName>'))` on a body field
	// (`HxIfExpr.thenBranch` / `elseBranch`). When `opt.<flagName>` is set and
	// the body's runtime ctor is one of the body type's BRACKET block ctors
	// (`@:lead('[')` + `@:trail` + a single `Star`, i.e. `HxExpr.ArrayExpr` —
	// an array literal AND an array comprehension), the resolved policy is
	// substituted with `Same`, so the `[` hugs the branch head exactly as a
	// `{` block body already does through the curly block-ctor arm. Folded
	// into the policy SELECTOR rather than added as another outer arm for the
	// JVM method-size reason `buildBodyCoreWrap` records. Null -> byte-inert.
	?bracketBodyGlueArgs: Null<Array<String>>
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
 * Output of `WriterCascadeLowering.buildCascadeEmit` — six Exprs ready to
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
