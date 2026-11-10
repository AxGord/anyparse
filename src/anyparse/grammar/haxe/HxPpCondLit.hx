package anyparse.grammar.haxe;

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
 */
@:scan('anyparse.grammar.haxe.HxPpCondScan.endAt')
@:rawString
@:condRegionCondition
@:writeNormalize('condOperatorSpacing')
abstract HxPpCondLit(String) from String to String {}
