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
 * The `modifiers` field has no `@:lead`, `@:trail`, or `@:sep` — it
 * uses the try-parse termination mode in `emitStarFieldSteps`: the
 * loop attempts to parse a modifier on each iteration and breaks when
 * the next token is not a recognised modifier keyword.
 */
@:peg
typedef HxMemberDecl = {
	var modifiers:Array<HxModifier>;
	var member:HxClassMember;
}
