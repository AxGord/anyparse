package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <modifiers> [#elseif ...] [#else ...] #end`
 * preprocessor-guarded modifier region. The enclosing
 * `HxModifier.Conditional` / `HxMemberModifier.Conditional` ctor consumes
 * the `#if` keyword and the trailing `#end`; this typedef covers the
 * content between them - the condition atom, a try-parse Star of further
 * entries, the `#elseif` chain, and an optional `#else` clause with its
 * own Star.
 *
 * Modifier-scope sibling of `HxConditionalMeta` (declaration prefix) and
 * `HxConditionalHeritage` (heritage clauses), and structurally identical
 * to both: `{ cond, body, elseifs, elseBody }`.
 *
 * The Stars hold `HxCondModPrefix`, not `HxModifier` - a branch may
 * contribute a metadata tag or a bare `enum` / `macro` keyword instead of
 * a plain modifier, as in Pony's
 * `#if (haxe_ver >= 4.2) extern #else @:extern #end public inline function new(...)`.
 * See that enum for the full motivating-shape list and for why the
 * widening is scoped to the conditional bodies and cannot shadow the
 * ordinary modifier dispatch.
 *
 * Which Star claims a given prefix `#if` region is decided by field
 * order, not by lookahead. `HxMemberDecl` / `HxTopLevelDecl` run `meta`
 * before `modifiers`, so a region whose every branch is metadata-only (or
 * `enum`-plus-metadata, the openfl `enum abstract` shape) is claimed by
 * `HxMetadata.Conditional` and keeps its pre-slice AST. A region carrying
 * any modifier keyword fails `HxConditionalMeta` - its Star cannot match
 * the keyword, and the trailing `#end` check then rejects the branch - so
 * the meta Star rolls back to empty and the region falls through to the
 * modifier Star handled here. The two element types therefore overlap on
 * metadata without either Star ever stealing the other's regions.
 * CONSUMER NOTE: one consequence is that the same textual region lands in
 * a different typed field depending on whether a modifier precedes it -
 * `#if a enum #else @:enum #end abstract E(Int)` reaches `decls[0].meta`,
 * while `private #if a enum #else @:enum #end abstract E(Int)` reaches
 * `decls[0].modifiers`. The S-expr dump renders both identically because
 * the ctor names coincide, so anything scanning for conditional prefix
 * regions must look at both Stars.
 *
 * No field-level whitespace literals (e.g. `@:lead(' ')`) - the generated
 * parser calls `skipWs` at every field boundary (`Lowering.lowerStruct`
 * pre-field skipWs, plus the try-parse loop's own `skipWs` before each
 * iteration), so any amount of spacing between `cond`, the entries, and
 * `#end` is consumed transparently. A whitespace-prefix literal would
 * never match: the pre-field skipWs runs first and eats the space.
 * Multi-line variants (issue_332 V4 - newline between `cond` and
 * modifier) parse correctly as a consequence; the writer reads the
 * trivia-captured `newlineBefore` to round-trip the shape.
 *
 * `@:tryparse` on the Stars puts them in try-parse termination mode
 * (`Lowering.emitStarFieldSteps` try-parse branch): the loop parses
 * entries until the next token is not a recognised keyword, `@`, or
 * nested `#if`, which in legal input is `#elseif` / `#else` / `#end` -
 * consumed by the following field or the outer ctor's `@:trail`.
 *
 * Writer-side output shape: `#if <cond> <entries> #end` (V1-V3) or
 * `#if <cond>\n<entries>\n#end` (V4 - cond / mods / `#end` on separate
 * source lines). The `#if ` keyword carries its trailing space from
 * `@:kw` + Case 3's `kwLead + ' '` rule, entries join internally with
 * single spaces, and the `@:fmt(padLeading, padTrailing)` flag pair on
 * each Star adds a leading + trailing pad around it when it is non-empty
 * - closing the cond<->body[0] and body[last]<->`#else`/`#end` gaps that
 * the default internal-only sep leaves glued against the surrounding
 * tokens. The two flags are independent - `HxAbstractDecl.clauses` uses
 * `@:fmt(padLeading)` alone because its trailing slot is already covered
 * by the next field's `@:lead('{')` spaced-lead separator.
 *
 * KNOWN WRITER GAPS, all three shared verbatim with `HxConditionalMeta`
 * and `HxConditionalHeritage` and therefore a shared-mechanism fix rather
 * than a modifier-scope one. No corpus fixture and no dogfood tree hits
 * any of them.
 *  - An EMPTY Star degrades to `_de()`, which drops the pad entirely
 *    instead of leaving one space: the plain writer emits
 *    `#if a#end` and `#if a extern #else#end`, and the trivia writer
 *    turns the latter into an injected line break before `#end`.
 *  - A non-empty `#elseif` body is followed by a DOUBLE space, because
 *    its own padTrailing runs in addition to the separator the next
 *    field's `@:kw` contributes - `... extern  #else` / `... extern
 *    #elseif`. It fires after every non-empty `#elseif` body regardless
 *    of what follows.
 *  - An EMPTY `#elseif` body loses its separator the same way the empty
 *    `#else` arm does: `#if a extern #elseif b#end`.
 *
 * `@:trivia` on the Stars makes each entry trivia-bearing
 * (`Trivial<HxCondModPrefixT>` with a `newlineBefore` slot). The
 * padLeading/padTrailing pads switch from a literal space to a hardline
 * when `body[0].newlineBefore` is set, reproducing the multi-line source
 * shape (issue_332 V4). The trail-side decision mirrors the leading-side
 * because the parser does not capture a body[last] -> `#end` newline slot
 * - in legal source shapes the two newlines are correlated. Inter-element
 * separator inside a Star keeps its existing per-element
 * `newlineBefore`-driven hardline-vs-space logic in
 * `triviaTryparseStarExpr`.
 */
@:peg
typedef HxConditionalMod = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxCondModPrefix>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifMod>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing) var elseBody: Null<Array<HxCondModPrefix>>;
};
