package anyparse.grammar.haxe;

/**
 * Haxe expression grammar — ternary and null-coalescing operators on top
 * of the postfix + unary-prefix slices.
 *
 * Eight atom constructors plus three unary-prefix constructors plus three
 * postfix constructors (field access, index access, call) plus one
 * ternary operator plus thirty-three binary-operator constructors
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
 *  - `ParenExpr` — parenthesised expression `(inner)`. The
 *    `@:wrap('(', ')')` metadata is handled by the `Lit` strategy,
 *    which writes `lit.leadText = '('` and `lit.trailText = ')'`.
 *    `Lowering.lowerEnumBranch` Case 3 (single-`Ref` wrapping) reads
 *    both and emits the `expectLit('(') → parseHxExpr → expectLit(')')`
 *    sequence — no Lowering-level change was needed to support
 *    parens. The inner call re-enters `parseHxExpr` at `minPrec = 0`
 *    (default), so parens fully reset precedence and any operator
 *    is allowed inside the group.
 *  - `DoubleStringExpr` — double-quoted string literal (`"hello"`).
 *    Escape sequences (`\"`, `\\`, `\n`, `\r`, `\t`) decoded via
 *    `HxStringDecoder.decode` at runtime. `@:decode` metadata on the
 *    terminal abstract names the decoder function — a new mechanism
 *    (slice ν₁) that generalises the closed decoder table in
 *    `Lowering.lowerTerminal`.
 *  - `SingleStringExpr` — single-quoted string literal (`'hello'`).
 *    Same escape handling as double-quoted, plus `\'`. Interpolation
 *    (`$var`, `${expr}`) deferred to a later slice.
 *  - `NewExpr` — `new T(args)` constructor call. The `new` keyword
 *    is the commit point (`@:kw('new')`); the type name and argument
 *    list are parsed by `HxNewExpr`. Must appear before `IdentExpr`
 *    so `new` is not consumed as an identifier.
 *  - `IdentExpr` — bare identifier (`other`). **Must appear last**
 *    among the pure atom branches: the identifier regex is permissive
 *    and would otherwise match `null` / `true` / `false` as bare
 *    identifiers.
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
 *    an `HxIdentLit` (the terminal identifier rule), so the field
 *    name ends up in the ctor as a single identifier string. No
 *    module path or type parameter syntax yet.
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
 *  - prec 5 — `==` `!=` `<=` `>=` `<` `>` (comparison, left-assoc)
 *  - prec 4 — `&&` (logical and, left-assoc)
 *  - prec 3 — `||` (logical or, left-assoc)
 *  - prec 2 — `??` (null-coalescing, **right-assoc**)
 *  - prec 1 — `? :` (ternary, via `@:ternary`)
 *  - prec 0 — `=` `+=` `-=` `*=` `/=` `%=` `<<=` `>>=` `>>>=` `|=`
 *    `&=` `^=` `??=` (assignment, **right-assoc**)
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
 * **Still deferred**: `=>` — context-dependent (lambda, map literal,
 * switch case), addressed in a future slice.
 */
@:peg
enum HxExpr {

	FloatLit(v:HxFloatLit);

	IntLit(v:HxIntLit);

	@:lit('true', 'false')
	BoolLit(v:Bool);

	@:lit('null')
	NullLit;

	DoubleStringExpr(v:HxDoubleStringLit);

	SingleStringExpr(v:HxSingleStringLit);

	@:wrap('(', ')')
	ParenExpr(inner:HxExpr);

	@:kw('new')
	NewExpr(expr:HxNewExpr);

	IdentExpr(v:HxIdentLit);

	@:prefix('-')
	Neg(operand:HxExpr);

	@:prefix('!')
	Not(operand:HxExpr);

	@:prefix('~')
	BitNot(operand:HxExpr);

	@:postfix('.')
	FieldAccess(operand:HxExpr, field:HxIdentLit);

	@:postfix('[', ']')
	IndexAccess(operand:HxExpr, index:HxExpr);

	@:postfix('(', ')') @:sep(',')
	Call(operand:HxExpr, args:Array<HxExpr>);

	@:infix('*', 9)
	Mul(left:HxExpr, right:HxExpr);

	@:infix('/', 9)
	Div(left:HxExpr, right:HxExpr);

	@:infix('%', 9)
	Mod(left:HxExpr, right:HxExpr);

	@:infix('+', 8)
	Add(left:HxExpr, right:HxExpr);

	@:infix('-', 8)
	Sub(left:HxExpr, right:HxExpr);

	@:infix('<<', 7)
	Shl(left:HxExpr, right:HxExpr);

	@:infix('>>>', 7)
	UShr(left:HxExpr, right:HxExpr);

	@:infix('>>', 7)
	Shr(left:HxExpr, right:HxExpr);

	@:infix('|', 6)
	BitOr(left:HxExpr, right:HxExpr);

	@:infix('&', 6)
	BitAnd(left:HxExpr, right:HxExpr);

	@:infix('^', 6)
	BitXor(left:HxExpr, right:HxExpr);

	@:infix('==', 5)
	Eq(left:HxExpr, right:HxExpr);

	@:infix('!=', 5)
	NotEq(left:HxExpr, right:HxExpr);

	@:infix('<=', 5)
	LtEq(left:HxExpr, right:HxExpr);

	@:infix('>=', 5)
	GtEq(left:HxExpr, right:HxExpr);

	@:infix('<', 5)
	Lt(left:HxExpr, right:HxExpr);

	@:infix('>', 5)
	Gt(left:HxExpr, right:HxExpr);

	@:infix('&&', 4)
	And(left:HxExpr, right:HxExpr);

	@:infix('||', 3)
	Or(left:HxExpr, right:HxExpr);

	@:infix('??', 2, 'Right')
	NullCoal(left:HxExpr, right:HxExpr);

	@:ternary('?', ':', 1)
	Ternary(cond:HxExpr, thenExpr:HxExpr, elseExpr:HxExpr);

	@:infix('=', 0, 'Right')
	Assign(left:HxExpr, right:HxExpr);

	@:infix('+=', 0, 'Right')
	AddAssign(left:HxExpr, right:HxExpr);

	@:infix('-=', 0, 'Right')
	SubAssign(left:HxExpr, right:HxExpr);

	@:infix('*=', 0, 'Right')
	MulAssign(left:HxExpr, right:HxExpr);

	@:infix('/=', 0, 'Right')
	DivAssign(left:HxExpr, right:HxExpr);

	@:infix('%=', 0, 'Right')
	ModAssign(left:HxExpr, right:HxExpr);

	@:infix('<<=', 0, 'Right')
	ShlAssign(left:HxExpr, right:HxExpr);

	@:infix('>>>=', 0, 'Right')
	UShrAssign(left:HxExpr, right:HxExpr);

	@:infix('>>=', 0, 'Right')
	ShrAssign(left:HxExpr, right:HxExpr);

	@:infix('|=', 0, 'Right')
	BitOrAssign(left:HxExpr, right:HxExpr);

	@:infix('&=', 0, 'Right')
	BitAndAssign(left:HxExpr, right:HxExpr);

	@:infix('^=', 0, 'Right')
	BitXorAssign(left:HxExpr, right:HxExpr);

	@:infix('??=', 0, 'Right')
	NullCoalAssign(left:HxExpr, right:HxExpr);
}
