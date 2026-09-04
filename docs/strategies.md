# Strategies

A **strategy** is a plugin that knows how to turn a piece of grammar into a piece of CoreIR. Strategies are the extensibility point of anyparse: adding a new parsing technique (new operator precedence scheme, new indentation semantics, new binary layout) means writing a new strategy, not modifying the core.

See `architecture.md` for the overall macro pipeline and how strategies fit into it.

## The interface

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

Strategies emit CoreIR. Codegen (pass 4) turns CoreIR into `haxe.macro.Expr`. A strategy that directly calls `macro ...` is wrong — it should be emitting CoreIR with `Host` as the escape hatch if nothing else works.

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
field, and `WriterLowering` — with `TriviaTypeSynth` and `Lowering` for the trivia and
span twins — decides what layout the flag lowers to. A flag nothing reads is silently
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
| `WriterLowering` | 199 |
| `TriviaTypeSynth` | 17 |
| `Lowering` | 16 |
| `WriterPolicyLowering` | 10 |
| `WriterCodegen` | 3 |
| `WriterBlankLowering` | 2 |
| `WriterLoweringSupport` | 2 |
| `TriviaSlotNames` | 1 |
| `WriterChainLowering` | 1 |

Read the shape of it, not just the numbers. `WriterLowering` answers 199 of 212 because
the writer lowering is organised by grammar SHAPE — Star, Ref, Terminal, Alt branch, Pratt
— and a flag is a branch INSIDE one of those emitters, not a unit of its own. A per-flag
module split is therefore not a code motion; it would mean rewriting the emitters, and the
thirteen flags that have left are the ones whose whole handler was a function.

**Four flags are handler-only** — `WriterLowering` names them, no shipped grammar declares
them, so they are absent from the inventory above: `blankLinesBeforeCtor`,
`blankLinesBeforeCtorIf`, `fill` and `fillDoubleIndent`. That is the plugin contract
working (a handler is available before a grammar asks for it), not dead code — but it is
the state that has to be visible, because the same reading covers a handler whose grammar
declaration was DELETED.

`unit.lowering.FmtFlagOwnershipTest` pins all of it: every inventory flag is named by at
least one module, the module list and the per-module counts match the scan, and the four
handler-only flags are named-but-undeclared. Change any of it and the test says which line
of this file to edit. That is how `clearBracePolicy` was found.

## Planned strategies

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

Owns: `@:lit`, `@:lead`, `@:trail`, `@:trailOpt`, `@:wrap`, `@:sep`.

Lowers literal glue around fields into `Lit` nodes in a `Seq`. A field with `@:lead("{")` becomes `Seq([Lit("{"), field])`. A `@:sep(",")` on a `Star` becomes `Star(item, sep=Lit(","))`.

`@:trailOpt(";")` is the optional-on-parse variant of `@:trail`. The parser emits `matchLit` (peek + consume-if-present) instead of `expectLit` (throws on absence); the writer keeps emitting the literal as canonical output. First consumer: `HxDecl.TypedefDecl` for `typedef Foo = T` without trailing `;`. Source-fidelity (preserve presence per input) came later as the `<field>TrailPresent` synth slot (`ω-struct-trailopt-source-track`), which the writer consults instead of always re-emitting.

Two fields opt OUT of that fidelity on purpose. A field carrying `@:fmt(dropSingleStmtBraces)` (`HxIfStmt.thenBody` / `elseBody`, `HxForStmt.body`, `HxWhileStmt.body`, `HxDoWhileStmt.body`) NEVER re-emits its trail literal (`omega-ssb-trailopt-drop`): a STATEMENT owns its own terminator — in `if (c) g();` the `;` sits inside the inner `ExprStmt` — so this slot can only ever hold a REDUNDANT `;` (`for (…) { x; };`). Canonicalising it away is what makes the `for (…) x;;` shape unreachable, so `SingleStmtBraces` no longer has to keep the braces to avoid it. Fidelity is the right default only where the optional token is a legitimate style choice; where it is provably meaningless, preserving it would let stray input degrade unrelated layout.

`@:sep(",", tailRelax)` is the opt-in two-arg form that makes "trailing sep before close is accepted" an explicit grammar contract. The bare ident `tailRelax` is the only recognised second arg. Semantically a no-op against current `Lowering.hx` behaviour — the close-peek Star loop already tolerates a trailing sep — but the annotation earmarks consumers for the BlockBody Star refactor (project memory `project_blockbody_star_tail_relax_debt`) and documents intent at the grammar site. First consumers: `JArray` / `JObject` in the JSON grammar.

`@:sep(";", tailRelax, blockEnded)` is the three-arg form that additionally turns on **block-ended exemption** — between two elements, the separator may be omitted when the prior element ended with `}` or `;` (parser-side byte-level check on `_prevEndPos - 1`). Writer side: `DocMeasure.endsWithCloseBrace` performs the equivalent check on each element's rendered Doc, suppressing sep emission when true. Combined with tail-relax this implements the trivia-mode part of the Haxe `BlockBody` separator policy. First consumer: the `MiniBlock` pilot grammar under `test/unit/miniblock/`. The ident must appear after `tailRelax` — `@:sep("text", blockEnded)` without tail-relax is rejected at compile time.

`@:sep(";", tailRelax, blockEnded("<predicate>"))` is the option (b2) AST-shape variant. In addition to the byte-check `}` / `;`, the Star primitive calls the named predicate on the just-pushed element (`<accum>[<accum>.length - 1]`) to decide sep-elision by AST shape. For a format declaring `astPreds = true` (Haxe), the string names a GENERATED typed function on the per-family `AstPreds` / `AstPredsT` / `AstPredsS` marker classes (tables in `HxAstPredLowering`, machinery in `AstPredLowering`); other formats keep the legacy schema-instance channel — a method on the plugin's HaxeFormat-shaped class, reached through the same channel as `unescapeChar` (the MiniBlock pilots' path). Required to cover ident-terminated stmts (e.g. `x is String` — `HxStatement.ExprStmt(Is)`) and `]`-terminated stmts (`[1, 2, 3]` — `HxStatement.ExprStmt(ArrayExpr)`) which the byte-check cannot cover safely (`]` would silently accept `arr[0] foo()`). Both channels are wired by the helper `Lowering.buildBlockEndedPredicateCall`; the same astPreds split applies to the `trailOptParseGate` writer/parser gates.

### Re

Owns: `@:re`.

For an `abstract X(String) @:re("pattern")`, emits a `Re("pattern")` terminal. Used for regex-matched primitives: strings, numbers, identifiers, ASCII tokens.

### Lexical

Owns: `@:lexical(<Kind>)`, `@:balanced(<open>, <close>)`. Reads `@:re`, `@:lead`, `@:trail`, `@:lit` and the format's `lineComment` / `blockComment`.

Not a strategy in the plugin sense — like `BaseShape` it is a PASS, run for the `Build.buildLexicalScan` entry point only (`LexicalLowering` then `LexicalCodegen`). It answers "which byte ranges of this source are NOT code" for the occurrence scans that must mask comments and literals before they rename or delete anything. That question is asked of RAW text, including text that does not parse, so it cannot be answered from a tree.

`@:lexical(<Kind>)` marks a rule as one such region and names the `anyparse.query.LexicalRegions.LexRegionKind` it carries — an unknown kind is a compile error listing the real ones. Two shapes are accepted, and nothing else:

- a `@:re` TERMINAL, whose pattern must be a delimited literal — `<open>(?:[^<excluded>]|<esc>.)*<close>[<flags>]*`. The pass reads the delimiters, the escape, the excluded set and the flag range out of the pattern rather than running it, because a regex cannot say where an UNTERMINATED literal ends and the scan must still report that region. A pattern of any other shape is a compile error naming the rule. Excluding `\n` from the body is what declares the region single-line: one that does not close on its own line then opens nothing, while one without that bound runs to EOF.
- a `@:lead` / `@:trail` rule over a Star of segment constructors — the interpolating string. The delimiters come off the Star's field; the body's escape, its skipped runs (`@:lit("$$")`, a bare `@:lead("$")`) and its code holes come off the segment constructors in declaration order.

`@:balanced("{", "}")` is the one thing no declaration expressed before this pass existed. On a segment constructor whose body is CODE — `@:lead("${") @:trail("}") Block(expr: HxExpr)` — it names the pair whose balancing ends the hole, and the walk re-enters the top-level region arms inside it so a quote or a comment written in the hole is read as one. Both arguments must be single characters.

The emitted walk reports every region with the interpolation DEPTH it was found at, and the two public entries are filters over that one stream: `scan` keeps `depth == 0` (the flat region model says the whole literal), `scanComments` keeps the comment kinds at ANY depth (a comment inside a hole is one the writer's comment-loss guard must not drop). That deliberate disagreement is a declared policy of one pass, not two lexers, and `unit.LexicalRegionAgreementTest` pins it by name.

Nothing about a grammar survives as a literal in either module: every character the emitted code compares against arrives in a spec. `unit.minilex` is the standing proof — a second grammar spelling its line comment `#`, its block comment `<# … #>` and its string `@ … @`, whose generated pass finds those and not Haxe's (`unit.lowering.GeneratedLexicalScanSecondGrammarTest`).

### Kw

Owns: `@:kw`.

Sugar for "keyword with word boundary". Lowers `@:kw("true")` to `Seq([Lit("true"), Not(Re("[A-Za-z0-9_]"))])`. Handles the common bug where `true` matches the start of `trueish`.

### Skip

Owns: `@:skip`, `@:ws`.

Cross-cutting. Does not lower nodes directly. Instead, pushes the active skip regex onto `LoweringCtx.skipStack` when entering a scope, and base lowering inserts `currentSkip` before each `Lit`/`Re` terminal in that scope.

`@:ws` is shorthand for `@:skip('[ \t\n\r]*')`.

### Capture

Owns: `@:capture`, `@:match`.

Implements named captures for context-dependent grammars. `@:capture public var tag:XIdent` stores the matched text in a slot named after the field. `@:match(tag) public var _close:Void` asserts that the current position matches the same text. This is how XML matches `<a>...</a>`.

### Pratt

Owns: `@:infix`, `@:prefix`, `@:op`.

When an enum has constructors with `@:infix(prec, assoc)` and `@:op("...")`, Pratt takes over lowering. It splits constructors into atoms (primary expressions) and operators (with priority tables). It emits a `Host` node containing a Pratt operator-precedence climbing loop, where `parsePrimary()` is generated from the atom constructors via the normal `Alt` strategy.

This is one of only two places where `Host` is used in the base library — because the Pratt loop is genuinely stateful and iterative in a way that does not fit cleanly into PEG combinators.

### Indent

Owns: `@:indent(same)`, `@:indent(block)`, `@:indent(gt)`, `@:indent(suspend)`.

Handles indent-sensitive grammars. Requires runtime state (`indentStack:Array<Int>`) contributed to the Parser context. Wraps `@:indent(block)` fields in `Host` nodes that push and pop the stack with `try/finally` semantics.

The `@:indent(suspend)` variant freezes the indent stack within a scope — needed for Python-style implicit line continuation inside `(...)` groups.

### Binary

Owns: `@:u8`, `@:u16le`, ..., `@:magic`, `@:tag`, `@:tagMask`, `@:fromTag`, `@:lenPrefix`, `@:countPrefix`, `@:count`, `@:decode`, `@:bytes`.

The biggest strategy by metadata count. Lowers binary format primitives into `Bin(BinKind)` nodes, `Switch` nodes for tagged unions, and `Count`/`BytesVar` for length-prefixed structures.

Interacts with `Skip` by overriding it to empty when entering a `@:bin` type (binary formats have no whitespace).

### Recovery (future)

Owns: `@:commit`, `@:recover`.

Activated only in Tolerant mode. Wraps relevant rules in error-recovery logic: on error after a `@:commit`, collects the error and advances to the nearest sync point declared by `@:recover(syncRe)`, then resumes parsing.

Not in Phase 1 or 2. Appears when Tolerant mode becomes a full target.

## Writing a new strategy

High-level procedure:

1. **Pick an owned metadata name**. Check `strategies/` for conflicts. Name should be short and specific to what it does.
2. **Pick dependencies**. If your strategy lowers to primitives that another strategy handles (e.g., `Kw` lowers to `Lit` + `Not`), declare `runsBefore` so you run first.
3. **Implement `appliesTo`**: check for your metadata on the node.
4. **Implement `annotate`**: write into namespaced slots. Do not lower yet.
5. **Implement `lower`**: produce `CoreIR`. If your strategy is purely annotation (like `Skip`), return null and let base lowering handle structural form.
6. **Declare `runtimeContribution`**: if you need a field on the Parser context or a helper method, declare it. Strategies that do not need runtime state return empty arrays.
7. **Register in the strategy registry**: one line in the strategies list.
8. **Write tests**: a small `@:peg` type using your metadata, compile it, assert the generated code behaves correctly.

## Error cases the framework catches at registration

- Two strategies claiming the same `ownedMeta`.
- Cyclic `runsAfter`/`runsBefore` dependencies.
- A strategy declaring `ctxFields` but no `cacheKeyContributors` (packrat integrity).
- A strategy declaring a helper with the same name as another strategy's helper.

These are all compile-time errors and prevent surprising runtime behavior from ambiguous composition.

## Why strategies are in the architecture

Without strategies, everything about grammar handling would live in one giant macro. Adding Pratt-style operators would mean editing the core. Adding indent sensitivity would mean editing the core again. Adding binary would mean editing the core a third time.

With strategies, each of these is a file in `strategies/`. The core macro pipeline is unchanged. Strategies are composed at registration, their order is deterministic, and conflicts fail fast.

This is the same reasoning as compiler passes in LLVM, lints in clippy, Babel plugins, Webpack loaders. It is the correct decomposition for extensible code transformation, and it applies here.
