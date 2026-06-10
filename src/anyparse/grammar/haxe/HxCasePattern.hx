package anyparse.grammar.haxe;

/**
 * One pattern element inside a `case` pattern list, optionally
 * carrying a guard (`case P if (cond):`).
 *
 * `expr` is the pattern body — the `HxCasePatternBody` Alt-enum split
 * between the Haxe pattern-only `case var <ident>:` capture
 * (`Capture(name:HxVarNameLit)`, Slice 34) and the regular pattern
 * expression catch-all (`Plain(expr:HxExpr)`). Splitting the body
 * out of bare `HxExpr` keeps the capture form from routing through
 * `HxExpr.VarExpr`, whose `HxVarDecl` would otherwise commit the
 * type-hint `@:optional @:lead(':')` peek on the case-element
 * terminator `:` and fail trying to parse the statement body as an
 * `HxType`. See `HxCasePatternBody` for the parse-order rationale and
 * why the inner `Pattern(var foo, var bar)` form still flows through
 * the Plain path unchanged.
 *
 * `guard` is the optional `if (cond)` clause: `@:optional @:kw('if')`,
 * the exact shape of `HxIfStmt.elseBody` / `HxIfExpr.elseBranch`
 * (`@:optional @:kw('else') var x:Null<…>`) — a word-like keyword
 * lead, so `@:kw` (word-boundary `matchKw`, D47) not `@:lead`
 * (raw `matchLit`): `case ify:` must NOT be read as guard `if y`.
 * When present the generic optional-Ref keyword writer path emits
 * ` if (cond)` (the same path that emits ` else …` for the
 * precedents above); absent (the `if` keyword peek fails on `:` / `,`
 * / a non-`if` token) leaves it null.
 *
 * Haxe binds a single guard to the whole pattern list
 * (`case A, B if (g):`), so in valid source the guard only ever
 * appears after the last list element — it attaches to the last
 * parsed `HxCasePattern` and round-trips byte-identically. The
 * grammar also accepts a guard mid-list (`case A if (x), B:`), which
 * is not valid Haxe; over-acceptance of malformed input is consistent
 * with anyparse's permissive-parser stance (it parses and round-trips
 * faithfully, it is not a validating compiler frontend).
 *
 * Element-wrap rationale: `HxCaseBranch.patterns` stays
 * `@:sep(',') @:trail(':')` unchanged — only the element type widens
 * (the K3 element-widening precedent). This sidesteps the `Lowering`
 * bans a direct reshape of `HxCaseBranch` would hit (a `@:sep` Star
 * requires an explicit `@:trail`; `@:optional` combined with
 * `@:trail` on a Ref is deferred). `HxExpr` has no infix or postfix
 * `:` (only the ternary `?:`) and `,` is not a binary operator, so
 * the guard expression parses `(cond)` and stops cleanly at `:` / `,`
 * — the same property the pattern list itself already relies on.
 */
@:peg
typedef HxCasePattern = {
	var expr: HxCasePatternBody;
	@:optional @:kw('if') var guard: Null<HxExpr>;
};
