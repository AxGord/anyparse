package anyparse.grammar.haxe;

/**
 * Haxe preprocessor condition atom — the expression consumed right after `#if` / `#elseif`,
 * captured verbatim as the matched substring so the original condition text round-trips.
 *
 * Its extent is `CondCondition.expressionEnd`'s, the reader every other consumer of a `#if`
 * condition asks: `!`* (a line break may follow a `!`) and ONE operand — a parenthesised group
 * at any depth whose quoted strings may hold parentheses, a quoted string, a dotted flag name
 * (`target.threaded`) or a number (`#if 0` comments out a region). A binary operator outside
 * parentheses ends the condition, so the parser and the query side never disagree on where a
 * condition stops; a regex could not, since it cannot count a group's depth.
 *
 * `@:rawString` routes the matched slice through `TerminalParseLowering.lowerTerminal` as the
 * stored value without the string-unescape loop — a preprocessor condition is not a Haxe
 * string literal, so `\n` etc. stay as literal backslash-n in the captured text.
 */
@:scan('anyparse.runtime.CondCondition.expressionEnd')
@:rawString
@:condRegionCondition
@:writeNormalize('condOperatorSpacing')
abstract HxPpCondLit(String) from String to String {}
