package anyparse.grammar.haxe;

/**
 * Grammar for a single case inside a switch body.
 *
 * Two branches, tried in source order via `tryBranch` rollback:
 *
 *  - `CaseBranch` — `case pattern: body`. The `case` keyword is the
 *    commit point. The pattern and body are parsed by `HxCaseBranch`.
 *
 *  - `DefaultBranch` — `default: body`. The `default` keyword is the
 *    commit point. The colon and body are parsed by `HxDefaultBranch`
 *    (colon as `@:lead` on the `stmts` field, not as a branch trail,
 *    because the colon precedes the body content).
 *
 * The containing `Array<HxSwitchCase>` in `HxSwitchStmt` uses
 * close-peek termination on `}` — when the closing brace is reached,
 * neither `case` nor `default` matches and the loop terminates.
 */
@:peg
enum HxSwitchCase {
	@:kw('case')
	CaseBranch(branch:HxCaseBranch);

	@:kw('default')
	DefaultBranch(branch:HxDefaultBranch);
}
