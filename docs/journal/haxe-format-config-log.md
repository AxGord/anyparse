# hxformat.json journal

> **Journal, not contract.** Every number here is a reading of one tree at one moment; the
> contract lives in [`docs/haxe-format-config.md`](../haxe-format-config.md). Each block is the ORIGINAL text of a paragraph
> that the reference condensed or dropped, moved verbatim under the section it was written in
> (`From § …` names that section by its heading at the time), in the original order, so
> `git log -S` and the ledger's citations still resolve (the one edit: a link to a sibling doc
> gains `../`, and a same-file `#anchor` gains `../haxe-format-config.md`, since this file lives one
> directory down). A `§` pointer inside moved text names a heading of the reference
> (`docs/haxe-format-config.md`), not of this file. Nothing here is a norm, and nothing here is auto-loaded.

## From § (the preamble above the first heading)

The formatter reads the project's `hxformat.json` (discovered by walking up from each
file, `FormatConfigDiscovery`). The **keys** are the fork's; the **accepted values** are
not all of them, and three of the useful ones exist only here. Until this file, every
accepted string lived in exactly one place — the `switch` arms of
`anyparse.grammar.haxe.HaxeFormatValues` — so a config that named a value it does not know
was silently ignored and read as "the feature is not wired". That misreading produced
three separate false defect reports in one campaign; this page is the fix.

## From § `wrapping.<class>` — a cascade per delimited-list class

All four cuddle keys are **anyparse extensions** — the fork has no such concept
(`grep -i cuddl` over the whole fork returns nothing), so their shapes were derived
here, not copied. `ternaryCuddledBraces` lets a broken ternary's `:` and its else
branch's opening delimiter ride on the then branch's own closing line (`} : {`) instead of opening a
continuation line that would hold nothing but `: {`; the `?` gap is untouched. It
fires only when the then branch has a closing line to ride — a forced or
renderer-decided break whose closing brace lands at the indent of the line the
branch started on. A flat then branch has no closing line to ride, so a ternary whose
branches both fit is never rebuilt onto one line, and the else branch must itself open a
delimited body for the `} : {` shape to be legible at all. It also declines when the glue
would COST lines: gluing shifts the else right by the then branch's whole closing-line
closer run plus a space (two columns for a bare `}`, four for a `}))`), so an else that
fits its own separator line but not the line it would ride keeps the separator. That
width guard reads the ternary's REAL trailing width off the render stack — the `;` a
statement host adds, the `);` a glued call argument adds, nothing at all when the host
opened its own paren — so the band's edges move with the host instead of sitting on one
reserved column (`Doc.IfArrowContinuationFitsWithRest`). Within the two break shapes it
covers, only the `beforeLast` separator location is affected: the `afterLast` shapers
never read the flag. Default `false`.

`comprehensionCuddledOpen` governs a comprehension that is the SOLE item of its
brackets. The rule: `[ for (head)` is always cuddled, and the body stays on that head
line only while the whole comprehension renders flat — otherwise the body drops one
indent level and the closing bracket takes a line of its own at the `[` line's indent.
The knob therefore fires whenever the brackets did not fit on one line, and the only
question it asks is whether the head `[ for (…)` fits the line it is glued to; the
body is never consulted. An item that renders flat has its body FORCED one level down,
because its own fit group would keep the body on the head line whenever `[ head body`
fits and cannot see the closing bracket — leaving head and body packed on one line with
a lone `]` underneath, or (with a gate refusing that half-shape) a layout that jumps
between one line, the leading-break ladder and the cuddle as the line grows by a
column. A comprehension whose first break sits inside its HEAD rather than after the
generator's `)` is excluded — only a body-level break can deliver the shape the knob
promises. Default `false`.

## From § `wrapping.<class>` — a cascade per delimited-list class › `defaultWrap` / `rules[].type`

`ignore` is the one that answers "how do I get a canonical layout?": it is the **only**
mode that COLLAPSES a list the source broke — every other mode either preserves the source
form or only breaks a long one. Measured, `objectLiteral` with `defaultWrap: "ignore"` plus
an `itemCount >= n` rule: a source-broken `{x: 1, y: 2}` collapses to one line, and a
source-flat three-item literal breaks one-per-line. The fork's `WrappingType` has no
`ignore`, so no corpus fixture selects it — which is exactly why it went unnoticed.

## From § `wrapping.<class>` — a cascade per delimited-list class › `rules[].conditions[].cond`

Two gates in that pair are not decoration. `itemCount >= 2` keeps a lone callback glued —
without it `api.load(profile -> { … })` puts its own single argument on a separate line one
indent deeper. And the multi-line half MUST be the lambda-specific condition: written as the
plain `hasMultilineItems` it also fires when the multi-line element is the COLLECTION, which
sends `new Row([` … `], w, h)` one-argument-per-line and takes the bracket off the head —
measured over one real tree, that spelling changed 65 files where the correct one changes 13.
There is no `containerItemCount >= n` — no cascade has needed to count them.

## From § `sameLine.*` — the full key list (33 keys)

`HxFormatSameLineSection` (`src/anyparse/grammar/haxe/format/HxFormatSameLineSection.hx`)
declares 33 `sameLine.*` fields. Before this section the file you are reading named 9 of
them with a real default/values write-up (10 if a passing mention counts — `grep -oE
'sameLine\.[A-Za-z]+' docs/haxe-format-config.md` returns 10 distinct names, but
`doWhileBody` was only named in passing inside the `loopBodyIfElseNext` do-while
subsection, never documented on its own); the other 24 lived only in
`HxFormatSameLineSection`'s doc-comment, which is where its own doc points a reader who
hits a key that "does nothing". The table below is sourced from that doc-comment, from
`HxModuleWriteOptions`'s own (more detailed, per-field) doc-comment, and from the actual
default values in `HaxeFormat.defaultWriteOptions` — and every key is cross-checked
against `HaxeFormatConfigLoader.applySameLine` / `applySameLineBodies` /
`applyExpressionIfFanout`: all 33 are read unconditionally (`if (section.<key> != null)
opt.<key> = …`), so none of the 33 is a dead field the loader silently drops.

| Key | Kind | Default | Governs |
|---|---|---|---|
| `ifElse` | same/next/keep | `same` | `else` placement after a statement-`if`'s closing `}` |
| `tryCatch` | same/next/keep | `same` | `catch` placement after a `try` block's `}` |
| `doWhile` | same/next/keep | `same` | closing `while (…)` placement after a `do … while` body's `}` |
| `expressionTry` | same/next/keep | `same` | separator between an expression-position `try`'s body and each `catch` (`var x = try foo() catch (_:Any) null;`); independent of `tryCatch`, which is the statement form |
| `ifBody` | same/next/fitLine/keep | `keep` (bare) / `next` (any config loaded) | statement-`if` then-body placement (non-block bodies only); re-baselined, see the note above the table |
| `elseBody` | same/next/fitLine/keep | `keep` (bare) / `next` (any config loaded) | statement-`if` else-body placement (a non-`if` else; `elseIf` governs a nested `if`, `elseSwitch` a nested `switch`); re-baselined |
| `forBody` | same/next/fitLine/keep | `keep` (bare) / `next` (any config loaded) | statement-`for` body placement; re-baselined |
| `whileBody` | same/next/fitLine/keep | `keep` (bare) / `next` (any config loaded) | statement-`while` body placement; re-baselined |
| `doWhileBody` | same/next/fitLine/keep | `keep` (bare) / `next` (any config loaded) | `do <body> while (…);` body placement (maps to the runtime `doBody` field); re-baselined |
| `returnBody` | same/next/fitLine/keep | `fitLine` | separator between `return` and its value |
| `returnBodySingleLine` | same/next/fitLine/keep | `fitLine` | refines `returnBody` for return values that are NOT a control-flow/block construct (`if`/`for`/`while`/`switch`/`try`/`{…}` keep using `returnBody`) — wired via `@:fmt(bodyPolicySingleLine('returnBodySingleLine', …))` on `HxStatement.ReturnStmt`, confirmed live in the grammar. `HxFormatSameLineSection`'s doc-comment on `returnBody` used to call this knob "parsed and silently dropped"; fixed in source (T160) |
| `catchBody` | same/next/fitLine/keep | `next` | separator between a `catch (name:Type)` header's `)` and its body |
| `tryBody` | same/next/fitLine/keep | `next` | separator between `try` and its body (`HxTryCatchStmt.body`), orthogonal to `whitespace.tryPolicy` (the `try{` vs `try {` inline gap); NOT re-baselined (outside the `ω-D6`/`ω-D7` block), so `next` holds whether or not a config is loaded, unless a project's own `hxformat.json` sets `"tryBody": "same"` as an explicit override — the AxGord fork's does, which is what the field's doc-comment used to describe as the compiled default; fixed in source (T160) |
| `caseBody` | same/next/fitLine/keep | `keep` (bare) / `next` (any config loaded) | statement-switch single-stmt case-body placement (`HxCaseBranch.body` / `HxDefaultBranch.stmts`); `fitLine` measures the whole `case <patterns>: <body>` against `lineWidth`; re-baselined, see the note above the table — its own field doc-comment already states the `next` reading and was not stale |
| `expressionCase` | same/next/fitLine/keep | `keep` | same shape, selected instead of `caseBody` for an expression-position switch (`var x = switch … { case Y: 1; }`) — dispatch is on `opt._inExprPosition`, not an OR of the two keys (see the position trap below) |
| `functionBody` | same/next/fitLine/keep | `next` | separator between a function declaration's `()` and a single-expression body (`function f() trace("hi");`); `BlockBody` and the `;`-only `NoBody` are unaffected |
| `anonFunctionBody` | same/next/fitLine/keep | `same` | expression-position sibling of `functionBody`, for `HxFnExpr.body`'s `ExprBody` branch (e.g. `function() trace(i)`) |
| `untypedBody` | same/next/fitLine/keep | `same` | parent→`untyped` separator at `HxFnBody.UntypedBlockBody` (`function f():T untyped { … }`); the statement form `HxStatement.UntypedBlockStmt` (incl. `try untyped { … }`) deliberately does not read this knob — stacking it with parent body-policy / block-stmt separators would double a gap |
| `expressionIf` | same/next/fitLine/keep | n/a — no single default, see Governs | body placement for the expression-position counterparts of `if`/`for` (array comprehensions and any value-position `if`/`for`). One JSON key fans into three runtime knobs (`expressionIfBody` / `expressionElseBody` / `expressionForBody`); ABSENT, each of the three keeps its OWN compiled default — `same` / `same` / `keep`, not a uniform value (not re-baselined the way `ifBody`'s sextet is — `expressionIfBody`/`expressionElseBody`/`expressionForBody` are outside the `ω-D6`/`ω-D7` block). PRESENT, `keep`/`same` propagate to all three; `next`/`fitLine` propagate only to the if/else pair, never to `expressionForBody` (a `for` has no `else` sibling, so the arrow-body/comprehension-filter fallback that `next`/`fitLine` would otherwise break stays intact) — `comprehensionFor` is the way to set the `for` case specifically, and it is read AFTER this fanout so it always wins |
| `comprehensionFor` | same/next/fitLine/keep | absent → `keep` | the SPECIFIC override of `expressionForBody`, read after the `expressionIf` fanout — see its own section below |
| `elseIf` | same/next | `same` | keyword placement for a nested `if` inside an `else` (`else if (…)` inline vs. `else` alone then `if` one indent deeper); overrides `elseBody` for the `IfStmt` ctor |
| `elseSwitch` | same/next/keep | `keep` | keyword placement for a nested `switch` inside an `else`, the `elseIf` twin for the other keyword-headed branch — see "The three keys S67 added" below |
| `fitLineIfWithElse` | bool | `false` | when `false`, an `ifBody`/`elseBody` of `fitLine` degrades to `next` for an `if` that carries an `else` (fitting one branch and breaking the other reads as inconsistent); `true` keeps `fitLine` unconditionally |
| `fitLineBodyGlue` | bool | `false` | when a `fitLine` construct body (`if`/`for`/`while`) does not fit the header line AND the next line would not rescue it either (its flat width still exceeds the continuation indent), stay glued to the header and break inside the body instead of moving down a line and an indent step; also reaches an arrow-lambda body that is itself a parenthesised expression. Neither this knob nor `fitLine` itself decides whether a body parked inside a LAMBDA item is counted in the enclosing line's width — that is a separate mechanism, see "A `fitLine` body parked inside a lambda item" below |
| `loopBodyIfElseNext` | bool | `false` | see the dedicated section below (S159's paragraph, left as-is by this slice) |
| `conditionalExprFit` | bool | `false` | break an expression-scope `#if … #end` region at its directive seams, the way an `if`/`else if`/`else` chain breaks, when the glued form does not fit the line; off (default) keeps the layout purely source-driven |
| `ifElseSemicolonNextLine` | bool | **`true`** | when the statement-`if` then-branch is a bare (non-block) statement ending in `;` and the branch carries an `else`, put that `else` on the next line instead of gluing it after the `;` (`if (c) foo();` / `else bar();` rather than `if (c) foo(); else bar();`). Undocumented in any doc-comment in either source file (no class-level mention, no field-level `/**…*/`); this description is derived from its one consumer, `WriterFieldSepLowering.hx` (the `@:fmt(semicolonNextLineElse)` flag on `HxIfStmt.elseBody`). Trivia-mode only: the plain (Fast) writer canonicalises `;` presence, so this knob is inert there and the flag-based separator is used instead; it also never fires in expression position (`opt._inExprPosition`), which is `sameLineExpressionElse`'s job. Note the default is `true`, unlike every other bare-Bool `sameLine` knob in this table, which default `false` |
| `expressionIfWithBlocks` | bool | `false` | collapses a `BlockExpr` branch body's CONTENTS onto one line regardless of width (`{ … }` survives, its interior flattens); glues nothing and never moves `else` — see the closing paragraph of the `expressionIfWithBrackets` section below for the distinction |
| `expressionIfWithBrackets` | bool | `false` | see the dedicated section below |
| `expressionIfArrowBodyReflow` | bool | `false` | when `true`, a value-`if`/`else` chain that is the direct body of an arrow lambda becomes one width-decided unit — flat when it fits, one branch per line (each value glued to its own condition) when it does not — instead of each branch following the `expressionIf` policy independently. Reach extends slightly beyond the immediate arrow body: a `cast(…, T)` operand, an `untyped`/`@:meta` prefix, and an enclosing value-`if`'s condition also re-flow. A comment anywhere on the chain's `else`-spine refuses the reflow whole |
| `expressionIfFit` | bool | `false` | the non-arrow sibling of `expressionIfArrowBodyReflow`: fit-decides EVERY value-`if`/`else if` chain (initializer, `return`, call argument, …), not only one in an arrow body — flat on one line when it fits, otherwise the exact `expressionIfBody`/`expressionElseBody` layout. An arrow body under both knobs keeps the arrow-specific shape (that gate is checked first) |
| `expressionIfFitMaxBranches` | int | `0` (no cap) | largest number of value branches an `expressionIfFit` chain may hold and still collapse onto one line (`if (c) a else b` is 2, `if (c) a else if (d) b else e` is 3); a chain over the cap keeps the exact policy layout. Inert while `expressionIfFit` is off |
| `elseIfCommentReflow` | bool | `false` | when `true`, an `else if` whose nested `if` carries exactly one interposed `//` line comment glues as usual (`} else if (b) {`) and re-emits that comment at the end of the nested `if`'s head line, instead of forcing the three-line layout (`else` alone, comment one indent deeper, `if` back at the outer indent). Refuses (layout unchanged) for a block comment, more than one comment, a comment cuddled to `else` itself, a nested `if` head that already carries its own trailing `//`, an empty then-body, or any body shape offering no provable head-line anchor. Statement position only (`HxIfStmt.elseBody`); `elseBody: "keep"` also disables it |

**Unlike the `wrapping.*` cascades, a `sameLine.*` value must be spelled in the exact
lowercase-camelCase the schema declares — `"Same"` / `"FitLine"` / `"Keep"` are each a
DIFFERENT string from `"same"` / `"fitLine"` / `"keep"` to Haxe's enum-abstract-from-string
equality, so a capitalised spelling here is not silently ignored, it is a hard parse
failure: `apq fmt` exits 1 with `invalid HxFormat<…>Policy value: "Same"` and leaves the
file unformatted** (measured: `sameLine.ifElse`, `sameLine.ifBody` and `sameLine.elseIf`
all reject `"Same"` this way — every `sameLine.*` value type does, since all three enum
abstracts behind it declare only the lowercase spellings). This is the opposite of the
`wrapping.*` cascades' `defaultWrap`/`rules[].type`, which DO also accept a capitalised
spelling (`OnePerLine`, `FillLine`, …) — a different vocabulary with its own reader.

## From § A `fitLine` body parked inside a lambda item IS counted in the line width

Until S183 only the first gate existed, and the asymmetry was measurable at one variable.
Under `maxLineLength: 140` with `ifBody: fitLine`, at the same site, statement at two tabs:

```haxe
// 141 columns — the arrow gate reveals the body's width, so this breaks correctly
if (s != orig[k]) table.where(client == $key && key == $k).update(['value' => (s: DBV)], (r) -> if (!r) throw 'Cannot save storage');

// 146 columns — a FIXED POINT before S183: re-emitted unchanged, over the limit
if (s != orig[k]) table.where(client == $key && key == $k).update(['value' => (s: DBV)], function(r) if (!r) throw 'Cannot save storage');
```

The overflow was unbounded, not a threshold effect: the same shape with a 260-character
body sat at 420 columns and still moved nothing. With the width visible it breaks at every
point the construct owns — the statement body first (`ifBody: fitLine`), then `methodChain`,
then the call parens — and only an unbreakable string literal can still exceed the limit.

**The two gates coincide only for a plain `if` body.** The `function` gate accepts any
hardline-free body; `isArrowPlainIfBody` still demands `if` with no top-level `else`. So for
a `for` / `while` / `switch` / `if`-`else` body the `function` spelling now measures and the
ARROW spelling does not — measured under Pony's own `hxformat.json`, where
`function(r) for (q in r) f(q)` as the last argument went from a 149-column line to a correct
break while `(r) -> for (q in r) f(q)` is byte-identical before and after. That residual is
open (T875); closing it means one spelling-agnostic "does this item park a hardline-free
`BodyGroup`?" predicate, which also has to be weighed against the landed thin-arrow if-else
path `isArrowPlainIfBody`'s `else` clause protects.

## From § The three keys S67 added, and the position trap each of them has

**`sameLine.elseSwitch: "same" | "next" | "keep"`** — keyword placement for a `switch`
BRANCH of an `if`, the twin of `sameLine.elseIf` for the other keyword-headed statement a
branch idiomatically carries. `"same"` glues it (`if (c) switch s { … } else switch s { … }`),
`"next"` puts it on its own line, `"keep"` (the DEFAULT) has no opinion and lets the field's
`ifBody` / `elseBody` (`expressionIfBody` / `expressionElseBody`) policy decide. The default
differs from `elseIf`'s (`Same`) on purpose: this key is new and must leave every existing
config's bytes alone. It reaches BOTH the statement `if` and the value `if`, and BOTH branches
of each — S138 armed the then-branch after the user reported the two halves of one `if`/`else`
coming back laid out differently, and stated the rule as SYMMETRY. A glued then-`switch` also
closes in its head's own column, so the `else` cuddles that `}` the way it already cuddles a
block's — two seams, not one, and the second is why `if (c) switch … }` + newline + `else` was
never the right half-way answer. One refusal, on either branch: a comment written between the keyword and the `switch`
declines the glue — both seams — and the source layout is kept byte for byte, because the glued
layout has no channel for that comment.

## From § `sameLine.comprehensionFor` — a body policy, plus one bracket side effect

**`sameLine.comprehensionFor: "same" | "next" | "fitLine" | "keep"`** places the BODY of an
expression-position `for` — the array-comprehension generator (`[for (x in xs) <body>]`) and any
value-position `for`. It reaches `HxForExpr.body` / `HxForReif.body` through the same
`@:fmt(bodyPolicy('expressionForBody'))` knob `sameLine.expressionIf` fans out into, and is read
AFTER that fanout, so the specific key outranks the general one: `expressionIf: "same"` with
`comprehensionFor: "next"` breaks the comprehension body and nothing else.

The four values are the engine's own `BodyPolicy`, so they mean here exactly what they mean on
`forBody` / `ifBody`: `same` on the head's line, `next` on its own line one level in, `keep`
reproduces the source break, and `fitLine` glues a body whose first line fits the head line and
breaks one whose does not.

Until 2026-09-04 the key did nothing BUT the padding: `same` / `next` / `fitLine` / `keep` produced
byte-identical output for every input, so no config value could move a comprehension body.

## From § `sameLine.loopBodyIfElseNext` — the one loop body whose `else` has nothing to pair with

**`sameLine.loopBodyIfElseNext: true | false`** (default `false`) breaks a `for` / `while` /
`do … while` header away from a body that is an `if` carrying an `else`, putting the whole
`if`/`else` on the next line one indent step in. A `Bool`, like its nine `sameLine` neighbours
(`fitLineIfWithElse`, `fitLineBodyGlue`, `expressionIfWithBlocks`, `expressionIfFit`,
`expressionIfWithBrackets`, `expressionIfArrowBodyReflow`, `ifElseSemicolonNextLine`,
`conditionalExprFit`, `elseIfCommentReflow`) — it does not pick a placement, it withdraws ONE shape
from the placement `forBody` / `whileBody` / `doWhileBody` already decided.

It reaches EVERY placement, because it is a substitution on the placement VALUE rather than on one
layout: for this one body shape the writer reads `next` where the config said `fitLine`, `same` or
`keep`, before any layout is chosen. Measured on the reported site, one variable at a time:

S157 shipped the key gated on the `FitLine` LAYOUT, so the `same` and `keep` rows of this table both
read "glued / glued": a config on either had the reported defect and no way to decline the key that
was documented for it. S159 moved the gate onto the policy value (`WriterBodyPolicyLowering.`
`buildBodyCoreWrap`, one ternary over `BodyPolicy.Next`) and wired `HxDoWhileStmt.body` as well.

Reported site (`src/pony/unity3d/UTools.hx`), off — the `}` and the `else` sit at the LOOP's
indent, so the `else` reads as a branch of the `for`:

## From § `sameLine.loopBodyIfElseNext` — the one loop body whose `else` has nothing to pair with › What counts as a "branching body", and what does not

The predicate is exactly `LoopBodyShape.isIfWithElse`: the body's ctor is `IfStmt` AND its
`elseBody` field is non-null. Nothing else. (`do … while` needs one unwrap first — its body is an
`HxDoWhileBody`, so the same `if` arrives as `ExprBody(IfExpr(…))` and the field is `elseBranch`.)
Two neighbouring shapes look like they belong and do not, measured over one real 872-file tree
(all six source roots):

- **An `if` with NO `else` — 64 further files.** This is the deliberate `for (x in xs) if (c) …`
  guard idiom, and the whole reason the gate reads the body's shape instead of being a body policy:
  `forBody: "next"` moves the guard idiom under the header too. Nothing here is dangling — the
  header line's own `{`, or its single statement, is what the reader pairs with.
- **A `switch` body — 19 files.** `for (e in data) switch e {` … `}` has no keyword outside the
  braces: the `}` at the loop's indent closes the `{` on the header line, which is the same visual
  contract the guard idiom has. The defect this key exists for is a SECOND keyword (`else`)
  appearing at the loop's indent with nothing on the header line to pair it with, and a `switch`
  body never produces one.

That asymmetry is why the key is named for its predicate rather than for the broader
"branching body": the wider name would promise coverage the predicate does not have, over 19 sites
whose glued form the reporter's own layout rule endorses.

## From § `sameLine.loopBodyIfElseNext` — the one loop body whose `else` has nothing to pair with › `do … while`

The population is 0 in both configs measured here (no `hxformat.json` in either tree sets
`doWhileBody` at all), so this arm of the key is carried by pins rather than by a corpus.

## From § `sameLine.expressionIfWithBrackets` — one knob, three seams, and they have to agree

It owns THREE seams, not one: the body placement (the `[` comes up to the head), the branch's
optional `;` (dropped before an `else`, because `];` cannot cuddle) and the pre-`else` gap (a plain
space, so the `else` reaches the `]`). Two of them read the flag alone; until S154 the OPEN seam was
folded one level deeper, into the layout policy INSIDE `WriterBodyPolicyLowering.buildBodyCoreWrap`'s
`Keep` switch — so under `sameLine.expressionIf: "keep"` the knob dropped the `;`, pulled `else` up to
the `]`, and left the `[` on a line of its own. Half a shape, and the half the knob exists to prevent:

```haxe
// pre-S154, `expressionIf: "keep"` + `expressionIfWithBrackets: true`
return if (c)
	[
		oneLongElementName,
		anotherLongElementName
	] else
	[];
```

S154 moved the substitution onto the policy VALUE, the seam S159 took for `loopBodyIfElseNext`, so
every placement consults the knob before a layout is chosen. Measured on one broken source (`[` on
its own line, `];`, `else` on the next), one variable at a time:

| `expressionIf` | knob off (or absent) | knob on, pre-S154 | knob on, S154 |
|---|---|---|---|
| `same` | source shape | **hugged + cuddled** | hugged + cuddled |
| `next` | source shape | **hugged + cuddled** | hugged + cuddled |
| `keep` | source shape (preserved whole) | `] else` only, `[` left behind | **hugged + cuddled** |

`keep` decides the LAYOUT POLICY — it never decides whether an explicit knob applies; with the knob
absent it still preserves the source whole, which is the vacuity guard in
`unit.grammar.haxe.HxValueIfBracketHugSliceTest`. The `same` row is what proves the defect was the
placement and not the knob: the identical source already reached the target bytes there.

The curly twin is a different question and needs no key. `sameLine.expressionIfWithBlocks` collapses
a block body's CONTENTS and glues nothing; the `} else {` shape comes from `sameLine.expressionIf`
itself, whose `next` resolves the pre-`else` gap to `SameOnBlock` (S100). So a value-`if` with block
branches hugs its head and cuddles its `else` under `same` and `next` with or without
`expressionIfWithBlocks` — measured on the same broken source in both trees' configs.

## Reading: where the haxe-formatter fork and `hxq fmt` disagree on three trees (FX-REMEASURE, 2026-11-07)

Successor of the first census (FX-0, 2026-10-22). One reading of one moment: anyparse main `5981140d0`, the newest fork branch
(`fx/type-doc-emptylines`, tip `d3df79a`, built from a detached worktree of the fork, its checked-out tree and the haxelib path
untouched). The trees are COPIES of the `.hx` files, each with its own `hxformat.json`: this repo (`src test tools`, 3177 files /
731 k lines), Pony (`src tools tests socketTests install docgen`, working tree, 872 / 72 k) and the client tree (`src`, 936 / 132 k).
Both tools format the same input in place; a second pass of each measures idempotence. A hunk is a maximal run of differing lines
(runs closer than four lines are merged); "h/f" = hunks / files. The harness (copy, two passes, hunk merge, class predicates) was scratch code and is not kept, the census is reproducible from
the method in this paragraph. Examples of the class table were reduced from a hunk and run on a tree's own config, each tool on
the same snippet; the tree is the one whose cell is largest in the row (row 9: the client tree, the only config under which the
example reproduces; rows 8, 14 and 15: the anyparse tree; row 13: the client tree), the per-example tree was not recorded.
Classes 11, 18, 19, row 12 (its examples are the config gaps above) and the three long-tail rows are **counted by predicate, no
repro**: their counts say how many hunks match the predicate, not that one mechanism was isolated.

| tree | fork rewrote | hxq rewrote | **fork ≠ hxq** | fork 2nd pass changes | hxq 2nd pass changes |
|---|---:|---:|---:|---:|---:|
| anyparse | 1249 f | 0 | **1249 f / 27 871 l** | 109 f / 921 l | 0 |
| Pony | 277 f (+1 crash) | 49 f (+3 not parsed) | **280 f / 6 380 l** | 7 f / 80 l | 0 |
| client tree | 291 f | 7 f | **293 f / 7 791 l** | 2 f / 8 l | 0 |

FX-0 had 1459 / 347 / 824 files (19 205 / 5 929 / 68 850 lines). In FILES the client tree fell 824 → 293 (F1 config reading, F2
type-body blanks), anyparse and Pony fell less (1459 → 1249, 347 → 280). In LINES only the client tree fell (68 850 → 7 791);
anyparse rose 19 205 → 27 871 and Pony 5 929 → 6 380, and the anyparse tree itself grew from 2279 to 3177 files (632 k → 731 k
lines; Pony 872 → 872 files, 72 k lines; client tree 906 → 936 files, 125 k → 132 k), so for anyparse and Pony this reading
is not a convergence.
Config reading is no longer the dominant source: the fork warns (with `-v`) on a key it does not know and accepts the other
hxq-only keys as "ignored". Closing the config gaps below (`ternaryMultilineBranch` everywhere, `opBoolChain` in anyparse, the two
space keys in Pony) leaves **1209 / 265 / 292 files** and 23 721 / 6 031 / 7 709 lines; the rest is layout.

### CONFIG GAPS (an unset key falls back to each tool's own default; checked by filling every key the fork's default config has and the tree lacks, then one key at a time)

Filling all unset keys with the fork's defaults moves the difference by 17 / 2 / 0 files, so gaps are small; the ones that move it:

| gap | trees | effect | example |
|---|---|---|---|
| `wrapping.ternaryMultilineBranch` unset: fork default `inline`, hxq default breaks; pin `"break"` (the fork has it) | all three | −2 437 / −78 / −82 lines | `return c == null ? null : switch f(c) {⏎case A: x;⏎case _: null;⏎};` fork keeps it on one head line, hxq puts `? null` and `: switch` on their own lines |
| `wrapping.opBoolChain` unset: the fork wraps a condition by `conditionWrapping` (fill), hxq falls back to one operand per line | anyparse | −1 713 l / 24 f (354 h) | `if (a == null \|\| b == null \|\| … six operands …)` fork fills two per line, hxq one per line; with the client tree's `opBoolChain` pinned both fill |
| `whitespace.colonPolicy` unset (catch parameter `catch (e:T)`: tokentree gives the fork `colonPolicy`, hxq reads `typeHintColonPolicy`) | Pony | 83 h / 45 f | `catch (e:Dynamic)` vs `catch (e: Dynamic)`; FX-0 K7, still open |
| `whitespace.bracketConfig.comprehensionBrackets.openingPolicy: onlyAfter` | Pony | 36 h / 23 f | `return [for (k in keys) k];` fork `return[ for (k in keys) k ];`, hxq `return [ for … ]`; FX-0 K6, still open: delete the key |
| `emptyLines.externClassEmptyLines` unset | Pony | 2 f / 4 l | |

Not a gap although the key is unset in the anyparse config: `arrayWrap`, `anonType`, `objectLiteral`. hxq's default for an unset
list class is to keep the source layout (flat stays flat, broken stays broken: a `for (k in [a, b]) …` stays flat or broken as written),
so `hxq(fork(x))` differs from `hxq(x)` in 351 / 73 / 15 files, mostly blanks plus about 340 h of array / object / hugged-argument
layout in anyparse. With the key set (Pony, client tree) hxq collapses both shapes. That is CANON-3 territory, not a config gap.

### hxq-only keys the fork reads and ignores (cannot converge by config; deleting the key from the hxq side is the measure)

| key | effect of deleting it | trees using it |
|---|---|---|
| `sameLine.caseSiblings: anyBreak` (the fork lists it as unknown) | −913 l Pony, −610 l client tree | Pony, client |
| `whitespace.bracesConfig.singleStatementBraces`: `remove` in Pony and the client tree, `symmetric` in anyparse | −328 l / 12 f Pony; not measured on the others | all three |
| `sameLine.loopBodyIfElseNext` | −109 l | Pony |
| `wrapping.methodChain.itemsAfterCloseParenOnly` | −476 l | anyparse |
| `wrapping.comprehensionCuddledOpen`, `soleItemCuddledBrackets`, `methodChainCuddledLinks`, `sameLine.expressionIfFitMaxBranches`, `fitLineBodyGlue`, `expressionIfArrowBodyReflow` | ±20…140 l each | Pony / client |

Not an ignored key: `<kind>EmptyLines.beginTypeIfDocComments` / `endTypeIfDocComments` — the fork now follows it, and deleting it
from the hxq side WIDENS the gap (+448 l).

### Divergence classes on the reading with `ternaryMultilineBranch` pinned

Hunks / files per tree: anyparse 4285 h / 1233 f, Pony 821 / 280, client tree 886 / 292. Verdict: **A** anyparse defect, **F** fork
defect or outdated, **G** config gap, **T** taste call (a question below), **K** hxq-only key the fork ignores. Cells are
anyparse | Pony | client tree; a hunk is counted once, in its first matching class (rules in the order of the table), so the rows
add up to the totals together with the three long-tail lines.

| # | class | verdict | h (f) anyparse | h (f) Pony | h (f) client | minimal example |
|---|---|---|---|---|---|---|
| 1 | `case` bodies: hxq moves every body of a switch onto its own line once one sibling does not fit; the fork decides per case | K, T1 | 3 (3) | 161 (73) | 110 (66) | `case A: foo();` beside an over-long `case B: x.y(…);` → hxq `case A:⏎foo();`, fork keeps `case A: foo();` and wraps B's call |
| 2 | fork breaks a fitting object literal: nested in an outer literal broken one per line, or as the last argument of a chain head | F | 73 (58) | 100 (40) | 60 (41) | `new W({ a: 1, …long…, nested: { x: true, y: false } })` → fork `nested: {⏎x: true,⏎y: false⏎}`; `f(a, b, { x: 0, alpha: 1 }).ease(e).onUpdate(u).onComplete(c);` over 140 → fork `{⏎x: 0, alpha: 1⏎})` |
| 3 | fork breaks a fitting array (a trailing `[x]` of a ternary inside a long argument list) or the parens of a fitting call argument | F | 17 (16) | 4 (3) | 86 (58) | `super(c ? (d ? [a, b] : [b, a]) : [x], w,⏎h, …)` → fork `: [⏎x⏎], w,`, hxq `: [x], w, h,` filled |
| 4 | closing `}` / `})` glued to the tail of a wrapped `+` chain (the continuation is left unindented); and the reverse, `}` of an anon type in a return type broken onto its own line with the function's closing brace mis-indented | F | 340 (143) | 0 | 1 (1) | `out.push({ …, message: 'a'⏎+ 'b' });` → hxq `+ 'b'⏎});`; `): Null<{ span: Span, text: String }> {` after a wrapped parameter list → fork `text: String⏎}> {` and `}` of the body one tab deeper |
| 5 | `&&` / `||` chains: hxq one operand per line (default of the unset `opBoolChain`), the fork fills by `conditionWrapping`; 153 of the hunks are the other direction (the fork breaks, hxq does not) | G | 354 (222) | 0 | 2 (2) | six operands in an `if (…)`: fork two per line, hxq one per line (with the client tree's `opBoolChain` pinned both fill) |
| 6 | method chain: hxq cuddles the head call (`Type.make(x)⏎.a()⏎.b()`), the fork breaks before the first `.` | K (`itemsAfterCloseParenOnly`) | 138 (110) | 0 | 9 (4) | `return Holder.Master.create(first.name).second(a)…tenth(g);` over 140 → fork `Holder.Master⏎.create(first.name)⏎.second(a)` |
| 7 | call arguments: hxq one per line when an argument is a container, the fork honours `fillLineWithLeadingBreak`; and the hug of a sole array argument the other way round | T2 | 442 (199) | 43 (35) | 80 (45) | `ParenGuard.guard(source, [{ span: s, text: t, holes: h }], plugin)` → fork `(⏎source, [{…}], plugin⏎)`, hxq one argument per line |
| 8 | list literal broken one per line by hxq where the fork keeps it flat: hxq keeps the source layout when `arrayWrap` is unset | A (CANON-3) | 272 (95) | 3 (3) | 9 (7) | `for (k in [(a: Null<String>), b]) if (k != null) k;` is stable flat AND broken in hxq |
| 9 | `try x catch (e:T) y;` on one line (client tree config: hxq keeps one line, the fork forces `catch` onto its own line); the 32 (20) / 2 (1) cells are counted by predicate on some other shape, no repro | F | 32 (20) | 2 (1) | 41 (27) | client tree config: `try load(this) catch (e:Exception) trace(e);` → fork `try load(this)⏎catch (e:Exception) trace(e);`. Under the anyparse and Pony configs both tools break `try load(this) catch (e:haxe.Exception) trace(e);` into the same four lines (try / load / catch / trace) |
| 10 | bodies of `if` / `for` / `return` (`singleStatementBraces`, `loopBodyIfElseNext`, `if (c)⏎return x ? a : b`); the fork also breaks a short condition when the body is long | K, F | 174 (138) | 82 (48) | 32 (22) | `if (c) { return v; }` → hxq `if (c) return v;`; `if (body.length == 0) return a || b ? x : y;` over 140 → fork `if (⏎body.length == 0⏎) return …` |
| 11 | ternary layout with non-switch branches; `+` continuation in array elements | F, T | 191 (137) | 7 (7) | 19 (15) | counted by predicate, no repro |
| 12 | space: `catch (e:T)`, `return[ for`, `#if (!macro )` | G, F | 1 (1) | 125 (64) | 0 | see the gaps |
| 13 | space: `->`: the fork leaves the arrow of a lambda after typed parameters unspaced and ignores `functionTypeHaxe4Policy: none` for function types | F | 0 | 0 | 56 (14) | `(n:Int)->run(n)` → fork unchanged, hxq `(n:Int) -> run(n)`; `var cb:()->Void` → fork `() -> Void`, hxq keeps |
| 14 | space: colon of a named function-type parameter and of a type-parameter constraint | T3 | 141 (85) | 45 (19) | 0 | `final f: (call:QueryNode) -> Bool;` `f<T:Dynamic>` → fork `(call: QueryNode)`, `<T: Dynamic>` (config `typeHintColonPolicy: after`), hxq unspaced |
| 15 | space: `macro (…)` against `macro(…)` | T4 | 95 (26) | 0 | 0 | `return macro ($a >= 1);` → fork `macro($a >= 1)` |
| 16 | blank line between consecutive typedef / enum fields after a field with a multi-line doc comment (the fork knows only the global `afterFieldsWithDocComments`, not the per-kind key) | F | 228 (127) | 2 (2) | 3 (3) | `/** …⏎ */ var reason;⏎var description;` → fork inserts a blank between the two |
| 17 | blank after a standalone `//` marker before a member: hxq keeps the source blank, the fork drops it | T5 | 62 (62) | 0 | 3 (2) | `// --- section⏎⏎public function t() {…}` → fork removes the blank |
| 18 | other blank-line differences (before a doc comment after `}`: hxq keeps two source blanks, the fork one or none) | T5 | 260 (153) | 62 (42) | 18 (14) | counted by predicate, no repro |
| 19 | indentation: `+` / `?` continuation, the `}` left by class 4, comment blocks, block-comment body re-indented | F | 139 (90) | 37 (33) | 20 (14) | counted by predicate, no repro |
| – | compound reshapes, same line count, several decisions at once | long tail | 313 (224) | 19 (18) | 195 (74) | not separable; counted by predicate, no repro |
| – | space, other positions (colons, brace padding, commas) | long tail | 116 (94) | 39 (24) | 16 (15) | counted by predicate, no repro |
| – | wrap shapes no predicate took | long tail | 894 (504) | 90 (65) | 126 (85) | counted by predicate, no repro |

Anyparse's own tree is canonical under hxq (0 files rewritten), Pony is not (49 files), the client tree nearly is (7). The fork is
not idempotent on any of the three; hxq is on all of them (second pass: 0 files).

### Defects found on the way

- anyparse: 3 Pony files do not parse (`tests/test/ToolsTest.hx`, a template under `tools/bin/templates/webmodel`, `tools/nodesrc/module/server/Proxy.hx`; the template also crashes the fork); `Build.hx` and `Copy.hx` of Pony need two writer rewrites to reach their fixed point (the writer says so); `hxq fmt` on a directory argument works through the `hxq` wrapper, the bare engine rejects it (`no argument names a file of a known language`).
- fork: classes 2, 3, 4, 9, 13 and 16 above; a second pass changes 109 / 7 / 2 files.

### Taste calls (questions for the user)

1. T1: `sameLine.caseSiblings: anyBreak` (all bodies of a switch move together). Dropping it removes 913 / 610 lines of divergence (Pony / client tree); the fork cannot express it. Keep, or per-case fitting like the fork?
2. T2: an argument that is an array / object literal: one argument per line (hxq) or fill (the config's `fillLineWithLeadingBreak`)?
3. T3: colon of a named function-type parameter and of a `<T:Bound>` constraint: follow `typeHintColonPolicy` (fork) or stay unspaced (hxq, what the anyparse tree has)?
4. T4: `macro (expr)` with or without the space?
5. T5: blank lines around `//` section markers and before doc comments: source decides (hxq, bounded by `maxAnywhereInFile`) or a forced count (fork)?
