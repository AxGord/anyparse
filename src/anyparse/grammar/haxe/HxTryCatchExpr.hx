package anyparse.grammar.haxe;

/**
 * Expression-position try-catch grammar.
 *
 * Shape: `try body catch (name:Type) catchBody [catch ...]`.
 *
 * Structurally parallel to `HxTryCatchStmt` but both `body` and each
 * catch clause's `body` are `HxExpr`, not `HxStatement` — used where
 * the try-catch yields a value (`var x = try foo() catch (e:Any)
 * null;`, `return try Xml.parse(s).firstElement() catch (_:Any)
 * null;`). Block bodies (`try { ... } catch (e:T) { ... }`) still
 * parse — `HxExpr.BlockExpr` absorbs the block form via `tryBranch`
 * rollback against `ObjectLit`.
 *
 * The `try` keyword is consumed at the enum-branch level
 * (`@:kw('try')` on the `TryExpr` ctor in `HxExpr`). This typedef
 * describes the remainder: a bare expression body followed by one or
 * more catch clauses.
 *
 * The `catches` array uses `@:tryparse` termination (D49) — the loop
 * terminates when the next token fails to parse as
 * `HxCatchClauseExpr` (i.e. no `catch` keyword found). Without
 * `@:tryparse`, the last-field heuristic would select EOF mode.
 *
 * Source-order placement in `HxExpr`: `TryExpr` sits among the
 * `@:kw` atoms (alongside `IfExpr` / `SwitchExpr` / `UntypedExpr` /
 * `TypedCastExpr` / `CastExpr`) — the `try` keyword commits the
 * branch before falling through to `IdentExpr`. Statement-position
 * `try` is consumed by `HxStatement.TryCatchStmt` first because
 * `HxStatement` source order puts `TryCatchStmt` ahead of `ExprStmt`.
 *
 * `@:fmt(sameLine('expressionTry'))` (ω-expression-try) drives the
 * separator between body and `catch`. The expression-form has its
 * own knob — `sameLineCatch` keeps driving the statement-form
 * (`HxTryCatchStmt.catches`). Default `Same` keeps the one-liner
 * idiom; `Next` produces the multi-line expression layout.
 */
@:peg
typedef HxTryCatchExpr = {
	var body:HxExpr;
	@:trivia @:tryparse @:fmt(sameLine('expressionTry')) var catches:Array<HxCatchClauseExpr>;
};
