package anyparse.grammar.haxe;

/**
 * Statement-position try-catch grammar with bare-expression bodies.
 *
 * Shape: `try expr catch (name:Type) expr [catch ...] ;` — the
 * traditional block-body form (`try { … } catch (…) { … }`) goes
 * through `HxTryCatchStmt`; this typedef captures statement-position
 * try-catches where bodies are bare `HxExpr`s without surrounding
 * braces (e.g. `try trace("") catch (e:Any) trace("");`). The
 * trailing `;` lives on the parent `HxStatement.TryCatchStmtBare`
 * ctor — bare-expression bodies have no inherent statement
 * terminator, so the entire try-catch needs one.
 *
 * Source-order in `HxStatement`: `TryCatchStmt` (block-form) is
 * tried first via `tryBranch`. When its `body:HxStatement` parse
 * fails (bare expression like `trace("")` lacks the trailing `;`
 * that `ExprStmt` requires), the parser rolls back to before the
 * `try` kw and tries `TryCatchStmtBare`. Two ctors with the same
 * `@:kw('try')` follow the same precedent as `HxExpr.TypedCastExpr`
 * / `HxExpr.CastExpr` (both `@:kw('cast')`).
 *
 * The bodies share types with the expression-position forms
 * (`HxTryCatchExpr` / `HxCatchClauseExpr`) — `HxExpr` plus
 * `HxCatchClauseStmtBare` for the per-catch shape — but the writer
 * format-knobs differ: `bareBodyBreaks` (no policy) replaces the
 * expression-form's `bodyBreak('expressionTry') + blockBodyKeepsInline`
 * pair. The shape-aware wrap forces hardline + Nest for non-block
 * bodies and keeps the inline `' '` separator for block bodies,
 * matching haxe-formatter's statement-context convention (always
 * multi-line for bare bodies, regardless of `sameLineCatch`).
 *
 * `@:fmt(sameLine('sameLineCatch'), bareBodyBreaks)` on `catches`
 * combines the existing per-catch policy with the same shape-aware
 * override: the `} catch (…)` separator follows `sameLineCatch`
 * after a block body (`Same` → ` ` / `Next` → hardline) and forces
 * hardline after a bare body regardless of the policy. The
 * expression-form (`HxTryCatchExpr.catches`) uses `expressionTry`
 * + `blockBodyKeepsInline` — opposite default direction (block
 * stays inline on `Next`).
 */
@:peg
typedef HxTryCatchStmtBare = {
	@:fmt(bareBodyBreaks) var body:HxExpr;
	@:trivia @:tryparse @:fmt(sameLine('sameLineCatch'), bareBodyBreaks) var catches:Array<HxCatchClauseStmtBare>;
};
