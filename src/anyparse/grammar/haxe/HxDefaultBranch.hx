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
 */
@:peg
typedef HxDefaultBranch = {
	@:lead(':') @:tryparse var stmts:Array<HxStatement>;
};
