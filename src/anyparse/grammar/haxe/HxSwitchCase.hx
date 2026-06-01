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
 *
 * `@:fmt(forwardNewlineForBody)` on `CaseBranch` (slice
 * ω-casepattern-keep) tells `Lowering`'s Case 3 to OMIT the post-`case`
 * `skipWs(ctx)` so the inner `HxCaseBranch.patterns` first-field
 * `collectTrivia` scans the `case`→pattern gap itself and captures
 * `newlineBefore` onto the synth `patternsBeforeNewline:Bool` slot.
 * Pairs with field-level `@:fmt(beforeNewlineSlotFirst)` on
 * `HxCaseBranch.patterns` (the inner struct's first field). Mirrors the
 * `HxStatement.TryCatchStmt` + `HxTryCatchStmt.body` pairing already
 * wired through this channel — the only difference is the inner first
 * field is a `@:sep(',') @:trail(':')` Star, not a bare Ref. Read by
 * the writer's struct-Star emit under `opt.leftCurly == Next` to
 * reproduce the author's `case\n\t{pattern}` source break verbatim
 * (fork's `leftCurly: both` puts a line-end before the pattern's
 * object-literal `{`). Byte-inert for `leftCurly` Same and for the
 * same-line source shape (`case {pattern}` stays glued).
 *
 * `@:fmt(deferKwSpace)` emits the `case ` trailing space as a deferred
 * `_dop(' ')` (OptSpace) instead of a hard `_dt('case ')`. The renderer
 * flushes it as a real space when the pattern stays inline (`case
 * {pattern}` — byte-identical to pre-slice) but DROPS it when the
 * pattern Doc opens with the keep-mode break hardline (`case\n\t…`,
 * avoiding a spurious trailing space before the newline). Mirrors the
 * `HxStatement.VarStmt` / `FinalStmt` deferred-kw-space split.
 */
@:peg
enum HxSwitchCase {
	@:kw('case') @:fmt(forwardNewlineForBody, deferKwSpace)
	CaseBranch(branch:HxCaseBranch);

	@:kw('default')
	DefaultBranch(branch:HxDefaultBranch);
}
