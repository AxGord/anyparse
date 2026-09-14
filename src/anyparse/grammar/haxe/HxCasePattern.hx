package anyparse.grammar.haxe;

/**
 * One pattern element inside a `case` pattern list, optionally carrying a guard
 * (`case P if (cond):`).
 *
 * `expr` is the pattern body — the `HxCasePatternBody` Alt-enum split between the Haxe
 * pattern-only `case var <ident>:` capture (`Capture(name:HxVarNameLit)`) and the regular
 * pattern expression catch-all (`Plain(expr:HxExpr)`). Splitting the body out of bare `HxExpr`
 * keeps the capture form from routing through `HxExpr.VarExpr`, whose `HxVarDecl` would
 * otherwise commit the type-hint `@:optional @:lead(':')` peek on the case-element terminator
 * `:` and fail parsing the statement body as an `HxType`. See `HxCasePatternBody` for the
 * parse order and why the inner `Pattern(var foo, var bar)` form still flows through `Plain`.
 *
 * `guard` is the optional `if (cond)` clause: `@:optional @:kw('if')`, the shape of
 * `HxIfStmt.elseBody` / `HxIfExpr.elseBranch` — a word-like keyword lead, so `@:kw`
 * (word-boundary `matchKw`, D47) not `@:lead` (raw `matchLit`): `case ify:` must NOT be read
 * as guard `if y`. When present the generic optional-Ref keyword writer path emits
 * ` if (cond)`; absent (the peek fails on `:` / `,` / a non-`if` token) leaves it null.
 *
 * Haxe binds a single guard to the whole pattern list (`case A, B if (g):`), so in valid
 * source the guard only ever appears after the last element — it attaches to the last parsed
 * `HxCasePattern` and round-trips byte-identically. The grammar also accepts a guard mid-list
 * (`case A if (x), B:`), which is not valid Haxe; over-acceptance is consistent with
 * anyparse's permissive-parser stance.
 *
 * Element-wrap rationale: `HxCaseBranch.patterns` stays `@:sep(',') @:trail(':')` — only the
 * element type widens (the K3 element-widening precedent), which sidesteps the `Lowering` bans
 * a direct reshape would hit (a `@:sep` Star requires an explicit `@:trail`; `@:optional`
 * combined with `@:trail` on a Ref is deferred). `HxExpr` has no infix or postfix `:` (only
 * the ternary `?:`) and `,` is not a binary operator, so the guard expression stops cleanly
 * at `:` / `,` — the property the pattern list itself relies on.
 */
@:peg
typedef HxCasePattern = {
	// `@:fmt(suppressCallRestProbe)` (omega-call-grouprestprobe-subposition) sets
	// `opt._suppressCallRestProbe = true` on the pattern-body subtree so a `Call`
	// ctor pattern (`Nest(_, _)` in `case Nest(_, _) | Concat(_):`) skips the
	// `groupRestProbe` rest-of-line fit bias -- the fork breaks the `|` (BitOr)
	// chain, not the ctor args. Not applied to `guard` (a genuine
	// expression-position condition where calls should wrap normally).
	//
	// `@:fmt(suppressPatternRestProbe)` (ω-pattern-rest-probe) widens that from
	// the top-level ctor to the WHOLE pattern subtree. The call flag alone does
	// not reach an object-literal pattern (`{ expr: ENew(tp, _) }` carries an
	// ungated `groupRestProbe` of its own, and its element arm CLEARS the call
	// flag for the field values), so the pattern was charged the trailing
	// guard's whole flat width and broke to make room for a condition that can
	// wrap perfectly well on its own. A pattern is a matching shape, not a
	// value: it never owns the line's overflow, so the guard breaks instead.
	// Also not applied to `guard`, for the same reason as above.
	@:fmt(suppressCallRestProbe, suppressComplexItems, suppressPatternRestProbe) var expr: HxCasePatternBody;
	@:optional @:kw('if') var guard: Null<HxExpr>;
};
