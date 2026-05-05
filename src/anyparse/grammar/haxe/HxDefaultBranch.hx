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
 *
 * `@:fmt(bodyPolicy('caseBody', 'expressionCase'))` (ω-case-body-policy
 * + ω-case-body-keep + ω-expression-case-keep-default) mirrors
 * `HxCaseBranch.body` — single-stmt flat emission when the body has no
 * leading / orphan-trailing trivia AND either flag is `Same` (always
 * flatten) OR either flag is `Keep` and the source had the stmt on the
 * same line as `:` (`!Trivial<T>.newlineBefore` on the first element).
 * `caseBody` defaults to `Next`; `expressionCase` defaults to `Keep`,
 * so author-written `default: foo();` round-trips byte-identically.
 *
 * `@:fmt(flatChildOpt('A=B', ...))` (ω-expression-case-flat-fanout)
 * mirrors `HxCaseBranch.body` — when the flat gate fires, the body's
 * element is written with a `Reflect.copy(opt)` whose listed fields are
 * overridden by the named sibling fields, so nested control-flow inside
 * a flat default body picks expression-position policy. See
 * `HxCaseBranch.body`'s doc for the propagation contract.
 */
@:peg
typedef HxDefaultBranch = {
	@:lead(':') @:trivia @:tryparse @:fmt(
		nestBody, bodyPolicy('caseBody', 'expressionCase'),
		flatChildOpt('ifBody=expressionCase', 'elseBody=expressionCase', 'forBody=expressionCase')
	) var stmts:Array<HxStatement>;
};
