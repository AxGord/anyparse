package anyparse.grammar.haxe;

/**
 * Raw byte capture of a SELF-TERMINATING token-splice conditional-compilation region: exactly
 * what `HxCondSpliceRaw` matches, narrowed to fragments whose last non-whitespace token
 * before the closing `#end` is a `;`.
 *
 * That `;` is the discriminator between the two things `#if … #end` can be in expression
 * position: a fragment that DANGLES and needs the operand after `#end` to complete it (`#if
 * !flash "b" + endl + #end "c"`, `#if share cond ? new A() : #end new B()`, `#if x if (c)
 * g(); else #end h();`) — those keep going to `HxCondSpliceExpr`, whose `tail` parses that
 * operand; and a fragment that is COMPLETE at its own `#end` because every branch terminated
 * its own statement (`#if ios true; #else false; #end`). Nothing after the latter belongs to
 * the region, and a MANDATORY `tail` would swallow whatever comes next: at a member boundary
 * the next member's leading `public` / `static` word read as an `IdentExpr` (a `member-order
 * --fix` reorder then moved the modifier away from its own declaration and silently turned a
 * public field private); inside a block, the next STATEMENT projected as a child of the
 * region. The swallow is silent in both directions because the writer re-emits the raw
 * fragment plus the absorbed tail verbatim, so only a reorder reveals the damage.
 *
 * The regex is `HxCondSpliceRaw`'s two-branch alternation — same nesting-aware first branch,
 * same stop-at-first-`#end` fallback — with `;` required immediately before the closing
 * `#end` of each.
 *
 * A MULTI-line fragment is admitted, and the writer RE-INDENTS it
 * (`@:writeNormalize('reindentBlock')`): gluing `return` onto the `#if` shifts the whole
 * region one level left, which a verbatim raw capture does not do. The fragment stays a RAW
 * capture rather than becoming a structured conditional: a structured reading (the
 * `HxConditionalSemiExpr` shape that already serves member initializers) reflows the region
 * onto one line, and real code carries such regions hand-laid over several lines; re-emission
 * line by line keeps every such region byte-stable while the tail swallow stops.
 *
 * `@:rawString` — byte-exact round-trip through `_dt(value)`, no unescape pass; the writer
 * re-emits the fragment verbatim, one line at a time.
 */
@:re('(?:(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#end)[\\s\\S])*#end(?:(?!#if|#end)[\\s\\S])*)*;\\s*#end|(?:(?!#end)[\\s\\S])*;\\s*#end)')
@:rawString
@:condRegionRaw
@:writeNormalize('reindentBlock')
abstract HxCondSpliceClosedRaw(String) from String to String {}
