package anyparse.macro;

#if macro
/**
 * Structural shape of one Alt enum branch, carrying the dispatch data
 * that branch's lowering needs — the SINGLE SOURCE that both
 * `Lowering.lowerEnumBranch` (which picks what to EMIT) and
 * `ParseDispatchLowering.branchFirstToken` (which picks what to GUARD on) switch
 * on.
 *
 * The two used to hold independent copies of the same predicate
 * chain, kept in step only by a comment saying they must be. That is
 * precisely the drift no oracle can catch: a classification that
 * disagrees with the emission silently skips a branch whose trial
 * would have MATCHED, and it does so only on grammars or inputs the
 * corpus never exercises — a byte-identical corpus dump, a green
 * suite and an A/B over real files all stay quiet. Routing both
 * through `ParseDispatchLowering.branchShape` turns that drift into a
 * non-exhaustive-switch COMPILE ERROR: add a constructor here and
 * neither side builds again until both have an arm for it.
 *
 * Constructor order mirrors the historical "Case N" numbering the
 * lowering comments use. `ParseDispatchLowering.branchShape` must test the shapes
 * in the SAME order the original chain did — the order is part of the
 * grammar contract, not an implementation detail (see `Prefix` and
 * `StarList` below, both of which must be decided before `KwRef`).
 */
enum BranchShape {

	/**
	 * Case 5 — `@:prefix('-')` on a ctor with a single `Ref` child
	 * referencing the same enum. Emits `skipWs; expectLit(op)`, then
	 * recurses for the operand.
	 *
	 * MUST be tested BEFORE `KwRef`: a prefix branch structurally
	 * matches "single `Ref` child, no `@:lit`", and the `KwRef`
	 * lowering would emit a body with no `expectLit` at all — an
	 * unguarded recursive call that consumes nothing and loops
	 * forever.
	 *
	 * `op` is symbolic by construction: `lowerPrefixBranch`
	 * fatal-errors on a word-like operator, because `expectLit`
	 * carries no word boundary and would accept the `not` of `notx`.
	 * To support word-like prefix operators, route this case through
	 * `expectKw` the way `SingleLit` / `MultiLit` dispatch on
	 * `endsWithWordChar`, and drop that fatal error.
	 *
	 * The operand recursion deliberately targets `recurseFnName` — the
	 * ATOM function for Pratt enums, not the Pratt loop: a prefix's
	 * operand is a single atom (possibly another prefix), not a whole
	 * expression. `-x * 2` parses as `Mul(Neg(x), 2)` because the atom
	 * handed back to the outer Pratt loop is already `Neg(x)`, and the
	 * loop then picks up `* 2` around it.
	 */
	Prefix(op: String);

	/**
	 * Case 0 — zero-arg ctor with `@:kw`, no `@:lit`. Parallel to
	 * `SingleLit`, but driven by the Kw strategy annotation rather than
	 * the Lit strategy. Emits `skipWs; expectKw(kw)`, with the
	 * word-boundary check. Used by modifier enums whose every ctor is a
	 * bare keyword.
	 *
	 * An optional `@:trail` literal (`@:kw('return') @:trail(';')
	 * VoidReturnStmt`, D48) is emitted unconditionally after the
	 * keyword, so it never affects the first token.
	 */
	KwZeroArg(kw: String);

	/**
	 * Case 1 — zero-arg ctor with a single `@:lit`. The lowering picks
	 * `expectKw` when the literal ends with a word character (`null`,
	 * `true`, `default`), so a partial match on the prefix of a longer
	 * identifier (`nullable`, `trueish`) is rejected and the trial
	 * rolls back to the next branch; symbolic literals (`;`, `=`, `{`)
	 * route through plain `expectLit`, since a word boundary after
	 * them would falsely reject sequences like `;foo`.
	 */
	SingleLit(lit: String);

	/**
	 * Case 2 — single-arg ctor with a multi-literal `@:lit`, the
	 * literals mapping to ident values of the field type. The lowering
	 * emits one `matchKw` / `matchLit` attempt per literal and takes
	 * whichever hits first, so the branch's first-token set is the
	 * WHOLE literal set. `matchKw` vs `matchLit` is decided once from
	 * `endsWithWordChar(lits[0])`; a set mixing word-like and symbolic
	 * literals is rejected at macro time, since its dispatch semantics
	 * would be inconsistent.
	 */
	MultiLit(lits: Array<String>);

	/**
	 * Case 4 — single-arg ctor wrapping a `Star` in `@:lead`/`@:trail`,
	 * with optional `@:sep` / `@:sepAlt`. EVERY variant of the
	 * lowering — plain, `@:sep`, `@:sepAlt`, block-ended and trivia —
	 * opens with `skipWs; expectLit(lead)`, so the lead literal
	 * genuinely is the first consumed token in all of them (the trivia
	 * variant's `collectTrailingFull` runs only AFTER the lead).
	 *
	 * The no-`@:sep` variant terminates its loop by PEEKING at the
	 * close delimiter rather than consuming a separator between items.
	 *
	 * MUST be tested BEFORE `KwRef`, which would otherwise claim the
	 * same single-child shape.
	 */
	StarList(lead: String, trail: String, sep: Null<String>, sepAlt: Null<String>);

	/**
	 * Case 3 — single-arg ctor wrapping a `Ref`, with an optional
	 * `@:kw` keyword and/or an optional `@:lead` / `@:wrap` literal
	 * (both map to the same lead-text annotation). When both are
	 * present the KEYWORD is emitted first, word-boundary checked, and
	 * only then the lead literal — so `kw` decides the first token
	 * whenever it is non-null.
	 *
	 * `KwRef(null, null)` is the bare-`Ref` catch-all (such as
	 * `HxStatement.ExprStmt`): it commits nothing before recursing, so
	 * it has no first token and stays unguarded.
	 *
	 * No separator loop here — that is `StarList`'s domain. NOTE: the
	 * comment this text replaces claimed only ONE of the keyword and
	 * the lead literal is ever emitted per branch. That has not been
	 * true since `@:kw` and `@:wrap` were allowed to compose on the
	 * same single-`Ref` branch; `appendKwRefLeadSteps` emits both, in
	 * that order.
	 */
	KwRef(kw: Null<String>, lead: Null<String>);

	/**
	 * No supported shape. `lowerEnumBranch` halts the build on this;
	 * `branchFirstToken` maps it to `BranchFirstToken.Unknown` so the
	 * classifier stays total.
	 */
	Unsupported;

}
#end
