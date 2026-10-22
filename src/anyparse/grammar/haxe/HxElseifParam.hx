package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <params>` clause inside a `HxConditionalParam`'s
 * `elseifs` Star. The fn-param-scope twin of `HxElseifObjectField` /
 * `HxElseifMember` / `HxElseifStmt` / `HxElseifDecl`: carries the
 * `#elseif` keyword on its first field's metadata (HxCatchClause
 * precedent), so the parent's `@:tryparse` Star loop tries the kw at
 * each iteration and naturally terminates when the next token isn't
 * `#elseif`.
 *
 * Body shape: comma-separated `HxParam` Star, terminated by fail-rewind
 * (Slice 18's `@:sep+@:tryparse` without `@:trail` Lowering branch —
 * the enclosing `HxParam.Conditional` ctor's `@:trail('#end')` consumes
 * the closing directive). Same `@:fmt(padLeading, padTrailing)` pads as
 * the obj-lit twin — close the boundary gaps between `#elseif <cond>`
 * and the body, and between the body's last param and the next clause's
 * `#elseif` / the trailing `#else` / `#end`.
 *
 * The member-scope import/using blank-line cascades on `HxElseifDecl.body`
 * are NOT mirrored: fn parameters carry no analogous grouping model.
 * `@:trivia` + `sepFaithful` on `body` for the reason
 * `HxConditionalParam.body` carries them: only a trivia Star captures the
 * per-element `sepAfter` that writes a comma before the next `#else` /
 * `#end` back where the source put it.
 *
 * Position constraint at the call site (`HxConditionalParam`): the
 * `elseifs` Star MUST appear before the `elseBody` field so the
 * `#elseif` clauses fully terminate before the optional `#else`
 * dispatch fires.
 */
@:peg
typedef HxElseifParam = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:sep(',', sepFaithful) @:tryparse @:fmt(padLeading, padTrailing) var body: Array<HxParam>;
};
