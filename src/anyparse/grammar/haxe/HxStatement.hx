package anyparse.grammar.haxe;

/**
 * Statement grammar for Haxe function bodies.
 *
 * Branches in source order — keyword-dispatched branches first,
 * block statement next, expression-statement catch-all last:
 *
 *  - `StaticVarStmt` / `StaticFinalStmt` — `static var name = init;` /
 *    `static final name = init;` static-local declarations (Haxe 4.3
 *    feature, persists across function calls). Byte-twin of
 *    `VarStmt` / `FinalStmt` — same `HxVarDecl` payload, same trail-opt
 *    shape gate. The `static` prefix dispatches via `@:kw('static')` +
 *    `@:lead('var')` / `@:lead('final')` — kw+lead single-Ref pattern
 *    (precedent: `LocalInlineFnStmt` `@:kw('inline') @:lead('function')`,
 *    `HxDoWhileStmt`'s `@:kw('while') @:lead('(')`). Multi-var and leading meta compose for free via the shared
 *    `HxVarDecl` body — `static final @Test a = 1, b = 2;` round-trips
 *    without grammar additions. Placed before the bare `VarStmt` /
 *    `FinalStmt` because `static` is a distinct kw that never collides
 *    with a leading `var` / `final` ident, so branch order is
 *    documentation, not dispatch.
 *
 *  - `VarStmt` — `var name:Type = init;` local variable declaration.
 *    Reuses `HxVarDecl` from the class-member grammar. The `var`
 *    keyword is consumed here (not in `HxVarDecl` itself, which is
 *    a plain typedef). The trailing `;` is `@:trailOpt(';')` —
 *    optional on parse, shape-gated on write via
 *    `@:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))`: the
 *    writer drops the `;` when `decl.init` ends with `}` (block,
 *    switch, if-with-else block, try-with-block, anon-fn body, object
 *    literal, …) and emits it otherwise. Mirrors haxe-formatter's
 *    canonical output (`var foo = switch (x) { case _: 1; }` without
 *    `;`); without the gate the writer would always emit a redundant
 *    `;` after `}`, regressing ~50 corpus fixtures of that shape. The
 *    optional `;` on parse is too lenient by Haxe's spec (`var x = 5
 *    \nvar y = 6` is accepted), but the formatter only ever emits the
 *    canonical form chosen by the gate, so the leniency has no
 *    observable effect on output.
 *
 *  - `FinalStmt` — `final name:Type = init;` immutable local-binding
 *    declaration. Parallel to `VarStmt`, identical body shape — the
 *    only difference is `@:kw('final')` instead of `@:kw('var')`. In
 *    Haxe, `final` replaces `var` (it is not a modifier on `var`),
 *    so the body is the same `HxVarDecl` reused verbatim. Trailing
 *    `;` follows `VarStmt`'s shape-gated `:trailOpt` for the same
 *    reason — `final foo = switch (x) { case _: 1; }` round-trips
 *    without a trailing `;`.
 *
 *  - `ReturnStmt` — `return expr;` return statement with a value.
 *    Tried before `VoidReturnStmt` — if expression parsing fails
 *    (e.g. next token is `;`), tryBranch rolls back and the void
 *    variant is tried. The trailing `;` is `@:trailOpt(';')` (ω-return-trailopt) — Haxe's parser allows
 *    `return expr` without `;` when the next token already terminates
 *    the statement (typically `}`), e.g. `return if (...) {} else {}`.
 *    Trivia mode preserves the source's `;` presence verbatim via the
 *    `trailPresent:Bool` synth slot from `ω-trailopt-source-track`,
 *    so round-trip is byte-identical regardless of whether the
 *    author wrote `;` or not. Plain mode falls back to always emitting
 *    `;` (no AST-shape gate wired) — corpus tests run trivia mode
 *    exclusively. `@:fmt(bodyPolicy('returnBody'))` on `value`
 *    routes the `return`→value separator through the runtime
 *    `BodyPolicy` switch (ω-return-body), mirroring how
 *    `HxIfStmt.thenBody` / `HxForStmt.body` consume `ifBody` /
 *    `forBody`. `Same` keeps `return value;` flat when it fits in
 *    `opt.lineWidth`; otherwise the value breaks to the next line at
 *    one indent level deeper (ω-returnbody-widthaware via the
 *    `@:fmt(widthAware)` companion meta — see below). `Next` always
 *    pushes the value to the next line at one indent level deeper.
 *    `FitLine` keeps it flat when it fits within `lineWidth`, otherwise
 *    breaks. Default is `FitLine`. With `widthAware` active, our `Same`
 *    now matches haxe-formatter's `sameLine.returnBody: same` directly
 *    — their `Same` wraps long values via a separate
 *    `wrapping.maxLineLength` pass, which we replicate per-field at
 *    write time via a `Doc.IfWidthExceeds(opt.lineWidth, brk, flat)`
 *    wrap around the `Same`-mode emission. `Keep` `BodyOnSameLine=true`
 *    (source had inline) inherits the same width-aware wrap; `Keep`
 *    `BodyOnSameLine=false` (source had break) is unaffected — already
 *    breaks via `nextLayoutExpr`.
 *
 *    Known limitation: the renderer probe uses `flatTokenWidth` which sums every token in the flat shape, treating forced hardlines as zero. For multi-line bodies whose first rendered line fits but whose total token width exceeds `lineWidth` (multi-branch `if-expr` under `expressionIf=keep` is the canonical example), the probe over-fires and breaks the body to next line — correct for `Keep`-with-source-broken (break is what the user wrote), wrong for `Same`-with-multi-line-body (the user asked for inline). A proper fix requires threading a `<refName>BeforeNewline:Bool` synth slot to kw-led ctor branches with `@:fmt(bodyPolicy)` AND a first-line-width measurement primitive (`IfFirstLineExceeds` Doc sibling, or the equivalent helper).
 *
 *    The parameterless `@:fmt(widthAware)` flag opts the field into the
 *    width-aware wrap inside `WriterLowering.bodyPolicyWrap`. Strictly
 *    opt-in: other `bodyPolicy` consumers (HxIfStmt.thenBody,
 *    HxForExpr.body, HxObjectField.value, …) keep strict-flat `Same`
 *    semantics until they explicitly opt in. Mirrors haxe-formatter's
 *    per-construct `wrapping.maxLineLength` rules — currently only
 *    return-shape consumers (`return`, eventually `throw`) match.
 *    Also carries `@:fmt(indentValueIfCtor('ObjectLit',
 *    'indentObjectLiteral', 'objectLiteralLeftCurly'))` (ω-return-indent-objectliteral) — when the value is an
 *    `ObjectLit` AND `opt.indentObjectLiteral=true` AND
 *    `opt.objectLiteralLeftCurly==Next`, the kw→body wrap routes
 *    through a `Nest(_cols, subCall)` shape that lets the
 *    `ObjectLit`'s own leading `_dhl` (from its leftCurly=Next)
 *    pick up `+cols` indent. Result: `return\n\t{\n\t\tk: v\n\t};`
 *    instead of `return \n{...};` (cuddled space + body at parent
 *    column). Mirrors `indentation.indentObjectLiteral` semantics
 *    extended from `HxVarDecl.init` / `HxObjectField.value` to the
 *    return-body site.
 *
 *    Sister entry `@:fmt(indentValueIfCtor('IfExpr',
 *    'indentComplexValueExpressions'))` (ω-issue-257-return-same-indent-value-expr) — when the value is
 *    an `IfExpr` AND `opt.indentComplexValueExpressions=true`, the
 *    flat-path body emit (Same / Keep+bodyOnSameLine / widthAware
 *    flat) is wrapped in `Nest(_cols, body)` so the multi-branch
 *    if-expr's internal `else` hardlines pick up `+cols`. Fires
 *    ONLY in flat-path; `nextLayoutExpr`/brk/`blockLayoutExpr`/
 *    `fitExpr` already supply their own outer Nest, so doubling
 *    would over-indent. Mirrors the parallel entry on
 *    `HxVarDecl.init`. Result: `return if (a) x\n\t\telse y;`
 *    instead of `return if (a) x\n\telse y;`.
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
 *    (ω-throw-body), mirroring `ReturnStmt` exactly. `Same`
 *    (default) keeps `throw value;` flat regardless of length; `Next`
 *    always pushes the value to the next line at one indent level
 *    deeper; `FitLine` keeps it flat when it fits within `lineWidth`,
 *    otherwise breaks. The default is `Same` (ω-throw-body-same-default) because haxe-formatter has no
 *    `throwBody` knob and leaves `throw <expr>` inline regardless of
 *    length, so a long chain-typed value wraps via its own internal
 *    fill rules (`opAddSubChain` / `opBoolChain` cascade) rather
 *    than breaking at the kw boundary.
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
 *    `@:fmt(tryPolicy)` (ω-try-policy) — runtime-switchable
 *    `WhitespacePolicy` for the gap after the `try` keyword (default
 *    `After` → `try {`; `None` / `Before` collapse to `try{`). Mirrors
 *    `ifPolicy` / `forPolicy` / `whilePolicy` / `switchPolicy` on
 *    sibling control-flow ctors. Co-exists with `tryBody` on the
 *    sub-struct's `body` field via the `kwOwnsInlineSpace` mode in
 *    `WriterLowering.bodyPolicyWrap` (ω-tryBody): the parent
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
 *    input wins via the source-order precedence; bare-form input that would otherwise route through `ExprStmt(TryExpr(...))` (with expression-form layout) matches here and picks up the
 *    `bareBodyBreaks` shape-aware multi-line layout. Intentionally
 *    does NOT carry `@:fmt(tryPolicy)`: the first field's
 *    `@:fmt(bareBodyBreaks)` triggers the `stripKwTrailingSpace`
 *    predicate in `WriterLowering.lowerEnumBranch`, which gates the
 *    kw-trailing-space slot to `null` regardless of the configured
 *    policy. Carrying the flag here would silently no-op, so it is
 *    omitted to keep the asymmetry visible in source.
 *
 *  - `UntypedBlockStmt(body:HxUntypedFnBody)` — `untyped { stmts }`
 *    block statement. The `untyped` keyword acts as a block-shape
 *    modifier with no trailing `;` requirement (parallel to how
 *    `if`/`while`/`for` block bodies avoid `;` while `ExprStmt`
 *    requires it). Reuses the shared `HxUntypedFnBody` Seq wrapper
 *    (kw + `HxFnBlock`) so the parse + write paths match
 *    `HxFnBody.UntypedBlockBody` byte-for-byte. Must appear before
 *    `BlockStmt` so the inner `untyped` peek (via `tryBranch`
 *    rollback) fires before the bare-`{` dispatch; covers the stmt-
 *    level `untyped { … }` form found in `try untyped { … } catch …`
 *    and inside fn-body blocks (`function f():T { untyped { … } }`).
 *    Without this branch the parser would accept `untyped { … };`
 *    (with trailing `;`) via `ExprStmt(UntypedExpr(BlockExpr))`, but
 *    the haxe-formatter corpus only emits the no-`;` form.
 *    Intentionally does NOT carry `@:fmt(bodyPolicy('untypedBody'))`
 *    on the ctor: a stmt-level inner wrap stacks with parent
 *    separators (block stmts already prepend `\n<indent>`, `try`'s
 *    tryBody wrap already supplies a `Same`/`Next` gap), so a
 *    duplicate inner wrap would produce double spaces / blank lines /
 *    trailing-space-before-hardline artefacts. The fn-decl form
 *    (`HxFnBody.UntypedBlockBody`) carries the knob because the
 *    parent `HxFnDecl.body` Ref-field's leftCurly Case 5 routes
 *    `UntypedBlockBody` through `spacePrefixCtors` + `ctorHasBodyPolicy`
 *    so the parent emits `_de()` and the wrap is the sole separator.
 *    Stmt-context handling lives at the parent site: ω-untyped-body-stmt-override wires
 *    `@:fmt(bodyPolicyOverride('UntypedBlockStmt', 'untypedBody'))`
 *    on `HxTryCatchStmt.body` so the existing `tryBody` wrap reads
 *    `opt.untypedBody` instead of `opt.tryBody` at runtime when the
 *    body is `UntypedBlockStmt`. Block-stmt Star context (no parent
 *    bodyPolicyWrap) keeps the Star's `\n<indent>` separator unchanged
 *    — matching haxe-formatter's `markUntyped` rule that
 *    `sameLine.untypedBody` only applies when the parent token is not
 *    a Block-typed `BrOpen`. The inner `untyped`→`{` gap is owned by
 *    `HxUntypedFnBody.block`'s `@:fmt(leftCurly)` (ω-untyped-leftCurly): under `leftCurly=Next` the brace drops onto
 *    its own line regardless of the stmt-context, mirroring
 *    haxe-formatter's `lineEnds.leftCurly` global Allman placement.
 *    Carries `@:fmt(blockShape)` (ω-tryBody-next-default + sameLineCatch-shape-aware) so shape-aware writers that gate on
 *    "the prev body ends with `}`" treat it as block-equivalent. Used
 *    by `bareBodyBreaks` on `HxTryCatchStmt.catches` to keep the
 *    `} catch (...)` cuddle for `try untyped { … } catch (...)`. The
 *    flag is consumed by `WriterLowering.isBlockShapeEquivalentBranch`,
 *    a sister of `isBlockCtorBranch` that respects `blockShape` —
 *    `bodyPolicyWrap`'s strict block-ctor override path keeps using
 *    `isBlockCtorBranch` so per-ctor overrides
 *    (`bodyPolicyOverride('UntypedBlockStmt', 'untypedBody')`) still
 *    fire.
 *
 *  - `Conditional` — `#if <cond> <stmts> [#else <stmts>] #end`
 *    preprocessor-guarded region wrapping function-body statements
 *    (ω-cond-comp-stmt). Mirror of `HxDecl.Conditional` /
 *    `HxModifier.Conditional` at the statement scope: `@:kw('#if')`
 *    dispatches with a non-word-char boundary check (so `#iff` is
 *    rejected); `@:trail('#end')` consumes the closing directive
 *    after `HxConditionalStmt` parses the cond atom, the body Star,
 *    and the optional `#else` clause. Nested `#if` is supported
 *    transitively because the body re-enters `HxStatement` through
 *    `HxConditionalStmt.body`.
 *
 *    Position before `BlockStmt` / `ExprStmt` ensures the `#if`
 *    keyword dispatch fires before the `{`-literal `BlockStmt`
 *    fallthrough and the catch-all expression-statement; branch order
 *    relative to other kw-led ctors does not matter because no other
 *    `HxStatement` ctor's keyword starts with `#`.
 *
 *  - `LocalFnStmt` / `LocalInlineFnStmt` — named local function
 *    declaration as a statement: `function g(...) {...}` and the
 *    `inline function g(...) {...}` form. Both reuse `HxFnDecl` —
 *    the exact payload of `HxClassMember.FnMember`, so the inner
 *    `name <typeParams>(params):Ret body` grammar is shared and
 *    needs no new types. `LocalFnStmt` dispatches on `@:kw('function')`;
 *    `LocalInlineFnStmt` composes `@:kw('inline') @:lead('function')`
 *    (the kw+lead single-Ref path, same as `HxDoWhileStmt`'s
 *    `@:kw('while') @:lead('(')`). An anonymous function expression
 *    `function() {}` / `function(x) trace(x)` is NOT a local-fn
 *    statement — it has no name, so `HxFnDecl.name` (an `HxIdentLit`)
 *    fails on `(` and `tryBranch` rolls the consumed `function`
 *    keyword back to `ExprStmt` → `HxExpr.FnExpr` (same shared-kw
 *    rollback pattern as `SwitchStmt`/`SwitchStmtBare`). Must appear
 *    before `BlockStmt` / `ExprStmt`; order relative to the other
 *    kw-led ctors does not matter (`function` / `inline` collide with
 *    no other `HxStatement` keyword).
 *
 *  - `BlockStmt` — `{ stmts }` block statement. No keyword guard —
 *    dispatched by the `{` literal. Uses Case 4 in
 *    `Lowering.lowerEnumBranch` (Array<Ref> with lead/trail, no sep).
 *    Must appear before `ExprStmt` so the `{` is not consumed by the
 *    expression parser.
 *
 *  - `EmptyStmt` — a lone `;` (the Haxe empty statement). Zero-arg
 *    ctor with `@:lit(';')`, the exact shape of `HxFnBody.NoBody`.
 *    Covers a standalone `;` and the optional trailing `;` after a
 *    brace-closed statement (`{ … };`, `switch e { … };`) — the `}`
 *    closes the prior statement (no terminator needed), leaving the
 *    `;` with no host. Placed immediately before `ExprStmt`: no other
 *    `HxStatement` starts with `;`, so `@:lit(';')` only fires when
 *    the statement literally begins with `;`; `expr;` still parses as
 *    `ExprStmt` (its expression does not start with `;`).
 *
 *  - `ExprStmt` — `expr;` expression-statement. Catch-all: any
 *    expression, optionally followed by `;`. Must appear last because
 *    it has no keyword guard — if placed before the keyword branches,
 *    input like `return 1;` would attempt to parse `return` as an
 *    `IdentExpr` atom.
 *
 *    The trailing `;` is `@:trailOpt(';')` shape-gated parser-side via
 *    `@:fmt(trailOptParseGate('stmtExprNoSemi'))` (ω-slice-V).
 *    The `;` is REQUIRED — the parser throws to terminate the
 *    statement, preserving multi-statement boundary detection in
 *    blocks / switch-arms (the statement Star loop relies on
 *    `expectLit` throwing) — UNLESS the parsed expr is
 *    brace-terminated (`HxExprUtil.stmtExprNoSemi` true: `macro { … }`,
 *    `macro switch (e) { … }`, and the `endsWithCloseBrace` set), where
 *    it is optional, matching Haxe's rule that a `}`-closed statement
 *    needs no `;`. A blanket `@:trailOpt` (no gate) on this no-keyword
 *    catch-all would make `;` unconditionally optional and destroy
 *    boundary detection; the gate keeps `expectLit` for every
 *    non-brace expr. Trivia mode preserves the source's `;` presence
 *    verbatim through the generic `isAltTrailOptBranch` `trailPresent`
 *    synth slot (same path as `ReturnStmt`); plain mode falls back to
 *    always emitting `;`.
 */
@:peg
enum HxStatement {

	@:kw('static') @:lead('var') @:trailOpt(';') @:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'), captureKwNewline)
	StaticVarStmt(decl: HxVarDecl);

	@:kw('static') @:lead('final') @:trailOpt(';') @:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'), captureKwNewline)
	StaticFinalStmt(decl: HxVarDecl);

	@:kw('var') @:trailOpt(';') @:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'), deferKwSpace, captureKwNewline)
	VarStmt(decl: HxVarDecl);

	@:kw('final') @:trailOpt(';') @:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'), deferKwSpace, captureKwNewline)
	FinalStmt(decl: HxVarDecl);

	@:kw('return') @:trailOpt(';')
	@:fmt(bodyPolicy('returnBody'),
		bodyPolicySingleLine(
			'returnBodySingleLine', 'IfExpr', 'ForExpr', 'WhileExpr', 'SwitchExpr', 'SwitchExprBare', 'TryExpr', 'BlockExpr'
		), indentValueIfCtor('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly'),
		indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'), widthAware, captureKwNewline, propagateExprPosition)
	ReturnStmt(value: HxExpr);

	@:kw('return') @:trail(';')
	VoidReturnStmt;

	@:kw('if') @:fmt(ifPolicy)
	IfStmt(stmt: HxIfStmt);

	@:kw('while') @:fmt(whilePolicy)
	WhileStmt(stmt: HxWhileStmt);

	@:kw('for') @:fmt(forPolicy)
	ForStmt(stmt: HxForStmt);

	@:kw('switch') @:fmt(switchPolicy)
	SwitchStmt(stmt: HxSwitchStmt);

	@:kw('switch') @:fmt(switchPolicy)
	SwitchStmtBare(stmt: HxSwitchStmtBare);

	@:kw('throw') @:trail(';') @:fmt(bodyPolicy('throwBody'))
	ThrowStmt(expr: HxExpr);

	@:kw('do') @:trail(';')
	DoWhileStmt(stmt: HxDoWhileStmt);

	@:kw('break') @:trail(';')
	BreakStmt;

	@:kw('continue') @:trail(';')
	ContinueStmt;

	@:kw('try') @:fmt(tryPolicy, forwardNewlineForBody)
	TryCatchStmt(stmt: HxTryCatchStmt);

	@:kw('try') @:trail(';')
	TryCatchStmtBare(stmt: HxTryCatchStmtBare);

	@:fmt(blockShape)
	UntypedBlockStmt(body: HxUntypedFnBody);

	/**
	 * `#error "msg"` / `#error 'msg'` preprocessor directive at
	 * statement scope (ω-sharp-error). Reachable from
	 * `HxConditionalStmt.body` (`Array<HxStatement>`) — `#if cs #error
	 * '…' #end` inside a function body. `@:kw` + single Ref, no
	 * `@:trail` (like `LocalFnStmt`); falls before the `ExprStmt`
	 * catch-all because `#error` is keyword-dispatched. See
	 * `HxDecl.ErrorDecl` for the shared rationale.
	 */
	@:kw('#error')
	ErrorStmt(message: HxErrorMsg);

	@:kw('#if') @:trail('#end') @:fmt(sharpCondParensGap, conditionalMarkerDedent)
	Conditional(inner: HxConditionalStmt);

	/**
	 * Token-splice fallback for `#if` statement regions the structured
	 * `Conditional` fail-rewinds on (dangling-else if-heads) — see
	 * `HxCondSpliceStmt`. Tried directly after it.
	 */
	@:kw('#if')
	CondSpliceStmt(inner: HxCondSpliceStmt);

	@:kw('function')
	LocalFnStmt(decl: HxFnDecl);

	@:kw('inline') @:lead('function')
	LocalInlineFnStmt(decl: HxFnDecl);

	@:fmt(leftCurly('blockLeftCurly'), emptyCurlyBreak('blockEmptyCurly'), rightCurly('blockRightCurly'), keepCurlyBlanks,
		clearExprPositionNonTail)
	@:lead('{') @:trail('}') @:trivia
	@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	BlockStmt(stmts: Array<HxStatement>);

	@:lit(';')
	EmptyStmt;

	/**
	 * `....` placeholder statement.
	 *
	 * Statement-level twin of `HxClassMember.EllipsisMember`.
	 * Accepts the literal four-dot token as a function-body statement,
	 * matching the haxe-formatter test corpus convention for elided
	 * function bodies (`function f() { .... }` placeholder fixtures).
	 * Not standard Haxe syntax, but the formatter must round-trip these
	 * files verbatim. SimpleCtor with `@:lit('....')` — twin of
	 * `EmptyStmt(';')` (a literal-only token with no payload). No
	 * `@:trail` because the placeholder has no terminator; trivia after
	 * it (newlines, comments) is captured by the surrounding statement
	 * Star slot. Placed before `ExprStmt` so the lit dispatch fires
	 * before the expression catch-all; no other `HxStatement` ctor's
	 * lit/keyword starts with `.`, so order relative to siblings is by
	 * convention only.
	 *
	 * Distinct token from `HxClassMember.EllipsisMember`'s three-dot
	 * `...`: the corpus convention uses 3 dots at member scope and 4
	 * dots at statement scope. The three-dot `...` is also reused by
	 * `HxExpr.@:infix('...', 5) Interval` at expression scope, so the
	 * four-dot statement variant avoids any collision with the infix
	 * range operator in expression position.
	 */
	@:lit('....')
	EllipsisStmt;

	@:trailOpt(';') @:fmt(trailOptParseGate('stmtExprNoSemi'))
	ExprStmt(expr: HxExpr);

	/**
	 * Metadata-prefixed keyword statement — the fallback AFTER
	 * `ExprStmt` so every shape the expression route already parses
	 * (`@:meta expr;`) keeps its `ExprStmt(MetaExpr(...))`
	 * representation byte-identically; only `@:meta if/try/...`
	 * statements (whose branch consumed the terminator) reach here.
	 * See `HxMetaStmt`.
	 */
	MetaStmt(inner: HxMetaStmt);

}
