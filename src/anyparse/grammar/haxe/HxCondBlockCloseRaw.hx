package anyparse.grammar.haxe;

/**
 * Raw byte capture of a BLOCK-CLOSING conditional-compilation region:
 * everything after the dispatching `#if` keyword up to AND INCLUDING the
 * closing `#end`, constrained so that the fragment OPENS with a `}` -
 * the closer of the block the region sits in - before any `{` of its
 * own.
 *
 * The shape is the mirror image of `HxCondBlockOpenRaw`: the region
 * closes the enclosing block, re-opens a continuation of the same
 * if-chain, and leaves that continuation unclosed so the `}` AFTER
 * `#end` serves every compilation variant:
 *
 * ```haxe
 * else if (array != null)
 * {
 *     this = new JSFloat32Array(untyped array);
 * #if (openfl && commonjs)
 * }
 * else if (vector != null)
 * {
 *     this = new JSFloat32Array(untyped (vector));
 * #elseif openfl
 * }
 * else if (vector != null)
 * {
 *     this = new JSFloat32Array(untyped untyped (vector).__array);
 * #end
 * }
 * else if (view != null)
 * ```
 *
 * (`lime/utils/Float32Array.hx:43` and its eight sibling typed-array
 * modules; `std/cs/_std/Type.hx:130` and `std/cs/internal/Runtime.hx:118`
 * are the same shape with no `#elseif` clause.)
 *
 * The owning ctor `HxStatement.CondSpliceBlockClose` takes the raw
 * fragment as its ENTIRE payload - there is no tail field. What follows
 * `#end` is the enclosing block's own `}`, which that block's
 * `@:trail('}')` consumes, and the if-chain then continues in the
 * enclosing statement Star (`else if (view != null) ...` above reaches
 * `HxStatement.OrphanElseStmt`). A `{raw, tail}` shape would have to
 * name `}` as a statement, which no production does.
 *
 * WHY A DEDICATED TERMINAL rather than reusing `HxCondSpliceRaw`. A
 * payload-only raw ctor is maximally greedy - it matches ANY region that
 * reaches it. The leading-`}` constraint keeps it to regions that
 * genuinely close their enclosing block, so the ctor cannot silently
 * swallow a region a future structural production should own. It is
 * dispatched AFTER `HxStatement.CondSpliceStmt` for the same reason
 * `CondSpliceStmt` sits after `Conditional`: every region an earlier
 * ctor can represent is already gone by the time this one is tried.
 *
 * NESTING is deliberately NOT supported - the scan stops at the FIRST
 * `#end`, and the leading run also refuses to cross a `#if`, so a region
 * with an inner conditional simply does not match. No observed
 * block-closing region nests.
 *
 * `@:rawString` - byte-exact round-trip through `_dt(value)`, no
 * unescape pass; the writer re-emits the fragment verbatim.
 */
@:re('(?:(?![{}]|#if|#end)[\\s\\S])*\\}(?:(?!#end)[\\s\\S])*#end')
@:rawString
abstract HxCondBlockCloseRaw(String) from String to String {}
