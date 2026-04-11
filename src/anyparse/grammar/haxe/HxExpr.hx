package anyparse.grammar.haxe;

/**
 * Haxe expression grammar — Pratt slice with parens and right-assoc
 * assignments on top of the expanded operator set.
 *
 * Six atom constructors plus sixteen binary-operator constructors
 * across six precedence levels. Atoms are the leaf shapes a single
 * call to `parseHxExprAtom` resolves; operator branches carry
 * `@:infix(op, prec)` (or `@:infix(op, prec, 'Right')`) metadata so
 * the Pratt strategy sees them and `Lowering` generates a
 * precedence-climbing loop wrapping the atom parser.
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
 *  - `IdentExpr` — bare identifier (`other`). **Must appear last**:
 *    the identifier regex is permissive and would otherwise match
 *    `null` / `true` / `false` as bare identifiers.
 *
 * **Operator branches** — all binary infix. Each `@:infix(op, prec)`
 * carries the operator literal and its precedence; higher precedence
 * binds tighter. The optional third argument `'Left'` / `'Right'`
 * selects associativity (default is left). Six precedence levels
 * are populated:
 *
 *  - prec 7 — `*` `/` `%` (multiplicative, left-assoc)
 *  - prec 6 — `+` `-` (additive, left-assoc)
 *  - prec 5 — `==` `!=` `<=` `>=` `<` `>` (comparison, left-assoc)
 *  - prec 4 — `&&` (logical and, left-assoc)
 *  - prec 3 — `||` (logical or, left-assoc)
 *  - prec 1 — `=` `+=` `-=` (assignment, **right-assoc**)
 *
 * Declaration order inside each precedence level puts longer literals
 * first (`<=` before `<`) for human readability. Correctness does NOT
 * depend on this order — `Lowering.lowerPrattLoop` sorts operators by
 * literal length descending before emitting the dispatch chain, so the
 * generated parser always attempts the longer prefix first regardless
 * of how the grammar author orders the branches. Without that sort,
 * input `a <= b` would parse as `Lt(a, <error>)` because the naive
 * `matchLit(ctx, "<")` consumes one character and strands the `=`.
 *
 * Precedence 2 is deliberately free for a future ternary / `??` /
 * `=>` slot decision — each of those is a separate concept the
 * corresponding slice will land. Prec 1 is claimed by assignments;
 * if ternary ultimately needs to sit below assignments in the Haxe
 * precedence table, that slice revisits the numbering (the exit
 * criterion for this decision).
 *
 * **Still deferred**: `*=` / `/=` / `%=` (same right-assoc concept,
 * next session), bitwise-assignments (`|= &= ^= <<= >>= >>>= ??=`,
 * blocked on bitwise/shift ops), ternary `? :`, `??`, `=>`, unary
 * prefix (`-x`, `!x`), postfix (`f()`, `o.x`, `a[i]`), bitwise
 * (`& | ^`), shifts (`<< >> >>>`), `new T(...)`. Each is a separate
 * concept a future Pratt slice addresses.
 */
@:peg
enum HxExpr {

	FloatLit(v:HxFloatLit);

	IntLit(v:HxIntLit);

	@:lit('true', 'false')
	BoolLit(v:Bool);

	@:lit('null')
	NullLit;

	@:wrap('(', ')')
	ParenExpr(inner:HxExpr);

	IdentExpr(v:HxIdentLit);

	@:infix('*', 7)
	Mul(left:HxExpr, right:HxExpr);

	@:infix('/', 7)
	Div(left:HxExpr, right:HxExpr);

	@:infix('%', 7)
	Mod(left:HxExpr, right:HxExpr);

	@:infix('+', 6)
	Add(left:HxExpr, right:HxExpr);

	@:infix('-', 6)
	Sub(left:HxExpr, right:HxExpr);

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

	@:infix('=', 1, 'Right')
	Assign(left:HxExpr, right:HxExpr);

	@:infix('+=', 1, 'Right')
	AddAssign(left:HxExpr, right:HxExpr);

	@:infix('-=', 1, 'Right')
	SubAssign(left:HxExpr, right:HxExpr);
}
