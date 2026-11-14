package anyparse.grammar.haxe.cond;

/**
 * Haxe preprocessor condition atom — the expression consumed right after `#if` / `#elseif`,
 * captured verbatim as the matched substring so the original condition text round-trips.
 *
 * Its extent is the one `HxPpCond` declares, read by the reader generated from it
 * (`HxPpCondScan.endAt`), which every other consumer of a `#if` condition reaches through this
 * terminal's `@:scan`: the parser and the query side never disagree on where a condition stops,
 * and a regex could not say it, since it cannot count a group's depth.
 *
 * `@:rawString` routes the matched slice through `TerminalParseLowering.lowerTerminal` as the
 * stored value without the string-unescape loop — a preprocessor condition is not a Haxe
 * string literal, so `\n` etc. stay as literal backslash-n in the captured text.
 *
 * `@:condRegionBlank` names the reader of the blank between a directive keyword and its condition and after the
 * condition (`HxPpCondBlankScan.endAt`, generated from `HxPpCondBlank`).
 */
@:scan('anyparse.grammar.haxe.cond.HxPpCondScan.endAt')
@:rawString
@:condRegionCondition
@:condRegionBlank('anyparse.grammar.haxe.cond.HxPpCondBlankScan.endAt')
@:writeNormalize('condOperatorSpacing')
abstract HxPpCondLit(String) from String to String {}
