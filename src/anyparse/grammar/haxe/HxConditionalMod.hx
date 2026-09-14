package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <modifiers> [#elseif ...] [#else ...] #end` preprocessor-guarded
 * modifier region. The enclosing `HxModifier.Conditional` / `HxMemberModifier.Conditional`
 * ctor consumes the `#if` keyword and the trailing `#end`; this typedef covers the content
 * between them — the condition atom, a try-parse Star of further entries, the `#elseif`
 * chain, and an optional `#else` clause with its own Star. Modifier-scope sibling of
 * `HxConditionalMeta` and `HxConditionalHeritage`, structurally identical to both.
 *
 * The Stars hold `HxCondModPrefix`, not `HxModifier` — a branch may contribute a metadata
 * tag or a bare `enum` / `macro` keyword instead of a plain modifier (`#if (haxe_ver >= 4.2)
 * extern #else @:extern #end public inline function new(...)`); see that enum for why the
 * widening is scoped to the conditional bodies and cannot shadow the ordinary dispatch.
 *
 * Which Star claims a given prefix `#if` region is decided by field order, not by lookahead.
 * `HxMemberDecl` / `HxTopLevelDecl` run `meta` before `modifiers`, so a region whose every
 * branch is metadata-only (or `enum`-plus-metadata) is claimed by `HxMetadata.Conditional`.
 * A region carrying any modifier keyword fails `HxConditionalMeta` — its Star cannot match
 * the keyword, and the trailing `#end` check then rejects the branch — so the meta Star rolls
 * back to empty and the region falls through to the modifier Star handled here. CONSUMER
 * NOTE: the same textual region lands in a different typed field depending on whether a
 * modifier precedes it — `#if a enum #else @:enum #end abstract E(Int)` reaches
 * `decls[0].meta`, `private #if a enum #else @:enum #end abstract E(Int)` reaches
 * `decls[0].modifiers`; the S-expr dump renders both identically, so anything scanning for
 * conditional prefix regions must look at both Stars.
 *
 * No field-level whitespace literals — the generated parser calls `skipWs` at every field
 * boundary, so any spacing between `cond`, the entries and `#end` is consumed transparently.
 * `@:tryparse` puts the Stars in try-parse termination mode: the loop parses entries until
 * the next token is not a recognised keyword, `@` or nested `#if`.
 *
 * Writer-side: the `#if ` keyword carries its trailing space from `@:kw` + Case 3's `kwLead
 * + ' '` rule, entries join with single spaces, and `@:fmt(padLeading, padTrailing)` on each
 * Star adds a leading + trailing pad around it when non-empty. `@:trivia` makes each entry
 * trivia-bearing; the pads switch from a space to a hardline when `body[0].newlineBefore` is
 * set, the trail side mirroring the leading side because the parser captures no
 * `body[last]` → `#end` newline slot. KNOWN WRITER GAPS, shared with `HxConditionalMeta` and
 * `HxConditionalHeritage` (a shared-mechanism fix): an EMPTY Star degrades to `_de()` and
 * drops the pad entirely (`#if a#end`); a non-empty `#elseif` body is followed by a DOUBLE
 * space, since its own padTrailing runs in addition to the next `@:kw`'s separator.
 */
@:peg
typedef HxConditionalMod = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxCondModPrefix>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifMod>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxCondModPrefix>>;
};
