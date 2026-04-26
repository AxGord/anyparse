package anyparse.grammar.haxe;

/**
 * A class member declaration with optional leading metadata and
 * modifiers.
 *
 * Wraps `HxClassMember` (the `var`/`final`/`function` dispatch enum)
 * with two preceding Star fields: metadata tags (`@:keep`,
 * `@:overload(...)`, `@in(true)` …) first, then access/storage
 * modifiers (`public`, `static`, `#if … #end`, …). This typedef is
 * the unit that `HxClassDecl.members` iterates over, so both prefix
 * sections are parsed once before the keyword dispatch — no redundant
 * re-parsing on failed branches.
 *
 * The modifier element type is `HxMemberModifier` (not the broader
 * `HxModifier`) so `final` is NOT eaten by the modifier Star — it
 * reaches `HxClassMember.FinalMember` as the introducer of an
 * immutable field declaration. The trade-off is the legacy
 * `final var x:Int;` shape no longer parses at the member position;
 * modern `final x:Int;` is the canonical form. See `HxMemberModifier`
 * for full rationale.
 *
 * Neither Star carries `@:lead`, `@:trail`, or `@:sep` — both use the
 * try-parse termination mode in `emitStarFieldSteps`: the loop attempts
 * to parse an element on each iteration and breaks when the next token
 * isn't a recognised start character (`@` for metadata, a reserved
 * keyword for modifiers). `@:tryparse` is stated explicitly (not
 * inferred from `!isLastField`) because the Trivia-mode path in
 * `emitTriviaStarFieldSteps` requires one of `@:trail`, `isLastField`,
 * or `@:tryparse` to pick a termination mode.
 *
 * `@:trivia` on both Stars enables per-element trivia capture (leading
 * comments, trailing comment, blank-line and single-newline markers).
 * This is load-bearing for `issue_332_conditional_modifiers` V1 — the
 * fixture expects the newline that follows a `#if COND <mods> #end`
 * conditional modifier before the next real modifier (`#end\n\tpublic`)
 * to round-trip verbatim, which requires the writer to emit a hardline
 * between those two modifiers instead of the default space separator.
 * The same channel carries per-metadata newline markers so `@:allow(Cls)`
 * followed by `\nvar x` round-trips with the newline preserved.
 *
 * The paired-type synth in `TriviaTypeSynth.buildTypeDefinition` handles
 * two trivia Stars on one Seq by prefixing every slot with the field
 * name (`metaTrailingLeading`, `modifiersTrailingLeading`, …), so the
 * two Stars compose without name collision.
 */
@:peg
typedef HxMemberDecl = {
	@:trivia @:tryparse var meta:Array<HxMetadata>;
	@:trivia @:tryparse var modifiers:Array<HxMemberModifier>;
	var member:HxClassMember;
}
