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

## `sameLine.*` — one position trap worth repeating

`sameLine.caseBody` governs a `switch` in STATEMENT position; a `switch` used as a VALUE
(`return switch …`) is governed by `sameLine.expressionCase`. The two are a dispatch on
position (`opt._inExprPosition`), NOT an OR — setting only `caseBody` and testing on
`return switch` reads as "the key does nothing". `Same` / `FitLine` OVERRIDE a source
break; only `Keep` reads it. Full detail in `HxFormatSameLineSection`'s own doc.

## The three keys S67 added, and the position trap each of them has

**`sameLine.elseSwitch: "same" | "next" | "keep"`** — keyword placement for a `switch`
else-body, the twin of `sameLine.elseIf` for the other keyword-headed statement an `else`
idiomatically carries. `"same"` glues it (`} else switch s { … }`), `"next"` puts it on its
own line, `"keep"` (the DEFAULT) has no opinion and lets the field's `elseBody` /
`expressionElseBody` policy decide. The default differs from `elseIf`'s (`Same`) on purpose:
this key is new and must leave every existing config's bytes alone. It reaches BOTH the
statement `if` and the value `if`. One refusal: a comment written between `else` and the
`switch` declines the glue and the source layout is kept byte for byte — the glued layout has
no channel for that comment.

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

## Where to look when a key still does nothing

1. Check the spelling here. An unknown value is silently ignored.
2. Check whether the section needs `"rules": []` to clear the built-in cascade.
3. Check the construct's POSITION (the `sameLine` trap above; expression vs statement).
4. Then, and only then, read the emit path: `HaxeFormatValues` maps config text to the
   `WriteOptions` field, `TriviaSepLowering.triviaSepStarExpr` is where a trivia-bearing
   list's mode is consumed, and `WrapList` is the cascade engine.
