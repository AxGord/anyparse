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

`arrayWrap`, `multiVar`, `casePattern`, `anonType`, `methodChain`, `opBoolChain`,
`opAddSubChain`, `callParameter`, `objectLiteral`, `conditionWrapping`,
`ternaryExpression`, `functionSignature`, `anonFunctionSignature`,
`metadataCallParameter`, `typeParameter`, `expressionWrapping`, `implementsExtends`.

Alongside them, on `wrapping` itself: `maxLineLength` (Int), `arrayMatrixWrap` (String),
`trailingComma`, `comprehensionCuddledOpen` (Bool), `methodChainCuddledLinks` (Bool).

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

The exact spellings, with the `value` each reads (`n`); a condition naming no `n` ignores it:

| `cond` | true when |
|---|---|
| `itemCount <= n` | the list has at most `n` items |
| `itemCount >= n` | at least `n` items |
| `anyItemLength >= n` | some item renders at least `n` chars wide |
| `allItemLengths < n` | every item is under `n` chars |
| `totalItemLength >= n` | the items together are at least `n` chars |
| `totalItemLength <= n` | at most `n` chars |
| `exceedsMaxLineLength` | the flat form would pass `maxLineLength` |
| `lineLength >= n` | the line already reaches `n` chars at the open delimiter |
| `hasMultilineItems` | some item is itself multi-line |
| `complexItemCount >= n` | at least `n` items are "complex" (a call, a literal list, a lambda) |

Capitalised enum spellings (`ItemCountLargerThan`, `ExceedsMaxLineLength`, …) are accepted
too. All conditions of one rule must hold; the first matching rule wins, else `defaultWrap`.

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
