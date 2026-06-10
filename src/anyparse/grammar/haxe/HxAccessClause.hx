package anyparse.grammar.haxe;

/**
 * Property accessor clause on a Haxe `var`/`final` member —
 * the parenthesised `(read, write)` pair, e.g. `(get, set)`,
 * `(default, null)`, `(get, never)`, or method-name accessors
 * `(getFoo, setFoo)`.
 *
 * Modelled as the proven `Array + @:sep + @:trail` inner shape from
 * `HxNewExpr.args`: the opening `(` is the parent's optional
 * commit-point (`HxVarDecl.access` carries `@:lead('(')`), entries are
 * `,`-separated, and the closing `)` is consumed by `@:trail`.
 *
 * Each entry is an `HxIdentLit` — the existing identifier terminal
 * covers every accessor keyword (`get`/`set`/`never`/`default`/`null`/
 * `dynamic`) as well as custom method names without special-casing.
 *
 * The parser is intentionally permissive on arity: it accepts one or
 * more identifiers rather than enforcing Haxe's exactly-two rule.
 * Semantic policing belongs to a later analysis pass, consistent with
 * the `HxHeritageClause` / `HxDecl` philosophy.
 */
@:peg
typedef HxAccessClause = {
	@:sep(',') @:trail(')') var ids: Array<HxIdentLit>;
};
