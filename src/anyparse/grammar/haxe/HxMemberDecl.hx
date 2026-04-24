package anyparse.grammar.haxe;

/**
 * A class member declaration with optional leading modifiers.
 *
 * Wraps `HxClassMember` (the `var`/`function` dispatch enum) with a
 * preceding `Array<HxModifier>` field. This typedef is the unit that
 * `HxClassDecl.members` iterates over, so modifiers are parsed once
 * before the keyword dispatch — no redundant re-parsing on failed
 * branches.
 *
 * `modifiers` has no `@:lead`, `@:trail`, or `@:sep` — it uses the
 * try-parse termination mode in `emitStarFieldSteps`: the loop attempts
 * to parse a modifier on each iteration and breaks when the next token
 * is not a recognised modifier keyword. `@:tryparse` is stated
 * explicitly (not inferred from `!isLastField`) because the Trivia-mode
 * path in `emitTriviaStarFieldSteps` requires one of `@:trail`,
 * `isLastField`, or `@:tryparse` to pick a termination mode.
 *
 * `@:trivia` enables per-element trivia capture (leading comments,
 * trailing comment, blank-line and single-newline markers). This is
 * load-bearing for `issue_332_conditional_modifiers` V1 — the fixture
 * expects the newline that follows a `#if COND <mods> #end` conditional
 * modifier before the next real modifier (`#end\n\tpublic`) to round-
 * trip verbatim, which requires the writer to emit a hardline between
 * those two modifiers instead of the default space separator. Without
 * the capture the writer cannot distinguish V1 (newline) from V2
 * (space) — both parse the same modifier list.
 */
@:peg
typedef HxMemberDecl = {
	@:trivia @:tryparse var modifiers:Array<HxModifier>;
	var member:HxClassMember;
}
