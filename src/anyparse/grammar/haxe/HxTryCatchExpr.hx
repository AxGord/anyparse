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
 *
 * `@:fmt(bodyBreak('expressionTry'))` (ω-expression-try-body-break)
 * on the `body` field wraps the body in a SameLinePolicy switch.
 * `Same` emits the existing inline space (`try foo()`); `Next` emits
 * hardline + Nest one level deeper (`try\n\tfoo()`). Paired with the
 * Star sameLine knob on `catches`, `Next` produces the canonical
 * multi-line expression try layout (`try\n\tBODY\ncatch (...)\n\tCBODY`).
 * Case 3 enum-branch lowering strips the `try` keyword's trailing
 * space when the sub-struct opens with `@:fmt(bodyBreak(...))` — the
 * wrap below provides the conditional space/hardline instead,
 * preventing a double space in `Same` and a dangling space before a
 * hardline in `Next`.
 *
 * `@:fmt(blockBodyKeepsInline)` (ω-block-shape-aware) on both `body`
 * and `catches` makes the body-break and per-catch separator shape-
 * aware: when the body's runtime ctor is a block-form (`BlockExpr`),
 * the layout collapses to inline (`try { … }` / `} catch (…) { … }`)
 * regardless of `expressionTry=Next`. Block bodies have their own
 * visual structure — breaking `try \n\t{ … }` would split a brace pair
 * across the leading hardline. Statement-form `HxTryCatchStmt` does
 * NOT carry the flag — its haxe-formatter contract on `sameLine.
 * tryCatch=next` breaks `} catch` to `}\ncatch` regardless of body
 * shape (see `testSameLineCatchAppliesToEveryCatch`).
 */
@:peg
typedef HxTryCatchExpr = {
	@:fmt(bodyBreak('expressionTry'), blockBodyKeepsInline) var body:HxExpr;
	@:trivia @:tryparse @:fmt(sameLine('expressionTry'), blockBodyKeepsInline) var catches:Array<HxCatchClauseExpr>;
};
