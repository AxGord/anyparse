package anyparse.grammar.haxe;

/**
 * Statement-position try-catch grammar with bare-expression bodies:
 * `try expr catch (name:Type) expr [catch ...] ;`. The block-body form (`try { … } catch (…)
 * { … }`) goes through `HxTryCatchStmt`; this typedef captures bodies that are bare `HxExpr`s
 * without braces (`try trace("") catch (e:Any) trace("");`). The trailing `;` lives on the
 * parent `HxStatement.TryCatchStmtBare` ctor — bare-expression bodies have no inherent
 * statement terminator, so the entire try-catch needs one.
 *
 * Source order in `HxStatement`: `TryCatchStmt` (block form) is tried first via `tryBranch`;
 * when its `body:HxStatement` parse fails (a bare expression lacks the `;` that `ExprStmt`
 * requires), the parser rolls back to before the `try` kw and tries `TryCatchStmtBare`. Two
 * ctors with the same `@:kw('try')` follow the `HxExpr.TypedCastExpr` / `CastExpr` precedent.
 *
 * The bodies share types with the expression-position forms (`HxTryCatchExpr` /
 * `HxCatchClauseExpr`) — `HxExpr` plus `HxCatchClauseStmtBare` per catch — but the writer
 * knobs differ: `bareBodyBreaks` (no policy) replaces the expression form's
 * `bodyBreak('expressionTry') + blockBodyKeepsInline` pair. The shape-aware wrap forces
 * hardline + Nest for non-block bodies and keeps the inline `' '` separator for block bodies,
 * haxe-formatter's statement-context convention (always multi-line for bare bodies, regardless
 * of `sameLineCatch`). `@:fmt(sameLine('sameLineCatch'), bareBodyBreaks)` on `catches`
 * combines the per-catch policy with the same override: `} catch (…)` follows `sameLineCatch`
 * after a block body and is forced onto a new line after a bare body. The expression form
 * (`HxTryCatchExpr.catches`) uses `expressionTry` + `blockBodyKeepsInline`, the opposite
 * default direction.
 *
 * omega-try-brace-symmetry: this form is where a de-braced statement try/catch lands on
 * re-parse, so it carries the same wrap-only symmetry metas as `HxTryCatchExpr`, plus
 * `@:fmt(constructFitGroup('body', 'catches'))` and the `bareBodyBreaks` policy arguments.
 * Without those the second `fmt` pass would explode what the first collapsed and `fmt` would
 * stop being a fixed point: the unconditional hardline stays the default, while a named
 * `FitLine` knob buys the escape that keeps a fitting construct on one line.
 * `@:fmt(constructFitBody)` on the body turns that escape into a SOFT line the construct group
 * owns, so a construct that does not fit breaks at BOTH seams and reads as the if/else ladder
 * rather than gluing its body to `try`.
 */
@:peg
@:fmt(constructFitGroup('body', 'catches'))
typedef HxTryCatchStmtBare = {
	@:fmt(bareBodyBreaks('tryBody'), constructFitBody, tryBraceSymmetry('catches', 'BlockExpr', 'ExprStmt')) var body: HxExpr;
	@:trivia @:tryparse @:fmt(sameLine('sameLineCatch'), bareBodyBreaks('tryBody', 'catchBody'), constructFitSep,
		tryCatchBraceSymmetry('body', 'BlockExpr', 'ExprStmt')) var catches: Array<HxCatchClauseStmtBare>;
};
