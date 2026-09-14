package anyparse.grammar.haxe;

/**
 * Expression-position try-catch grammar: `try body catch (name:Type) catchBody [catch ...]`.
 * Structurally parallel to `HxTryCatchStmt` but both `body` and each catch clause's `body`
 * are `HxExpr`, not `HxStatement` — used where the try-catch yields a value (`var x = try
 * foo() catch (e:Any) null;`). Block bodies still parse — `HxExpr.BlockExpr` absorbs the
 * block form via `tryBranch` rollback against `ObjectLit`. The `try` keyword is consumed at
 * the enum-branch level (`@:kw('try')` on `HxExpr.TryExpr`, among the `@:kw` atoms);
 * statement-position `try` is consumed by `HxStatement.TryCatchStmt` first. The `catches`
 * Star uses `@:tryparse` termination (D49) — without it the last-field heuristic would
 * select EOF mode.
 *
 * `@:fmt(sameLine('expressionTry'))` (ω-expression-try) drives the separator between body
 * and `catch` — the expression form's own knob; `sameLineCatch` keeps driving the statement
 * form. `@:fmt(bodyBreak('expressionTry'))` on `body` wraps the body in a SameLinePolicy
 * switch: `Same` emits the inline space (`try foo()`), `Next` a hardline + Nest one level
 * deeper. Case 3 enum-branch lowering strips the `try` keyword's trailing space when the
 * sub-struct opens with `@:fmt(bodyBreak(...))`, so the wrap provides the conditional
 * space/hardline instead. `@:fmt(blockBodyKeepsInline)` on `body` makes the break
 * shape-aware: a `BlockExpr` body collapses to inline (`try { … }`) regardless of
 * `expressionTry=Next`, since breaking `try \n\t{ … }` would split a brace pair across the
 * leading hardline. `@:fmt(blockBodyKeepsInline('sameLineCatch'))` on `catches` is the knob
 * form of the same flag: when the previous body is a block, the catch separator is driven by
 * `sameLine.tryCatch` (the statement-form knob) instead of `expressionTry`, matching
 * haxe-formatter, where `tryCatch=next` breaks `} catch` for both statement-form and
 * block-bodied expression-form while `expressionTry` drives the bare-bodied one.
 *
 * `body` carries `@:trailOpt(';')`: Haxe accepts an optional `;` terminating the
 * try-expression body before `catch` (`return try call(); catch (e:Any) null;`) — the same
 * meta and lowerStruct path as `HxIfExpr.thenBranch`'s `;`-before-`else`. The `;` is
 * consumed, not stored; re-emitting it where the source had it is a deferred follow-up.
 *
 * omega-try-brace-symmetry: `@:fmt(tryBraceSymmetry('catches', 'BlockExpr', 'ExprStmt'))` on
 * `body` and `@:fmt(tryCatchBraceSymmetry('body', 'BlockExpr', 'ExprStmt'))` on `catches`
 * give the value form the same one-verdict-per-construct brace symmetry the statement form
 * has — but WITHOUT `@:fmt(tryDeBrace)`, so it only ever adds braces: a de-braced value body
 * would need a terminator only the enclosing statement can supply, and this rule cannot see
 * its parent (the wrap-only stance `valueBraceSymmetry` takes on a value-`if`). The third
 * argument names the ctor that raises the wrapped EXPRESSION into the block element type.
 */
@:peg
typedef HxTryCatchExpr = {
	@:trailOpt(';') @:fmt(bodyBreak('expressionTry'), blockBodyKeepsInline, tryBraceSymmetry(
		'catches', 'BlockExpr', 'ExprStmt'
	)) var body: HxExpr;
	@:trivia @:tryparse @:fmt(sameLine('expressionTry'), blockBodyKeepsInline('sameLineCatch'),
		tryCatchBraceSymmetry('body', 'BlockExpr', 'ExprStmt')) var catches: Array<HxCatchClauseExpr>;
};
