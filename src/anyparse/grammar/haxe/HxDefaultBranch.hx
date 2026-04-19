package anyparse.grammar.haxe;

/**
 * Grammar for the `default:` branch body inside a switch statement.
 *
 * The `default` keyword is consumed at the enum-branch level
 * (`@:kw('default')` on the `DefaultBranch` ctor in `HxSwitchCase`).
 * This typedef describes the colon and body: the `@:lead(':')` on
 * the `stmts` field consumes the colon, then the statements follow.
 *
 * The body uses `@:tryparse` to force try-parse termination even
 * though `stmts` is the last (and only) field. Without `@:tryparse`,
 * the last-field heuristic in `emitStarFieldSteps` would select EOF
 * mode, which would attempt to consume past the next `case` /
 * `default` / `}` token. Try-parse terminates cleanly because none
 * of those tokens parse as an `HxStatement`.
 *
 * `@:fmt(nestBody)` makes the writer wrap the body Doc in an extra
 * indent level, so statements drop onto their own line below the
 * `default:` header at body-indent instead of inline.
 */
@:peg
typedef HxDefaultBranch = {
	@:lead(':') @:trivia @:tryparse @:fmt(nestBody) var stmts:Array<HxStatement>;
};
