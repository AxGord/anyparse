package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.macro.WriterRefFieldLowering.*;
import anyparse.macro.WriterStarEmitLowering.*;
import anyparse.macro.WriterFieldSepLowering.*;
import anyparse.macro.WriterCtorPatternLowering.*;
import anyparse.macro.WriterCondWrapLowering.*;
import anyparse.macro.WriterBraceSymmetryLowering.*;
import anyparse.macro.PrattMeta.*;
import anyparse.macro.WriterBlankLowering.*;
import anyparse.macro.WriterPolicyLowering.*;
import anyparse.macro.WriterLoweringSupport.*;
import anyparse.macro.WriterChainLowering.*;
import anyparse.macro.MacroNames.*;

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
 * The writer lowering is SEVERAL modules, split five ways.
 *
 * SEVEN are LAYERS, one responsibility each - `WriterLoweringSupport` (the
 * shared field-access / name / `@:fmt`-argument vocabulary),
 * `WriterPolicyLowering` (the `hxformat.json` policy separators),
 * `WriterCascadeLowering` (the `@:fmt(blankLines*)` cascade),
 * `WriterChainLowering` (`@:fmt(methodChain)`), `WriterBlankLowering`
 * (the shared source-fidelity probes), `WriterCtorPatternLowering` (what
 * the grammar says about a referenced rule's constructors) and
 * `WriterFieldSepLowering` (the gap between a field and the sibling before
 * it). Their members are reached UNQUALIFIED from here - a wildcard import
 * plus the class-level `@:access` - which is what let the first five move
 * without touching a call site, and is why they stayed private. The last
 * two read build state, so they take a bundle as their first argument like
 * the families below; what makes them LAYERS rather than families is the
 * inbound side - every writer shape family calls into both, and five ctx
 * bundles were already exporting members of `WriterCtorPatternLowering` as
 * bound closures before it had a name.
 *
 * FOUR carry a trivia Star emit family each - `TriviaTryparseLowering`,
 * `TriviaEofLowering`, `TriviaSepLowering` and `TriviaBlockLowering`. Each
 * is entered from one or two members of `WriterStarEmitLowering` under
 * `@:access`, calls back into the shared lowering utilities
 * (`optFieldAccess`, `astPredCallT`, `buildCascadeEmit`,
 * `blankBefore2ExtrasExpr`, ...) the same way, and types its parameters
 * with this module's sub-module typedefs, which stayed behind - which is
 * why the fifty-four typedefs below the class did not travel with the
 * families that use them.
 *
 * EIGHT carry a SHAPE FAMILY each - one region of this module's call graph,
 * moved whole: `WriterPrattLowering` (`@:ternary` / `@:infix` / `@:prefix`
 * / `@:postfix` branches), `WriterKwRefLowering` (the keyword-plus-`Ref`
 * enum branches), `WriterBodyPolicyLowering` (`@:fmt(bodyPolicy)` and its
 * five layouts), `WriterArrowValueIfLowering`
 * (`@:fmt(arrowValueIfReflow)`), `WriterCtorBlankLowering` (the
 * `@:fmt(blankLines*)` INFO readers), `WriterTriviaStarDispatch` (the
 * close-peek trivia Star dispatch), `WriterStarEmitLowering` (BOTH writer
 * halves of the Star fork) and `WriterRefFieldLowering` (what a struct
 * field that is a `Ref` emits). These differ from the layers above in one
 * way that matters: their members were INSTANCE methods here, so the
 * extraction had to hand each family the build state explicitly. Each got
 * a ctx-bundle typedef of its own, built once in the constructor
 * (`_pratt`, `_kwRef`, `_bodyPolicy`, `_arrowValueIf`, `_ctorBlank`,
 * `_triviaStar`, `_starEmit`, `_refField`) and passed as the first
 * argument; the bundle IS the family's dependency surface, so widening one
 * is a visible edit here.
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
 * The LAST split - `WriterCtorPatternLowering`, `WriterFieldSepLowering`,
 * `WriterStarEmitLowering`, `WriterRefFieldLowering` - is the one that
 * cleared the caps, 112 members / 5869 lines down to 47 / 1508, and it
 * turned on rereading an entanglement rather than on new code motion. S117
 * measured that seven members Ref-field reached lived in the Seq-field
 * region and priced the two families as one joint extraction. The edges
 * were real; the reading was not. Judged by what they READ, none of the
 * seven is a Seq-field member: four are separator builders answering "what
 * `Doc` goes BETWEEN two emits", two read only `shape.rules` and answer
 * "which Alt branches match this shape predicate", and the seventh
 * (`beforeTrailSlotAccess`) is a plain Ref-field member that landed in a
 * Seq-field bucket only because its two callers sit in two different Ref
 * sub-families whose nearest common dominator is `lowerStruct`. Name the
 * two LAYERS and the entanglement is gone rather than carried:
 * `WriterRefFieldLowering` reaches nothing in the Seq walker at all,
 * `lowerStruct` calls in at four sites, and its bundle holds neither
 * `_shape` nor `_formatInfo`. Three helpers that read as shared
 * (`buildBodyPolicyForCtorChain`, `buildBoolFlagRawWriteCall`,
 * `buildLeftCurlySepExpr`) had both their callers inside the family and
 * came along; `blockEndedPredCheck` and `arrayBracketInsidePolicySpace`
 * did the same on the Star side.
 *
 * That the move is byte-inert is not an inference. This module is
 * `#if macro`, so nothing here reaches a JS target's output - only the
 * writer it GENERATES does. A build of the moved tree hashes into the same
 * four-md5 float set an unmoved tree produces, which is the same `cmp`
 * proof the purity moves had.
 *
 * ⚠️ Star emission FORKS across FOUR sites —
 * `StarFieldLowering.emitStarFieldSteps` and the `lowerStar*Branch` leaves
 * beside it on the parse side (`Lowering.lowerEnumBranch`'s Case 4 is the
 * dispatch between those two, not a fifth site), `emitWriterStarField` and
 * `lowerEnumStar`, both now in `WriterStarEmitLowering`. They moved
 * TOGETHER and that is the whole condition on moving them: an extraction
 * taking one and leaving the other would put the pair in two files with
 * nothing naming the other half, which is why S117 refused to take the
 * Star-field region alone. `WriterStarPadLowering` holds plain-Star LEAF
 * emitters taken out from under `emitWriterStarField`; none of them is
 * reachable from `lowerEnumStar` (measured on the call graph), so neither
 * fork half was separated from its twin there either.
 *
 * Generated code references `_dt`, `_dc`, `_dhl`, `_de` etc. — thin
 * wrappers over `Doc` constructors emitted by `WriterCodegen` on the
 * same class. This avoids direct enum constructor calls in `macro {}`
 * blocks, which trigger macro-time type checking.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterBraceSymmetryLowering, anyparse.macro.WriterCascadeLowering,
	anyparse.macro.WriterCtorPatternLowering, anyparse.macro.WriterFieldSepLowering, anyparse.macro.WriterRefFieldLowering,
	anyparse.macro.WriterStarEmitLowering, anyparse.macro.WriterChainLowering, anyparse.macro.WriterCondWrapLowering,
	anyparse.macro.WriterLoweringSupport, anyparse.macro.WriterPolicyLowering, anyparse.macro.WriterRefLeadLowering,
	anyparse.macro.WriterStarPadLowering, anyparse.macro.WriterTriviaSlotLowering)
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
	 * (synthesise the slot) and `StructSeqLowering.computeBeforeSlots` (capture it), so a
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
	 * The ctor-pattern lookups' ctx bundle — see `WriterCtorPatternLowering`.
	 *
	 * Built FIRST: five of the bundles below hand one of those lookups to a
	 * sibling module as a bound closure, so they read this field.
	 */
	private final _ctorPat: anyparse.macro.WriterCtorPatternLowering.CtorPatternCtx;

	/** The Ref-field family's ctx bundle — see `WriterRefFieldLowering`. */
	private final _refField: anyparse.macro.WriterRefFieldLowering.RefFieldCtx;

	/** Both Star forks' ctx bundle — see `WriterStarEmitLowering`. */
	private final _starEmit: anyparse.macro.WriterStarEmitLowering.StarEmitCtx;

	/** The field-separator layer's ctx bundle — see `WriterFieldSepLowering`. */
	private final _fieldSep: anyparse.macro.WriterFieldSepLowering.FieldSepCtx;

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
		_ctorPat = {
			shape: shape,
			isTriviaBearing: isTriviaBearing,
			ruleCtorPath: ruleCtorPath
		};
		_fieldSep = {
			ctx: ctx,
			ctorPat: _ctorPat,
			isTriviaBearing: isTriviaBearing,
			writeFnFor: writeFnFor
		};
		_pratt = {
			shape: shape,
			ctx: ctx,
			ruleValueCT: ruleValueCT,
			writeFnFor: writeFnFor
		};
		_bodyPolicy = {
			shape: shape,
			ctx: ctx,
			branchCtorPattern: branchCtorPattern.bind(_ctorPat),
			buildBracketBodyGlueTest: buildBracketBodyGlueTest.bind(_ctorPat),
			findCtorPattern: findCtorPattern.bind(_ctorPat),
			foldSsbTrailingComment: foldSsbTrailingComment
		};
		_ctorBlank = { shape: shape, branchSynthExtraArity: branchSynthExtraArity.bind(_ctorPat) };
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
			branchSynthExtraArity: branchSynthExtraArity.bind(_ctorPat)
		};
		_braceSym = {
			shape: shape,
			ctx: ctx,
			findCtorPattern: findCtorPattern.bind(_ctorPat),
			isTriviaBearing: isTriviaBearing,
			ruleCtorPath: ruleCtorPath
		};
		_refField = {
			ctx: ctx,
			ctorPat: _ctorPat,
			fieldSep: _fieldSep,
			bodyPolicy: _bodyPolicy,
			braceSym: _braceSym,
			isTightLead: isTightLead,
			isTriviaBearing: isTriviaBearing,
			writeFnFor: writeFnFor
		};
		_starEmit = {
			shape: shape,
			formatInfo: formatInfo,
			ctx: ctx,
			ctorPat: _ctorPat,
			fieldSep: _fieldSep,
			braceSym: _braceSym,
			ctorBlank: _ctorBlank,
			triviaStar: _triviaStar,
			buildKeepBlankAfterCtorGate: buildKeepBlankAfterCtorGate,
			isSpacedLead: isSpacedLead,
			isTriviaBearing: isTriviaBearing,
			mapWrapFor: mapWrapFor,
			ruleCtorPath: ruleCtorPath,
			writeFnFor: writeFnFor
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
			return lowerEnumStar(_starEmit, branch, typePath, writeFnName, hasPratt, argNames);

		// ---- Case 3: single-arg Ref ----
		if (litList == null && children.length == 1 && children[0].kind == Ref) return WriterKwRefLowering.lowerKwRefBranch(_kwRef, c);

		Context.fatalError('WriterLowering: unsupported enum branch shape for ${simpleName(typePath)}', Context.currentPos());
		throw 'unreachable';
	}

	// -------- struct rule --------

	/**
	 * Mirror of `StructSeqLowering.shouldLowerByName` for the writer side. When
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
					_starEmit, child, parts, node, typePath, isFirstField, isRaw, stalePrevBareRefBody, prevTrailFieldName, kwLead,
					fieldName, prevBodyField, prevPadTrailing, fieldAccess, prevAnyStarNonEmpty, multiVarMoreField, isOptional,
					prevFieldAlwaysEmits
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
				_refField, child, parts, kwLead, leadText, isOptional, isFirstField, isRaw, prevBodyField, typePath, prevPadTrailing,
				hasCondWrap, hasCondWrapEnd, prevAnyStarNonEmpty, fieldAccess
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
					// `StructSeqLowering.computeBeforeSlots` exactly, because those three decide
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
							_fieldSep, child, fieldName, typePath, prevAnyStarNonEmpty, prevPadTrailing,
							buildKeepBlankAfterCtorGate(child, node, typePath)
						)
						: null;
					thisPadTrailing = emitOptionalRefField(
						_refField, child, parts, node, typePath, fieldName, fieldAccess, kwLead, leadText, trailText, trailOptText,
						bodyPolicyFlag, bodyPolicyExprFlag, hasElseIf, elseFieldName, prevBodyField, prevPadTrailing,
						hasStructFieldTrailOptSlot, structTrailOptAccess, prevTrailFieldName, optBareSep
					);

				case Ref:
					final mandResult = emitMandatoryRefField(
						_refField, child, parts, typePath, fieldAccess, fieldName, bodyPolicyFlag, bodyPolicyExprFlag, kwLead, leadText,
						isRaw, isFirstField, hasElseIf, elseFieldName, fallbackFlag, hasCondWrap, condWrapArgs, spanInfo != null,
						trailText, prevTrailFieldName, prevAnyStarNonEmpty, prevPadTrailing, condFitGroupConsumer || inConstructFitGroup
					);
					justWrappedBody = mandResult.justWrappedBody;
					prevBareRefBody = mandResult.prevBareRefBody;

				case _:
					Context.fatalError('WriterLowering: struct field kind ${child.kind} not supported', Context.currentPos());
			}

			// Trail + per-field finalize (accumulator fold) — see finalizeNonStarField.
			final finalizeResult = finalizeNonStarField(
				_refField, child, parts, node, typePath, fieldName, fieldAccess, isOptional, trailText, trailOptText, hasCondWrap,
				hasCondWrapEnd, hasStructFieldTrailOptSlot, structTrailOptAccess, thisPadTrailing, prevPadTrailing, justWrappedBody,
				spanInfo, spanStartPartsIdx
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
		final pattern: Null<Expr> = findCtorPattern(_ctorPat, elemRefName, ctorName);
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
 *
 * `headGlue` is the runtime Bool that says the `elseSwitch` knob glued this
 * body to its own head, so it closes in that head's column and the following
 * keyword may cuddle the close exactly as it cuddles a block's. Built where
 * the body is emitted, from that field's OWN meta and minus the captured
 * comment that declines the glue - the gap must never infer it from the
 * keyword field's meta, which says nothing about what the body did. Null on
 * every path with no such knob.
 */
typedef PrevBodyInfo = {
	access: Expr,
	typePath: String,
	?headGlue: Null<Expr>
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
	// `@:fmt(elseSwitch('<optField>', '<ctor>'…))` on a BRANCH body field - the
	// `KeywordPlacement` knob field first, then one or more body ctors that
	// spell a keyword-headed `switch` branch (`HxIfStmt` names both the
	// parenthesised and the bare `switch` statement ctor, on `thenBody` and
	// `elseBody` alike - the user's rule is that the two halves of one
	// `if`/`else` are laid out the same way). The core macro
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

	/**
	 * ω-case-sibling-symmetry: `final _csW: Int = …;` widest-sibling
	 * pre-pass, or `macro -1` when the Star has no `caseSiblingSymmetry` meta.
	 */
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
 * the name has nothing to pick. `isMapLiteralExpr` is a spliced `Expr` rather than a predicate name
 * because the class it calls depends on the build (`AstPreds` plain, `AstPredsT` trivia), which only the
 * lowering that owns `_shape` and `_ctx` can resolve — `WriterLowering.mapWrapFor` builds both halves.
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

	/**
	 * Typed nested-conditional element probe fn-ref (`AstPredsT.elementIsConditional_<ElemRule>`),
	 * or null when the format has no generated predicates.
	 */
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
