package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <stmts>` clause inside a `HxConditionalStmt`'s
 * `elseifs` Star. Mirror of `HxElseifDecl` at the statement scope:
 * the `#elseif` keyword sits on the first field's metadata so the
 * parent's `@:tryparse Star` loop can dispatch + terminate uniformly,
 * and the body is `Array<HxStatement>` Star (matching
 * `HxConditionalStmt.body`'s element type).
 *
 * `@:fmt(padLeading, padTrailing)` on `body` adds the same
 * boundary-pad treatment used by `HxConditionalStmt.body` — closing
 * the gap between `#elseif <cond>` and the first body element, and
 * between the last body element and the next clause / `#else` /
 * `#end`. Pads switch from a literal space to a hardline when the
 * first body element's `newlineBefore` slot is set (captured via
 * `@:trivia`).
 *
 * Position constraint at the call site (`HxConditionalStmt`): the
 * `elseifs` Star MUST appear before the `elseBody` field — same as
 * the decl-scope sibling.
 */
@:peg
typedef HxElseifStmt = {
	@:kw('#elseif') var cond:HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing)
		@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
		var body:Array<HxStatement>;
};
