package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import anyparse.macro.PrattPostfixLowering.PrattPostfixCtx;
import anyparse.macro.StructSeqLowering.StructSeqCtx;
import anyparse.macro.TerminalParseLowering.TerminalCtx;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.macro.StarFieldLowering.*;
import anyparse.macro.PrattPostfixLowering.*;
import anyparse.macro.StructSeqLowering.*;
import anyparse.macro.TerminalParseLowering.*;
import anyparse.macro.SpanArgLowering.*;
import anyparse.macro.KwBranchLowering.*;
import anyparse.macro.PrattMeta.*;
import anyparse.macro.ParseDispatchLowering.*;
import anyparse.macro.MacroNames.*;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3 of the macro pipeline — lowering.
 *
 * Walks the shape tree produced by `ShapeBuilder` (after the strategy
 * annotation pass has written the `lit.*`, `re.*`, `skip.*` slots on
 * each node) and emits one `GeneratedRule` per top-level type in the
 * grammar. Each rule's body uses unqualified helper names (`skipWs`,
 * `matchLit`, `expectLit`, `parseXxx`) that Codegen injects into the
 * same class, plus `$p{...}` expressions for cross-package type and
 * constructor references.
 *
 * Phase 2 ships three rule shapes: enum Alt rules (construct a named
 * enum constructor per branch), typedef Seq rules (build an anonymous
 * struct literal), and Terminal rules (run an `EReg` and decode the
 * matched slice). Structural CoreIR primitives (`Lit`, `Re`, `Seq`,
 * `Alt`, `Star`, `Opt`, `Ref`, `Empty`) are used to describe each rule
 * conceptually; the emitter produces the concrete Haxe expression
 * directly rather than round-tripping through a separate `CoreIR → Expr` serializer, which would double the code with no observable
 * benefit until Phase 3 adds more primitive variants.
 *
 * Thirteen sibling `#if macro` modules carry one responsibility each
 * out of this pass. Four analyse or name: `ParseDispatchLowering` (the whole
 * LL(1) first-token analysis behind the branch guards - `BranchShape`,
 * `BranchFirstToken` and the byte-set algebra they compile to),
 * `BinaryParseLowering` (the `@:binary` field decode emit),
 * `TriviaSlotNames` (the generated parser's trivia-slot local-name
 * vocabulary) and `PrattMeta` (the operator annotations, shared with
 * `WriterLowering`, which used to carry its own copy). Five carry emit
 * leaves - every member a pure function of its arguments, reading
 * neither `_shape`, `_formatInfo` nor `_ctx`: `SpanArgLowering` (where a
 * `new Span(...)` argument lands in a finished body), `OperatorLoopLowering`
 * (what a Pratt / postfix loop emits on its no-match paths),
 * `StarLoopLowering` (one repetition-loop iteration body and its
 * close detection), `KwBranchLowering` (the Alt branches whose head is a
 * keyword or a literal) and `StructFieldTrailLowering` (what validates
 * and surrounds ONE struct field). Their members are reached UNQUALIFIED
 * from here through a wildcard import plus the class-level `@:access`, so
 * the split rewrote no call site.
 *
 * Four MORE carry a rule SHAPE each, and they are a different axis: their
 * members read instance state, so each takes a ctx bundle built once in the
 * constructor below rather than moving for free. `TerminalParseLowering`
 * (the EReg-and-decode shape), `StructSeqLowering` (the typedef Seq walk and
 * its per-field emit), `StarFieldLowering` (the repetition emitters under
 * it, plus the enum-ctor Star shape leaves) and `PrattPostfixLowering` (the
 * two operator-precedence loops). A bundle carries the fields its family
 * reads plus the naming vocabulary that stayed here (`parseFnName`,
 * `isTriviaBearing`, `isSpanBearing`, `ruleReturnCT`, `ruleCtorPath`,
 * `stashNewlineClearExpr`, `buildBlockEndedPredicateCall`) as bound
 * closures, so the bundle IS that family's dependency surface.
 *
 * The four-site Star+sep audit therefore reads as ONE file and not two:
 * `emitStarFieldSteps` (the struct-field half) and the five
 * `lowerStar*Branch` shape leaves of the enum-ctor path both live in
 * `StarFieldLowering`. What stays HERE is `lowerEnumBranch`'s Case 4, the
 * dispatch that chooses between them.
 */
@:access(anyparse.macro.BinaryParseLowering, anyparse.macro.KwBranchLowering, anyparse.macro.OperatorLoopLowering,
	anyparse.macro.ParseDispatchLowering, anyparse.macro.PrattPostfixLowering, anyparse.macro.SpanArgLowering,
	anyparse.macro.StarFieldLowering, anyparse.macro.StarLoopLowering, anyparse.macro.StructFieldTrailLowering,
	anyparse.macro.StructSeqLowering, anyparse.macro.TerminalParseLowering, anyparse.macro.TriviaSlotNames)
class Lowering {

	/**
	 * Names of the three locals the Alt first-token dispatch prologue
	 * emits into the generated parse function. `lowerEnum` DECLARES them
	 * and `branchGuardExpr` READS two of them, in different methods and
	 * from different `macro` blocks, so the shared spelling is pinned here
	 * rather than duplicated as bare identifiers on both sides.
	 *
	 * Underscore-prefixed to match every other generated local
	 * (`_savedPos`, `_raw`, `_items`) and chosen not to collide with any
	 * of them.
	 */
	private static inline final GUARD_SAVED_LOCAL: String = '_gSaved';

	/** Char code at the dispatch position — the `FirstLit` guard's subject. */
	private static inline final GUARD_BYTE_LOCAL: String = '_gC0';

	/** Maximal word at the dispatch position — the `FirstKw` guard's subject. */
	private static inline final GUARD_WORD_LOCAL: String = '_gW';

	/**
	 * Names of the two locals a `@:tryparse` Star call-site gate emits.
	 * Deliberately distinct from the `_gC0` / `_gW` pair above: a Star
	 * loop lives INSIDE an Alt branch trial, so the enclosing rule's
	 * dispatch prologue locals are in scope at the loop and reusing
	 * their names would shadow them. Also distinct from every local the
	 * loops themselves declare (`_savedPos`, `_lead`, `_leadStart`,
	 * `_savedPending`, `_afterTriviaPos`, `_node`, `_e`).
	 */
	private static inline final STAR_GATE_BYTE_LOCAL: String = '_eC0';

	/** Maximal word at the Star element position — the `FirstKw` gate's subject. */
	private static inline final STAR_GATE_WORD_LOCAL: String = '_eW';

	/**
	 * Char code at a `@:re` Terminal's own entry position — the subject of
	 * the multi-code first-byte reject `lowerTerminal` emits, and the name
	 * `firstByteRejectCodes` reads that reject back through.
	 *
	 * Distinct from `_gC0` / `_eC0` because a terminal function is a
	 * SEPARATE function from the Alt or Star that guards its call: nothing
	 * is in scope from either, and giving it its own name keeps the three
	 * readers from ever matching each other's shape.
	 */
	private static inline final TERMINAL_BYTE_LOCAL: String = '_tC0';

	/** `DEL` — the one non-printable byte that is not below the space. */
	private static inline final DELETE_BYTE: Int = 127;

	/**
	 * Shape-node annotation recording `shouldLowerByName`'s answer.
	 *
	 * That answer is a FORMAT decision (`_formatInfo.fieldLookup` /
	 * `keySyntax`), so the static first-token classifier cannot ask for
	 * it — `generate` stamps it on every `Seq` rule before any lowering
	 * runs instead. `seqFirstToken` needs it because a by-name struct
	 * matches its fields in ANY order behind the format's own object
	 * syntax: the positional first field says nothing about what the
	 * emitted body opens with.
	 */
	private static inline final BY_NAME_KEY: String = 'lowering.byName';

	/**
	 * `@:fmt` flag that retargets a Ref's parse call to the `${parseFn}Atom`
	 * variant of the sub-rule: the operand binds at ATOM level (prefix and the
	 * whole postfix loop included, infix Pratt excluded), so a trailing binary
	 * operator is left for whatever follows instead of being swallowed.
	 *
	 * Read from THREE places that must not drift: the single-Ref enum-branch
	 * arm (`lowerKwRefBranch`, `HxExpr.CastExpr`), the bare struct-field arm
	 * (`HxCondSpliceOpTerm.operand`), and `refBranchFirstToken`, which answers
	 * `Unknown` for such a branch because `ruleFirstToken` models the ENTRY
	 * function and this flag bypasses it.
	 */
	private static inline final ATOM_OPERAND_FLAG: String = 'atomOperand';

	/**
	 * How many guardable branches an Alt rule needs before the dispatch
	 * prologue repays itself. Read by `lowerEnum` (which acts on it) and
	 * by `dumpDispatch` (which reports it), so the dump can never claim a
	 * dispatch decision the codegen does not make.
	 *
	 * One guardable branch cannot repay the prologue: the single trial it
	 * saves costs about what the peek itself costs. MEASURED, not argued: a
	 * threshold of 1 makes 9 more Alts dispatch and parses 9.3% SLOWER
	 * (356 ms vs 389 ms, calibrated corpus, median of 9 interleaved rounds).
	 */
	private static inline final DISPATCH_MIN_GUARDS: Int = 2;

	private final _eregByRule: Map<String, GeneratedRule.EregSpec> = [];

	/**
	 * One record per `@:tryparse` Star call site the lowering walked,
	 * accumulated as a side effect of `emitStarFieldSteps` exactly as
	 * `_eregByRule` is of `lowerTerminal`. Consumed only by
	 * `dumpDispatch` under `-D anyparse_dispatch_dump`, so the dump can
	 * never claim a gate the codegen did not emit.
	 */
	private final _starGates: Array<{
		rule: Null<String>,
		field: Null<String>,
		elem: String,
		first: BranchFirstToken,
	}> = [];

	private final _shape: ShapeBuilder.ShapeResult;
	private final _formatInfo: FormatReader.FormatInfo;
	private final _ctx: LoweringCtx;

	/**
	 * The build state of the three rule-shape families this pass hands off to,
	 * bundled once each. A bundle carries the fields its family reads plus the
	 * naming vocabulary that stayed here as bound closures, so the bundle IS
	 * that family's dependency surface and widening one is a visible edit in
	 * the constructor below.
	 */
	private final _terminal: TerminalCtx;

	private final _struct: StructSeqCtx;
	private final _pratt: PrattPostfixCtx;

	public function new(shape: ShapeBuilder.ShapeResult, formatInfo: FormatReader.FormatInfo, ctx: LoweringCtx) {
		_shape = shape;
		_formatInfo = formatInfo;
		_ctx = ctx;
		_terminal = { formatInfo: formatInfo, eregByRule: _eregByRule };
		_struct = {
			ctx: ctx,
			shape: shape,
			formatInfo: formatInfo,
			starGates: _starGates,
			buildBlockEndedPredicateCall: buildBlockEndedPredicateCall,
			isSpanBearing: isSpanBearing,
			isTriviaBearing: isTriviaBearing,
			parseFnName: parseFnName,
			ruleReturnCT: ruleReturnCT,
			stashNewlineClearExpr: stashNewlineClearExpr
		};
		_pratt = {
			ctx: ctx,
			parseFnName: parseFnName,
			ruleCtorPath: ruleCtorPath,
			ruleReturnCT: ruleReturnCT,
			stashNewlineClearExpr: stashNewlineClearExpr
		};
	}

	public function generate(): Array<GeneratedRule> {
		final rules: Array<GeneratedRule> = [];
		// Track which generated rules need span instrumentation. With the
		// in-AST `_span` arg mechanism, Alt rules need their ctor build
		// sites rewritten to append the span arg; Seq rules need the
		// `_start` snapshot in scope so their inner ctor builds (none at
		// top level, but Pratt-like rules called from inside Seqs share
		// the convention) compile uniformly. Terminal rules return raw
		// primitives and have no ctor builds — skip them so their bodies
		// stay untouched.
		final spanRuleNames: Map<String, Bool> = [];
		for (node in _shape.rules) if (node.kind == Seq) node.annotations[BY_NAME_KEY] = shouldLowerByName(_struct, node);
		// `parseFnName` is an INSTANCE method (it consults `isSpanBearing`
		// / `isTriviaBearing`), so the inverse map the emitted-body check
		// needs to resolve a leading `parseXxx(ctx)` back to its rule is
		// built here, once, rather than inside the static checker.
		final fnToRule: Map<String, String> = [for (typePath in _shape.rules.keys()) parseFnName(typePath) => typePath];
		for (typePath => node in _shape.rules) {
			final entryFn: String = parseFnName(typePath);
			for (rule in lowerRule(typePath, node)) {
				rules.push(rule);
				if (_ctx.spans && node.kind != Terminal) spanRuleNames[rule.fnName] = true;
				if (rule.fnName == entryFn) checkRuleFirstToken(_shape.rules, fnToRule, typePath, rule);
			}
		}
		#if anyparse_dispatch_dump
		dumpDispatch(_shape.rules, _starGates);
		#end
		if (_ctx.spans) for (rule in rules) if (spanRuleNames.exists(rule.fnName)) rule.body = instrumentSpans(rule.body);
		return rules;
	}

	private function lowerRule(typePath: String, node: ShapeNode): Array<GeneratedRule> {
		final simple: String = simpleName(typePath);
		final fnName: String = parseFnName(typePath);
		final returnCT: ComplexType = ruleReturnCT(typePath);
		// `eregByRule` is populated as a side-effect of `lowerTerminal`, so
		// every branch that builds the body must run before we read back
		// the registered eregs. The loop-vs-atom Pratt split hangs the
		// eregs off the loop rule (which is the public entry point for
		// the enum); the atom sub-rule has none of its own.
		final rules: Array<GeneratedRule> = switch node.kind {
			case Alt if (hasPrattBranch(node) && hasPostfixBranch(node)):
				// Pratt + postfix enum: emit three rules.
				//  * `parseXxx(ctx, ?minPrec = 0)` — the precedence-climbing loop
				//    (public entry, called via the `parse` wrapper).
				//  * `parseXxxAtom(ctx)` — the atom WRAPPER. Calls `parseXxxAtomCore`
				//    to get an underlying atom, then runs `lowerPostfixLoop` around
				//    the result, applying postfix operators left-recursively. Every
				//    caller that wants a "complete atom with any attached postfix"
				//    uses this function — the Pratt loop for left/right operands,
				//    and Case 5 prefix's operand recursion.
				//  * `parseXxxAtomCore(ctx)` — the actual tryBranch chain over
				//    non-operator branches (atoms + prefix). Never called directly
				//    except by `parseXxxAtom`.
				//
				// Prefix's `recurseFnName` targets `parseXxxAtom` (the wrapper),
				// so `-a.b` parses as `Neg(FieldAccess(a, b))`: prefix's operand
				// goes through the wrapper, which applies postfix to `a` before
				// the prefix ctor wraps the result.
				final wrapperFnName: String = '${fnName}Atom';
				final coreFnName: String = '${fnName}AtomCore';
				final loopBody: Expr = lowerPrattLoop(_pratt, node, typePath, simple);
				final wrapperBody: Expr = lowerPostfixLoop(_pratt, node, typePath, simple, coreFnName);
				final coreBody: Expr = lowerEnum(node, typePath, true, wrapperFnName);
				final eregs: Array<GeneratedRule.EregSpec> = collectEregs(_terminal, typePath);
				final loopRule: GeneratedRule = new GeneratedRule(fnName, returnCT, loopBody, eregs, true);
				final wrapperRule: GeneratedRule = new GeneratedRule(wrapperFnName, returnCT, wrapperBody, [], false);
				final coreRule: GeneratedRule = new GeneratedRule(coreFnName, returnCT, coreBody, [], false);
				[loopRule, wrapperRule, coreRule];
			case Alt if (hasPrattBranch(node)):
				// Pratt-enabled enum (no postfix): emit two rules sharing the same return type.
				//  * `parseXxx(ctx, ?minPrec = 0)` — the precedence-climbing loop
				//    (primary public entry; the regular `parse` wrapper calls it).
				//  * `parseXxxAtom(ctx)` — the atoms-only dispatcher covering the
				//    non-infix enum branches through the existing Cases 1–4 of
				//    `lowerEnumBranch`. The Pratt loop calls this for the left
				//    operand, then repeatedly for every right operand as long as
				//    the next peeked operator's precedence meets `minPrec`.
				//
				// The two rules deliberately share a return type but differ in
				// signature: the loop rule takes `?minPrec` so recursion inside
				// the loop can climb levels, whereas external callers
				// (`parseHxVarDecl` → `parseHxExpr(ctx)`) drop the parameter via
				// its default value, keeping every other rule's call sites
				// untouched.
				final atomFnName: String = '${fnName}Atom';
				final loopBody: Expr = lowerPrattLoop(_pratt, node, typePath, simple);
				final atomBody: Expr = lowerEnum(node, typePath, true, atomFnName);
				final eregs: Array<GeneratedRule.EregSpec> = collectEregs(_terminal, typePath);
				final loopRule: GeneratedRule = new GeneratedRule(fnName, returnCT, loopBody, eregs, true);
				final atomRule: GeneratedRule = new GeneratedRule(atomFnName, returnCT, atomBody, [], false);
				[loopRule, atomRule];
			case Alt if (hasPostfixBranch(node)):
				// Postfix-only enum (no Pratt): emit two rules.
				//  * `parseXxx(ctx)` — the atom WRAPPER, also the public entry.
				//    Calls `parseXxxCore` then runs `lowerPostfixLoop` around the
				//    result.
				//  * `parseXxxCore(ctx)` — the atom core (tryBranch chain over
				//    non-postfix branches).
				//
				// Prefix's `recurseFnName` targets `parseXxx` — the wrapper — so
				// any prefix operator's operand flows through postfix application
				// before the prefix ctor wraps it. This branch is not exercised
				// by HxExpr (which has both Pratt and postfix), but keeps the
				// logic general for future postfix-only enums.
				final coreFnName: String = '${fnName}Core';
				final wrapperBody: Expr = lowerPostfixLoop(_pratt, node, typePath, simple, coreFnName);
				final coreBody: Expr = lowerEnum(node, typePath, true, fnName);
				final eregs: Array<GeneratedRule.EregSpec> = collectEregs(_terminal, typePath);
				final wrapperRule: GeneratedRule = new GeneratedRule(fnName, returnCT, wrapperBody, eregs, false);
				final coreRule: GeneratedRule = new GeneratedRule(coreFnName, returnCT, coreBody, [], false);
				[wrapperRule, coreRule];
			case Alt:
				final body: Expr = lowerEnum(node, typePath, false, fnName);
				[new GeneratedRule(fnName, returnCT, body, collectEregs(_terminal, typePath))];
			case Seq:
				final body: Expr = lowerStruct(_struct, node, typePath);
				[new GeneratedRule(fnName, returnCT, body, collectEregs(_terminal, typePath))];
			case Terminal:
				final body: Expr = lowerTerminal(_terminal, node, typePath, simple);
				[new GeneratedRule(fnName, returnCT, body, collectEregs(_terminal, typePath))];
			case _:
				Context.fatalError('Lowering: cannot lower top-level ${node.kind} for $typePath', Context.currentPos());
				throw 'unreachable';
		};
		// `@:raw` on a grammar type suppresses all `skipWs(ctx)` calls in
		// the generated parse function(s) for that rule. Used for string
		// content and other whitespace-sensitive zones where the parser must
		// NOT consume spaces between tokens. The caller's skipWs (in the
		// non-raw parent rule) handles whitespace before the raw rule's
		// entry point; inside the raw rule, every character is significant.
		if (node.hasMeta(':raw') || _formatInfo.isBinary) for (rule in rules) rule.body = stripSkipWs(rule.body);
		return rules;
	}


	/**
	 * Build the blockEnded predicate call on the accumulator's last
	 * element, for `@:sep('text', tailRelax, blockEnded('<predicate>'))`
	 * (Session 6 option b2 — AST-shape adapter). The predicate is
	 * invoked between elements to decide whether the separator is
	 * elidable based on the prior element's AST shape (e.g.
	 * `HxStatement.ExprStmt(ArrayExpr(_))` → `;`-elision;
	 * `HxStatement.BlockStmt(_)` → trivially `;`-elidable).
	 *
	 * For an `astPreds` format the call targets the generated typed
	 * predicate of this build's AST family. The element is passed bare:
	 * every reachable caller sits on a NON-trivia-collecting path (the
	 * trivia-collecting Stars branch off earlier into
	 * `emitTriviaStarFieldSteps` / `lowerTriviaStarBranch`), so the
	 * accumulator never holds `Trivial<…>` wrappers here — if a future
	 * trivia-collecting caller appears, it must unwrap `.node` itself
	 * (the typed predicate makes forgetting that a compile error, not a
	 * silent null). Other formats keep the legacy schema-instance
	 * channel, the sister of `parseGateCall` / `unescapeChar`.
	 */
	private function buildBlockEndedPredicateCall(predicateName: String, accumRef: Expr): Expr {
		final lastElem: Expr = macro $accumRef[$accumRef.length - 1];
		if (_formatInfo.astPreds) return AstPredLowering.predCallExpr(_shape.root, _ctx.trivia, _ctx.spans, predicateName, [lastElem]);
		final fmtParts: Array<String> = _formatInfo.schemaTypePath.split('.');
		return {
			expr: ECall({ expr: EField(macro $p{fmtParts}.instance, predicateName), pos: Context.currentPos() }, [lastElem]),
			pos: Context.currentPos()
		};
	}

	// -------- enum rule --------

	/**
	 * Lower an enum `ShapeNode` into the body of its `parseXxx` function.
	 *
	 * `atomsOnly` controls whether operator-shaped branches are excluded.
	 * When true, both Pratt-annotated (`pratt.prec`) and postfix-annotated
	 * (`postfix.op`) branches are filtered out — those operators are
	 * handled by separate generated rules (`lowerPrattLoop` for Pratt,
	 * `lowerPostfixLoop` for postfix). Prefix branches (`prefix.op`) are
	 * left in, because prefix is an atom-producing form (consumes one
	 * operand and builds a value) that belongs alongside the leaf cases.
	 *
	 * `recurseFnName` is the name of the function whose body `tryBranch`
	 * should target as the recursion point for prefix operands. It is
	 * passed down through `tryBranch` → `lowerEnumBranch` to Case 5
	 * (unary prefix), where a `@:prefix` branch's operand recursion
	 * targets this function. The caller picks a name that yields the
	 * correct binding-tightness:
	 *
	 *  - For a plain enum: the function's own name (`parseXxx`).
	 *  - For a Pratt enum (no postfix): the atom function name
	 *    (`parseXxxAtom`) — NOT the Pratt loop, so `-x * 2` parses as
	 *    `Mul(Neg(x), 2)`.
	 *  - For a Pratt + postfix enum: the atom WRAPPER name
	 *    (`parseXxxAtom`, which is now the postfix-extended wrapper
	 *    around `parseXxxAtomCore`) — so prefix's operand gets postfix
	 *    applied before the prefix ctor wraps it, yielding
	 *    `Neg(FieldAccess(a, b))` for `-a.b`.
	 *  - For a postfix-only enum: the wrapper name (`parseXxx` itself,
	 *    which wraps `parseXxxCore`) — same semantics, prefix's operand
	 *    gets postfix before the prefix ctor wraps it.
	 */
	private function lowerEnum(node: ShapeNode, typePath: String, atomsOnly: Bool, recurseFnName: String): Expr {
		final branches: Array<ShapeNode> = atomsOnly ? [
			for (b in node.children)
				if (
					b.annotations.get(AnnotationKeys.PRATT_PREC) == null && b.annotations.get(AnnotationKeys.POSTFIX_OP) == null
					&& b.annotations.get(AnnotationKeys.TERNARY_OP) == null
				)
					b
		] : node.children;
		// omega-alt-first-token: first-token dispatch guards. Ordered choice
		// is untouched — branches keep their source order, nothing is
		// reordered or grouped. Each GUARDABLE branch's `tryBranch` block is
		// merely wrapped in a cheap test that skips the trial when the token
		// at the current position provably cannot start that branch. This
		// removes the dozens of failed `expectKw` probes every ident-led
		// statement used to pay walking a long Alt.
		// THE SOUNDNESS INVARIANT: a guard may only skip a branch whose
		// trial would deterministically FAIL WITHOUT CONSUMING INPUT at the
		// current position. First-token guards satisfy it — a kw-first
		// branch's `expectKw(kw)` fails iff the word at the position is not
		// `kw` (word-boundary semantics = maximal ident run, exactly what
		// `peekWord` returns), and a lit-first branch's `expectLit(lit)`
		// fails on its first compare iteration when the byte at the position
		// is not `lit`'s first byte. A skipped branch is therefore
		// observationally identical to a failed trial, EXCEPT for
		// `ctx.recordFail` bookkeeping: on MALFORMED input the farthest-fail
		// diagnostic can change in WORDING **and in POSITION**. Wording,
		// because the branches that still run name different expected
		// tokens; position, because if EVERY branch at some offset is
		// guarded away then nothing records there at all and `maxFailPos`
		// falls back to a strictly EARLIER offset — the reported error locus
		// moves, it is not merely relabelled.
		// EXPOSURE is confined to grammars declaring NO comment patterns.
		// Where a format has them, `skipWs` probes each opener with
		// `matchLit` and so records the position ITSELF — before any branch
		// runs, and past the reach of any guard. That is why the Haxe
		// grammar's farthest-fail position and `expected` string are
		// unchanged. A comment-free grammar (the JValue / sexpr / ar /
		// miniblock pilots, depending on what each declares) has no such
		// backstop. This is the one accepted behaviour change; the
		// well-formed language is unaffected in every grammar.
		final firstTokens: Array<BranchFirstToken> = branches.map(branchFirstToken.bind(_shape.rules, []));
		final guards: Array<Null<Expr>> = firstTokens.map(branchGuardExpr.bind(_, GUARD_BYTE_LOCAL, GUARD_WORD_LOCAL));
		var guardCount: Int = 0;
		var needWord: Bool = false;
		var needByte: Bool = false;
		for (first in firstTokens) switch first {
			case FirstKw(_):
				guardCount++;
				needWord = true;
			case FirstLit(_):
				guardCount++;
				needByte = true;
			case Unknown:
		}
		final dispatch: Bool = guardCount >= DISPATCH_MIN_GUARDS;
		// The peek runs ONCE per dispatch and RESTORES `ctx.pos`, so every
		// branch body still starts from the exact original position and does
		// its own `skipWs`.
		// `skipWs` is NOT side-effect-free, and the guards do not need it to
		// be: for any format declaring comment patterns its body probes each
		// opener with `matchLit`, whose miss path calls `ctx.recordFail`.
		// The prologue is safe because that probe is not NEW work — every
		// branch body opens with its own `skipWs`, and `dispatch` implies at
		// least two branches, so the identical probe at the identical
		// position already ran (as branch 1's) before guards existed, and
		// `recordFail` keeps only the deepest position, so repeating it
		// changes nothing.
		// The trivia-capturing variants — `collectTrivia` /
		// `skipWsAndStash` — live in the Star loops and the Pratt operator
		// chain, never at an Alt branch head. No branch reaches one before
		// its first literal, so a guard-skipped branch cannot strand trivia
		// state either.
		// In `@:raw` / binary rules the prologue's `skipWs` is erased by
		// `stripSkipWs` exactly as the branch bodies' are, keeping the peek
		// position aligned with what the branches see. That composition is
		// load-bearing: a prologue that skipped whitespace the branches do
		// NOT skip would peek a later token and could guard away a branch
		// that would have matched.
		final statements: Array<Expr> = [];
		if (dispatch) {
			statements.push(finalLocal(GUARD_SAVED_LOCAL, macro :Int, macro ctx.pos));
			statements.push(macro skipWs(ctx));
			if (needByte) statements.push(finalLocal(GUARD_BYTE_LOCAL, macro :Int, macro ctx.input.charCodeAt(ctx.pos)));
			if (needWord) statements.push(finalLocal(GUARD_WORD_LOCAL, macro :String, macro peekWord(ctx)));
			statements.push(macro ctx.pos = $i{GUARD_SAVED_LOCAL});
		}
		for (i in 0...branches.length) {
			final trial: Expr = tryBranch(branches[i], typePath, recurseFnName);
			final guard: Null<Expr> = dispatch ? guards[i] : null;
			statements.push(if (guard == null)
				trial
			else
				macro if ($guard) $trial);
		}
		statements.push(macro throw anyparse.runtime.ParseError.backtrack);
		return macro $b{statements};
	}


	private function tryBranch(branch: ShapeNode, typePath: String, recurseFnName: String): Expr {
		final body: Expr = lowerEnumBranch(branch, typePath, recurseFnName);
		return macro {
			final _savedPos: Int = ctx.pos;
			try
				$body
			catch (_e: anyparse.runtime.ParseError)
				ctx.pos = _savedPos;
		};
	}

	private function lowerEnumBranch(branch: ShapeNode, typePath: String, recurseFnName: String): Expr {
		final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final ctorPath: Array<String> = ruleCtorPath(typePath, ctor);
		final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
		// The shape decision lives in `branchShape`, shared with
		// `branchFirstToken` so the Alt dispatch guards can never guard on
		// a token this emission does not actually consume first. Each
		// shape's rationale — including why `Prefix` and `StarList` must be
		// decided before `KwRef` — is on the `BranchShape` constructors.
		return switch branchShape(branch) {
			case Prefix(op): lowerPrefixBranch(branch, typePath, ctorRef, recurseFnName, op);
			case KwZeroArg(kw): lowerKwZeroArgBranch(branch, ctorRef, kw);
			case SingleLit(lit): lowerSingleLitBranch(ctorRef, lit);
			case MultiLit(lits): lowerMultiLitBranch(ctorRef, lits);
			case StarList(lead, trail, sep, sepAlt): lowerStarBranch(branch, ctorRef, lead, trail, sep, sepAlt);
			case KwRef(_, _): lowerKwRefBranch(branch, typePath, ctorRef);
			case Unsupported:
				Context.fatalError('Lowering: unsupported enum branch shape for ${simpleName(typePath)}.${ctor}', Context.currentPos());
				throw 'unreachable';
		};
	}

	// -------- struct rule --------
	// -------- terminal rule --------
	// -------- trivia-mode helpers --------

	/**
	 * True when `ctx.trivia` is active AND the rule at `refName` carries
	 * `trivia.bearing=true`. The rule-lookup guard returns false for
	 * non-grammar refs (format primitives the Lowering still expects to
	 * call through their plain `parse*` functions, e.g. `JIntLit` under
	 * `HxFormatConfig`).
	 */
	private function isTriviaBearing(refName: String): Bool {
		if (!_ctx.trivia) return false;
		final node: Null<ShapeNode> = _shape.rules[refName];
		return node != null && node.annotations.get(AnnotationKeys.TRIVIA_BEARING) == true;
	}

	/**
	 * True for every Alt/Seq rule when `ctx.spans=true`. Span synthesis
	 * pairs all non-Terminal rules so the typed AST carries spans on
	 * every enum value (Terminals stay as primitives — no carrier).
	 */
	private function isSpanBearing(refName: String): Bool {
		if (!_ctx.spans) return false;
		final node: Null<ShapeNode> = _shape.rules[refName];
		return node != null && node.kind != Terminal;
	}

	/**
	 * `parse<name>S` when span-bearing, `parse<name>T` when trivia-bearing,
	 * else `parse<name>` — every ref fn-name site goes through this.
	 * Span and trivia modes are mutually exclusive in current consumers
	 * (`HaxeModuleSpanParser` uses `{spans:true}` only; `HaxeModuleTriviaParser`
	 * uses `{trivia:true}` only). Composition is a future slice.
	 */
	private function parseFnName(refName: String): String {
		final simple: String = simpleName(refName);
		return if (isSpanBearing(refName))
			'parse${simple}S'
		else if (isTriviaBearing(refName))
			'parse${simple}T'
		else
			'parse$simple';
	}

	/** Paired `*S` / `*T` ComplexType in the synth module for bearing rules; plain TPath otherwise. */
	private function ruleReturnCT(refName: String): ComplexType {
		final simple: String = simpleName(refName);
		return if (isSpanBearing(refName))
			TPath({
				pack: packOf(refName).concat(['spans']),
				name: 'Pairs',
				sub: '${simple}S',
				params: []
			})
		else if (isTriviaBearing(refName))
			TPath({
				pack: packOf(refName).concat(['trivia']),
				name: 'Pairs',
				sub: '${simple}T',
				params: []
			})
		else
			TPath({ pack: packOf(refName), name: simple, params: [] });
	}

	/** Enum-constructor field-path segments for `toFieldExpr` — routes through the synth module for bearing enums. */
	private function ruleCtorPath(typePath: String, ctor: String): Array<String> {
		final simple: String = simpleName(typePath);
		return if (isSpanBearing(typePath))
			packOf(typePath).concat(['spans', 'Pairs', '${simple}S', ctor])
		else if (isTriviaBearing(typePath))
			packOf(typePath).concat(['trivia', 'Pairs', '${simple}T', ctor])
		else
			packOf(typePath).concat([simple, ctor]);
	}


	/**
	 * ω-stash-nl-operator-commit: drop a stale `pendingTrivia` LINE-BREAK signal
	 * (`newlineBefore` + `blankBefore`) at the point an operator COMMITS. Emits
	 * `{}` outside Trivia mode, where nothing reads the stash.
	 *
	 * The stash is a forward signal: a Pratt / postfix loop that exits on
	 * no-match having eaten a newline records it (`ω-untyped-keep`) so the next
	 * SIBLING's `collectTrivia` still sees the line break the loop consumed. It
	 * describes a boundary — and an operator match right after it proves there
	 * is no boundary there: the newline sits strictly INSIDE this expression,
	 * before the operator. Only a DEEPER loop can have written it (the
	 * committing loop's own `skipWsAndStash` consumes the gap before the
	 * operator without recording it), so nothing legitimate is dropped.
	 *
	 * Left standing, it is drained by whatever calls `collectTrivia` next, which
	 * can be arbitrarily far away — a following `@:trivia` Star element, an
	 * optional-kw field, or the FIRST element of a container the very next
	 * operand opens — and that node reports a source line break its own leading
	 * gap does not have.
	 *
	 * The observable damage is a phantom hardline. A `@:fmt(padTrailing,
	 * captureSourceNewlineAfter)` boundary emits `_dhl()` instead of `_dt(' ')`
	 * on the phantom signal, so `v = #if a X #elseif b c ? d : e #elseif f Y
	 * #end;` — flat on one source line — round-tripped to a DIFFERENT layout on
	 * the second pass than on the first: pass 1 broke the ternary (correct: no
	 * stash yet), pass 2 read its own `?`/`:` line breaks back in, leaked the
	 * signal onto the `#elseif` that followed the ternary, and broke THERE
	 * instead. A writer whose output is not its own fixed point makes every
	 * canonical-gated op (`lint --fix`, `add-member`, …) refuse the file it just
	 * wrote. `blankBefore` travels with `newlineBefore` in both producers and
	 * has its own consumer (a blank line ahead of the drained node), so it is
	 * dropped in the same breath — clearing one alone leaves a
	 * `{blankBefore: true, newlineBefore: false}` state no producer can build.
	 *
	 * TWO OTHER READERS of `newlineBefore` see the flag before this clear can
	 * reach them, and both stay truthful. `chainNlValue` (the
	 * `@:fmt(captureChainNewline)` `&&` / `||` arm) ORs the stash in because a
	 * higher-precedence left operand routinely pre-consumes their gap — so the
	 * infix site pushes this clear only AFTER that read, which is where the
	 * `captureChainNewline` ctors already dropped the flag themselves. The
	 * `#if`-splice same-line gate `gapNewline` in `buildPostfixOpMatchExpr` ORs
	 * it for the same reason; it runs in the postfix loop's MATCH expression,
	 * before any operator of that iteration has committed, and each iteration
	 * re-derives its own gap from a freshly saved `_preWsPos`.
	 *
	 * An OPENING delimiter proves interiority the same way, and the two
	 * trivia-Star open-literal emitters (`lowerTriviaStarBranch`,
	 * `emitTriviaStarFieldSteps`) push this clear right after their own
	 * `expectLit` for exactly that reason: a stash made before `[` or `{`
	 * cannot be the leading gap of the first element INSIDE it.
	 *
	 * Without the barrier, the stash an `@:absentOn` body field leaves behind
	 * for a source newline before the enclosing statement reached element 0,
	 * and `reflowSourceMultiline` broke a flat comprehension bracket open. The
	 * ω₆b `@:optional @:kw` producer below feeds the same channel and is
	 * intercepted the same way, which is deliberate: its own comment describes
	 * a drain by "the sub-rule's first `@:trivia` Star element", and when that
	 * Star carries a `@:lead` the newline was never that element's gap.
	 *
	 * SCOPE, since it is wider than the reported bug: the two emitters serve
	 * every `@:lead` + `@:trivia` Star in the grammar (~20 sites), and three
	 * families move — a comprehension or array bracket (the report), an object
	 * literal or anon type written flat on the line after a break
	 * (`var c =\n\t{k: 1, m: 2}` stayed broken before), and Keep mode, where
	 * `triviaSepPredicateScanExpr` deliberately exempts element 0 from its own
	 * suppression (`!_keepEmit`) — the barrier runs UPSTREAM of that exemption,
	 * so a newline before `[` no longer re-emerges as a break after it while a
	 * genuine in-bracket one still does. Everything else measured byte-
	 * identical: Allman braces, parameter and argument lists, lambda bodies,
	 * case bodies, ternary branches, `#if` regions.
	 *
	 * `blankAfterLeadingComments` is NOT cleared, and that is not the asymmetry
	 * the paragraph above warns about: it describes the gap AFTER the leading
	 * comments, which still travel, so it travels with them.
	 *
	 * NOT covered, both stable fixed points — cosmetic, not canonical-gate
	 * breakers — and both left alone here:
	 *
	 *  - a CLOSING delimiter proves interiority just as an operator does, and
	 *    those commits do not clear (`{k: (foo\n), m: 2}` still breaks before
	 *    `m`);
	 *  - the postfix loop clears at the matched iteration's TAIL, so a stash the
	 *    RECEIVER left is still live while the suffix's own payload parses and a
	 *    container the payload opens can drain it. NARROWED by the barrier
	 *    above, which intercepts every such container that IS a `@:lead` trivia
	 *    Star: `(foo\n)[{k: 1, m: 2}]` broke its index literal on the base
	 *    commit and is flat now, measured on both arms; what stays uncovered is
	 *    a container with no trivia Star of its own. Clearing before `$opChain`
	 *    instead is NOT the fix — `gapNewline` reads the flag inside the match
	 *    expression, and a genuine boundary the receiver stashed (`try f() catch
	 *    (_) {}` then an own-line `#if`) is unrecoverable by the no-match
	 *    scanback, whose `_preWsPos` already sits past the newline. Closing it
	 *    means threading the pre-clear value through every postfix branch builder.
	 */
	private function stashNewlineClearExpr(): Expr {
		final clear: Expr = macro {
			final _stashClr = ctx.pendingTrivia;
			if (_stashClr != null) {
				_stashClr.newlineBefore = false;
				_stashClr.blankBefore = false;
			}
		};
		return _ctx.trivia ? clear : macro {};
	}


	/**
	 * Case 5: unary-prefix branch (`@:prefix("-")`). A ctor with a single
	 * `Ref` child that references the same enum: consume the prefix literal,
	 * recurse into `recurseFnName` (the atom fn for Pratt enums), and build
	 * the ctor around the returned operand.
	 */
	private function lowerPrefixBranch(branch: ShapeNode, typePath: String, ctorRef: Expr, recurseFnName: String, prefixOp: String): Expr {
		final children: Array<ShapeNode> = branch.children;
		if (children.length != 1 || children[0].kind != Ref) {
			Context.fatalError('Lowering: @:prefix branch must have exactly one Ref child (the operand)', Context.currentPos());
		}
		final refName: String = children[0].annotations.get(AnnotationKeys.BASE_REF);
		final enumSimple: String = simpleName(typePath);
		if (simpleName(refName) != enumSimple) {
			Context.fatalError('Lowering: @:prefix operand must reference the same enum ($enumSimple)', Context.currentPos());
		}
		if (endsWithWordChar(prefixOp)) {
			Context.fatalError(
				'Lowering: @:prefix operator must be symbolic (word-like prefix ops not supported yet): "$prefixOp"', Context.currentPos()
			);
		}
		final operandCT: ComplexType = ruleReturnCT(typePath);
		final recurseCall: Expr = {
			expr: ECall(macro $i{recurseFnName}, [macro ctx]),
			pos: Context.currentPos()
		};
		final ctorCall: Expr = { expr: ECall(ctorRef, [macro _operand]), pos: Context.currentPos() };
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{prefixOp});
			skipWs(ctx);
			final _operand: $operandCT = $recurseCall;
			return $ctorCall;
		};
	}

	/**
	 * Case 4 (block-ended @:sep): sep between two elements may be omitted
	 * when the prior element ended with `}`/`;` (byte-check) or a schema
	 * predicate matches; `sepStartsElement` flips the byte-ambiguity policy
	 * so the sep char belongs to the NEXT element. Strictly opt-in via
	 * `lit.sepBlockEnded`.
	 */
	private function lowerStarBlockEndedBranch(
		branch: ShapeNode, leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr,
		ctorCall: Expr, sepCharCode: Int, sepText: String
	): Expr {
		final predicateName: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE];
		final accumRefForPred: Expr = macro _items;
		final predicateCall: Expr = predicateName != null ? buildBlockEndedPredicateCall(predicateName, accumRefForPred) : macro false;
		// sepStartsElement (Session 9 BlockBody Star) — when block-ended is
		// TRUE, the sep byte at pos belongs to the NEXT element, never a
		// separator. Required for grammars where the sep char can ALSO be a
		// valid element body (Haxe `EmptyStmt`). When the flag is absent the
		// default permissive-sep semantics applies (sep-first branch in the
		// loop).
		final sepStartsElement: Bool = branch.annotations[AnnotationKeys.LIT_SEP_STARTS_ELEMENT] == true;
		return sepStartsElement
			? lowerStarBlockEndedSepStarts(
				leadText, trailText, elemCT, elemCall, closeNotNextExpr, ctorCall, sepCharCode, sepText, predicateCall
			)
			: lowerStarBlockEndedSepLast(
				leadText, trailText, elemCT, elemCall, closeNotNextExpr, ctorCall, sepCharCode, sepText, predicateCall
			);
	}

	/**
	 * Case 4 (@:trivia Star): replaces the plain element-push loop with a
	 * collectTrivia -> parseElement -> collectTrailing pipeline that feeds
	 * `Trivial<T>` structs into the accumulator, so leading/trailing
	 * comments and blank-line signals survive round-trip. Supports `@:sep`
	 * alongside `@:trivia` for close-peek Alt branches.
	 */
	private function lowerTriviaStarBranch(
		branch: ShapeNode, ctorRef: Expr, leadText: String, trailText: String, sepText: Null<String>, elemCT: ComplexType, elemCall: Expr,
		closeNextOrEofExpr: Expr
	): Expr {
		final wrappedCT: ComplexType = TPath({
			pack: ['anyparse', 'runtime'],
			name: 'Trivial',
			params: [TPType(elemCT)]
		});
		// ω-close-trailing-alt: synth ctor of close-peek `@:trivia`
		// Alt branches (e.g. `HxStatementT.BlockStmt`) carries an
		// extra positional `closeTrailing:Null<String>` arg captured
		// here by `collectTrailingFull(ctx)` right after the close
		// literal. The Full variant keeps comment delimiters so the
		// writer can round-trip block-vs-line style (ω-trailing-
		// block-style). Plain mode keeps the 1-arg ctor.
		//
		// ω-open-trailing-alt: when the branch carries `@:lead`,
		// append `_openTrail` as a 3rd positional arg. Captured
		// via `collectTrailingFull` right after the open literal
		// (mirror of Seq-struct's `<field>TrailingOpen` slot).
		// Without this, an inline `[ /* foo */ ]` would lose the
		// comment — the loop's terminal `_lead` is dropped on
		// the close-peek break, and same-line comments after `[`
		// don't show up in `collectTrivia`'s newline-anchored
		// scan anyway.
		final hasOpenTrail: Bool = branch.readMetaString(':lead') != null && !branch.hasMeta(':tryparse');
		final ctorArgsTrivia: Array<Expr> = [macro _items, macro _closeTrail];
		if (hasOpenTrail) {
			ctorArgsTrivia.push(macro _openTrail);
			// ω-orphan-trivia-alt: parallel to the Seq-struct
			// trail-orphan capture in `emitTriviaStarFieldSteps`.
			// Captured into mutable locals on the close-peek break
			// (see loop body below) so trivia between the last Star
			// element and the close literal survives round-trip.
			ctorArgsTrivia.push(macro _trailBB);
			ctorArgsTrivia.push(macro _trailLC);
			// ω-arraylit-source-trail-comma: sep+trail+lead+@:trivia
			// branches additionally forward whether the source had a
			// trailing separator before the close literal. The synth
			// ctor's 6th positional `trailPresent:Bool` (gated on
			// `:sep` in `TriviaTypeSynth.buildEnumCtor`) holds the
			// last-iteration `matchLit(sepText)` result captured by
			// `sepMatchExpr` below. Same `:sep` gate keeps the
			// positional count in sync between parser-emit and synth-
			// define for non-sep branches (BlockStmt, BlockExpr).
			if (sepText != null) {
				ctorArgsTrivia.push(macro _trailPresent);
			}
		}
		final ctorCallTrivia: Expr = {
			expr: ECall(ctorRef, ctorArgsTrivia),
			pos: Context.currentPos()
		};
		final sepMatchExpr: Expr = if (sepText != null) {
			// Same horizontal-whitespace-only skip as the struct-field
			// trivia+sep path — avoids `skipWs` consuming the trailing
			// `// comment` before `collectTrailing` runs.
			//
			// ω-arraylit-source-trail-comma: capture matchLit result
			// into `_trailPresent`. After the close-peek loop exits,
			// the local holds the LAST iteration's sep result — `true`
			// iff the source committed to a trailing `,` before the
			// close literal. Forwarded as the 6th positional ctor arg
			// when both `:lead` and `:sep` are present (see ctorArgs
			// build above). Mirror of the struct-Star-side capture at
			// `emitTriviaStarFieldSteps`'s `$i{trailPresentLocal} =
			// matchLit(...)` (Lowering.hx around line 2859).
			//
			// ω-objectlit-source-inter-sep: additionally capture per-
			// iteration into `_sepAfter` for the per-element
			// `Trivial.sepAfter` slot. The writer's trivia-branch sep
			// gate (`TriviaSepLowering.triviaSepStarExpr`) consults this to
			// suppress inter-element seps the source intentionally
			// omitted (lineends/issue_111). For sep-less branches the
			// loop body sets `_sepAfter = true` (always-emit default).
			macro {
				while (ctx.pos < ctx.input.length) {
					final _hwc: Int = ctx.input.charCodeAt(ctx.pos);
					if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code)
						ctx.pos++;
					else
						break;
				}
				_sepAfter = matchLit(ctx, $v{sepText});
				_trailPresent = _sepAfter;
			}
		} else {
			macro {};
		};
		// ω-open-delim-interiority: the open literal proves the elements are
		// INSIDE the bracket, so a stash made before it can no longer be the
		// first element's own leading gap. Same argument `stashNewlineClearExpr`
		// makes for an operator commit; without it a `@:absentOn` body field's
		// pre-peek stash (`function(a, b)\n\treturn [for (k in m) …]`) reaches
		// element 0 and `reflowSourceMultiline` breaks a flat bracket open.
		final openDelimBarrier: Expr = stashNewlineClearExpr();
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			$openDelimBarrier;
			final _openTrail: Null<String> = collectTrailingFull(ctx);
			final _items: Array<$wrappedCT> = [];
			var _trailBB: Bool = false;
			var _trailLC: Array<String> = [];
			// ω-arraylit-source-trail-comma: declared unconditionally to
			// keep the macro body shape stable; only assigned when
			// `sepText != null` (see `sepMatchExpr` above) and only
			// forwarded to the ctor when both `:lead` AND `:sep` apply
			// (see `ctorArgsTrivia` build above). For sep-less branches
			// the var is unused; Haxe does not warn on unused locals.
			var _trailPresent: Bool = false;
			while (true) {
				final _lead = collectTrivia(ctx);
				if ($closeNextOrEofExpr) {
					_trailBB = _lead.blankBefore;
					_trailLC = _lead.leadingComments;
					break;
				}
				final _node: $elemCT = $elemCall;
				// ω-trivia-trailing-before-sep (mirror of
				// emitStarFieldSteps :3339): probe a same-line trailing
				// comment BEFORE the sep-match so `elem /*c*/ , next`
				// shape parses. Without this, the pre-sep horizontal-ws
				// skip stops at `/`, sep-match fails, the next iteration
				// tries to parse `,` as element start → SKIP_PARSE.
				// Captured into the existing `trailingComment` slot via
				// coalescing — the synth wrapper's `trailingBeforeSep`
				// flag records the position so the writer can emit at
				// the source position instead of always after sep.
				final _trailingBeforeSep: Null<String> = collectTrailingFull(ctx);
				var _sepAfter: Bool = true;
				$sepMatchExpr;
				final _trailing: Null<String> = _trailingBeforeSep ?? (_sepAfter ? collectTrailingFull(ctx) : null);
				_items.push({
					blankBefore: _lead.blankBefore,
					blankBefore2: _lead.blankBefore2,
					blankAfterLeadingComments: _lead.blankAfterLeadingComments,
					newlineBefore: _lead.newlineBefore,
					leadingComments: _lead.leadingComments,
					trailingComment: _trailing,
					trailingBeforeSep: _trailingBeforeSep != null,
					sepAfter: _sepAfter,
					// ω-643-leading-block-glue: the last leading comment
					// sat on the same source line as the element (no
					// newline between the comment and the element's first
					// token). The writer keeps a same-line BLOCK comment
					// glued; line-style is filtered at emit. Empty
					// leadingComments → false (nothing to glue).
					leadingCommentsGlued: _lead.leadingComments.length > 0 && !_lead.newlineAfterLeadingComments,
					node: _node,
				});
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			final _closeTrail: Null<String> = collectTrailingFull(ctx);
			return $ctorCallTrivia;
		};
	}

	/**
	 * Case 3 (extended): single-arg ctor wrapping a Ref, with optional
	 * kw/lit lead and optional lit trail. No separator loop — that's Case
	 * 4's domain. Emits the kw (word-boundary checked) and/or lead literal,
	 * the structurally-parsed inner Ref, and the optional trail literal,
	 * threading the trivia-mode source-capture probes into the synth ctor.
	 *
	 */
	private function lowerKwRefBranch(branch: ShapeNode, typePath: String, ctorRef: Expr): Expr {
		final children: Array<ShapeNode> = branch.children;
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final refName: String = children[0].annotations.get(AnnotationKeys.BASE_REF);
		// ω-cast-bind-tightness: `@:fmt(atomOperand)` on a
		// single-Ref kw branch routes the operand parse to the
		// `${parseFn}Atom` variant of the sub-rule instead of the
		// full Pratt entry. The operand binds at atom level (atom
		// wrapper — includes postfix loop and prefix, excludes infix
		// Pratt), so a trailing binary operator stays for the outer
		// Pratt loop instead of being swallowed into the operand.
		// Mirrors `@:prefix` semantics for word-keyword unary operators
		// without requiring the prefix-extension work. Consumed by
		// `HxExpr.CastExpr` so `cast (x) is Bool` parses as
		// `Is(CastExpr(ParenExpr(x)), Bool)` (Haxe-faithful), not as
		// `CastExpr(Is(ParenExpr(x), Bool))`. The atom fn name pattern
		// `${baseFn}Atom` matches all three pipeline-mode fn-name
		// conventions (`parseHxExpr` / `parseHxExprS` / `parseHxExprT`
		// → `parseHxExprAtom` / `parseHxExprSAtom` / `parseHxExprTAtom`).
		final atomOperand: Bool = branch.fmtHasFlag(ATOM_OPERAND_FLAG);
		final subFnName: String = atomOperand ? '${parseFnName(refName)}Atom' : parseFnName(refName);
		final callSub: Expr = {
			expr: ECall(macro $i{subFnName}, [macro ctx]),
			pos: Context.currentPos()
		};
		final trailOptional: Bool = branch.annotations[AnnotationKeys.LIT_TRAIL_OPTIONAL] == true;
		// ω-trailopt-source-track: in trivia mode, paired Alt ctors
		// of `@:trailOpt(...)` branches carry an extra positional
		// `trailPresent:Bool` arg synthesised by `TriviaTypeSynth`.
		// Pass the captured `matchLit` result through so the writer
		// can preserve source presence of the trail literal.
		final triviaTrailOpt: Bool = trailOptional && _ctx.trivia && isTriviaBearing(typePath);
		// ω-slice-V — parser-side shape-gated trail literal. A ctor
		// carrying `@:fmt(trailOptParseGate('<adapter>'))` alongside
		// `@:trailOpt(...)` makes the optional-trail decision depend on
		// the just-parsed child `_raw`: `<adapter>(_raw)` true →
		// `matchLit` (`;` optional, brace-terminated expr); false →
		// `expectLit` (`;` required — THROWS to terminate the
		// statement, preserving the Star-loop boundary). `<adapter>`
		// names the generated typed predicate for astPreds formats
		// (see `buildKwRefParseGateCall`); other formats reach it via
		// the schema instance, the same `formatInfo.schemaTypePath`
		// `.instance.<m>` channel the generated parser already uses
		// for `unescapeChar`. Strictly
		// opt-in: `parseGate == null` → the unconditional emission
		// below is byte-identical, so every other `@:trailOpt` ctor
		// (`VarStmt` / `FinalStmt` / `ReturnStmt` / …) is untouched.
		// Sole consumer: `HxStatement.ExprStmt` (the no-keyword
		// catch-all, where a blanket optional `;` would break boundary
		// detection — hence the shape gate instead).
		final parseGateCall: Null<Expr> = buildKwRefParseGateCall(branch);
		// ω-string-interp-noformat: ctors with `@:fmt(captureSource)` +
		// `@:lead`/`@:trail` carry a positional `sourceText:String` arg
		// in trivia mode. The parser captures the byte slice between
		// lead and trail (inclusive of any interior whitespace) so the
		// writer can emit verbatim under
		// `opt.formatStringInterpolation == false`. Trivia-only because
		// the synth-pair ctor is the carrier; plain pipelines keep the
		// pre-slice ctor arity.
		final triviaCaptureSource: Bool = _ctx.trivia && isTriviaBearing(typePath) && TriviaPairAltCtor.isCaptureSourceBranch(branch);
		// ω-issue-257-firstline: ctors with `@:fmt(bodyPolicy(...))` on a
		// single-Ref kw-led branch (e.g. `HxStatement.ReturnStmt`) carry
		// a positional `bodyOnSameLine:Bool` arg in the synth pair. The
		// parser captures whether the post-kw whitespace crossed a
		// newline so `bodyPolicyWrap`'s `Keep` branch can dispatch
		// source-shape-aware. Trivia-only — plain mode keeps the
		// original ctor arity and falls back to width-driven layout
		// via `widthAware`.
		final triviaBodyPolicyKw: Bool = _ctx.trivia && isTriviaBearing(typePath) && TriviaPairAltCtor.isAltBodyPolicyKwBranch(branch);
		// omega-paren-wrap-source-newline: ctors with @:fmt(captureWrapOpenNewline)
		// on a single-Ref @:wrap branch carry a positional wrapOpenNewline:
		// Bool arg in the synth pair. Parser captures whether the gap
		// between the open lead literal and the inner sub-rule's first
		// token crossed a newline so the writer can pick between
		// `(\n<inner>\n)` (open broken; preserves authored shape on
		// chain inners) and `(<inner>\n)` (glued; unchanged default).
		// Trivia-only; plain mode keeps the original ctor arity.
		final triviaWrapOpenNewline: Bool = _ctx.trivia && isTriviaBearing(typePath) && TriviaPairAltCtor.isAltWrapOpenNewlineBranch(
			branch
		);
		// ω-keep-kw-newline (increment 1b): mandatory-`@:kw` VarStmt-family
		// ctors with `@:fmt(captureKwNewline)` carry a positional
		// `kwNewline:Bool` arg. The parser captures whether the gap between
		// the LAST keyword / lead literal (`var` / `final`) and the inner
		// `decl` Ref's first token crossed a newline, so the writer's
		// `HxVarDecl` multiVar fold reproduces the source `var`→head newline
		// under `WrapMode.Keep`. Trivia-only; plain mode keeps the original
		// ctor arity (head always glued to `var `).
		final triviaKwNewline: Bool = _ctx.trivia && isTriviaBearing(typePath) && TriviaPairAltCtor.isAltKwNewlineBranch(branch);
		final ctorCall: Expr = buildKwRefCtorCall(
			ctorRef, triviaTrailOpt, triviaCaptureSource, triviaBodyPolicyKw, triviaWrapOpenNewline, triviaKwNewline
		);
		final kwLead: Null<String> = branch.annotations[AnnotationKeys.KW_LEAD_TEXT];
		final steps: Array<Expr> = [macro skipWs(ctx)];
		// `@:kw` and `@:wrap`/`@:lead` compose on the same single-Ref
		// branch: emit kw (word-boundary checked) first, then the lead
		// literal. The composed shape supports kw-led ctors that wrap
		// their payload in matched delimiters — keyword commits the
		// branch and the wrap pair delimits the structurally-parsed
		// inner Ref. Either or both may be absent — the `@:kw('return')`
		// -only ctors keep their pre-slice shape, and a bare `@:wrap`
		// -only ctor (`ParenExpr`) stays a single-literal commit.
		// ω-untyped-keep-trybody: branch-level `@:fmt(forwardNewlineForBody)`
		// opt-in tells Case 3 to OMIT the post-kw `skipWs(ctx)` so the
		// inner sub-rule's first-field `collectTrivia` can scan the gap
		// itself and capture `newlineBefore` onto the synth
		// `<field>BeforeNewline:Bool` slot. Pairs with field-level
		// `@:fmt(beforeNewlineSlotFirst)` on the inner struct's first
		// Ref field — both must be present for the channel to work.
		// Without the flag the post-kw `skipWs` runs as before, which
		// is the right default for every other Case 3 kw-branch (`if`,
		// `while`, `for`, `do`, `switch`, `throw`, etc.). Currently
		// consumed only by `HxStatement.TryCatchStmt` (issue_362
		// _untyped_body_keep `try\n\tuntyped {…}` shape).
		final forwardNewlineForBody: Bool = branch.fmtHasFlag('forwardNewlineForBody');
		// `forwardNewlineForBody` omits the post-kw `skipWs`. The
		// `triviaBodyPolicyKw` capture (`_bodyOnSameLine` from
		// `hasNewlineIn(_kwEndPos, ctx.pos)`) would then scan an empty
		// range and silently degenerate to `_bodyOnSameLine=true`. The
		// two channels target the same data (post-kw newline) via
		// different routes — combining them is a grammar error.
		if (forwardNewlineForBody && triviaBodyPolicyKw)
			Context.fatalError(
				'Lowering: @:fmt(forwardNewlineForBody) on a @:fmt(bodyPolicy(...)) '
				+ 'branch is a conflict — both channels capture the post-kw newline; pick one.',
				Context.currentPos()
			);
		appendKwRefLeadSteps(steps, kwLead, leadText, triviaKwNewline, triviaBodyPolicyKw, forwardNewlineForBody, triviaWrapOpenNewline);
		// Capture _start_pos AFTER any lead literal AND its skipWs, so
		// the substring spans only what lives between lead and trail.
		// In `@:raw` rules the `skipWs` call gets stripped by the rule-
		// level post-process, but the capture still works — `ctx.pos`
		// at this point is the position of the first byte after the
		// lead literal.
		if (triviaCaptureSource) steps.push(macro final _start_pos: Int = ctx.pos);
		steps.push({
			expr: EVars([
				{
					name: '_raw',
					type: null,
					expr: callSub,
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
		if (trailText != null) appendKwRefTrailStep(steps, trailText, triviaTrailOpt, triviaCaptureSource, trailOptional, parseGateCall);
		appendRejectFollowKwStep(steps, branch);
		steps.push(macro return $ctorCall);
		return macro $b{steps};
	}

	/**
	 * Build the optional parse-gate predicate call (`@:fmt(trailOptParseGate(
	 * '<adapter>'))`), or `null` when the branch carries no gate. For an
	 * `astPreds` format the gate is the generated typed predicate of this
	 * build's AST family (`AstPreds` / `AstPredsT` / `AstPredsS` — the
	 * parse fns return bare mode values, so `_raw` needs no unwrap);
	 * other formats keep the legacy schema-instance channel (same
	 * `formatInfo.schemaTypePath` `.instance.<m>` path as `unescapeChar`).
	 */
	private function buildKwRefParseGateCall(branch: ShapeNode): Null<Expr> {
		final parseGate: Null<Array<String>> = branch.fmtReadStringArgs('trailOptParseGate');
		if (parseGate == null || parseGate.length != 1) return null;
		if (_formatInfo.astPreds) return AstPredLowering.predCallExpr(_shape.root, _ctx.trivia, _ctx.spans, parseGate[0], [macro _raw]);
		final fmtParts: Array<String> = _formatInfo.schemaTypePath.split('.');
		return {
			expr: ECall({ expr: EField(macro $p{fmtParts}.instance, parseGate[0]), pos: Context.currentPos() }, [macro _raw]),
			pos: Context.currentPos()
		};
	}

	/**
	 * Case 4 dispatch: compute the shared close-peek locals (element call,
	 * close-not-next / close-or-eof probes, ctor call) for a `@:lead`/
	 * `@:trail` Star branch, then route to the trivia / sepAlt / block-ended
	 * / plain-sep / no-sep arm.
	 */
	private function lowerStarBranch(
		branch: ShapeNode, ctorRef: Expr, leadText: String, trailText: String, sepText: Null<String>, sepAltText: Null<String>
	): Expr {
		final starNode: ShapeNode = branch.children[0];
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: Star child must be a Ref in Phase 2', Context.currentPos());
		}
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = parseFnName(elemRefName);
		final elemCT: ComplexType = ruleReturnCT(elemRefName);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos()
		};
		// See struct-field close-peek (emitStarFieldSteps) for why
		// we flip to full-string `peekLit` when close is multi-byte.
		final closeCharCode: Int = trailText.charCodeAt(0);
		final closeNotNextExpr: Expr = trailText.length == 1
			? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
			: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{trailText});
		final closeNextOrEofExpr: Expr = trailText.length == 1
			? macro ctx.pos >= ctx.input.length || ctx.input.charCodeAt(ctx.pos) == $v{closeCharCode}
			: macro ctx.pos >= ctx.input.length || peekLit(ctx, $v{trailText});
		final ctorCall: Expr = { expr: ECall(ctorRef, [macro _items]), pos: Context.currentPos() };
		// Trivia-mode @:trivia Star in an enum branch (e.g. HxStatement.BlockStmt
		// marks its stmts Star via the branch-level @:trivia meta propagated to
		// the Star by TriviaAnalysis). Replace the plain element-push loop with
		// a collectTrivia → parseElement → collectTrailing pipeline that feeds
		// Trivial<T> structs into the accumulator.
		//
		// ω-trivia-sep: `@:sep` is supported alongside `@:trivia` for
		// close-peek Alt branches (e.g. `HxExpr.ArrayExpr` with
		// `@:lead('[') @:trail(']') @:sep(',')`). The sep is matched
		// after each element via `matchLit`, before `collectTrailing`,
		// so a same-line `// comment` after `,` attaches to the
		// just-pushed element.
		if (_ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true)
			return lowerTriviaStarBranch(branch, ctorRef, leadText, trailText, sepText, elemCT, elemCall, closeNextOrEofExpr);
		if (sepText == null) return lowerStarNoSepBranch(leadText, trailText, elemCT, elemCall, closeNotNextExpr, ctorCall);
		final sepCharCode: Int = sepText.charCodeAt(0);
		// Opt-in (@:sepAlt) tolerant variant: a close-driven loop that
		// consumes an OPTIONAL separator (sepText or sepAltText) between
		// elements. Mirrors the trivia-build close-peek loop in plain
		// mode so multi `;`-separated anon fields parse under the
		// non-trivia HaxeParser / HaxeModuleSpanParser builds. Only the
		// @:sepAlt branch (HxType.Anon) reaches this; the strict loop
		// below stays byte-identical for every other @:sep Star.
		if (sepAltText != null)
			return lowerStarSepAltBranch(
				leadText, trailText, elemCT, elemCall, closeNotNextExpr, ctorCall, sepCharCode, sepAltText.charCodeAt(0)
			);
		// Block-ended exemption (Session 2 pilot — mirror of
		// `emitStarFieldSteps`). When the enum branch carries
		// `@:sep('text', tailRelax, blockEnded)`, sep between two
		// elements may be omitted when the prior element ended
		// with `}` or `;` (byte-check). The optional
		// `blockEnded('<predicate>')` form additionally consults a
		// schema-instance predicate on the just-pushed element to
		// decide sep-elision based on AST shape (Session 6 option
		// b2 — see `buildBlockEndedPredicateCall`). Strictly
		// opt-in: when `lit.sepBlockEnded` is absent the
		// byte-identical pre-existing path runs.
		final blockEnded: Bool = branch.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		return blockEnded
			? lowerStarBlockEndedBranch(branch, leadText, trailText, elemCT, elemCall, closeNotNextExpr, ctorCall, sepCharCode, sepText)
			: lowerStarSepBranch(leadText, trailText, elemCT, elemCall, closeNotNextExpr, ctorCall, sepCharCode);
	}

	// -------- binary field helpers --------
	// -------- @:raw post-processing --------
	// -------- helpers --------
}
#end
