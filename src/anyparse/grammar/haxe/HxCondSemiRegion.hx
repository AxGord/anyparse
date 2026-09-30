package anyparse.grammar.haxe;

/**
 * The region of `HxCondSemiValue.CondSemiRegion`: `#if cond <statements> [#elseif cond <statements>]* #else <statements>`, the
 * `#end` riding the enum branch. Each branch is a run of statements, as the preprocessor makes it: the first completes
 * the assignment (`x = false;`), any further one follows it (`#if a false; log(); …` is `x = false; log();`). The
 * statement bodies are `HxConditionalStmt`'s, trivia included, so a hand-laid branch keeps its lines and its comments.
 *
 * Every branch ends the statement with its own `;`. The bodies cannot demand it — a statement before `#else` / `#end`
 * may omit its `;` — so `HxCondSemiAssign.end` refuses a `;` right after the `#end` instead: that is where a region
 * whose branches are bare values (`x = #if a 1 #else 2 #end;`) puts its terminator, and it is a value region, not this
 * shape.
 *
 * The `#else` is MANDATORY: it is what ends the statement in every configuration. Without it a configuration taking no
 * branch reads the text after the `#end` as the value (`x = #if a 1; #end compute();`), which stays
 * `HxCondSpliceExpr`'s shape.
 */
@:peg
typedef HxCondSemiRegion = {
	@:kw('#if') @:fmt(sharpCondParensInside('sharpCondParensInsideOpen', 'sharpCondParensInsideClose')) var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent)
	@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	var body: Array<HxStatement>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifStmt>;
	// the Star before it ends with its own separator (`padTrailing`): `fillSeam` adds none, a gap comment still emitted
	@:fmt(fillSeam) var elseKw: HxCondElseLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent)
	@:sep(';', tailRelax, blockEnded('stmtNoSemi', sepStartsElement))
	var elseBody: Array<HxStatement>;
};
