package anyparse.grammar.haxe;

/**
 * Raw byte capture of a SWITCH-OPENING conditional-compilation region: a
 * `#if` region whose every branch opens an OUTER block AND, inside it, a
 * `switch (...) {` header, with the switch's case list, its closing `}`
 * and the outer block's closing `}` all living AFTER `#end`, shared by
 * every compilation variant:
 *
 * ```haxe
 * #if utf16
 * for (c in StringIteratorUnicode.unicodeIterator(tmp)) {
 * 	switch (c) {
 * #else
 * for (i in 0...tmp.length) {
 * 	switch (StringTools.fastCodeAt(tmp, i)) {
 * #end
 * 		case ":".code: acc.add(":");
 * 		case var i: acc.addChar(i);
 * 	}
 * }
 * ```
 *
 * (`std/haxe/io/Path.hx:241`.) The shared continuation is a switch CASE
 * LIST, which no `HxStatement` production represents, so the sibling
 * `HxCondSpliceBlockOpen` (whose `body` is `Array<HxStatement>`) cannot
 * own it - the cases fail to parse as statements and its `@:trail('}')`
 * throws on the first `case`.
 *
 * The three constraints select exactly this shape and keep the terminal
 * disjoint from `HxCondBlockOpenRaw`:
 *
 *  - a `#else` / `#elseif` clause (PARALLEL branches, as for
 *    `HxCondBlockOpenRaw` - see that type for why the opener/closer PAIR
 *    shape must be excluded);
 *  - an OUTER `{` before the switch keyword (the wrapping block whose own
 *    `}` follows the switch's - this is what makes the region open TWO
 *    blocks and distinguishes it from a lone `switch`-opening region, a
 *    shape not observed in any live source);
 *  - a `switch (` header as the LAST opener before `#end`, so the shared
 *    body is a case list rather than statements.
 *
 * `HxCondBlockOpenRaw` would also match this region (it ends on `{ #end`
 * with a `#else`), so `HxStatement.CondSpliceSwitchOpen` must be tried
 * BEFORE `CondSpliceBlockOpen`: the block-open ctor's statement body
 * would strand the case list exactly as it does today. The outer-`{`
 * -before-`switch` requirement here is what `HxCondBlockOpenRaw` lacks,
 * so the two terminals never both match a region that has no `switch`.
 *
 * NESTING is deliberately NOT supported: the scan stops at the FIRST
 * `#end`, mirroring `HxCondBlockOpenRaw` - no observed switch-opening
 * region nests a complete inner `#if ... #end`.
 *
 * `@:rawString` - byte-exact round-trip through `_dt(value)`, no
 * unescape pass; the writer re-emits the fragment verbatim.
 */
@:re('(?:(?!#end)[\\s\\S])*#else(?:(?!#end)[\\s\\S])*\\{(?:(?!#end)[\\s\\S])*\\bswitch\\b(?:(?!#end)[\\s\\S])*\\{\\s*#end')
@:rawString
abstract HxCondSwitchOpenRaw(String) from String to String {}
