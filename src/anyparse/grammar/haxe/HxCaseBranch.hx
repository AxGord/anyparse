package anyparse.grammar.haxe;

/**
 * Grammar for a single `case pattern: body` branch inside a switch.
 *
 * The `case` keyword is consumed at the enum-branch level
 * (`@:kw('case')` on the `CaseBranch` ctor in `HxSwitchCase`).
 * This typedef describes the remainder: a pattern expression
 * followed by a colon, then zero or more body statements.
 *
 * Patterns are parsed as `HxExpr` — identifiers, literals, and
 * constructor-like patterns (`Foo(x, y)` parses as a `Call`
 * expression) all work without new grammar types. Full pattern
 * matching (extractors, guards, OR patterns) is future work.
 *
 * The body uses `@:tryparse` to force try-parse termination on the
 * last field (D49). The try-parse loop breaks when the next token
 * is `case`, `default`, or `}` — none of which parse as an
 * `HxStatement`.
 *
 * `@:fmt(nestBody)` makes the writer wrap the body Doc in an extra
 * indent level, so statements drop onto their own line below the
 * `case pattern:` header at body-indent instead of inline.
 */
@:peg
typedef HxCaseBranch = {
	@:trail(':') var pattern:HxExpr;
	@:trivia @:tryparse @:fmt(nestBody) var body:Array<HxStatement>;
};
