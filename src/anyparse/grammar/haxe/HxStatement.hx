package anyparse.grammar.haxe;

/**
 * Statement grammar for Haxe function bodies.
 *
 * Branches in source order — keyword-dispatched branches first,
 * block statement next, expression-statement catch-all last:
 *
 *  - `VarStmt` — `var name:Type = init;` local variable declaration.
 *    Reuses `HxVarDecl` from the class-member grammar. The `var`
 *    keyword is consumed here (not in `HxVarDecl` itself, which is
 *    a plain typedef). The trailing `;` is `@:trailOpt(';')` —
 *    optional on parse, canonical on write. Real Haxe drops the `;`
 *    when the initializer ends with `}` (block, switch, if-with-else
 *    block, try-with-block, …) because `}` already terminates the
 *    statement; mandating `;` here would block ~50 corpus fixtures of
 *    the `var foo = switch (x) { case _: ... }` shape. The optional
 *    `;` is too lenient by Haxe's spec (`var x = 5\nvar y = 6` is
 *    accepted), but the formatter only ever emits canonical `;`, so
 *    the leniency has no observable effect on output.
 *
 *  - `FinalStmt` — `final name:Type = init;` immutable local-binding
 *    declaration. Parallel to `VarStmt`, identical body shape — the
 *    only difference is `@:kw('final')` instead of `@:kw('var')`. In
 *    Haxe, `final` replaces `var` (it is not a modifier on `var`),
 *    so the body is the same `HxVarDecl` reused verbatim. Trailing
 *    `;` follows `VarStmt`'s `:trailOpt` for the same reason.
 *
 *  - `ReturnStmt` — `return expr;` return statement with a value.
 *    Tried before `VoidReturnStmt` — if expression parsing fails
 *    (e.g. next token is `;`), tryBranch rolls back and the void
 *    variant is tried. `@:fmt(bodyPolicy('returnBody'))` on `value`
 *    routes the `return`→value separator through the runtime
 *    `BodyPolicy` switch (slice ω-return-body), mirroring how
 *    `HxIfStmt.thenBody` / `HxForStmt.body` consume `ifBody` /
 *    `forBody`. `Same` keeps `return value;` flat (the pre-slice
 *    behaviour). `Next` always pushes the value to the next line at
 *    one indent level deeper. `FitLine` keeps it flat when it fits
 *    within `lineWidth`, otherwise breaks. Default is `FitLine`,
 *    matching haxe-formatter's effective `sameLine.returnBody:
 *    @:default(Same)` semantics — their `Same` wraps long values via
 *    a separate `wrapping.maxLineLength` pass, which corresponds to
 *    our `FitLine` rather than strict `Same`.
 *
 *  - `VoidReturnStmt` — `return;` void return statement. Zero-arg
 *    ctor with `@:kw('return') @:trail(';')`. Lowering Case 0
 *    extended to emit the trail literal (D48).
 *
 *  - `IfStmt` — `if (cond) body [else body]`. Dispatched by the
 *    `if` keyword. The body is parsed via `HxIfStmt` typedef which
 *    handles parenthesised condition, then-body, and optional else.
 *
 *  - `WhileStmt` — `while (cond) body`. Dispatched by the `while`
 *    keyword. The body is parsed via `HxWhileStmt` typedef which
 *    handles parenthesised condition and body.
 *
 *  - `ForStmt` — `for (varName in iterable) body`. Dispatched by
 *    the `for` keyword. The body is parsed via `HxForStmt` typedef
 *    which handles the parenthesised `varName in iterable` clause
 *    and the loop body.
 *
 *  - `SwitchStmt` — `switch (expr) { cases }` switch statement.
 *    Dispatched by the `switch` keyword. The expression, case branches,
 *    and default branch are parsed via `HxSwitchStmt` typedef. Case
 *    bodies use `@:tryparse` for implicit termination at the next
 *    `case` / `default` / `}` token (D49).
 *
 *  - `SwitchStmtBare` — `switch expr { cases }` switch statement
 *    with no parens around the subject. Bodies and case structure
 *    are identical to `SwitchStmt`; only the subject loses its
 *    surrounding parens. Both ctors share `@:kw('switch')`;
 *    `tryBranch` rolls back when `SwitchStmt`'s `@:lead('(')` fails
 *    (next token after `switch` is the subject, not `(`), and
 *    `SwitchStmtBare` is tried next. The parens-form keeps source-
 *    order precedence, so `switch (cond) { … }` still routes to
 *    `SwitchStmt`. Same precedent as the `TryCatchStmt` /
 *    `TryCatchStmtBare` pair.
 *
 *  - `ThrowStmt` — `throw expr;` throw statement. Dispatched by the
 *    `throw` keyword. The expression is parsed and the trailing `;`
 *    is consumed by the branch's `@:trail`.
 *    `@:fmt(bodyPolicy('throwBody'))` on `expr` routes the
 *    `throw`→value separator through the runtime `BodyPolicy` switch
 *    (slice ω-throw-body), mirroring `ReturnStmt` exactly. `Same`
 *    keeps `throw value;` flat; `Next` always pushes the value to
 *    the next line at one indent level deeper; `FitLine` keeps it
 *    flat when it fits within `lineWidth`, otherwise breaks. Default
 *    is `FitLine` matching the `returnBody` precedent — haxe-formatter
 *    has no separate `throwBody` knob upstream, but the same
 *    fit-or-break semantics make sense for long thrown expressions.
 *
 *  - `DoWhileStmt` — `do body while (cond);` do-while loop.
 *    Dispatched by the `do` keyword. The body and parenthesised
 *    condition are parsed via `HxDoWhileStmt` typedef. The trailing
 *    `;` is consumed by the branch's `@:trail` (fires after the
 *    inner typedef). The `cond` field uses `@:kw('while')` +
 *    `@:lead('(')` on the same field (D50).
 *
 *  - `TryCatchStmt` — `try body catch (name:Type) catchBody`.
 *    Dispatched by the `try` keyword. No trailing `;`. The body and
 *    catch clauses are parsed via `HxTryCatchStmt` typedef. Catches
 *    use `@:tryparse` termination (D49). Each catch clause uses
 *    `@:kw('catch') @:lead('(')` on the same field (D50). Bodies
 *    are full `HxStatement`s (typically `BlockStmt`). Carries
 *    `@:fmt(tryPolicy)` (slice ω-try-policy) — runtime-switchable
 *    `WhitespacePolicy` for the gap after the `try` keyword (default
 *    `After` → `try {`; `None` / `Before` collapse to `try{`). Mirrors
 *    `ifPolicy` / `forPolicy` / `whilePolicy` / `switchPolicy` on
 *    sibling control-flow ctors. Co-exists with `tryBody` on the
 *    sub-struct's `body` field via the `kwOwnsInlineSpace` mode in
 *    `WriterLowering.bodyPolicyWrap` (slice ω-tryBody): the parent
 *    Case 3 strips the kw-trail-space (so the kw-policy slot at this
 *    level is `null`) and the wrap's `Same` inline separator inside
 *    `HxTryCatchStmt.body` reads `opt.tryPolicy` to choose between
 *    space and empty. The body-placement axis (`tryBody`) and the
 *    kw-trail-space axis (`tryPolicy`) are thus orthogonal at the
 *    user-facing JSON config level.
 *
 *  - `TryCatchStmtBare` — bare-expression bodies form (ω-statement-
 *    bare-break). `try expr catch (name:Type) expr;` — bodies are
 *    `HxExpr` instead of `HxStatement`, and the entire chain ends
 *    with `;` (bare expressions have no inherent statement
 *    terminator). Both ctors share `@:kw('try')`; `tryBranch`
 *    rolls back when `TryCatchStmt`'s `body:HxStatement` parse
 *    fails on a bare expression (no `;` after `EXPR`, next token
 *    is `catch`), and `TryCatchStmtBare` is tried next. Block-form
 *    input wins via the source-order precedence; bare-form fixtures
 *    that previously routed through `ExprStmt(TryExpr(...))` (with
 *    expression-form layout) now match here and pick up the
 *    `bareBodyBreaks` shape-aware multi-line layout. Intentionally
 *    does NOT carry `@:fmt(tryPolicy)`: the first field's
 *    `@:fmt(bareBodyBreaks)` triggers the `stripKwTrailingSpace`
 *    predicate in `WriterLowering.lowerEnumBranch`, which gates the
 *    kw-trailing-space slot to `null` regardless of the configured
 *    policy. Carrying the flag here would silently no-op, so it is
 *    omitted to keep the asymmetry visible in source.
 *
 *  - `BlockStmt` — `{ stmts }` block statement. No keyword guard —
 *    dispatched by the `{` literal. Uses Case 4 in
 *    `Lowering.lowerEnumBranch` (Array<Ref> with lead/trail, no sep).
 *    Must appear before `ExprStmt` so the `{` is not consumed by the
 *    expression parser.
 *
 *  - `ExprStmt` — `expr;` expression-statement. Catch-all: any
 *    expression followed by a semicolon. Must appear last because it
 *    has no keyword guard — if placed before the keyword branches,
 *    input like `return 1;` would attempt to parse `return` as an
 *    `IdentExpr` atom.
 */
@:peg
enum HxStatement {
	@:kw('var') @:trailOpt(';')
	VarStmt(decl:HxVarDecl);

	@:kw('final') @:trailOpt(';')
	FinalStmt(decl:HxVarDecl);

	@:kw('return') @:trail(';') @:fmt(bodyPolicy('returnBody'))
	ReturnStmt(value:HxExpr);

	@:kw('return') @:trail(';')
	VoidReturnStmt;

	@:kw('if') @:fmt(ifPolicy)
	IfStmt(stmt:HxIfStmt);

	@:kw('while') @:fmt(whilePolicy)
	WhileStmt(stmt:HxWhileStmt);

	@:kw('for') @:fmt(forPolicy)
	ForStmt(stmt:HxForStmt);

	@:kw('switch') @:fmt(switchPolicy)
	SwitchStmt(stmt:HxSwitchStmt);

	@:kw('switch') @:fmt(switchPolicy)
	SwitchStmtBare(stmt:HxSwitchStmtBare);

	@:kw('throw') @:trail(';') @:fmt(bodyPolicy('throwBody'))
	ThrowStmt(expr:HxExpr);

	@:kw('do') @:trail(';')
	DoWhileStmt(stmt:HxDoWhileStmt);

	@:kw('try') @:fmt(tryPolicy)
	TryCatchStmt(stmt:HxTryCatchStmt);

	@:kw('try') @:trail(';')
	TryCatchStmtBare(stmt:HxTryCatchStmtBare);

	@:fmt(leftCurly) @:lead('{') @:trail('}') @:trivia
	BlockStmt(stmts:Array<HxStatement>);

	@:trail(';')
	ExprStmt(expr:HxExpr);
}
