package anyparse.grammar.haxe;

/**
 * Haxe expression atom grammar — the atom-only slice.
 *
 * Four constructors, all leaves (no operators, no calls, no field
 * access). They cover the literal atoms that a Pratt expression
 * parser will eventually wrap in precedence-driven operator nodes:
 *
 *  - `IntLit` — positive integer literal (`42`)
 *  - `BoolLit` — `true` / `false`
 *  - `NullLit` — `null`
 *  - `IdentExpr` — bare identifier (`other`)
 *
 * `FloatLit` and `StringLit` are deliberately deferred. `FloatLit`
 * shares an `IntLit` prefix (`3` of `3.14`) and wants a branch-
 * ordering / lookahead fix that belongs with the Pratt slice.
 * `StringLit` wants real Haxe escape semantics (different from JSON)
 * and should ride with a format-contributed decoder table.
 *
 * **Branch order matters.** The enum-branch try-loop in the generated
 * parser iterates children in source order. `NullLit` and `BoolLit`
 * must appear before `IdentExpr`, otherwise `IdentExpr` eagerly
 * matches `null` / `true` / `false` as bare identifiers. `IntLit`
 * is kept at the top because it is unambiguous with the others
 * (digits never start a keyword or an identifier).
 *
 * **Known debt:** word-boundary enforcement for `BoolLit` / `NullLit`
 * is deferred. Multi-`@:lit` and zero-arg `@:lit` currently emit
 * bare `matchLit` without a trailing word-boundary check, so
 * `trueish` would partial-match `true` and leave `ish`. This is
 * acceptable for the current test corpus; close when a real
 * collision appears (see known debt #7 in session_state.md).
 */
@:peg
enum HxExpr {

	IntLit(v:HxIntLit);

	@:lit('true', 'false')
	BoolLit(v:Bool);

	@:lit('null')
	NullLit;

	IdentExpr(v:HxIdentLit);
}
