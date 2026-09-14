package anyparse.grammar.haxe;

/**
 * Grammar for a single case inside a switch body.
 *
 * Two branches, tried in source order via `tryBranch` rollback: `CaseBranch` — `case pattern:
 * body`, the `case` keyword is the commit point and `HxCaseBranch` parses the rest; and
 * `DefaultBranch` — `default: body`, the `default` keyword is the commit point and
 * `HxDefaultBranch` parses the colon and body (colon as `@:lead` on `stmts`, because it
 * precedes the body content). The containing `Array<HxSwitchCase>` in `HxSwitchStmt`
 * terminates on a close-peek of `}`, where neither keyword matches.
 *
 * `@:fmt(forwardNewlineForBody)` on `CaseBranch` (ω-casepattern-keep) tells `Lowering`'s
 * Case 3 to OMIT the post-`case` `skipWs(ctx)` so the inner `HxCaseBranch.patterns`
 * first-field `collectTrivia` scans the `case`→pattern gap itself and captures `newlineBefore`
 * onto the synth `patternsBeforeNewline:Bool` slot; pairs with field-level
 * `@:fmt(beforeNewlineSlotFirst)` on `HxCaseBranch.patterns`, the same channel
 * `HxStatement.TryCatchStmt` + `HxTryCatchStmt.body` use. The writer's struct-Star emit reads
 * it under `opt.leftCurly == Next` to reproduce the author's `case\n\t{pattern}` break
 * verbatim; byte-inert for `leftCurly` Same and for the same-line shape.
 *
 * `@:fmt(deferKwSpace)` emits the `case ` trailing space as a deferred `_dop(' ')` (OptSpace)
 * instead of a hard `_dt('case ')`: the renderer flushes it as a real space when the pattern
 * stays inline but DROPS it when the pattern Doc opens with the keep-mode break hardline, so
 * no trailing space precedes the newline. Mirrors the `HxStatement.VarStmt` / `FinalStmt`
 * split.
 */
@:peg
enum HxSwitchCase {

	@:kw('case') @:fmt(forwardNewlineForBody, deferKwSpace)
	CaseBranch(branch: HxCaseBranch);

	@:kw('default')
	DefaultBranch(branch: HxDefaultBranch);

	/**
	 * `#if`-guarded run of whole case LABELS whose body is shared after
	 * the `#end` -- see `HxCondSpliceCase`. Tried BEFORE `Conditional`
	 * because `Conditional` parses the same bytes successfully and only
	 * strands the shared body afterwards, at which point the enclosing
	 * `HxSwitchStmt.cases` Star can no longer re-dispatch this element.
	 * The mandatory `tail` statement inside `HxCondSpliceCase` is the
	 * guard that hands every ordinary whole-clause region back to
	 * `Conditional` via `tryBranch` rollback.
	 */
	@:kw('#if') @:fmt(conditionalMarkerDedent)
	CondSpliceCase(inner: HxCondSpliceCase);

	/**
	 * `#if`-guarded run of whole case/default clauses — see
	 * `HxConditionalCase` for the shape and the dispatch-order
	 * interplay with statement-scope conditionals inside case bodies.
	 */
	@:kw('#if') @:trail('#end') @:fmt(conditionalMarkerDedent)
	Conditional(inner: HxConditionalCase);

}
