package anyparse.grammar.haxe;

/**
 * Raw byte capture of a TOKEN-SPLICE conditional-compilation region:
 * everything after the dispatching `#if` keyword up to AND INCLUDING
 * the closing `#end` — the condition atom plus an arbitrary token
 * fragment that is NOT a balanced expression/statement subtree
 * (dangling operators, half a ternary, an if-head whose else-branch
 * lives outside the region).
 *
 * Live dogfood shapes (regions no structural conditional production can represent):
 *
 *  - `"a" + endl + #if !flash "b" + x + #end "c"` — operand run with
 *    a trailing dangling `+`
 *  - `A + B #if mobile - 120 #end` — infix tail
 *  - `a.wrong || b.wrong #if !mobile || c.wrong #end` — infix tail on a bool chain
 *  - `#if share cond ? new A(...) : #end new B(...)` — half a ternary
 *  - `#if x if (c) g(); else #end h();` — if-head with the else branch outside
 *
 * The `#end` is swallowed INTO the raw match (rather than living on a
 * `@:trail`) so the enclosing ctors can parse their continuation tail
 * immediately after this terminal with no mid-struct keyword field.
 *
 * NESTING. The regex is a two-branch alternation. The FIRST branch skips
 * over BALANCED inner `#if ... #end` pairs and stops at the first UNMATCHED
 * `#end`, so a splice fragment may itself contain a complete nested
 * conditional. Three live sources need this, and all three were skip-parse
 * until it existed:
 *
 *  - `lime/system/ThreadPool.hx:829` -- `if (activeJobs #if lime_threads +
 *    __queuedExitEvents #if lime_threads_deque + __queuedWorkEvents #end
 *    #end <= 0)`, a postfix `CondSpliceTail` whose fragment nests one
 *    region.
 *  - `motion/actuators/SimpleActuator.hx:232` -- `#if (!neko && !hl) if
 *    (Reflect.hasField(target, i) #if flash ... #elseif js ... #end) { ... }
 *    else #end { ... }`, a statement `CondSpliceStmt` whose dangling-else
 *    if-head carries a region inside its condition.
 *  - `lime/text/Font.hx:111` -- `#if js if (ascender == untyped #if haxe4
 *    js.Syntax.code #else __js__ #end ("undefined")) #end ascender = 0;`,
 *    the same statement shape with the nested region in the condition's
 *    operand position.
 *
 * The SECOND branch is the original stop-at-the-first-`#end` rule, kept as
 * a fallback so an UNBALANCED inner `#if` (one whose `#end` also closes the
 * outer region) still matches exactly as it did before -- the nesting-aware
 * branch cannot represent that shape and would otherwise scan forward to an
 * unrelated `#end`. Branch order matters: regex alternation is first-match,
 * so the balanced reading wins whenever it applies. Both branches end at a
 * `#end`, so the terminal's contract (byte-verbatim capture through the
 * closing directive) is unchanged.
 *
 * The whole alternation is wrapped in a non-capturing group because
 * `Codegen.eregField` prepends a bare `^`, and `^A|B` parses as `(^A)|B` --
 * the second alternative would otherwise be free to match mid-buffer.
 *
 * `@:rawString` — byte-exact round-trip through `_dt(value)`, no
 * unescape pass; the writer re-emits the fragment verbatim.
 */
@:re('(?:(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#end)[\\s\\S])*#end(?:(?!#if|#end)[\\s\\S])*)*#end|(?:(?!#end)[\\s\\S])*#end)')
@:rawString
abstract HxCondSpliceRaw(String) from String to String {}
