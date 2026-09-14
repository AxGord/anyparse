# Strategies

A **strategy** is a plugin that knows how to turn a piece of grammar into a piece of CoreIR. Strategies are the extensibility point of anyparse: adding a new parsing technique (new operator precedence scheme, new indentation semantics, new binary layout) means writing a new strategy, not modifying the core.

See `architecture.md` for the overall macro pipeline and how strategies fit into it.

## The interface

`anyparse.core.Strategy` (`src/anyparse/core/Strategy.hx`, `#if macro`) is the contract, and each member's doc there is the authority on what it must do: `name` (stable, used in dependency declarations and errors), `runsAfter` / `runsBefore` (the ordering constraints), `ownedMeta` (the tags this strategy exclusively owns), `appliesTo` (does this shape node concern me), `annotate` (write my namespaced slots — pass 2, no lowering), `lower` (return a CoreIR subtree or `null` to leave the node to base lowering — pass 3), and `runtimeContribution` (`anyparse.core.RuntimeContrib`: context fields, helper methods and packrat cache-key contributions the generated parser must carry). `anyparse.macro.StrategyRegistry` is the thing that consumes it — it validates ownership, topo-sorts and runs the annotate walk — and `Build.registerStrategies` is where the shipped strategies are registered (called by `buildParser` and `buildWriter`).

## Rules of engagement

### One owner per metadata tag

If two strategies claim `@:lit`, the registration fails at compile time. This is how we catch silent conflicts early. If two strategies need to read the same tag, one of them declares it as `owned` and the other as `reads` (a read-only dependency — not yet implemented, will be added when needed).

### Namespaced annotations

A strategy writes to `node.annotations["strategy-name.field"]`. It never touches a slot owned by another strategy. This means strategies can be developed independently and composed without fear of cross-contamination.

### Lowering is append-only on existing shape

A strategy's `lower` function returns a new `CoreIR` subtree for the node it owns. It does not modify the shape tree. If it returns `null`, base lowering handles the node with default semantics.

### Explicit dependencies, not implicit ordering

`runsAfter` and `runsBefore` declare which other strategies this one needs to see annotated before or after it. A topological sort at registration time produces a deterministic run order. Cycles are a registration error.

### Strategies do not emit Haxe code

Strategies never emit `haxe.macro.Expr`: their contribution is the slots `annotate` writes and, for one that needs its own shape, a CoreIR subtree from `lower`; as shipped every strategy returns `null` and `Lowering` emits the parser expression from the slots directly (`docs/architecture.md` § "Five-pass macro pipeline"). A strategy that directly calls `macro ...` is wrong — `Host` is the escape hatch if nothing else works.

### The engine never spells a grammar's own type or constructor

Invariant 4 read at its sharpest: nothing under `anyparse.core` or `anyparse.macro`
may name a rule type or an enum constructor of any one grammar — not as an
identifier, and not as a string it switches on. A `@:fmt` feature whose lowering
knows `HxFnBody` is a feature only the Haxe grammar can ever opt into, and the
next grammar's author has no way to see that from the outside.

What the lowering may do instead is ASK. Two channels exist, both declarative:

- **A meta argument.** `@:fmt(bodyPolicyForCtor('ExprBody', 'functionBody'))` names
  the constructor at the GRAMMAR, and the lowering treats it as an opaque string
  it passes to `ruleCtorPath`. Same for `metaBlockGlue`, `valueBraceSymmetry`,
  `arrowValueIfReflow`.
- **A generated predicate.** For a question that needs real code — "is this element
  a call-bearing container", "is this array literal a map or a comprehension" — the
  lowering emits a call to the per-family marker class
  (`<grammarPack>.AstPreds` / `AstPredsT` / `AstPredsS`, tables in the grammar's own
  `…AstPredLowering`, machinery in `anyparse.macro.AstPredLowering`). The lowering
  holds only the PREDICATE NAME, which is a name it owns; the marker-class path is
  derived from the grammar root. A format that has not declared `astPreds` keeps the
  older schema-instance channel (`<schema>.instance.<predicate>`), which is equally
  grammar-neutral at the call site.

`unit.query.LexicalRegionsSeamTest.testTheEngineNamesNoHaxeGrammarRuleType` is the ratchet.
It derives the name inventory from the grammar package's own module list, so a new
rule extends it for free, and it counts a hit inside a STRING literal — the last two
violations it removed were a `switch` on `'HxFnBody'` / `'HxFnExprBody'` in
`WriterLowering` and a hard-coded `HxComplexItems.kinds` call emitted from two sites.
What it does not see is a bare constructor name in a `macro switch`; reaching those
needs the constructor inventory rather than the module list.

## `@:fmt(...)` — the writer-lowering handler vocabulary

`@:fmt` is the grammar's channel into the WRITER half of the build macro. It carries no
built-in meaning of its own (invariant 6): a grammar declares a flag on a rule type or a
field, and `WriterLowering` — with `TriviaPairSlots` / `TriviaPairAltCtor` and
`Lowering` for the trivia and span twins — decides what layout the flag lowers to. A flag nothing reads is silently
inert, which is why this section is an INVENTORY rather than a specification: the list
below is what the macro answers to today, extracted from the declarations themselves.

**How a flag is read.** `MetaInspect.fmtHasFlag(node, name)` walks the node's `:fmt`
metadata and matches either `EConst(CIdent(name))` — the bare form — or
`ECall({expr: EConst(CIdent(name))}, args)` — the argument form. So `@:fmt(padLeading)`
and `@:fmt(bodyPolicy('functionBody'))` are the same mechanism, and a flag may appear in
both forms in different places. Arguments are opaque strings the lowering forwards
(a `hxformat.json` key, a rule-constructor name it hands to `ruleCtorPath`, a field
name); the lowering never interprets one as a grammar type of its own — see "The engine
never spells a grammar's own type or constructor" above.

**The inventory.** `(…)` marks a flag that takes arguments, `[(…)]` one seen in both
forms; everything else is bare.

```
accessBrackets, afterFieldsWithDocComments, afterFileHeaderCommentBlanks, allmanIndentForCtor(…),
anonFuncParens, anonTypeBracesClose, anonTypeBracesOpen, arrayMatrixWrap, arrowBodyLineWrap,
arrowBodyOpenPadSuppress, arrowFunctions, arrowValueIfElemTrail, arrowValueIfReflow(…), arrowValueIfReflowSite,
atomOperand, bareBodyBreaks(…), bareRefSepWhenPresent, beforeDocCommentEmptyLines, beforeDocCondLookThrough(…),
beforeNewlineSlotFirst, beginEndType[(…)], betweenMultilineCommentsBlanks, blankAroundMultilineMembers(…),
blankBeforeFinalDocCommentInLeading, blankBeforeLineCommentLed, blankBeforeOrphanLineCommentTrail,
blankLinesAfterCtor(…), blankLinesAfterCtorIf(…), blankLinesAfterCtorIfTailLeafNull(…),
blankLinesAtHeadIfCtor(…), blankLinesBeforeCtorIfPrevNot(…), blankLinesBetweenSameCtorByLevel(…),
blankLinesBetweenSameCtorHeadTransparent(…), blankLinesBetweenSameCtorIfNot(…),
blankLinesBetweenSameCtorTailTransparent(…), blankLinesOnTransitionAcross(…), blockBodyKeepsInline[(…)],
blockShape, bodyAllmanIndentForCtor(…), bodyAwareCompactIndent, bodyBreak(…), bodyPolicy(…),
bodyPolicyForCtor(…), bodyPolicyOverride(…), bodyPolicySingleLine(…), bracketKindPad,
breakAfterLeadOnOverflow(…), callArgChainNest, callParens, callParensInside, captureChainNewline,
captureCondOpenNewline, captureKwNewline, capturePostfixOpSpace, captureRhsTrail, captureSource(…),
captureSourceNewlineAfter, captureTernaryTrail, captureTrailComment, captureWrapOpenNewline,
caseSiblingSymmetry(…), catchParensGap, catchParensInsideClose, catchParensInsideOpen, chainNestSuppress,
clearBracePolicy, clearElseIfBranch, clearExprPosition, clearExprPositionNonTail, complexItems, condExprFitBreak,
condExprFitGroup, conditionalBodyIndent, conditionalMarkerDedent, condParensInside(…),
condSpliceCaseMarkerDedent, condSwitchOpenCasesNest, condWrap(…), condWrapEnd, constructFitBody,
constructFitGroup(…), constructFitSep, cuddle, deferKwSpace, dropSingleStmtBraces, elemSelfTrailsNewline,
elseIf, elseIfCommentReflow, elseSwitch(…), emptyBlockBreak, emptyCurlyBreak[(…)], existingBetweenFields,
expressionParenHardFlatten, fillItems, fillParts, fillSeam, fitLineIfWithElse, flatChildOpt(…), forceInlineSep,
forceMultiInTypedef, forPolicy, forwardNewlineForBody, funcParamParens, functionTypeHaxe3, functionTypeHaxe4,
groupRestProbe, heritageWrap, ifPolicy, ignoreSourceNewlinesForWrap, indentCaseLabels, indentValueIfCtor(…),
inlineBlockBodyIfFlag(…), inlineSep, interMemberBlankLines(…), interMemberCondLookThrough(…), intervalPolicy,
keepBlankAfterStarCtor(…), keepCurlyBlanks, keepInnerWhenEmpty(…), kwPolicy(…), leftCurly[(…)],
leftCurlyAnonFnOverride(…), lineLengthAwareSeps, loopBodyIfElseNext(…), mapWrapRules(…),
measuredMultilineDecls, metaBlockGlue(…), metaLineEndPolicy(…), methodChain(…), multilineCtor,
multilineWhenFieldCtorAndOpt(…), multilineWhenFieldNonEmpty(…), multilineWhenFieldShape(…),
multilineWhenLeadingTriviaSpansLines(…), multilineWhenStarFieldWrapsCascade(…), multiVarWrap(…), nestBody,
nestBodyOnSourceNewline, noSiblingFallback(…), objectFieldColon, objectLiteralBracesClose,
objectLiteralBracesOpen, operandBreakAfterMultilineBrace, optionalSemicolon(…), padLeading, padTrailing,
preWrite(…), propagateAnonFnContext, propagateArrowLambdaBody, propagateElseIfBranch,
propagateEnumAbstractContext, propagateExprPosition, propagateFieldLevelVar, propagateTypedefContext,
propagateValueIfBranch, reflowInExprPosition, reflowSourceMultiline, refuseFlatOnComplexExpr,
refuseGlueOnControlFlowRoot, rightCurly[(…)], rightCurlyAnonFnOverride(…), sameLine(…),
semicolonBeforeSibling(…), semicolonNextLineElse, sepBeforeOpt, setBoolFlagFromStarCtor(…), shapeAware,
sharpCondParensGap, sharpCondParensInside(…), softFill, spaceAfterLead, spaceBeforeLead, spaceBeforeTrail,
staticVarSubdivision, suppressCallRestProbe, suppressComplexItems, suppressPatternRestProbe,
switchCondParensInsideClose, switchCondParensInsideOpen, switchPolicy, switchSubjectNoWrap,
switchSubjectParensStrip, switchWrapSpace, tight, tightKw, tightLead, tightOnParenOperand(…), trailingComma(…),
trailingCommaRemovable, trailOptParseGate(…), trailOptShapeGate(…), tryBraceSymmetry(…),
tryCatchBraceSymmetry(…), tryDeBrace, tryPolicy, typeCheckColon, typedefAssign, typedefBodyBlanks,
typedefIntersection, typedefIntersectionBreak, typeHintColon, typeParamClose, typeParamDefaultEquals,
typeParamOpen, uniformBetween(…), uniformStmtBlanks, valueBraceSymmetry(…), whileCondParensInsideClose,
whileCondParensInsideOpen, whilePolicy, widthAware, wrapRules(…)
```

Regenerate it with `apq meta '@:fmt' src/anyparse/grammar --limit 500 --flat` and collect
the identifiers out of each argument list — that command IS the source of the list above,
so a flag added to a grammar shows up without anyone maintaining a second copy. What it
cannot tell you is whether the macro still READS a given flag: a declaration whose handler
was removed keeps parsing and does nothing. That is the other half of the audit, and it is
the table below.

### Which module answers a flag

`@:fmt` has no dispatcher: a flag is not routed to a handler, it is ASKED FOR at the point
in an emit body that cares (`if (child.fmtHasFlag('nestBody'))`, `firstFmtFlag(node, [...])`,
`fmtReadStringArgs(node, 'bodyPolicy')`). So the answer to "who handles this flag" is
"which module names it", and this table is that, per module, over every string literal in
`src/anyparse/macro` that matches an inventory name.

| module | inventory flags it names |
|---|---|
| `WriterRefFieldLowering` | 45 |
| `WriterTriviaStarDispatch` | 43 |
| `WriterStarEmitLowering` | 40 |
| `WriterKwRefLowering` | 31 |
| `WriterTriviaStarEmitLowering` | 28 |
| `WriterCtorBlankLowering` | 17 |
| `WriterLowering` | 17 |
| `WriterRefLeadLowering` | 17 |
| `WriterPrattLowering` | 14 |
| `WriterPolicyLowering` | 10 |
| `TriviaPairSlots` | 9 |
| `TriviaPairAltCtor` | 8 |
| `StructSeqLowering` | 7 |
| `WriterBraceSymmetryLowering` | 6 |
| `WriterFieldSepLowering` | 6 |
| `PrattPostfixLowering` | 4 |
| `Lowering` | 3 |
| `StarFieldLowering` | 3 |
| `WriterBodyPolicyLowering` | 3 |
| `WriterCodegen` | 2 |
| `WriterBlankLowering` | 2 |
| `WriterCondWrapLowering` | 2 |
| `WriterLoweringSupport` | 2 |
| `WriterTriviaSlotLowering` | 2 |
| `StructFieldTrailLowering` | 1 |
| `TriviaPairConverters` | 1 |
| `WriterArrowValueIfLowering` | 1 |
| `TriviaSlotNames` | 1 |
| `WriterChainLowering` | 1 |
| `WriterCtorPatternLowering` | 1 |
| `WriterOptFanout` | 1 |

Read the shape of it, not just the numbers. The counts sum to far more than the inventory
because a flag is named wherever it is asked, and several are asked in two emitters.

The rows are not a per-flag split and never will be. The writer lowering is organised by
grammar SHAPE — Star, Ref, Terminal, Alt branch, Pratt — and a flag is a branch INSIDE one
of those emitters, not a unit of its own. The `Writer*Lowering` modules below `WriterLowering`
are a split by shape family (code motion: one region of the call graph moved whole, with the
flags its emitters ask travelling along), so a family's row says how `@:fmt`-dense that shape
is, not that the flag belongs to it; a flag asked on both sides of a seam is counted twice.
`WriterRefLeadLowering`, `WriterCondWrapLowering`, `WriterTriviaSlotLowering`,
`WriterBraceSymmetryLowering` and `WriterStarPadLowering` (no row — it names no flag) are a
split along a different axis, what STATE a member reads: pure functions of their arguments
moved as `private static` with no call-site change, and a family that reads build state moved
with a ctx bundle as its first argument, built once in `WriterLowering`'s constructor. The
`TriviaPair*` rows are a third axis, the qualified call site — `TriviaTypeSynth` and
`WriterCodegen` were already all-static, so the state census decided nothing there and the
three question-shaped families left instead. The parse side split the same way by RULE SHAPE
(`TerminalParseLowering`, `StructSeqLowering`, `StarFieldLowering`, `PrattPostfixLowering`
under `Lowering`), which is why `Lowering`'s row is small. The census readings and the slice
narrative behind each split are in `docs/journal/strategies-log.md`.

**Four flags are handler-only** — a macro module names them, no shipped grammar declares
them, so they are absent from the inventory above: `blankLinesBeforeCtor` and
`blankLinesBeforeCtorIf` (named by `WriterCtorBlankLowering`), `fill` and
`fillDoubleIndent` (named by `WriterLowering` and `WriterPrattLowering`). That is the
plugin contract working (a handler is available before a grammar asks for it), not dead
code — but it is the state that has to be visible, because the same reading covers a
handler whose grammar declaration was DELETED.

`unit.lowering.FmtFlagOwnershipTest` pins all of it: every inventory flag is named by at
least one module, the module list and the per-module counts match the scan, and the four
handler-only flags are named-but-undeclared. Change any of it and the test says which line
of this file to edit — the inventory block is read from this file, so it stays here, and the
table above is the doc twin of the test's `EXPECTED_OWNERSHIP` map.

### What a split has to pass

Two questions, in this order, and the second one is a veto rather than a preference.

**Is it a LAYER or a FAMILY?** A layer has a SMALL dependency surface and SEVERAL unrelated
callers: the boundary buys something, because the thing behind it can be asked for by name
from anywhere. A family is one closed region of a call graph with a single inbound edge that
takes the producer's whole bundle: the boundary buys SIZE, and a module that is one has to
say so in its own header rather than dress a size split as a responsibility. The test is
mechanical — count the inbound call sites, and count how much of the bundle the moved code
actually reads. Read a constructor's bundle assignments before proposing a seam: a layer
usually already has one (`_bodyPolicy`, `_ctorBlank`, `_arrowValueIf` and `_braceSym` were
bound closures handed to sibling modules before `WriterCtorPatternLowering` was named).

**Does it move a FORK half away from its twin?** Star emission forks across FOUR sites —
`StarFieldLowering.emitStarFieldSteps` and the `lowerStar*Branch` leaves beside it on the
parse side, `emitWriterStarField` (struct field) and `lowerEnumStar` (enum ctor) on the
writer side. Adding anything to Star emission means editing all four, so a split that puts
two of them in different modules with nothing naming the other half is REFUSED. What that
constraint does NOT forbid is taking a leaf or a sub-tree out from under ONE fork half, and
the discriminator is the call graph, not the topic: a region is admissible when none of its
members is reachable from the other half (`WriterStarPadLowering`, `WriterTriviaStarEmitLowering`).

**The module-level typedefs under `WriterLowering` stay where they are.** They look like a
block waiting for a home; measured, nearly every one has a single consumer and each is the
bundle `WriterLowering`'s constructor BUILDS and hands to one collaborator, so the declaration
sits at the producing end, and typedefs do not count toward the `oversized-type` line extent
(the reading is in the journal and `docs/decisions.md`).

⚠️ **The instrument that answers a typedef-deadness question is NOT `hxq uses` / `lit` /
`mentions`.** A type annotation on a PARAMETER or a LOCAL declaration is not projected into
the query tree at all (`probe 'function f(c: Mod.T) { final m: Mod.T = null; }'` gives
`(Required c)` and `(FinalStmt m …)` with no type child), so a type referenced only there is
invisible to all three, and a `uses`+`lit` census reports live typedefs as dead. For a
deadness question about a type, dump the sources and search the TEXT, or delete and build.

## The strategies

Every shipped strategy is annotate-only — `lower` returns `null` and `Lowering` reads the
slots the strategy wrote and emits the parser expression directly (the CoreIR shapes named
below describe what it emits; no `CoreIR` value is built — `architecture.md` § "Five-pass
macro pipeline") — so each subsection names what the strategy owns and where its slots are
consumed; the tag argument forms, the slot names and the compile-time refusals are each
class's own doc (`src/anyparse/macro/strategy/`).

### BaseShape

Not a strategy in the plugin sense — it is the pass 1 foundation that every strategy runs on top of. Handles the structural mapping from `haxe.macro.Type` to `ShapeTree`:

| Haxe form | ShapeTree form |
|---|---|
| `enum E { A; B; }` | `Alt(A, B)` |
| `class C { var f1; var f2; }` | `Seq(f1, f2)` |
| `typedef T = { f1, f2 }` | `Seq(f1, f2)` |
| `Array<T>` | `Star(T)` |
| `Null<T>` | `Opt(T)` |
| reference to another `@:peg`-type | `Ref(typeName)` |
| `abstract X(Base)` | `Terminal(Base)` — awaits further annotation |

### Lit

Owns: `@:lit`, `@:lead`, `@:trail`, `@:trailOpt`, `@:wrap`, `@:sep`, `@:sepAlt`.

Literal glue around fields, lowered into `Lit` nodes in a `Seq`: a field with `@:lead("{")` becomes `Seq([Lit("{"), field])`, a `@:sep(",")` on a `Star` becomes `Star(item, sep=Lit(","))`. Every tag's argument forms — `@:trailOpt` (optional on parse, canonical on write, source presence tracked in the `<field>TrailPresent` synth slot), `@:sep("…", tailRelax | sepFaithful)`, `@:sep("…", tailRelax, blockEnded)`, `@:sep("…", tailRelax, blockEnded('<predicate>'[, sepStartsElement]))`, `@:sepAlt` — and the `lit.*` slots each sets are the contract of `anyparse.macro.strategy.Lit`'s class doc. A `@:trailOpt` slot on a field carrying `@:fmt(dropSingleStmtBraces)` is never re-emitted; the reason is at the handler (`WriterRefFieldLowering`, `omega-ssb-trailopt-drop`).

`blockEnded('<predicate>')` names a predicate the Star primitive calls on the just-pushed element to decide separator elision by AST shape, over and above the byte check for `}` / `;`. For a format declaring `astPreds = true` (Haxe), the string names a GENERATED typed function on the per-family `AstPreds` / `AstPredsT` / `AstPredsS` marker classes (tables in `HxAstPredLowering`, machinery in `AstPredLowering`); other formats keep the legacy schema-instance channel — a method on the plugin's format-shaped class, reached through the same channel as `unescapeChar`. Both channels are wired by `Lowering.buildBlockEndedPredicateCall`; the same split applies to the `trailOptParseGate` writer/parser gates. The shape channel exists because the byte check cannot safely cover ident-terminated statements (`x is String`) or `]`-terminated ones (`[1, 2, 3]` — accepting `]` would silently accept `arr[0] foo()`).

### Re

Owns: `@:re`, `@:captureGroup`.

For an `abstract X(String) @:re("pattern")`, emits a `Re("pattern")` terminal. Used for regex-matched primitives: strings, numbers, identifiers, ASCII tokens. `@:captureGroup(n)` selects which group of the pattern becomes the value.

### Lexical

Owns: `@:lexical(<Kind>)`, `@:balanced(<open>, <close>)`. Reads `@:re`, `@:lead`, `@:trail`, `@:lit` and the format's `lineComment` / `blockComment`.

Not a strategy in the plugin sense — like `BaseShape` it is a PASS, run for the `Build.buildLexicalScan` entry point only (`LexicalLowering` then `LexicalCodegen`). It answers "which byte ranges of this source are NOT code" for the occurrence scans that must mask comments and literals before they rename or delete anything. That question is asked of RAW text, including text that does not parse, so it cannot be answered from a tree.

`@:lexical(<Kind>)` marks a rule as one such region and names the `anyparse.query.LexicalRegions.LexRegionKind` it carries — an unknown kind is a compile error listing the real ones. Two shapes are accepted, and nothing else:

- a `@:re` TERMINAL, whose pattern must be a delimited literal — `<open>(?:[^<excluded>]|<esc>.)*<close>[<flags>]*`. The pass reads the delimiters, the escape, the excluded set and the flag range out of the pattern rather than running it, because a regex cannot say where an UNTERMINATED literal ends and the scan must still report that region. A pattern of any other shape is a compile error naming the rule. Excluding `\n` from the body is what declares the region single-line: one that does not close on its own line then opens nothing, while one without that bound runs to EOF.
- a `@:lead` / `@:trail` rule over a Star of segment constructors — the interpolating string. The delimiters come off the Star's field; the body's escape, its skipped runs (`@:lit("$$")`, a bare `@:lead("$")`) and its code holes come off the segment constructors in declaration order.

`@:balanced("{", "}")` is the one thing no declaration expressed before this pass existed. On a segment constructor whose body is CODE — `@:lead("${") @:trail("}") Block(expr: HxExpr)` — it names the pair whose balancing ends the hole, and the walk re-enters the top-level region arms inside it so a quote or a comment written in the hole is read as one. Both arguments must be single characters. It is about an interpolation HOLE and nothing else — in particular it says nothing about a `#if ... #end` region, whose raw-capture decision belongs to the PARSER falling back to a ctor the macro derives into `GrammarPlugin.opaqueCondRegionKinds` from the grammar's `@:condRegionRaw` terminals and is not a bracket count at all (`architecture.md` § "A `#if` region the parser captured raw").

The emitted walk reports every region with the interpolation DEPTH it was found at, and the two public entries are filters over that one stream: `scan` keeps `depth == 0` (the flat region model says the whole literal), `scanComments` keeps the comment kinds at ANY depth (a comment inside a hole is one the writer's comment-loss guard must not drop). That deliberate disagreement is a declared policy of one pass, not two lexers, and `unit.LexicalRegionAgreementTest` pins it by name.

Nothing about a grammar survives as a literal in either module: every character the emitted code compares against arrives in a spec. `unit.minilex` is the standing proof — a second grammar spelling its line comment `#`, its block comment `<# … #>` and its string `@ … @`, whose generated pass finds those and not Haxe's (`unit.lowering.GeneratedLexicalScanSecondGrammarTest`).

### Kw

Owns: `@:kw`.

"Keyword with word boundary": `@:kw("class")` matches the literal and then asserts the next character is not a word character, so `class` does not match inside `classify`. The strategy fills `kw.leadText`; `Lowering` picks `expectKw` over `expectLit` wherever it reads a lead text.

### Skip

Owns: `@:skip`, `@:ws`.

Cross-cutting and annotate-only: `@:ws` on a rule root records `skip.active`, which nothing reads yet; the generated `skipWs(ctx)` — spaces, tabs, LF, CR and the BOM plus the format's comment delimiters, `Codegen.skipWsField`; the format's `whitespace` field is not consulted — is emitted before every terminal by the lowering whether or not the tag is present, so today the tag documents intent. `LoweringCtx.skipStack` is declared for a future scoped skip and is never pushed; the `@:skip("regex")` form with a user-provided pattern is owned but not read.

### Pratt, Prefix, Postfix, Ternary

Owns: `@:infix` (Pratt), `@:prefix` (Prefix), `@:postfix` (Postfix), `@:ternary` (Ternary).

Operator-precedence parsing for expression languages, split by operator shape into four annotate-only strategies that write `pratt.*` / `prefix.*` / `postfix.*` / `ternary.*` slots on the enum branches they own. `PrattPostfixLowering` reads them (`ParseDispatchLowering.branchShape` classifies a `prefix.op` branch first): the branches of a Pratt-enabled enum are split into atoms (every non-operator branch, routed through the ordinary Alt lowering as `parseXxxAtom`) and operators, and the rule becomes a precedence-climbing loop `parseXxx(ctx, ?minPrec)` whose operator dispatch is sorted longest-literal-first, so `<=` is tried before `<` whatever the declaration order. Prefix operators recurse into the atom function and so bind tighter than any infix; postfix operators loop inside the atom wrapper and bind tighter still; a ternary is merged into the infix dispatch chain and is right-associative by construction (its middle and right operands parse at `minPrec = 0`). What each branch shape must look like, and which forms are still refused at compile time, is each class's doc.

### Bin

Owns: `@:bin`, `@:magic`, `@:align`, `@:length`.

Binary format primitives: fixed-width ASCII strings and ASCII-encoded integers, a variable byte run whose length another field holds, a leading length prefix, a magic prefix on a typedef, alignment padding. Its `bin.*` slots are emitted by `StructSeqLowering` (parse) and `BinaryWriterLowering` (write); `CoreIR.BinKind` is the vocabulary those shapes are described in. Binary entries never call `skipWs` (`Codegen.skipWsField`'s own doc). `anyparse.format.binary.ArFormat` with the `ar` archive grammar under `anyparse.grammar.ar` is the shipped consumer.

### Planned: Capture, Indent, Recovery

None of these is registered today; each is a plugin waiting for its first grammar.

- **Capture** — `@:capture`, `@:match`: named captures for context-dependent grammars. `@:capture public var tag:XIdent` stores the matched text in a slot named after the field; `@:match(tag) public var _close:Void` asserts that the current position matches the same text. This is how XML matches `<a>...</a>`.
- **Indent** — `@:indent(same)`, `@:indent(block)`, `@:indent(gt)`, `@:indent(suspend)`: indent-sensitive grammars. Requires runtime state (`indentStack:Array<Int>`) contributed to the Parser context; `@:indent(block)` fields would be wrapped in `Host` nodes that push and pop the stack with `try/finally` semantics, and `@:indent(suspend)` freezes the stack within a scope — Python-style implicit line continuation inside `(...)` groups.
- **Recovery** — `@:commit`, `@:recover`: Tolerant mode only. On error after a `@:commit`, collect the error and advance to the nearest sync point declared by `@:recover(syncRe)`, then resume. Appears when Tolerant mode becomes a full target.

## Writing a new strategy

High-level procedure:

1. **Pick an owned metadata name**. Check `src/anyparse/macro/strategy/` for conflicts. Name should be short and specific to what it does.
2. **Pick dependencies**. If your strategy's slots are read where another strategy's are (e.g., `Kw` declares `runsBefore: ['Lit']` so the order is deterministic), declare `runsBefore` / `runsAfter`.
3. **Implement `appliesTo`**: check for your metadata on the node.
4. **Implement `annotate`**: write into namespaced slots. Do not lower yet.
5. **Implement `lower`**: produce `CoreIR`, or return `null` and let `Lowering` interpret your slots — which is what every shipped strategy does.
6. **Declare `runtimeContribution`**: if you need a field on the Parser context or a helper method, declare it. Strategies that do not need runtime state return empty arrays.
7. **Register it**: one `registry.register(new …)` line in `Build.registerStrategies`.
8. **Write tests**: a small `@:peg` type using your metadata, compile it, assert the generated code behaves correctly.

## Error cases the framework catches at registration

`StrategyRegistry.prepare` catches two, both as compile-time errors:

- Two strategies claiming the same `ownedMeta`.
- Cyclic `runsAfter`/`runsBefore` dependencies.

Two more were part of the original plan and are NOT checked — a strategy declaring `ctxFields` but no `cacheKeyContributors` (packrat integrity), and two strategies declaring a helper of the same name. No shipped strategy contributes runtime state, so neither has been needed; the line in `docs/decisions.md` records that.

## Why strategies are in the architecture

Without strategies, everything about grammar handling would live in one giant macro. Adding Pratt-style operators would mean editing the core. Adding indent sensitivity would mean editing the core again. Adding binary would mean editing the core a third time.

With strategies, each of these is a file in `strategies/`. The core macro pipeline is unchanged. Strategies are composed at registration, their order is deterministic, and conflicts fail fast.

This is the same reasoning as compiler passes in LLVM, lints in clippy, Babel plugins, Webpack loaders. It is the correct decomposition for extensible code transformation, and it applies here.
