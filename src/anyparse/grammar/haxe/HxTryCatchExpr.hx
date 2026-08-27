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
 * `@:fmt(blockBodyKeepsInline)` (ω-block-shape-aware) on `body` makes
 * the body-break shape-aware: when the body's runtime ctor is a block-
 * form (`BlockExpr`), the layout collapses to inline (`try { … }`)
 * regardless of `expressionTry=Next`. Block bodies have their own
 * visual structure — breaking `try \n\t{ … }` would split a brace pair
 * across the leading hardline.
 *
 * `@:fmt(blockBodyKeepsInline('sameLineCatch'))` (ω-block-body-alt-
 * samelinepolicy) on `catches` is the knob form of the same flag —
 * when the prev body's runtime ctor is a block, the catch separator
 * is driven by `sameLine.tryCatch` (the statement-form knob) instead
 * of the bare-body branch's `sameLine('expressionTry')`. Matches
 * haxe-formatter, where `tryCatch=next` breaks `} catch` to `}\ncatch`
 * for both statement-form and block-bodied expression-form (e.g.
 * `return try { … } catch ...`) while `expressionTry` continues to
 * drive bare-bodied expression-form (`var x = try foo() catch (...)
 * bar;`). Statement-form `HxTryCatchStmt` does NOT carry the flag —
 * its catches Star opts into the dual `bareBodyBreaks` shape that
 * forces hardline before each catch whenever the prev body is non-
 * block, regardless of policy (see
 * `testSameLineCatchAppliesToEveryCatch`).
 *
 * `body` carries `@:trailOpt(';')`: Haxe accepts an optional `;`
 * terminating the try-expression body before `catch`, e.g.
 * `return try call(); catch (e:Any) null;` — the bare-body form the
 * formatter emits, and the shape macro code commonly writes. Same
 * `@:trailOpt(';')` meta and lowerStruct path as `HxIfExpr.thenBranch`
 * (the `;`-before-`else` precedent). The `;` is consumed, not stored
 * (AST is identical to the no-semicolon form), so non-`;` callers are
 * untouched and statement-scope `try` (own `HxStatement` production) is
 * unaffected. Block-body forms (`try { … } catch { … }`) carry no `;`
 * and are likewise unaffected. NOTE: the haxe-formatter reference
 * preserves the `;` for the bare-body form; re-emitting it
 * (source-presence + writer gate, cf. `HxAstPredLowering`) is a deferred
 * follow-up — this slice closes the parse gap only.
 *
 * omega-try-brace-symmetry: `@:fmt(tryBraceSymmetry('catches', 'BlockExpr', 'ExprStmt'))` on `body`
 * and `@:fmt(tryCatchBraceSymmetry('body', 'BlockExpr', 'ExprStmt'))` on `catches` give the value
 * form the same one-verdict-per-construct brace symmetry the statement form has — but WITHOUT
 * `@:fmt(tryDeBrace)`, so it only ever adds braces. A de-braced value body would leave the whole
 * expression needing a terminator only the enclosing statement can supply, and this rule cannot see
 * its parent. The third argument names the ctor that raises the wrapped EXPRESSION into the block
 * expression element type. Same wrap-only stance `valueBraceSymmetry` takes on a value-`if`.
 */
@:peg
typedef HxTryCatchExpr = {
	@:trailOpt(';') @:fmt(bodyBreak('expressionTry'), blockBodyKeepsInline, tryBraceSymmetry(
		'catches', 'BlockExpr', 'ExprStmt'
	)) var body: HxExpr;
	@:trivia @:tryparse @:fmt(sameLine('expressionTry'), blockBodyKeepsInline('sameLineCatch'),
		tryCatchBraceSymmetry('body', 'BlockExpr', 'ExprStmt')) var catches: Array<HxCatchClauseExpr>;
};
