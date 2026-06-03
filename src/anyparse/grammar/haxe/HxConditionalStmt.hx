package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <stmts> [#else <stmts>] #end` preprocessor-
 * guarded function-body region. Mirror of `HxConditionalDecl` at the
 * statement scope: the enclosing `HxStatement.Conditional` ctor
 * consumes the `#if` keyword and the trailing `#end`; this typedef
 * covers the content between them — the condition atom, the then-body
 * Star of further statements, and an optional `#else` clause with its
 * own statement Star.
 *
 * Element type is bare `HxStatement` (not a wrapper analogous to
 * `HxTopLevelDecl`) because statements have no leading
 * meta + modifier prefix to thread through. The body's `@:tryparse`
 * Star terminates when the next token isn't a recognised statement
 * start — `#else` and `#end` fail every keyword and expression
 * dispatch path, so the loop naturally stops there. Trailing `;` /
 * `}` of nested statements is consumed by the inner ctor's own
 * `@:trail` / `@:trailOpt`, so the body Star sees whitespace +
 * statement-start at each iteration boundary.
 *
 * Nested `#if` is supported transitively through the body re-entering
 * `HxStatement.Conditional` via the dispatch enum's `@:kw('#if')` ctor.
 *
 * `#elseif` chained-clause support landed in slice ω-cond-comp-elseif:
 * `elseifs:Array<HxElseifStmt>` Star sits between `body` and
 * `elseBody`. Each clause is a `HxElseifStmt` typedef carrying the
 * `#elseif` keyword on its first field's metadata (HxCatchClause
 * precedent), so the Star's `@:tryparse` loop dispatches per-iteration
 * and naturally terminates when the next token isn't `#elseif`. Empty
 * Star degrades to `_de()` (no output). Position before `elseBody` is
 * mandatory so the clause loop fully terminates before the optional
 * `#else`.
 *
 * Writer-side output mirrors `HxConditionalDecl`: the
 * `@:fmt(padLeading, padTrailing)` flag pair on `body` and `elseBody`
 * adds a leading + trailing pad around each Star when non-empty,
 * closing the `#if`/`#else`/`#end` boundary gaps that the default
 * internal-only sep leaves glued. The pads switch from a literal space
 * to a hardline when the first body element's `newlineBefore` slot is
 * set (captured via `@:trivia`), reproducing the multi-line shape that
 * fn-body fixtures exercise (`function f() {\n#if php\n\treturn 1;\n#end\n}`).
 *
 * `@:optional @:kw('#else') @:tryparse var elseBody:Null<Array<…>>`
 * uses the kw-led optional Star path (Lowering's
 * `emitOptionalKwStarFieldSteps`, slice ω-cond-comp-engine). The path
 * splices the kw-Ref commit machinery with the tryparse Star loop —
 * `#else` is the commit point, miss leaves the field `null` so the
 * writer skips the entire clause.
 *
 * Slice D4: `elseBody` carries the same
 * `@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))`
 * meta as `body` / `HxElseifStmt.body`. Pre-D4 the engine silently
 * ignored sep on the kw-led optional Star path — `#if … #else final x
 * = 1; #end` decomposed into `FinalStmt + EmptyStmt(';')` and the
 * writer produced `final x = 1 ;`. The fix extends
 * `emitOptionalKwStarFieldSteps` with the same sep-consumption shape
 * the non-optional `@:trivia + @:tryparse + @:sep` branch uses.
 */
@:peg
typedef HxConditionalStmt = {
	@:fmt(sharpCondParensInside('sharpCondParensInsideOpen', 'sharpCondParensInsideClose')) var cond:HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent)
		@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
		var body:Array<HxStatement>;
	@:trivia @:tryparse var elseifs:Array<HxElseifStmt>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent)
		@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
		var elseBody:Null<Array<HxStatement>>;
};
