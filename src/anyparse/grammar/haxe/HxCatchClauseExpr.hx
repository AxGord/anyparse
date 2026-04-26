package anyparse.grammar.haxe;

/**
 * Expression-position catch clause grammar.
 *
 * Shape: `catch (name:Type) body`.
 *
 * Structurally parallel to `HxCatchClause` but the `body` field is
 * `HxExpr`, not `HxStatement` — used inside `HxTryCatchExpr` where
 * a value is produced rather than a side effect (`var x = try expr
 * catch (e:T) fallbackExpr;`).
 *
 * Block bodies (`catch (e:T) { ... }`) still parse — `HxExpr.BlockExpr`
 * absorbs the block form via `tryBranch` rollback against `ObjectLit`.
 *
 * The `catch` keyword and opening `(` are both on the `name` field —
 * `@:kw('catch')` emits `expectKw` and `@:lead('(')` emits
 * `expectLit`, both sequentially (D50). The closing `)` is
 * `@:trail(')')` on the `type` field.
 *
 * `@:fmt(bodyBreak('expressionTry'))` on the `body` field wraps the
 * catch body in a SameLinePolicy switch. `Same` keeps the existing
 * inline space (`catch (e:T) body`); `Next` emits hardline + Nest
 * one level deeper (`catch (e:T)\n\tbody`). Pair with
 * `bodyBreak('expressionTry')` on `HxTryCatchExpr.body` to get the
 * full multi-line expression try layout when `expressionTry=Next`.
 */
@:peg
typedef HxCatchClauseExpr = {
	@:kw('catch') @:lead('(') var name:HxIdentLit;
	@:lead(':') @:trail(')') var type:HxType;
	@:fmt(bodyBreak('expressionTry')) var body:HxExpr;
};
