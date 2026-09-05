package anyparse.grammar.haxe;

/**
 * Statement-position BLOCK-TAIL conditional: `#if <cond> <fragment
 * closing the enclosing block> <block> #end` — a region that closes the
 * block it sits in and then opens AND closes a block of its own, so the
 * whole construct is self-contained and nothing after `#end` belongs to
 * it.
 *
 * Motivating source — `pony/magic/builder/ChainBuilder.hx:72`, the
 * closing half of an opener/closer pair whose opener is at `:27`:
 *
 * ```haxe
 * #if display
 * } catch (_:Dynamic) {
 * }
 * #end
 * return fields;
 * ```
 *
 * `raw` swallows the condition atom and the unbalanced head byte-verbatim
 * (see `HxCondBlockTailRaw` for why the head cannot be given a tree and
 * why keeping it raw is what preserves its own spelling); `body` parses
 * the region's own block as an ordinary `HxStatement`, so the writer
 * formats it exactly as it formats any other block — which is the whole
 * point of the ctor. The empty catch body above then collapses to `{}`
 * through `HxStatement.BlockStmt`'s `@:lead('{') @:trail('}')` pair, the
 * same collapse an unguarded `} catch (_: Dynamic) {}` already gets.
 *
 * `endKw` carries the closing `#end` as a TERMINAL field rather than a
 * ctor `@:trail` — the `HxCondSpliceOpExpr.endKw` precedent. A ctor-level
 * trail is emitted after the last field with the ctor's own separator,
 * which has no source-newline slot to read; a terminal field goes through
 * the ordinary field path and reproduces the `}\n<indent>#end` boundary
 * from the captured trivia.
 *
 * Dispatch: tried AFTER `HxStatement.Conditional` (every balanced region
 * keeps its structured representation) and BEFORE `CondSpliceStmt`, which
 * otherwise matches this region — its `{raw, tail}` shape swallows the
 * whole region into `raw` and binds the statement AFTER `#end` as `tail`,
 * which is how `ChainBuilder.hx` parsed before this ctor existed. Disjoint
 * from `CondSpliceBlockOpen` by construction: `HxCondBlockOpenRaw` ends on
 * an unclosed `{` before `#end`, this head ends before a `{` whose closer
 * is inside the region. Disjoint from `CondSpliceBlockClose`, which is
 * dispatched later and whose regions leave their re-opened block unclosed.
 */
@:peg
typedef HxCondSpliceBlockTail = {
	var raw: HxCondBlockTailRaw;
	var body: HxStatement;
	var endKw: HxCondEndLit;
}
