# `hxformat.json` — the values the Haxe writer accepts

The formatter reads the project's `hxformat.json` (discovered by walking up from each
file, `FormatConfigDiscovery`). The **keys** are the fork's; the **accepted values** are
not all of them, and three of the useful ones exist only here. Until this file, every
accepted string lived in exactly one place — the `switch` arms of
`anyparse.grammar.haxe.HaxeFormatValues` — so a config that named a value it does not know
was silently ignored and read as "the feature is not wired". That misreading produced
three separate false defect reports in one campaign; this page is the fix.

**A value the reader does not recognise leaves the option at its previous setting.** No
error, no warning. So the first debugging step for "the key does nothing" is to check the
spelling against the tables below, not to look for the missing feature.

## `wrapping.<class>` — a cascade per delimited-list class

```json
{
  "wrapping": {
    "objectLiteral": {
      "defaultWrap": "ignore",
      "rules": [
        { "conditions": [{ "cond": "itemCount >= n", "value": 3 }], "type": "onePerLine" }
      ]
    }
  }
}
```

The classes (`HxFormatWrappingSection`) — each takes the same rules object:

`arrayWrap`, `mapWrap`, `multiVar`, `casePattern`, `anonType`, `methodChain`,
`opBoolChain`, `opAddSubChain`, `callParameter`, `objectLiteral`, `conditionWrapping`,
`ternaryExpression`, `functionSignature`, `anonFunctionSignature`,
`metadataCallParameter`, `typeParameter`, `expressionWrapping`, `implementsExtends`.

`mapWrap` governs a MAP literal — a bracket list whose FIRST element is a `=>` arrow
(`[k => v, …]`) — and `arrayWrap` governs an ordinary array literal, matching the fork's
split between `mapLiteralWrapping` and `arrayLiteralWrapping`. A COMPREHENSION
(`[for (x in xs) …]`) is NOT a map however it is spelled — upstream routes that bracket
kind to `arrayLiteralWrapping` alongside plain arrays, so `arrayWrap` governs it here too
(subject to `sameLine.comprehensionFor`, which can pre-empt the cascade).
hxq asks the same question its
`whitespace.bracketConfig` padding asks, so a list cannot be a map to one knob and an
array to the other. Both cascades default to the same rules, so a config that sets only
one of them is where the difference shows.

Alongside them, on `wrapping` itself: `maxLineLength` (Int), `arrayMatrixWrap` (String),
`trailingComma`, `comprehensionCuddledOpen` (Bool), `methodChainCuddledLinks` (Bool),
`soleItemCuddledBrackets` (Bool), `ternaryCuddledBraces` (Bool).

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
The knob therefore fires exactly when the item's own group BREAKS once glued after
`[ `, which is a question about the PEN COLUMN, not about the indent: the statement
prefix ahead of the bracket (`return ` against `final cr: Array<String> = `) is what
decides whether the body has to move down, and the same item can fit one indent deeper
while overflowing the glue column. Where the item still fits after `[ `, gluing would
leave head and body packed on one line with a lone `]` underneath, so the leading-break
shape is kept instead. A comprehension whose first break sits inside its HEAD rather
than after the generator's `)` is excluded — only a body-level break can deliver the
shape the knob promises. Default `false`.

A rules object holds `defaultWrap`, `defaultLocation`, `defaultAdditionalIndent` (Int),
`rules` (an array of `{type, location, conditions}`) and `itemsAfterCloseParenOnly` (Bool,
`methodChain` only — see its doc for why it is opt-in). **`defaultWrap` alone is a no-op**
unless the object also carries `"rules": []`: without it the built-in cascade's rules stay
in force and win over the default. That trap has its own memory entry and is the second
most common way a wrapping section reads as unwired.

### `defaultWrap` / `rules[].type`

| value | layout |
|---|---|
| `noWrap` | items stay on one line |
| `onePerLine` | every item on its own indented line, first included |
| `onePerLineAfterFirst` | first item inline with the open delimiter, the rest one per line |
| `fillLine` | greedy packing to the line budget, no leading break |
| `fillLineWithLeadingBreak` | the same with a break before the first item |
| `keep` | preserve the source's per-item newline pattern (the fork's `keep`) |
| `ignore` | **anyparse extension** — drop the source newlines and let width decide |
| `packedOrOnePerLine` | **anyparse extension** — leading break, then all items on one continuation line if they fit, else one each |

Every value also accepts its capitalised spelling (`OnePerLine`, `FillLine`, …).

`ignore` is the one that answers "how do I get a canonical layout?": it is the **only**
mode that COLLAPSES a list the source broke — every other mode either preserves the source
form or only breaks a long one. Measured, `objectLiteral` with `defaultWrap: "ignore"` plus
an `itemCount >= n` rule: a source-broken `{x: 1, y: 2}` collapses to one line, and a
source-flat three-item literal breaks one-per-line. The fork's `WrappingType` has no
`ignore`, so no corpus fixture selects it — which is exactly why it went unnoticed.

### `rules[].conditions[].cond`

The exact spellings. A condition whose name contains `n` reads `value` as that threshold;
the five that do not — `exceedsMaxLineLength`, `hasMultilineItems`, `equalItemLengths`,
`hasContainerItems`, `hasMultilineLambdaItems` —
read it as a POLARITY, `1` for "the signal holds" and `0` for "it does not". An omitted
`value` reads as `1`.

| `cond` | true when |
|---|---|
| `itemCount <= n` | the list has at most `n` items |
| `itemCount >= n` | at least `n` items |
| `anyItemLength >= n` | the WIDEST item renders at least `n` chars wide |
| `anyItemLength <= n` | the NARROWEST item is at most `n` chars |
| `allItemLengths <= n` | every item is at most `n` chars (the fork's spelling; `allItemLengths < n` is an older hxq alias for the same test) |
| `allItemLengths >= n` | every item is at least `n` chars |
| `equalItemLengths` | `value: 1` — every item measures the same; `value: 0` — some two differ |
| `totalItemLength >= n` | the items together are at least `n` chars |
| `totalItemLength <= n` | at most `n` chars |
| `exceedsMaxLineLength` | the flat form would pass `maxLineLength` |
| `lineLength >= n` | the line already reaches `n` chars at the open delimiter |
| `hasMultilineItems` | some item is itself multi-line |
| `complexItemCount >= n` | at least `n` items are "complex" — see below the table |
| `hasContainerItems` | some item is an object / array literal — see below the table |
| `hasMultilineLambdaItems` | some MULTI-LINE item is a function literal — see below the table |

Item width is per-construct. For a delimited list (`arrayWrap`, `mapWrap`, `objectLiteral`,
`callParameter`, `anonType`, …) it includes the separator and the space after it for every
item but the last, which is why `equalItemLengths` still holds for a list whose last item
is one separator shorter. The chain classes (`methodChain`, `opBoolChain`, `opAddSubChain`)
measure differently and say so in `WrapItemMeasure`'s own doc — a method chain has no
separator at all, and a binary chain compares `equalItemLengths` on the bare operands.

**`complexItemCount >= n` counts SEMANTICALLY, and only in three classes.** An item is complex
when it is a call or a `new`, or an object / array literal carrying a call or `new` anywhere in
its subtree. Nothing else counts — a lambda does not, and neither does a container with no call
in it, so `[{x: 1}, {x: 2}]` counts zero. The classification is supplied by the grammar at three
sites only (array literal elements, call arguments, `new` arguments), so the condition can be
non-zero for `arrayWrap`, `mapWrap` and `callParameter` and is inert — always false — in every
other wrap class. It is deliberately not a width proxy: the same `arrayWrap` cascade also governs
array PATTERNS in `case` arms and switch-subject arrays, which an `anyItemLength >= n` rule would
mangle and this counter cannot reach.

**`hasContainerItems` reads the other half of the same classification.** It holds when at least
one item is an object or array literal, whether or not a call sits inside it — so it is true for
both `{x: 1, y: 2}` and `{x: f()}`, and false for a call, a lambda, an identifier or a literal.
The two conditions ask different questions: `complexItemCount` asks whether an item carries work,
this asks whether an item is a brace construct. It is supplied at the same three sites and is
inert everywhere else. Its motivating use is `callParameter`: an argument list that mixes a
container with a multi-line argument cannot start that argument on the call line and stay
readable, and a bare `{ UUID: uuid, DeviceTypeId: id }` — complex-count zero — is exactly the case
`complexItemCount >= 1` misses:

```json
"callParameter": { "defaultWrap": "fillLineWithLeadingBreak", "rules": [
  { "conditions": [ { "cond": "itemCount >= n", "value": 2 }, { "cond": "hasMultilineLambdaItems", "value": 1 },
                    { "cond": "complexItemCount >= n", "value": 1 } ], "type": "onePerLine" },
  { "conditions": [ { "cond": "itemCount >= n", "value": 2 }, { "cond": "hasMultilineLambdaItems", "value": 1 },
                    { "cond": "hasContainerItems", "value": 1 } ], "type": "onePerLine" }
] }
```

Two gates in that pair are not decoration. `itemCount >= 2` keeps a lone callback glued —
without it `api.load(profile -> { … })` puts its own single argument on a separate line one
indent deeper. And the multi-line half MUST be the lambda-specific condition: written as the
plain `hasMultilineItems` it also fires when the multi-line element is the COLLECTION, which
sends `new Row([` … `], w, h)` one-argument-per-line and takes the bracket off the head —
measured over one real tree, that spelling changed 65 files where the correct one changes 13.
There is no `containerItemCount >= n` — no cascade has needed to count them.

**`hasMultilineLambdaItems` crosses the kinds array with the rendered items.** It holds when at
least one element is a function literal — an arrow lambda in any spelling, or an anonymous
`function` — AND that element renders multi-line. Neither half answers alone: the kind alone
matches a one-line lambda, and `hasMultilineItems` alone cannot say WHICH element breaks, which
is the whole distinction above.

Capitalised enum spellings (`ItemCountLargerThan`, `ExceedsMaxLineLength`, …) are accepted
too — including the fork's `HasMultiLineItems`, whose capital `L` differs from hxq's own
`HasMultilineItems`. All conditions of one rule must hold; the first matching rule wins,
else `defaultWrap`.

**`lineLength <= n` is the one fork-shipped condition spelling hxq does NOT implement** —
answering it needs the renderer's column probe inverted. A rule naming it is dropped whole.
The same is true of the wrap TYPE `equalNumber`, which upstream declares and then does
nothing with (its own `applyRule` arm is empty, so the rule matches and no wrapping is
applied); hxq drops the rule instead, which lets a LATER rule match — a divergence only a
config that names `equalNumber` can see.

Every drop is named on stderr when the config is read, so a condition or type hxq cannot
answer says so rather than quietly removing your rule.

### `rules[].location` / `defaultLocation`

`beforeLast` or `afterLast` — which side of the separator the break falls on.

## `sameLine.*` — the full key list (33 keys)

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

**`Default` is the COMPILED baseline — `HaxeFormat.instance.defaultWriteOptions`,
what a bare file with no discoverable `hxformat.json` gets.** Six keys
(`ifBody`/`elseBody`/`forBody`/`whileBody`/`doWhileBody`/`caseBody`) are
RE-BASELINED to the fork's own declared default the moment ANY `hxformat.json`
is loaded — before individual JSON keys are applied — because anyparse's
compiled default for these six is `Keep` (a "no config at all" dogfood
preference) while upstream haxe-formatter's own schema declares `Next` for
all six (`HaxeFormatConfigLoader.loadHxFormatJson`, the `ω-D6`/`ω-D7`
re-baseline block, unconditional and outside the `cfg.sameLine != null`
guard). So `caseBody`'s row below is accurate on a scratch file with no
project config, and the do-while section further down (`whose default
`Next` already puts the body on its own line`) is accurate for the
overwhelmingly common case — a real project that HAS an `hxformat.json`,
even one that never mentions these six keys. The `Kind`/`Default` columns
give the compiled value; the `Governs` column notes the re-baseline where it
applies.

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
| `fitLineBodyGlue` | bool | `false` | when a `fitLine` construct body (`if`/`for`/`while`) does not fit the header line AND the next line would not rescue it either (its flat width still exceeds the continuation indent), stay glued to the header and break inside the body instead of moving down a line and an indent step; also reaches an arrow-lambda body that is itself a parenthesised expression |
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

A CORRECTLY-spelled `sameLine.*` value can still be silently DEGRADED at the runtime-mapping
step, which is a narrower and different failure mode than the capitalisation one above — it
parses, and only THEN loses information. The four `SameLinePolicy` keys (`ifElse`,
`tryCatch`, `doWhile`, `expressionTry`) parse all four lowercase `HxFormatSameLinePolicy`
strings, but their runtime type (`anyparse.format.SameLinePolicy`) has only three members —
`sameLineToRuntime` maps `next` → `Next`, `keep` → `Keep`, and BOTH `same` and `fitLine` →
`Same`, so `ifElse: "fitLine"` parses fine and silently becomes `same` (`HxFormatSameLinePolicy`'s
own doc-comment describes an older Bool-only runtime and is stale on this point — the
loader code, read above, is the current truth). `elseIf` and
`elseSwitch` share one JSON vocabulary, `HxFormatKeywordPlacement` — all four strings
(`same`/`next`/`keep`/`fitLine`) parse on EITHER key, but `elseIf` only has a two-value
`KeywordPlacement` to land in at runtime: `keywordPlacementToRuntime` degrades both
`keep` and `fitLine` to `Same` (no per-node source-shape tracking / no fit mode for a
lone keyword), while `elseSwitch` reads through `keywordPlacementKeepToRuntime`, which
keeps `keep` as real `Keep` and only degrades `fitLine`. So `elseIf: "keep"` is accepted
by the schema and silently becomes `same` — not a parse error, and not what the string
promises.

## `sameLine.*` — one position trap worth repeating

`sameLine.caseBody` governs a `switch` in STATEMENT position; a `switch` used as a VALUE
(`return switch …`) is governed by `sameLine.expressionCase`. The two are a dispatch on
position (`opt._inExprPosition`), NOT an OR — setting only `caseBody` and testing on
`return switch` reads as "the key does nothing". `Same` / `FitLine` OVERRIDE a source
break; only `Keep` reads it. Full detail in `HxFormatSameLineSection`'s own doc.

## The three keys S67 added, and the position trap each of them has

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

**`whitespace.bracesConfig.singleStatementBraces: "symmetric"`** — the ADD direction of a
policy that until now only removed. An if/else (or try/catch group, or value-`if`) with
EXACTLY ONE braced branch gets the other braced; a bare branch with NO braced sibling is left
alone, so this is not "brace everything". `"remove"` arms both directions (the repair has been
part of it since it shipped), `"symmetric"` only the repair, `"keep"` neither. `else if` and
`else switch` are exempt in both directions — bracing them would rebuild the `else { if … }`
shape `collapsible-else-if` exists to remove. ⚠️ The statement path and the VALUE path keep
two separate skip lists (`SingleStmtBraces.SYMMETRY_WRAP_SKIP_CTORS` and the tail of
`@:fmt(valueBraceSymmetry(…))` in `HxIfExpr`); teaching one about a ctor does not teach the
other, which is how a value `switch` in else position was still being braced after the
statement one was exempt.

**`whitespace.conditionalCompilationBinop: true`** — respace the `&&` / `||` inside a `#if` /
`#elseif` CONDITION, which the grammar carries as one verbatim text terminal rather than as an
expression tree, so `whitespace.binopPolicy` (which acts on operator NODES) has never reached
it. A BOOL, not a policy of its own: the direction is read from `binopPolicy` so the two
cannot drift. Default off. An operator inside a string literal, a unary `!`, and an operator
whose whitespace holds a newline are all left exactly as authored. ⚠️ The `#if` head and the
`#elseif` head reach the writer by DIFFERENT paths — the `#if` cond field carries
`@:fmt(sharpCondParensInside(…))`, whose handler emits the condition text itself — so a
normalisation wired only on the terminal reaches `#elseif` alone.

## `sameLine.comprehensionFor` — a body policy, plus one bracket side effect

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

Two traps:

1. **An absent key is `keep`, not the fork's `same`.** Every fork corpus fixture omits the key, and
   defaulting to `Same` would re-lay every comprehension body those fixtures wrote on their own
   line. So a config that says nothing keeps whatever the source wrote.
2. **`fitLine` also pads the comprehension brackets** (`[ for … ]`), overriding
   `whitespace.bracketConfig.comprehensionBrackets`. That is fork parity, not a shorthand:
   `MarkSameLine.markArrayComprehension`'s FitLine arm forces the same spacing whenever the bracket
   config has not already asked for it. If you want padding WITHOUT `fitLine`'s body policy, set
   `whitespace.bracketConfig.comprehensionBrackets` to `{"openingPolicy": "onlyAfter",
   "closingPolicy": "before"}` and pick the body policy you actually want — that is what this
   repository's own fixtures do.

Until 2026-09-04 the key did nothing BUT the padding: `same` / `next` / `fitLine` / `keep` produced
byte-identical output for every input, so no config value could move a comprehension body.

## `sameLine.loopBodyIfElseNext` — the one loop body whose `else` has nothing to pair with

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

| `forBody` | knob off (or absent) | knob on |
|---|---|---|
| `fitLine` | glued | **broken out** |
| `same`    | glued | **broken out** |
| `keep`    | glued (a glued source is reproduced) | **broken out** |
| `next`    | broken out | broken out |

`whileBody` and `doWhileBody` answer the same table. All four ON cells emit the SAME bytes — the
ones `next` emits — and every OFF cell is byte-identical to what that placement produced before the
key existed. `next` already breaks every loop body, the guard idiom included, which is the cost this
key exists to avoid.

S157 shipped the key gated on the `FitLine` LAYOUT, so the `same` and `keep` rows of this table both
read "glued / glued": a config on either had the reported defect and no way to decline the key that
was documented for it. S159 moved the gate onto the policy value (`WriterBodyPolicyLowering.`
`buildBodyCoreWrap`, one ternary over `BodyPolicy.Next`) and wired `HxDoWhileStmt.body` as well.

```jsonc
"sameLine": { "forBody": "fitLine", "whileBody": "fitLine", "loopBodyIfElseNext": true }
```

Reported site (`src/pony/unity3d/UTools.hx`), off — the `}` and the `else` sit at the LOOP's
indent, so the `else` reads as a branch of the `for`:

```haxe
		for (i in 0...a.Length) if (skip) {
			skip = false;
		} else {
```

and on:

```haxe
		for (i in 0...a.Length)
			if (skip) {
				skip = false;
			} else {
```

### The two forms are NOT both fixed points

With the key off and `forBody: fitLine`, writing the broken-out shape by hand does not survive one
`fmt` pass — the writer re-joins it onto the header, because that is what `fitLine` means. The key
is the only way to hold the shape. (`HxLoopBodyIfElseSliceTest.testKnobOffRejoinsAHandBrokenSite`
records this in both directions.)

### What counts as a "branching body", and what does not

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

### `do … while`

`do <body> while (cond);` has a glued form of its own (`do if (c) { … } else { … } while (c);`)
under every `sameLine.doWhileBody` value but `next`, whose default `Next` already puts the body on
its own line. The key reaches it: on, the body moves one indent step under `do` and the trailing
`while (cond);` stays cuddled to the body's close, exactly as `doWhileBody: "next"` renders it.

Off:

```haxe
		do if (skip) {
			skip = false;
		} else {
			use(skip);
		} while (skip);
```

and on:

```haxe
		do
			if (skip) {
				skip = false;
			} else {
				use(skip);
			} while (skip);
```

The population is 0 in both configs measured here (no `hxformat.json` in either tree sets
`doWhileBody` at all), so this arm of the key is carried by pins rather than by a corpus.

## `sameLine.expressionIfWithBrackets` — one knob, three seams, and they have to agree

**`sameLine.expressionIfWithBrackets: true | false`** (default `false`; the fork has no such key,
so an absent one is fork parity) makes an opening `[` — an array literal AND an array
comprehension, which share one ctor — that is the value of an expression-`if` branch HUG the branch
head, and makes the matching `]` close against the `else`:

```haxe
return if (c) [
	oneLongElementName,
	anotherLongElementName
] else [];
```

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

## Where to look when a key still does nothing

1. Check the spelling here. An unknown value is silently ignored.
2. Check whether the section needs `"rules": []` to clear the built-in cascade.
3. Check the construct's POSITION (the `sameLine` trap above; expression vs statement).
4. Then, and only then, read the emit path: `HaxeFormatValues` maps config text to the
   `WriteOptions` field, `TriviaSepLowering.triviaSepStarExpr` is where a trivia-bearing
   list's mode is consumed, and `WrapList` is the cascade engine.
