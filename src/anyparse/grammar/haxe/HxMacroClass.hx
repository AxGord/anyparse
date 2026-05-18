package anyparse.grammar.haxe;

/**
 * Payload of a `macro class` reification expression
 * (`HxExpr.MacroClassExpr`).
 *
 * The `macro` keyword is consumed at the enclosing `HxExpr.MacroClassExpr`
 * ctor via `@:kw('macro')` — this typedef describes the remainder:
 * the `class` keyword + optional name (delegated to `HxMacroClassHead`,
 * which owns the always-consume-`class` / optional-name disambiguation)
 * followed by a brace-delimited member list.
 *
 * `MacroClassExpr` must be declared on `HxExpr` BEFORE `MacroExpr`
 * (`@:kw('macro') MacroExpr(operand:HxExpr)`): with `macro class`
 * tried first, `MacroExpr` never gets to attempt parsing `class { … }`
 * as an expression operand (which would fail). It is declared AFTER
 * `MacroTypeExpr` (`macro :`) since that form is disjoint.
 *
 * `members` is a separator-less close-peek `Star`, byte-identical in
 * parse behaviour to `HxClassDecl.members` (`@:lead('{') @:trail('}')
 * @:trivia` with no `@:sep`) — each `HxMemberDecl` self-terminates
 * via its own `;` / `{}` tail and the loop ends on the closing `}`.
 * The `@:fmt(…)` formatting knobs `HxClassDecl.members` carries are
 * intentionally omitted: they only shape writer output, never parsing.
 * The default member layout is acceptable for a first implementation
 * (newly-parsing fixtures may land in `fail` rather than `pass` via
 * the established deferred-byte-reemit caveat; the hard invariant is
 * zero byte-regression on already-passing fixtures).
 *
 * `@:trivia` on `members` makes `HxMacroClass` transitively
 * trivia-bearing; the paired `HxMacroClassT` is synthesised
 * automatically by `TriviaTypeSynth` (no manual registration), the
 * same as `HxFnExpr` / `HxClassDecl`.
 */
@:peg
typedef HxMacroClass = {
	var head:HxMacroClassHead;
	@:lead('{') @:trail('}') @:trivia var members:Array<HxMemberDecl>;
}
