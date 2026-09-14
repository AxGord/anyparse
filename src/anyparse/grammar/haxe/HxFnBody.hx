package anyparse.grammar.haxe;

/**
 * Function-body shape on `HxFnDecl.body`. Five forms, in DISPATCH order:
 *
 * `UntypedBlockBody(body:HxUntypedFnBody)` — `untyped { stmts }` with the `untyped` keyword as a pre-block
 * modifier (`function f():Type untyped { body }`). The kw + `HxFnBlock` payload live inside the
 * `HxUntypedFnBody` Seq wrapper so this branch is a single-Ref Case 3 with no own `@:kw`. The
 * parent→`untyped` separator is wired at the PARENT: `HxFnDecl.body` carries
 * `@:fmt(bodyPolicyForCtor('UntypedBlockBody', 'untypedBody'))`, which replaces this ctor's `sep + write`
 * pair in the leftCurly Case 5 chain with a `bodyPolicyWrap` (`Same`, the default, cuddles `function f():
 * T untyped { … }`; `Next` pushes `untyped` onto its own line). The branch itself carries no `bodyPolicy`;
 * the `untyped`→`{` gap is `HxUntypedFnBody.block`'s `@:fmt(leftCurly)`. Must appear before `BlockBody` so
 * the inner `untyped` peek (via `tryBranch` rollback) fires before the bare-`{` dispatch.
 *
 * `BlockBody(block:HxFnBlock)` — `{ stmts }`. The `{`-leading peek, the brace policy, the `@:trivia`
 * capture and the orphan-trivia trailing slots all sit inside the Seq-typedef wrapper (see `HxFnBlock`).
 * `NoBody` — `;` only, the shape of an interface method or `@:overload` stub, dispatched by the `;`
 * literal. `CondBody` — a `#if` region occupying the whole body slot; its branch doc explains why it
 * precedes `ExprBody`.
 *
 * `ExprBody(expr:HxExpr)` — single-expression body, optionally terminated by `;` (`function foo()
 * trace("hi");` or, as the last member before `}`, without it). The catch-all tried LAST; `tryBranch`'s
 * rollback ensures the literal-led siblings win on shared input. `@:trailOpt(';')` consumes the terminator
 * when present and tracks its source presence — the writer re-emits it byte-faithfully (single-Ref Alt
 * `trailPresent` arg, the `HxStatement.ExprStmt` mirror). The signature→body separator is
 * runtime-switchable via the PARENT `HxFnDecl.body`'s `@:fmt(bodyPolicyForCtor('ExprBody',
 * 'functionBody'))`: `Next` (default) emits a hardline + Nest, `Same` a single space, `Keep` reproduces
 * the source newline-or-not via the parent struct's `bodyBeforeNewline:Bool` synth slot. The wrap lives at
 * the parent for the same reason `UntypedBlockBody`'s does: the signature→body gap is consumed by the
 * parent struct's pre-field `skipWs` BEFORE this branch's sub-rule probes, so a branch-local slot would
 * always read "no newline".
 *
 * `HxFnBlock` is trivia-bearing, which transitively makes this enum bearing — paired type `HxFnBodyT`
 * synthesised by `TriviaTypeSynth`.
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
	 * `#if <cond> <body> [#elseif ...] [#else <body>] #end` occupying the ENTIRE function-body
	 * slot. See `HxConditionalFnBody` for the motivating shapes and the Ref-vs-Star rationale.
	 *
	 * Dispatched BEFORE `ExprBody`, and that ordering is load-bearing. `ExprBody` runs the whole
	 * `HxExpr` parser, whose last `#if` ctor is `HxExpr.CondSpliceExpr` — a raw `{raw, tail}`
	 * swallow that consumes the region through its `#end` and then parses whatever FOLLOWS as
	 * the `tail`. At a member boundary that tail is the NEXT MEMBER, so with `ExprBody` first a
	 * whole-body region silently absorbed the member after `#end` (or its leading `static` /
	 * `public` word as an `IdentExpr`) unless it happened to be the LAST member. Trying
	 * `CondBody` first ends the body at its own `#end` whenever the region is a balanced
	 * per-branch body; a shape whose SUB-PARSE fails still fail-rewinds into `ExprBody`.
	 *
	 * The cost, a TRADE and not a pure win: a balanced region followed by an expression TAIL is
	 * representable here, so `CondBody` commits and the tail is stranded at member position
	 * with nothing to backtrack into — `#if a 1 #else 2 #end + 3` and `#if a x #else y
	 * #end.g()` FAIL TO PARSE in a body slot though they are legal Haxe. Taken knowingly: no
	 * real tree writes the tail shape, the std writes the swallow shape, and a parse refusal is
	 * loud where the swallow was silent (`testBalancedRegionWithExpressionTailIsRefused` pins
	 * it). The principled recovery, deferred: a restricted arm type for
	 * `HxConditionalFnBody.body` that rejects a bare-VALUE branch — an `ExprBody` carrying no
	 * `;` of its own — since a whole-body region always has `;`-terminated or braced arms.
	 *
	 * Second consequence: a region whose branches are single EXPRESSIONS projects here too
	 * (`function f() #if a { 1; } #else { 2; } #end`), the more accurate of the two readings, at
	 * one layout cost: a trailing `;` written OUTSIDE the region is not absorbed by
	 * `ExprBody`'s `@:trailOpt(';')` and lands as a sibling `EmptySemiMember`. Adding
	 * `@:trailOpt(';')` here does NOT recover it — the two trailers together make every
	 * `CondBody` source unparseable. A second layout cost: `HxFnDecl.body` wires
	 * `bodyPolicyForCtor` for `UntypedBlockBody` and `ExprBody` and not for this ctor, so the
	 * region is always emitted one space after the signature; wiring `bodyPolicyForCtor` here
	 * is NOT a drop-in fix, since that policy defaults to `Next` and would break same-line
	 * sources — it needs `Keep`-style source fidelity.
	 *
	 * The `#if` keyword lives on `HxConditionalFnBody.cond` rather than on this branch — the
	 * `HxUntypedFnBody` precedent: a bare single-Ref branch sits in
	 * `WriterLowering.spacePrefixCtors`, so the parent's `@:fmt(leftCurly)` emits the
	 * `<signature> #if` separating space, where a branch-level `@:kw` glued the region onto the
	 * return type (`:Dynamic#if`). `@:trail('#end')` stays on the branch.
	 */
	@:trail('#end')
	CondBody(inner: HxConditionalFnBody);

	@:trailOpt(';')
	ExprBody(expr: HxExpr);
}
