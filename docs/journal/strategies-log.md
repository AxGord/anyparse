# Strategies journal

> **Journal, not contract.** Every number here is a reading of one tree at one moment; the
> contract lives in [`docs/strategies.md`](../strategies.md). Each block is the ORIGINAL text of a paragraph
> that the reference condensed or dropped, moved verbatim under the section it was written in
> (`From § …` names that section by its heading at the time), in the original order, so
> `git log -S` and the ledger's citations still resolve (the one edit: a link to a sibling doc
> gains `../`, and a same-file `#anchor` gains `../strategies.md`, since this file lives one
> directory down). A `§` pointer inside moved text names a heading of the reference
> (`docs/strategies.md`), not of this file. Nothing here is a norm, and nothing here is auto-loaded.

## From § The interface

```haxe
interface Strategy {
  /** A short, stable name. Used in dependency declarations and error messages. */
  var name:String;

  /** Names of strategies that must have annotated before this one runs. */
  var runsAfter:Array<String>;

  /** Names of strategies that must run after this one. */
  var runsBefore:Array<String>;

  /** Which metadata tags this strategy exclusively owns. Conflicts are a registration error. */
  var ownedMeta:Array<String>;

  /** Return true if this strategy applies to the given shape node. */
  function appliesTo(node:ShapeNode):Bool;

  /** Annotate the shape node with this strategy's namespaced slots. No lowering yet. */
  function annotate(node:ShapeNode, ctx:LoweringCtx):Void;

  /**
    Lower the shape node to CoreIR, or return null to let base lowering handle it.
    Called during pass 3.
  **/
  function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR>;

  /** Declarations of what the strategy needs at runtime — context fields, helper methods, cache key contributions. */
  var runtimeContribution:RuntimeContrib;
}

typedef RuntimeContrib = {
  ctxFields:Array<Field>,            // new fields on the Parser context
  helpers:Array<Field>,              // helper methods available to generated code
  cacheKeyContributors:Array<Expr>,  // expressions contributing to the packrat cache key
};
```

## From § Rules of engagement › Strategies do not emit Haxe code

Strategies emit CoreIR. Codegen (pass 4) turns CoreIR into `haxe.macro.Expr`. A strategy that directly calls `macro ...` is wrong — it should be emitting CoreIR with `Host` as the escape hatch if nothing else works.

## From § `@:fmt(...)` — the writer-lowering handler vocabulary

**The measurement, on this tree.** 335 `@:fmt(...)` annotations across the shipped
grammars declare **212 distinct flags**: 142 bare-only, 65 argument-only, and 5 that
appear both ways (`beginEndType`, `blockBodyKeepsInline`, `emptyCurlyBreak`, `leftCurly`,
`rightCurly`). The distribution is long-tailed — `padLeading` 51 sites, `padTrailing` 48,
`propagateExprPosition` 30, `wrapRules` 26, `groupRestProbe` 21, `conditionalBodyIndent`
18, `captureRhsTrail` 16, `bodyPolicy` 15, `leftCurly` 14, `typeParamClose` 13 — and 102 of
the 211 appear exactly once, each for one construct's one problem.

(`clearBracePolicy` is the 212th: it is declared twice, on `HxExpr.MacroClassExpr` and
`HxExpr.MacroExpr`, and read by `WriterLowering`, but the first extraction of this list
dropped it — a `@:fmt(a, b)` entry whose SECOND identifier is the one nothing else names.
The ownership table below is the check that found it, and is now the check that keeps the
list honest.)

## From § `@:fmt(...)` — the writer-lowering handler vocabulary › Which module answers a flag

Read the shape of it, not just the numbers. The counts sum to far more than 212 because a
flag is named wherever it is asked, and several are asked in two emitters.

`WriterLowering` answered 117 of 212 until S133, and that number was never a per-flag split
waiting to finish. The writer lowering is organised by grammar SHAPE — Star, Ref, Terminal,
Alt branch, Pratt — and a flag is a branch INSIDE one of those emitters, not a unit of its
own, so splitting by flag would mean rewriting the emitters. What the `Writer*Lowering`
modules below `WriterLowering` in the table are is a split by SHAPE FAMILY, which is code
motion: each is one region of that module's call graph moved whole, with the flags its
emitters happened to ask travelling along. Reading a family's row therefore tells you how
`@:fmt`-dense that shape is, not that the flag belongs to it. That the biggest rows are now
`WriterRefFieldLowering` (45), `WriterTriviaStarDispatch` (43) and `WriterStarEmitLowering`
(40) is the same fact stated after the split: those shapes are where the flags always were.
The two Star rows add to 68 where one row held 58, and that is the counting rule showing
through rather than an error: `WriterStarEmitLowering` fell 58 -> 40 when S137 took its
trivia routes into `WriterTriviaStarEmitLowering` (28), and ten of the 58 are asked on BOTH
sides of that seam, so they are now named twice.

`WriterRefLeadLowering`, `WriterCondWrapLowering`, `WriterTriviaSlotLowering`,
`WriterBraceSymmetryLowering`, plus a fifth, `WriterStarPadLowering`, that names no
inventory flag at all and therefore has no row — are a split along a DIFFERENT axis: not
"which shape family is this member in" but "what state does this member read". A census of
`WriterLowering`'s 127 members found 25 that touch none of `_shape` / `_formatInfo` /
`_ctx` / the six ctx bundles, directly or through a callee — pure functions of their
arguments, for which `private function` → `private static function` in a sibling module
costs no call-site change at all (the wildcard import plus the class-level `@:access`
reaches them unqualified). 24 of the 25 moved. That axis is orthogonal to the shape
families and stops much sooner: the remaining 102 members read build state, and moving one
of those is a signature change at every call site.

Which is why the axis that came NEXT is neither of those two, and why
`WriterBraceSymmetryLowering` is the one row that grew rather than appearing. Re-run the
census over the 121 members left, but record for each what SLICE of the instance it needs
rather than a yes/no: 50 members / 2482 lines reach the instance only through `_ctx.trivia`
and `_shape.rules` — one `Bool` and one `Map`. That is not a decomposition on its own (it
is "everything reachable from `isTriviaBearing`", one call graph, no name), but it prices
every candidate family inside it, and the prices differ by a factor of twenty-five: the
trivia-paired NAMING vocabulary (`isTriviaBearing`, `writeFnFor`, `ruleCtorPath`,
`ruleValueCT`) is 42 lines behind 33 inbound call sites, the ctor-pattern lookups 218 lines
behind 25, and the brace-symmetry family 382 lines behind SEVEN. Cheapest-to-free and
cheapest-to-move are opposite ends of the same graph — a hub frees the most members and
costs the most call sites — so the state census names candidates and only the inbound count
picks between them.

So the brace-symmetry family moved, and this is the shape a member that reads build state
takes when it does: `private static`, with a `BraceSymmetryCtx` bundle as its first
argument, built once in `WriterLowering`'s constructor exactly like `_pratt` / `_kwRef` /
`_bodyPolicy` / `_arrowValueIf`. The bundle carries `shape`, `ctx` and the three shape-name
helpers whose other callers stayed behind. Nothing about the emitted writer changes: the
macro package is `#if macro`, so none of it reaches a JS target's output and a build of the
moved tree is byte-identical to a build of the unmoved one.

The `TriviaPair*` and `WriterOptFanout` rows are a THIRD axis, and they are there because
the second one had nothing to say about them. `TriviaTypeSynth` (95 members) and
`WriterCodegen` (75) declare no instance field AT ALL — every member of both was already
static — so the state census that split `WriterLowering` returns 100 % pure and decides
nothing. What binds instead is the QUALIFIED call site: `WriterCodegen.<member>` is spelled
twice outside its file and 48 of its members left at zero call-site change, while
`TriviaTypeSynth.<member>` is spelled 133 times outside its file, 59 of those the ALL-CAPS
slot-name constants, which is why the name vocabulary stayed and the three question-shaped
families (`TriviaPairAltCtor` — which extra positional argument an Alt branch shape earns;
`TriviaPairSlots` — which trivia slot a struct field earns; `TriviaPairConverters` — how a
paired value converts to and from its raw sibling) left instead.

`WriterLowering`'s row did NOT move, and the reason is a measurement rather than an
omission. Its purity axis is genuinely spent: a state census over its 94 methods finds ZERO
that are transitively pure, so nothing is left that `private function` → `private static`
would move for free. (Beware the instrument here — an offset census that slices member
bodies by BYTE rather than by codepoint reports 34 pure methods on this file, because the
`ω-` comment markers are multi-byte; the same run reports 19 for `Lowering` where the true
answer is the 5 purity leaves S83 deliberately left. Slice by codepoint and both numbers
collapse to the recorded ones.)

What remained was the family axis, and S117 priced it: five exclusive call-graph regions
cover 84 of the 112 members — Seq-field 30 / 1738 lines, Ref-field 22 / 1547, Star emit
16 / 1200, Alt branch 11 / 805, Terminal-and-by-name 5 / 237 (S133 reproduced all five from
an independent census; the Terminal row matched to the member and the line). Clearing BOTH
caps needs 62 members and 3869 lines out, i.e. at least three of the five, and S117 refused
on two obstacles. The FIRST was that the two largest regions looked MUTUALLY entangled:
seven of the nine members Ref-field reaches outside itself (`sameLineSeparator`,
`beforeKwSeparator`, `padTrailingDoc`, `buildBareRefLeadingSep`, `beforeTrailSlotAccess`,
`findCtorPattern`, `collectBlockCtorPatterns`) were read as members of the Seq-field region.

The edges were real; that reading was not, and the discriminator is the campaign's own rule
— judge a member by what it READS. None of the seven is a Seq-field member. Four
(`sameLineSeparator`, `beforeKwSeparator`, `padTrailingDoc`, `buildBareRefLeadingSep`) read
one field's `@:fmt` gap metadata and the trivia slot behind it: they answer "what `Doc` goes
BETWEEN two emits", which is a LAYER both families stand on, and they are now
`WriterFieldSepLowering` with `sameLineSeparatorShapeAware` and `valueIfFitSeam` beside
them. Two (`findCtorPattern`, `collectBlockCtorPatterns`) read only `shape.rules` and answer
"which Alt branches of this rule match a shape predicate, and what pattern does each
project" — a second layer, and one already exported by bound closure to five sibling modules
through `_bodyPolicy` / `_ctorBlank` / `_arrowValueIf` / `_braceSym`, which is a layer's
signature written down before anyone named it. They are now `WriterCtorPatternLowering`,
twelve neighbours included. The seventh, `beforeTrailSlotAccess`, is a plain Ref-field
member that landed in a Seq-field bucket only because its two callers sit in two different
Ref sub-families whose nearest common dominator is `lowerStruct`.

With both layers named, the entanglement is gone rather than carried: `WriterRefFieldLowering`
reaches NOTHING in the Seq walker — `lowerStruct` calls in at four sites and nothing calls
back — and its bundle is eight fields with neither `shape` nor the format info in it. Three
helpers that read as shared (`buildBodyPolicyForCtorChain`, `buildBoolFlagRawWriteCall`,
`buildLeftCurlySepExpr`) turned out to have both their callers inside the family and came
along, and `blockEndedPredCheck` / `arrayBracketInsidePolicySpace` did the same for the Star
side. S117's SECOND obstacle — that the Star-emit region holds `emitWriterStarField` and not
`lowerEnumStar` — was answered by taking BOTH: `WriterStarEmitLowering` carries the two
writer halves of the four-site Star fork together and names the parse pair in its own header,
which is more than a 7309-line file holding them 3200 lines apart was doing.

`WriterLowering` is 112 members / 5869 lines before and 47 / 1508 after, and the
`oversized-type` row is gone from the whole macro package. The proof of a pure decomposition
is byte-identity: the corpus sweep is unchanged at 781 / 120 / 43 and two whole-repo Pony
runs, base engine against this one, are identical file for file.

`Lowering`'s row fell from 16 to 3 on a FOURTH axis, and it is the parse side's first
split by RULE SHAPE. `lowerRule` dispatches a top-level type on four shapes, and until now
every emitter for all four lived in one 4801-line type: `TerminalParseLowering` now carries
the `EReg`-and-decode shape (and names no inventory flag at all, so it has no row — a
terminal rule's parse body has no layout to ask about), `StructSeqLowering` the typedef Seq
walk and its per-field emit, `StarFieldLowering` the six repetition emitters underneath it,
and `PrattPostfixLowering` the two operator-precedence loops. Every member that reads state
takes the state-carrying shape: `private static` with a ctx bundle as the first argument,
built once in `Lowering`'s constructor, carrying the fields the family reads plus the
naming vocabulary that stayed behind (`parseFnName`, `isTriviaBearing`, `ruleReturnCT`, …)
as bound closures. `StarFieldLowering` is the one that is a SIZE split rather than a new
responsibility — same rule shape, same state, so it takes `StructSeqLowering`'s own
`StructSeqCtx` unchanged instead of declaring a bundle of its own. It is also where the
five purity leaves S83 deliberately left behind finally went: they are the enum-ctor half
of the four-site Star+sep audit and `emitStarFieldSteps` is the struct-field half, so
putting both in `StarFieldLowering` keeps that audit ONE read — which is the reason S83
gave for not moving them, honoured rather than dropped.

`unit.lowering.FmtFlagOwnershipTest` pins all of it: every inventory flag is named by at
least one module, the module list and the per-module counts match the scan, and the four
handler-only flags are named-but-undeclared. Change any of it and the test says which line
of this file to edit. That is how `clearBracePolicy` was found.

## From § `@:fmt(...)` — the writer-lowering handler vocabulary › What a split has to pass

This codebase had already WRITTEN a layer down before anyone named it. `_bodyPolicy`,
`_ctorBlank`, `_arrowValueIf` and `_braceSym` are bound closures assembled in
`WriterLowering`'s constructor and handed to four sibling modules; the members those four
closures reach are exactly what became `WriterCtorPatternLowering`, and the closure list was
the evidence that they had multiple unrelated callers. Read a constructor's bundle
assignments before proposing a seam: a layer usually already has one.

The size splits are legitimate too, and they are recognisable by what they take:
`WriterStarPadLowering` takes `PlainStarCtx` and holds LEAVES; `StarFieldLowering` takes
`StructSeqLowering`'s own `StructSeqCtx` unchanged because it is the same rule shape and the
same state; `WriterTriviaStarEmitLowering` (S137) takes `WriterStarEmitLowering`'s whole
`StarEmitCtx` and reads seven of its fifteen fields, which is why its header calls itself a
size split and names the cap it relieved.

**Does it move a FORK half away from its twin?** Star emission forks across FOUR sites —
`StarFieldLowering.emitStarFieldSteps` and the `lowerStar*Branch` leaves beside it on the
parse side, `emitWriterStarField` (struct field) and `lowerEnumStar` (enum ctor) on the
writer side. Adding anything to Star emission means editing all four, so a split that puts
two of them in different modules with nothing naming the other half is REFUSED, and an
earlier slice that took one and left the other had to move five leaves back. The two writer
halves live together in `WriterStarEmitLowering` and its header names the parse pair.

What that constraint does NOT forbid is taking a leaf or a sub-tree out from under ONE fork
half, and the discriminator is the call graph, not the topic. `WriterStarPadLowering` was
admissible because none of its members is reachable from `lowerEnumStar`;
`WriterTriviaStarEmitLowering` was admissible for the same reason, measured the same way —
`emitTriviaStar` and its four descendants have exactly one inbound edge (`emitWriterStarField`
at one site), call nothing else in the module, and the enum arm reaches its own trivia emit
through `lowerEnumStarTrivia` / `triviaSepStarBuild` / `triviaBlockStarBuild`, sharing no
member with them. Both fork halves and the whole enum arm stayed. S137 also re-derived the
seam S133 had named for it and found it one member wider than recorded: the tryparse route's
two sep-override builders (`buildTryparseSepOverrides`,
`buildCloseTrailingFirstSepOverride`) are private to `emitTriviaTryparseStar`, so the closed
region is 5 members / 532 lines, not 3 / 404. `WriterStarEmitLowering` is 1957 lines / 25
members before and 1425 / 20 after, against a 2000-line `oversized-type` cap it was 43 lines
under.

**The module-level typedefs under `WriterLowering` are not a shared vocabulary, and the
question is settled.** Its 52 module-level typedefs look like a block waiting for a home;
measured, they are 93 point-to-point edges to 20 consumer modules, and 29 of the 52 have
exactly ONE consumer, 51 of 52 at most five (`PrevBodyInfo`, the maximum, has five). Every
one of them is the bundle `WriterLowering`'s constructor BUILDS and hands to one collaborator,
so the declaration sits at the producing end; only `FieldMeta` has no external consumer at
all. A dedicated module would give twenty modules a second dependency to name in place of one
they already have, and typedefs do not count toward the `oversized-type` line extent, so
there is no size argument either. Leave them.

⚠️ **The instrument that answers this is NOT `hxq uses` / `lit` / `mentions`.** A type
annotation on a PARAMETER or a LOCAL declaration is not projected into the query tree at all
(`probe 'function f(c: Mod.T) { final m: Mod.T = null; }'` gives `(Required c)` and
`(FinalStmt m …)` with no type child), so a type referenced only there is invisible to all
three. A `uses`+`lit` census over this tree reported ELEVEN of these typedefs as dead; every
one of the eleven is live, each read by exactly one sibling module through a qualified
`WriterLowering.<T>` parameter or local annotation, and the Haxe compiler is what said so.
For a deadness question about a type, dump the sources and search the TEXT, or delete and
build.

## From § Planned strategies › Lit

Owns: `@:lit`, `@:lead`, `@:trail`, `@:trailOpt`, `@:wrap`, `@:sep`.

Lowers literal glue around fields into `Lit` nodes in a `Seq`. A field with `@:lead("{")` becomes `Seq([Lit("{"), field])`. A `@:sep(",")` on a `Star` becomes `Star(item, sep=Lit(","))`.

`@:trailOpt(";")` is the optional-on-parse variant of `@:trail`. The parser emits `matchLit` (peek + consume-if-present) instead of `expectLit` (throws on absence); the writer keeps emitting the literal as canonical output. First consumer: `HxDecl.TypedefDecl` for `typedef Foo = T` without trailing `;`. Source-fidelity (preserve presence per input) came later as the `<field>TrailPresent` synth slot (`ω-struct-trailopt-source-track`), which the writer consults instead of always re-emitting.

Two fields opt OUT of that fidelity on purpose. A field carrying `@:fmt(dropSingleStmtBraces)` (`HxIfStmt.thenBody` / `elseBody`, `HxForStmt.body`, `HxWhileStmt.body`, `HxDoWhileStmt.body`) NEVER re-emits its trail literal (`omega-ssb-trailopt-drop`): a STATEMENT owns its own terminator — in `if (c) g();` the `;` sits inside the inner `ExprStmt` — so this slot can only ever hold a REDUNDANT `;` (`for (…) { x; };`). Canonicalising it away is what makes the `for (…) x;;` shape unreachable, so `SingleStmtBraces` no longer has to keep the braces to avoid it. Fidelity is the right default only where the optional token is a legitimate style choice; where it is provably meaningless, preserving it would let stray input degrade unrelated layout.

`@:sep(",", tailRelax)` is the opt-in two-arg form that makes "trailing sep before close is accepted" an explicit grammar contract. The bare ident `tailRelax` is the only recognised second arg. Semantically a no-op against current `Lowering.hx` behaviour — the close-peek Star loop already tolerates a trailing sep — but the annotation earmarks consumers for the BlockBody Star refactor (project memory `project_blockbody_star_tail_relax_debt`) and documents intent at the grammar site. First consumers: `JArray` / `JObject` in the JSON grammar.

`@:sep(";", tailRelax, blockEnded)` is the three-arg form that additionally turns on **block-ended exemption** — between two elements, the separator may be omitted when the prior element ended with `}` or `;` (parser-side byte-level check on `_prevEndPos - 1`). Writer side: `DocMeasure.endsWithCloseBrace` performs the equivalent check on each element's rendered Doc, suppressing sep emission when true. Combined with tail-relax this implements the trivia-mode part of the Haxe `BlockBody` separator policy. First consumer: the `MiniBlock` pilot grammar under `test/unit/miniblock/`. The ident must appear after `tailRelax` — `@:sep("text", blockEnded)` without tail-relax is rejected at compile time.

`@:sep(";", tailRelax, blockEnded("<predicate>"))` is the option (b2) AST-shape variant. In addition to the byte-check `}` / `;`, the Star primitive calls the named predicate on the just-pushed element (`<accum>[<accum>.length - 1]`) to decide sep-elision by AST shape. For a format declaring `astPreds = true` (Haxe), the string names a GENERATED typed function on the per-family `AstPreds` / `AstPredsT` / `AstPredsS` marker classes (tables in `HxAstPredLowering`, machinery in `AstPredLowering`); other formats keep the legacy schema-instance channel — a method on the plugin's HaxeFormat-shaped class, reached through the same channel as `unescapeChar` (the MiniBlock pilots' path). Required to cover ident-terminated stmts (e.g. `x is String` — `HxStatement.ExprStmt(Is)`) and `]`-terminated stmts (`[1, 2, 3]` — `HxStatement.ExprStmt(ArrayExpr)`) which the byte-check cannot cover safely (`]` would silently accept `arr[0] foo()`). Both channels are wired by the helper `Lowering.buildBlockEndedPredicateCall`; the same astPreds split applies to the `trailOptParseGate` writer/parser gates.

## From § Planned strategies › Re

Owns: `@:re`.

## From § Planned strategies › Kw

Sugar for "keyword with word boundary". Lowers `@:kw("true")` to `Seq([Lit("true"), Not(Re("[A-Za-z0-9_]"))])`. Handles the common bug where `true` matches the start of `trueish`.

## From § Planned strategies › Skip

Cross-cutting. Does not lower nodes directly. Instead, pushes the active skip regex onto `LoweringCtx.skipStack` when entering a scope, and base lowering inserts `currentSkip` before each `Lit`/`Re` terminal in that scope.

`@:ws` is shorthand for `@:skip('[ \t\n\r]*')`.

## From § Planned strategies › Capture

Owns: `@:capture`, `@:match`.

Implements named captures for context-dependent grammars. `@:capture public var tag:XIdent` stores the matched text in a slot named after the field. `@:match(tag) public var _close:Void` asserts that the current position matches the same text. This is how XML matches `<a>...</a>`.

## From § Planned strategies › Pratt

Owns: `@:infix`, `@:prefix`, `@:op`.

When an enum has constructors with `@:infix(prec, assoc)` and `@:op("...")`, Pratt takes over lowering. It splits constructors into atoms (primary expressions) and operators (with priority tables). It emits a `Host` node containing a Pratt operator-precedence climbing loop, where `parsePrimary()` is generated from the atom constructors via the normal `Alt` strategy.

This is one of only two places where `Host` is used in the base library — because the Pratt loop is genuinely stateful and iterative in a way that does not fit cleanly into PEG combinators.

## From § Planned strategies › Indent

Owns: `@:indent(same)`, `@:indent(block)`, `@:indent(gt)`, `@:indent(suspend)`.

Handles indent-sensitive grammars. Requires runtime state (`indentStack:Array<Int>`) contributed to the Parser context. Wraps `@:indent(block)` fields in `Host` nodes that push and pop the stack with `try/finally` semantics.

The `@:indent(suspend)` variant freezes the indent stack within a scope — needed for Python-style implicit line continuation inside `(...)` groups.

## From § Planned strategies › Binary

Owns: `@:u8`, `@:u16le`, ..., `@:magic`, `@:tag`, `@:tagMask`, `@:fromTag`, `@:lenPrefix`, `@:countPrefix`, `@:count`, `@:decode`, `@:bytes`.

The biggest strategy by metadata count. Lowers binary format primitives into `Bin(BinKind)` nodes, `Switch` nodes for tagged unions, and `Count`/`BytesVar` for length-prefixed structures.

Interacts with `Skip` by overriding it to empty when entering a `@:bin` type (binary formats have no whitespace).

## From § Planned strategies › Recovery (future)

Owns: `@:commit`, `@:recover`.

Activated only in Tolerant mode. Wraps relevant rules in error-recovery logic: on error after a `@:commit`, collects the error and advances to the nearest sync point declared by `@:recover(syncRe)`, then resumes parsing.

Not in Phase 1 or 2. Appears when Tolerant mode becomes a full target.

## From § Writing a new strategy

1. **Pick an owned metadata name**. Check `strategies/` for conflicts. Name should be short and specific to what it does.
2. **Pick dependencies**. If your strategy lowers to primitives that another strategy handles (e.g., `Kw` lowers to `Lit` + `Not`), declare `runsBefore` so you run first.
3. **Implement `appliesTo`**: check for your metadata on the node.
4. **Implement `annotate`**: write into namespaced slots. Do not lower yet.
5. **Implement `lower`**: produce `CoreIR`. If your strategy is purely annotation (like `Skip`), return null and let base lowering handle structural form.
6. **Declare `runtimeContribution`**: if you need a field on the Parser context or a helper method, declare it. Strategies that do not need runtime state return empty arrays.
7. **Register in the strategy registry**: one line in the strategies list.
8. **Write tests**: a small `@:peg` type using your metadata, compile it, assert the generated code behaves correctly.

## From § Error cases the framework catches at registration

- Two strategies claiming the same `ownedMeta`.
- Cyclic `runsAfter`/`runsBefore` dependencies.
- A strategy declaring `ctxFields` but no `cacheKeyContributors` (packrat integrity).
- A strategy declaring a helper with the same name as another strategy's helper.

These are all compile-time errors and prevent surprising runtime behavior from ambiguous composition.
