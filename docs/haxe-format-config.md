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
`soleItemCuddledBrackets` (Bool).

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
the three that do not — `exceedsMaxLineLength`, `hasMultilineItems`, `equalItemLengths` —
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
| `complexItemCount >= n` | at least `n` items are "complex" (a call, a literal list, a lambda) |

Item width is per-construct. For a delimited list (`arrayWrap`, `mapWrap`, `objectLiteral`,
`callParameter`, `anonType`, …) it includes the separator and the space after it for every
item but the last, which is why `equalItemLengths` still holds for a list whose last item
is one separator shorter. The chain classes (`methodChain`, `opBoolChain`, `opAddSubChain`)
measure differently and say so in `WrapItemMeasure`'s own doc — a method chain has no
separator at all, and a binary chain compares `equalItemLengths` on the bare operands.

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

## Where to look when a key still does nothing

1. Check the spelling here. An unknown value is silently ignored.
2. Check whether the section needs `"rules": []` to clear the built-in cascade.
3. Check the construct's POSITION (the `sameLine` trap above; expression vs statement).
4. Then, and only then, read the emit path: `HaxeFormatValues` maps config text to the
   `WriteOptions` field, `TriviaSepLowering.triviaSepStarExpr` is where a trivia-bearing
   list's mode is consumed, and `WrapList` is the cascade engine.
