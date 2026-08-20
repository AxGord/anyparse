package anyparse.grammar.haxe;

/**
 * Raw byte capture of a SELF-TERMINATING token-splice conditional-
 * compilation region: exactly what `HxCondSpliceRaw` matches, narrowed
 * to fragments whose last non-whitespace token before the closing
 * `#end` is a `;`.
 *
 * That `;` is the discriminator between the two things `#if … #end`
 * can be in expression position:
 *
 *  - a fragment that DANGLES and needs the operand after `#end` to
 *    complete it — `#if !flash "b" + endl + #end "c"` (trailing `+`),
 *    `#if share cond ? new A() : #end new B()` (half a ternary),
 *    `#if x if (c) g(); else #end h();` (an if-head whose else-branch
 *    lives outside). Those keep going to `HxCondSpliceExpr`, whose
 *    `tail` parses that operand.
 *  - a fragment that is COMPLETE at its own `#end` because every
 *    branch terminated its own statement — `#if ios true; #else false;
 *    #end`, `@SuppressWarnings(…) #if (haxe_ver > 4.2) a = f(); #else
 *    a = new Map(); #end`. Nothing follows that belongs to the region.
 *
 * Before the split, `HxExpr.CondSpliceExpr`'s MANDATORY `tail` made
 * the second family swallow whatever came next. At a member boundary
 * that is the next member's leading `public` / `static` word read as an
 * `IdentExpr` (`Pony/pony/ui/touch/TouchableBase.hx` — a `member-order
 * --fix` reorder then moved the modifier away from its own declaration
 * and silently turned a public field private); inside a block it is the
 * next STATEMENT (`Pony/pony/Logable.hx:234`, where
 * `l_origTrace = Log.trace;` was projected as a child of the region
 * above it). The swallow is silent in both directions: the writer
 * re-emits the raw fragment plus the absorbed tail verbatim, so the
 * file round-trips byte-exactly and only a reorder reveals the damage.
 *
 * The regex is `HxCondSpliceRaw`'s two-branch alternation - same
 * nesting-aware first branch, same stop-at-first-`#end` fallback - with
 * `;` required immediately before the closing `#end` of each and NO NEWLINE
 * anywhere in the fragment. The one-line restriction is not cosmetic:
 * every real site measured is one line (Pony's `TouchableBase.hx:313`,
 * `haxe/std/Math.hx:302` and `:305`, and nothing else in either tree),
 * while a MULTI-line closed region is a construct the writer cannot yet
 * re-emit correctly - gluing `return` onto the `#if` shifts the whole
 * region one level left, which a verbatim raw capture does not do. The
 * fork's `sameline/issue_54_return_sharp_multiple_passes` fixture pins
 * exactly that dedent, and admitting the shape here turned it from
 * SKIP_PARSE into a round-trip FAIL - so a multi-line closed region keeps
 * going to `HxExpr.CondSpliceExpr` and keeps swallowing its tail, and
 * closing that needs the region REFLOWED, a slice of its own.
 *
 * The fragment stays a RAW capture rather than becoming a structured
 * conditional: a structured reading (the `HxConditionalSemiExpr` shape
 * that already serves member initializers) reflows the region onto one
 * line, which measured as two Pony modules newly drifting under
 * `hxq fmt --list` that the formatter leaves alone today. Verbatim
 * re-emission keeps every such region byte-stable while the tail
 * swallow stops.
 *
 * `@:rawString` - byte-exact round-trip through `_dt(value)`, no
 * unescape pass; the writer re-emits the fragment verbatim.
 */
@:re('(?:(?:(?!#if|#end)[^\\n])*(?:#if(?:(?!#end)[^\\n])*#end(?:(?!#if|#end)[^\\n])*)*;[ \\t]*#end|(?:(?!#end)[^\\n])*;[ \\t]*#end)')
@:rawString
abstract HxCondSpliceClosedRaw(String) from String to String {}
