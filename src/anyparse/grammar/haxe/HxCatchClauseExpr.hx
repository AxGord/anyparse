package anyparse.grammar.haxe;

/**
 * Expression-position catch clause grammar.
 *
 * Shape: `catch (name[:Type]) body`.
 *
 * Structurally parallel to `HxCatchClause` but the `body` field is
 * `HxExpr`, not `HxStatement` — used inside `HxTryCatchExpr` where
 * a value is produced rather than a side effect (`var x = try expr
 * catch (e:T) fallbackExpr;`).
 *
 * Block bodies (`catch (e:T) { ... }`) still parse — `HxExpr.BlockExpr`
 * absorbs the block form via `tryBranch` rollback against `ObjectLit`.
 *
 * The `catch` keyword, opening `(`, and closing `)` all sit on the
 * `param` wrapper field — `@:kw('catch')` emits `expectKw`, `@:lead('(')`
 * emits `expectLit`, both sequentially (D50), and `@:trail(')')` emits
 * the matching closer after the inner `HxCatchParam` shape parses. The
 * type annotation is optional inside the wrapper (`catch (_)` is legal).
 *
 * `@:fmt(bodyBreak('expressionTry'))` on the `body` field wraps the
 * catch body in a SameLinePolicy switch. `Same` keeps the existing
 * inline space (`catch (e:T) body`); `Next` emits hardline + Nest
 * one level deeper (`catch (e:T)\n\tbody`). Pair with
 * `bodyBreak('expressionTry')` on `HxTryCatchExpr.body` to get the
 * full multi-line expression try layout when `expressionTry=Next`.
 *
 * `@:fmt(blockBodyKeepsInline)` makes the body-break shape-aware: when
 * the catch body's runtime ctor is `BlockExpr`, the layout stays
 * inline (`catch (e:T) { … }`) regardless of `expressionTry=Next`.
 * See the parallel paragraph on `HxTryCatchExpr` for the rationale.
 */
@:peg
@:spanned('CatchClause')
typedef HxCatchClauseExpr = {
	@:kw('catch') @:lead('(') @:trail(')') var param:HxCatchParam;
	@:fmt(bodyBreak('expressionTry'), blockBodyKeepsInline) var body:HxExpr;
};
