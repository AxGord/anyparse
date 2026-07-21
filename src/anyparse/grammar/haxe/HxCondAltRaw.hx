package anyparse.grammar.haxe;

/**
 * Raw byte capture of the ALTERNATE branches of a conditional-
 * compilation region: from `#else` / `#elseif` up to AND INCLUDING the
 * closing `#end`.
 *
 * Unlike `HxCondSpliceRaw` - which starts at the `#if` and therefore
 * swallows the FIRST branch as well - this terminal begins at the first
 * alternative, so the region's first branch can be parsed structurally
 * ahead of it. That asymmetry is the point: `HxCondSharedBodyDecl` uses
 * it to keep a type declaration's name, type parameters and heritage in
 * the tree while the parallel headers that a preprocessor would have
 * chosen instead survive as bytes.
 *
 * Motivating source - `pony/flash/ui/TooltipSource.hx:16`:
 *
 * ```haxe
 * #if starling
 * class TooltipSource extends MovieClip implements IStarlingConvertible {
 * #else
 * class TooltipSource extends MovieClip {
 * #end
 *     ... members ...
 * }
 * ```
 *
 * The `#else` prefix is MANDATORY, which is also what keeps the owning
 * ctor off regions that have no alternative branch at all.
 *
 * NESTING is supported by the same two-branch alternation
 * `HxCondSpliceRaw` uses: the first alternative skips over BALANCED
 * inner `#if ... #end` pairs and stops at the first UNMATCHED `#end`,
 * the second is the plain stop-at-the-first-`#end` fallback. One live
 * source needs it - `lime/net/HTTPRequest.hx:16`, whose `#else` branch
 * contains two complete `#if ... #end` regions plus a whole class
 * declaration before the header that opens the shared body. The known
 * hazard of the nesting-aware branch (a DIRECTIVE-unbalanced inner `#if`
 * whose `#end` also closes the outer region would let the scan run past
 * it) does not arise here: such a region has no structurally parseable
 * first branch either, so it never reaches this terminal.
 *
 * The whole alternation is wrapped in a non-capturing group because
 * `Codegen.eregField` prepends a bare `^`, and `^A|B` parses as
 * `(^A)|B` - the second alternative would otherwise be free to match
 * mid-buffer.
 *
 * `@:rawString` - byte-exact round-trip through `_dt(value)`, no
 * unescape pass; the writer re-emits the fragment verbatim.
 */
@:re('#else(?:(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#end)[\\s\\S])*#end(?:(?!#if|#end)[\\s\\S])*)*#end|(?:(?!#end)[\\s\\S])*#end)')
@:rawString
abstract HxCondAltRaw(String) from String to String {}
