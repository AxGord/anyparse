package anyparse.grammar.haxe;

/**
 * Raw byte capture of the HEAD of a BLOCK-TAIL conditional-compilation region: everything
 * after the dispatching `#if` keyword up to — but NOT including — the `{` that opens a block
 * whose closer is INSIDE the same region, constrained so the fragment OPENS with a `}` (the
 * closer of the block the region sits in) before any `{` of its own. The shape is a region
 * that CLOSES the enclosing block and then opens AND closes a block of its own, with nothing
 * after that block but `#end` — the closing half of the opener/closer PAIR that
 * `HxCondBlockOpenRaw`'s `#else` requirement deliberately keeps off:
 *
 * ```haxe
 * #if display
 * try {
 * #end
 * #if display
 * } catch (_:Dynamic) {
 * }
 * #end
 * ```
 *
 * WHY THE HEAD STAYS RAW AND ONLY THE BLOCK GETS A TREE. The leading `}` closes a `{` that
 * was opened in a DIFFERENT lexical region, so no production can name it at this position —
 * the head is unbalanced by construction. Everything from its `{` on IS a balanced subtree,
 * and `HxCondSpliceBlockTail.body` parses it as an ordinary `HxStatement`: the split
 * `HxCondBlockOpenRaw` makes (raw head, structural body), mirrored. It also keeps the head's
 * own spelling (`catch (_:Dynamic)`, not the writer's `catch (_: Dynamic)`) — a tree there
 * would rewrite bytes that only ONE of the two compilation variants sees.
 *
 * WHY THE LEADING-`}` CONSTRAINT. Without it the terminal would match any region whose
 * fragment merely contains a balanced block, ahead of `CondSpliceStmt` for regions that ctor
 * owns; the constraint restricts it to regions that genuinely close their enclosing block
 * (the `HxCondBlockCloseRaw` rationale), and its leading run refuses `{` because a fragment
 * that opens a block before closing one is not a tail. The trailing run is LAZY with a `(?=\s*\{)` lookahead so the match ends on the last
 * non-whitespace byte of the head; the gap before `{` reaches `body` as ordinary field trivia
 * instead of riding inside the raw string, where the writer could not re-space it.
 *
 * NESTING is deliberately NOT supported — both runs refuse to cross a `#if` or an `#end`, so
 * a region with a complete inner conditional falls through to the other conditional ctors.
 * `@:rawString` — byte-exact round-trip through `_dt(value)`, no unescape pass.
 */
@:re('(?:(?![{}]|#if|#end)[\\s\\S])*\\}(?:(?!\\{|#if|#end)[\\s\\S])*?(?=\\s*\\{)')
@:rawString
@:condRegionRaw
abstract HxCondBlockTailRaw(String) from String to String {}
