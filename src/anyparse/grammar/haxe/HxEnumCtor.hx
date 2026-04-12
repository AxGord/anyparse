package anyparse.grammar.haxe;

/**
 * Grammar type for a single enum constructor inside an enum body.
 *
 * Two branches, tried in source order via `tryBranch` rollback:
 *
 *  - `ParamCtor` — `Name(param:Type, ...);` constructor with a
 *    parenthesised, comma-separated parameter list. Wraps
 *    `HxEnumCtorDecl` which reuses `HxParam` from function params.
 *    Tried first because `(` after the name disambiguates it from
 *    `SimpleCtor`. If `(` is missing, the sub-rule parse fails and
 *    tryBranch rolls back.
 *
 *  - `SimpleCtor` — `Name;` zero-argument constructor. Fallback
 *    when `ParamCtor` fails.
 *
 * Both branches carry `@:trail(';')` — the semicolon is always
 * present in Haxe enum declarations.
 */
@:peg
enum HxEnumCtor {
	@:trail(';')
	ParamCtor(decl:HxEnumCtorDecl);

	@:trail(';')
	SimpleCtor(name:HxIdentLit);
}
