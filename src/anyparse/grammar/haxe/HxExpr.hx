package anyparse.grammar.haxe;

/**
 * Haxe expression grammar — arrow operator, array/map literals, ternary,
 * null-coalescing, and the full infix/prefix/postfix suite.
 *
 * Atom constructors plus five unary-prefix constructors (including
 * `++`/`--` pre-increment/decrement) plus five postfix constructors
 * (field access, index access, call, `++`/`--` post-increment/decrement)
 * plus one
 * ternary operator plus thirty-five binary-operator constructors
 * across ten precedence levels. Atoms, prefix and postfix are all
 * reached through a single `parseHxExprAtom` call — internally split
 * into `parseHxExprAtom` (the wrapper) and `parseHxExprAtomCore` (the
 * pure leaf + prefix dispatcher) when postfix branches are present.
 * Operator branches carry `@:infix(op, prec)` (or `@:infix(op, prec,
 * 'Right')`) metadata so the Pratt strategy sees them and `Lowering`
 * generates a precedence-climbing loop wrapping the atom parser.
 *
 * **Atom branches** — all leaves, no operators:
 *
 *  - `HexLit` — hexadecimal integer `0x20` / `0XFF`. `@:re @:rawString`
 *    terminal (`HxHexLit`), source-verbatim like `RegexLit`. **Must
 *    appear before `IntLit`**: the integer regex `[0-9]+` would match
 *    the leading `0` and stop, leaving `x20` unconsumed. No overlap
 *    with `FloatLit` (hex has no fractional/exponent form).
 *  - `FloatLit` — decimal with mandatory fractional part (`3.14`,
 *    `1.0e-3`). **Must appear before `IntLit`**: the enum-branch
 *    try-loop iterates in source order, and `3.14` has to be
 *    matched as one float, not `IntLit(3)` followed by stray `.14`.
 *    A bare `42` fails the float regex on the missing `.` and rolls
 *    back to `IntLit`.
 *  - `IntLit` — positive integer (`42`).
 *  - `BoolLit` — `true` / `false`. The `@:lit` multi-literal case in
 *    `Lowering` emits `matchKw` (word-boundary aware) so `trueish`
 *    does not eagerly consume `true`.
 *  - `NullLit` — `null`. Same word-boundary treatment via `expectKw`
 *    in the single-`@:lit` zero-arg case.
 *  - `RegexLit` — EReg literal `~/pattern/flags`. `@:re @:rawString`
 *    terminal (`HxRegexLit`), source-verbatim like `DoubleStringExpr`.
 *    Declared before the `@:prefix('~')` ctor so the atom dispatch
 *    tries the `~/` literal before bitwise-not.
 *  - `ArrayExpr` — array / map literal `[elems]`. Uses `@:lead('[')
 *    @:trail(']') @:sep(',')` — Case 4 in `lowerEnumBranch`, same
 *    pattern as `BlockStmt`. No conflict with postfix `IndexAccess`
 *    (`@:postfix('[', ']')`) because atoms and postfix are separate
 *    dispatch loops. Map literals `[k => v, k2 => v2]` work naturally
 *    because each element is a full expression and `Arrow` is an infix
 *    operator inside the element parse.
 *  - `ObjectLit` — anonymous object literal `{name: value, ...}`.
 *    Wraps `HxObjectLit` typedef. The `@:lead('{')` inside the typedef
 *    drives `tryBranch` peek — non-`{` input rolls back to the next
 *    atom candidate. Statement-level ambiguity with `BlockStmt` (also
 *    `@:lead('{')`) is deferred: only exercised in pure expression
 *    contexts (fn args, RHS of binops, initializers) where no
 *    statement parser competes. Expression-level ambiguity with
 *    `BlockExpr` (also `@:lead('{')`) is resolved by source order
 *    plus `tryBranch` rollback — see `BlockExpr` below.
 *  - `BlockExpr` — block-form expression `{stmt1; stmt2; ...; expr;}`,
 *    e.g. `var x = { trace("hi"); 5; }`,
 *    `return { switch y { case A: 1; } }`. `Array<HxStatement>` between
 *    `{` `}`, no sep — same shape as `HxStatement.BlockStmt`. Placed
 *    AFTER `ObjectLit` so the strict `key: value` shape is tried first;
 *    on inner-shape failure (no `:` after the first identifier, or `;`
 *    instead of `,`/`}`), `tryBranch` (Lowering Case wrapper) rolls back
 *    `ctx.pos` to before `{` and BlockExpr is tried next. Empty `{}` is
 *    consumed by ObjectLit (zero-field Star) — block-vs-object
 *    disambiguation only kicks in for non-empty bodies.
 *  - `ECheckTypeExpr` — type-check expression `(expr : Type)`. Wraps
 *    `HxECheckType` typedef carrying `expr:HxExpr` after `(` and
 *    `type:HxType` after `:` with closing `)`. Same field-pair shape
 *    as `HxTypedCast` (`cast(target, type)`), differing only in the
 *    inner separator (`:` vs `,`) and the writer-side spacing knob
 *    (`@:fmt(typeCheckColon)` defaults to `Both`, emitting `("" : String)`
 *    with surrounding spaces). Placed BEFORE `ParenExpr` and
 *    `ParenLambdaExpr` so a typed map key `(x : Int) => body` parses as
 *    a check-type key + prec-0 infix `=>` (mirroring haxe-formatter's
 *    `Binop(OpArrow, ECheckType(...), body)`), which gives the spaced
 *    `:` and spaced `=>` for free; placed BEFORE `ParenExpr` so bare
 *    `(expr)` only matches when the inner `:` is absent and `tryBranch`
 *    rolls ECheckType back. Followed by postfix the usual way:
 *    `("" : String).length` parses as
 *    `FieldAccess(ECheckTypeExpr(...), "length")`.
 *  - `ParenExpr` — parenthesised expression `(inner)`. The
 *    `@:wrap('(', ')')` metadata is handled by the `Lit` strategy,
 *    which writes `lit.leadText = '('` and `lit.trailText = ')'`.
 *    `Lowering.lowerEnumBranch` Case 3 (single-`Ref` wrapping) reads
 *    both and emits the `expectLit('(') → parseHxExpr → expectLit(')')`
 *    sequence — no Lowering-level change was needed to support
 *    parens. The inner call re-enters `parseHxExpr` at `minPrec = 0`
 *    (default), so parens fully reset precedence and any operator
 *    is allowed inside the group.
 *  - `ParenLambdaExpr` — parenthesised lambda `(params) => body`.
 *    Wraps `HxParenLambda` typedef. Placed **last** among the paren
 *    atoms (after `ECheckTypeExpr` and `ParenExpr`) so it only catches
 *    the forms that CANNOT parse as an expression key: `() => e`,
 *    `(x, y) => e`, `(?x) => e`. Single-expression keys `(x) => e` and
 *    `(x : Int) => e` route through `ParenExpr` / `ECheckTypeExpr` +
 *    prec-0 infix `=>` instead (correct `:` and `=>` spacing).
 *  - `DoubleStringExpr` — double-quoted string literal (`"hello"`).
 *    Escape sequences (`\"`, `\\`, `\n`, `\r`, `\t`) decoded via
 *    inline walk-and-unescape loop generated by `@:unescape` (D53)
 *    using `HaxeFormat.unescapeChar`.
 *  - `SingleStringExpr` — single-quoted string literal with
 *    interpolation (`'hello $name, ${x + 1}!'`). Parsed by a
 *    declarative grammar: `HxInterpString` typedef wraps
 *    `Array<HxStringSegment>` between `'` delimiters. Segments are
 *    `Literal` (plain text + escapes), `Dollar` (`$$` → `$`),
 *    `Block` (`${expr}` — recursive `HxExpr`), `Ident` (`$name`).
 *    All string-content rules use `@:raw` to suppress `skipWs` —
 *    whitespace inside the string is significant.
 *  - `NewExpr` — `new T(args)` constructor call. The `new` keyword
 *    is the commit point (`@:kw('new')`); the type name and argument
 *    list are parsed by `HxNewExpr`. Must appear before `IdentExpr`
 *    so `new` is not consumed as an identifier.
 *  - `MetaExpr` — `@:meta expr` / `@:meta(args) expr` expression-level
 *    metadata wrapper. Wraps `HxMetaExpr` typedef carrying the
 *    `HxMetadata` regex slice plus a recursive `HxExpr`. Placed before
 *    `IdentExpr` so the leading `@` is committed by the meta regex
 *    before the bare-identifier catch-all is tried; non-`@` input fails
 *    the regex on the first byte and `tryBranch` rolls back. Used by
 *    `@:privateAccess (X).object` and similar argument-position metas.
 *  - `IdentExpr` — bare identifier (`other`). **Must appear last**
 *    among the pure atom branches: the identifier regex is permissive and would otherwise match `null` / `true` / `false` as bare identifiers. The terminal is the guarded `HxExprIdentLit` (not the plain `HxIdentLit`): control-flow keywords are rejected up front so a failed keyword-atom branch fail-rewinds honestly instead of re-matching its keyword as a call head (`if (a == b)` → `Call(IdentExpr if, …)`), which would poison ordered-choice fallbacks like `CondSpliceStmt`.
 *  - `DollarBlockExpr` / `DollarReifExpr` / `DollarIdentExpr` — macro
 *    reification escapes (`${expr}`, `$name{expr}`, `$ident`). Exact
 *    expression-position mirror of the `HxStringSegment` interpolation
 *    grammar (`Block` / `Ident`): the only structural addition is the
 *    named-reification middle form `$i{}` / `$v{}` / `$p{}` / `$a{}` /
 *    `$b{}` / `$e{}`, carried by the `HxDollarReif` typedef (`name`
 *    ident then `@:lead("{")` recursive `HxExpr`, closed by the ctor's
 *    `@:trail("}")` — same ctor-wraps-typedef shape as `NewExpr`/
 *    `HxNewExpr`; enum-ctor params cannot carry inline metadata so the
 *    brace lead lives on the typedef field). Declared in
 *    this order so `tryBranch` resolves the shared `$` prefix: `${`
 *    (longest) before `$`, and the brace-bearing `$name{…}` before the
 *    bare `$ident` (the latter is reached only when no `{` follows).
 *    These are purely syntactic — no reification semantics are applied;
 *    the forms exist so anyparse can self-parse its own build macros.
 *  - `VarExpr` / `FinalExpr` — expression-position `var`/`final`
 *    local-binding declarations (`var name:Type = init`,
 *    `final _x:Int = ctx.pos`). Keyword-atom mirror of
 *    `HxStatement.VarStmt` / `FinalStmt`, reusing the same
 *    `HxVarDecl` typedef verbatim — the only difference is the
 *    absence of `@:trailOpt(';')` / `@:fmt(trailOptShapeGate(...))`:
 *    an expression has no statement terminator, the enclosing
 *    statement owns any `;`. Reached when an `HxExpr` is parsed
 *    directly (notably the `MacroExpr` operand: `macro var x = e`,
 *    `macro final _x:Int = ctx.pos`); statement-position `var`/`final`
 *    still binds `HxStatement.VarStmt`/`FinalStmt`, declared before
 *    the `ExprStmt` catch-all. Exists so anyparse can self-parse the
 *    `macro var`/`macro final` reifications its own build macros use.
 *  - `ThrowExpr` — expression-position `throw <expr>`. Bottom-typed
 *    control-flow keyword-atom, the direct analog of the existing
 *    `ReturnExpr` and the expression mirror of `HxStatement.ThrowStmt`,
 *    reusing the same single `value:HxExpr` child — the only
 *    difference from `ThrowStmt` is the absence of the statement-only
 *    `@:trail(';')` / `@:fmt(bodyPolicy('throwBody'))`: an expression
 *    has no statement terminator, the enclosing statement owns any
 *    `;`. Reached when an `HxExpr` is parsed directly (notably the
 *    `MacroExpr` operand: `macro throw new ParseError(...)`);
 *    statement-position `throw e;` still binds `HxStatement.ThrowStmt`,
 *    declared before the `ExprStmt` catch-all. Exists so anyparse can
 *    self-parse the `macro throw` reifications its own build macros use.
 *
 * **Prefix branches** — unary operators, symbolic only. Each
 * `@:prefix(op)` ctor consumes its literal, recurses into the atom
 * parser for the operand, and constructs itself around the result.
 * Prefix binds tighter than any binary infix because the recursion
 * targets the atom function, not the Pratt loop — so `-x * 2` parses
 * as `Mul(Neg(x), 2)`, not `Neg(Mul(x, 2))`. Prefix has no precedence
 * value: all three operators share "one atom consumed, one ctor
 * built", and nesting (`--x`, `!!x`, `-!x`) falls out of the same
 * recursion-into-atom pattern with no extra machinery. Prefix
 * branches sit after the pure atoms in source order so the regex- and
 * literal-based atom branches get first attempt on input like `-5`
 * (FloatLit/IntLit fail on the leading `-`, then the prefix branch
 * consumes it and recurses).
 *
 *  - `Neg` — `-` unary minus.
 *  - `Not` — `!` logical not.
 *  - `BitNot` — `~` bitwise not.
 *
 * **Postfix branches** — left-recursive suffix operators. Each
 * `@:postfix(op)` or `@:postfix(open, close)` ctor applies to an
 * already-parsed atom and builds itself around the result. Postfix
 * lives in the atom wrapper function (`parseHxExprAtom`), which calls
 * `parseHxExprAtomCore` for the underlying leaf/prefix value and then
 * repeatedly peeks each postfix op on the accumulator. The loop
 * terminates when no postfix matches.
 *
 * Binding-tightness invariants (locked in by tests in
 * `HxPostfixSliceTest`):
 *
 *  - **Postfix binds tighter than Pratt infix.** `a.b + c` parses as
 *    `Add(FieldAccess(a, b), c)`, not `FieldAccess(a, Add(b, c))`.
 *    The Pratt loop calls `parseHxExprAtom`, which returns the
 *    postfix-extended atom in one step; the `+` is seen only after
 *    `FieldAccess(a, b)` is already built.
 *  - **Postfix binds tighter than unary prefix.** `-a.b` parses as
 *    `Neg(FieldAccess(a, b))`, not `FieldAccess(Neg(a), b)`. The
 *    prefix ctor `Neg` recurses into the atom wrapper for its
 *    operand (via `recurseFnName` in `Lowering`), so the wrapper
 *    applies postfix to `a` before the prefix ctor wraps the result.
 *  - **Postfix is left-recursive.** `a.b.c` parses as
 *    `FieldAccess(FieldAccess(a, b), c)` because the postfix loop
 *    keeps extending `left` until no further postfix matches.
 *
 *  - `FieldAccess` — `.name` member access. The suffix is parsed as
 *    an `HxFieldNameLit` (the identifier terminal with an optional
 *    leading `$` for macro field-reification — `obj.$name`), so the
 *    field name ends up in the ctor as a single identifier string,
 *    `$` included for the reification form. No module path or type
 *    parameter syntax yet; the recursive `obj.${expr}` form is out of
 *    scope (a regex terminal cannot carry a nested expression).
 *  - `SafeFieldAccess` / `ForceFieldAccess` — `?.name` (Haxe 4.3
 *    null-safe navigation) and `!.name` (the haxe-formatter corpus's
 *    force/assert-navigation form) member access. Structural clones of
 *    `FieldAccess` differing only by the postfix literal; the suffix is
 *    the same `HxFieldNameLit`, so they round-trip through the generic
 *    postfix writer path (`operand` + `?.`/`!.` + `field`) with zero
 *    writer fork. The whole `?.` / `!.` is one two-char postfix literal
 *    rather than a bare postfix `?` / `!` plus a `.`: a bare postfix
 *    `!` would mis-fire on `a != b` (its `!` peeled off `!=`) and a
 *    bare postfix `?` would collide with the ternary `?` / `??`. As a
 *    two-char literal the postfix peek only matches when the next two
 *    chars are exactly `?.` / `!.`, so `a ?? b`, `a ? b : c`,
 *    `a != b` all fall through the postfix loop into the Pratt loop
 *    untouched (postfix runs in the atom wrapper, the ternary /
 *    null-coalescing operators in the separate Pratt loop after it).
 *    `@:fmt(methodChain(...))` is intentionally omitted — the corpus
 *    forms are short and the plain postfix emit is byte-faithful;
 *    chain-layout for `?.`/`!.` is a deferred formatting follow-up.
 *    Left-recursive like `FieldAccess`: `obj!.field!.length` →
 *    `ForceFieldAccess(ForceFieldAccess(obj, field), length)`. The
 *    recursive `obj?.${expr}` computed-safe-nav form is out of scope
 *    (same regex-terminal limit as `FieldAccess`).
 *  - `IndexAccess` — `[expr]` index. The inner expression is parsed
 *    via `parseHxExpr` (not the atom wrapper), resetting precedence
 *    so arbitrary operators are allowed inside the brackets.
 *  - `Call` — `(args)` function/method call. Handles both zero-arg
 *    `f()` and N-arg `f(a, b, c)` through a single ctor with a
 *    comma-separated argument list. The `@:sep(',')` on the ctor
 *    feeds `lit.sepText` on the branch node (via Lit strategy), and
 *    `lowerPostfixLoop`'s Star-suffix variant emits the sep-peek
 *    loop — same pattern as Case 4 in `lowerEnumBranch`.
 *
 * **Ternary branch** — mixfix `? :` operator. `@:ternary('?', ':', 1)`
 * declares the opening operator, middle separator, and precedence.
 * `Lowering.lowerPrattLoop` merges it into the operator dispatch chain
 * alongside binary `@:infix` branches — longest-match sort (D33)
 * resolves `??` (len 2) vs `?` (len 1) automatically. Both middle
 * and right operands parse at `minPrec = 0` (full expression), so
 * right-associativity is inherent: `a ? b : c ? d : e` yields
 * `Ternary(a, b, Ternary(c, d, e))`. Assignments are accepted in
 * ternary branches: `a ? b : c = d` yields `Ternary(a, b, Assign(c, d))`.
 *
 * **Operator branches** — all binary infix. Each `@:infix(op, prec)`
 * carries the operator literal and its precedence; higher precedence
 * binds tighter. The optional third argument `'Left'` / `'Right'`
 * selects associativity (default is left). Ten precedence levels
 * are populated (0-9, with ternary at 1 and null-coalescing at 2),
 * following the Haxe reference table:
 *
 *  - prec 9 — `*` `/` `%` (multiplicative, left-assoc)
 *  - prec 8 — `+` `-` (additive, left-assoc)
 *  - prec 7 — `<<` `>>` `>>>` (shift, left-assoc)
 *  - prec 6 — `|` `&` `^` (bitwise, left-assoc)
 *  - prec 5 — `==` `!=` `<=` `>=` `<` `>` (comparison, left-assoc),
 *    `...` (interval / range), and `is` (runtime type-check, left-assoc).
 *    The interval branch is tight-spaced in the writer via `@:fmt(tight)`
 *    on the ctor so `0...n` stays compact; arithmetic (`+`, `-`, `*`,
 *    `/`) at prec 8-9 binds tighter, so `0...n + 1` parses as `0...(n + 1)`
 *    matching Haxe's convention. The `is` operator is **asymmetric**:
 *    its right operand is `HxType`, not `HxExpr`. Lowering detects the
 *    cross-type Ref and routes the right operand through `parseHxType`
 *    instead of recursing into the Pratt loop; the writer mirrors via
 *    `writeFnFor(rightRef)`. Word-boundary dispatch (`matchKw` instead
 *    of `matchLit`) ensures `island` does not eagerly consume `is`.
 *  - prec 4 — `&&` (logical and, left-assoc)
 *  - prec 3 — `||` (logical or, left-assoc)
 *  - prec 2 — `??` (null-coalescing, **right-assoc**)
 *  - prec 1 — `? :` (ternary, via `@:ternary`)
 *  - prec 0 — `=` `+=` `-=` `*=` `/=` `%=` `<<=` `>>=` `>>>=` `|=`
 *    `&=` `^=` `??=` `=>` (assignment + arrow, **right-assoc**), and
 *    `in` (iterator / membership binder, **left-assoc**). Haxe's
 *    `OpIn` has priority 10 — looser than the arrow `=>` (9), tighter
 *    than assignment `=` (11). anyparse collapses Haxe's arrow and
 *    assignment tiers into a single prec 0, so `in` maps to that same
 *    loosest tier. The infix `in` branch is reached only via a
 *    `macro $x in $y` reification (e.g. building an `EFor` head in a
 *    build macro); a real `for (a in b)` loop is the dedicated
 *    `@:kw('for')` HxForStmt production, not this branch. It is never
 *    chained with an adjacent operator in the corpus, so the
 *    left-assoc / prec-0 placement is the Haxe-faithful choice for the
 *    isolated form. Word-boundary dispatch (`matchKw`, auto-selected
 *    by `Lowering.endsWithWordChar`) keeps `index` / `internal` from
 *    being mis-read as `in` (same mechanism as the `is` operator).
 *
 * Declaration order inside each precedence level puts longer literals
 * first (`<=` before `<`, `>>>` before `>>` before `>`, `>>>=` before
 * `>>=`) for human readability. Correctness does NOT depend on this
 * order — `Lowering.lowerPrattLoop` sorts operators by literal length
 * descending before emitting the dispatch chain, so the generated
 * parser always attempts the longer prefix first regardless of how
 * the grammar author orders the branches. Without that sort, input
 * `a <= b` would parse as `Lt(a, <error>)` because the naive
 * `matchLit(ctx, "<")` consumes one character and strands the `=`.
 * Same story for `<<` vs `<`, `>>>` vs `>>` vs `>`, `&&` vs `&`,
 * `||` vs `|`, `*=` vs `*`, `>>>=` vs `>>>` vs `>>=` vs `>>`, `<<=`
 * vs `<<` vs `<=`, `|=` vs `||`, `&=` vs `&&`, `??` vs `?`, and
 * every other shared-prefix pair — each conflict is resolved at macro
 * time by the length-desc sort.
 *
 * **Arrow operator (`=>`)**: handled via a hybrid approach. Single-
 * ident lambdas (`x => body`) and map literal entries (`[k => v]`)
 * parse naturally through `Arrow` as a prec-0 right-associative
 * infix operator (D33 longest-match resolves `=>` vs `=`). Multi-
 * param and zero-param lambdas (`(x, y) => body`, `() => body`)
 * parse via `ParenLambdaExpr` atom with `tryBranch` backtracking.
 * Switch case `=>` is deferred.
 *
 * **Value-position switch** (`SwitchExpr` / `SwitchExprBare`): a switch
 * parsed as an `HxExpr` (rather than `HxStatement.SwitchStmt`) is by
 * grammar in value position — `directionIndex += switch (e) {…}`,
 * `var x = switch …`, `f(switch …)`. Its ctors carry
 * `@:fmt(propagateExprPosition)` so the descendant cases see
 * `opt._inExprPosition = true` and route their body-placement through
 * the `expressionCase` policy (default `Keep`, preserve same-line
 * source) instead of the statement-position `caseBody` policy (default
 * `Next`, break). Mirrors the fork's `MarkSameLine.markCase` →
 * `isReturnExpression` parent-walk: a value-yielding switch's short
 * `case X: e;` bodies stay glued. Same channel as the `ParenExpr` /
 * `ReturnExpr` ctors above. Statement-position `SwitchStmt` does NOT
 * carry the flag, so its bodies keep the `caseBody`-default break.
 */
@:peg
enum HxExpr {

	HexLit(v: HxHexLit);

	FloatLit(v: HxFloatLit);

	IntLit(v: HxIntLit);

	@:lit('true', 'false')
	BoolLit(v: Bool);

	@:lit('null')
	NullLit;

	DoubleStringExpr(v: HxDoubleStringLit);

	SingleStringExpr(v: HxInterpString);

	RegexLit(v: HxRegexLit);

	@:lead("${") @:trail('}')
	DollarBlockExpr(expr: HxExpr);

	@:lead("$") @:trail('}')
	DollarReifExpr(v: HxDollarReif);

	@:lead("$")
	DollarIdentExpr(name: HxIdentLit);

	@:trivia @:lead('[') @:trail(']') @:sep(',') @:fmt(trailingComma('trailingCommaArrays'), wrapRules('arrayLiteralWrap'),
		reflowSourceMultiline, bracketKindPad, arrayMatrixWrap, propagateExprPosition)
	ArrayExpr(elems: Array<HxExpr>);

	ObjectLit(lit: HxObjectLit);

	@:fmt(leftCurly('blockLeftCurly'), leftCurlyAnonFnOverride('anonFunctionLeftCurly'), emptyCurlyBreak('blockEmptyCurly'),
		rightCurly('blockRightCurly'), keepCurlyBlanks, clearExprPositionNonTail)
	@:lead('{') @:trail('}') @:trivia
	@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	BlockExpr(stmts: Array<HxStatement>);

	ThinParenLambdaExpr(lambda: HxThinParenLambda);

	ECheckTypeExpr(info: HxECheckType);

	@:wrap('(', ')') @:fmt(captureWrapOpenNewline, propagateExprPosition, expressionParenHardFlatten, switchWrapSpace)
	ParenExpr(inner: HxExpr);

	ParenLambdaExpr(lambda: HxParenLambda);

	@:kw('new')
	NewExpr(expr: HxNewExpr);

	@:kw('if') @:fmt(ifPolicy)
	IfExpr(stmt: HxIfExpr);

	@:kw('for') @:fmt(forPolicy)
	ForExpr(stmt: HxForExpr);

	@:kw('for') @:fmt(forPolicy)
	ForReifExpr(inner: HxForReif);

	@:kw('while') @:fmt(whilePolicy)
	WhileExpr(stmt: HxWhileExpr);

	@:kw('switch') @:fmt(switchPolicy, propagateExprPosition)
	SwitchExpr(stmt: HxSwitchStmt);

	@:kw('switch') @:fmt(switchPolicy, propagateExprPosition)
	SwitchExprBare(stmt: HxSwitchStmtBare);

	@:kw('try')
	TryExpr(stmt: HxTryCatchExpr);

	@:kw('untyped')
	UntypedExpr(operand: HxExpr);

	@:kw('untyped')
	UntypedAtom;

	@:kw('macro') @:lead(':') @:fmt(spaceBeforeLead)
	MacroTypeExpr(t: HxType);

	@:kw('macro')
	MacroClassExpr(v: HxMacroClass);

	@:kw('macro') @:fmt(clearExprPosition)
	MacroExpr(operand: HxExpr);

	@:kw('var')
	VarExpr(decl: HxVarDecl);

	@:kw('final')
	FinalExpr(decl: HxVarDecl);

	@:kw('cast') @:fmt(tightKw)
	TypedCastExpr(info: HxTypedCast);

	@:kw('cast') @:fmt(atomOperand, tightOnParenOperand('ParenExpr', 'ECheckTypeExpr'))
	CastExpr(operand: HxExpr);

	@:kw('return') @:fmt(propagateExprPosition)
	ReturnExpr(value: HxExpr);

	@:kw('return')
	VoidReturnExpr;

	@:kw('throw')
	ThrowExpr(value: HxExpr);

	@:kw('break')
	BreakExpr;

	@:kw('continue')
	ContinueExpr;

	@:kw('inline')
	InlineExpr(operand: HxExpr);

	@:kw('function')
	NamedFnExpr(decl: HxFnDecl);

	@:kw('function') @:fmt(anonFuncParens)
	FnExpr(fn: HxFnExpr);

	@:kw('#if') @:trail('#end')
	ConditionalExpr(inner: HxConditionalExpr);

	@:kw('#if') @:trail('#end')
	ConditionalArgs(inner: HxConditionalArgs);

	/**
	 * Token-splice fallback for `#if` regions no structural
	 * conditional can represent — see `HxCondSpliceExpr`.
	 */
	@:kw('#if')
	CondSpliceExpr(inner: HxCondSpliceExpr);

	/**
	 * POST-operand token-splice conditional — an infix tail spliced
	 * onto a complete operand: `A + B #if mobile - 120 #end` /
	 * `a.wrong || b.wrong #if !mobile || c.wrong #end` (live dogfood shapes). The raw fragment (condition
	 * + dangling operator run, `#end` swallowed — see
	 * `HxCondSpliceRaw`) binds tightest as a postfix on the operand;
	 * the writer re-emits it verbatim with single-space pads around
	 * the word-like `#if` op.
	 */
	@:postfix('#if') @:fmt(capturePostfixOpSpace)
	CondSpliceTail(operand: HxExpr, raw: HxCondSpliceRaw);

	MetaExpr(v: HxMetaExpr);

	IdentExpr(v: HxExprIdentLit);

	@:prefix('++')
	PreIncr(operand: HxExpr);

	@:prefix('--')
	PreDecr(operand: HxExpr);

	@:prefix('-')
	Neg(operand: HxExpr);

	@:prefix('!')
	Not(operand: HxExpr);

	@:prefix('~')
	BitNot(operand: HxExpr);

	@:prefix('...') @:fmt(tight)
	Spread(operand: HxExpr);

	@:postfix('.') @:fmt(methodChain('methodChainWrap'), captureChainNewline)
	FieldAccess(operand: HxExpr, field: HxFieldNameLit);

	@:postfix('?.')
	SafeFieldAccess(operand: HxExpr, field: HxFieldNameLit);

	@:postfix('!.')
	ForceFieldAccess(operand: HxExpr, field: HxFieldNameLit);

	@:postfix('[', ']') @:fmt(accessBrackets)
	IndexAccess(operand: HxExpr, index: HxExpr);

	@:postfix('(', ')') @:sep(',') @:fmt(trailingComma('trailingCommaArgs'), callParens, callParensInside, wrapRules('callParameterWrap'),
		methodChain('methodChainWrap'), propagateExprPosition, callArgChainNest, groupRestProbe)
	Call(operand: HxExpr, args: Array<HxExpr>);

	@:postfix('++')
	PostIncr(operand: HxExpr);

	@:postfix('--')
	PostDecr(operand: HxExpr);

	@:infix('*', 9) @:fmt(captureRhsTrail)
	Mul(left: HxExpr, right: HxExpr);

	@:infix('/', 9) @:fmt(captureRhsTrail)
	Div(left: HxExpr, right: HxExpr);

	@:infix('%', 9) @:fmt(captureRhsTrail)
	Mod(left: HxExpr, right: HxExpr);

	@:infix('+', 8) @:fmt(captureChainNewline)
	Add(left: HxExpr, right: HxExpr);

	@:infix('-', 8) @:fmt(captureChainNewline)
	Sub(left: HxExpr, right: HxExpr);

	@:infix('<<', 7) @:fmt(captureRhsTrail)
	Shl(left: HxExpr, right: HxExpr);

	@:infix('>>>', 7) @:fmt(captureRhsTrail)
	UShr(left: HxExpr, right: HxExpr);

	@:infix('>>', 7) @:fmt(captureRhsTrail)
	Shr(left: HxExpr, right: HxExpr);

	@:infix('|', 6) @:fmt(captureRhsTrail)
	BitOr(left: HxExpr, right: HxExpr);

	@:infix('&', 6) @:fmt(captureRhsTrail)
	BitAnd(left: HxExpr, right: HxExpr);

	@:infix('^', 6) @:fmt(captureRhsTrail)
	BitXor(left: HxExpr, right: HxExpr);

	@:infix('==', 5) @:fmt(captureRhsTrail)
	Eq(left: HxExpr, right: HxExpr);

	@:infix('!=', 5) @:fmt(captureRhsTrail)
	NotEq(left: HxExpr, right: HxExpr);

	@:infix('<=', 5) @:fmt(captureRhsTrail)
	LtEq(left: HxExpr, right: HxExpr);

	@:infix('>=', 5) @:fmt(captureRhsTrail)
	GtEq(left: HxExpr, right: HxExpr);

	@:infix('<', 5) @:fmt(captureRhsTrail)
	Lt(left: HxExpr, right: HxExpr);

	@:infix('>', 5) @:fmt(captureRhsTrail)
	Gt(left: HxExpr, right: HxExpr);

	@:infix('...', 5) @:fmt(intervalPolicy)
	Interval(left: HxExpr, right: HxExpr);

	@:infix('is', 5) @:fmt(captureRhsTrail)
	Is(left: HxExpr, right: HxType);

	@:infix('&&', 4) @:fmt(captureChainNewline)
	And(left: HxExpr, right: HxExpr);

	@:infix('||', 3) @:fmt(captureChainNewline)
	Or(left: HxExpr, right: HxExpr);

	@:infix('??', 2, 'Right') @:fmt(captureChainNewline)
	NullCoal(left: HxExpr, right: HxExpr);

	@:ternary('?', ':', 1)
	Ternary(cond: HxExpr, thenExpr: HxExpr, elseExpr: HxExpr);

	@:infix('in', 0)
	In(left: HxExpr, right: HxExpr);

	@:infix('=', 0, 'Right') @:fmt(propagateExprPosition)
	Assign(left: HxExpr, right: HxExpr);

	@:infix('+=', 0, 'Right') @:fmt(propagateExprPosition)
	AddAssign(left: HxExpr, right: HxExpr);

	@:infix('-=', 0, 'Right') @:fmt(propagateExprPosition)
	SubAssign(left: HxExpr, right: HxExpr);

	@:infix('*=', 0, 'Right') @:fmt(propagateExprPosition)
	MulAssign(left: HxExpr, right: HxExpr);

	@:infix('/=', 0, 'Right') @:fmt(propagateExprPosition)
	DivAssign(left: HxExpr, right: HxExpr);

	@:infix('%=', 0, 'Right') @:fmt(propagateExprPosition)
	ModAssign(left: HxExpr, right: HxExpr);

	@:infix('<<=', 0, 'Right') @:fmt(propagateExprPosition)
	ShlAssign(left: HxExpr, right: HxExpr);

	@:infix('>>>=', 0, 'Right') @:fmt(propagateExprPosition)
	UShrAssign(left: HxExpr, right: HxExpr);

	@:infix('>>=', 0, 'Right') @:fmt(propagateExprPosition)
	ShrAssign(left: HxExpr, right: HxExpr);

	@:infix('|=', 0, 'Right') @:fmt(propagateExprPosition)
	BitOrAssign(left: HxExpr, right: HxExpr);

	@:infix('&=', 0, 'Right') @:fmt(propagateExprPosition)
	BitAndAssign(left: HxExpr, right: HxExpr);

	@:infix('^=', 0, 'Right') @:fmt(propagateExprPosition)
	BitXorAssign(left: HxExpr, right: HxExpr);

	@:infix('??=', 0, 'Right') @:fmt(propagateExprPosition)
	NullCoalAssign(left: HxExpr, right: HxExpr);

	@:infix('&&=', 0, 'Right') @:fmt(propagateExprPosition)
	BoolAndAssign(left: HxExpr, right: HxExpr);

	@:infix('||=', 0, 'Right') @:fmt(propagateExprPosition)
	BoolOrAssign(left: HxExpr, right: HxExpr);

	@:infix('->', 0, 'Right') @:fmt(propagateExprPosition, propagateArrowLambdaBody, arrowBodyLineWrap)
	ThinArrow(left: HxExpr, right: HxExpr);

	@:infix('=>', 0, 'Right') @:fmt(propagateExprPosition)
	Arrow(left: HxExpr, right: HxExpr);

}
