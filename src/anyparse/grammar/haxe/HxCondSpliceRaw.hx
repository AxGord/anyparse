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
 * Nested `#if` inside a splice region is NOT supported — the guarded
 * lookahead stops at the FIRST `#end` (no such nesting exists in the
 * corpus or the dogfood tree; a structural conditional inside a splice
 * would be mis-bracketed anyway).
 *
 * `@:rawString` — byte-exact round-trip through `_dt(value)`, no
 * unescape pass; the writer re-emits the fragment verbatim.
 */
@:re('(?:(?!#end)[\\s\\S])*#end')
@:rawString
abstract HxCondSpliceRaw(String) from String to String {}
