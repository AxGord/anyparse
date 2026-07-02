package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <fields>` clause inside a
 * `HxConditionalObjectField`'s `elseifs` Star. The object-literal-scope
 * twin of `HxElseifMember` / `HxElseifStmt` / `HxElseifDecl`: carries
 * the `#elseif` keyword on its first field's metadata (HxCatchClause
 * precedent), so the parent's `@:tryparse` Star loop tries the kw at
 * each iteration and naturally terminates when the next token isn't
 * `#elseif`.
 *
 * Body shape: comma-separated `HxObjectField` Star, terminated by
 * fail-rewind (Slice 18's `@:sep+@:tryparse` without `@:trail`
 * Lowering branch — the enclosing `HxObjectField.Conditional` ctor's
 * `@:trail('#end')` consumes the closing directive). Same
 * `@:fmt(padLeading, padTrailing)` pads as the member-scope twin —
 * close the boundary gaps between `#elseif <cond>` and the body, and
 * between the body's last field and the next clause's `#elseif` / the
 * trailing `#else` / `#end`.
 *
 * The member-scope import/using blank-line cascades on `HxElseifDecl.body`
 * are NOT mirrored: object-literal fields carry no analogous grouping
 * model. Inter-element trivia is the responsibility of the outer
 * `HxObjectLit.fields` Star (`@:trivia` there), not of the cond-comp
 * body — Slice 18 deliberately keeps the inner Star non-trivia (see
 * `HxConditionalObjectField` doc for the trivia-vs-sep wall rationale).
 *
 * Position constraint at the call site (`HxConditionalObjectField`): the
 * `elseifs` Star MUST appear before the `elseBody` field so the
 * `#elseif` clauses fully terminate before the optional `#else`
 * dispatch fires.
 */
@:peg
typedef HxElseifObjectField = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:sep(',', sepFaithful) @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var body: Array<HxObjectField>;
};
