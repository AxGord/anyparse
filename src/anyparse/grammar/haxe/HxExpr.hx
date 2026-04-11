package anyparse.grammar.haxe;

/**
 * Haxe expression grammar — Pratt slice.
 *
 * Five atom constructors and four binary-operator constructors. The
 * atoms are literal values that a single call to `parseHxExprAtom`
 * resolves; the operator branches carry `@:infix` metadata so the
 * Pratt strategy sees them and `Lowering` generates a precedence-
 * climbing loop that wraps the atom parser.
 *
 * **Atom branches** — all leaves, no operators:
 *
 *  - `FloatLit` — decimal with mandatory fractional part (`3.14`,
 *    `1.0e-3`). **Must appear before `IntLit`**: the enum-branch
 *    try-loop iterates in source order, and `3.14` has to be
 *    matched as one float, not as `IntLit(3)` followed by stray
 *    `.14`. A bare `42` fails the float regex on the missing `.`
 *    and rolls back to `IntLit`.
 *  - `IntLit` — positive integer (`42`).
 *  - `BoolLit` — `true` / `false`. The `@:lit` multi-literal case
 *    in `Lowering` now emits `matchKw` (word-boundary aware) rather
 *    than `matchLit`, so `var x = trueish;` no longer eagerly
 *    consumes `true` and leaves stray `ish`.
 *  - `NullLit` — `null`. Same word-boundary treatment via
 *    `expectKw` in the single-`@:lit` zero-arg case.
 *  - `IdentExpr` — bare identifier (`other`). **Must appear last**:
 *    the identifier regex is permissive and would otherwise match
 *    `null` / `true` / `false` as bare identifiers.
 *
 * **Operator branches** — all binary infix, left-associative. The
 * `@:infix` metadata carries the operator literal and its precedence;
 * higher precedence binds tighter. Multiplicative `*` and `/` are at
 * precedence 7, additive `+` and `-` at 6, mirroring Haxe's standard
 * operator table.
 *
 *  - `Add`, `Sub` at prec 6
 *  - `Mul`, `Div` at prec 7
 *
 * Associativity is left-only in this slice. Right-associative
 * operators (`=`, `??`), unary prefix (`-x`, `!x`), function calls,
 * field access, parenthesised groups, and the remaining binary
 * operators (`==`, `!=`, `<`, `<=`, `&&`, `||`, `|`, `&`, `^`, `<<`,
 * `>>`, `>>>`, `%`, `...`, `=>`) are deferred to later Pratt slices.
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

	@:infix('+', 6)
	Add(left:HxExpr, right:HxExpr);

	@:infix('-', 6)
	Sub(left:HxExpr, right:HxExpr);

	@:infix('*', 7)
	Mul(left:HxExpr, right:HxExpr);

	@:infix('/', 7)
	Div(left:HxExpr, right:HxExpr);
}
