package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <members>` clause inside a `HxConditionalMember`'s
 * `elseifs` Star. The member-scope twin of `HxElseifStmt` /
 * `HxElseifDecl`: carries the `#elseif` keyword on its first field's
 * metadata (HxCatchClause precedent), so the parent's `@:tryparse` Star
 * loop tries the kw at each iteration and naturally terminates when the
 * next token isn't `#elseif`.
 *
 * Body shape mirrors `HxConditionalMember.body` exactly: trivia-wrapped,
 * tryparse-terminated `Array<HxMemberDecl>` Star with
 * `@:fmt(padLeading, padTrailing)` for the leading + trailing pads around
 * the body Star (closes the boundary gaps between `#elseif <cond>` and
 * the body, and between the body's last member and the next clause's
 * `#elseif` / the trailing `#else` / `#end`).
 *
 * The decl-scope import/using blank-line cascades on `HxElseifDecl.body`
 * are intentionally NOT mirrored here: members carry their own
 * blank-line model (`interMemberBlankLines`, applied by
 * `HxClassDecl.members`); an import-ordering cascade has no meaning at
 * member scope. Add a member blank-line cascade only if a concrete
 * corpus fixture later demands it.
 *
 * Element type is `HxMemberDecl` (not bare `HxClassMember`) so leading
 * metadata + modifiers inside the clause region parse uniformly through
 * the same meta + modifier Stars used by `HxClassDecl.members`.
 *
 * Position constraint at the call site (`HxConditionalMember`): the
 * `elseifs` Star MUST appear before the `elseBody` field so the
 * `#elseif` clauses fully terminate before the optional `#else`
 * dispatch fires.
 */
@:peg
typedef HxElseifMember = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var body: Array<HxMemberDecl>;
};
