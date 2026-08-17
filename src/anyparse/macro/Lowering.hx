package anyparse.macro;

using StringTools;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.MacroStringTools;
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;

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
 * directly rather than round-tripping through a separate `CoreIR →
 * Expr` serializer, which would double the code with no observable
 * benefit until Phase 3 adds more primitive variants.
 */
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
	private final _shape: ShapeBuilder.ShapeResult;
	private final _formatInfo: FormatReader.FormatInfo;
	private final _ctx: LoweringCtx;

	public function new(shape: ShapeBuilder.ShapeResult, formatInfo: FormatReader.FormatInfo, ctx: LoweringCtx) {
		_shape = shape;
		_formatInfo = formatInfo;
		_ctx = ctx;
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
		for (typePath => node in _shape.rules) {
			final entryFn: String = parseFnName(typePath);
			for (rule in lowerRule(typePath, node)) {
				rules.push(rule);
				if (_ctx.spans && node.kind != Terminal) spanRuleNames[rule.fnName] = true;
				if (rule.fnName == entryFn) checkRuleFirstToken(_shape.rules, typePath, rule);
			}
		}
		#if anyparse_dispatch_dump
		dumpDispatch(_shape.rules);
		#end
		if (_ctx.spans) for (rule in rules) if (spanRuleNames.exists(rule.fnName)) rule.body = instrumentSpans(rule.body);
		return rules;
	}

	/**
	 * ω-span-mode-inast — when `ctx.spans=true`, walk the rule body Expr
	 * and append a `Span(_start, ctx.pos)` positional arg to every ctor
	 * build site so the constructed paired enum value carries its own
	 * span in-AST.
	 *
	 * Prepends `final _start:Int = ctx.pos;` at the body top so every
	 * downstream ctor call sees a per-rule entry position. Pratt and
	 * Postfix loops reuse the same `_start` for every iteration — the
	 * span of an iteration's freshly-built composite ctor covers (rule
	 * entry, end of the right operand), which is the correct outer
	 * coverage (`a + b + c` produces `Add(Add(a,b), c)` whose outer
	 * `Add`'s span covers the whole expression).
	 *
	 * Ctor build shapes the walker rewrites:
	 *  - `return $ctorRef;` where `$ctorRef` is the EField chain to a
	 *    paired ctor (zero-arg branches, Case 0/1). Walker wraps the
	 *    reference into `ECall(ctorRef, [spanArg])` so the paired ctor's
	 *    single `_span` arg is supplied.
	 *  - `return ECall($ctorRef, [args])` — every other ctor return
	 *    (Cases 2/3/4/5 + multi-lit dispatch + prefix). Walker appends
	 *    the span arg to the args list.
	 *  - `left = ECall($ctorRef, [args])` — Pratt/Postfix iteration
	 *    composites. Walker appends the span arg.
	 *
	 * Seq struct returns (`return $structLit`) are left untouched —
	 * `EObjectDecl` is structurally distinct and Seq paired typedefs
	 * carry no `_span` field (their parent enum value's span covers
	 * them in the consumer's QueryNode model).
	 *
	 * `return left;` at the tail of Pratt/Postfix loops is excluded by
	 * the `isBareLeft` guard — `left` is already a paired value built
	 * inside the loop iterations; re-wrapping it would be wrong.
	 *
	 * Failed `tryBranch` attempts throw `ParseError` before reaching
	 * the ctor build site, so no incorrect span lands on a rolled-back
	 * branch — `tryBranch`'s own `ctx.pos = _savedPos` rollback handles
	 * recovery.
	 */
	private function instrumentSpans(body: Expr): Expr {
		final transformed: Expr = transformForSpans(body);
		return macro {
			final _start: Int = ctx.pos;
			$transformed;
		};
	}

	private function transformForSpans(e: Expr): Expr {
		return switch e.expr {
			case EReturn(returnExpr) if (returnExpr != null && !isBareLeft(returnExpr)):
				final appended: Expr = appendSpanArg(returnExpr);
				macro return $appended;
			case EBinop(OpAssign, lhs, rhs) if (isBareLeft(lhs)):
				final appended: Expr = appendSpanArg(rhs);
				macro left = $appended;
			case _: ExprTools.map(e, transformForSpans);
		};
	}

	/**
	 * Append `new Span(_start, ctx.pos)` as a trailing positional arg
	 * to a ctor build expression. Three shapes:
	 *
	 *  - `ECall(fn, args)` — typical ctor call. Args grow by one. Note:
	 *    this matches BOTH paired ctor calls (the intended case) AND
	 *    helper invocations that wrap the return value, but no helper
	 *    is ever a top-level `return`/`left=` rhs in Lowering's output
	 *    — the only top-level shapes for those positions are ctor refs/
	 *    calls and Seq struct literals.
	 *  - `EField` / `EConst(CIdent)` — bare ctor reference (Case 0/1
	 *    paths `return $ctorRef;`). Wrap into a single-arg call so the
	 *    paired ctor's `_span` arg is supplied.
	 *  - Anything else (EObjectDecl from Seq, the rare untouched form)
	 *    — pass through unchanged.
	 */
	private function appendSpanArg(e: Expr): Expr {
		final spanArg: Expr = macro new anyparse.runtime.Span(_start, ctx.pos);
		return switch e.expr {
			case ECall(fn, args):
				{ expr: ECall(fn, args.concat([spanArg])), pos: e.pos };
			case EField(_, _) | EConst(CIdent(_)):
				{ expr: ECall(e, [spanArg]), pos: e.pos };
			case _: e;
		};
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
				final loopBody: Expr = lowerPrattLoop(node, typePath, simple);
				final wrapperBody: Expr = lowerPostfixLoop(node, typePath, simple, coreFnName);
				final coreBody: Expr = lowerEnum(node, typePath, true, wrapperFnName);
				final eregs: Array<GeneratedRule.EregSpec> = collectEregs(typePath);
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
				final loopBody: Expr = lowerPrattLoop(node, typePath, simple);
				final atomBody: Expr = lowerEnum(node, typePath, true, atomFnName);
				final eregs: Array<GeneratedRule.EregSpec> = collectEregs(typePath);
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
				final wrapperBody: Expr = lowerPostfixLoop(node, typePath, simple, coreFnName);
				final coreBody: Expr = lowerEnum(node, typePath, true, fnName);
				final eregs: Array<GeneratedRule.EregSpec> = collectEregs(typePath);
				final wrapperRule: GeneratedRule = new GeneratedRule(fnName, returnCT, wrapperBody, eregs, false);
				final coreRule: GeneratedRule = new GeneratedRule(coreFnName, returnCT, coreBody, [], false);
				[wrapperRule, coreRule];
			case Alt:
				final body: Expr = lowerEnum(node, typePath, false, fnName);
				[new GeneratedRule(fnName, returnCT, body, collectEregs(typePath))];
			case Seq:
				final body: Expr = lowerStruct(node, typePath);
				[new GeneratedRule(fnName, returnCT, body, collectEregs(typePath))];
			case Terminal:
				final body: Expr = lowerTerminal(node, typePath, simple);
				[new GeneratedRule(fnName, returnCT, body, collectEregs(typePath))];
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

	private function collectEregs(typePath: String): Array<GeneratedRule.EregSpec> {
		final eregs: Array<GeneratedRule.EregSpec> = [];
		if (_eregByRule.exists(typePath)) eregs.push(_eregByRule[typePath]);
		return eregs;
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
			pos: Context.currentPos(),
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
		final firstTokens: Array<BranchFirstToken> = branches.map(branchFirstToken.bind(_shape.rules));
		final guards: Array<Null<Expr>> = firstTokens.map(branchGuardExpr);
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
			if (guard == null)
				statements.push(trial);
			else
				statements.push(macro if ($guard) $trial);
		}
		statements.push(macro throw anyparse.runtime.ParseError.backtrack);
		return macro $b{statements};
	}

	/**
	 * Lower the Pratt-loop body for a `@:infix`-annotated enum. The body
	 * implements a standard precedence-climbing loop:
	 *
	 * ```
	 *   var left = parseXxxAtom(ctx);
	 *   while (true) {
	 *       skipWs(ctx);
	 *       final _savedPos = ctx.pos;
	 *       // Operators are dispatched longest-first — the branches
	 *       // are sorted by literal length descending before the
	 *       // chain is folded, so `<=` is tried before `<` and the
	 *       // naive `matchLit` cannot eat a short prefix of a longer
	 *       // operator. Declaration order is irrelevant to dispatch.
	 *       if (matchLit(ctx, "<op1>")) { ... }
	 *       else if (matchLit(ctx, "<op2>")) { ... }
	 *       else break;
	 *   }
	 *   return left;
	 * ```
	 *
	 * Each matched branch checks the operator's precedence against
	 * `minPrec`: if it falls below, the matched literal is rolled back and
	 * the loop breaks — the operator belongs to an outer caller. Otherwise
	 * the right operand is parsed by recursing into `parseXxx` itself at
	 * an elevated `minPrec`, and `left` is replaced with a freshly
	 * constructed ctor call built from the matched branch.
	 *
	 * Associativity is read from the `pratt.assoc` annotation on each
	 * branch (written by `Pratt.annotate`). Left-associative branches
	 * recurse at `prec + 1`, so a second same-prec operator fails the
	 * inner gate and is re-taken by the outer loop iteration, folding
	 * left. Right-associative branches recurse at `prec`, so a second
	 * same-prec operator is absorbed by the inner recursion, folding
	 * right. The per-branch choice is baked in at macro time — no
	 * runtime switch on associativity.
	 */
	private function lowerPrattLoop(node: ShapeNode, typePath: String, simple: String): Expr {
		final returnCT: ComplexType = ruleReturnCT(typePath);
		final loopFnName: String = parseFnName(typePath);
		final atomFnName: String = '${loopFnName}Atom';
		final atomCall: Expr = {
			expr: ECall(macro $i{atomFnName}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final operatorBranches: Array<ShapeNode> = [
			for (b in node.children)
				if (b.annotations.get(AnnotationKeys.PRATT_PREC) != null || b.annotations.get(AnnotationKeys.TERNARY_OP) != null) b
		];
		// Longest-match sort: longer operator literals come first in the
		// generated dispatch chain so `<=` is attempted before `<` (and
		// `??` before `?`). Without this, `matchLit(ctx, "<")` succeeds on
		// input `<=`, consumes one char, and leaves `=` stranded for the
		// right operand parser to trip over. The sort is a Lowering-level
		// policy — `matchLit` stays a naive prefix match everywhere else
		// (enum-branch Case 1 `expectLit`, struct lead/trail, Case 4 array
		// loops) where ambiguity cannot arise because the literal is fixed
		// at macro time. Order among equal-length operators is semantically
		// irrelevant (no length-N operator is a prefix of another length-N
		// operator in a well-formed grammar), so `Array.sort` suffices.
		// The sort key uses `pratt.op` for binary infix branches and
		// `ternary.op` for ternary branches — both are operator literals
		// that compete in the same `matchLit` dispatch chain.
		operatorBranches.sort((a, b) -> {
			final la: Int = getOperatorText(a).length;
			final lb: Int = getOperatorText(b).length;
			return lb - la;
		});
		// Fold the operator chain into a nested if/else if tree. Each leaf
		// branch consumes the operator literal (already matched at the
		// peek), enforces `minPrec`, parses the right operand by recursing
		// into `parseXxx` at `prec + 1` for left-associative branches or
		// `prec` for right-associative branches, and rebuilds `left` as
		// the matched ctor call. Ternary branches (detected by `ternary.op`)
		// parse both middle and right operands at `minPrec = 0` (full
		// expression) with an `expectLit` separator in between.
		// ω-pratt-comment-stash: in Trivia mode, the matched-branch internal
		// `skipWs` calls swap to `skipWsAndStash` so any line/block comment
		// between the operator and the next operand is captured verbatim
		// into `ctx.pendingTrivia.leadingComments`. The next `collectTrivia`
		// drains them as leading-of-next-thing — orphan trivia rather than
		// data loss. Without this swap, `a + // c\n b` loses `// c` because
		// the post-op `skipWs` discards it (the outer Pratt rewind only fires
		// on no-match). Plain mode keeps `skipWs` (no Trivia channel).
		final skipFnName: String = _ctx.trivia ? 'skipWsAndStash' : 'skipWs';
		final skipCall: Expr = {
			expr: ECall(macro $i{skipFnName}, [macro ctx]),
			pos: Context.currentPos(),
		};
		var opChain: Expr = macro _matched = false;
		for (i in 0...operatorBranches.length) {
			final branch: ShapeNode = operatorBranches[operatorBranches.length - 1 - i];
			final opText: String = getOperatorText(branch);
			final branchBody: Expr = buildPrattBranchBody(branch, typePath, simple, skipCall);
			final matchFnName: String = endsWithWordChar(opText) ? 'matchKw' : 'matchLit';
			final matchCall: Expr = {
				expr: ECall(macro $i{matchFnName}, [macro ctx, macro $v{opText}]),
				pos: Context.currentPos(),
			};
			opChain = macro if ($matchCall)
				$branchBody
			else
				$opChain;
		}
		// ω-cond-splice: word-like op literals of the ENUM (not only the
		// Pratt tier — the postfix tier's `#if` splice dispatch re-probes
		// from the position this loop exits at). Drives the conditional
		// no-match position restore in `buildPrattLoopExpr`.
		final wordOps: Array<String> = [for (op in collectAllOps(node)) if (endsWithWordChar(op)) op];
		return buildPrattLoopExpr(returnCT, atomCall, opChain, wordOps);
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

	/**
	 * Lower the postfix-loop body for a `@:postfix`-annotated enum. The
	 * body runs inside the atom wrapper function and looks like:
	 *
	 * ```
	 *   var left = parseXxxAtomCore(ctx);
	 *   while (true) {
	 *       skipWs(ctx);
	 *       var _matched:Bool = true;
	 *       if (matchLit(ctx, "(")) { skipWs; expectLit(")"); left = Ctor(left); }
	 *       else if (matchLit(ctx, "[")) { skipWs; _i = parseXxx(ctx); skipWs; expectLit("]"); left = Ctor(left, _i); }
	 *       else if (matchLit(ctx, ".")) { skipWs; _f = parseHxIdentLit(ctx); left = Ctor(left, _f); }
	 *       else _matched = false;
	 *       if (!_matched) break;
	 *   }
	 *   return left;
	 * ```
	 *
	 * There is no precedence gate and no `_savedPos` rollback. Once a
	 * postfix operator matches, the body commits: a failing inner parse
	 * (e.g. unclosed `[`) throws `ParseError` upward as a hard error.
	 * The loop only terminates by exhausting the dispatch chain — none
	 * of the peeked operators matched, so the postfix-extended atom is
	 * complete and control returns to the caller (usually the Pratt
	 * loop, which then tries its own operators around `left`).
	 *
	 * Longest-first sort on `postfix.op` (same pattern as `lowerPrattLoop`
	 * D33) keeps declaration order irrelevant to dispatch. For slice δ1
	 * the three shipping ops (`.`, `[`, `(`) have unique first characters
	 * so the sort is a no-op, but the guarantee holds for future
	 * shared-prefix cases (e.g. hypothetical `?.` vs `?`).
	 *
	 * Each branch picks one of three body shapes based on a combination
	 * of `postfix.close` presence and the branch's children:
	 *
	 *  1. **pair-lit (call-no-args)** — 1 child (operand only),
	 *     `postfix.close` set. Body: expect close literal, build
	 *     `Ctor(left)`.
	 *  2. **single-Ref-suffix (field access)** — 2 children (operand +
	 *     suffix Ref), `postfix.close` absent. Body: parse the suffix
	 *     Ref, build `Ctor(left, suffix)`. The suffix Ref typically
	 *     points at a Terminal like `HxIdentLit`.
	 *  3. **wrap-with-recurse (index access)** — 2 children (operand +
	 *     inner Ref), `postfix.close` set. Body: parse the inner Ref
	 *     (typically `SelfType`, a full recursive expression), expect
	 *     close, build `Ctor(left, inner)`.
	 *
	 * Validation of the operand child (must be `Ref` to same enum) and
	 * symbolic-op check (no word-like postfix ops yet) run at macro
	 * time — word-like ops would need a word-boundary-aware match helper
	 * which is not wired for postfix in this slice.
	 */
	private function lowerPostfixLoop(node: ShapeNode, typePath: String, simple: String, coreFnName: String): Expr {
		final returnCT: ComplexType = ruleReturnCT(typePath);
		final enumSimple: String = simple;
		final selfFnName: String = parseFnName(typePath);
		final coreCall: Expr = {
			expr: ECall(macro $i{coreFnName}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final postfixBranches: Array<ShapeNode> = [
			for (b in node.children) if (b.annotations.get(AnnotationKeys.POSTFIX_OP) != null) b
		];
		if (postfixBranches.length == 0) {
			Context.fatalError('Lowering: lowerPostfixLoop called with no postfix branches', Context.currentPos());
		}
		// ω-keep-chain-receiver-comment: when this postfix enum has a method-chain
		// `@:fmt(captureChainNewline)` branch (`HxExpr.FieldAccess`), capture the
		// operand's trailing comment at the loop's pre-skipWs site so a bare chain
		// receiver's same-line comment survives the per-iteration `skipWs`. The
		// captured value feeds the FieldAccess ctor's `chainLeadComment` slot;
		// trivia-mode only and gated on the branch flag so every other postfix loop
		// emits the legacy body unchanged (byte-inert non-keep / non-chain).
		var hasChainBranch: Bool = false;
		for (b in postfixBranches) if (b.fmtHasFlag('captureChainNewline')) hasChainBranch = true;
		final wantOpTrail: Bool = _ctx.trivia && hasChainBranch;
		// Longest-first sort — same macro-time policy as lowerPrattLoop (D33).
		postfixBranches.sort((a, b) -> {
			final la: Int = (a.annotations.get(AnnotationKeys.POSTFIX_OP): String).length;
			final lb: Int = (b.annotations.get(AnnotationKeys.POSTFIX_OP): String).length;
			return lb - la;
		});
		// Cross-category longer-prefix resolution: a postfix op that is a
		// strict prefix of another op in the same enum (postfix, infix, or
		// ternary) must lose to that longer op. Without this, postfix `.`
		// commits on the first `.` of `...` — then fails to parse a
		// following HxIdentLit and throws upward, rewinding past the entire
		// HxVarDecl/HxClassMember/… chain. Collecting ALL op literals on
		// the enum lets us emit a `!peekLit(longer)` guard per conflict so
		// the postfix dispatch declines and Pratt picks up the longer op.
		final allOps: Array<String> = collectAllOps(node);
		// Fold the dispatch chain right-to-left, mirroring lowerPrattLoop.
		var opChain: Expr = macro _matched = false;
		for (i in 0...postfixBranches.length) {
			final branch: ShapeNode = postfixBranches[postfixBranches.length - 1 - i];
			final op: String = branch.annotations[AnnotationKeys.POSTFIX_OP];
			final close: Null<String> = branch.annotations[AnnotationKeys.POSTFIX_CLOSE];
			final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
			// Word-like postfix ops (ω-cond-splice: '#if' as the dispatch of
			// `CondSpliceTail`) route through `matchKw` in
			// `buildPostfixOpMatchExpr` — word-boundary-checked, so an
			// identifier merely PREFIXED by the op text never commits.
			final children: Array<ShapeNode> = branch.children;
			if (children.length == 0 || children[0].kind != Ref) {
				Context.fatalError(
					'Lowering: @:postfix branch "$ctor" must have operand:$enumSimple as its first argument', Context.currentPos()
				);
			}
			final operandRef: String = children[0].annotations.get(AnnotationKeys.BASE_REF);
			if (simpleName(operandRef) != enumSimple) {
				Context.fatalError('Lowering: @:postfix operand must reference the same enum ($enumSimple)', Context.currentPos());
			}
			final ctorPath: Array<String> = ruleCtorPath(typePath, ctor);
			final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
			final branchBody: Expr = if (children.length == 1) {
				buildPostfixSingleBranch(close, ctorRef);
			} else if (children.length == 2 && children[1].kind == Star) {
				buildPostfixStarSuffixBranch(branch, children, close, ctor, ctorRef, enumSimple, selfFnName);
			} else if (children.length == 2) {
				buildPostfixSuffixBranch(children, ctor, ctorRef, close, branch, enumSimple, selfFnName);
			} else {
				Context.fatalError(
					'Lowering: @:postfix branch "$ctor" has ${children.length} arguments; expected 1 (pair-lit), 2 (suffix/Star form)',
					Context.currentPos()
				);
				throw 'unreachable';
			};
			// Prepend `!peekLit(longerOp)` guards for every op literal that
			// strictly starts with `op`. Short-circuits so matchLit is not
			// called when a longer op is about to match.
			final matchExpr: Expr = buildPostfixOpMatchExpr(op, allOps);
			opChain = macro if ($matchExpr)
				$branchBody
			else
				$opChain;
		}
		// ω-trivia-sep: same pre-skipWs save + comment-only rewind as
		// `lowerPrattLoop`. See that function for the rationale.
		// ω-cond-comp-expr-multiline: mirror lowerPrattLoop's
		// `ω-untyped-keep` newline-stash on postfix-loop exit. When the
		// loop's last skipWs consumed a `\n` (and no comment, no postfix
		// match), the newline is otherwise silently dropped — Pratt's
		// outer trivia loop saves `_preWsPos` at the position the postfix
		// loop returns from, so by the time Pratt's own stash logic runs
		// the newline is already past `_preWsPos` and the scan-back finds
		// nothing. Without the stash, downstream `collectTrivia` calls
		// (e.g. the `@:trivia @:tryparse Star` `elseifs` of
		// `HxConditionalExpr` after `expr` is parsed) read
		// `newlineBefore=false` and the writer's pad-as-hardline lift
		// fires false on the `expr → elseifs[0]` boundary even when
		// source is multi-line.
		// ω-keep-chain-receiver-comment: capture the operand's same-line trailing
		// comment at the dot gap BEFORE the per-iteration `skipWs` eats it.
		// `collectTrailingFull` consumes only horizontal ws + a same-line comment
		// (rewinding on none) and stops at the newline, so the subsequent `skipWs`
		// lands at the identical position — position-inert for every branch — while
		// the FieldAccess branch reads `_opTrailComment` into its `chainLeadComment`
		// slot. Declared `null` when this enum has no chain branch so the local stays
		// in scope for the branch bodies without invoking the helper.
		final opTrailCapture: Expr = wantOpTrail
			? macro final _opTrailComment: Null<String> = collectTrailingFull(ctx)
			: macro final _opTrailComment: Null<String> = null;
		final postfixWordOps: Array<String> = [for (op in collectAllOps(node)) if (endsWithWordChar(op)) op];
		return buildPostfixLoopExpr(returnCT, coreCall, opTrailCapture, opChain, postfixWordOps);
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

	private function lowerStruct(node: ShapeNode, typePath: String): Expr {
		if (shouldLowerByName(node)) return lowerStructByName(node);
		final parseSteps: Array<Expr> = [];
		final structFields: Array<ObjectField> = [];
		// Binary: @:magic prefix — validate fixed magic bytes before fields.
		final magic: Null<String> = node.annotations['bin.magic'];
		if (magic != null) parseSteps.push(macro expectLit(ctx, $v{magic}));
		for (child in node.children) {
			final fieldName: Null<String> = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			if (fieldName == null) {
				Context.fatalError('Lowering: struct field missing base.fieldName', Context.currentPos());
			}
			// Per-field prefix: @:kw (word-boundary checked) and/or @:lead.
			// When both are present, both are emitted sequentially — @:kw
			// first, then @:lead (D50). First consumers:
			// HxDoWhileStmt.cond and HxCatchClause.name.
			//
			// For a Star field, the @:lead/@:trail pair semantically describes
			// the surrounding wrappers of the collection and is read directly
			// from the Star node's own `lit.*` annotations by
			// `emitStarFieldSteps`. Emitting them here too would produce
			// duplicate `expectLit` calls, so we skip struct-level lead/trail
			// emission whenever the field is a Star.
			//
			// For an @:optional field, the lead literal is parsed via
			// `matchLit` as part of the peek-conditional block, not as a
			// preceding unconditional `expectLit` — the peek IS the commit
			// point. So the lead emission is also skipped for optional
			// fields, and the peek + conditional sub-rule call are emitted
			// together inside the field-value switch below.
			final kwLead: Null<String> = child.readMetaString(':kw');
			final leadText: Null<String> = child.readMetaString(':lead');
			final trailText: Null<String> = child.readMetaString(':trail');
			// ω-absent-on: declarative escape-hatch for `@:optional Ref` to
			// an enum without a shared lead literal. Lists the terminator
			// literals that signal field absence at the current position;
			// emission peeks them BEFORE attempting `parseRef` instead of
			// the lead/kw matchLit-commit chain. Used by `HxFnExpr.body`
			// where `HxFnExprBody = BlockBody({-led) | ExprBody(catch-all)`
			// — the latter has no fixed lead, so a regular `@:optional`
			// can't dispatch.
			final absentOnLits: Null<Array<String>> = child.readMetaStringArgs(':absentOn');
			final isStar: Bool = child.kind == Star;
			final isOptional: Bool = child.annotations.get(AnnotationKeys.BASE_OPTIONAL) == true;
			validateStructField(child, fieldName, isOptional, isStar, kwLead, leadText, trailText, absentOnLits);
			// Binary @:length prefix — read an N-byte ASCII-encoded length
			// BEFORE any field-level lead literal. The parsed integer is
			// stored in `_lenPrefix_<field>` and consumed by the
			// `bin.lengthPrefix` branch in the Terminal case below, which
			// uses it as the byte count for a variable-length Bytes payload.
			final lenPrefix: Null<{ width: Int, encoding: String }> = child.annotations.get('bin.lengthPrefix');
			if (lenPrefix != null) emitBinLengthPrefix(fieldName, lenPrefix.width, lenPrefix.encoding, parseSteps);
			// ω-condition-wrap-keep: a mandatory-Ref condition field of a
			// `@:fmt(condWrap)` struct opted in via
			// `@:fmt(captureCondOpenNewline)` captures whether the source broke
			// right after the open paren (`if (\n\tcond`). The probe spans the
			// gap between the end of the `@:lead('(')` literal (BEFORE its
			// post-lead `skipWs`) and the cond's first token (AFTER the
			// pre-field `skipWs` at L~2224). Trivia+bearing only — plain mode
			// keeps the original struct shape (no slot synthesised). Read by
			// the writer's single-Ref condWrap emit under `WrapMode.Keep`.
			final hasCondOpenNewlineSlot: Bool = hasCondOpenNewlineField(child, typePath, isStar, isOptional, leadText);
			final condOpenNewlineLocal: String = '_condOpenNewline_$fieldName';
			emitFieldLeadIn(parseSteps, isStar, isOptional, kwLead, leadText, hasCondOpenNewlineSlot);
			// Field value — by kind.
			final localName: String = '_f_$fieldName';
			// Suppress the pre-field `skipWs` only for a trivia-collecting
			// Star with no lead literal (HxModule.decls). There the outer
			// skipWs would discard the file's first leading comments
			// before the Star loop's `collectTrivia` sees them. When a
			// lead IS present (HxClassDecl.members `{`, HxFnDecl.body `{`)
			// the outer skipWs belongs before the lead — comments between
			// the lead `{` and the first member are captured by
			// `collectTrivia` inside the loop regardless.
			final fieldFlags = computeStructFieldFlags(child, node, typePath, isStar, isOptional, kwLead, leadText);
			final triviaEofStar: Bool = fieldFlags.triviaEofStar;
			final isOptionalRef: Bool = fieldFlags.isOptionalRef;
			final isOptionalKwStar: Bool = fieldFlags.isOptionalKwStar;
			final hasBeforeNewlineSlot: Bool = fieldFlags.hasBeforeNewlineSlot;
			final hasBeforeLeadingSlot: Bool = fieldFlags.hasBeforeLeadingSlot;
			final optStarWithLead: Bool = fieldFlags.optStarWithLead;
			// The pre-emit dispatch flags above are computed in computeStructFieldFlags;
			// see there for the per-flag rationale (ω₆a optional-Ref ws ownership,
			// ω-cond-comp-engine optional-kw Star, ω-issue-48-v2 / ω-untyped-keep-trybody
			// / ω-casepattern-keep BeforeNewline slot, ω-598-member-leading-comment
			// BeforeLeading slot).
			final beforeNlLocal: String = '_beforeNl_$fieldName';
			final beforeLeadingLocal: String = '_beforeLeadCm_$fieldName';
			// ω-optional-star-rewind: when the field is `@:optional Star`
			// with `@:lead` (e.g. `HxTypeRef.params:Array<HxType>` —
			// `<...>`), defer the pre-field `skipWs` into the emit so the
			// emit can rewind cursor on `matchLit` miss. The miss-rewind
			// preserves any trivia (notably doc-comments between
			// `typedef Foo = Int` and the next decl) that the pre-field
			// `skipWs` would otherwise silently consume — closes
			// issue_216 / issue_321 cluster's parser-side bug.
			emitPreFieldWs(
				parseSteps, triviaEofStar, isOptionalRef, isOptionalKwStar, optStarWithLead, hasBeforeLeadingSlot, hasBeforeNewlineSlot,
				beforeNlLocal, beforeLeadingLocal, hasCondOpenNewlineSlot, condOpenNewlineLocal
			);
			// ω-condition-wrap-keep: the pre-field `skipWs` above advanced
			// `ctx.pos` to the cond's first token, so `hasNewlineIn` over
			// `[_condLeadEnd, ctx.pos)` answers "did the source break right
			// after `(`?". Captured into the local that the struct literal
			// writes onto the `<field>CondOpenNewline:Bool` synth slot. Runs
			// only for the opted-in condWrap cond field; `_condLeadEnd` was
			// declared right after the lead `expectLit` above.
			// ω-issue-316: for `@:optional @:kw(...)` Ref fields in Trivia
			// mode, declare per-field locals that capture (a) a same-line
			// trailing comment after the kw and (b) own-line leading comments
			// between the kw and the body's first token. These land on synth
			// sibling slots `<field>AfterKw:Null<String>` and
			// `<field>KwLeading:Array<String>` of the paired type. Writer
			// consumes them to preserve source layout.
			//
			// ω-keep-policy: two additional source-shape booleans captured
			// on the same path — `_beforeKwNl_<field>` records whether the
			// whitespace between the preceding token and the kw crossed a
			// newline; `_bodyOnSameLine_<field>` records whether the body
			// follows the kw on the same line. Both default to `false` on
			// the commit-miss path. Landed on synth slots
			// `<field>BeforeKwNewline:Bool` / `<field>BodyOnSameLine:Bool`
			// for the writer's `Keep` dispatch.
			// Sidecar slots (<field>AfterKw, <field>KwLeading, <field>BeforeKwNewline,
			// <field>BodyOnSameLine) only exist on the synth paired `*T` type of
			// trivia-bearing rules. Non-bearing rules have no paired type and the
			// plain typedef has no sidecar fields, so emitting the locals +
			// struct-literal writes for them would reference fields that do not
			// exist on the target type. First non-bearing consumer of the
			// `@:optional @:kw(...)` pattern is `HxIfExpr` — the expression-
			// position `if`. Gating on bearing mirrors every other trivia-
			// conditional branch in the codegen (`parseFnName`, `ruleReturnCT`,
			// `ruleCtorPath` all return the plain form for non-bearing refs in
			// trivia mode).
			final hasKwTriviaSlots: Bool = hasKwTriviaSlotsField(typePath, isOptionalRef, isOptionalKwStar, kwLead);
			final afterKwLocal: String = '_afterKw_$fieldName';
			final kwLeadingLocal: String = '_kwLeading_$fieldName';
			final beforeKwNlLocal: String = '_beforeKwNl_$fieldName';
			final bodyOnSameLineLocal: String = '_bodyOnSameLine_$fieldName';
			final beforeKwLeadingLocal: String = '_beforeKwLeading_$fieldName';
			final beforeKwTrailingLocal: String = '_beforeKwTrailing_$fieldName';
			// ω-optional-ref-trail: pre-declare the
			// `<field>AfterTrail` capture local before the parse step so
			// the optional-Ref's lead-led commit branch can assign into
			// it after `expectLit(trail)`, while the absent branch leaves
			// the default `null`. Mandatory-Ref path declares the same
			// local fresh post-trail (`final … = collectTrailing(ctx)`)
			// — the names collide harmlessly because the mandatory and
			// optional paths are mutually exclusive per field.
			final trailPresentLocal: String = '_trailPresent_$fieldName';
			final trailSidecar = emitTrailSidecarDecls(
				child, typePath, fieldName, isStar, isOptional, trailText, trailPresentLocal, parseSteps
			);
			final hasOptionalRefAfterTrailSlot: Bool = trailSidecar.hasOptionalRefAfterTrailSlot;
			final hasStructFieldTrailOptSlot: Bool = trailSidecar.hasStructFieldTrailOptSlot;
			final captureTrailPresentExpr: Expr = trailSidecar.captureTrailPresentExpr;
			// hasOptionalRefAfterTrailSlot / hasStructFieldTrailOptSlot and the two
			// _afterTrail_/_trailPresent_ accumulator decls + captureTrailPresentExpr
			// splice are computed/emitted by emitTrailSidecarDecls; see there.
			if (hasKwTriviaSlots) {
				emitKwTriviaSlotDecls(
					afterKwLocal, kwLeadingLocal, beforeKwNlLocal, bodyOnSameLineLocal, beforeKwLeadingLocal, beforeKwTrailingLocal,
					parseSteps
				);
			}
			emitFieldValueByKind(
				child, node, fieldName, localName, parseSteps, isOptional, kwLead, leadText, trailText, absentOnLits,
				hasOptionalRefAfterTrailSlot, captureTrailPresentExpr, hasKwTriviaSlots, afterKwLocal, kwLeadingLocal, beforeKwNlLocal,
				bodyOnSameLineLocal, beforeKwLeadingLocal, beforeKwTrailingLocal, lenPrefix
			);
			// Per-field trail. Skipped for Star fields — `emitStarFieldSteps`
			// already emitted the close literal as part of the loop wrappers.
			// Mandatory Ref path: the close + same-line `// comment`
			// capture live here. Optional Ref + lead + trail:
			// the trail consumption AND `collectTrailing` capture live
			// inside the lead-led commit branch (see the Ref-with-trail
			// splicing into `subCall` above); the slot is still emitted
			// to the struct literal via the post-switch `hasAfterTrailSlot`
			// branch below — `_afterTrail_<field>` is pre-declared in the
			// optional-Ref step to default-null in the absent branch.
			final hasAfterTrailSlot: Bool = hasAfterTrailSlotField(child, typePath, isStar, trailText);
			final afterTrailLocal: String = '_afterTrail_$fieldName';
			// `@:trailOpt("close")` on a struct Ref field: optional
			// trailing literal. The required-trail block above reads the
			// `:trail` meta only (`trailText`), so a `@:trailOpt` field
			// has `trailText == null` and is skipped there. Mirror
			// `lowerEnumBranch`'s `lit.trailOptional` handling (the
			// `else if (trailOptional) matchLit` arm): peek + consume the
			// literal if present, do NOT throw if absent. The literal is
			// consumed, not stored — the AST is identical to the
			// no-literal form. Plain `matchLit` in both modes; no trivia
			// `trailPresent` synth (the round-trip contract for the
			// struct-field consumer is idempotency, not byte presence —
			// no `@:fmt(trailOptShapeGate)` here). First consumer:
			// `HxIfExpr.thenBranch` (`if (c) e1; else e2` in value
			// position; the Build.hx offset-25 self-parse blocker).
			final trailOptText: Null<String> = child.annotations.get(AnnotationKeys.LIT_TRAIL_OPTIONAL) == true
				? child.annotations.get(AnnotationKeys.LIT_TRAIL_TEXT)
				: null;
			emitFieldTrail(
				parseSteps, isStar, isOptional, trailText, hasAfterTrailSlot, afterTrailLocal, trailOptText, captureTrailPresentExpr
			);
			// ω-cond-comp-expr-multiline: terminal-slot newline capture for
			// bare Ref fields opted in via `@:fmt(captureSourceNewlineAfter)`.
			// Mirrors `hasBeforeNewlineSlot` (which captures the gap BEFORE
			// the field's first token) — this captures the gap AFTER. Drains
			// any `pendingTrivia` stashed by the field's parse path
			// (e.g. Pratt / postfix newline-stash on the bare-Ref's own
			// expression body) AND consumes inter-token whitespace through
			// to the next non-whitespace byte. The captured trivia is
			// re-stashed into `ctx.pendingTrivia` so the next field's own
			// `collectTrivia` can replay it for its leading-newline slot —
			// without the re-stash, the newline would be consumed by the
			// terminal slot's read alone and the downstream signal walker
			// in `WriterLowering.padTrailingDoc` would lose its primary
			// (non-terminal) signal.
			final newlineAfter: { newlineAfterLocal: String, hasNewlineAfterSlot: Bool } = emitNewlineAfterCapture(
				child, typePath, fieldName, isStar, trailText, parseSteps
			);
			final hasNewlineAfterSlot: Bool = newlineAfter.hasNewlineAfterSlot;
			final newlineAfterLocal: String = newlineAfter.newlineAfterLocal;
			pushStructFieldEntries(
				structFields, fieldName, localName, child, hasStructFieldTrailOptSlot, trailPresentLocal, hasAfterTrailSlot,
				afterTrailLocal, hasBeforeNewlineSlot, beforeNlLocal, hasBeforeLeadingSlot, beforeLeadingLocal, hasNewlineAfterSlot,
				newlineAfterLocal, hasCondOpenNewlineSlot, condOpenNewlineLocal, hasKwTriviaSlots, afterKwLocal, kwLeadingLocal,
				beforeKwNlLocal, bodyOnSameLineLocal, beforeKwLeadingLocal, beforeKwTrailingLocal
			);
			// pushStructFieldEntries pushes the field value + every applicable
			// trivia/source-shape sidecar slot (TrailPresent / AfterTrail /
			// BeforeNewline / BeforeLeading / NewlineAfter / CondOpenNewline / the
			// kw-trivia set / TrailingStar slots / SepBefore); see there for the
			// per-slot gating rationale.
		}
		// Binary: @:align — skip to next alignment boundary after all fields.
		final align: Null<Int> = node.annotations['bin.align'];
		if (align != null) {
			parseSteps.push(macro {
				final _rem: Int = ctx.pos % $v{align};
				if (_rem != 0 && ctx.pos < ctx.input.length) ctx.pos += $v{align} - _rem;
			});
		}
		// ω-spanned-struct: a Seq typedef tagged `@:spanned('<Kind>')` opts
		// out of QueryNode transparency. Its paired `*S` struct carries
		// `_span` + `_kind` (synthesised by SpanTypeSynth); inject the
		// matching values here so `HaxeQueryPlugin.appendNodes` can surface
		// it as an addressable node. `_start` is in scope because
		// `instrumentSpans` wraps the whole rule body for span-bearing
		// (incl. Seq) rules. Flat/no-span builds skip both fields entirely.
		final spannedKind: Null<String> = node.readMetaString(':spanned');
		if (_ctx.spans && spannedKind != null) {
			structFields.push({ field: '_span', expr: macro new anyparse.runtime.Span(_start, ctx.pos) });
			structFields.push({ field: '_kind', expr: macro $v{spannedKind} });
		}
		final structLiteral: Expr = { expr: EObjectDecl(structFields), pos: Context.currentPos() };
		parseSteps.push(macro return $structLiteral);
		return macro $b{parseSteps};
	}

	/**
	 * Emit the parse steps for a struct field of shape `Star<Ref>`. The
	 * Star node's own `lit.*` annotations carry the surrounding wrappers
	 * (`@:lead` open, `@:trail` close, optional `@:sep`). The accumulator
	 * is declared with the given `localName` so the enclosing `lowerStruct`
	 * can reference it in the final struct literal.
	 *
	 * Four termination modes are selected by the metadata on the Star
	 * node and by the `isLastField` flag:
	 *
	 *  - `@:trail("X")` **without** `@:sep` — loop terminates when the
	 *    next non-whitespace char is the close literal's first char.
	 *  - `@:trail("X")` **with** `@:sep(",")` — loop terminates when the
	 *    next char is not a separator. The first element is parsed only
	 *    when the next char is not already the close char (empty-list
	 *    case).
	 *  - No `@:trail`, **not last field** (or `@:tryparse`) — try-parse
	 *    mode. Loop attempts to parse an element on each iteration; on
	 *    `ParseError` restores position and breaks. Used by modifier
	 *    arrays where the loop stops when the next token is not a
	 *    recognised keyword, and by switch-case bodies where the loop
	 *    stops at the next `case` / `default` / `}` (D49).
	 *  - No `@:trail`, **last field**, no `@:tryparse` — EOF mode. Loop
	 *    terminates when `ctx.pos` reaches `ctx.input.length`. Used by
	 *    module-root Star fields where the top level has no close
	 *    delimiter.
	 *  - No `@:trail`, **with** `@:sep(",")` + `@:tryparse` — try-parse
	 *    with sep peek. Loop attempts to parse an element; on success,
	 *    peeks the separator: if present, consumes it and continues; if
	 *    absent, breaks. On element-parse fail, rewinds to before any
	 *    whitespace skip and breaks (so the enclosing rule's close
	 *    literal — e.g. `#end` on the wrapping ctor — sees the next
	 *    token at its original position). Use case:
	 *    `HxConditionalObjectField.body` — comma-separated object-literal
	 *    fields inside a `#if … #end` block, where `#end` is consumed by
	 *    the enclosing `HxObjectField.Conditional` ctor, not by this
	 *    Star.
	 *
	 * `@:sep` combined with no `@:trail` AND no `@:tryparse` is rejected
	 * at compile time because there is no unambiguous way to stop a
	 * sep-peek loop at EOF without a fail-rewind signal.
	 */
	private function emitStarFieldSteps(starNode: ShapeNode, localName: String, parseSteps: Array<Expr>, isLastField: Bool): Void {
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: Star struct field must contain a Ref', Context.currentPos());
		}
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = parseFnName(elemRefName);
		final elemCT: ComplexType = ruleReturnCT(elemRefName);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final openText: Null<String> = starNode.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final closeText: Null<String> = starNode.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		if (closeText == null && sepText != null && !starNode.hasMeta(':tryparse')) {
			Context.fatalError(
				'Lowering: Star struct field with @:sep without @:trail requires @:tryparse for fail-rewind termination',
				Context.currentPos()
			);
		}
		// Trivia-mode branch — @:trivia-annotated Star accumulates
		// `Trivial<T>` wrappers instead of plain element values. Supports
		// close-peek mode (HxClassDecl.members / HxFnDecl.body) and EOF
		// mode (HxModule.decls). `@:sep` and `@:tryparse` combined with
		// @:trivia are rejected — no current grammar combines them and the
		// semantics of "trivia around a sep-separated list" are undecided.
		if (_ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true) {
			emitTriviaStarFieldSteps(starNode, localName, parseSteps, isLastField, elemCT, elemCall, openText, closeText);
			return;
		}
		if (openText != null) {
			parseSteps.push(macro expectLit(ctx, $v{openText}));
			parseSteps.push(macro skipWs(ctx));
		}
		final accumCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(elemCT)] });
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: accumCT,
					expr: macro [],
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
		final accumRef: Expr = macro $i{localName};
		if (closeText == null && sepText != null && starNode.hasMeta(':tryparse')) {
			// Try-parse with sep peek. After each successful
			// element, peeks the next non-whitespace char: if it equals
			// the sep, consumes it and continues; otherwise breaks. On
			// element-parse fail, restores `_savedPos` (taken BEFORE
			// `skipWs`) so the enclosing rule's close literal sees the
			// pre-whitespace position — matches the rewind discipline of
			// the regular tryparse-no-sep branch below. Empty input is
			// accepted (zero-element Star) for the same reason: first
			// `$elemCall` throws on `#end`, the rewind hits the original
			// position, the enclosing `@:trail('#end')` consumes the
			// directive at its native offset. The trailing-sep tolerance
			// of the sep+close branch (consume sep then check close) is
			// folded inline: after consuming the sep, the next iteration's
			// element parse will fail on `#end` and rewind to just AFTER
			// the consumed sep, so the enclosing close still sees `#end`.
			//
			// `@:fmt(sepBeforeOpt)` opt-in: BEFORE entering the
			// element loop, peek-and-consume a single leading sep INSIDE
			// the body (between enclosing kw and first element). Captures
			// true/false into `<localName>SepBefore` for the writer's
			// padLeading runtime gate to re-emit the leading sep. Without
			// this, `#if X, body #end` parses by other means only if the
			// body Star tolerates a leading `,` — which it does NOT (no
			// HxParam dispatch matches `,`, fail-rewind sticks at `,`).
			// First consumer: `HxConditionalParam.body`
			// (`whitespace/issue_582_type_hints_conditionals`).
			final sepCharCode: Int = sepText.charCodeAt(0);
			final hasSepBeforeOpt: Bool = starNode.fmtHasFlag('sepBeforeOpt');
			if (hasSepBeforeOpt) emitSepBeforeOptStep(localName, parseSteps, sepCharCode);
			final sepBlockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
			final predicateName: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE];
			final predicateCall: Expr = predicateName != null ? buildBlockEndedPredicateCall(predicateName, accumRef) : macro false;
			parseSteps.push(buildTryparseSepLoop(elemCall, accumRef, sepCharCode, sepBlockEnded, predicateCall));
			return;
		}
		emitNonTriviaCloseSteps(starNode, parseSteps, isLastField, elemCall, accumRef, closeText, sepText);
	}

	/**
	 * Emit the parse steps for an `@:optional` Star struct field with
	 * `@:lead` / `@:trail` (and optionally `@:sep`). The local is typed
	 * `Null<Array<elemCT>>`; absent input leaves it `null`, present input
	 * parses the bracketed list and assigns the array.
	 *
	 * First consumer: `HxTypeRef.params` (`@:optional @:lead('<')
	 * @:trail('>') @:sep(',')`). The element rule may recurse into the
	 * containing rule — composition is handled by the parser dispatcher,
	 * not by this emitter.
	 *
	 * Termination is close-peek with an optional sep loop, mirroring
	 * `emitStarFieldSteps`'s sep+close branch. Trivia-mode trailing slots
	 * and tryparse / EOF modes are not supported — the bracketed list
	 * shape commits to a close delimiter on `matchLit` hit.
	 */
	private function emitOptionalStarFieldSteps(starNode: ShapeNode, localName: String, parseSteps: Array<Expr>): Void {
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: @:optional Star struct field must contain a Ref', Context.currentPos());
		}
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = parseFnName(elemRefName);
		final elemCT: ComplexType = ruleReturnCT(elemRefName);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		// `@:lead` and `@:trail` are guaranteed non-null at this point —
		// the validation block in `lowerStruct` rejects optional Star
		// without both before the field-value switch fires.
		final openText: String = starNode.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final closeText: String = starNode.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final accumCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(elemCT)] });
		final optAccumCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(accumCT)] });
		final closeCharCode: Int = closeText.charCodeAt(0);
		final closeNotNextExpr: Expr = closeText.length == 1
			? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
			: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{closeText});
		final loopBody: Expr = if (sepText != null) {
			final sepCharCode: Int = sepText.charCodeAt(0);
			macro {
				skipWs(ctx);
				if ($closeNotNextExpr) {
					_items.push($elemCall);
					skipWs(ctx);
					while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
						_items.push($elemCall);
						skipWs(ctx);
					}
				}
			};
		} else {
			macro {
				skipWs(ctx);
				while ($closeNotNextExpr) {
					_items.push($elemCall);
					skipWs(ctx);
				}
			};
		}
		// ω-optional-star-rewind: save cursor BEFORE the pre-peek
		// `skipWs`, then attempt the open-lit match. On miss, rewind to
		// the saved pos so any consumed trivia (whitespace OR comments)
		// stays in the source for the next field / outer Star to pick
		// up. The caller (`lowerStruct`) suppresses its per-field
		// pre-`skipWs` for this branch so we don't double-skip.
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: optAccumCT,
					expr: macro {
						final _savedPosOptStar: Int = ctx.pos;
						skipWs(ctx);
						if (matchLit(ctx, $v{openText})) {
							final _items: $accumCT = [];
							$loopBody;
							skipWs(ctx);
							expectLit(ctx, $v{closeText});
							_items;
						} else {
							ctx.pos = _savedPosOptStar;
							null;
						}
					},
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit the parse steps for an `@:optional @:kw + @:tryparse Star`
	 * struct field. The kw is the commit point — on `matchKw` hit the
	 * tryparse loop runs until element parse fails; on miss `ctx.pos`
	 * rewinds to before the pre-commit ws scan so any trivia we just
	 * skipped becomes visible again to the enclosing `@:trivia` Star's
	 * next `collectTrivia` (mirrors the optional-Ref miss-rewind at
	 * `lowerStruct` ~1825).
	 *
	 * First consumer: `HxConditionalDecl.elseBody` (`#if … #else <decls>
	 * #end`). Splices two known-working components: kw-led commit +
	 * miss-rewind + trivia-slot machinery from the optional-Ref path
	 * (`lowerStruct` ~1744-1839) and the tryparse Star loop body from
	 * the non-optional Star path (`emitStarFieldSteps` ~2071 plain /
	 * `emitTriviaStarFieldSteps` ~2438 trivia).
	 *
	 * The local is typed `Null<Array<elemCT>>` (plain) or
	 * `Null<Array<Trivial<elemCT>>>` (trivia + `trivia.starCollects`) —
	 * absent input leaves it `null`, present input commits and runs the
	 * loop. This preserves the round-trip distinction between absent
	 * `#else` (null) and present-but-empty `#else #end` (empty array).
	 *
	 * Trivia-mode orphan-trail slots (`<localName>Trailing*`) are
	 * declared at outer scope with zero-init. Regular tryparse rewinds
	 * uncapture trivia on element-parse failure, so the slots stay at
	 * their defaults — orphan trivia propagates outward through the
	 * enclosing Star's `collectTrivia`. `@:fmt(nestBody)` is rejected
	 * (no current consumer; semantics inside an optional kw guard are
	 * undecided).
	 */
	private function emitOptionalKwStarFieldSteps(
		starNode: ShapeNode, localName: String, parseSteps: Array<Expr>, kwLead: String, hasKwTriviaSlots: Bool, afterKwLocal: String,
		beforeKwNlLocal: String, bodyOnSameLineLocal: String, beforeKwLeadingLocal: String, beforeKwTrailingLocal: String
	): Void {
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) Context.fatalError('Lowering: @:optional @:kw Star struct field must contain a Ref', Context.currentPos());
		if (starNode.fmtHasFlag('nestBody'))
			Context.fatalError('Lowering: @:optional @:kw Star + @:fmt(nestBody) is not supported', Context.currentPos());
		if (!starNode.hasMeta(':tryparse')) Context.fatalError('Lowering: @:optional @:kw Star requires @:tryparse', Context.currentPos());
		// Slice D4: `@:sep('text', tailRelax, blockEnded(...))` is supported
		// on kw-led optional Stars. Pre-D4 the engine silently ignored sep
		// on this path — `HxConditionalStmt.elseBody` (`#if … #else <stmt>;
		// #end`) decomposed `final x = 1;` into `FinalStmt + EmptyStmt(';')`
		// and the writer's sep-less inter-element pad produced `final x = 1 ;`.
		// Mirror of the sister `emitTriviaStarFieldSteps` (3422) /
		// WriterLowering (3380) contract: sep without `blockEnded` is rejected
		// because termination semantic is undefined without it.
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final blockEndedFlag: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		// ω-sep-faithful: valid alternative — same permissive-matchLit +
		// per-element `sepAfter` capture (the D4 loop below), writer-side
		// re-emission keyed purely on that captured signal.
		final kwStarSepFaithful: Bool = starNode.annotations['lit.sepFaithful'] == true;
		if (sepText != null && !blockEndedFlag && !kwStarSepFaithful) {
			Context.fatalError(
				'Lowering: @:optional @:kw Star + @:sep requires the blockEnded flag (@:sep(text, tailRelax, blockEnded)) or sepFaithful — termination semantic undefined otherwise',
				Context.currentPos()
			);
		}
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = parseFnName(elemRefName);
		final elemCT: ComplexType = ruleReturnCT(elemRefName);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final isTriviaCollects: Bool = _ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		// Element wrap and accumulator types — Trivial<T> in trivia mode.
		final accumElemCT: ComplexType = isTriviaCollects
			? TPath({ pack: ['anyparse', 'runtime'], name: 'Trivial', params: [TPType(elemCT)] })
			: elemCT;
		final accumCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(accumElemCT)] });
		final optAccumCT: ComplexType = TPath({ pack: [], name: 'Null', params: [TPType(accumCT)] });
		// Trivia-mode orphan-trail slots — zero-init at outer scope so
		// the writer's struct-literal at end-of-fn can read them. Regular
		// tryparse never writes here (rewind-on-fail uncaptures trivia);
		// slots exist purely to satisfy synth-paired-type field shape.
		if (isTriviaCollects) {
			final trailBBLocal: String = trailingBlankBeforeLocalName(localName);
			final trailNLLocal: String = trailingNewlineBeforeLocalName(localName);
			final trailLCLocal: String = trailingLeadingLocalName(localName);
			final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
			final arrayStrCT: ComplexType = TPath({
				pack: [],
				name: 'Array',
				params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
			});
			parseSteps.push({
				expr: EVars([
					{
						name: trailBBLocal,
						type: boolCT,
						expr: macro false,
						isFinal: false
					}
				]),
				pos: Context.currentPos(),
			});
			// ω-keep-fnsig-newline: sibling zero-init local so the struct-literal
			// push of TrailingNewlineBefore has a defined value on this path too.
			parseSteps.push({
				expr: EVars([
					{
						name: trailNLLocal,
						type: boolCT,
						expr: macro false,
						isFinal: false
					}
				]),
				pos: Context.currentPos(),
			});
			parseSteps.push({
				expr: EVars([
					{
						name: trailLCLocal,
						type: arrayStrCT,
						expr: macro [],
						isFinal: false
					}
				]),
				pos: Context.currentPos(),
			});
		}
		final loopBody: Expr = buildOptKwStarLoopBody(
			elemCT, elemCall, isTriviaCollects, sepText, starNode.fmtHasFlag('padTrailing'), trailingBlankBeforeLocalName(localName),
			trailingLeadingLocalName(localName)
		);
		final innerCommitAction: Expr = buildOptKwStarInnerCommit(hasKwTriviaSlots, afterKwLocal, bodyOnSameLineLocal);
		final preCommitCapture: Expr = if (hasKwTriviaSlots)
			macro $i{beforeKwNlLocal} = hasNewlineIn(ctx.input, _prevEnd, _kwStartPos);
		else
			macro {};
		final commitCheck: Expr = macro matchKw(ctx, $v{kwLead});
		// Pre-commit ws scan + commit + miss-rewind. Trivia mode does the
		// scan-back + collectTrailing + collectTrivia capture; plain mode
		// just `skipWs`. Both rewind `ctx.pos = _wsPos` on miss.
		final valueExpr: Expr = if (hasKwTriviaSlots)
			macro {
				final _wsPos: Int = ctx.pos;
				var _prevEnd: Int = _wsPos;
				while (_prevEnd > 0) {
					final _wsCh: Int = ctx.input.charCodeAt(_prevEnd - 1);
					if (_wsCh == ' '.code || _wsCh == '\t'.code || _wsCh == '\n'.code || _wsCh == '\r'.code)
						_prevEnd--;
					else
						break;
				}
				final _trailComment: Null<String> = collectTrailing(ctx);
				final _preTrivia = collectTrivia(ctx);
				final _kwStartPos: Int = ctx.pos;
				if ($commitCheck) {
					$i{beforeKwTrailingLocal} = _trailComment;
					for (_c in _preTrivia.leadingComments) $i{beforeKwLeadingLocal}.push(_c);
					$preCommitCapture;
					$innerCommitAction;
					final _items: $accumCT = [];
					$loopBody;
					_items;
				} else {
					ctx.pos = _wsPos;
					null;
				}
			}
		else
			macro {
				final _wsPos: Int = ctx.pos;
				skipWs(ctx);
				final _kwStartPos: Int = ctx.pos;
				if ($commitCheck) {
					$preCommitCapture;
					$innerCommitAction;
					final _items: $accumCT = [];
					$loopBody;
					_items;
				} else {
					ctx.pos = _wsPos;
					null;
				}
			};
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: optAccumCT,
					expr: valueExpr,
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit the Trivia-mode variant of a Star struct field — each element
	 * goes through `collectTrivia` (leading comments + blank-before
	 * detection) before being parsed, then `collectTrailing` probes for
	 * a same-line comment after the element. The result is pushed into
	 * `_items:Array<Trivial<elemCT>>` as a struct literal that mirrors
	 * `Trivial<T>`'s four fields.
	 *
	 * Supported termination modes:
	 *  - Close-peek (`closeText != null`, no `@:sep`) — reuses the
	 *    `charCodeAt == closeChar` peek from the plain-mode path.
	 *  - EOF (`closeText == null`, `isLastField`, no `@:tryparse`) —
	 *    terminates at `ctx.pos >= ctx.input.length`.
	 *  - Try-parse (`@:tryparse`, no close) — attempts element parse in
	 *    a try/catch; on failure rewinds `ctx.pos` to the start of the
	 *    iteration (before `collectTrivia`) so the enclosing Star
	 *    re-scans the bytes and attaches trivia to the correct site.
	 *    Trailing slots stay at defaults — orphan trivia propagates
	 *    outward, not into `TrailingLeading`.
	 *
	 * `@:sep` combined with `@:trivia` is rejected upstream in
	 * `emitStarFieldSteps` — no current grammar combines them and its
	 * semantics for trivia placement (before or after the separator)
	 * is undecided.
	 */
	private function emitTriviaStarFieldSteps(
		starNode: ShapeNode, localName: String, parseSteps: Array<Expr>, isLastField: Bool, elemCT: ComplexType, elemCall: Expr,
		openText: Null<String>, closeText: Null<String>
	): Void {
		final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final blockEndedFlag: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		// ω-blockended-trivia-tryparse (Session 3): the historical
		// `@:trivia + @:sep + (EOF | @:tryparse)` reject is relaxed for
		// the specific shape `@:sep(text, tailRelax, blockEnded) +
		// @:tryparse`. The blockEnded flag supplies the missing
		// termination signal: between two elements, sep may be absent
		// when the prior element ended with `}`, and sep-absent +
		// non-blockEnded gracefully exits the tryparse loop (tryparse
		// semantic: element is valid but no-more-sep means we're done).
		// First consumers: HxCaseBranch.body, HxDefaultBranch.stmts —
		// the case/default-body Stars where per-
		// statement `@:trailOpt(';')` consuming `;` and element-
		// parse failure alone cannot terminate at next `case`/`default`/`}`.
		if (sepText != null && closeText == null && !starNode.hasMeta(':tryparse')) {
			Context.fatalError('Lowering: @:trivia + @:sep requires @:trail (close-peek) or @:tryparse', Context.currentPos());
		}
		// ω-sep-faithful: `@:sep(text, sepFaithful)` supplies the same
		// termination semantic as blockEnded for the tryparse loop
		// (sep-absent exits via element-parse fail-rewind), so it is a
		// valid alternative — the difference is writer-side only
		// (source-faithful sep re-emission instead of `}`/`;` elision).
		final sepFaithfulFlag: Bool = starNode.annotations['lit.sepFaithful'] == true;
		if (sepText != null && starNode.hasMeta(':tryparse') && !blockEndedFlag && !sepFaithfulFlag) {
			Context.fatalError(
				'Lowering: @:trivia + @:sep + @:tryparse requires the blockEnded flag (@:sep(text, tailRelax, blockEnded)) or sepFaithful (@:sep(text, sepFaithful)) — termination semantic undefined otherwise',
				Context.currentPos()
			);
		}
		if (closeText == null && !isLastField && !starNode.hasMeta(':tryparse')) {
			// Defensive — the Star shape would reject on the plain path too.
			Context.fatalError('Lowering: @:trivia Star without @:trail requires the field to be terminal', Context.currentPos());
		}
		final tryparse: Bool = starNode.hasMeta(':tryparse');
		final nestBody: Bool = starNode.fmtHasFlag('nestBody');
		if (openText != null) {
			parseSteps.push(macro expectLit(ctx, $v{openText}));
			// ω-open-trailing: capture a same-line `// comment` (or
			// `/* … */`) sitting right after the open literal (e.g.
			// `{ // foo` before the first element). Stored in a synth
			// `<field>TrailingOpen` slot on the paired Seq type; the
			// writer emits it inline after the open lit so it stays on
			// the same line as `{` rather than being mis-bucketed as
			// own-line leading of the first element. Captured via
			// `collectTrailingFull` (content WITH delimiters) so block-
			// style trailings round-trip as `/* foo */`, mirroring the
			// `<field>TrailingClose` slot's verbatim contract.
			//
			// Skipped for `@:tryparse` Stars: their writer helper
			// (`triviaTryparseStarExpr`) does not consume the slot —
			// capturing here would silently drop the comment at write
			// time. The synth gate in `TriviaTypeSynth.buildStarTrailingSlots`
			// matches; without it the struct-literal push below would
			// also reference a non-existent field.
			if (!tryparse) {
				final trailOpenLocal: String = trailingOpenLocalName(localName);
				final nullStrCT: ComplexType = TPath({
					pack: [],
					name: 'Null',
					params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
				});
				parseSteps.push({
					expr: EVars([
						{
							name: trailOpenLocal,
							type: nullStrCT,
							expr: macro collectTrailingFull(ctx),
							isFinal: true,
						}
					]),
					pos: Context.currentPos(),
				});
			}
		}
		final wrappedCT: ComplexType = TPath({
			pack: ['anyparse', 'runtime'],
			name: 'Trivial',
			params: [TPType(elemCT)]
		});
		final accumCT: ComplexType = TPath({ pack: [], name: 'Array', params: [TPType(wrappedCT)] });
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: accumCT,
					expr: macro [],
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
		// ω-orphan-trivia: two mutable locals capture the trivia scanned
		// on the final iteration (the one that hits the termination
		// check). Without these, orphan comments between the last
		// element and the close literal (or EOF) would be silently
		// dropped. Paired with the two synth slots on the parent Seq
		// type (see `TriviaTypeSynth.buildStarTrailingSlots`).
		//
		// In `@:tryparse` mode the rewind-on-fail path uncaptures any
		// trivia the failed iteration had already scanned, so the
		// trailing slots stay at their zero-initialised defaults — orphan
		// trivia propagates outward through the enclosing Star's own
		// `collectTrivia` scan rather than being stashed here.
		final trailBBLocal: String = trailingBlankBeforeLocalName(localName);
		final trailNLLocal: String = trailingNewlineBeforeLocalName(localName);
		final trailLCLocal: String = trailingLeadingLocalName(localName);
		final trailBALocal: String = trailingBlankAfterLocalName(localName);
		final boolCT: ComplexType = TPath({ pack: [], name: 'Bool', params: [] });
		final arrayStrCT: ComplexType = TPath({
			pack: [],
			name: 'Array',
			params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
		});
		parseSteps.push({
			expr: EVars([
				{
					name: trailBBLocal,
					type: boolCT,
					expr: macro false,
					isFinal: false,
				}
			]),
			pos: Context.currentPos(),
		});
		// ω-keep-fnsig-newline: sibling close-newline local, declared
		// unconditionally next to `trailBBLocal`. Assigned from the terminal
		// `_lead.newlineBefore` at each close-peek break below.
		parseSteps.push({
			expr: EVars([
				{
					name: trailNLLocal,
					type: boolCT,
					expr: macro false,
					isFinal: false,
				}
			]),
			pos: Context.currentPos(),
		});
		parseSteps.push({
			expr: EVars([
				{
					name: trailLCLocal,
					type: arrayStrCT,
					expr: macro [],
					isFinal: false,
				}
			]),
			pos: Context.currentPos(),
		});
		// ω-trail-blank-after: tryparse + nestBody Stars carry an extra Bool
		// slot that records whether the source had a blank line BETWEEN the
		// stashed orphan trail comment and the next outer-Star sibling. Set
		// from `_lead.blankAfterLeadingComments` on the failed iteration
		// (the parse attempt that triggered trail capture); other tryparse
		// shapes either rewind on failure or have no nestBody wrap so the
		// signal is meaningless. Default `false` matches the no-blank case.
		if (tryparse && nestBody) {
			parseSteps.push({
				expr: EVars([
					{
						name: trailBALocal,
						type: boolCT,
						expr: macro false,
						isFinal: false,
					}
				]),
				pos: Context.currentPos(),
			});
		}
		// ω-objectlit-source-trail-comma: sep-Stars with a close literal
		// declare an extra mutable Bool that records whether the LAST
		// `matchLit(sepText)` call inside the loop succeeded. After the
		// loop terminates via the close-peek check, the local holds
		// `true` iff the final parsed element was followed by a separator
		// (i.e. source had a trailing comma). Default `false` covers the
		// empty-list case and the no-trailing-sep case identically.
		final trailPresentLocal: String = trailPresentLocalName(localName);
		if (sepText != null) {
			parseSteps.push({
				expr: EVars([
					{
						name: trailPresentLocal,
						type: boolCT,
						expr: macro false,
						isFinal: false,
					}
				]),
				pos: Context.currentPos(),
			});
		}
		final accumRef: Expr = macro $i{localName};
		if (tryparse) {
			// ω-blockended-trivia-tryparse (Session 3): `@:tryparse +
			// @:sep(text, tailRelax, blockEnded)` fork — permissive
			// matchLit on sep (consistent with the close-peek trivia
			// path's existing semantics). Element-parse failure still
			// rewinds + breaks via the existing try/catch. The
			// `blockEnded` flag does NOT affect parsing — it lives on
			// the writer side (suppress sep emission when prior ends
			// with `}` / `;`). Both nestBody and non-nestBody variants
			// emit; nestBody keeps the orphan-trail capture on parse
			// failure.
			if (sepText != null) {
				// ω-sep-faithful: mirror the plain path's `@:fmt(sepBeforeOpt)`
				// pre-loop leading-sep peek so trivia-collecting
				// conditional element bodies (`#if X, elem #end`) capture the
				// leading sep into the `<localName>SepBefore` slot the ctor
				// call references.
				if (starNode.fmtHasFlag('sepBeforeOpt')) emitSepBeforeOptStep(localName, parseSteps, sepText.charCodeAt(0));
				parseSteps.push(buildTriviaTryparseSepBody(
					elemCT, elemCall, accumRef, sepText, trailPresentLocal, trailBBLocal, trailLCLocal, trailBALocal, nestBody
				));
				return;
			}
			// Try-parse termination: each iteration saves `ctx.pos` before
			// `collectTrivia`, attempts the element parse, and rewinds to
			// the saved pos on failure so the captured trivia is fully
			// uncaptured. The enclosing `@:trivia` Star's next
			// `collectTrivia` re-scans the same bytes and attaches them
			// correctly (e.g. as leading of the next sibling element).
			//
			// `@:fmt(nestBody)` Stars (case/default bodies) add a trailing-
			// orphan capture: when parse fails AFTER scanning own-line
			// comments without a blank-line separator, those comments
			// belong to THIS body (rendered at body-indent), not to the
			// next sibling. We stash them in the trailing slots and
			// advance cursor past the trivia so the enclosing Star does
			// not re-capture. Comments separated by a blank line still
			// flow outward via rewind — preserving "blank line = belongs
			// to next entity" convention.
			parseSteps.push(buildTriviaTryparseNoSepBody(
				elemCT, elemCall, accumRef, trailBBLocal, trailLCLocal, trailBALocal, nestBody, starNode.fmtHasFlag('padTrailing')
			));
			return;
		}
		final terminationCheck: Expr = buildTriviaCloseTerminationCheck(closeText);
		// ω-trivia-sep: when the trivia Star carries `@:sep`, an
		// optional separator (e.g. `,`) is matched after each element
		// before the trailing-comment capture. Trailing same-line
		// comments after the sep (e.g. `field: 1, // comment`) attach
		// to the just-pushed element. Without sep, the close-peek loop
		// falls through unchanged.
		//
		// The pre-sep horizontal-whitespace skip avoids consuming
		// newlines / comments (`skipWs` would swallow the trailing
		// `// comment` before `collectTrailing` could see it). Inlines
		// the same `' ' | '\t' | '\r'` walk that `collectTrailing`
		// uses internally.
		// ω-objectlit-source-trail-comma: capture the per-iteration
		// `matchLit` result into the slice's source-trail-presence local.
		// After the loop's close-peek terminates, the local holds the
		// LAST iteration's sep result — `true` iff the source committed
		// to a trailing separator before the close.
		//
		// ω-objectlit-source-inter-sep: additionally capture per-
		// iteration into `_sepAfter` for the per-element
		// `Trivial.sepAfter` slot. The writer's trivia-branch sep gate
		// (`TriviaSepLowering.triviaSepStarExpr`) consults this to suppress inter-
		// element seps the source intentionally omitted
		// (lineends/issue_111). Sep-less Stars push `sepAfter: true`
		// (default declared just inside the loop body) so the writer's
		// always-emit branch fires unchanged.
		// ω-blockended-trivia (Session 3): Stars carrying
		// `@:sep('text', tailRelax, blockEnded)` keep the existing
		// matchLit-permissive sep loop on the parser side — sep is
		// optional, source-fidelity flows through `_sepAfter` to the
		// per-element wrapper. The `blockEnded` flag controls
		// WRITER-side sep emission (suppress `;` when prior ends with
		// `}` or `;`). Trying to enforce strict expectLit-on-miss here
		// fails on shapes like `if (c) return;` where the inner stmt's
		// own `;` was already consumed by an inner `@:trail(';')` /
		// embedded VoidReturnStmt — the byte at `_prevEndPos - 1` is
		// `;` not `}`. Permissive parser keeps backwards-compatibility
		// with the old per-stmt-@:trailOpt model byte-for-byte.
		final blockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		final sepMatchExpr: Expr = buildTriviaCloseSepMatchExpr(sepText, trailPresentLocal);
		// ω-trivia-trailing-before-sep: capture trailing same-line comment
		// BEFORE the optional sep-match. Source shape `elem /*c*/, next`
		// would break sep-match (`,` not found after h-ws skip stops
		// at `/`) and then `collectTrailing` consumed `/*c*/` AFTER the
		// failed sep-match — the `,` was never matched and the next
		// iteration's element parse failed on `,`. Reorder: first probe
		// `collectTrailing` (rewinds on miss), then run sep-match. The
		// post-sep `collectTrailing` still fires when the source carried
		// the trailing after the sep (`elem, // c\n`) — covered by the
		// `_trailingBeforeSep == null && _sepAfter` gate so we don't
		// double-capture.
		parseSteps.push(
			buildTriviaCloseLoopBody(elemCT, elemCall, accumRef, terminationCheck, sepMatchExpr, trailBBLocal, trailNLLocal, trailLCLocal)
		);
		if (closeText == null) return;
		parseSteps.push(macro skipWs(ctx));
		parseSteps.push(macro expectLit(ctx, $v{closeText}));
		// ω-close-trailing: capture a same-line trailing comment sitting
		// right after the close literal (e.g. `} // catch` before the
		// next `catch` clause). Stored in a synth `<field>TrailingClose`
		// slot on the paired Seq type; the writer emits
		// `trailingCommentDocVerbatim(...)` after the close when non-
		// null. ω-trailing-block-style: captured via `collectTrailingFull`
		// (content WITH delimiters) so block-style trailing comments
		// round-trip as `/* foo */`, not as `// foo`. EOF mode and
		// try-parse mode have no close literal and skip this capture
		// entirely.
		final trailCloseLocal: String = trailingCloseLocalName(localName);
		final nullStrCT: ComplexType = TPath({
			pack: [],
			name: 'Null',
			params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
		});
		parseSteps.push({
			expr: EVars([
				{
					name: trailCloseLocal,
					type: nullStrCT,
					expr: macro collectTrailingFull(ctx),
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
	}

	// -------- terminal rule --------

	private function lowerTerminal(node: ShapeNode, typePath: String, simple: String): Expr {
		final stringEnumValues: Null<Array<{ name: String, value: String }>> = node.annotations['base.stringEnumValues'];
		if (stringEnumValues != null) return lowerStringEnumTerminal(typePath, simple, stringEnumValues);
		final pattern: Null<String> = node.annotations['re.pattern'];
		if (pattern == null) {
			Context.fatalError('Lowering: terminal $typePath missing @:re', Context.currentPos());
			throw 'unreachable';
		}
		final underlying: String = node.annotations['base.underlying'];
		final eregVar: String = '_re_$simple';
		_eregByRule[typePath] = { varName: eregVar, pattern: pattern };

		// `@:rawString` on a String-underlying Terminal means "the regex
		// match is already the raw value" — skip decoding entirely. Used
		// for identifier-like terminals (Haxe `HxIdentLit`) where the
		// matched slice IS the identifier text.
		final raw: Bool = node.hasMeta(':rawString');

		final decodeExpr: Expr = lowerTerminalDecodeExpr(node, typePath, underlying, raw);

		// `@:captureGroup(N)` (N >= 1) picks the Nth capture group as the
		// stored value — position still advances by the full `matched(0)`
		// length, so any prefix matched but not stored (leading ws, style
		// markers like `* ` in a `/*...*/` body) is consumed. Default (no
		// meta) keeps the whole match as both stored value and advance
		// amount, preserving the existing behaviour for every other
		// terminal.
		final captureGroup: Null<Int> = node.annotations['re.captureGroup'];
		final matchedValueExpr: Expr = captureGroup == null ? macro $i{eregVar}.matched(0) : macro $i{eregVar}.matched($v{captureGroup});
		final advanceLenExpr: Expr = captureGroup == null ? macro _matched.length : macro $i{eregVar}.matched(0).length;
		// ω-terminal-anchor-guard: `EReg.match` returns true even when the
		// regex matches mid-string (the `^` anchor binds only to the FIRST
		// alternative without an explicit non-capturing group — `^A|B` ≡
		// `(^A)|B`, so the second alt silently scans the rest of input for
		// an arbitrary match). Caught by the `HxFloatLit` regex
		// extension: `^[0-9]+\.[0-9]+|[0-9]+\.(?![\w.])` matched `1.` mid-
		// buffer when the parser was sitting at an ident, overwriting the
		// ident's position with the float slice. Defensive runtime check
		// rejects any match that did not start at position 0 of `_rest` —
		// `matchedPos().pos != 0` ⇒ same `ParseError` as `!match`. Cheap
		// (one extra accessor call per terminal hit), universal (every
		// `@:re`-driven terminal gets it), and catches the bug class
		// instead of patching individual regexes after they leak into a
		// slice's sweep delta.
		return macro {
			final _rest: String = ctx.input.substring(ctx.pos, ctx.input.length);
			if (!$i{eregVar}.match(_rest) || $i{eregVar}.matchedPos().pos != 0) {
				ctx.recordFail(ctx.pos, $v{simple});
				throw anyparse.runtime.ParseError.backtrack;
			}
			final _matched: String = $matchedValueExpr;
			ctx.pos += $advanceLenExpr;
			return $decodeExpr;
		};
	}

	/**
	 * Lower an `enum abstract(String)` terminal — parses the format's
	 * string literal, then dispatches to the matching enum value via a
	 * macro-time switch over the declared `name → value` pairs. Unknown
	 * strings raise a `ParseError`. No regex is registered — the value
	 * set is closed at compile time, so a literal switch is both faster
	 * and cleaner than an `EReg` alternation.
	 */
	private function lowerStringEnumTerminal(typePath: String, simple: String, values: Array<{ name: String, value: String }>): Expr {
		final stringType: Null<String> = _formatInfo.stringType;
		if (stringType == null) {
			Context.fatalError(
				'Lowering: enum-abstract(String) terminal $typePath requires the format ${_formatInfo.schemaTypePath}'
				+ ' to declare stringType',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final pack: Array<String> = packOf(typePath);
		final errMsg: String = 'invalid $simple value';
		final cases: Array<Case> = [
			for (v in values)
				{
					values: [{ expr: EConst(CString(v.value)), pos: Context.currentPos() }],
					expr: MacroStringTools.toFieldExpr(pack.concat([simple, v.name])),
				}
		];
		final defaultExpr: Expr = macro throw new anyparse.runtime.ParseError(
			new anyparse.runtime.Span(_errPos, ctx.pos), $v{errMsg} + ': "' + _matched + '"'
		);
		final switchExpr: Expr = { expr: ESwitch(macro _matched, cases, defaultExpr), pos: Context.currentPos() };
		final stringFn: String = 'parse${simpleName(stringType)}';
		final stringCall: Expr = { expr: ECall(macro $i{stringFn}, [macro ctx]), pos: Context.currentPos() };
		return macro {
			skipWs(ctx);
			final _errPos: Int = ctx.pos;
			final _matched: String = $stringCall;
			return $switchExpr;
		};
	}

	/**
	 * True when the struct node should be lowered as a key-dispatched
	 * (ByName) object. Two conditions must hold: the resolved format
	 * has `fieldLookup == ByName` and no field on the struct carries
	 * positional metadata (`@:kw`, `@:lead`, `@:trail`, `@:sep`) or
	 * binary metadata. The positional Haxe grammar uses anchors to
	 * describe fixed syntax — those structs stay on the original
	 * positional codepath even though `HaxeFormat` also declares
	 * `ByName`. Binary schemas never reach this branch (`isBinary`
	 * short-circuits `fieldLookup` to a non-ByName default inside
	 * `FormatReader`).
	 */
	private function shouldLowerByName(node: ShapeNode): Bool {
		if (_formatInfo.isBinary) return false;
		if (_formatInfo.fieldLookup != ByName) return false;
		if (_formatInfo.keySyntax != Quoted) return false;
		if (node.annotations['bin.magic'] != null) return false;
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
	 * Lower a typedef struct as a JSON-style key-dispatched object. The
	 * generated body emits one `Null<T>` local per field, then runs a
	 * loop that reads `"key"`, dispatches to the matching field's
	 * parser, and finally materialises the struct literal. Unknown keys
	 * are routed by the format's `onUnknown` policy — `Skip` silently
	 * consumes the value via `_skipJsonValue`, `Error` raises a
	 * `ParseError` naming the offending key. Non-optional fields are
	 * checked for null after the loop and raise `ParseError` listing
	 * the missing name; optional fields retain their `null` default.
	 */
	private function lowerStructByName(node: ShapeNode): Expr {
		final structFields: Array<ObjectField> = [];
		final declareLocals: Array<Expr> = [];
		final switchCases: Array<Case> = [];
		final missingChecks: Array<Expr> = [];
		for (child in node.children) {
			final fieldName: Null<String> = child.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
			if (fieldName == null) Context.fatalError('Lowering: ByName struct field missing base.fieldName', Context.currentPos());
			final isOptional: Bool = child.annotations.get(AnnotationKeys.BASE_OPTIONAL) == true;
			final fieldCT: Null<ComplexType> = child.annotations.get(AnnotationKeys.BASE_FIELD_TYPE);
			if (fieldCT == null)
				Context.fatalError('Lowering: ByName struct field "$fieldName" missing base.fieldType', Context.currentPos());
			final localName: String = '_f_$fieldName';
			final localCT: ComplexType = isOptional ? fieldCT : TPath({ pack: [], name: 'Null', params: [TPType(fieldCT)] });
			declareLocals.push({
				expr: EVars([
					{
						name: localName,
						type: localCT,
						expr: macro null,
						isFinal: false
					}
				]),
				pos: Context.currentPos(),
			});
			final parseCall: Expr = byNameFieldParseExpr(child, fieldName);
			switchCases.push({
				values: [{ expr: EConst(CString(fieldName)), pos: Context.currentPos() }],
				expr: macro $i{localName} = $parseCall,
			});
			if (isOptional) {
				structFields.push({ field: fieldName, expr: macro $i{localName} });
			} else {
				final errMsg: String = 'missing required field "$fieldName"';
				final checkedName: String = '_r_$fieldName';
				// Two-step unwrap: the `if (... == null) throw` narrows the
				// local in the subsequent statement, and the `final` re-bind
				// produces a non-null local that the struct literal can
				// consume without tripping the object-literal inference
				// collapsing back to Null<T>.
				missingChecks.push(macro {
					if ($i{localName} == null)
						throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{errMsg});
				});
				missingChecks.push({
					expr: EVars([
						{
							name: checkedName,
							type: fieldCT,
							expr: macro $i{localName},
							isFinal: true,
						}
					]),
					pos: Context.currentPos(),
				});
				structFields.push({ field: fieldName, expr: macro $i{checkedName} });
			}
		}
		final defaultExpr: Expr = switch _formatInfo.onUnknown {
			case Skip:
				final anyType: Null<String> = _formatInfo.anyType;
				if (anyType == null) {
					Context.fatalError(
						'Lowering: UnknownPolicy.Skip requires the format ${_formatInfo.schemaTypePath}'
						+ ' to declare anyType (the universal-value grammar type used to consume unknown keys)',
						Context.currentPos()
					);
					throw 'unreachable';
				}
				final anyFn: String = 'parse${simpleName(anyType)}';
				macro {
					$i{anyFn}(ctx);
				};
			case Error: macro throw new anyparse.runtime.ParseError(
				new anyparse.runtime.Span(ctx.pos, ctx.pos), 'unknown field: "' + _key + '"'
			);
			case _:
				Context.fatalError(
					'Lowering: UnknownPolicy.Store is not supported in ByName mode (schema ${_formatInfo.schemaTypePath})',
					Context.currentPos()
				);
				throw 'unreachable';
		};
		final switchExpr: Expr = { expr: ESwitch(macro _key, switchCases, defaultExpr), pos: Context.currentPos() };
		final structLiteral: Expr = { expr: EObjectDecl(structFields), pos: Context.currentPos() };
		// The field locals sit ahead of the shared mapping loop — pure
		// null-init declarations, so their position relative to the open
		// literal is unobservable.
		final parseSteps: Array<Expr> = declareLocals;
		parseSteps.push(byNameMappingLoopExpr('ByName struct parsing', '_key', switchExpr));
		for (c in missingChecks) parseSteps.push(c);
		parseSteps.push(macro return $structLiteral);
		return macro $b{parseSteps};
	}

	private function byNameFieldParseExpr(child: ShapeNode, fieldName: String): Expr {
		return switch child.kind {
			case Ref:
				final refName: String = child.annotations[AnnotationKeys.BASE_REF];
				final fnName: String = parseFnName(refName);
				{ expr: ECall(macro $i{fnName}, [macro ctx]), pos: Context.currentPos() };
			case Star:
				child.annotations.exists(AnnotationKeys.BASE_MAP_VALUE)
					? byNameMapParseExpr(child, fieldName)
					: byNameStarParseExpr(child, fieldName);
			case _:
				Context.fatalError(
					'Lowering: ByName struct field "$fieldName" has unsupported kind ${child.kind}'
					+ ' — format ${_formatInfo.schemaTypePath} may be missing a primitive type mapping',
					Context.currentPos()
				);
				throw 'unreachable';
		};
	}

	/**
	 * Emit the parse expression for a `ByName` struct field whose type is
	 * `Array<T>`. Walks `formatInfo.sequenceOpen` / `entrySep` /
	 * `sequenceClose` to drive the loop. Inner element parsing routes
	 * through the Ref case's helpers (`parseFnName` + `ruleReturnCT`),
	 * picking up trivia-bearing paths and JSON primitive rewrites
	 * (`Array<HxFormatWrapRule>` reads via `parseHxFormatWrapRule`,
	 * etc.).
	 *
	 * The accumulator local is typed against the field's declared
	 * element type (extracted from `base.fieldType`) rather than the
	 * inner Ref's rewrite target, so primitive-rewrite cases — where
	 * the schema declares `Array<Int>` but the inner Ref points at
	 * `anyparse.grammar.json.JIntLit` — keep the schema's invariant
	 * `Array<Int>` shape and rely on the abstract's `from Int to Int`
	 * conversion at each `push`.
	 *
	 * The element shape must be a single `Ref` child; nested `Star` is
	 * deferred until a real schema needs `Array<Array<T>>`.
	 */
	private function byNameStarParseExpr(child: ShapeNode, fieldName: String): Expr {
		final seqOpen: Null<String> = _formatInfo.sequenceOpen;
		final seqClose: Null<String> = _formatInfo.sequenceClose;
		if (seqOpen == null || seqClose == null) {
			Context.fatalError(
				'Lowering: ByName Array<T> field "$fieldName" requires the format ${_formatInfo.schemaTypePath} '
				+ 'to declare sequenceOpen / sequenceClose',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		if (child.children.length != 1) {
			Context.fatalError(
				'Lowering: ByName Array<T> field "$fieldName" expected exactly one element child, got ${child.children.length}',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final inner: ShapeNode = child.children[0];
		if (inner.kind != Ref) {
			Context.fatalError(
				'Lowering: ByName Array<T> field "$fieldName" element kind ${inner.kind} is not supported '
				+ '— only Array<RefType> (a single named element type) is implemented',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final refName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final fnName: String = parseFnName(refName);
		final fieldCT: Null<ComplexType> = child.annotations[AnnotationKeys.BASE_FIELD_TYPE];
		final innerCT: ComplexType = extractArrayElementCT(fieldCT) ?? ruleReturnCT(refName);
		final closeCharCode: Int = seqClose.charCodeAt(0);
		final entrySep: String = _formatInfo.entrySep;
		return macro {
			final _arr: Array<$innerCT> = [];
			skipWs(ctx);
			expectLit(ctx, $v{seqOpen});
			skipWs(ctx);
			if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
				while (true) {
					skipWs(ctx);
					_arr.push($i{fnName}(ctx));
					skipWs(ctx);
					if (!matchLit(ctx, $v{entrySep})) break;
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{seqClose});
			_arr;
		};
	}

	/**
	 * Parse expression for a ByName `Map<String, V>` field — the
	 * arbitrary-key counterpart of `byNameStarParseExpr`. Emits the
	 * SHARED `byNameMappingLoopExpr` skeleton (the same one
	 * `lowerStructByName` uses, so the two mapping dialects cannot
	 * drift), storing every entry under the key it just parsed instead
	 * of dispatching on a declared field name. The value rule comes
	 * from the Star's single Ref child, exactly like the Array twin;
	 * the accumulator is typed against the schema-DECLARED value type
	 * when extractable (paired-type symmetry with
	 * `extractArrayElementCT`). Parse-only: the ByName WRITER path
	 * fatal-errors on a Map field (see `byNameFieldWriteExpr`).
	 */
	private function byNameMapParseExpr(child: ShapeNode, fieldName: String): Expr {
		final inner: ShapeNode = child.children[0];
		if (inner.kind != Ref) {
			Context.fatalError(
				'Lowering: ByName Map<String, V> field "$fieldName" value kind ${inner.kind} is not supported '
				+ '— only Map<String, RefType> (a single named value type) is implemented',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final refName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final valueFn: String = parseFnName(refName);
		final fieldCT: Null<ComplexType> = child.annotations[AnnotationKeys.BASE_FIELD_TYPE];
		final valueCT: ComplexType = extractMapValueCT(fieldCT) ?? ruleReturnCT(refName);
		final loop: Expr = byNameMappingLoopExpr(
			'ByName Map<String, V> field "$fieldName"', '_mapKey', macro {
				_map[_mapKey] = $i{valueFn}(ctx);
			}
		);
		return macro {
			final _map: Map<String, $valueCT> = [];
			$loop;
			_map;
		};
	}

	/**
	 * The one ByName mapping-loop skeleton: `skipWs; expectLit(open);
	 * [empty-mapping short-circuit; loop: key via the format's
	 * `stringType` parser bound to `<keyLocal>`, expectLit(keyValueSep),
	 * <perEntry>, matchLit(entrySep) or break]; skipWs;
	 * expectLit(close)`. Both ByName consumers — the fixed-field struct
	 * dispatch (`lowerStructByName`) and the arbitrary-key Map field
	 * (`byNameMapParseExpr`) — splice THIS skeleton with only the
	 * per-entry statement differing, so key / separator / close /
	 * trailing-sep semantics cannot drift between the two dialects.
	 * `site` names the caller for the stringType diagnostic.
	 */
	private function byNameMappingLoopExpr(site: String, keyLocal: String, perEntry: Expr): Expr {
		final stringType: Null<String> = _formatInfo.stringType;
		if (stringType == null) {
			Context.fatalError(
				'Lowering: $site requires the format ${_formatInfo.schemaTypePath} '
				+ 'to declare stringType (the grammar type used to parse mapping keys)',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		final keyFn: String = 'parse${simpleName(stringType)}';
		final keyDecl: Expr = {
			expr: EVars([
				{
					name: keyLocal,
					type: macro :String,
					expr: { expr: ECall(macro $i{keyFn}, [macro ctx]), pos: Context.currentPos() },
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		};
		final mappingOpen: String = _formatInfo.mappingOpen;
		final mappingClose: String = _formatInfo.mappingClose;
		final keyValueSep: String = _formatInfo.keyValueSep;
		final entrySep: String = _formatInfo.entrySep;
		final closeCharCode: Int = mappingClose.charCodeAt(0);
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{mappingOpen});
			skipWs(ctx);
			if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
				while (true) {
					skipWs(ctx);
					$keyDecl;
					skipWs(ctx);
					expectLit(ctx, $v{keyValueSep});
					skipWs(ctx);
					$perEntry;
					skipWs(ctx);
					if (!matchLit(ctx, $v{entrySep})) break;
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{mappingClose});
		};
	}

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

	private function lowerTerminalDecodeExpr(node: ShapeNode, typePath: String, underlying: String, raw: Bool): Expr {
		// `@:unescape` on a Terminal abstract generates an inline
		// walk-and-unescape loop using the `@:schema` format's
		// `unescapeChar`. Bare `@:unescape` strips surrounding quotes
		// first; `@:unescape("raw")` and `@:unescape("singleQuoteRaw")`
		// both use the matched string as-is (no quote strip) — they
		// differ only in writer-side escape table (see WriterLowering).
		final unescape: Bool = node.hasMeta(':unescape');
		final unescapeMode: Null<String> = node.readMetaString(':unescape');

		// `@:decode("pkg.Class.method")` on a Terminal abstract names a
		// static function that decodes the matched string into the
		// terminal's underlying type. The path is split on `.` and
		// emitted as `pkg.Class.method(_matched)`.
		final decodePath: Null<String> = node.readMetaString(':decode');

		if (unescape && decodePath != null)
			Context.fatalError('Lowering: terminal $typePath has both @:unescape and @:decode', Context.currentPos());
		if (unescape && raw) Context.fatalError('Lowering: terminal $typePath has both @:unescape and @:rawString', Context.currentPos());

		if (unescape) {
			final fmtParts: Array<String> = _formatInfo.schemaTypePath.split('.');
			final bodyExpr: Expr = if (unescapeMode == 'raw' || unescapeMode == 'singleQuoteRaw')
				macro _matched
			else
				macro _matched.substring(1, _matched.length - 1);
			return macro {
				final _body: String = $e{bodyExpr};
				final _buf: StringBuf = new StringBuf();
				var _i: Int = 0;
				while (_i < _body.length) {
					final _c: Int = StringTools.fastCodeAt(_body, _i);
					if (_c == '\\'.code) {
						final _res: anyparse.format.text.TextFormat.UnescapeResult = $p{fmtParts}.instance.unescapeChar(_body, _i + 1);
						_buf.addChar(_res.char);
						_i += 1 + _res.consumed;
					} else {
						_buf.addChar(_c);
						_i++;
					}
				}
				_buf.toString();
			};
		}
		if (decodePath == null) return switch underlying {
			case 'Float': macro Std.parseFloat(_matched);
			case 'Int':
				macro {
					final _v: Null<Int> = Std.parseInt(_matched);
					if (_v == null) {
						throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), 'invalid int literal');
					}
					_v;
				};
			case 'Bool': macro _matched == 'true';
			case 'String' if (raw): macro _matched;
			case 'String':
				Context.fatalError(
					'Lowering: String terminal $typePath requires @:unescape, @:decode, or @:rawString', Context.currentPos()
				);
				throw 'unreachable';
			case _:
				Context.fatalError('Lowering: no decoder for underlying type "$underlying"', Context.currentPos());
				throw 'unreachable';
		};
		final parts: Array<String> = decodePath.split('.');
		return { expr: ECall(macro $p{parts}, [macro _matched]), pos: Context.currentPos() };
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
	 * NOT covered, both stable fixed points — cosmetic, not canonical-gate
	 * breakers — and both left alone here:
	 *
	 *  - a CLOSING delimiter proves interiority just as an operator does, and
	 *    those commits do not clear (`{k: (foo\n), m: 2}` still breaks before
	 *    `m`);
	 *  - the postfix loop clears at the matched iteration's TAIL, so a stash the
	 *    RECEIVER left is still live while the suffix's own payload parses and a
	 *    container the payload opens can drain it (`(foo\n)[{k: 1, m: 2}]`
	 *    breaks the index literal). Clearing before `$opChain` instead is NOT
	 *    the fix — `gapNewline` reads the flag inside the match expression, and
	 *    a genuine boundary the receiver stashed (`try f() catch (_) {}` then an
	 *    own-line `#if`) is unrecoverable by the no-match scanback, whose
	 *    `_preWsPos` already sits past the newline. Closing it means threading
	 *    the pre-clear value through every postfix branch builder.
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

	private function buildPrattBranchBody(branch: ShapeNode, typePath: String, simple: String, skipCall: Expr): Expr {
		// noqa: complexity
		final returnCT: ComplexType = ruleReturnCT(typePath);
		final loopFnName: String = parseFnName(typePath);
		final ctor: String = branch.annotations[AnnotationKeys.BASE_CTOR];
		final ctorPath: Array<String> = ruleCtorPath(typePath, ctor);
		final ctorRef: Expr = MacroStringTools.toFieldExpr(ctorPath);
		final isTernary: Bool = branch.annotations[AnnotationKeys.TERNARY_OP] != null;
		final opText: String = getOperatorText(branch);
		final precValue: Int = isTernary
			? (branch.annotations[AnnotationKeys.TERNARY_PREC]: Int)
			: (branch.annotations[AnnotationKeys.PRATT_PREC]: Int);
		return if (isTernary) {
			// Ternary branch: three operands (cond, middle, right).
			// Both middle and right parse at minPrec=0 (full expression).
			final sepText: String = branch.annotations[AnnotationKeys.TERNARY_SEP];
			final fullExprCall: Expr = {
				expr: ECall(macro $i{loopFnName}, [macro ctx, macro $v{0}]),
				pos: Context.currentPos(),
			};
			// ω-keep-ternary-operand-comment: `@:fmt(captureTernaryTrail)` grows
			// two operand-trailing slots. The CONDITION's comment is already in
			// scope as the Pratt loop's `_opTrailComment` (collected before the
			// `?` matched, and restored by the no-match rewind when this branch
			// declines); the THEN branch's is collected right after its operand
			// parse, before `$skipCall` stashes it into `pendingTrivia` where it
			// would leak out and be re-emitted below the whole statement.
			// Both styles are accepted: unlike the infix RHS slot there is no
			// enclosing chain that could own the comment — the mandatory `:` /
			// the ternary's own end bound it.
			final captureTernaryTrail: Bool = _ctx.trivia && branch.fmtHasFlag('captureTernaryTrail');
			final ctorArgs: Array<Expr> = [macro left, macro _middle, macro _right];
			if (captureTernaryTrail) {
				ctorArgs.push(macro _opTrailComment);
				ctorArgs.push(macro _thenTrailComment);
			}
			final ctorCall: Expr = {
				expr: ECall(ctorRef, ctorArgs),
				pos: Context.currentPos(),
			};
			final thenTrailCapture: Expr = captureTernaryTrail
				? macro final _thenTrailComment: Null<String> = collectTrailingFull(ctx)
				: macro {};
			final clearStashNl: Expr = stashNewlineClearExpr();
			macro {
				if ($v{precValue} < minPrec) {
					ctx.pos = _savedPos;
					_matched = false;
				} else {
					$clearStashNl;
					$skipCall;
					final _middle: $returnCT = $fullExprCall;
					$thenTrailCapture;
					$skipCall;
					expectLit(ctx, $v{sepText});
					$skipCall;
					// The separator is the ternary's SECOND operator commit — the middle
					// operand's own loop exit can have stashed the gap before it.
					$clearStashNl;
					final _right: $returnCT = $fullExprCall;
					left = $ctorCall;
				}
			};
		} else {
			// Binary infix branch: two operands (left, right). The right
			// operand normally recurses into the same Pratt loop at an
			// elevated minPrec to enforce associativity. When the right
			// child references a different enum than the loop's own
			// (asymmetric infix, e.g. `x is Type` where left:HxExpr but
			// right:HxType), recursing into the same loop is wrong — call
			// the other type's parse function once at its default starting
			// precedence and let outer Pratt iteration handle chaining.
			final assocValue: String = branch.annotations[AnnotationKeys.PRATT_ASSOC];
			final nextMinPrec: Int = assocValue == 'Right' ? precValue : precValue + 1;
			final rightChildren: Array<ShapeNode> = branch.children;
			final rightChild: ShapeNode = rightChildren[1];
			final rightRef: Null<String> = rightChild.kind == Ref ? rightChild.annotations[AnnotationKeys.BASE_REF] : null;
			final isAsymmetric: Bool = rightRef != null && simpleName(rightRef) != simple;
			final rightCT: ComplexType = isAsymmetric ? ruleReturnCT(rightRef) : returnCT;
			final rightCall: Expr = if (isAsymmetric)
				{ expr: ECall(macro $i{parseFnName(rightRef)}, [macro ctx]), pos: Context.currentPos(), }
			else
				{ expr: ECall(macro $i{loopFnName}, [macro ctx, macro $v{nextMinPrec}]), pos: Context.currentPos(), };
			// ω-keep-chain (increment 2): in Trivia mode, infix ctors carrying
			// `@:fmt(captureChainNewline)` (the chain ctors Add/Sub/And/Or)
			// grow a 3rd positional `chainNewline:Bool` synth arg holding
			// whether the source had a newline anywhere in the gap before
			// this ctor's RIGHT operand. Two sources:
			//  (1) `hasNewlineIn(ctx.input, _preWsPos, ctx.pos)` — the gap
			//      [before-op .. after-op-WS] scan. Correct whenever the gap
			//      newline is NOT pre-consumed by a higher-prec left-operand
			//      recursion (covers `a +\n b` and any chain whose left
			//      operand is an atom).
			//  (2) `ctx.pendingTrivia.newlineBefore` (boolean OR, `&&`/`||`
			//      ONLY) — when the left operand is itself an infix sub-expr
			//      (`X == Y && …`), its right-operand recursion's no-match
			//      already CONSUMED the `\n` before this operator and stashed
			//      the signal into pendingTrivia (the ω-untyped-keep stash),
			//      so the span scan misses it. Scoped to the boolean
			//      operators because their operands are routinely
			//      higher-precedence comparisons that pre-consume the gap;
			//      `+`/`-` keep relies on the span scan alone to avoid the
			//      head-leading-newline pollution that the stash carries when
			//      an additive chain is the head of a freshly-opened paren
			//      (`!(\n a.y + b.h …`). The flag is cleared after the read so
			//      it does not leak to the next operand. O(1), no recursive
			//      probe. Plain mode keeps the 2-arg ctor (synth widens only
			//      in Trivia).
			final captureChainNl: Bool = _ctx.trivia && branch.fmtHasFlag('captureChainNewline');
			// ω-keep-infix-rhs-comment: capture a same-line comment trailing the
			// RIGHT operand (position #3 — before the enclosing `)`/`;`/`,`).
			final captureRhsTrail: Bool = _ctx.trivia && branch.fmtHasFlag('captureRhsTrail');
			final isBoolChainOp: Bool = opText == '&&' || opText == '||';
			final ctorArgs: Array<Expr> = [macro left, macro _right];
			if (captureChainNl) {
				ctorArgs.push(macro _chainNl);
				ctorArgs.push(macro _opTrailComment);
				ctorArgs.push(macro _opAfterComment);
			}
			if (captureRhsTrail) ctorArgs.push(macro _opRhsTrail);
			final ctorCall: Expr = { expr: ECall(ctorRef, ctorArgs), pos: Context.currentPos() };
			// `_chainNl` is declared in the commit block; the right-operand
			// parse + ctor build live in the SAME block so it stays in scope
			// for `$ctorCall`. Non-capturing branches keep the legacy body.
			final chainNlValue: Expr = isBoolChainOp
				? macro hasNewlineIn(ctx.input, _preWsPos, ctx.pos) || (ctx.pendingTrivia != null && ctx.pendingTrivia.newlineBefore)
				: macro hasNewlineIn(ctx.input, _preWsPos, ctx.pos);
			final commitParts: Array<Expr> = [];
			// ω-keep-infix-postop-comment: capture a same-line comment trailing the
			// operator (before the right operand) BEFORE `skipWsAndStash` stashes it
			// into pendingTrivia (where it leaks into the next operand's parse).
			if (captureChainNl) commitParts.push(macro final _opAfterComment: Null<String> = collectTrailingFull(ctx));
			commitParts.push(skipCall);
			if (captureChainNl) commitParts.push(macro final _chainNl: Bool = $chainNlValue);
			// AFTER the `_chainNl` read (`&&`/`||` consume the very flag this drops).
			commitParts.push(stashNewlineClearExpr());
			commitParts.push(macro final _right: $rightCT = $rightCall);
			// Restrict RHS-trail to BLOCK comments (`/* */`): a same-line LINE
			// comment after the operand belongs to an enclosing chain operator's
			// line-break slot (chainLeadComment) or the statement trailing slot —
			// stealing it here would collapse the chain and comment out the tail.
			// Block comments are inline-safe, so keep + rewind line comments.
			if (captureRhsTrail) {
				commitParts.push(macro final _savedRhsPos: Int = ctx.pos);
				commitParts.push(macro final _rhsRaw: Null<String> = collectTrailingFull(ctx));
				commitParts.push(
					macro final _opRhsTrail: Null<String> = _rhsRaw != null && StringTools.startsWith(_rhsRaw, '/*') ? _rhsRaw : null
				);
				commitParts.push(macro if (_opRhsTrail == null) ctx.pos = _savedRhsPos);
			}
			commitParts.push(macro left = $ctorCall);
			final commitBody: Expr = macro $b{commitParts};
			macro {
				if ($v{precValue} < minPrec) {
					ctx.pos = _savedPos;
					_matched = false;
				} else
					$commitBody;
			};
		};
	}

	private function buildPrattLoopExpr(returnCT: ComplexType, atomCall: Expr, opChain: Expr, ?wordOps: Array<String>): Expr {
		// ω-trivia-sep: in Trivia mode, save pos BEFORE the per-iteration
		// `skipWs`. On no-match, scan the consumed range for comment
		// markers — if any are present, rewind to preserve the comment
		// for a sibling's `collectTrailing` capture (otherwise `field: ""
		// // some comment` loses its trailing comment). Plain whitespace
		// and `\n` stay consumed so `@:raw` siblings (e.g. `${expr}` in
		// string interp, where the trailing literal expects `}` directly
		// without skipWs) keep working: no comment → no rewind.
		// ω-pratt-comment-stash: outer per-iter skipWs swaps to skipWsAndStash
		// so comments BEFORE an operator (`a /* c */ + b`) get captured into
		// `pendingTrivia` when an op matches. On no-match rewind, the
		// captured comments must also be popped from the stash — otherwise
		// the caller's collectTrivia sees them AND re-captures from input,
		// duplicating. `_stashCount0` snapshot lets us truncate.
		final noMatch: Expr = buildPrattNoMatchHandlerExpr();
		return _ctx.trivia
			? macro {
				var left: $returnCT = $atomCall;
				while (true) {
					final _preWsPos: Int = ctx.pos;
					// ω-keep-infix-operand-comment: capture the left operand's
					// same-line trailing comment before `skipWsAndStash` consumes it,
					// mirroring the postfix loop's receiver-comment capture. Position-
					// inert — collectTrailingFull rewinds when there is no comment, and
					// on no operator match the `_hadComment` rewind (scanning from
					// `_preWsPos`) restores a consumed comment; only a matched chain
					// ctor reads it into its chainLeadComment slot.
					final _opTrailComment: Null<String> = collectTrailingFull(ctx);
					final _stashCount0: Int = ctx.pendingTrivia == null ? 0 : ctx.pendingTrivia.leadingComments.length;
					skipWsAndStash(ctx);
					final _savedPos: Int = ctx.pos;
					var _matched: Bool = true;
					$opChain;
					$noMatch;
				}
				return left;
			}
			: macro {
				var left: $returnCT = $atomCall;
				while (true) {
					// ω-cond-splice: save BEFORE skipWs and restore on no-match
					// ONLY when a word-like op (`#if` splice dispatch) is the
					// next token — an ENCLOSING atom's postfix loop reads the
					// operand↔`#if` gap for its same-line gate, and an inner
					// loop that consumed the newline on its way out would blind
					// it. The restore is CONDITIONAL because `@:raw` siblings
					// (`${expr}` string interpolation) expect the whitespace
					// consumed — an unconditional restore breaks them.
					final _preWsPos: Int = ctx.pos;
					skipWs(ctx);
					final _savedPos: Int = ctx.pos;
					var _matched: Bool = true;
					$opChain;
					if (!_matched) {
						${buildWordOpRestoreExpr(wordOps)};
						break;
					}
				}
				return left;
			};
	}

	private function buildPrattNoMatchHandlerExpr(): Expr {
		return macro if (!_matched) {
			var _scanI: Int = _preWsPos;
			var _hadComment: Bool = false;
			var _hadNewline: Bool = false;
			// ω-keep-pratt-blank: track a blank line (≥2 newlines with
			// only horizontal whitespace between them) inside the
			// Pratt-consumed run, mirroring `collectTrivia`'s `_nl >= 2`
			// semantics so the source-blank signal survives the no-op
			// tail loop the same way the single-newline signal does.
			var _nlRun: Int = 0;
			var _hadBlank: Bool = false;
			while (_scanI < ctx.pos) {
				final _ch: Int = ctx.input.charCodeAt(_scanI);
				if (_ch == '\n'.code) {
					_hadNewline = true;
					_nlRun++;
					if (_nlRun >= 2) _hadBlank = true;
				} else if (_ch != ' '.code && _ch != '\t'.code && _ch != '\r'.code) {
					_nlRun = 0;
				}
				if (_ch == '/'.code && _scanI + 1 < ctx.pos) {
					final _c2: Int = ctx.input.charCodeAt(_scanI + 1);
					if (_c2 == '/'.code || _c2 == '*'.code) {
						_hadComment = true;
						break;
					}
				}
				_scanI++;
			}
			if (_hadComment) {
				ctx.pos = _preWsPos;
				final _pt = ctx.pendingTrivia;
				if (_pt != null) {
					while (_pt.leadingComments.length > _stashCount0) _pt.leadingComments.pop();
				}
			} else if (_hadNewline) {
				// ω-untyped-keep: when no operator matches AND the consumed
				// WS contained a newline (no comment, no rewind), stash the
				// newline signal into `pendingTrivia` so the next sibling's
				// `collectTrivia` drain captures `newlineBefore=true`. Without
				// this, Pratt silently consumes the newline and downstream
				// `bodyBeforeNewline` slots never fire (e.g. function-body
				// `untyped` after `:Type\n\tuntyped {…}` — the body field's
				// pre-field collectTrivia sees pos already past the `\n`).
				// ω-keep-pratt-blank: also carry `blankBefore` when the run
				// held a blank line, so a `var b = function(){…}\n\nfinal a`
				// brace-terminated `@:trailOpt(';')`-absent decl preserves
				// its source blank line (issue_644). Without this the bit was
				// hardcoded `false` and the blank collapsed to a single `\n`.
				final _pt = ctx.pendingTrivia;
				if (_pt == null) {
					ctx.pendingTrivia = {
						blankBefore: _hadBlank,
						blankAfterLeadingComments: false,
						newlineBefore: true,
						leadingComments: [],
					};
				} else {
					_pt.newlineBefore = true;
					if (_hadBlank) _pt.blankBefore = true;
				}
			}
			break;
		};
	}

	private function buildOptKwStarLoopBody(
		elemCT: ComplexType, elemCall: Expr, isTriviaCollects: Bool, sepText: Null<String>, branchTrail: Bool, trailBBLocal: String,
		trailLCLocal: String
	): Expr {
		final hWsSkip: Expr = buildOptKwStarHWsSkipExpr();
		// ω-cond-comp-branch-trail: on the terminating parse failure at
		// `#end`/`#elseif`/`#else`, an orphan own-line comment (no blank-line
		// separator) belongs to THIS branch body — capture it into the trailing
		// slots and advance past it (mirror of the `nestBody` catch) instead of
		// rewind+discard. Gated on `branchTrail` (`@:fmt(padTrailing)`).
		final triviaCatch: Expr = branchTrail
			? macro {
				if (!_lead.blankBefore && _lead.leadingComments.length > 0) {
					$i{trailBBLocal} = _lead.blankBefore;
					$i{trailLCLocal} = _lead.leadingComments;
					ctx.pos = _afterTriviaPos;
				} else {
					ctx.pos = _savedPos;
				}
				break;
			}
			: macro {
				ctx.pos = _savedPos;
				break;
			};
		return if (isTriviaCollects && sepText != null)
			macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					final _lead = collectTrivia(ctx);
					final _afterTriviaPos: Int = ctx.pos;
					try {
						final _node: $elemCT = $elemCall;
						final _trailingBeforeSep: Null<String> = collectTrailingFull(ctx);
						var _sepAfter: Bool = false;
						$hWsSkip;
						_sepAfter = matchLit(ctx, $v{sepText});
						final _trailing: Null<String> = _trailingBeforeSep ?? (_sepAfter ? collectTrailingFull(ctx) : null);
						_items.push({
							blankBefore: _lead.blankBefore,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							trailingBeforeSep: _trailingBeforeSep != null,
							sepAfter: _sepAfter,
							node: _node,
						});
					} catch (_e: anyparse.runtime.ParseError)
						$triviaCatch;
				}
			}
		else if (isTriviaCollects)
			macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					final _lead = collectTrivia(ctx);
					final _afterTriviaPos: Int = ctx.pos;
					try {
						final _node: $elemCT = $elemCall;
						final _trailing: Null<String> = collectTrailingFull(ctx);
						_items.push({
							blankBefore: _lead.blankBefore,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							trailingBeforeSep: false,
							sepAfter: true,
							node: _node,
						});
					} catch (_e: anyparse.runtime.ParseError)
						$triviaCatch;
				}
			}
		else if (sepText != null)
			macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					try {
						skipWs(ctx);
						_items.push($elemCall);
						$hWsSkip;
						matchLit(ctx, $v{sepText});
					} catch (_e: anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
				}
			}
		else
			macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					try {
						skipWs(ctx);
						_items.push($elemCall);
					} catch (_e: anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
				}
			};
	}

	private function buildOptKwStarInnerCommit(hasKwTriviaSlots: Bool, afterKwLocal: String, bodyOnSameLineLocal: String): Expr {
		// Post-commit kw-trivia capture — mirrors the optional-Ref path.
		return hasKwTriviaSlots
			? macro {
				final _kwEndPos: Int = ctx.pos;
				$i{afterKwLocal} = collectTrailing(ctx);
				final _t = collectTrivia(ctx);
				$i{bodyOnSameLineLocal} = !hasNewlineIn(ctx.input, _kwEndPos, ctx.pos);
				// ω-cond-comp-elseBody-leading: route the own-line leading comments
				// after the kw into pendingTrivia so the body Star's first
				// collectTrivia attaches them to body[0] and emits them (the
				// kw-Leading slot is NOT emitted for kw-Star fields — only kw-Ref).
				// Mirrors the non-kw branch below; keeps the newline/blank signal.
				// ω-cond-comp-elseBody-pad-stash: propagate the post-kw
				// newline/blank signal forward so the loop's first-iteration
				// `collectTrivia` (which drains `ctx.pendingTrivia`) sees it
				// and sets `_arr[0].newlineBefore = true`. Without this stash
				// the writer's `_padHardline` switch (`triviaTryparseStarExpr`)
				// reads false on the first body element and `#else\nimport\n
				// #end` round-trips flat as `#else import #end`. Sister non-kw
				// branch below already does the equivalent stash; the kw
				// branch lacked the producer despite sharing the downstream
				// drainer (`Codegen.collectTriviaField`). leadingComments
				// drained into kwLeading above — re-stashing would emit them
				// twice (once attached to the kw, once on body[0]).
				if (_t.newlineBefore || _t.blankBefore || _t.blankAfterLeadingComments || _t.leadingComments.length > 0)
					ctx.pendingTrivia = _t;
			}
			: _ctx.trivia
				? macro {
					final _t = collectTrivia(ctx);
					if (_t.leadingComments.length > 0 || _t.blankBefore || _t.blankAfterLeadingComments || _t.newlineBefore)
						ctx.pendingTrivia = _t;
				}
				: macro skipWs(ctx);
	}

	private function buildOptKwStarHWsSkipExpr(): Expr {
		return macro while (ctx.pos < ctx.input.length) {
			final _hwc: Int = ctx.input.charCodeAt(ctx.pos);
			if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code)
				ctx.pos++;
			else
				break;
		};
	}

	private function buildTriviaTryparseSepBody(
		elemCT: ComplexType, elemCall: Expr, accumRef: Expr, sepText: String, trailPresentLocal: String, trailBBLocal: String,
		trailLCLocal: String, trailBALocal: String, nestBody: Bool
	): Expr {
		// ω-blockended-trivia-tryparse (Session 3): `@:tryparse +
		// @:sep(text, tailRelax, blockEnded)` fork — permissive matchLit
		// on sep. Element-parse failure rewinds + breaks via the try/catch.
		// nestBody keeps the orphan-trail capture on parse failure.
		return nestBody
			? macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					final _lead = collectTrivia(ctx);
					final _afterTriviaPos: Int = ctx.pos;
					try {
						final _node: $elemCT = $elemCall;
						final _trailingBeforeSep: Null<String> = collectTrailingFull(ctx);
						var _sepAfter: Bool = false;
						while (ctx.pos < ctx.input.length) {
							final _hwc: Int = ctx.input.charCodeAt(ctx.pos);
							if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code)
								ctx.pos++;
							else
								break;
						}
						_sepAfter = matchLit(ctx, $v{sepText});
						final _trailing: Null<String> = _trailingBeforeSep ?? (_sepAfter ? collectTrailingFull(ctx) : null);
						$i{trailPresentLocal} = _sepAfter;
						$accumRef.push({
							blankBefore: _lead.blankBefore,
							blankBefore2: _lead.blankBefore2,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							trailingBeforeSep: _trailingBeforeSep != null,
							sepAfter: _sepAfter,
							node: _node,
						});
					} catch (_e: anyparse.runtime.ParseError) {
						if (!_lead.blankBefore && _lead.leadingComments.length > 0) {
							$i{trailBBLocal} = _lead.blankBefore;
							$i{trailLCLocal} = _lead.leadingComments;
							$i{trailBALocal} = _lead.blankAfterLeadingComments;
							ctx.pos = _afterTriviaPos;
						} else {
							ctx.pos = _savedPos;
						}
						break;
					}
				}
			}
			: macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					final _lead = collectTrivia(ctx);
					try {
						final _node: $elemCT = $elemCall;
						final _trailingBeforeSep: Null<String> = collectTrailingFull(ctx);
						var _sepAfter: Bool = false;
						while (ctx.pos < ctx.input.length) {
							final _hwc: Int = ctx.input.charCodeAt(ctx.pos);
							if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code)
								ctx.pos++;
							else
								break;
						}
						_sepAfter = matchLit(ctx, $v{sepText});
						final _trailing: Null<String> = _trailingBeforeSep ?? (_sepAfter ? collectTrailingFull(ctx) : null);
						$i{trailPresentLocal} = _sepAfter;
						$accumRef.push({
							blankBefore: _lead.blankBefore,
							blankBefore2: _lead.blankBefore2,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							trailingBeforeSep: _trailingBeforeSep != null,
							sepAfter: _sepAfter,
							node: _node,
						});
					} catch (_e: anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
				}
			};
	}

	private function buildTriviaTryparseNoSepBody(
		elemCT: ComplexType, elemCall: Expr, accumRef: Expr, trailBBLocal: String, trailLCLocal: String, trailBALocal: String,
		nestBody: Bool, branchTrail: Bool
	): Expr {
		// Try-parse termination: each iteration saves `ctx.pos` before
		// `collectTrivia`, attempts the element parse, and rewinds to the
		// saved pos on failure so the captured trivia is fully uncaptured.
		// `@:fmt(nestBody)` Stars (case/default bodies) add a trailing-orphan
		// capture; the non-nestBody path carries the ω-keep-pratt-blank stash.
		if (nestBody) {
			return macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					final _lead = collectTrivia(ctx);
					final _afterTriviaPos: Int = ctx.pos;
					try {
						final _node: $elemCT = $elemCall;
						final _trailing: Null<String> = collectTrailingFull(ctx);
						$accumRef.push({
							blankBefore: _lead.blankBefore,
							blankBefore2: _lead.blankBefore2,
							blankAfterLeadingComments: _lead.blankAfterLeadingComments,
							newlineBefore: _lead.newlineBefore,
							leadingComments: _lead.leadingComments,
							trailingComment: _trailing,
							trailingBeforeSep: false,
							sepAfter: true,
							node: _node,
						});
					} catch (_e: anyparse.runtime.ParseError) {
						if (!_lead.blankBefore && _lead.leadingComments.length > 0) {
							$i{trailBBLocal} = _lead.blankBefore;
							$i{trailLCLocal} = _lead.leadingComments;
							$i{trailBALocal} = _lead.blankAfterLeadingComments;
							ctx.pos = _afterTriviaPos;
						} else {
							ctx.pos = _savedPos;
						}
						break;
					}
				}
			};
		}
		final nlAfterSepScan: Expr = buildPrattBlankNlAfterSepScan();
		final restoreStash: Expr = buildPrattBlankRestoreStash();
		// ω-cond-comp-branch-trail: for a `@:fmt(padTrailing)` conditional branch
		// body (no `#else` — the `#if` body Star before `#end`), capture the
		// orphan own-line trailing comment into the trail slots on the
		// terminating parse failure (mirror the nestBody branch) instead of
		// rewind+discard. Non-branchTrail Stars keep the plain rewind+stash.
		final nonNestCatch: Expr = branchTrail
			? macro {
				if (!_lead.blankBefore && _lead.leadingComments.length > 0) {
					$i{trailBBLocal} = _lead.blankBefore;
					$i{trailLCLocal} = _lead.leadingComments;
					ctx.pos = _leadStart;
				} else {
					ctx.pos = _savedPos;
					$restoreStash;
				}
				break;
			}
			: macro {
				ctx.pos = _savedPos;
				$restoreStash;
				break;
			};
		return macro {
			while (true) {
				final _savedPos: Int = ctx.pos;
				// ω-keep-pratt-blank: snapshot the incoming `pendingTrivia`
				// BEFORE `collectTrivia` drains it. On element-parse failure
				// the cursor rewinds to `_savedPos`, but `collectTrivia`
				// already nulled `pendingTrivia` — a stash-only blank-line
				// signal (left by a brace-terminated value's Pratt / postfix
				// no-op tail, living in bytes BEFORE `_savedPos` and NOT
				// re-scannable) would otherwise be lost. Restored on rollback
				// ONLY when the just-parsed value ended with `}`. See
				// `buildPrattBlankRestoreStash` for the brace-terminated rule.
				final _savedPending = ctx.pendingTrivia;
				final _lead = collectTrivia(ctx);
				// ω-keep-newline-after-sep (increment 1): `collectTrivia`
				// leaves the cursor at the element's first token — for a
				// `@:lead(LIT)`-prefixed link (e.g. `HxVarMore`'s
				// `@:lead(',')`) that token IS the separator literal.
				// Record it so we can probe the newline AFTER the
				// separator (before the link payload): `_lead.newlineBefore`
				// only sees the gap BEFORE the comma (usually empty —
				// `getRaw(read),`), while the source break the writer's
				// `Keep` wrap must reproduce lands `,\n  next`. Additive
				// (an `@:optional Trivial.newlineAfterSep` slot, read only
				// under `WrapMode.Keep`) → byte-inert for non-keep.
				final _leadStart: Int = ctx.pos;
				try {
					final _node: $elemCT = $elemCall;
					final _trailing: Null<String> = collectTrailingFull(ctx);
					var _nlAfterSep: Bool = false;
					$nlAfterSepScan;
					$accumRef.push({
						blankBefore: _lead.blankBefore,
						blankBefore2: _lead.blankBefore2,
						blankAfterLeadingComments: _lead.blankAfterLeadingComments,
						newlineBefore: _lead.newlineBefore,
						leadingComments: _lead.leadingComments,
						trailingComment: _trailing,
						trailingBeforeSep: false,
						sepAfter: true,
						newlineAfterSep: _nlAfterSep,
						node: _node,
					});
				} catch (_e: anyparse.runtime.ParseError)
					$nonNestCatch;
			}
		};
	}

	private function buildTriviaCloseTerminationCheck(closeText: Null<String>): Expr {
		if (closeText == null) return macro ctx.pos >= ctx.input.length;
		// See emitStarFieldSteps for why we flip to full-string `peekLit` when
		// close is multi-byte (single-byte peek false-positives when close's
		// first byte can legitimately appear inside element content).
		final closeCharCode: Int = closeText.charCodeAt(0);
		return closeText.length == 1
			? macro ctx.pos >= ctx.input.length || ctx.input.charCodeAt(ctx.pos) == $v{closeCharCode}
			: macro ctx.pos >= ctx.input.length || peekLit(ctx, $v{closeText});
	}

	private function buildTriviaCloseSepMatchExpr(sepText: Null<String>, trailPresentLocal: String): Expr {
		// ω-trivia-sep: when the trivia Star carries `@:sep`, an optional
		// separator is matched after each element. The pre-sep horizontal-
		// whitespace skip avoids consuming newlines / comments (`skipWs` would
		// swallow the trailing `// comment` before `collectTrailing` could see
		// it). Sep-less Stars get a no-op.
		return sepText != null
			? macro {
				while (ctx.pos < ctx.input.length) {
					final _hwc: Int = ctx.input.charCodeAt(ctx.pos);
					if (_hwc == ' '.code || _hwc == '\t'.code || _hwc == '\r'.code)
						ctx.pos++;
					else
						break;
				}
				_sepAfter = matchLit(ctx, $v{sepText});
				$i{trailPresentLocal} = _sepAfter;
			}
			: macro {};
	}

	private function buildTriviaCloseLoopBody(
		elemCT: ComplexType, elemCall: Expr, accumRef: Expr, terminationCheck: Expr, sepMatchExpr: Expr, trailBBLocal: String,
		trailNLLocal: String, trailLCLocal: String
	): Expr {
		// ω-trivia-trailing-before-sep: capture trailing same-line comment
		// BEFORE the optional sep-match. Source shape `elem /*c*/, next`
		// would break sep-match (`,` not found after h-ws skip stops
		// at `/`) and then `collectTrailing` consumed `/*c*/` AFTER the
		// failed sep-match — the `,` was never matched and the next
		// iteration's element parse failed on `,`. Reorder: first probe
		// `collectTrailing` (rewinds on miss), then run sep-match. The
		// post-sep `collectTrailing` still fires when the source carried
		// the trailing after the sep (`elem, // c\n`) — covered by the
		// `_trailingBeforeSep == null && _sepAfter` gate so we don't
		// double-capture.
		return macro {
			while (true) {
				final _lead = collectTrivia(ctx);
				if ($terminationCheck) {
					$i{trailBBLocal} = _lead.blankBefore;
					// ω-keep-fnsig-newline: capture the close-newline alongside
					// the close-blank so a kept signature reproduces a glued vs
					// own-line close.
					$i{trailNLLocal} = _lead.newlineBefore;
					$i{trailLCLocal} = _lead.leadingComments;
					break;
				}
				final _node: $elemCT = $elemCall;
				final _trailingBeforeSep: Null<String> = collectTrailingFull(ctx);
				var _sepAfter: Bool = true;
				$sepMatchExpr;
				final _trailing: Null<String> = _trailingBeforeSep ?? (_sepAfter ? collectTrailingFull(ctx) : null);
				$accumRef.push({
					blankBefore: _lead.blankBefore,
					blankBefore2: _lead.blankBefore2,
					blankAfterLeadingComments: _lead.blankAfterLeadingComments,
					newlineBefore: _lead.newlineBefore,
					leadingComments: _lead.leadingComments,
					trailingComment: _trailing,
					trailingBeforeSep: _trailingBeforeSep != null,
					sepAfter: _sepAfter,
					node: _node,
				});
			}
		};
	}

	private function buildPrattBlankNlAfterSepScan(): Expr {
		// Skip the contiguous non-whitespace separator punctuation, then
		// OR-in any newline in the immediately-following whitespace run.
		return macro {
			var _nlScan: Int = _leadStart;
			while (_nlScan < ctx.input.length) {
				final _sc: Int = ctx.input.charCodeAt(_nlScan);
				if (_sc == ' '.code || _sc == '\t'.code || _sc == '\r'.code || _sc == '\n'.code) break;
				_nlScan++;
			}
			while (_nlScan < ctx.input.length) {
				final _wc: Int = ctx.input.charCodeAt(_nlScan);
				if (_wc == '\n'.code) {
					_nlAfterSep = true;
					break;
				}
				if (_wc != ' '.code && _wc != '\t'.code && _wc != '\r'.code) break;
				_nlScan++;
			}
		};
	}

	private function buildPrattBlankRestoreStash(): Expr {
		// ω-keep-pratt-blank: restore the pre-iteration stash only when the
		// just-parsed value ended with `}` — scan back from `_savedPos` past
		// trailing whitespace to the last content byte. Brace-terminated →
		// preserve the source blank to the next sibling (issue_644 /
		// typedef_fields); otherwise keep the baseline drop (issue_216).
		return macro {
			if (_savedPending != null) {
				var _bpRew: Int = _savedPos - 1;
				while (_bpRew > 0) {
					final _bpc: Int = ctx.input.charCodeAt(_bpRew);
					if (_bpc == ' '.code || _bpc == '\t'.code || _bpc == '\n'.code || _bpc == '\r'.code)
						_bpRew--;
					else
						break;
				}
				if (_bpRew >= 0 && ctx.input.charCodeAt(_bpRew) == '}'.code) ctx.pendingTrivia = _savedPending;
			}
		};
	}

	private function buildPostfixStarSuffixBranch(
		branch: ShapeNode, children: Array<ShapeNode>, close: Null<String>, ctor: String, ctorRef: Expr, enumSimple: String,
		selfFnName: String
	): Expr {
		// Star-suffix form: `Call(operand:T, args:Array<T>)` with
		// @:postfix('(', ')') @:sep(','). The Star child wraps a Ref to the
		// element type. After the open literal is consumed by the outer
		// matchLit, this emits a sep-peek array loop and then expects close.
		if (close == null) {
			Context.fatalError(
				'Lowering: @:postfix Star-suffix branch "$ctor" requires @:postfix(open, close) pair form', Context.currentPos()
			);
			throw 'unreachable';
		}
		final starNode: ShapeNode = children[1];
		final inner: ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: @:postfix Star child must be a Ref', Context.currentPos());
			throw 'unreachable';
		}
		final elemRefName: String = inner.annotations[AnnotationKeys.BASE_REF];
		final elemFn: String = simpleName(elemRefName) == enumSimple ? selfFnName : parseFnName(elemRefName);
		final elemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final elemCT: ComplexType = ruleReturnCT(elemRefName);
		// See struct-field close-peek (emitStarFieldSteps) for why
		// we flip to full-string `peekLit` when close is multi-byte.
		final closeCharCode: Int = close.charCodeAt(0);
		final closeNotNextExpr: Expr = close.length == 1
			? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
			: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{close});
		final sepText: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final ctorCall: Expr = { expr: ECall(ctorRef, [macro left, macro _args]), pos: Context.currentPos() };
		// ω-postfix-call-trailing: when the synth pair grew a
		// `closeTrailing:Null<String>` slot (see
		// `TriviaTypeSynth.isPostfixCloseTrailingBranch`), the trivia
		// branch's ctor call grows a third positional arg. The slot
		// is filled by `collectTrailingFull` after `expectLit(close)`
		// — capturing same-line `// c` / `/* c */` between `)` and
		// the next postfix step's leading-trivia. Without the slot,
		// the inner `skipWs(ctx)` of the next postfix iteration eats
		// the comment.
		//
		// ω-D9A-keep-callargs-v2: alongside `_trailClose`, the ctor
		// call grows a fourth positional `_argsOpenNewline:Bool`
		// captured BEFORE the per-iter `skipWs`/`collectTrivia` (see
		// macro block below). The signal feeds `lowerPostfixStar`'s
		// Keep-mode args[0] hardline; `Trivial.newlineBefore` for
		// args[0] is unreliable due to upstream `ctx.pendingTrivia`
		// leak so a separate parser-side capture is required.
		final ctorCallTrivia: Expr = {
			expr: ECall(ctorRef, [
				macro left,
				macro _args,
				macro _trailClose,
				macro _argsOpenNewline,
				macro _argsCloseNewline,
				macro _argsInnerComment,
				macro _callLeadingComment
			]),
			pos: Context.currentPos(),
		};
		// ω-postfix-starsuffix-trivia: when TriviaAnalysis marks
		// this Star with `trivia.starCollects=true` (auto-set for
		// postfix Star-suffix branches), the synth wraps the
		// args type as `Array<Trivial<elemCT>>` and the parser
		// captures per-arg trailing comments. Mirrors lowerStruct's
		// trivia-Star pattern: horizontal-only-skip before sep match
		// so an inline `// comment` or `/* x */` after each arg lands
		// in `collectTrailing` instead of being eaten by `skipWs`.
		final triviaCollect: Bool = _ctx.trivia && starNode.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true;
		if (triviaCollect && sepText != null) {
			final wrappedCT: ComplexType = TPath({
				pack: ['anyparse', 'runtime'],
				name: 'Trivial',
				params: [TPType(elemCT)]
			});
			final sepCharCode: Int = sepText.charCodeAt(0);
			return buildPostfixCallArgsTriviaLoop(
				elemCT, elemCall, wrappedCT, closeNotNextExpr, sepCharCode, sepText, close, ctorCallTrivia
			);
		}
		if (sepText != null) {
			final sepCharCode: Int = sepText.charCodeAt(0);
			return macro {
				skipWs(ctx);
				final _args: Array<$elemCT> = [];
				if ($closeNotNextExpr) {
					_args.push($elemCall);
					skipWs(ctx);
					// Permissive sep (ω-span-sep-permissive) — see
					// lowerStarSepBranch for rationale; same trivia-loop
					// alignment applied to the postfix Star-suffix loop
					// (call args).
					while ($closeNotNextExpr) {
						if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
							ctx.pos++;
							skipWs(ctx);
							if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
						}
						_args.push($elemCall);
						skipWs(ctx);
					}
				}
				skipWs(ctx);
				expectLit(ctx, $v{close});
				left = $ctorCall;
			};
		}
		if (triviaCollect) {
			// triviaCollect is auto-set only on `@:postfix(...) @:sep(...)`
			// branches by `TriviaAnalysis.markPostfixStarSuffix`, so this
			// branch is unreachable today. Surface the invariant loud rather
			// than carrying dead code that silently mishandles a future
			// no-sep variant.
			Context.fatalError(
				'Lowering: postfix Star-suffix branch "$ctor'
				+ '" has trivia.starCollects=true without @:sep — TriviaAnalysis should not auto-mark this shape; needs explicit support',
				Context.currentPos()
			);
			throw 'unreachable';
		}
		// No separator — peek-close loop (same as Case 4 no-sep).
		return macro {
			skipWs(ctx);
			final _args: Array<$elemCT> = [];
			while ($closeNotNextExpr) {
				_args.push($elemCall);
				skipWs(ctx);
			}
			skipWs(ctx);
			expectLit(ctx, $v{close});
			left = $ctorCall;
		};
	}

	private function buildPostfixCallArgsTriviaLoop(
		elemCT: ComplexType, elemCall: Expr, wrappedCT: ComplexType, closeNotNextExpr: Expr, sepCharCode: Int, sepText: String,
		close: String, ctorCallTrivia: Expr
	): Expr {
		// noqa: complexity
		// Per-element loop: leading-trivia → close-peek break → parse →
		// multi-line trailing scan → matchLit(sep). Trailing comments are
		// captured up to the next sep or close, even across newlines
		// (mirrors fork's `arg \n /* c */, b` interpretation: the comment
		// is trailing-of-arg, not leading-of-next). Sep-after-newline
		// (`arg\n,bar`) tolerance: when the post-sweep position landed past
		// `\n` whitespace and no comments need preserving, KEEP that swept
		// position so `matchLit(sep)` finds the sep; only when the sweep
		// yielded comments NOT at sep do we rewind for the next iter's `_lead`.
		return macro {
			// ω-D9A-keep-callargs-v2: capture source-vertical signal
			// BEFORE per-iter `skipWs`/`collectTrivia` so the
			// post-open `\n` is preserved as a dedicated bool slot.
			// Reading `Trivial.newlineBefore` for args[0] would be
			// polluted by `ctx.pendingTrivia` drained from upstream
			// kw-Ref rules (see project_phase3_slice_d9a_revert).
			// `_openPos` sits right after the outer postfix
			// dispatch consumed the open lit (e.g. `(`); after
			// `skipWs(ctx)` `ctx.pos` lands at the first
			// non-whitespace byte, so the byte range covers exactly
			// the post-open inter-token whitespace.
			final _openPos: Int = ctx.pos;
			// ω-callarg-empty-inner-comment: skip only whitespace (not comments)
			// before the args loop, so the loop's `collectTrivia` can capture a
			// leading comment on the first argument or an empty-parens inner
			// comment. For comment-free calls this lands at the identical byte
			// `skipWs` did, keeping the `argsOpenNewline` signal byte-identical.
			while (ctx.pos < ctx.input.length) {
				final _wc: Int = ctx.input.charCodeAt(ctx.pos);
				if (_wc == ' '.code || _wc == '\t'.code || _wc == '\n'.code || _wc == '\r'.code) {
					ctx.pos++;
					continue;
				}
				break;
			}
			final _argsOpenNewline: Bool = hasNewlineIn(ctx.input, _openPos, ctx.pos);
			var _argsInnerComment: Null<String> = null;
			// ω-keep-call-leading-comment: a pre-callee inline block comment leaked
			// into `ctx.pendingTrivia` by the upstream operator/keyword
			// `skipWsAndStash` (`a * /* c */ f()`, `/* c */ f()`) would otherwise be
			// drained by this loop's `collectTrivia` into args[0]'s leading / the
			// inner slot — relocating it INSIDE the parens. Claim it here, BEFORE
			// the loop, so the writer emits it before the operand. Only inline block
			// comments (mirrors the argsInnerComment gate); a line / multi-line
			// block stays in pendingTrivia (existing drop behavior, unchanged). The
			// newline / blank signals on pendingTrivia are preserved for args[0].
			var _callLeadingComment: Null<String> = null;
			{
				final _clPending = ctx.pendingTrivia;
				if (_clPending != null && _clPending.leadingComments.length > 0) {
					var _clInline: Bool = true;
					for (_c in _clPending.leadingComments) if (!StringTools.startsWith(_c, '/*') || _c.indexOf('\n') >= 0)
						_clInline = false;
					if (_clInline) {
						_callLeadingComment = _clPending.leadingComments.join(' ');
						while (_clPending.leadingComments.length > 0) _clPending.leadingComments.pop();
					}
				}
			}
			final _args: Array<$wrappedCT> = [];
			// ω-keep-callclose-newline: source-vertical signal for the
			// gap before the postfix close literal. `collectTrivia`'s
			// final iteration (the close-peek break) reports whether a
			// newline preceded the close in `_lead.newlineBefore`
			// (`arg\n)` vs `arg)`). Captured on the break and threaded
			// to the writer's Keep-mode chain close placement. Default
			// `false` for the never-iterated impossible path.
			var _argsCloseNewline: Bool = false;
			while (true) {
				final _lead = collectTrivia(ctx);
				if (!($closeNotNextExpr)) {
					_argsCloseNewline = _lead.newlineBefore;
					// ω-callarg-empty-inner-comment: an empty argument list whose
					// only content is a comment (`f(/* c */)`) — the comment
					// captured by `collectTrivia` belongs to no argument. Route it
					// to the inner-comment slot so the writer emits it between the
					// open and close literals. Only inline block comments are
					// captured (mirrors the ω-callarg-leading-comment gate): a
					// line comment or multi-line block would be emitted inline
					// before `)` and swallow it, producing unparseable output.
					if (_args.length == 0 && _lead.leadingComments.length > 0) {
						var _icInline: Bool = true;
						for (_c in _lead.leadingComments) if (!StringTools.startsWith(_c, '/*') || _c.indexOf('\n') >= 0) _icInline = false;
						if (_icInline) _argsInnerComment = _lead.leadingComments.join(' ');
					}
					break;
				}
				final _node: $elemCT = $elemCall;
				var _trailing: Null<String> = null;
				// Step 1: same-line trail capture. Returns
				// captured slice with delimiters or null.
				final _sameLine: Null<String> = collectTrailingFull(ctx);
				if (_sameLine != null) _trailing = _sameLine;
				// Step 2: multi-line trail look-ahead.
				final _preSweepPos: Int = ctx.pos;
				final _swept = collectTrivia(ctx);
				final _atSep: Bool = ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode};
				if (_atSep && _swept.leadingComments.length > 0) {
					final _addl: String = _swept.leadingComments.join('\n');
					_trailing = _trailing != null ? _trailing + '\n' + _addl : _addl;
				} else if (_swept.leadingComments.length > 0) {
					// Comments belong to next iter's _lead —
					// rewind so they're re-captured (and to
					// avoid losing them through `matchLit`'s
					// no-skip behaviour).
					ctx.pos = _preSweepPos;
				}
				// Else: no comments swept — keep cursor at
				// post-sweep pos. This crosses `\n` and any
				// horizontal ws, so `matchLit(sep)` finds a
				// sep on a different line than the arg
				// (`arg\n,bar`) — fork-supported pattern.
				final _sepAfter: Bool = matchLit(ctx, $v{sepText});
				// ω-callarg-after-sep-comment: a same-line comment sitting AFTER
				// the separator (`arg, // note`) belongs to THIS argument's line,
				// not to the next argument it would otherwise reach as a leading
				// comment. Restricted to LINE style: a `//` in a leading slot is
				// unemittable inline (it would swallow the argument that follows)
				// and was silently DROPPED, so claiming it here is pure recovery.
				// A block comment after the separator already round-trips through
				// the next element's leading slot (`f(a, /* c */ b)`) — leaving it
				// there keeps every existing layout byte-identical.
				final _postSepPos: Int = ctx.pos;
				final _afterSepRaw: Null<String> = _sepAfter && _trailing == null ? collectTrailingFull(ctx) : null;
				final _afterSep: Null<String> = _afterSepRaw != null && StringTools.startsWith(_afterSepRaw, '//') ? _afterSepRaw : null;
				if (_afterSep == null)
					ctx.pos = _postSepPos
				else
					_trailing = _afterSep;
				_args.push({
					blankBefore: _lead.blankBefore,
					blankBefore2: _lead.blankBefore2,
					blankAfterLeadingComments: _lead.blankAfterLeadingComments,
					newlineBefore: _lead.newlineBefore,
					leadingComments: _lead.leadingComments,
					trailingComment: _trailing,
					trailingBeforeSep: _afterSep == null,
					sepAfter: _sepAfter,
					node: _node,
				});
			}
			skipWs(ctx);
			expectLit(ctx, $v{close});
			// Capture trailing comment between `close` and the
			// next postfix iteration's leading trivia. Same-line
			// only — multi-line look-ahead would steal comments
			// belonging to the next chain segment's `_lead` slot
			// (or to the enclosing statement's trailing slot
			// when the chain ends here). The Pratt loop's
			// outer skipWs-rewind handles the chain-end case
			// (no postfix matches → rewind on `_hadComment`).
			final _trailClose: Null<String> = collectTrailingFull(ctx);
			left = $ctorCallTrivia;
		};
	}

	private function buildPostfixSuffixBranch(
		children: Array<ShapeNode>, ctor: String, ctorRef: Expr, close: Null<String>, branch: ShapeNode, enumSimple: String,
		selfFnName: String
	): Expr {
		final suffix: ShapeNode = children[1];
		if (suffix.kind != Ref) {
			Context.fatalError('Lowering: @:postfix branch "$ctor" second argument must be a Ref', Context.currentPos());
			throw 'unreachable';
		}
		final suffixRef: String = suffix.annotations[AnnotationKeys.BASE_REF];
		// For the wrap-with-recurse form, the inner Ref typically points
		// at SelfType — to force a full expression parse reset we call
		// `parseXxx` directly (via its public entry) rather than the
		// atom wrapper. This lets a `[a + b]` index expression contain
		// arbitrary infix operators. For the single-Ref-suffix form,
		// the suffix is usually a Terminal like HxIdentLit and the
		// `parseXxxSuffix` call is just a terminal call.
		final suffixFn: String = simpleName(suffixRef) == enumSimple ? selfFnName : parseFnName(suffixRef);
		final suffixCall: Expr = {
			expr: ECall(macro $i{suffixFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final suffixCT: ComplexType = ruleReturnCT(suffixRef);
		// ω-keep-chain (increment 9): a `@:postfix('.')` ctor carrying
		// `@:fmt(captureChainNewline)` (`HxExpr.FieldAccess`) grows a 3rd
		// positional `chainNewline:Bool` synth arg in Trivia mode holding
		// whether the source had a newline in the gap BEFORE the `.`
		// dispatch. `_preWsPos` (the trivia while-loop's pre-skipWs save)
		// to `ctx.pos` (just past the matched `.`) spans exactly the
		// dot-leading gap; the `.` is a single non-newline char so the
		// scan is equivalent to the gap before it. The writer's chain
		// dispatch reads it into a `_breaks` array parallel to `_segs`
		// and threads it to `MethodChainEmit.emit(..., sourceBreakBefore)`
		// so a `WrapMode.Keep` method-chain round-trips the source per-
		// segment dot-boundary line breaks. Plain mode keeps the original
		// 2-arg ctor arity (no slot; chain always glues via shapeNoWrap).
		final captureChainNl: Bool = _ctx.trivia && branch.fmtHasFlag('captureChainNewline');
		// ω-postfix-op-space: a word-op postfix ctor with
		// `@:fmt(capturePostfixOpSpace)` grows a positional `opSpaceBefore:Bool`
		// synth arg in Trivia mode — whether the source had whitespace between
		// the operand and the operator. At branch entry `ctx.pos` sits just past
		// the matched operator and `_preWsPos` is the loop's pre-skipWs save, so
		// the gap is non-empty iff their distance exceeds the operator length.
		final captureOpSpace: Bool = _ctx.trivia && branch.fmtHasFlag('capturePostfixOpSpace');
		final postfixOpLen: Int = (branch.annotations[AnnotationKeys.POSTFIX_OP]: String).length;
		// ω-keep-chain-receiver-comment: the FieldAccess ctor grows a 4th
		// positional `chainLeadComment:Null<String>` slot after `chainNewline`.
		// It reads `_opTrailComment` — the operand's trailing comment captured
		// at the loop's pre-skipWs site (see the trivia postfix loop below).
		// The slot lets the writer's keep-mode chain dispatch reattach a bare
		// receiver's trailing comment (`owner // test`) that the per-iteration
		// `skipWs` would otherwise eat.
		final ctorCall: Expr = {
			expr: ECall(
				ctorRef,
				captureChainNl
					? [
						macro left,
						macro _suffix,
						macro _chainNl,
						macro _opTrailComment
					]
					: captureOpSpace
						? [
							macro left,
							macro _suffix,
							macro _opSpaceBefore
						]
						: [
							macro left,
							macro _suffix
						]
			),
			pos: Context.currentPos(),
		};
		return close == null
			? captureChainNl
				? macro {
					final _chainNl: Bool = hasNewlineIn(ctx.input, _preWsPos, ctx.pos);
					skipWs(ctx);
					final _suffix: $suffixCT = $suffixCall;
					left = $ctorCall;
				}
				: captureOpSpace
					? macro {
						final _opSpaceBefore: Bool = ctx.pos - _preWsPos > $v{postfixOpLen};
						skipWs(ctx);
						final _suffix: $suffixCT = $suffixCall;
						left = $ctorCall;
					}
					: macro {
						skipWs(ctx);
						final _suffix: $suffixCT = $suffixCall;
						left = $ctorCall;
					}
			: macro {
				skipWs(ctx);
				final _suffix: $suffixCT = $suffixCall;
				skipWs(ctx);
				expectLit(ctx, $v{close});
				left = $ctorCall;
			};
	}

	private function buildPostfixNoMatchScanback(): Expr {
		// ω-cond-comp-expr-multiline / ω-keep-pratt-blank: when no postfix op
		// matched, scan the `[_preWsPos, ctx.pos)` run consumed by the last
		// skipWs. A comment rewinds to `_preWsPos` so the enclosing loop
		// re-captures it; a bare newline (or a blank line, ≥2 newlines) is
		// stashed into `ctx.pendingTrivia` so downstream `collectTrivia` reads
		// the source-vertical signal the postfix loop otherwise drops.
		return macro {
			var _scanI: Int = _preWsPos;
			var _hadComment: Bool = false;
			var _hadNewline: Bool = false;
			// ω-keep-pratt-blank: mirror the Pratt-loop blank tracking —
			// a blank line (≥2 newlines separated only by horizontal
			// whitespace) inside the postfix-consumed run must survive
			// the no-op tail so a brace-terminated value followed by a
			// blank line (`var b = function(){…}\n\nfinal a`, issue_644)
			// carries `blankBefore` to the next decl's `collectTrivia`.
			var _nlRun: Int = 0;
			var _hadBlank: Bool = false;
			while (_scanI < ctx.pos) {
				final _ch: Int = ctx.input.charCodeAt(_scanI);
				if (_ch == '\n'.code) {
					_hadNewline = true;
					_nlRun++;
					if (_nlRun >= 2) _hadBlank = true;
				} else if (_ch != ' '.code && _ch != '\t'.code && _ch != '\r'.code) {
					_nlRun = 0;
				}
				if (_ch == '/'.code && _scanI + 1 < ctx.pos) {
					final _c2: Int = ctx.input.charCodeAt(_scanI + 1);
					if (_c2 == '/'.code || _c2 == '*'.code) {
						_hadComment = true;
						break;
					}
				}
				_scanI++;
			}
			if (_hadComment) {
				ctx.pos = _preWsPos;
			} else if (_hadNewline) {
				final _pt = ctx.pendingTrivia;
				if (_pt == null) {
					ctx.pendingTrivia = {
						blankBefore: _hadBlank,
						blankAfterLeadingComments: false,
						newlineBefore: true,
						leadingComments: [],
					};
				} else {
					_pt.newlineBefore = true;
					if (_hadBlank) _pt.blankBefore = true;
				}
			}
		};
	}

	private function buildPostfixLoopExpr(
		returnCT: ComplexType, coreCall: Expr, opTrailCapture: Expr, opChain: Expr, ?wordOps: Array<String>
	): Expr {
		// Trivia mode adds the per-iteration operand-trail capture and the
		// no-match scan-back (comment-rewind / newline-stash); plain mode is
		// the bare matchExpr dispatch loop.
		final scanback: Expr = buildPostfixNoMatchScanback();
		final clearStashNl: Expr = stashNewlineClearExpr();
		return _ctx.trivia
			? macro {
				var left: $returnCT = $coreCall;
				while (true) {
					final _preWsPos: Int = ctx.pos;
					$opTrailCapture;
					skipWs(ctx);
					var _matched: Bool = true;
					$opChain;
					if (!_matched) {
						$scanback;
						break;
					}
					// A matched suffix keeps the expression open, so any stash the
					// core / the suffix payload left describes an INTERIOR gap —
					// `(foo\n).bar` must not report a line break before whatever
					// follows `.bar`. See `stashNewlineClearExpr`.
					$clearStashNl;
				}
				return left;
			}
			: macro {
				var left: $returnCT = $coreCall;
				while (true) {
					final _preWsPos: Int = ctx.pos;
					skipWs(ctx);
					var _matched: Bool = true;
					$opChain;
					if (!_matched) {
						// ω-cond-splice: conditional restore — see
						// buildPrattLoopExpr (unconditional restore breaks
						// `@:raw` interpolation siblings).
						${buildWordOpRestoreExpr(wordOps)};
						break;
					}
				}
				return left;
			};
	}

	private function collectAllOps(node: ShapeNode): Array<String> {
		// Cross-category longer-prefix resolution: a postfix op that is a
		// strict prefix of another op in the same enum (postfix, infix, or
		// ternary) must lose to that longer op. Collecting ALL op literals on
		// the enum lets us emit a `!peekLit(longer)` guard per conflict so the
		// postfix dispatch declines and Pratt picks up the longer op.
		final allOps: Array<String> = [];
		for (b in node.children) {
			final po: Null<String> = b.annotations.get(AnnotationKeys.POSTFIX_OP);
			if (po != null) allOps.push(po);
			final pr: Null<String> = b.annotations.get(AnnotationKeys.PRATT_OP);
			if (pr != null) allOps.push(pr);
			final tr: Null<String> = b.annotations.get(AnnotationKeys.TERNARY_OP);
			if (tr != null) allOps.push(tr);
		}
		return allOps;
	}

	private function buildPostfixOpMatchExpr(op: String, allOps: Array<String>): Expr {
		// Prepend `!peekLit(longerOp)` guards for every op literal that
		// strictly starts with `op`. Short-circuits so matchLit is not
		// called when a longer op is about to match.
		// Word-like postfix ops (cond-splice `#if`) carry an OWN-LINE gate.
		// A `#if` on its own line after a no-semi BLOCK-ENDED statement is a
		// structured STATEMENT conditional, not an infix splice-tail: without
		// the gate the splice raw-swallows it and the enclosing statement then
		// fails on the next token. Two live shapes need the rejection --
		// `@:privateAccess { ... }` followed by an own-line
		// `#if debug final t = ...; #end`
		// (`TM-Haxe4/src/video/GpuDirectPipeline.hx:52`, the original dogfood
		// catch recorded when this gate was written), and a `switch { ... }`
		// assignment followed by an own-line
		// `#if (haxe_ver >= 4.10) if (...) #else if (...) #end`
		// (`pony/ui/xml/HeapsXmlUi.hx:202`).
		//
		// The gate was UNCONDITIONAL on the newline until this slice, which
		// also rejected the two legitimate own-line SPLICE TAILS --
		// `return __idleThreads\n#if lime_threads - __queuedExitEvents #end;`
		// (`lime/system/ThreadPool.hx:1029`) and the in-condition operand form
		// `if (intf != null\n// ...\n#if (js_es >= 6) && (...) #end)`
		// (`std/js/Boot.hx:151`). Two predicates admit those without admitting
		// the scope-level regions:
		//  - `spliceFragmentIsInfix` is the discriminator: a splice TAIL
		//    continues the operand, so past the condition atom its fragment
		//    opens with an infix operator, while a scope-level region opens
		//    with a declaration, statement, list separator or metadata. It is
		//    what keeps the param-list
		//    (`whitespace/issue_582_type_hints_conditionals`) and array-element
		//    (`wrapping/issue_207_array_wrapping_with_conditionals`) fixtures
		//    on their own productions -- a newline-blind relaxation broke both.
		//  - `endsWithBlockClose` is the belt-and-braces half: a Haxe statement
		//    terminable WITHOUT a `;` always ends with `}`, so an own-line
		//    `#if` after a `}` is a statement conditional whatever its fragment
		//    looks like.
		// The same-line case is untouched (no newline => always a splice tail),
		// so the relaxation only ever ADDS accepted input.
		//
		// TRIVIA-MODE NEWLINE SOURCE #2 (ω-cond-splice-stash-newline). The gap
		// scan alone is BLIND when the operand's own parse pre-consumed the gap:
		// a construct ending in a `@:trivia @:tryparse` Star
		// (`HxTryCatchExpr.catches`) runs one no-match iteration past the
		// operand, which skips the newline and stashes the signal into
		// `ctx.pendingTrivia` (the ω-untyped-keep stash). The postfix loop then
		// saves `_preWsPos` PAST the newline, the gap scan reads empty, and an
		// own-line statement region binds as a SAME-LINE splice tail --
		// `try f() catch (_:Exception) {}` followed by an own-line
		// `#if cpp ... #end` raw-swallowed the whole region (dogfood
		// `utils/CleanExit.hx:36`); the glue then fed the region's flat width
		// into the operand's rest-stack and wrapped a method chain that fit.
		// `pendingTrivia.newlineBefore` is the same second newline source that
		// `captureChainNewline` already ORs in (see `chainNlValue`). This scan
		// runs in the MATCH expression, before any operator of the iteration has
		// committed, so `stashNewlineClearExpr` at the loop's matched tail cannot
		// blind it: the next iteration re-derives its gap from a freshly saved
		// `_preWsPos`, and the flag that tail dropped described a gap BEFORE the
		// operator already consumed.
		//
		// The leading `peekLit` is a pure cost guard: `matchKw` has to stay LAST
		// (it consumes on success), so without it both scanners would run at
		// every postfix-loop iteration whose operand happens to end a line.
		final gapNewline: Expr = _ctx.trivia
			? macro (hasNewlineIn(ctx.input, _preWsPos, ctx.pos) || (ctx.pendingTrivia != null && ctx.pendingTrivia.newlineBefore))
			: macro hasNewlineIn(ctx.input, _preWsPos, ctx.pos);
		var matchExpr: Expr = endsWithWordChar(op)
			? macro peekLit(ctx, $v{op}) && (
				!$gapNewline || (!endsWithBlockClose(ctx.input, _preWsPos) && spliceFragmentIsInfix(ctx.input, ctx.pos + $v{op.length}))
			) && matchKw(ctx, $v{op})
			: macro matchLit(ctx, $v{op});
		for (other in allOps) {
			if (other.length > op.length && other.startsWith(op)) {
				matchExpr = macro !peekLit(ctx, $v{other}) && $matchExpr;
			}
		}
		return matchExpr;
	}

	private function buildPostfixSingleBranch(close: Null<String>, ctorRef: Expr): Expr {
		final ctorCall: Expr = { expr: ECall(ctorRef, [macro left]), pos: Context.currentPos() };
		return close == null
			? macro {
				left = $ctorCall;
			}
			: macro {
				skipWs(ctx);
				expectLit(ctx, $v{close});
				left = $ctorCall;
			};
	}

	private function buildTryparseSepLoop(
		elemCall: Expr, accumRef: Expr, sepCharCode: Int, sepBlockEnded: Bool, predicateCall: Expr
	): Expr {
		// Try-parse with sep peek. After each successful element,
		// peeks the next non-whitespace char: if it equals the sep, consumes
		// it and continues; otherwise breaks. On element-parse fail, rewinds
		// to `_savedPos` (taken BEFORE `skipWs`) so the enclosing close sees
		// the pre-whitespace position. The block-ended variant additionally
		// tolerates an omitted sep when the prior element ended with `;` (or
		// the schema predicate matches).
		return sepBlockEnded
			? macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					try {
						skipWs(ctx);
						$accumRef.push($elemCall);
					} catch (_e: anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
					final _prevEndPos: Int = ctx.pos;
					skipWs(ctx);
					final _isBE: Bool = _prevEndPos > 0 && {
						var _pebRew: Int = _prevEndPos - 1;
						while (_pebRew > 0) {
							final _bc: Int = ctx.input.charCodeAt(_pebRew);
							if (_bc == ' '.code || _bc == '\t'.code || _bc == '\n'.code || _bc == '\r'.code)
								_pebRew--;
							else
								break;
						}
						final _b: Int = ctx.input.charCodeAt(_pebRew);
						_b == ';'.code || $predicateCall;
					};
					if (_isBE) continue;
					if (ctx.pos >= ctx.input.length || ctx.input.charCodeAt(ctx.pos) != $v{sepCharCode}) break;
					ctx.pos++;
				}
			}
			: macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					try {
						skipWs(ctx);
						$accumRef.push($elemCall);
					} catch (_e: anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
					skipWs(ctx);
					if (ctx.pos >= ctx.input.length || ctx.input.charCodeAt(ctx.pos) != $v{sepCharCode}) break;
					ctx.pos++;
				}
			};
	}

	private function buildCloseBlockEndedBody(
		elemCall: Expr, accumRef: Expr, closeNotNextExpr: Expr, sepCharCode: Int, sepText: String, predicateCall: Expr,
		sepStartsElement: Bool
	): Expr {
		// Block-ended exemption: after a successful element, sep may be
		// omitted if the element ended with `}` / `;` (byte-level check on
		// `_prevEndPos - 1`) — or, when the predicate matches. Tail-relax
		// (trailing sep tolerated before close) is folded in. `sepStartsElement`
		// flips byte-ambiguity policy: when block-ended is TRUE, the sep byte
		// at pos belongs to the NEXT element, never a separator (needed where
		// the sep char can ALSO be a valid element body — Haxe `EmptyStmt`).
		final beCheck: Expr = buildBlockEndedByteCheck(predicateCall);
		return sepStartsElement
			? macro {
				skipWs(ctx);
				if ($closeNotNextExpr) {
					var _prevEndPos: Int = ctx.pos;
					$accumRef.push($elemCall);
					_prevEndPos = ctx.pos;
					skipWs(ctx);
					while ($closeNotNextExpr) {
						final _isBE: Bool = $beCheck;
						if (_isBE) {
							// block-ended: sep byte at pos belongs to next element
							$accumRef.push($elemCall);
							_prevEndPos = ctx.pos;
							skipWs(ctx);
						} else if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
							ctx.pos++;
							skipWs(ctx);
							if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
							$accumRef.push($elemCall);
							_prevEndPos = ctx.pos;
							skipWs(ctx);
						} else {
							expectLit(ctx, $v{sepText}); // throws expected-sep
						}
					}
				}
			}
			: macro {
				skipWs(ctx);
				if ($closeNotNextExpr) {
					var _prevEndPos: Int = ctx.pos;
					$accumRef.push($elemCall);
					_prevEndPos = ctx.pos;
					skipWs(ctx);
					while ($closeNotNextExpr) {
						if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
							ctx.pos++;
							skipWs(ctx);
							if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
							$accumRef.push($elemCall);
							_prevEndPos = ctx.pos;
							skipWs(ctx);
						} else if ($beCheck) {
							// Block-ended: prior element ended with `;`
							// (byte-check after walking back over
							// whitespace — covers stmts whose own
							// `@:trailOpt(';')` consumed `;` and then
							// the trailing `skipWs` advanced past it)
							// or the AST-shape predicate returned true.
							// No sep needed; parse next.
							$accumRef.push($elemCall);
							_prevEndPos = ctx.pos;
							skipWs(ctx);
						} else {
							expectLit(ctx, $v{sepText}); // throws expected-sep
						}
					}
				}
			};
	}

	private function buildBlockEndedByteCheck(predicateCall: Expr): Expr {
		// `true` iff the just-parsed element is block-ended: scan back from
		// `_prevEndPos` over trailing whitespace to the last content byte and
		// accept `;` (covers stmts whose own `@:trailOpt(';')` consumed the
		// terminator), or the schema predicate matches.
		return macro _prevEndPos > 0 && {
			var _pebRew: Int = _prevEndPos - 1;
			while (_pebRew > 0) {
				final _bc: Int = ctx.input.charCodeAt(_pebRew);
				if (_bc == ' '.code || _bc == '\t'.code || _bc == '\n'.code || _bc == '\r'.code)
					_pebRew--;
				else
					break;
			}
			final _b: Int = ctx.input.charCodeAt(_pebRew);
			_b == ';'.code || $predicateCall;
		};
	}

	private function buildClosePeekBody(elemCall: Expr, accumRef: Expr, closeNotNextExpr: Expr, sepText: Null<String>): Expr {
		// Close-peek loop: parse elements until the close literal is the next
		// non-whitespace token. With `@:sep`, consume one separator between
		// elements and tolerate a trailing sep before the close.
		if (sepText == null) return macro {
			skipWs(ctx);
			while ($closeNotNextExpr) {
				$accumRef.push($elemCall);
				skipWs(ctx);
			}
		};
		final sepCharCode: Int = sepText.charCodeAt(0);
		return macro {
			skipWs(ctx);
			if ($closeNotNextExpr) {
				$accumRef.push($elemCall);
				skipWs(ctx);
				// Permissive sep (ω-span-sep-permissive) — see
				// lowerStarSepBranch for rationale; same trivia-loop
				// alignment applied to the field-Star close loop
				// (fn params, new-expr args).
				while ($closeNotNextExpr) {
					if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
					}
					$accumRef.push($elemCall);
					skipWs(ctx);
				}
			}
		};
	}

	private function emitSepBeforeOptStep(localName: String, parseSteps: Array<Expr>, sepCharCode: Int): Void {
		// `@:fmt(sepBeforeOpt)` opt-in: BEFORE entering the
		// element loop, peek-and-consume a single leading sep INSIDE the body
		// (between enclosing kw and first element). Captures true/false into
		// `<localName>SepBefore` for the writer's padLeading runtime gate to
		// re-emit the leading sep.
		final sepBeforeLocal: String = '${localName}SepBefore';
		parseSteps.push({
			expr: EVars([
				{
					name: sepBeforeLocal,
					type: macro :Bool,
					expr: macro false,
					isFinal: false,
				}
			]),
			pos: Context.currentPos(),
		});
		parseSteps.push(macro {
			final _savedPos: Int = ctx.pos;
			skipWs(ctx);
			if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
				ctx.pos++;
				$i{sepBeforeLocal} = true;
			} else {
				ctx.pos = _savedPos;
			}
		});
	}

	private function emitNonTriviaCloseSteps(
		starNode: ShapeNode, parseSteps: Array<Expr>, isLastField: Bool, elemCall: Expr, accumRef: Expr, closeText: Null<String>,
		sepText: Null<String>
	): Void {
		if (closeText == null && (!isLastField || starNode.hasMeta(':tryparse'))) {
			// Try-parse mode: loop until element parse fails. Used by Star
			// fields that are NOT the last field in a struct, OR by fields
			// annotated with `@:tryparse` (D49) — the loop terminates when the
			// next token cannot be parsed as an element (e.g. a modifier loop
			// stopping at `var`/`function`, or a switch-case body stopping at
			// the next `case`/`default`).
			parseSteps.push(macro {
				while (true) {
					final _savedPos: Int = ctx.pos;
					try {
						skipWs(ctx);
						$accumRef.push($elemCall);
					} catch (_e: anyparse.runtime.ParseError) {
						ctx.pos = _savedPos;
						break;
					}
				}
			});
			return;
		}
		if (closeText == null) {
			// EOF mode: last field, no trail — loop until end of input.
			parseSteps.push(macro {
				skipWs(ctx);
				while (ctx.pos < ctx.input.length) {
					$accumRef.push($elemCall);
					skipWs(ctx);
				}
			});
			return;
		}
		// Close-peek entry guard for the Star loop.
		//
		// When `closeText` is a single byte, a `charCodeAt` peek is the
		// fastest way to decide "are we at the close or at an element?".
		// When `closeText` is longer, the single-byte peek false-positives
		// on elements whose first byte happens to equal `closeText[0]` —
		// concretely, `@:trail('*\/')` on a block-comment body lets `*`
		// appear inside line content, and a `charCodeAt != '*'` guard
		// skips the Star entirely the moment body begins with `*` (e.g.
		// `/**` javadoc). The full-string `peekLit` call eats a substring
		// comparison instead of a byte compare, which is negligible
		// outside of very hot inner loops.
		final closeCharCode: Int = closeText.charCodeAt(0);
		final closeNotNextExpr: Expr = closeText.length == 1
			? macro ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}
			: macro ctx.pos < ctx.input.length && !peekLit(ctx, $v{closeText});
		final blockEnded: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED] == true;
		if (sepText != null && blockEnded) {
			final sepCharCode: Int = sepText.charCodeAt(0);
			final predicateName: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_BLOCK_ENDED_PREDICATE];
			final predicateCall: Expr = predicateName != null ? buildBlockEndedPredicateCall(predicateName, accumRef) : macro false;
			final sepStartsElement: Bool = starNode.annotations[AnnotationKeys.LIT_SEP_STARTS_ELEMENT] == true;
			parseSteps.push(
				buildCloseBlockEndedBody(elemCall, accumRef, closeNotNextExpr, sepCharCode, sepText, predicateCall, sepStartsElement)
			);
		} else {
			parseSteps.push(buildClosePeekBody(elemCall, accumRef, closeNotNextExpr, sepText));
		}
		parseSteps.push(macro skipWs(ctx));
		parseSteps.push(macro expectLit(ctx, $v{closeText}));
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
			pos: Context.currentPos(),
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
	 * Case 0: zero-arg ctor with `@:kw` (no `@:lit`). Emits `expectKw` with
	 * word-boundary enforcement; when `@:trail` is present the trail literal
	 * is emitted unconditionally after the keyword (D48).
	 */
	private function lowerKwZeroArgBranch(branch: ShapeNode, ctorRef: Expr, kwLeadBranch: String): Expr {
		final trailBranch: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		return trailBranch != null
			? macro {
				skipWs(ctx);
				expectKw(ctx, $v{kwLeadBranch});
				skipWs(ctx);
				expectLit(ctx, $v{trailBranch});
				return $ctorRef;
			}
			: macro {
				skipWs(ctx);
				expectKw(ctx, $v{kwLeadBranch});
				return $ctorRef;
			};
	}

	/**
	 * Case 1: zero-arg ctor with `@:lit(single)`. A word-ending literal
	 * routes through the word-boundary-checking `expectKw`; a symbolic
	 * literal through plain `expectLit`.
	 */
	private function lowerSingleLitBranch(ctorRef: Expr, lit: String): Expr {
		final expectCall: Expr = endsWithWordChar(lit) ? macro expectKw(ctx, $v{lit}) : macro expectLit(ctx, $v{lit});
		return macro {
			skipWs(ctx);
			$expectCall;
			return $ctorRef;
		};
	}

	/**
	 * Case 2: single-arg ctor with `@:lit(multi)` — literals map to ident
	 * values of the field type. Each literal dispatches via `matchKw` (word-
	 * like set) or `matchLit` (symbolic set); a mixed set is rejected at
	 * macro time.
	 */
	private function lowerMultiLitBranch(ctorRef: Expr, litList: Array<String>): Expr {
		final wordLike: Bool = endsWithWordChar(litList[0]);
		for (lit in litList) {
			if (endsWithWordChar(lit) != wordLike) {
				Context.fatalError(
					'Lowering: multi-@:lit set mixes word-like and symbolic literals: ${litList.join(', ')}', Context.currentPos()
				);
			}
		}
		final matchFnName: String = wordLike ? 'matchKw' : 'matchLit';
		final attempts: Array<Expr> = [];
		for (lit in litList) {
			final valueExpr: Expr = { expr: EConst(CIdent(lit)), pos: Context.currentPos() };
			final call: Expr = { expr: ECall(ctorRef, [valueExpr]), pos: Context.currentPos() };
			final matchCall: Expr = {
				expr: ECall(macro $i{matchFnName}, [macro ctx, macro $v{lit}]),
				pos: Context.currentPos(),
			};
			attempts.push(macro if ($matchCall) return $call);
		}
		final failExpr: Expr = macro throw anyparse.runtime.ParseError.backtrack;
		final body: Array<Expr> = [macro skipWs(ctx)].concat(attempts).concat([failExpr]);
		return macro $b{body};
	}

	/**
	 * Case 4 (no-sep): `@:lead`/`@:trail` Star with no separator. The loop
	 * terminates by peeking at the close literal instead of consuming a
	 * separator between items.
	 */
	private function lowerStarNoSepBranch(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			while ($closeNotNextExpr) {
				_items.push($elemCall);
				skipWs(ctx);
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			return $ctorCall;
		};
	}

	/**
	 * Case 4 (plain @:sep): close-driven Star loop that consumes one
	 * separator between elements and tolerates a trailing sep before the
	 * close literal.
	 */
	private function lowerStarSepBranch(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr, sepCharCode: Int
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			if ($closeNotNextExpr) {
				_items.push($elemCall);
				skipWs(ctx);
				// Permissive sep (ω-span-sep-permissive): consume one optional
				// separator between elements and keep looping until the close —
				// aligning with the trivia build's close-peek loop, which has
				// always tolerated an omitted sep (`[1 2]`, `f(a b)`). Required
				// for `#if`-guarded element groups whose commas live INSIDE the
				// conditional body (`[a, #if x b, #end c]`) — the span build
				// otherwise stops at the group boundary. Garbage input still
				// fails: the element parse throws on anything that is not an
				// element, and the close expect catches the rest.
				while ($closeNotNextExpr) {
					if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
					}
					_items.push($elemCall);
					skipWs(ctx);
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			return $ctorCall;
		};
	}

	/**
	 * Case 4 (@:sepAlt): tolerant close-driven loop that consumes an
	 * OPTIONAL separator (sepText or sepAltText) between elements. Mirrors
	 * the trivia-build close-peek loop in plain mode so multi `;`-separated
	 * anon fields parse under the non-trivia builds. Sole consumer:
	 * `HxType.Anon`.
	 */
	private function lowerStarSepAltBranch(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr, sepCharCode: Int,
		sepAltCharCode: Int
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			while ($closeNotNextExpr) {
				_items.push($elemCall);
				skipWs(ctx);
				if (ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode} || ctx.input.charCodeAt(ctx.pos) == $v{sepAltCharCode}) {
					ctx.pos++;
					skipWs(ctx);
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
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
			pos: Context.currentPos(),
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
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
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
	 * Case 4 block-ended Star with `sepStartsElement` — the sep byte at pos
	 * belongs to the NEXT element when the prior element is block-ended.
	 *
	 */
	private function lowerStarBlockEndedSepStarts(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr, sepCharCode: Int,
		sepText: String, predicateCall: Expr
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			if ($closeNotNextExpr) {
				var _prevEndPos: Int = ctx.pos;
				_items.push($elemCall);
				_prevEndPos = ctx.pos;
				skipWs(ctx);
				while ($closeNotNextExpr) {
					final _isBE: Bool = _prevEndPos > 0 && {
						var _pebRew: Int = _prevEndPos - 1;
						while (_pebRew > 0) {
							final _bc: Int = ctx.input.charCodeAt(_pebRew);
							if (_bc == ' '.code || _bc == '\t'.code || _bc == '\n'.code || _bc == '\r'.code)
								_pebRew--;
							else
								break;
						}
						final _b: Int = ctx.input.charCodeAt(_pebRew);
						_b == ';'.code || $predicateCall;
					};
					if (_isBE) {
						// block-ended: sep byte at pos belongs to next element
						_items.push($elemCall);
						_prevEndPos = ctx.pos;
						skipWs(ctx);
					} else if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
						_items.push($elemCall);
						_prevEndPos = ctx.pos;
						skipWs(ctx);
					} else {
						expectLit(ctx, $v{sepText});
					}
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			return $ctorCall;
		};
	}

	/**
	 * Case 4 block-ended Star, sep-first policy — sep is consumed between
	 * elements; block-ended exemption tolerates an omitted sep when the
	 * prior element ended with `;`/`}` or the predicate matches.
	 */
	private function lowerStarBlockEndedSepLast(
		leadText: String, trailText: String, elemCT: ComplexType, elemCall: Expr, closeNotNextExpr: Expr, ctorCall: Expr, sepCharCode: Int,
		sepText: String, predicateCall: Expr
	): Expr {
		return macro {
			skipWs(ctx);
			expectLit(ctx, $v{leadText});
			final _items: Array<$elemCT> = [];
			skipWs(ctx);
			if ($closeNotNextExpr) {
				var _prevEndPos: Int = ctx.pos;
				_items.push($elemCall);
				_prevEndPos = ctx.pos;
				skipWs(ctx);
				while ($closeNotNextExpr) {
					if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						if (!($closeNotNextExpr)) break; // L1: tolerate trailing sep before close
						_items.push($elemCall);
						_prevEndPos = ctx.pos;
						skipWs(ctx);
					} else if (
						_prevEndPos > 0 && {
							var _pebRew: Int = _prevEndPos - 1;
							while (_pebRew > 0) {
								final _bc: Int = ctx.input.charCodeAt(_pebRew);
								if (_bc == ' '.code || _bc == '\t'.code || _bc == '\n'.code || _bc == '\r'.code)
									_pebRew--;
								else
									break;
							}
							final _b: Int = ctx.input.charCodeAt(_pebRew);
							_b == ';'.code || $predicateCall;
						}
					) {
						_items.push($elemCall);
						_prevEndPos = ctx.pos;
						skipWs(ctx);
					} else {
						expectLit(ctx, $v{sepText});
					}
				}
			}
			skipWs(ctx);
			expectLit(ctx, $v{trailText});
			return $ctorCall;
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
		final atomOperand: Bool = branch.fmtHasFlag('atomOperand');
		final subFnName: String = atomOperand ? '${parseFnName(refName)}Atom' : parseFnName(refName);
		final callSub: Expr = {
			expr: ECall(macro $i{subFnName}, [macro ctx]),
			pos: Context.currentPos(),
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
		final triviaCaptureSource: Bool = _ctx.trivia && isTriviaBearing(typePath) && TriviaTypeSynth.isCaptureSourceBranch(branch);
		// ω-issue-257-firstline: ctors with `@:fmt(bodyPolicy(...))` on a
		// single-Ref kw-led branch (e.g. `HxStatement.ReturnStmt`) carry
		// a positional `bodyOnSameLine:Bool` arg in the synth pair. The
		// parser captures whether the post-kw whitespace crossed a
		// newline so `bodyPolicyWrap`'s `Keep` branch can dispatch
		// source-shape-aware. Trivia-only — plain mode keeps the
		// original ctor arity and falls back to width-driven layout
		// via `widthAware`.
		final triviaBodyPolicyKw: Bool = _ctx.trivia && isTriviaBearing(typePath) && TriviaTypeSynth.isAltBodyPolicyKwBranch(branch);
		// omega-paren-wrap-source-newline: ctors with @:fmt(captureWrapOpenNewline)
		// on a single-Ref @:wrap branch carry a positional wrapOpenNewline:
		// Bool arg in the synth pair. Parser captures whether the gap
		// between the open lead literal and the inner sub-rule's first
		// token crossed a newline so the writer can pick between
		// `(\n<inner>\n)` (open broken; preserves authored shape on
		// chain inners) and `(<inner>\n)` (glued; unchanged default).
		// Trivia-only; plain mode keeps the original ctor arity.
		final triviaWrapOpenNewline: Bool = _ctx.trivia && isTriviaBearing(typePath) && TriviaTypeSynth.isAltWrapOpenNewlineBranch(branch);
		// ω-keep-kw-newline (increment 1b): mandatory-`@:kw` VarStmt-family
		// ctors with `@:fmt(captureKwNewline)` carry a positional
		// `kwNewline:Bool` arg. The parser captures whether the gap between
		// the LAST keyword / lead literal (`var` / `final`) and the inner
		// `decl` Ref's first token crossed a newline, so the writer's
		// `HxVarDecl` multiVar fold reproduces the source `var`→head newline
		// under `WrapMode.Keep`. Trivia-only; plain mode keeps the original
		// ctor arity (head always glued to `var `).
		final triviaKwNewline: Bool = _ctx.trivia && isTriviaBearing(typePath) && TriviaTypeSynth.isAltKwNewlineBranch(branch);
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
				'Lowering: @:fmt(forwardNewlineForBody) on a @:fmt(bodyPolicy(...)) branch is a conflict — both channels capture the post-kw newline; pick one.',
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
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
		if (trailText != null) appendKwRefTrailStep(steps, trailText, triviaTrailOpt, triviaCaptureSource, trailOptional, parseGateCall);
		appendRejectFollowKwStep(steps, branch);
		steps.push(macro return $ctorCall);
		return macro $b{steps};
	}

	/**
	 * Branch-level `@:rejectFollowKw('<kw>')`: a negative lookahead that makes an
	 * otherwise-successful branch backtrack when the named keyword is the next token.
	 *
	 * The case it exists for is a branch whose trailing `@:tryparse` Star can legally
	 * match ZERO elements. Such a branch reports success on input the NEXT branch was
	 * meant to take, and `tryBranch` never gets to roll back — it only rolls back on
	 * failure. `HxStatement.TryCatchStmt` is exactly that shape: `catches` is a
	 * `@:tryparse` Star and a catch-less `try {…}` is valid Haxe, so a `try` whose
	 * catch bodies are bare expressions (`catch (e:E) f(e) catch (e2:F) g(e2);` — no
	 * `;` before the second `catch`, hence no `HxStatement` to match) parsed as a
	 * catch-less try and left the `catch` chain for the enclosing block, which fails.
	 * Rejecting a following `catch` hands that input to `TryCatchStmtBare`, whose
	 * `HxExpr` bodies do match it.
	 *
	 * The peek runs on a saved position that is restored either way: the branch either
	 * throws, or returns with `ctx.pos` exactly where the parse left it, so the trivia
	 * scan of whatever comes next is unaffected.
	 */
	private function appendRejectFollowKwStep(steps: Array<Expr>, branch: ShapeNode): Void {
		final rejectKw: Null<String> = branch.readMetaString(':rejectFollowKw');
		if (rejectKw == null) return;

		steps.push(macro {
			final _rejectPos: Int = ctx.pos;
			skipWs(ctx);
			final _rejectHit: Bool = peekKw(ctx, $v{rejectKw});
			ctx.pos = _rejectPos;
			if (_rejectHit) throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/**
	 * Append the kw/lead literal-consume steps (plus the trivia-mode newline
	 * / source-position probes) to a `lowerKwRefBranch` step list. Either or
	 * both of kw and lead may be absent.
	 */
	private function appendKwRefLeadSteps(
		steps: Array<Expr>, kwLead: Null<String>, leadText: Null<String>, triviaKwNewline: Bool, triviaBodyPolicyKw: Bool,
		forwardNewlineForBody: Bool, triviaWrapOpenNewline: Bool
	): Void {
		// ω-keep-kw-newline (increment 1b): track the byte position right
		// after the LAST consumed keyword / lead literal (BEFORE its post-
		// literal `skipWs`) so the `_varKwNewline` probe spans the gap up to
		// the inner `decl` Ref's first token. Reassigned after each
		// `expectKw` / `expectLit` so the last one wins (`static var` →
		// after `var`). Declared only when the branch opts in.
		if (triviaKwNewline) steps.push(macro var _lastLitEnd: Int = ctx.pos);
		if (kwLead != null) {
			steps.push(macro expectKw(ctx, $v{kwLead}));
			if (triviaKwNewline) steps.push(macro _lastLitEnd = ctx.pos);
			// ω-issue-257-firstline: capture `_kwEndPos` BEFORE the
			// post-kw `skipWs` so `_bodyOnSameLine` can probe whether
			// the gap up to the body's first token crossed a newline.
			// Mirrors the struct-side `_bodyOnSameLine_<field>` capture
			// in `lowerStruct`'s `@:optional @:kw` path.
			if (triviaBodyPolicyKw) steps.push(macro final _kwEndPos: Int = ctx.pos);
			if (!forwardNewlineForBody) steps.push(macro skipWs(ctx));
			if (triviaBodyPolicyKw) steps.push(macro final _bodyOnSameLine: Bool = !hasNewlineIn(ctx.input, _kwEndPos, ctx.pos));
		}
		if (leadText != null) {
			steps.push(macro expectLit(ctx, $v{leadText}));
			if (triviaKwNewline) steps.push(macro _lastLitEnd = ctx.pos);
			// omega-paren-wrap-source-newline: capture _leadEndPos BEFORE
			// the post-lead skipWs so _wrapOpenNewline can probe whether
			// the gap up to the inner sub-rule's first token crossed a
			// newline. Mirrors the kw-led _kwEndPos / _bodyOnSameLine
			// pattern above.
			if (triviaWrapOpenNewline) steps.push(macro final _leadEndPos: Int = ctx.pos);
			steps.push(macro skipWs(ctx));
			if (triviaWrapOpenNewline) steps.push(macro final _wrapOpenNewline: Bool = hasNewlineIn(ctx.input, _leadEndPos, ctx.pos));
		}
		// ω-keep-kw-newline (increment 1b): the gap probe runs AFTER both the
		// kw and lead skipWs but BEFORE `_raw = callSub`, so `ctx.pos` sits at
		// the inner `decl` Ref's first token. `_lastLitEnd` holds the end of
		// the last literal before its skipWs, so `hasNewlineIn` spans exactly
		// the `var`→head gap.
		if (triviaKwNewline) steps.push(macro final _varKwNewline: Bool = hasNewlineIn(ctx.input, _lastLitEnd, ctx.pos));
	}

	/**
	 * Append the optional trail-literal consume step to a `lowerKwRefBranch`
	 * step list, threading the trivia-mode trailing-trivia stash, the
	 * source-text slice, and the parse-gated optional-`;` decision (Slices
	 * V/X2/X3/X4).
	 */
	private function appendKwRefTrailStep(
		steps: Array<Expr>, trailText: String, triviaTrailOpt: Bool, triviaCaptureSource: Bool, trailOptional: Bool,
		parseGateCall: Null<Expr>
	): Void {
		// noqa: complexity
		// ω-trailopt-stash-trivia: in trivia mode + `@:trailOpt`, use
		// `skipWsAndStash` so trailing comments between the body and
		// the optional trail literal land in `ctx.pendingTrivia`.
		// When the trail is ABSENT (e.g. `typedef Foo = Int\n/** doc
		// **/\ntypedef Bar`), the parent Star's next `collectTrivia`
		// drains the stash and the doc-comment becomes leading of the
		// next decl. The plain `skipWs` path silently dropped it.
		// Cases: issue_216 / issue_321 closures. Mandatory `@:trail`
		// paths keep the original `skipWs` — comments before a
		// required trail literal are intra-decl close trivia and the
		// downstream writer handles them via close-trail slots.
		if (triviaTrailOpt) {
			// ω-trailopt-stash-trivia: capture the gap between the
			// inner Ref's last byte and the (optional) trail literal
			// via `collectTrivia` — captures `newlineBefore` /
			// `blankBefore` AND any line/block comments. Re-stash
			// into `ctx.pendingTrivia` when anything was captured so
			// the parent Star's next `collectTrivia` drains them as
			// leading of the next sibling decl (the trail literal
			// was absent so there's no intra-decl trailing slot to
			// route to). Plain `skipWsAndStash` would lose the
			// blank/newline signal.
			steps.push(macro {
				final _trailOptCap = collectTrivia(ctx);
				if (
					_trailOptCap.newlineBefore || _trailOptCap.blankBefore || _trailOptCap.blankAfterLeadingComments
					|| _trailOptCap.leadingComments.length > 0
				) {
					ctx.pendingTrivia = {
						blankBefore: _trailOptCap.blankBefore,
						blankAfterLeadingComments: _trailOptCap.blankAfterLeadingComments,
						newlineBefore: _trailOptCap.newlineBefore,
						leadingComments: _trailOptCap.leadingComments,
					};
				}
			});
		} else
			steps.push(macro skipWs(ctx));
		// Capture _end_pos AFTER the post-Ref skipWs but BEFORE the
		// trail-literal match, so trailing whitespace inside the
		// braces (e.g. `${ i + 1 }`) is included in the verbatim
		// slice. In `@:raw` rules the skipWs is stripped at post-
		// process time and the capture lands at the position of
		// the trail literal directly.
		if (triviaCaptureSource) {
			steps.push(macro final _end_pos: Int = ctx.pos);
			steps.push(macro final _sourceText: String = ctx.input.substring(_start_pos, _end_pos));
		}
		// `@:trailOpt` annotates `lit.trailOptional:true` alongside
		// `lit.trailText`. The trail literal becomes optional on
		// parse — `matchLit` peeks + consumes if present, but does
		// NOT throw if absent. In trivia mode the captured presence
		// flag flows into the synth ctor's extra `trailPresent:Bool`
		// arg (ω-trailopt-source-track). Plain
		// mode keeps the original ctor arity and falls back to
		// AST-shape gates such as `@:fmt(trailOptShapeGate(...))`
		// in the writer.
		// Consumers: `HxDecl.TypedefDecl` for `typedef Foo = T`
		// without trailing `;` (ω-typedef-trailOpt);
		// `HxStatement.VarStmt` / `FinalStmt` for `var foo =
		// switch (x) { case _: 1 }` without trailing `;` (slice
		// ω-vardecl-trailOpt — the `}`-terminated rhs idiom).
		// ω-slice-V: when `@:fmt(trailOptParseGate(...))` is present
		// (parseGateCall != null) the matchLit/expectLit choice is
		// made at runtime from the parsed child shape, so a
		// non-brace expr still hits `expectLit` (throws → statement
		// boundary preserved). Without the gate the emission is
		// unchanged (byte-identical for
		// every other ctor).
		// ω-slice-X2: extend the ω-slice-V gate so the trail `;` is
		// ALSO optional when an `else` keyword immediately follows.
		// An `ExprStmt` followed by `else` is only ever an
		// if-then-body in valid Haxe (a stray `else` after any other
		// statement was already a parse error), so relaxing the `;`
		// there only newly-accepts the valid `if (c) bareExpr else
		// …` form — it cannot regress a previously-valid input. The
		// `peekKw` is non-consuming (the `else` belongs to
		// `HxIfStmt.elseBody`'s own `@:optional @:kw('else')`). Still
		// `parseGateCall`-guarded (sole consumer `HxStatement.
		// ExprStmt`) → byte-identical for every other ctor.
		// ω-slice-X3 (`}`-terminator): extend the gate
		// further so the trail `;` is optional when the next non-
		// trivia byte is `}`. An `ExprStmt` followed by `}` is only
		// ever the last stmt of an enclosing block in valid Haxe —
		// the closing brace itself is unambiguously the statement
		// separator, regardless of the just-parsed expr's kind. This
		// generalises the earlier per-ctor extensions
		// (BlockExpr / MetaExpr-ReturnExpr /
		// ObjectLit / ArrayExpr / DollarBlockExpr / Is) — each only
		// got `;` elision because its OWN tail token happened to
		// close a brace/bracket; the principled invariant is
		// extrinsic, not intrinsic. Cascade-safe: `f(); g();` keeps
		// the inter-stmt `;` because `peekLit("}")` only succeeds
		// when `}` is genuinely next; `f() g()` (no `;`, no `}`)
		// still throws on the missing `;`. The `peekLit` is
		// non-consuming — the `}` belongs to the enclosing block's
		// Star `@:trail('}')`. Sole consumer remains `HxStatement.
		// ExprStmt`.
		//
		// ω-slice-X4 (`case`/`default`-terminator): extend
		// the gate further so the trail `;` is optional when the
		// next non-trivia bytes form a word-boundary-checked
		// `case` or `default` keyword. `case` and `default` are
		// reserved in Haxe and legal ONLY as switch arm labels, so
		// an `ExprStmt` followed by either keyword can only be the
		// last stmt of a switch arm — the next `case`/`default`
		// label itself is unambiguously the arm separator,
		// regardless of the just-parsed expr's kind.
		// Motivating shape: try-expr-catch `try x = foo()
		// catch (e:Exception) { … }` as the body of a switch arm
		// followed by another `case`. Byte-twin of the `peekKw("else")`
		// disjunct above — same word-boundary check, same
		// non-consuming nature (the `case`/`default` belongs to the
		// enclosing switch's `Star` of case clauses). Sole consumer
		// remains `HxStatement.ExprStmt`. Cascade-safe: `f() g()`
		// inside a switch arm still throws (`g` is neither `case`
		// nor `default`).
		//
		// `#end` / `#else` / `#elseif` disjuncts (ω-cond-body-nosemi):
		// a no-semi last statement inside a `#if` conditional BODY is legal
		// Haxe (dogfood shape: `haxe.Log.trace = (v) -> {…}` directly
		// before `#end`). The conditional-body Star has no `}` close for the
		// `peekLit` disjunct to see, so the preprocessor terminators must be
		// first-class gate exits like `case`/`default` are for switch arms.
		final gateCond: Null<Expr> = parseGateCall != null
			? (macro ($parseGateCall || peekKw(ctx, 'else') || peekLit(ctx, '}') || peekKw(ctx, 'case') || peekKw(ctx, 'default')
				|| peekKw(ctx, '#end') || peekKw(ctx, '#else') || peekKw(ctx, '#elseif')))
			: null;
		if (parseGateCall != null && triviaTrailOpt)
			steps.push(macro final _trailPresent: Bool = $gateCond ? matchLit(ctx, $v{trailText}) : {
				expectLit(ctx, $v{trailText});
				true;
			});
		else if (parseGateCall != null && trailOptional)
			steps.push(macro if ($gateCond)
				matchLit(ctx, $v{trailText})
			else
				expectLit(ctx, $v{trailText}));
		else if (triviaTrailOpt)
			steps.push(macro final _trailPresent: Bool = matchLit(ctx, $v{trailText}));
		else if (trailOptional)
			steps.push(macro matchLit(ctx, $v{trailText}));
		else
			steps.push(macro expectLit(ctx, $v{trailText}));
	}

	/**
	 * Build the synth-ctor call for a `lowerKwRefBranch` ctor, appending the
	 * trivia-mode positional args (`_trailPresent` / `_sourceText` /
	 * `_bodyOnSameLine` / `_wrapOpenNewline` / `_varKwNewline`) the active
	 * capture channels carry.
	 */
	private function buildKwRefCtorCall(
		ctorRef: Expr, triviaTrailOpt: Bool, triviaCaptureSource: Bool, triviaBodyPolicyKw: Bool, triviaWrapOpenNewline: Bool,
		triviaKwNewline: Bool
	): Expr {
		final ctorArgs: Array<Expr> = [macro _raw];
		if (triviaTrailOpt) ctorArgs.push(macro _trailPresent);
		if (triviaCaptureSource) ctorArgs.push(macro _sourceText);
		if (triviaBodyPolicyKw) ctorArgs.push(macro _bodyOnSameLine);
		if (triviaWrapOpenNewline) ctorArgs.push(macro _wrapOpenNewline);
		if (triviaKwNewline) ctorArgs.push(macro _varKwNewline);
		return { expr: ECall(ctorRef, ctorArgs), pos: Context.currentPos() };
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
			pos: Context.currentPos(),
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
			pos: Context.currentPos(),
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

	/**
	 * Emit the `case Ref if (isOptional)` struct-field arm: the lead/kw/absentOn
	 * peek-commit machinery for an optional Ref field. Pushes a single `EVars`
	 * (the `_f_<field>` capture) onto `parseSteps`. Threaded from `lowerStruct`
	 * so the loop's mutable accumulators stay in the loop; this helper is a pure
	 * Expr-builder over the per-field locals it receives.
	 */
	private function emitOptionalRefField(
		child: ShapeNode, fieldName: String, localName: String, parseSteps: Array<Expr>, kwLead: Null<String>, leadText: Null<String>,
		trailText: Null<String>, absentOnLits: Null<Array<String>>, hasOptionalRefAfterTrailSlot: Bool, captureTrailPresentExpr: Expr,
		hasKwTriviaSlots: Bool, afterKwLocal: String, kwLeadingLocal: String, beforeKwNlLocal: String, bodyOnSameLineLocal: String,
		beforeKwLeadingLocal: String, beforeKwTrailingLocal: String
	): Void {
		if (kwLead == null && leadText == null && absentOnLits == null) {
			Context.fatalError('Lowering: @:optional struct field "$fieldName" requires @:lead, @:kw or @:absentOn', Context.currentPos());
		}
		final refName: String = child.annotations[AnnotationKeys.BASE_REF];
		final subCallRaw: Expr = {
			expr: ECall(macro $i{parseFnName(refName)}, [macro ctx]),
			pos: Context.currentPos(),
		};
		// ω-optional-ref-trail: consume the per-field `@:trail`
		// literal AFTER the sub-rule parse, INSIDE the lead-led
		// commit branch. Mirrors the mandatory-Ref trail emit
		// (see post-switch block) but threaded into the optional
		// path so the commit-miss branch (lead absent) does not
		// expect a close. First consumer: `HxAbstractDecl.
		// underlyingType` for the `@:coreType` bare-abstract
		// shape `abstract Foo from Int to Int {}`.
		final captureAfterTrail: Expr = hasOptionalRefAfterTrailSlot
			? macro $i{'_afterTrail_$fieldName'} = collectTrailingFull(ctx)
			: macro {};
		// ω-optional-ref-trailOpt (Session 11 path b): consume
		// the per-field `@:trailOpt(';')` literal AFTER the
		// sub-rule parse, INSIDE the lead/kw commit branch.
		// Mirrors the mandatory `@:trail` arm above but uses
		// peek+consume+rewind (no throw on miss) so existing
		// self-consuming inner stmts (ReturnStmt-pre-S10.3,
		// ExprStmt, etc.) stay no-op. First consumer:
		// `HxIfStmt.elseBody` (`if (c) ...; else ...;` —
		// post-S10.3 ReturnStmt migration target). The
		// post-switch `lit.trailOptional` block (~L2500) is
		// gated `!isOptional`, so this arm is the optional+kw
		// path's sole emitter.
		final trailOptText: Null<String> = child.annotations[AnnotationKeys.LIT_TRAIL_OPTIONAL] == true
			? child.annotations[AnnotationKeys.LIT_TRAIL_TEXT]
			: null;
		final subCall: Expr = if (trailText != null)
			macro {
				final _v = $subCallRaw;
				skipWs(ctx);
				expectLit(ctx, $v{trailText});
				$captureAfterTrail;
				_v;
			}
		else if (trailOptText != null)
			macro {
				final _v = $subCallRaw;
				final _trailOptWsPos: Int = ctx.pos;
				skipWs(ctx);
				if (matchLit(ctx, $v{trailOptText}))
					$captureTrailPresentExpr;
				else
					ctx.pos = _trailOptWsPos;
				_v;
			}
		else
			subCallRaw;
		// In trivia or span mode a bearing ref needs the Null<XxxT>
		// / Null<XxxS> wrap around the synth pair — `base.fieldType`
		// captured the plain-mode `Null<Xxx>` form at shape-analysis
		// time so we rebuild it here when the target is bearing;
		// otherwise the cached annotation is re-used unchanged.
		final fieldCT: ComplexType = isSpanBearing(refName) || isTriviaBearing(refName)
			? TPath({ pack: [], name: 'Null', params: [TPType(ruleReturnCT(refName))] })
			: child.annotations[AnnotationKeys.BASE_FIELD_TYPE];
		if (absentOnLits != null) {
			// `@:absentOn(lit1, lit2, ...)` — peek-ahead absence
			// dispatch. The listed terminators are NOT consumed
			// (they belong to the enclosing context); the parser
			// just decides whether to call `parseRef` or set the
			// field to `null`. On absence the pre-ws position is
			// restored so any leading whitespace stays visible to
			// the parent's next `skipWs`. On presence the call
			// runs from the post-ws position; `parseRef` does not
			// double-skip. Trivia mode applies the same
			// `pendingTrivia` stash as the lead-led branch so
			// leading comments captured before an absent body
			// flow to the next sibling's `collectTrivia`.
			final peekChain: Expr = {
				var acc: Expr = macro peekLit(ctx, $v{absentOnLits[0]});
				for (i in 1...absentOnLits.length) {
					final lit: String = absentOnLits[i];
					acc = macro $acc || peekLit(ctx, $v{lit});
				}
				acc;
			};
			final wsAction: Expr = _ctx.trivia
				? macro {
					final _t = collectTrivia(ctx);
					if (_t.leadingComments.length > 0 || _t.blankBefore || _t.blankAfterLeadingComments || _t.newlineBefore)
						ctx.pendingTrivia = _t;
				}
				: macro skipWs(ctx);
			final absentOnValueExpr: Expr = macro {
				final _wsPos: Int = ctx.pos;
				$wsAction;
				if ($peekChain) {
					ctx.pos = _wsPos;
					null;
				} else {
					$subCall;
				}
			};
			parseSteps.push({
				expr: EVars([
					{
						name: localName,
						type: fieldCT,
						expr: absentOnValueExpr,
						isFinal: true,
					}
				]),
				pos: Context.currentPos(),
			});
		} else {
			emitOptionalRefLeadCommit(
				parseSteps, localName, fieldCT, subCall, kwLead, leadText, hasKwTriviaSlots, afterKwLocal, kwLeadingLocal, beforeKwNlLocal,
				bodyOnSameLineLocal, beforeKwLeadingLocal, beforeKwTrailingLocal
			);
		}
	}

	/**
	 * Compute the per-field pre-emit dispatch booleans for one struct field.
	 * These gate the pre-field whitespace/trivia handling and the
	 * `<field>BeforeNewline` / `<field>BeforeLeading` synth-slot captures.
	 * The intermediate flags (`isBareTriviaRefNoLead`, `isFirstField`, …) stay
	 * internal; only the six downstream-read flags are returned. Lifted from
	 * `lowerStruct`'s per-field loop to keep its decision points out of the
	 * orchestrator.
	 */
	private function computeStructFieldFlags(
		child: ShapeNode, node: ShapeNode, typePath: String, isStar: Bool, isOptional: Bool, kwLead: Null<String>, leadText: Null<String>
	): {
		triviaEofStar: Bool,
		isOptionalRef: Bool,
		isOptionalKwStar: Bool,
		hasBeforeNewlineSlot: Bool,
		hasBeforeLeadingSlot: Bool,
		optStarWithLead: Bool
	} {
		final triviaEofStar: Bool = isStar && child.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true
			&& child.readMetaString(':lead') == null && child.readMetaString(':kw') == null && _ctx.trivia;
		// Slice ω₆a: an @:optional Ref field takes ownership of its own
		// pre-field ws handling so the commit-check can rewind over the
		// just-consumed whitespace (and any comments inside it, in trivia
		// mode) when the kw/lead miss — that trivia belongs to the next
		// outer @:trivia Star loop, not to this discarded optional slot.
		final isOptionalRef: Bool = child.kind == Ref && isOptional;
		// ω-cond-comp-engine: `@:optional @:kw + tryparse Star` — kw-led
		// commit point on a Star field. Splices the kw commit + miss-rewind
		// machinery from the optional-Ref path with the tryparse Star loop
		// body. Mirrors `isOptionalRef`'s pre-field ws ownership: the
		// commit-check below performs its own ws scan + rewind so trivia
		// stays visible to the next outer @:trivia Star on commit miss.
		// First consumer: `HxConditionalDecl.elseBody` (`#if … #else <decls>
		// #end`). Replaces the pre-slice Ref-wrapper companion typedef
		// pattern (extra fn frame + wrapper struct alloc per `#else` hit).
		final isOptionalKwStar: Bool = child.kind == Star && isOptional && kwLead != null;
		// ω-issue-48-v2: a bare non-first Ref field (no `@:optional`, no
		// `@:kw`, no `@:lead`) in a trivia-bearing Seq captures the
		// `newlineBefore` signal in the gap between preceding content
		// and the sub-rule's first token. Needed when the preceding
		// bare-tryparse Star is empty (e.g. `HxMemberDecl.modifiers`
		// empty → `member` follows an `@:allow(...)\n` meta element):
		// the Star's rewind stashes trivia back to `ctx.pendingTrivia`,
		// and the pre-Ref `collectTrivia` here drains it, preserving
		// the newline on the synth `<field>BeforeNewline:Bool` slot.
		//
		// ω-untyped-keep-trybody: opt-in `@:fmt(beforeNewlineSlotFirst)`
		// extends the slot to FIRST Ref fields when the parent Alt-branch
		// carries `@:fmt(forwardNewlineForBody)` (which omits the parent's
		// post-kw `skipWs`). The first-field `collectTrivia` then scans
		// the gap between the parent kw and the field's first token
		// itself, capturing `newlineBefore` for the writer's `Keep`
		// dispatch. Currently consumed by `HxTryCatchStmt.body` to
		// preserve `try\n\tuntyped {…}` source shape under
		// `untypedBody=Keep`.
		final beforeSlots: { hasBeforeNewlineSlot: Bool, hasBeforeLeadingSlot: Bool } = computeBeforeSlots(
			child, node, typePath, isStar, isOptional, kwLead, leadText
		);
		final hasBeforeNewlineSlot: Bool = beforeSlots.hasBeforeNewlineSlot;
		final hasBeforeLeadingSlot: Bool = beforeSlots.hasBeforeLeadingSlot;
		// ω-casepattern-keep: extend the first-field source-newline-before
		// capture to a bare (lead-less, non-optional) trivia Star whose
		// parent omits its post-kw `skipWs` via `forwardNewlineForBody`.
		// The condition Star (`HxCaseBranch.patterns`, `@:sep(',')
		// @:trail(':')`) then captures `newlineBefore` for the `case`→
		// pattern gap onto a `<field>BeforeNewline:Bool` slot, mirroring
		// the bare-Ref first-field case (`HxTryCatchStmt.body`). Gated on
		// the `beforeNewlineSlotFirst` opt-in so every other bare trivia
		// Star (no opt-in) keeps the plain pre-field `skipWs`.
		// ω-598-member-leading-comment: the bare non-first Ref host (e.g.
		// `HxMemberDecl.member`) additionally captures the `collectTrivia`
		// run's `leadingComments` into a `<field>BeforeLeading` slot. Gated
		// on the bare-Ref host (matches `TriviaTypeSynth.isBareNonFirstRef`),
		// NOT the Star-opt-in host. Without it, a multiline block comment
		// sitting between the last modifier and the member keyword (rejected
		// by the modifier Star's `collectTrailingFull` for its internal
		// newline) is scanned here but discarded.
		// ω-optional-star-rewind: when the field is `@:optional Star`
		// with `@:lead` (e.g. `HxTypeRef.params:Array<HxType>` —
		// `<...>`), defer the pre-field `skipWs` into the emit so the
		// emit can rewind cursor on `matchLit` miss. The miss-rewind
		// preserves any trivia (notably doc-comments between
		// `typedef Foo = Int` and the next decl) that the pre-field
		// `skipWs` would otherwise silently consume — closes
		// issue_216 / issue_321 cluster's parser-side bug.
		final optStarWithLead: Bool = isStar && isOptional && kwLead == null;
		return {
			triviaEofStar: triviaEofStar,
			isOptionalRef: isOptionalRef,
			isOptionalKwStar: isOptionalKwStar,
			hasBeforeNewlineSlot: hasBeforeNewlineSlot,
			hasBeforeLeadingSlot: hasBeforeLeadingSlot,
			optStarWithLead: optStarWithLead,
		};
	}

	/**
	 * Push the trivia-Star sidecar slots (`<field>TrailingBlankBefore` /
	 * `TrailingNewlineBefore` / `TrailingLeading` / `TrailingClose` /
	 * `TrailingOpen` / `TrailingBlankAfter` / `TrailPresent`) onto the struct
	 * literal for a `@:trivia`-collecting Star field. Each slot is gated on the
	 * same annotation that `TriviaTypeSynth` uses to grow it, so the field set
	 * matches the synth-define exactly. Pure — lifted from `lowerStruct`'s
	 * per-field loop.
	 */
	private function pushTrailingStarSlots(
		child: ShapeNode, localName: String, fieldName: Null<String>, structFields: Array<ObjectField>
	): Void {
		final trailBBLocal: String = trailingBlankBeforeLocalName(localName);
		final trailNLLocal: String = trailingNewlineBeforeLocalName(localName);
		final trailLCLocal: String = trailingLeadingLocalName(localName);
		structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_BLANK_BEFORE_SUFFIX, expr: macro $i{trailBBLocal} });
		// ω-keep-fnsig-newline: sibling close-newline push, unconditional
		// next to TrailingBlankBefore so the struct-literal field set
		// matches the synth-define exactly.
		structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_NEWLINE_BEFORE_SUFFIX, expr: macro $i{trailNLLocal} });
		structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_LEADING_SUFFIX, expr: macro $i{trailLCLocal} });
		// ω-close-trailing: the synth slot exists only for close-peek
		// Stars (see `TriviaTypeSynth.buildStarTrailingSlots`). Gate
		// the push on the Star's own `lit.trailText` annotation so
		// EOF-mode Stars (e.g. `HxModule.decls`) skip the field.
		if (child.annotations[AnnotationKeys.LIT_TRAIL_TEXT] != null) {
			final trailCloseLocal: String = trailingCloseLocalName(localName);
			structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_CLOSE_SUFFIX, expr: macro $i{trailCloseLocal} });
		}
		// ω-open-trailing: synth slot exists only for Stars with
		// `@:lead` AND not `@:tryparse` (the tryparse writer helper
		// does not consume the slot — see TriviaTypeSynth gate +
		// `emitTriviaStarFieldSteps`'s open-text capture gate).
		if (child.annotations[AnnotationKeys.LIT_LEAD_TEXT] != null && !child.hasMeta(':tryparse')) {
			final trailOpenLocal: String = trailingOpenLocalName(localName);
			structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_OPEN_SUFFIX, expr: macro $i{trailOpenLocal} });
		}
		// ω-trail-blank-after: synth slot exists only for `@:tryparse +
		// @:fmt(nestBody)` Stars (see TriviaTypeSynth gate). Gate the
		// push the same way; emitTriviaStarFieldSteps's tryparse+nestBody
		// branch is the sole producer of `trailBALocal`.
		if (child.hasMeta(':tryparse') && child.fmtHasFlag('nestBody')) {
			final trailBALocal: String = trailingBlankAfterLocalName(localName);
			structFields.push({ field: fieldName + TriviaTypeSynth.TRAILING_BLANK_AFTER_SUFFIX, expr: macro $i{trailBALocal} });
		}
		// ω-objectlit-source-trail-comma: synth slot exists only for
		// sep-Stars with a close literal (see TriviaTypeSynth gate).
		// Both `lit.sepText` and `lit.trailText` are populated by the
		// Lit strategy before Lowering runs, so reading from
		// annotations here mirrors the close-trailing / open-trailing
		// gates above.
		if (child.annotations[AnnotationKeys.LIT_SEP_TEXT] == null || child.annotations[AnnotationKeys.LIT_TRAIL_TEXT] == null) return;
		final trailPresentLocal: String = trailPresentLocalName(localName);
		structFields.push({ field: fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX, expr: macro $i{trailPresentLocal} });
	}

	/**
	 * Push the parsed field value plus every applicable trivia/source-shape
	 * sidecar slot onto the struct literal for one field. Each `<field>*`
	 * synth slot is gated on the same `has*Slot` flag that grew it, so the
	 * struct-literal field set matches the synth-define exactly. The flags +
	 * capture-local names are threaded as params. Lifted from `lowerStruct`'s
	 * per-field loop.
	 */
	private function pushStructFieldEntries(
		structFields: Array<ObjectField>, fieldName: Null<String>, localName: String, child: ShapeNode, hasStructFieldTrailOptSlot: Bool,
		trailPresentLocal: String, hasAfterTrailSlot: Bool, afterTrailLocal: String, hasBeforeNewlineSlot: Bool, beforeNlLocal: String,
		hasBeforeLeadingSlot: Bool, beforeLeadingLocal: String, hasNewlineAfterSlot: Bool, newlineAfterLocal: String,
		hasCondOpenNewlineSlot: Bool, condOpenNewlineLocal: String, hasKwTriviaSlots: Bool, afterKwLocal: String, kwLeadingLocal: String,
		beforeKwNlLocal: String, bodyOnSameLineLocal: String, beforeKwLeadingLocal: String, beforeKwTrailingLocal: String
	): Void {
		structFields.push({ field: fieldName, expr: macro $i{localName} });
		// ω-struct-trailopt-source-track (Session 14 Phase 3): push the
		// `<field>TrailPresent` slot fed by the optional-Ref / mandatory-
		// Ref `@:trailOpt` capture above. Phase 4 wires the writer
		// reader; until then the populated true/false value is
		// unobserved (the slot's `@:optional Null<Bool>` shape would
		// also accept omission, but explicit push keeps the field
		// shape consistent and gives the writer a defined value at
		// every site).
		if (hasStructFieldTrailOptSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX, expr: macro $i{trailPresentLocal} });
		if (hasAfterTrailSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.AFTER_TRAIL_SUFFIX, expr: macro $i{afterTrailLocal} });
		if (hasBeforeNewlineSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX, expr: macro $i{beforeNlLocal} });
		// ω-598-member-leading-comment: push the verbatim leading-comment
		// run captured alongside the BeforeNewline scan above.
		if (hasBeforeLeadingSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_LEADING_SUFFIX, expr: macro $i{beforeLeadingLocal} });
		if (hasNewlineAfterSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.NEWLINE_AFTER_SUFFIX, expr: macro $i{newlineAfterLocal} });
		// ω-condition-wrap-keep: push the `<field>CondOpenNewline:Bool`
		// slot fed by the open-paren newline probe above. Read by the
		// writer's single-Ref condWrap emit under `WrapMode.Keep`.
		if (hasCondOpenNewlineSlot)
			structFields.push({ field: fieldName + TriviaTypeSynth.CONDITION_OPEN_NEWLINE_SUFFIX, expr: macro $i{condOpenNewlineLocal} });
		if (hasKwTriviaSlots) {
			structFields.push({ field: fieldName + TriviaTypeSynth.AFTER_KW_SUFFIX, expr: macro $i{afterKwLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.KW_LEADING_SUFFIX, expr: macro $i{kwLeadingLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_KW_NEWLINE_SUFFIX, expr: macro $i{beforeKwNlLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.BODY_ON_SAME_LINE_SUFFIX, expr: macro $i{bodyOnSameLineLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_KW_LEADING_SUFFIX, expr: macro $i{beforeKwLeadingLocal} });
			structFields.push({ field: fieldName + TriviaTypeSynth.BEFORE_KW_TRAILING_SUFFIX, expr: macro $i{beforeKwTrailingLocal} });
		}
		if (_ctx.trivia && child.kind == Star && child.annotations[AnnotationKeys.TRIVIA_STAR_COLLECTS] == true) {
			pushTrailingStarSlots(child, localName, fieldName, structFields);
		}
		// ω-condcomp-body-leading-sep: @:fmt(sepBeforeOpt)
		// on a Star field grows a `<field>SepBefore:Bool` slot fed by
		// the local declared inside `emitStarFieldSteps`'s
		// @:sep+@:tryparse-no-trail branch. The slot lives on the
		// trivia-paired typedef only (TriviaTypeSynth.buildTypeDefinition);
		// the plain typedef shape is unchanged. Gating on `ctx.trivia`
		// ensures plain-mode struct literals stay byte-identical to
		// pre-slice (the captured local is still declared above and
		// discarded — no field-shape mismatch).
		if (!(_ctx.trivia && child.kind == Star && child.fmtHasFlag('sepBeforeOpt'))) return;
		final sepBeforeLocal: String = '${localName}SepBefore';
		structFields.push({ field: fieldName + TriviaTypeSynth.SEP_BEFORE_SUFFIX, expr: macro $i{sepBeforeLocal} });
	}

	/**
	 * Compute the two trail-capture sidecar flags for a Ref field and emit
	 * their pre-declared accumulator locals: `_afterTrail_<field>` (null,
	 * filled by the optional-Ref lead-led commit branch) and
	 * `_trailPresent_<field>` (false, set true by the @:trailOpt matchLit hit).
	 * Returns the flags plus the shared `captureTrailPresentExpr` splice. Both
	 * locals are pushed onto `parseSteps`; the flags are read downstream by the
	 * switch arms, emitFieldTrail and pushStructFieldEntries. Lifted from
	 * `lowerStruct`.
	 */
	private function emitTrailSidecarDecls(
		child: ShapeNode, typePath: String, fieldName: Null<String>, isStar: Bool, isOptional: Bool, trailText: Null<String>,
		trailPresentLocal: String, parseSteps: Array<Expr>
	): {
		hasOptionalRefAfterTrailSlot: Bool,
		hasStructFieldTrailOptSlot: Bool,
		captureTrailPresentExpr: Expr
	} {
		// ω-optional-ref-trail: pre-declare the
		// `<field>AfterTrail` capture local before the parse step so
		// the optional-Ref's lead-led commit branch can assign into
		// it after `expectLit(trail)`, while the absent branch leaves
		// the default `null`. Mandatory-Ref path declares the same
		// local fresh post-trail (`final … = collectTrailing(ctx)`)
		// — the names collide harmlessly because the mandatory and
		// optional paths are mutually exclusive per field.
		final hasOptionalRefAfterTrailSlot: Bool = child.kind == Ref && isOptional && !isStar && trailText != null && _ctx.trivia
			&& isTriviaBearing(typePath);
		if (hasOptionalRefAfterTrailSlot) {
			parseSteps.push({
				expr: EVars([
					{
						name: '_afterTrail_$fieldName',
						type: macro :Null<String>,
						expr: macro null,
						isFinal: false,
					}
				]),
				pos: Context.currentPos(),
			});
		}
		// ω-struct-trailopt-source-track (Session 14 Phase 3): struct
		// typedef Ref fields carrying `@:trailOpt(LIT)` capture matchLit
		// presence into `_trailPresent_<field>:Bool`. Mirrors the
		// synth-side `<field>TrailPresent` slot pushed by
		// `TriviaTypeSynth.buildStructFieldTrailPresentSlot` (Phase 2).
		// Local is pre-declared `false` here so BOTH the mandatory-Ref
		// path (post-switch L2517) and the optional-Ref + trailOpt path
		// (inside the Ref-isOptional switch arm L2237) can write into
		// the same name (the two paths are mutually exclusive per
		// field — `!isOptional` vs `isOptional`).
		//
		// Phase 4 will read this on the writer side to gate trail
		// re-emission on source presence; until then the captured
		// value is unobserved and Δsweep stays 0.
		final hasStructFieldTrailOptSlot: Bool = child.kind == Ref && !isStar
			&& child.annotations[AnnotationKeys.LIT_TRAIL_OPTIONAL] == true && _ctx.trivia && isTriviaBearing(typePath);
		if (hasStructFieldTrailOptSlot) {
			parseSteps.push({
				expr: EVars([
					{
						name: trailPresentLocal,
						type: macro :Bool,
						expr: macro false,
						isFinal: false,
					}
				]),
				pos: Context.currentPos(),
			});
		}
		// Splicing the same `Expr` into two `macro` blocks is safe —
		// macro Expr values are AST snapshots, not consumed on splice.
		// Shared between the optional-Ref subCall arm and the mandatory-
		// Ref post-switch matchLit (mutually exclusive per field).
		final captureTrailPresentExpr: Expr = hasStructFieldTrailOptSlot ? macro $i{trailPresentLocal} = true : macro {};
		return {
			hasOptionalRefAfterTrailSlot: hasOptionalRefAfterTrailSlot,
			hasStructFieldTrailOptSlot: hasStructFieldTrailOptSlot,
			captureTrailPresentExpr: captureTrailPresentExpr,
		};
	}

	/**
	 * Emit the field-value parse steps for one struct field, dispatched by its
	 * shape kind: optional-Ref (peek-commit), bare Ref (direct sub-rule call),
	 * optional-kw Star / optional Star / plain Star (loop wrappers), or Terminal
	 * (binary fixed-len / int / data / length-prefixed). Each arm delegates to
	 * the corresponding emit*FieldSteps / emitBin* helper. Lifted from
	 * `lowerStruct`'s per-field loop.
	 */
	private function emitFieldValueByKind(
		child: ShapeNode, node: ShapeNode, fieldName: Null<String>, localName: String, parseSteps: Array<Expr>, isOptional: Bool,
		kwLead: Null<String>, leadText: Null<String>, trailText: Null<String>, absentOnLits: Null<Array<String>>,
		hasOptionalRefAfterTrailSlot: Bool, captureTrailPresentExpr: Expr, hasKwTriviaSlots: Bool, afterKwLocal: String,
		kwLeadingLocal: String, beforeKwNlLocal: String, bodyOnSameLineLocal: String, beforeKwLeadingLocal: String,
		beforeKwTrailingLocal: String, lenPrefix: Null<{ width: Int, encoding: String }>
	): Void {
		switch child.kind {
			case Ref if (isOptional):
				emitOptionalRefField(
					child, fieldName, localName, parseSteps, kwLead, leadText, trailText, absentOnLits, hasOptionalRefAfterTrailSlot,
					captureTrailPresentExpr, hasKwTriviaSlots, afterKwLocal, kwLeadingLocal, beforeKwNlLocal, bodyOnSameLineLocal,
					beforeKwLeadingLocal, beforeKwTrailingLocal
				);
			case Ref:
				final refName: String = child.annotations[AnnotationKeys.BASE_REF];
				final callExpr: Expr = {
					expr: ECall(macro $i{parseFnName(refName)}, [macro ctx]),
					pos: Context.currentPos(),
				};
				parseSteps.push({
					expr: EVars([
						{
							name: localName,
							type: null,
							expr: callExpr,
							isFinal: true,
						}
					]),
					pos: Context.currentPos(),
				});
			case Star if (isOptional && kwLead != null):
				emitOptionalKwStarFieldSteps(
					child, localName, parseSteps, kwLead, hasKwTriviaSlots, afterKwLocal, beforeKwNlLocal, bodyOnSameLineLocal,
					beforeKwLeadingLocal, beforeKwTrailingLocal
				);
			case Star if (isOptional):
				emitOptionalStarFieldSteps(child, localName, parseSteps);
			case Star:
				final isLastField: Bool = child == node.children[node.children.length - 1];
				emitStarFieldSteps(child, localName, parseSteps, isLastField);
			case Terminal:
				final binFixedLen: Null<Int> = child.annotations['bin.fixedLen'];
				final binEncoding: Null<String> = child.annotations['bin.encoding'];
				final binDataRef: Null<String> = child.annotations['bin.dataRef'];
				if (lenPrefix != null)
					emitBinLengthBytesField(localName, fieldName, parseSteps);
				else if (binFixedLen != null && binEncoding != null)
					emitBinFixedIntField(localName, binFixedLen, binEncoding, fieldName, parseSteps);
				else if (binFixedLen != null)
					emitBinFixedStringField(localName, binFixedLen, parseSteps);
				else if (binDataRef != null)
					emitBinDataField(localName, binDataRef, parseSteps);
				else
					Context.fatalError(
						'Lowering: Terminal struct field "$fieldName" requires @:bin or @:length in binary format', Context.currentPos()
					);
			case _:
				Context.fatalError('Lowering: struct field kind ${child.kind} not supported', Context.currentPos());
		}
	}

	/**
	 * ω-cond-comp-expr-multiline: terminal-slot newline capture for bare Ref
	 * fields opted in via `@:fmt(captureSourceNewlineAfter)`. Computes the
	 * `hasNewlineAfterSlot` flag and, when set, emits the `_newlineAfter_<field>`
	 * decl + the collectTrivia capture (re-stashed into `ctx.pendingTrivia` so
	 * the next field's leading-newline slot still sees it). Returns the flag +
	 * capture-local name for the downstream struct-literal push. Lifted from
	 * `lowerStruct`.
	 */
	private function emitNewlineAfterCapture(
		child: ShapeNode, typePath: String, fieldName: Null<String>, isStar: Bool, trailText: Null<String>, parseSteps: Array<Expr>
	): { hasNewlineAfterSlot: Bool, newlineAfterLocal: String } {
		final hasNewlineAfterSlot: Bool = child.kind == Ref && !isStar && trailText == null && _ctx.trivia && isTriviaBearing(typePath)
			&& child.fmtHasFlag('captureSourceNewlineAfter');
		final newlineAfterLocal: String = '_newlineAfter_$fieldName';
		if (hasNewlineAfterSlot) {
			parseSteps.push({
				expr: EVars([
					{
						name: newlineAfterLocal,
						type: macro :Bool,
						expr: macro false,
						isFinal: false,
					}
				]),
				pos: Context.currentPos(),
			});
			parseSteps.push(macro {
				final _captured = collectTrivia(ctx);
				$i{newlineAfterLocal} = _captured.newlineBefore;
				if (
					_captured.newlineBefore || _captured.blankBefore || _captured.blankAfterLeadingComments
					|| _captured.leadingComments.length > 0
				) {
					ctx.pendingTrivia = {
						blankBefore: _captured.blankBefore,
						blankAfterLeadingComments: _captured.blankAfterLeadingComments,
						newlineBefore: _captured.newlineBefore,
						leadingComments: _captured.leadingComments,
					};
				}
			});
		}
		return { hasNewlineAfterSlot: hasNewlineAfterSlot, newlineAfterLocal: newlineAfterLocal };
	}

	/**
	 * A mandatory-Ref condition field of a `@:fmt(condWrap)` struct opted in via
	 * `@:fmt(captureCondOpenNewline)` grows a `<field>CondOpenNewline:Bool` slot
	 * (trivia+bearing only). True for exactly that field shape. Pure predicate
	 * lifted from `lowerStruct`.
	 */
	private function hasCondOpenNewlineField(
		child: ShapeNode, typePath: String, isStar: Bool, isOptional: Bool, leadText: Null<String>
	): Bool {
		return child.kind == Ref && !isStar && !isOptional && leadText != null && _ctx.trivia && isTriviaBearing(typePath)
			&& child.fmtHasFlag('condWrap') && child.fmtHasFlag('captureCondOpenNewline');
	}

	/**
	 * An `@:optional @:kw(...)` Ref (or optional-kw Star) field in trivia mode
	 * on a bearing rule grows the kw-trivia sidecar slots (`<field>AfterKw` etc.).
	 * True for exactly that shape. Pure predicate lifted from `lowerStruct`.
	 */
	private function hasKwTriviaSlotsField(typePath: String, isOptionalRef: Bool, isOptionalKwStar: Bool, kwLead: Null<String>): Bool {
		return (isOptionalRef || isOptionalKwStar) && kwLead != null && _ctx.trivia && isTriviaBearing(typePath);
	}

	/**
	 * A mandatory-Ref field with `@:trail` in trivia mode on a bearing rule
	 * grows the `<field>AfterTrail` same-line-comment slot. True for exactly that
	 * shape. Pure predicate lifted from `lowerStruct`.
	 */
	private function hasAfterTrailSlotField(child: ShapeNode, typePath: String, isStar: Bool, trailText: Null<String>): Bool {
		// Mandatory Ref with @:trail, OR a @:fmt(captureTrailComment)-opted Star
		// (case-pattern list ending in `:`) — capture a same-line comment after
		// the trail literal so it stays cuddled to that token.
		return trailText != null && _ctx.trivia && isTriviaBearing(typePath)
			&& ((child.kind == Ref && !isStar) || (isStar && child.fmtHasFlag('captureTrailComment')));
	}

	/**
	 * Compute the two bare-trivia-Ref/Star BeforeNewline / BeforeLeading slot
	 * flags for a struct field. `hasBeforeNewlineSlot` captures the source
	 * newline in the gap before the field's first token (bare non-first Ref, or
	 * an opted-in first Ref/Star); `hasBeforeLeadingSlot` additionally captures
	 * the verbatim leading-comment run on the bare-Ref host. Pure — split out of
	 * `computeStructFieldFlags`.
	 */
	private function computeBeforeSlots(
		child: ShapeNode, node: ShapeNode, typePath: String, isStar: Bool, isOptional: Bool, kwLead: Null<String>, leadText: Null<String>
	): { hasBeforeNewlineSlot: Bool, hasBeforeLeadingSlot: Bool } {
		final isBareTriviaRefNoLead: Bool = child.kind == Ref && !isOptional && kwLead == null && leadText == null && _ctx.trivia
			&& isTriviaBearing(typePath);
		final isFirstField: Bool = child == node.children[0];
		final isFirstFieldNlOptIn: Bool = isBareTriviaRefNoLead && isFirstField && child.fmtHasFlag('beforeNewlineSlotFirst');
		final isBareTriviaStarNoLead: Bool = isStar && !isOptional && kwLead == null && leadText == null && _ctx.trivia
			&& isTriviaBearing(typePath);
		final isFirstFieldStarNlOptIn: Bool = isBareTriviaStarNoLead && isFirstField && child.fmtHasFlag('beforeNewlineSlotFirst');
		final hasBeforeNewlineSlot: Bool = (isBareTriviaRefNoLead && (!isFirstField || isFirstFieldNlOptIn)) || isFirstFieldStarNlOptIn;
		final hasBeforeLeadingSlot: Bool = isBareTriviaRefNoLead && (!isFirstField || isFirstFieldNlOptIn);
		return { hasBeforeNewlineSlot: hasBeforeNewlineSlot, hasBeforeLeadingSlot: hasBeforeLeadingSlot };
	}

	/**
	 * Emit the lead/kw peek-commit value for an `@:optional` Ref field (the
	 * `else` of the absentOn split): peek the lead literal or keyword; on hit,
	 * apply the post-commit trivia handling (kw-trivia capture / ω₆b stash /
	 * plain skipWs) and parse the sub-rule; on miss, rewind pos so the skipped
	 * trivia stays visible to the enclosing @:trivia Star. Pushes the
	 * `_f_<field>` EVars. Pure — split out of emitOptionalRefField.
	 */
	private function emitOptionalRefLeadCommit(
		parseSteps: Array<Expr>, localName: String, fieldCT: ComplexType, subCall: Expr, kwLead: Null<String>, leadText: Null<String>,
		hasKwTriviaSlots: Bool, afterKwLocal: String, kwLeadingLocal: String, beforeKwNlLocal: String, bodyOnSameLineLocal: String,
		beforeKwLeadingLocal: String, beforeKwTrailingLocal: String
	): Void {
		// The commit point peeks the lead literal or keyword —
		// on hit, consume and parse the sub-rule; on miss,
		// rewind pos to before the pre-commit ws scan so any
		// trivia we just skipped becomes visible again to the
		// enclosing @:trivia Star's next `collectTrivia`. No
		// backtracking over the sub-rule body (D24). Keywords
		// use matchKw for word-boundary enforcement (D47).
		final commitCheck: Expr = if (kwLead != null)
			macro matchKw(ctx, $v{kwLead})
		else
			macro matchLit(ctx, $v{leadText});
		// Post-commit trivia handling branches three ways:
		//  - Trivia mode + kw: capture same-line trailing into
		//    `_afterKw_<field>`, route own-line leadings into
		//    `_kwLeading_<field>` (ω-issue-316). Additionally
		//    capture source-shape booleans into
		//    `_beforeKwNl_<field>` (pre-kw ws crossed a newline)
		//    and `_bodyOnSameLine_<field>` (post-kw gap stayed
		//    on the same line) for the writer's `Keep` branches
		//    (ω-keep-policy).
		//  - Trivia mode + lead: ω₆b stash — any captured leading
		//    run flows into `pendingTrivia` for the sub-rule's
		//    first @:trivia Star to drain.
		//  - Plain mode: plain ws skip.
		final innerCommitAction: Expr = if (hasKwTriviaSlots)
			macro {
				final _kwEndPos: Int = ctx.pos;
				$i{afterKwLocal} = collectTrailing(ctx);
				final _t = collectTrivia(ctx);
				for (_c in _t.leadingComments) $i{kwLeadingLocal}.push(_c);
				$i{bodyOnSameLineLocal} = !hasNewlineIn(ctx.input, _kwEndPos, ctx.pos);
			}
		else if (_ctx.trivia)
			macro {
				final _t = collectTrivia(ctx);
				// Stash whenever the captured run carries any signal the
				// downstream `collectTrivia` would otherwise lose:
				// comments, blank lines, OR a single newline boundary
				// (the `newlineBefore` channel — sub-rule's first
				// `@:trivia` Star element consumes it via `_t.newlineBefore`).
				if (_t.leadingComments.length > 0 || _t.blankBefore || _t.blankAfterLeadingComments || _t.newlineBefore)
					ctx.pendingTrivia = _t;
			}
		else
			macro skipWs(ctx);
		final preCommitCapture: Expr = if (hasKwTriviaSlots)
			macro $i{beforeKwNlLocal} = hasNewlineIn(ctx.input, _prevEnd, _kwStartPos);
		else
			macro {};
		// ω-trivia-before-kw: in trivia mode + kw-bearing optional Ref,
		// the pre-commit ws scan must `collectTrivia` instead of
		// `skipWs` — otherwise own-line comments captured between the
		// preceding token and the kw (e.g. `} // comment\nelse`) are
		// silently discarded. On commit-success the captured leading
		// comments flow into `_beforeKwLeading_<field>` for the
		// writer to emit on its own line before the kw. On commit-
		// miss the rewind (`ctx.pos = _wsPos`) drops the captured
		// trivia so the enclosing Star's next `collectTrivia` re-
		// observes it.
		final valueExpr: Expr = if (hasKwTriviaSlots)
			macro {
				final _wsPos: Int = ctx.pos;
				// ω-prev-content-end: scan back past trailing whitespace consumed
				// by the preceding field's parser (notably HxExpr→Pratt, whose tail
				// loop's `skipWsAndStash` swallows `\n` before bailing on no-op
				// match — see Pratt loop tail rewind logic). Without scan-back,
				// `BeforeKwNewline = hasNewlineIn(_wsPos, _kwStartPos)` was always
				// false for `HxExpr→@:optional @:kw` siblings (HxIfExpr.elseBranch
				// most notably). `_prevEnd` walks back over [' ', '\t', '\n', '\r']
				// without touching `ctx.pos`, so `@:raw` next-siblings (e.g. `${expr}`
				// trailing `}` in HxStringSegment.Block) are unaffected.
				var _prevEnd: Int = _wsPos;
				while (_prevEnd > 0) {
					final _wsCh: Int = ctx.input.charCodeAt(_prevEnd - 1);
					if (_wsCh == ' '.code || _wsCh == '\t'.code || _wsCh == '\n'.code || _wsCh == '\r'.code)
						_prevEnd--;
					else
						break;
				}
				// ω-trivia-before-kw-trailing: probe for a single same-line
				// `// comment` after the preceding sibling's last token
				// (e.g. `resize(); // first\nelse`). `collectTrailing`
				// consumes pos to end of comment on hit, rewinds otherwise.
				// On commit-success the captured body lands in
				// `_beforeKwTrailing_<field>` for the writer to cuddle to
				// the prior token. On commit-miss the outer `ctx.pos =
				// _wsPos` rewind drops the capture so the enclosing Star's
				// next `collectTrivia` re-observes it.
				final _trailComment: Null<String> = collectTrailing(ctx);
				final _preTrivia = collectTrivia(ctx);
				final _kwStartPos: Int = ctx.pos;
				if ($commitCheck) {
					$i{beforeKwTrailingLocal} = _trailComment;
					for (_c in _preTrivia.leadingComments) $i{beforeKwLeadingLocal}.push(_c);
					$preCommitCapture;
					$innerCommitAction;
					$subCall;
				} else {
					ctx.pos = _wsPos;
					null;
				}
			}
		else
			macro {
				final _wsPos: Int = ctx.pos;
				skipWs(ctx);
				final _kwStartPos: Int = ctx.pos;
				if ($commitCheck) {
					$preCommitCapture;
					$innerCommitAction;
					$subCall;
				} else {
					ctx.pos = _wsPos;
					null;
				}
			};
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: fieldCT,
					expr: valueExpr,
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Name of the `Bool` local that records whether the trailing
	 * trivia run captured on a `@:trivia` Star's final iteration
	 * crossed a blank line. Shared between `emitTriviaStarFieldSteps`
	 * (the producer) and `lowerStruct`'s Seq-child loop (the consumer
	 * that pushes it into the struct literal).
	 */
	public static inline function trailingBlankBeforeLocalName(localName: String): String return '${localName}_trailBB';

	/**
	 * ω-keep-fnsig-newline: name of the `Bool` local that records whether the
	 * source had at least one newline (not necessarily a blank line) between
	 * the last `@:trivia` Star element and the close literal. Sibling of
	 * `trailingBlankBeforeLocalName`; set from the same terminal
	 * `_lead.newlineBefore`. Consumed by the writer's `_keepEmit` close
	 * placement to round-trip a kept signature's glued-vs-own-line close.
	 */
	public static inline function trailingNewlineBeforeLocalName(localName: String): String return '${localName}_trailNL';

	/**
	 * Name of the `Array<String>` local that records the own-line
	 * comments captured on a `@:trivia` Star's final iteration (after
	 * the last element, before the close / EOF).
	 */
	public static inline function trailingLeadingLocalName(localName: String): String return '${localName}_trailLC';

	/**
	 * Name of the `Null<String>` local that records a same-line
	 * trailing comment captured right after a close-peek `@:trivia`
	 * Star's close literal (ω-close-trailing). Only declared in the
	 * close-peek branch of `emitTriviaStarFieldSteps`; the EOF and
	 * try-parse branches skip it.
	 */
	public static inline function trailingCloseLocalName(localName: String): String return '${localName}_trailClose';

	/**
	 * Name of the `Null<String>` local that records a same-line trailing
	 * comment captured right after a `@:trivia` Star's open literal
	 * (ω-open-trailing). Mirror of `trailingCloseLocalName`. Only declared
	 * in branches of `emitTriviaStarFieldSteps` that emit the open lit
	 * (i.e. `openText != null`).
	 */
	public static inline function trailingOpenLocalName(localName: String): String return '${localName}_trailOpen';

	/**
	 * Name of the `Bool` local that records whether a tryparse+nestBody
	 * Star's stashed orphan trail run was followed by a blank line
	 * (ω-trail-blank-after). Mirrors `trailingBlankBeforeLocalName` —
	 * the "after" cousin records gap between trail and the next outer
	 * sibling, while "before" records gap between the last body element
	 * and the trail itself.
	 */
	public static inline function trailingBlankAfterLocalName(localName: String): String return '${localName}_trailBA';

	/**
	 * Name of the `Bool` local that records whether the source had a
	 * trailing separator after the last element of a `@:trivia` sep-Star
	 * with a close literal (ω-objectlit-source-trail-comma). Set by the
	 * per-iteration `matchLit(sepText)` capture inside
	 * `emitTriviaStarFieldSteps`'s sep+close branch; pushed into the
	 * synth pair's `<field>TrailPresent` slot by `lowerStruct`. Consumed
	 * by the writer's `WrapList.emit` call as the `forceExceeds` flag.
	 */
	public static inline function trailPresentLocalName(localName: String): String return '${localName}_trailPresent';

	/**
	 * Emit parse steps for a `@:bin(N, Dec|Oct)` Int field — read N bytes
	 * as an ASCII slice, strip trailing spaces, and decode as an integer
	 * in the given base.
	 */
	private static inline function emitBinFixedIntField(
		localName: String, len: Int, encoding: String, fieldName: String, parseSteps: Array<Expr>
	): Void {
		emitIntSliceLocal(localName, len, encoding, 'field "$fieldName"', parseSteps);
	}

	/**
	 * Emit parse steps for a `@:length(N, Dec|Oct)` length prefix. Reads
	 * N bytes, right-trims, decodes as an integer in the given base, and
	 * stores the result in `_lenPrefix_<field>:Int`.
	 */
	private static inline function emitBinLengthPrefix(fieldName: String, width: Int, encoding: String, parseSteps: Array<Expr>): Void {
		emitIntSliceLocal('_lenPrefix_$fieldName', width, encoding, 'length prefix for "$fieldName"', parseSteps);
	}

	private static function isBareLeft(e: Expr): Bool {
		return switch e.expr {
			case EConst(CIdent('left')): true;
			case _: false;
		};
	}

	private static function hasPrattBranch(node: ShapeNode): Bool {
		for (branch in node.children) {
			if (branch.annotations.get(AnnotationKeys.PRATT_PREC) != null || branch.annotations.get(AnnotationKeys.TERNARY_OP) != null)
				return true;
		}
		return false;
	}

	private static function hasPostfixBranch(node: ShapeNode): Bool {
		for (branch in node.children) if (branch.annotations.get(AnnotationKeys.POSTFIX_OP) != null) return true;
		return false;
	}

	/** Returns the operator literal for a branch in the Pratt dispatch chain.
	*  Binary infix branches carry `pratt.op`; ternary branches carry `ternary.op`. */
	private static function getOperatorText(branch: ShapeNode): String {
		return (branch.annotations[AnnotationKeys.PRATT_OP]: Null<String>) ?? branch.annotations[AnnotationKeys.TERNARY_OP];
	}

	/**
	 * Unwrap `Array<T>` (or `Null<Array<T>>`) and return the element
	 * `ComplexType`. Used by `byNameStarParseExpr` to type the
	 * accumulator local against the schema-declared element type
	 * instead of the parse-fn return type, so primitive-rewrite paths
	 * (`Array<Int>` field whose Ref child resolves to `JIntLit`) keep
	 * `Array<Int>` shape and rely on the abstract's `from`/`to`
	 * conversion at each `push`. Returns `null` on any other shape;
	 * caller falls back to `ruleReturnCT(refName)`.
	 */
	private static function extractArrayElementCT(ct: Null<ComplexType>): Null<ComplexType> {
		return ct == null
			? null
			: switch ct {
				case TPath({ pack: [], name: 'Array', params: [TPType(inner)] }): inner;
				case TPath({ pack: [], name: 'Null', params: [TPType(inner)] }): extractArrayElementCT(inner);
				case _: null;
			};
	}

	/**
	 * The schema-declared VALUE type of a `Map<String, V>` field's
	 * ComplexType — the map twin of `extractArrayElementCT`, with the
	 * same purpose: type the accumulator local against the declared type
	 * so a paired (`*T` / `*S`) parse-fn return type cannot diverge from
	 * the field. Only the direct `Map<K, V>` spelling is recognised
	 * (mirroring `ShapeBuilder.mapTypeParams`); `null` falls back to
	 * `ruleReturnCT(refName)` at the caller.
	 */
	private static function extractMapValueCT(ct: Null<ComplexType>): Null<ComplexType> {
		return ct == null
			? null
			: switch ct {
				case TPath({ name: 'Map', params: [TPType(_), TPType(value)] }): value;
				case TPath({ pack: [], name: 'Null', params: [TPType(inner)] }): extractMapValueCT(inner);
				case _: null;
			};
	}

	// -------- binary field helpers --------

	/**
	 * Emit parse steps for a `@:bin(N)` String field — read N bytes as
	 * an ASCII string and strip trailing spaces. The right-padding is a
	 * format convention (e.g. ar), never a meaningful part of the value.
	 */
	private static function emitBinFixedStringField(localName: String, len: Int, parseSteps: Array<Expr>): Void {
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: macro :String,
					expr: macro {
						final _s: String = StringTools.rtrim(ctx.input.substring(ctx.pos, ctx.pos + $v{len}));
						ctx.pos += $v{len};
						_s;
					},
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit parse steps for a `@:bin("fieldName")` Bytes field — read a
	 * variable number of bytes determined by `parseInt(trim(fieldRef))`.
	 */
	private static function emitBinDataField(localName: String, refField: String, parseSteps: Array<Expr>): Void {
		final localRef: Expr = { expr: EConst(CIdent('_f_$refField')), pos: Context.currentPos() };
		final errMsg: String = 'invalid size in field "$refField"';
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: macro :haxe.io.Bytes,
					expr: macro {
						final _len: Int = {
							final _s: String = StringTools.rtrim($localRef);
							final _v: Null<Int> = Std.parseInt(_s);
							if (_v == null) throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{errMsg});
							(_v: Int);
						};
						final _b: haxe.io.Bytes = ctx.input.bytes(ctx.pos, ctx.pos + _len);
						ctx.pos += _len;
						_b;
					},
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit `final <localName>:Int = decode(rtrim(slice of <width> bytes))`.
	 * Shared by fixed-width Int fields and length prefixes — they differ
	 * only in the local name they bind to and the error context string.
	 */
	private static function emitIntSliceLocal(
		localName: String, width: Int, encoding: String, errContext: String, parseSteps: Array<Expr>
	): Void {
		final decodeExpr: Expr = makeIntDecodeExpr(encoding, errContext);
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: macro :Int,
					expr: macro {
						final _s: String = StringTools.rtrim(ctx.input.substring(ctx.pos, ctx.pos + $v{width}));
						ctx.pos += $v{width};
						$decodeExpr;
					},
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit parse steps for a `@:length`-paired Bytes field — read the
	 * count stored in `_lenPrefix_<field>` bytes into the AST value.
	 */
	private static function emitBinLengthBytesField(localName: String, fieldName: String, parseSteps: Array<Expr>): Void {
		final lenRef: Expr = { expr: EConst(CIdent('_lenPrefix_$fieldName')), pos: Context.currentPos() };
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: macro :haxe.io.Bytes,
					expr: macro {
						final _b: haxe.io.Bytes = ctx.input.bytes(ctx.pos, ctx.pos + $lenRef);
						ctx.pos += $lenRef;
						_b;
					},
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Build the Int-decode expression for a right-trimmed `_s:String`
	 * local. `Dec` uses `Std.parseInt`; `Oct` runs an inline digit loop
	 * (Haxe's `Std.parseInt` interprets unprefixed ASCII as decimal, not
	 * octal, so the octal path cannot delegate to it).
	 */
	private static function makeIntDecodeExpr(encoding: String, errContext: String): Expr {
		return switch encoding {
			case 'Dec':
				final errMsg: String = 'invalid decimal in $errContext';
				macro {
					final _v: Null<Int> = Std.parseInt(_s);
					if (_v == null) throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{errMsg});
					(_v: Int);
				};
			case 'Oct':
				final emptyMsg: String = 'empty octal in $errContext';
				final digitMsg: String = 'invalid octal digit in $errContext';
				macro {
					if (_s.length == 0) throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{emptyMsg});
					var _acc: Int = 0;
					var _oi: Int = 0;
					while (_oi < _s.length) {
						final _oc: Int = StringTools.fastCodeAt(_s, _oi); // noqa: magic-number
						if (_oc < '0'.code || _oc > '7'.code)
							throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{digitMsg});
						_acc = (_acc << 3) | (_oc - '0'.code); // noqa: magic-number
						_oi++;
					}
					_acc;
				};
			case _:
				Context.fatalError('Lowering: unsupported bin encoding "$encoding"', Context.currentPos());
				throw 'unreachable';
		};
	}

	// -------- @:raw post-processing --------

	/**
	 * Recursively replace every `skipWs(ctx)` call in an expression tree
	 * with an empty block `{}`. Used by `@:raw` rules to suppress
	 * whitespace skipping without modifying any of the 50+ emission
	 * sites. Referenced sub-rules (via Ref) are separate generated
	 * functions — their own skipWs calls are in their own bodies, not
	 * in this tree, so they are unaffected.
	 */
	private static function stripSkipWs(e: Expr): Expr {
		return isSkipWsStep(e) ? { expr: EBlock([]), pos: e.pos } : ExprTools.map(e, stripSkipWs);
	}

	/**
	 * Whether `e` is the non-consuming `skipWs(ctx)` step a generated rule
	 * body opens with — INCLUDING the empty block `stripSkipWs` leaves
	 * behind in an `@:raw` / binary rule, which is the same step already
	 * reduced to nothing. Shared by the eraser and by `bodyFirstToken`,
	 * which must step over both spellings to reach the rule's first
	 * committed token.
	 */
	private static function isSkipWsStep(e: Expr): Bool {
		return switch e.expr {
			case EBlock([]), ECall({ expr: EConst(CIdent('skipWs')) }, _): true;
			case _: false;
		};
	}

	// -------- helpers --------

	/**
	 * Returns true if the literal's last character is a word character
	 * (`[A-Za-z0-9_]`). Used by `lowerEnumBranch` Cases 1 and 2 to decide
	 * between `expectLit` / `matchLit` and their word-boundary-enforcing
	 * `expectKw` / `matchKw` counterparts for `@:lit`-annotated branches.
	 * An empty literal returns false — the branch would be nonsense, and
	 * the surrounding shape checks reject it before this helper runs.
	 */
	private static function endsWithWordChar(lit: String): Bool {
		if (lit.length == 0) return false;
		final c: Int = lit.charCodeAt(lit.length - 1);
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/**
	 * `final <name>: <type> = <value>;` with a RUNTIME name. The reified
	 * `macro final x = ...` form can only take a literal identifier, and
	 * the dispatch prologue's locals are named from the `GUARD_*_LOCAL`
	 * constants so `branchGuardExpr` can read the same spellings back.
	 */
	private static function finalLocal(name: String, type: ComplexType, value: Expr): Expr {
		return {
			expr: EVars([
				{
					name: name,
					type: type,
					expr: value,
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Classify one Alt branch into the shape its lowering handles — the
	 * SOLE producer of `BranchShape`, read by `lowerEnumBranch` to pick
	 * the emission and by `branchFirstToken` to pick the dispatch guard.
	 * Neither can drift from the other any more: a new constructor breaks
	 * both switches until both have an arm for it.
	 *
	 * THE TEST ORDER BELOW IS THE GRAMMAR CONTRACT, not a detail. It
	 * reproduces the original predicate chain verbatim: `Prefix` before
	 * `KwRef` (a prefix branch matches the single-`Ref` shape too, and the
	 * `KwRef` lowering would emit an unguarded left-recursive call that
	 * consumes nothing), and `StarList` before `KwRef` for the same
	 * single-child reason. Each shape's own rationale lives on its
	 * `BranchShape` constructor.
	 */
	private static function branchShape(branch: ShapeNode): BranchShape {
		final prefixOp: Null<String> = branch.annotations[AnnotationKeys.PREFIX_OP];
		if (prefixOp != null) return Prefix(prefixOp);
		final litList: Null<Array<String>> = branch.annotations[AnnotationKeys.LIT_LIT_LIST];
		final children: Array<ShapeNode> = branch.children;
		final kwLead: Null<String> = branch.annotations[AnnotationKeys.KW_LEAD_TEXT];
		if (kwLead != null && children.length == 0 && litList == null) return KwZeroArg(kwLead);
		if (litList != null && litList.length == 1 && children.length == 0) return SingleLit(litList[0]);
		if (litList != null && litList.length > 1 && children.length == 1) return MultiLit(litList);
		final leadText: Null<String> = branch.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		final trailText: Null<String> = branch.annotations[AnnotationKeys.LIT_TRAIL_TEXT];
		final sepText: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final sepAltText: Null<String> = branch.annotations[AnnotationKeys.LIT_SEP_ALT_TEXT];
		// `prefer-ternary-return` fires on this trailing pair. Collapsing it
		// only moves the finding one guard up the chain — every `if (…)
		// return Shape;` above is the same shape — and the UNIFORM chain is
		// the point: it reproduces the original predicate sequence in order,
		// and that order is the grammar contract (see the doc above).
		return if (leadText != null && trailText != null && children.length == 1 && children[0].kind == Star)
			StarList(leadText, trailText, sepText, sepAltText)
		else if (litList == null && children.length == 1 && children[0].kind == Ref)
			KwRef(kwLead, leadText)
		else
			Unsupported;
	}

	/**
	 * The FIRST token an Alt branch commits to, or `Unknown` when it is
	 * not provably first-token dispatchable (which leaves the branch
	 * unguarded — exactly the pre-guard behaviour).
	 *
	 * Every arm reads the same `branchShape` value `lowerEnumBranch`
	 * dispatches its emission on, so "the guard matches what the branch
	 * actually consumes first" is now structural rather than a comment
	 * asking two predicate chains to stay in step.
	 */
	private static function branchFirstToken(rules: Map<String, ShapeNode>, branch: ShapeNode): BranchFirstToken {
		return switch branchShape(branch) {
			case Prefix(op): litFirst([op]);
			case KwZeroArg(kw): wordOrByteFirst([kw]);
			case SingleLit(lit): wordOrByteFirst([lit]);
			case MultiLit(lits): wordOrByteFirst(lits);
			case StarList(lead, _, _, _):
				litFirst([lead]);
			// Split into guarded arms rather than an if-chain inside one
			// arm: the keyword decides the first token whenever it is
			// present, the lead literal otherwise, and a bare `Ref` commits
			// nothing of its OWN — its first token is the referenced
			// rule's, which `refBranchFirstToken` reads. A new
			// `BranchShape` constructor still breaks this switch — the
			// trailing `KwRef` arm only makes the three KwRef sub-cases
			// exhaustive among themselves.
			case KwRef(kw, _) if (kw != null): wordOrByteFirst([kw]);
			case KwRef(_, lead) if (lead != null): litFirst([lead]);
			case KwRef(_, _): refBranchFirstToken(rules, branch);
			case Unsupported: Unknown;
		};
	}

	/**
		 * First token of a bare-`Ref` Alt branch, taken from the RULE it
		 * references — the branch itself commits nothing before recursing, so
		 * its first token is whatever the sub-rule's is.
		 *
		 * `@:fmt(atomOperand)` retargets the call to the `…Atom` variant of
		 * the sub-rule rather than its entry function; `ruleFirstToken`
		 * models the entry only, so such a branch answers `Unknown`.
		 *
		  * Kept separate from `branchFirstToken` so the dispatch dump can
	 * report, per branch, what the branch-local classifier sees AND what
	 * looking through the `Ref` would add.
	 */
	private static function refBranchFirstToken(rules: Map<String, ShapeNode>, branch: ShapeNode): BranchFirstToken {
		return switch branchShape(branch) {
			case KwRef(kw, lead) if (kw == null && lead == null && !branch.fmtHasFlag('atomOperand')):
				ruleFirstToken(rules, branch.children[0].annotations[AnnotationKeys.BASE_REF], []);
			case _: Unknown;
		};
	}

	/**
	 * The FIRST token the generated entry function of `refName` commits
	 * to, or `Unknown` when it cannot be established from the shape.
	 *
	 * This is the RULE-level twin of `branchFirstToken`. The branch
	 * classifier answers "what does this Alt branch consume first" from
	 * the branch's OWN annotations and stops at a bare `Ref`, because the
	 * branch commits nothing there. The answer for that case lives one
	 * level down, in the referenced rule — and that is where the Haxe
	 * grammar's costliest backtrack sites sit: `HxParenLambda`,
	 * `HxThinParenLambda` and `HxECheckType` on `(`, `HxObjectLit` on
	 * `{`, `HxInterpString` on `'`.
	 *
	 * THE SOUNDNESS INVARIANT is `BranchFirstToken`'s: a non-`Unknown`
	 * answer claims the rule fails WITHOUT CONSUMING at every position
	 * whose first byte / word is outside the returned set.
	 * `checkRuleFirstToken` turns a claim the emission does not honour
	 * into a COMPILE ERROR, so this classifier cannot silently drift from
	 * `lowerStruct` the way two hand-kept predicate chains would.
	 *
	 * `seen` breaks rule cycles (`A`'s first field refs `B`, `B`'s refs
	 * `A`): a revisited rule answers `Unknown`, the safe default.
	 */
	private static function ruleFirstToken(rules: Map<String, ShapeNode>, refName: String, seen: Array<String>): BranchFirstToken {
		if (seen.contains(refName)) return Unknown;
		final node: Null<ShapeNode> = rules[refName];
		// Only a `Seq` rule answers. An `Alt`'s own first token is the
		// UNION over its branches, which means nothing until the Pratt /
		// postfix / `atomsOnly` split `lowerEnum` applies is modelled here
		// too; a `Terminal`'s is a regex FIRST set. Both are deliberately
		// out of scope — see `docs/roadmap.md` O3.
		return node == null || node.kind != Seq ? Unknown : seqFirstToken(rules, node, seen.concat([refName]));
	}

	/**
	 * First token of a `Seq` rule = first token of its FIRST field, which
	 * `lowerStruct` emits before anything else.
	 *
	 * An OPTIONAL first field answers `Unknown`: its lead literal is
	 * emitted inside the optional's own trial, so a position not starting
	 * with it is not a failure of the rule at all — the field is absent
	 * and the SECOND field decides. Guarding on it would skip a branch
	 * that matches.
	 *
	 * A first field carrying no lead of its own but holding a bare `Ref`
	 * hands the question one level down, exactly as a bare-`Ref` Alt
	 * branch does.
	 */
	private static function seqFirstToken(rules: Map<String, ShapeNode>, node: ShapeNode, seen: Array<String>): BranchFirstToken {
		if (node.children.length == 0) return Unknown;
		final first: ShapeNode = node.children[0];
		if (first.kind == Opt || first.annotations[AnnotationKeys.BASE_OPTIONAL] == true) return Unknown;
		final kw: Null<String> = first.annotations[AnnotationKeys.KW_LEAD_TEXT];
		if (kw != null) return wordOrByteFirst([kw]);
		final lead: Null<String> = first.annotations[AnnotationKeys.LIT_LEAD_TEXT];
		return if (lead != null)
			litFirst([lead]);
		else if (first.kind == Ref)
			ruleFirstToken(rules, first.annotations[AnnotationKeys.BASE_REF], seen);
		else
			Unknown;
	}

	/**
	 * The first token a LOWERED rule body actually commits to, read off
	 * the emitted expression instead of off the shape — the oracle
	 * `checkRuleFirstToken` holds `ruleFirstToken` against.
	 *
	 * Leading `skipWs(ctx)` calls are stepped over: `skipWs` consumes
	 * only what the dispatch prologue's own `skipWs` consumed before
	 * peeking, so it cannot move the token being classified. The first
	 * statement that is anything else must be the `expectLit` /
	 * `expectKw` the claim names, or the claim is wrong.
	 */
	private static function bodyFirstToken(body: Expr): BranchFirstToken {
		final steps: Array<Expr> = switch body.expr {
			case EBlock(exprs): exprs;
			case _: [body];
		};
		for (step in steps) if (!isSkipWsStep(step)) return switch step.expr {
			case ECall({ expr: EConst(CIdent('expectLit')) }, [_, { expr: EConst(CString(lit, _)) }]): litFirst([lit]);
			case ECall({ expr: EConst(CIdent('expectKw')) }, [_, { expr: EConst(CString(kw, _)) }]): wordOrByteFirst([kw]);
			case _: Unknown;
		};
		return Unknown;
	}

	/**
	 * Hold `ruleFirstToken`'s claim about `typePath` against what the
	 * rule's lowered body emits, and halt the build when they differ.
	 *
	 * An over-claiming first-token classification is the one defect no
	 * runtime oracle catches: the dispatch guard it feeds skips a branch
	 * whose trial WOULD have matched, and only on grammars or inputs the
	 * corpus never exercises — a byte-identical corpus dump, a green
	 * suite and an A/B over real files all stay quiet. The claim and the
	 * emission are two independent code paths (`seqFirstToken` reads
	 * annotations, `lowerStruct` picks between a dozen field-emission
	 * variants), so this check is what keeps them in step — the same
	 * contract `BranchShape` gives `lowerEnumBranch` and
	 * `branchFirstToken`.
	 */
	private static function checkRuleFirstToken(rules: Map<String, ShapeNode>, typePath: String, rule: GeneratedRule): Void {
		final claimed: BranchFirstToken = ruleFirstToken(rules, typePath, []);
		if (claimed == Unknown) return;
		final emitted: BranchFirstToken = bodyFirstToken(rule.body);
		if (!sameFirstToken(claimed, emitted))
			Context.fatalError(
				'Lowering: the first-token claim for ${simpleName(typePath)} (${describeFirstToken(claimed)}) '
				+ 'disagrees with what ${rule.fnName} emits (${describeFirstToken(emitted)}) — '
				+ 'an Alt dispatch guard built on it would skip branches that match',
				Context.currentPos()
			);
	}

	/**
	 * Equality over first-token facts. The payloads are SETS (distinct
	 * first bytes, alternative keywords), so order must not decide the
	 * answer.
	 */
	private static function sameFirstToken(a: BranchFirstToken, b: BranchFirstToken): Bool {
		return switch [a, b] {
			case [FirstKw(x), FirstKw(y)]: sameSet(x, y);
			case [FirstLit(x), FirstLit(y)]: sameSet(x, y);
			case [Unknown, Unknown]: true;
			case _: false;
		};
	}

	/** Set equality for the first-token payloads — same length, same members. */
	private static function sameSet<T>(x: Array<T>, y: Array<T>): Bool {
		if (x.length != y.length) return false;
		for (v in x) if (!y.contains(v)) return false;
		return true;
	}

	/**
	 * One-line rendering of a first-token fact, shared by the dispatch
	 * dump and the drift error so a report and a diagnostic can never
	 * describe the same fact differently. Byte codes are printed as
	 * character AND number, since the interesting ones (`(`, `{`, `'`)
	 * are punctuation a bare character would make ambiguous in a log.
	 */
	private static function describeFirstToken(first: BranchFirstToken): String {
		return switch first {
			case FirstKw(words): 'kw ${words.join('|')}';
			case FirstLit(codes): 'lit ${[for (code in codes) '${String.fromCharCode(code)}($code)'].join('|')}';
			case Unknown: 'unknown';
		};
	}


	/**
	 * `-D anyparse_dispatch_dump` diagnostic — the per-grammar inventory
	 * of what first-token dispatch reaches, printed as `//` comments
	 * alongside the existing `anyparse_trivia_dump` / `anyparse_dump`
	 * channels.
	 *
	 * Three record kinds: `dispatch.first` (one per rule — the rule-level
	 * fact a caller could guard a `Ref` on), `dispatch.branch` (one per
	 * Alt branch — its shape, the fact that guards it, and the fact taken
	 * through a bare `Ref` when that is where it came from), and
	 * `dispatch.rule` (per Alt — guardable count and whether the prologue
	 * is emitted), closed by one `dispatch.total` summary line.
	 */
	private static function dumpDispatch(rules: Map<String, ShapeNode>): Void {
		var ruleCount: Int = 0;
		var altCount: Int = 0;
		var dispatchCount: Int = 0;
		var branchCount: Int = 0;
		var guardedCount: Int = 0;
		var refViaCount: Int = 0;
		for (typePath => node in rules) {
			ruleCount++;
			Sys.println('// dispatch.first: $typePath = ${describeFirstToken(ruleFirstToken(rules, typePath, []))}');
			if (node.kind != Alt) continue;
			altCount++;
			var guardable: Int = 0;
			for (branch in node.children) {
				branchCount++;
				final ctor: Null<String> = branch.annotations[AnnotationKeys.BASE_CTOR];
				final own: BranchFirstToken = branchFirstToken(rules, branch);
				final viaRef: BranchFirstToken = refBranchFirstToken(rules, branch);
				if (own != Unknown) {
					guardedCount++;
					guardable++;
				}
				if (viaRef != Unknown) refViaCount++;
				Sys.println(
					'// dispatch.branch: $typePath.$ctor shape=${branchShape(branch)} '
					+ 'first=${describeFirstToken(own)} viaRef=${describeFirstToken(viaRef)}'
				);
			}
			final dispatches: Bool = guardable >= DISPATCH_MIN_GUARDS;
			if (dispatches) dispatchCount++;
			Sys.println('// dispatch.rule: $typePath branches=${node.children.length} guardable=$guardable dispatch=$dispatches');
		}
		Sys.println(
			'// dispatch.total: rules=$ruleCount alts=$altCount dispatching=$dispatchCount branches=$branchCount '
			+ 'guarded=$guardedCount viaRef=$refViaCount'
		);
	}

	/**
	 * `FirstKw` when EVERY literal is word-shaped — only then does a
	 * `peekWord` compare reproduce the branch's `expectKw` / `matchKw`
	 * word-boundary test exactly. `FirstLit` otherwise, which stays sound
	 * either way: the first-byte compare is the first iteration of the
	 * literal compare that `expectKw` and `expectLit` both open with.
	 *
	 * THE LOAD-BEARING IMPLICATION: `isWordShaped(lit)` implies
	 * `endsWithWordChar(lit)` — a word-shaped literal's last character is
	 * either its ident-start head or one of the `[A-Za-z0-9_]` characters
	 * the tail loop checked, so it is a word character either way. And
	 * `endsWithWordChar` is exactly the predicate the Case 1 / Case 2
	 * lowerings use to choose `expectKw` / `matchKw` over the
	 * boundary-less `expectLit` / `matchLit`. Therefore a `FirstKw` guard
	 * can only ever sit in front of a WORD-BOUNDARY-CHECKING primitive —
	 * which is what makes `peekWord` equality an exact acceptance test
	 * rather than an over-strict one. Were a `peekWord` guard ever to
	 * front a bare `expectLit`, it would wrongly skip the branch on input
	 * like `dog` for `expectLit('do')`, since `peekWord` returns the
	 * MAXIMAL word `dog` and would not equal `do`.
	 *
	 * `isWordShaped` is strictly stronger than `endsWithWordChar` (`a-b`,
	 * `1abc` and `else if` all end in a word character without being
	 * word-shaped); those correctly degrade to the byte guard, still sound
	 * because `expectKw` opens with the very same literal compare.
	 */
	private static function wordOrByteFirst(lits: Array<String>): BranchFirstToken {
		for (lit in lits) if (!isWordShaped(lit)) return litFirst(lits);
		return FirstKw(lits);
	}

	/**
	 * `FirstLit` over the DISTINCT first bytes of `lits`. A literal with
	 * no first byte cannot be guarded, so an empty literal — or an empty
	 * SET, which would leave the guard with no terms at all — degrades the
	 * whole classification to `Unknown`. The surrounding shape checks
	 * reject such a grammar anyway; this only keeps the classifier total,
	 * so no downstream builder has to defend against a term-less guard.
	 */
	private static function litFirst(lits: Array<String>): BranchFirstToken {
		if (lits.length == 0) return Unknown;
		final codes: Array<Int> = [];
		for (lit in lits) {
			if (lit.length == 0) return Unknown;
			final code: Int = lit.charCodeAt(0);
			if (!codes.contains(code)) codes.push(code);
		}
		return FirstLit(codes);
	}

	/**
	 * Full-match test for `#?[A-Za-z_][A-Za-z0-9_]*` — the exact shape
	 * `peekWord` returns. A `#`-led conditional-compilation keyword
	 * (`#if`, `#elseif`, `#else`, `#end`) IS word-shaped: `peekWord` folds
	 * the `#` into the word whenever an ident-start follows it, so the
	 * word-guard compare holds for those too.
	 */
	private static function isWordShaped(lit: String): Bool {
		final start: Int = lit.length > 0 && lit.charCodeAt(0) == '#'.code ? 1 : 0;
		if (lit.length <= start) return false;
		final head: Int = lit.charCodeAt(start);
		if (!((head >= 'a'.code && head <= 'z'.code) || (head >= 'A'.code && head <= 'Z'.code) || head == '_'.code)) return false;
		for (i in start + 1...lit.length) {
			final c: Int = lit.charCodeAt(i);
			if (
				!((c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code)
			)
				return false;
		}
		return true;
	}

	/**
	 * Guard condition for one classified branch, reading the per-dispatch
	 * prologue locals `lowerEnum` emits once (`GUARD_WORD_LOCAL` /
	 * `GUARD_BYTE_LOCAL`). `null` for `Unknown` — that branch is emitted
	 * unwrapped.
	 */
	private static function branchGuardExpr(first: BranchFirstToken): Null<Expr> {
		return switch first {
			case FirstKw(words): orChain([for (word in words) macro $i{GUARD_WORD_LOCAL} == $v{word}]);
			case FirstLit(codes): orChain([for (code in codes) macro $i{GUARD_BYTE_LOCAL} == $v{code}]);
			case Unknown: null;
		};
	}

	/**
	 * Fold one branch's alternative first-token tests into a single `||`
	 * chain. `litFirst` / `wordOrByteFirst` never produce an empty term
	 * list — an empty set already degrades to `Unknown`, which
	 * `branchGuardExpr` answers with `null` instead of calling here — so
	 * the empty case is a broken classifier, not a possible grammar, and
	 * halts the build.
	 */
	private static function orChain(terms: Array<Expr>): Expr {
		if (terms.length == 0) {
			Context.fatalError('Lowering: orChain on an empty term list (a BranchFirstToken with no terms)', Context.currentPos());
			throw 'unreachable';
		}
		var chain: Expr = terms[0];
		for (i in 1...terms.length) {
			final term: Expr = terms[i];
			chain = macro $chain || $term;
		}
		return chain;
	}

	private static function simpleName(typePath: String): String {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	private static function packOf(typePath: String): Array<String> {
		final idx: Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}

	/**
	 * Compile-time validation of a struct field's metadata-combination
	 * legality (`@:optional` / `@:kw` / `@:lead` / `@:trail` / `@:absentOn`).
	 * Each illegal combination halts the build via `Context.fatalError`.
	 * Pure — no emit, no `ctx`; lifted out of `lowerStruct`'s per-field loop.
	 */
	private static function validateStructField(
		child: ShapeNode, fieldName: Null<String>, isOptional: Bool, isStar: Bool, kwLead: Null<String>, leadText: Null<String>,
		trailText: Null<String>, absentOnLits: Null<Array<String>>
	): Void {
		if (isOptional && child.kind != Ref && child.kind != Star) {
			Context.fatalError(
				'Lowering: @:optional is only supported on Ref- or Star-shaped struct fields (field "$fieldName")', Context.currentPos()
			);
		}
		if (isOptional && !isStar && trailText != null && kwLead != null) {
			// `@:trail` on an optional kw-led Ref has no consumer yet
			// (the kw-led trivia capture path threads `_afterKw_*` /
			// `_kwLeading_*` slots whose layout assumes no per-field
			// trail). Defer until a grammar needs it; the lead-led
			// shape (`@:optional @:lead('(') @:trail(')')`) is
			// supported below — first consumer `@:coreType`
			// bare abstract via `HxAbstractDecl.underlyingType`.
			Context.fatalError('Lowering: @:optional @:kw combined with @:trail is deferred (field "$fieldName")', Context.currentPos());
		}
		if (absentOnLits != null) {
			// `@:absentOn` is a peek-ahead absence dispatch — it does NOT
			// consume any literals (the listed terminators belong to the
			// enclosing context). Combined with `@:lead`/`@:kw` it would
			// be ambiguous (which decides absence?), and combined with
			// `@:trail` it inherits the same "trail inside peek" gap as
			// regular `@:optional`. Both combinations are rejected. The
			// meta also requires the field to be an optional Ref —
			// Stars have their own commit semantics through `@:lead` /
			// `@:trail`; `absentOn` adds nothing there.
			if (!isOptional || child.kind != Ref) {
				Context.fatalError('Lowering: @:absentOn requires @:optional Ref (field "$fieldName")', Context.currentPos());
			}
			if (kwLead != null || leadText != null) {
				Context.fatalError('Lowering: @:absentOn cannot combine with @:lead or @:kw (field "$fieldName")', Context.currentPos());
			}
			if (trailText != null) {
				Context.fatalError('Lowering: @:absentOn cannot combine with @:trail (field "$fieldName")', Context.currentPos());
			}
			if (absentOnLits.length == 0) {
				Context.fatalError(
					'Lowering: @:absentOn requires at least one terminator literal (field "$fieldName")', Context.currentPos()
				);
			}
		}
		if (isStar && isOptional && kwLead == null && (leadText == null || trailText == null)) {
			Context.fatalError(
				'Lowering: @:optional Star field "$fieldName'
				+ '" requires either @:kw (tryparse mode) or both @:lead and @:trail (angle-bracket mode)',
				Context.currentPos()
			);
		}
	}

	/**
	 * Pre-declare the six `@:optional @:kw(...)` trivia sidecar locals
	 * (`_afterKw_*` / `_kwLeading_*` / `_beforeKwNl_*` / `_bodyOnSameLine_*` /
	 * `_beforeKwLeading_*` / `_beforeKwTrailing_*`) that the optional-Ref /
	 * optional-kw-Star commit path assigns into. Pushes one `EVars` per local.
	 * Pure — lifted from `lowerStruct`'s per-field loop.
	 */
	private static function emitKwTriviaSlotDecls(
		afterKwLocal: String, kwLeadingLocal: String, beforeKwNlLocal: String, bodyOnSameLineLocal: String, beforeKwLeadingLocal: String,
		beforeKwTrailingLocal: String, parseSteps: Array<Expr>
	): Void {
		inline function pushVar(name: String, type: ComplexType, init: Expr): Void {
			parseSteps.push({
				expr: EVars([
					{
						name: name,
						type: type,
						expr: init,
						isFinal: false
					}
				]),
				pos: Context.currentPos(),
			});
		}
		pushVar(afterKwLocal, macro :Null<String>, macro null);
		pushVar(kwLeadingLocal, macro :Array<String>, macro []);
		pushVar(beforeKwNlLocal, macro :Bool, macro false);
		pushVar(bodyOnSameLineLocal, macro :Bool, macro false);
		pushVar(beforeKwLeadingLocal, macro :Array<String>, macro []);
		pushVar(beforeKwTrailingLocal, macro :Null<String>, macro null);
	}

	/**
	 * Emit the post-switch per-field trailing-literal steps for a non-Star,
	 * non-optional Ref field: the mandatory `@:trail` close (+ trivia
	 * `<field>AfterTrail` same-line-comment capture) and/or the `@:trailOpt`
	 * peek-consume-rewind close (+ `_trailPresent_<field>` capture). Both are
	 * gated `!isStar && !isOptional`; `trailText` drives the required path,
	 * `trailOptText` the optional path. Pure — lifted from `lowerStruct`.
	 */
	private static function emitFieldTrail(
		parseSteps: Array<Expr>, isStar: Bool, isOptional: Bool, trailText: Null<String>, hasAfterTrailSlot: Bool, afterTrailLocal: String,
		trailOptText: Null<String>, captureTrailPresentExpr: Expr
	): Void {
		// @:fmt(captureTrailComment) Star: the trail literal (e.g. `:`) is
		// already consumed by `emitStarFieldSteps`, so capture the same-line
		// trailing comment here into the same `<field>AfterTrail` slot the next
		// sibling's writer reads. `collectTrailingFull` keeps the delimiters so
		// block and line styles both round-trip verbatim.
		if (isStar && !isOptional && trailText != null && hasAfterTrailSlot) {
			parseSteps.push({
				expr: EVars([
					{
						name: afterTrailLocal,
						type: macro :Null<String>,
						expr: macro collectTrailingFull(ctx),
						isFinal: true,
					}
				]),
				pos: Context.currentPos(),
			});
		}
		if (!isStar && !isOptional && trailText != null) {
			parseSteps.push(macro skipWs(ctx));
			parseSteps.push(macro expectLit(ctx, $v{trailText}));
			// ω-trivia-after-trail: in trivia-bearing rules, capture a
			// same-line `// comment` after the trail literal into a
			// sidecar local — pushed to the synth pair as
			// `<field>AfterTrail:Null<String>` for the next sibling's
			// `bodyPolicyWrap` to thread before its body emission.
			// `collectTrailing` returns null when no same-line comment
			// is present and does not consume any whitespace beyond
			// the optional space + `//<body>` match.
			if (hasAfterTrailSlot) {
				parseSteps.push({
					expr: EVars([
						{
							name: afterTrailLocal,
							type: macro :Null<String>,
							expr: macro collectTrailingFull(ctx),
							isFinal: true,
						}
					]),
					pos: Context.currentPos(),
				});
			}
		}
		if (!isStar && !isOptional && trailOptText != null) {
			// ω-trailopt-rewind-on-miss-struct (BlockBody Star Session 5):
			// trail-absence must REWIND pos to pre-trivia so trivia stays
			// observable to the next field/Star. Bare `skipWs(ctx)` (the
			// pre-Session-5 form) silently advances past whitespace and
			// comments even when the optional trail literal is absent —
			// breaking BOTH trivia-mode round-trip (statement-context
			// hosts where the field-level `@:trailOpt(';')` sits between
			// two statement siblings — HxIfStmt.thenBody / .elseBody /
			// HxWhileStmt.body / HxForStmt.body / HxDoWhileStmt.body
			// added in Session 5 Step 1) AND plain-mode block-ended Star
			// detection (the close-peek Star at L2796-2833 reads
			// `ctx.input.charCodeAt(_prevEndPos - 1) == '}'.code` to
			// decide if sep is exempt; if `skipWs` advanced `_prevEndPos`
			// past the closing `}` to the next token, the check reads a
			// space instead of `}` and the exemption misses). The
			// optional-kw pattern at L2296 uses the same `ctx.pos = _wsPos`
			// rewind on miss — this mirrors it for optional-trail. On
			// `;` hit: advance past it normally. On miss: rewind pos so
			// the preceding trivia is re-observable. Applied in BOTH
			// modes — plain mode also benefits (downstream block-ended
			// Star checks need pre-trivia pos). Existing expression-
			// context consumers (HxIfExpr.thenBranch, HxConditionalType.type,
			// HxConditionalTypeElse.type, HxTryCatchExpr.body,
			// HxFnBody.ExprBody) see no observable change — their
			// downstream parsers re-scan the same trivia via their own
			// skipWs / collectTrivia.
			//
			// ω-struct-trailopt-source-track (Session 14 Phase 3): when
			// the field's paired-T type carries a synth
			// `<field>TrailPresent:Null<Bool>` slot, capture `matchLit`'s
			// hit into `_trailPresent_<field>` for the writer (Phase 4
			// will read it). Pre-declared `false` above so the miss
			// branch leaves the local untouched. `captureTrailPresentExpr`
			// is the shared splice — disjoint from the optional-Ref arm
			// which feeds the same Expr into a different subCall body.
			parseSteps.push(macro {
				final _trailOptWsPos: Int = ctx.pos;
				skipWs(ctx);
				if (matchLit(ctx, $v{trailOptText}))
					$captureTrailPresentExpr;
				else
					ctx.pos = _trailOptWsPos;
			});
		}
	}

	/**
	 * Emit the pre-field whitespace / trivia handling for one struct field
	 * (skipped for the optional-Ref / optional-kw-Star / EOF-Star / optional-
	 * Star-with-lead paths that own their own ws). Three modes: capture
	 * `collectTrivia` into BeforeLeading+BeforeNewline slots, or just
	 * BeforeNewline, or a plain `skipWs`. Then, for an opted-in condWrap cond
	 * field, probe the `(`→cond newline gap into the CondOpenNewline slot.
	 * Pure — lifted from `lowerStruct`'s per-field loop.
	 */
	private static function emitPreFieldWs(
		parseSteps: Array<Expr>, triviaEofStar: Bool, isOptionalRef: Bool, isOptionalKwStar: Bool, optStarWithLead: Bool,
		hasBeforeLeadingSlot: Bool, hasBeforeNewlineSlot: Bool, beforeNlLocal: String, beforeLeadingLocal: String,
		hasCondOpenNewlineSlot: Bool, condOpenNewlineLocal: String
	): Void {
		if (!triviaEofStar && !isOptionalRef && !isOptionalKwStar && !optStarWithLead) {
			if (hasBeforeLeadingSlot) {
				// ω-598-member-leading-comment: capture the full
				// `collectTrivia` result once, then split into the
				// `newlineBefore` bool (BeforeNewline slot) and the
				// verbatim `leadingComments` array (BeforeLeading slot).
				// The array holds a comment dropped in the gap between the
				// last modifier and the member keyword; emitted by the
				// writer's bare-Ref non-first separator. Empty in the
				// common case (no inter-modifier comment) → byte-inert.
				final arrayStrCT: ComplexType = TPath({
					pack: [],
					name: 'Array',
					params: [TPType(TPath({ pack: [], name: 'String', params: [] }))]
				});
				parseSteps.push(macro final _beforeTrivia = collectTrivia(ctx));
				parseSteps.push({
					expr: EVars([
						{
							name: beforeNlLocal,
							type: macro :Bool,
							expr: macro _beforeTrivia.newlineBefore,
							isFinal: true,
						}
					]),
					pos: Context.currentPos(),
				});
				parseSteps.push({
					expr: EVars([
						{
							name: beforeLeadingLocal,
							type: arrayStrCT,
							expr: macro _beforeTrivia.leadingComments,
							isFinal: true,
						}
					]),
					pos: Context.currentPos(),
				});
			} else if (hasBeforeNewlineSlot) {
				// Route through `collectTrivia` — drains any
				// `pendingTrivia` stash from a preceding empty
				// bare-tryparse Star and captures `newlineBefore` into
				// the local that the struct literal writes onto the
				// synth slot. `skipWs` would silently discard both.
				parseSteps.push({
					expr: EVars([
						{
							name: beforeNlLocal,
							type: macro :Bool,
							expr: macro collectTrivia(ctx).newlineBefore,
							isFinal: true,
						}
					]),
					pos: Context.currentPos(),
				});
			} else
				parseSteps.push(macro skipWs(ctx));
		}
		// ω-condition-wrap-keep: the pre-field `skipWs` above advanced
		// `ctx.pos` to the cond's first token, so `hasNewlineIn` over
		// `[_condLeadEnd, ctx.pos)` answers "did the source break right
		// after `(`?". Captured into the local that the struct literal
		// writes onto the `<field>CondOpenNewline:Bool` synth slot. Runs
		// only for the opted-in condWrap cond field; `_condLeadEnd` was
		// declared right after the lead `expectLit` above.
		if (hasCondOpenNewlineSlot) parseSteps.push({
			expr: EVars([
				{
					name: condOpenNewlineLocal,
					type: macro :Bool,
					expr: macro hasNewlineIn(ctx.input, _condLeadEnd, ctx.pos),
					isFinal: true,
				}
			]),
			pos: Context.currentPos(),
		});
	}

	/**
	 * Emit the mandatory per-field lead-in for a non-Star, non-optional field:
	 * the `@:kw` keyword (`skipWs` + `expectKw`) and/or the `@:lead` literal
	 * (`skipWs` + `expectLit`), in that order (D50). For an opted-in condWrap
	 * cond field, also record `_condLeadEnd` right after the lead so the
	 * `(`→cond newline probe in emitPreFieldWs spans the correct gap. Pure —
	 * lifted from `lowerStruct`.
	 */
	private static function emitFieldLeadIn(
		parseSteps: Array<Expr>, isStar: Bool, isOptional: Bool, kwLead: Null<String>, leadText: Null<String>, hasCondOpenNewlineSlot: Bool
	): Void {
		if (isStar || isOptional) return;
		if (kwLead != null) {
			parseSteps.push(macro skipWs(ctx));
			parseSteps.push(macro expectKw(ctx, $v{kwLead}));
		}
		if (leadText == null) return;
		parseSteps.push(macro skipWs(ctx));
		parseSteps.push(macro expectLit(ctx, $v{leadText}));
		// ω-condition-wrap-keep: record the byte position right
		// after the open paren (BEFORE the pre-field `skipWs` below)
		// so the `hasNewlineIn` probe spans exactly the `(`→cond gap.
		if (hasCondOpenNewlineSlot) parseSteps.push(macro final _condLeadEnd: Int = ctx.pos);
	}

	/**
	 * ω-cond-splice: no-match position-restore guard for the plain
	 * Pratt/postfix loops. Restores `ctx.pos` to the pre-skipWs save iff
	 * the next token is one of the enum's WORD-LIKE op literals (`#if`)
	 * — those dispatch on a same-line gate that needs the operand↔op gap
	 * intact when an enclosing loop re-probes. Empty/absent word-op set
	 * emits `{}` — grammars without word ops keep the historical
	 * consumed-whitespace exit byte-for-byte (string-interpolation `@:raw`
	 * siblings depend on it).
	 */
	private static function buildWordOpRestoreExpr(wordOps: Null<Array<String>>): Expr {
		if (wordOps == null || wordOps.length == 0) return macro {};
		var cond: Null<Expr> = null;
		for (op in wordOps) {
			final peek: Expr = macro peekKw(ctx, $v{op});
			cond = cond == null ? peek : macro $cond || $peek;
		}
		return macro if ($cond) ctx.pos = _preWsPos;
	}

}
#end
