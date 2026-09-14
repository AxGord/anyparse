package anyparse.grammar.haxe;

/**
 * A class member declaration with optional leading metadata and modifiers: wraps
 * `HxClassMember` (the `var`/`final`/`function` dispatch enum) with two preceding Star fields
 * — metadata tags first, then access/storage modifiers (`public`, `static`, `#if … #end`,
 * …). This typedef is the unit `HxClassDecl.members` iterates over, so both prefix sections
 * are parsed once before the keyword dispatch.
 *
 * The modifier element type is `HxMemberModifier` (not the broader `HxModifier`) so `final`
 * is NOT eaten by the modifier Star — it reaches `HxClassMember.FinalMember` as the
 * introducer of an immutable field declaration; the legacy `final var x:Int;` shape therefore
 * does not parse at the member position. See `HxMemberModifier`.
 *
 * Neither Star carries `@:lead`, `@:trail` or `@:sep` — both use the try-parse termination
 * mode in `emitStarFieldSteps`, breaking when the next token is not a recognised start
 * (`@` for metadata, a reserved keyword for modifiers). `@:tryparse` is stated explicitly
 * because the Trivia-mode path in `emitTriviaStarFieldSteps` requires one of `@:trail`,
 * `isLastField` or `@:tryparse` to pick a termination mode.
 *
 * `@:trivia` on both Stars enables per-element trivia capture (leading comments, trailing
 * comment, blank-line and single-newline markers). It is load-bearing for the newline that
 * follows a `#if COND <mods> #end` conditional modifier before the next real modifier
 * (`#end\n\tpublic`), which must round-trip as a hardline instead of the default space
 * separator; the same channel carries per-metadata newline markers so `@:allow(Cls)` followed
 * by `\nvar x` keeps its newline. `TriviaTypeSynth.buildTypeDefinition` prefixes every slot
 * with the field name (`metaTrailingLeading`, `modifiersTrailingLeading`, …), so the two
 * Stars compose without name collision.
 *
 * ω-region-prefix-blank: `@:fmt(keepBlankAfterStarCtor('meta', 'Conditional'))` sits on BOTH
 * `modifiers` and `member` because the blank after a prefix-only `#if X #end` region lands in
 * whichever of them comes next — the modifier run's first element when there is one, the
 * member's own leading gap when there is not. Either way it is kept only when the `meta` run
 * ENDS in a region: the fork deletes the blank after an ordinary metadata prefix and keeps it
 * after a region, and the parser folds both into the same `meta` Star, so the run's last ctor
 * is the only thing that tells them apart.
 */
@:peg
typedef HxMemberDecl = {
	@:trivia @:tryparse @:fmt(metaLineEndPolicy('metadataFunctionLineEnd')) var meta: Array<HxMetadata>;
	@:trivia @:tryparse @:fmt(forceInlineSep, keepBlankAfterStarCtor('meta', 'Conditional')) var modifiers: Array<HxMemberModifier>;
	@:optional @:absentOn('}') @:fmt(bareRefSepWhenPresent, keepBlankAfterStarCtor('meta', 'Conditional')) var member: Null<HxClassMember>;
}
