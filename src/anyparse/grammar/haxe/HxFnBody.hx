package anyparse.grammar.haxe;

/**
 * Function-body shape on `HxFnDecl.body`.
 *
 * Five forms are recognised. Four are described below in declaration
 * order; `CondBody` - fourth in DISPATCH order, between `NoBody` and
 * `ExprBody` - carries its own branch doc:
 *  - `UntypedBlockBody(body:HxUntypedFnBody)` — `untyped { stmts }` body
 *    with the `untyped` keyword as a pre-block modifier
 *    (`function f():Type untyped { body }`). Real Haxe sugar that
 *    wraps the entire body in an untyped block. The kw + `HxFnBlock`
 *    payload live inside the `HxUntypedFnBody` Seq wrapper so this
 *    branch is a single-Ref Case 3 with no own `@:kw`. Branch-level
 *    `@:fmt(bodyPolicy('untypedBody'))` (slice ω-untyped-body-policy)
 *    drives the parent→`untyped` separator via `bodyPolicyWrap`, which
 *    prepends the runtime-switched separator BEFORE the inner kw —
 *    `Same` (default) cuddles `function f():T untyped { … }`, `Next`
 *    pushes `untyped` to its own line. The parent `HxFnDecl.body`'s
 *    leftCurly Case 5 routes this ctor through `spacePrefixCtors` +
 *    `ctorHasBodyPolicy` (=> `_de()` separator), so the inner wrap is
 *    the sole source of the kw-leading transition. The `untyped`→`{`
 *    gap is governed independently by `HxUntypedFnBody.block`'s
 *    `@:fmt(leftCurly)` (slice ω-untyped-leftCurly): under
 *    `leftCurly=Next` the brace also drops onto its own line. Must
 *    appear before `BlockBody` so the inner `untyped` peek (via
 *    tryBranch rollback) fires before the bare-`{` dispatch.
 *  - `BlockBody(block:HxFnBlock)` — `{ stmts }` braced body. The
 *    `{`-leading peek that dispatches this branch lives on the
 *    `HxFnBlock.stmts` field; the brace policy (`@:fmt(leftCurly)`),
 *    the `@:trivia` capture, and the orphan-trivia trailing slots all
 *    sit inside the Seq-typedef wrapper (see `HxFnBlock`).
 *  - `NoBody` — `;` only. The shape of an interface method or
 *    `@:overload` stub: `function foo():Void;`. Dispatched by the
 *    `;` literal.
 *  - `ExprBody(expr:HxExpr)` — single-expression body, optionally
 *    terminated by `;`: `function foo() trace("hi");` OR
 *    `function foo() trace("hi")` with the `;` elided (e.g. as the
 *    last class member before `}`, or a top-level decl before EOF).
 *    Catch-all branch tried LAST, after the two literal-led
 *    siblings and `CondBody`;
 *    `tryBranch`'s rollback ensures `BlockBody` (`{`-led) and `NoBody`
 *    (`;`-led) win on shared input. `@:trailOpt(';')` consumes the
 *    terminator when present and tracks its source presence — Haxe
 *    treats the `;` as optional here and the writer re-emits it
 *    byte-faithfully (single-Ref Alt `trailPresent` arg, mirror of
 *    `HxStatement.ExprStmt`). The signature→body separator is
 *    runtime-switchable via the PARENT `HxFnDecl.body`'s
 *    `@:fmt(bodyPolicyForCtor('ExprBody', 'functionBody'))` (slice
 *    ω-fnbody-keep) — `Next` (default) emits a hardline + Nest, `Same`
 *    emits a single space, `Keep` reproduces the source newline-or-not
 *    via the parent struct's `bodyBeforeNewline:Bool` synth slot. The
 *    wrap lives at the parent (not on this branch) for the same reason
 *    `UntypedBlockBody`'s does: the signature→body gap is consumed by
 *    the parent struct's pre-field `skipWs` BEFORE this branch's
 *    sub-rule probes, so a branch-local slot would always read "no
 *    newline". Mirrors the `UntypedBlockBody`/`untypedBody` pairing
 *    already wired through `bodyPolicyForCtor`.
 *
 * Branch order matters for dispatch: UntypedBlockBody → BlockBody →
 * NoBody → CondBody → ExprBody. UntypedBlockBody dispatches via the inner
 * `HxUntypedFnBody`'s first-field `@:kw('untyped')` (peeked through
 * `tryBranch` rollback when input doesn't start with `untyped`); the
 * other three are tight first-char/keyword dispatches; ExprBody runs
 * the full HxExpr parser LAST, only when the preceding four fail;
 * see the CondBody branch for why it must not run first.
 * `HxFnBlock` is trivia-bearing, which transitively makes this enum
 * bearing — paired type `HxFnBodyT` synthesised by `TriviaTypeSynth`.
 */
@:peg
enum HxFnBody {

	@:fmt(multilineCtor)
	UntypedBlockBody(body: HxUntypedFnBody);

	@:fmt(multilineCtor)
	BlockBody(block: HxFnBlock);

	@:lit(';')
	NoBody;

	/**
	 * `#if <cond> <body> [#elseif ...] [#else <body>] #end` occupying the
	 * ENTIRE function-body slot (slice C1). See `HxConditionalFnBody`
	 * for the motivating std sources and the Ref-vs-Star rationale.
	 *
	 * Dispatched BEFORE `ExprBody`, and that ordering is load-bearing.
	 * `ExprBody` runs the whole `HxExpr` parser, whose last `#if` ctor is
	 * `HxExpr.CondSpliceExpr` - a raw `{raw, tail}` swallow that consumes
	 * the region through its `#end` and then parses whatever FOLLOWS as
	 * the `tail`. At a member boundary that tail is the NEXT MEMBER, so
	 * with `ExprBody` first a whole-body region silently absorbed the
	 * member after `#end`, or just its leading `static` / `public` word
	 * read as an `IdentExpr`. Live on `std/{flash,js}/_std/haxe/Json.hx`,
	 * `std/haxe/Int64.hx` and `std/cs/_std/haxe/Rest.hx`, all of which
	 * compile under every define set - the shape only projected correctly
	 * while the region happened to be the LAST member, where the tail had
	 * nothing left to eat. Trying `CondBody` first ends the body at its
	 * own `#end` whenever the region is a balanced per-branch body. The
	 * shapes whose SUB-PARSE fails - a dangling `else`, half a ternary -
	 * still fail-rewind into `ExprBody` exactly as before.
	 *
	 * The measured cost, and why this is a TRADE and not a pure win: a
	 * balanced region followed by an expression TAIL is representable
	 * here, so `CondBody` commits and the tail is stranded at member
	 * position with nothing to backtrack into. `#if a 1 #else 2 #end + 3`,
	 * `#if a x #else y #end.g()` and the `?:` twin now FAIL TO PARSE in a
	 * body slot where `ExprBody` -> `HxExpr.ConditionalExpr` used to take
	 * them, and they are legal Haxe - `function f():Void #if flash a
	 * #else b #end.push(1);` compiles and runs on 4.3.7. Taken knowingly:
	 * a sweep of ~20,300 files (haxe std, haxelib, Pony, TM-Haxe4, the
	 * haxe-formatter corpus, anyparse itself) found ZERO occurrences of
	 * the tail shape against four in the std alone for the swallow, and a
	 * parse refusal is loud where the swallow was silent corruption.
	 * `testBalancedRegionWithExpressionTailIsRefused` pins the refusal.
	 *
	 * The principled recovery, deferred to its own slice: a restricted
	 * arm type for `HxConditionalFnBody.body` that rejects a bare-VALUE
	 * branch - an `ExprBody` carrying no `;` of its own. A whole-body
	 * region always has `;`-terminated or braced arms; an operand region
	 * never does, so the discriminator is exact. It costs a new `@:peg`
	 * enum plus its writer paths, which is why it is not this change.
	 *
	 * Same reordering, second consequence: a region whose branches are
	 * single EXPRESSIONS now projects here too, where it used to reach
	 * `HxExpr.ConditionalExpr` through `ExprBody`
	 * (`function f() #if a { 1; } #else { 2; } #end`). That projection is
	 * the more accurate of the two - each branch IS a whole function body
	 * - and it costs one layout difference: a trailing `;` written
	 * OUTSIDE the region (`#if a 1 #else 2 #end;`) is no longer absorbed
	 * by `ExprBody`'s `@:trailOpt(';')` and lands as a sibling
	 * `EmptySemiMember` on its own line. Adding `@:trailOpt(';')` here
	 * does NOT recover it - the two trailers together make every
	 * `CondBody` source unparseable (measured), so the stray `;` stays a
	 * known cosmetic drift.
	 *
	 * A second layout cost predates this change, but the reorder widens
	 * who meets it: `HxFnDecl.body` wires `bodyPolicyForCtor` for
	 * `UntypedBlockBody` and `ExprBody` and not for this ctor, so the
	 * branch falls into `spacePrefixCtors` and the region is always
	 * emitted one space after the signature - a source that put `#if` on
	 * its own line (all four std files above) gets pulled up onto the
	 * signature line. Wiring `bodyPolicyForCtor('CondBody',
	 * 'functionBody')` is NOT a drop-in fix: that policy defaults to
	 * `Next`, which would break the same-line sources (`Int32.hx`) that
	 * round-trip byte-exactly today. It needs `Keep`-style source
	 * fidelity, so it is a slice of its own.
	 *
	 * The `#if` keyword lives on `HxConditionalFnBody.cond` rather than
	 * on this branch - the `HxUntypedFnBody` precedent one ctor up.
	 * Keeping the branch a bare single-Ref (no `@:kw` / `@:lead`) is what
	 * puts it in `WriterLowering.spacePrefixCtors`, so the parent
	 * `HxFnDecl.body`'s `@:fmt(leftCurly)` emits the `<signature> #if`
	 * separating space; a branch-level `@:kw` is excluded from that list
	 * and glued the region straight onto the return type (`:Dynamic#if`).
	 * Dispatch is unaffected: the inner `@:kw('#if')` still enforces the
	 * non-word-char boundary (so `#iff` is rejected) and fails fast
	 * through `tryBranch` on any other input. `@:trail('#end')` stays on
	 * the branch so the closing directive is consumed after the whole
	 * region - the byte twin of `HxClassMember.Conditional` /
	 * `HxStatement.Conditional`.
	 */
	@:trail('#end')
	CondBody(inner: HxConditionalFnBody);

	@:trailOpt(';')
	ExprBody(expr: HxExpr);
}
