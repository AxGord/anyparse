package anyparse.grammar.haxe;

/**
 * Raw byte capture of a function signature whose parameter list is CLOSED inside a `#if` region: from
 * after the `(` through the `#end`, where every branch carries the `)` and the return type —
 * `getPositions:#if (js && html5) Void->Array<Float>):Array<Float> #else TextLayout):Array<GlyphPosition> #end`.
 *
 * The regex admits directive-free parameter text whose parentheses balance to two levels, then one
 * `#if` region with no nested directive that holds a `)` somewhere before its `#end`. That lookahead is
 * only a cheap filter, not the proof: the function body must parse right after the `#end`, so a region
 * that did not close the list fails the member and the dispatch falls through.
 */
@:re('(?:[^()#]|\\((?:[^()#]|\\([^()#]*\\))*\\))*#if(?=(?:(?!#end)[\\s\\S])*\\))(?:(?!#if|#end)[\\s\\S])*#end')
@:rawString
@:condRegionRaw
abstract HxCondSigRaw(String) from String to String {}
