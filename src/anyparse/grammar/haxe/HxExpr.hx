package anyparse.grammar.haxe;

/**
 * Haxe expression grammar — Pratt slice with expanded operator set.
 *
 * Five atom constructors plus thirteen binary-operator constructors
 * across five precedence levels. Atoms are literal values a single
 * call to `parseHxExprAtom` resolves; operator branches carry
 * `@:infix(op, prec)` metadata so the Pratt strategy sees them and
 * `Lowering` generates a precedence-climbing loop wrapping the atom
 * parser.
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
 *  - `IdentExpr` — bare identifier (`other`). **Must appear last**:
 *    the identifier regex is permissive and would otherwise match
 *    `null` / `true` / `false` as bare identifiers.
 *
 * **Operator branches** — all binary infix, left-associative. Each
 * `@:infix(op, prec)` carries the operator literal and its precedence;
 * higher precedence binds tighter. Five levels are populated:
 *
 *  - prec 7 — `*` `/` `%` (multiplicative)
 *  - prec 6 — `+` `-` (additive)
 *  - prec 5 — `==` `!=` `<=` `>=` `<` `>` (comparison)
 *  - prec 4 — `&&` (logical and)
 *  - prec 3 — `||` (logical or)
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
 * Precedences 2 and 1 are intentionally left free for future right-
 * associative operators (`??` at 2, ternary at 1) so adding them will
 * not require renumbering the current set. `minPrec` defaults to 0
 * at the outer caller, so every operator at prec >= 1 is always
 * reachable.
 *
 * **Still deferred**: right-associative operators (`=`, `+=`, `??`,
 * `=>`, `? :`), unary prefix (`-x`, `!x`), postfix (`f()`, `o.x`,
 * `a[i]`), parenthesised groups `(a + b)`, bitwise (`& | ^`), shifts
 * (`<< >> >>>`), `new T(...)`. Each is a separate concept the next
 * Pratt slice(s) will address.
 */
@:peg
enum HxExpr {

	FloatLit(v:HxFloatLit);

	IntLit(v:HxIntLit);

	@:lit('true', 'false')
	BoolLit(v:Bool);

	@:lit('null')
	NullLit;

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
}
