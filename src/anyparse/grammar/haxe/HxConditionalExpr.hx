package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <expr> [#elseif <cond> <expr>]* [#else <expr>] #end`
 * preprocessor-guarded expression-position region. Mirror of `HxConditionalDecl` /
 * `HxConditionalStmt` at the expression scope: the enclosing `HxExpr.ConditionalExpr` ctor
 * consumes the `#if` keyword and the trailing `#end`; this typedef covers the content
 * between them.
 *
 * The body is a single `HxExpr` (not a Star) because an expression-scope `#if` wraps exactly
 * one expression per branch — `var x = #if cond e1 #else e2 #end;`; expressions do not
 * separate with `;` outside `BlockExpr`'s `{…}`, and the body Pratt loop stops at `#else` /
 * `#end`. A per-branch-`;` body is NOT this shape — the single-Ref body stops at the `;` and
 * the outer `@:trail('#end')` fails; a block body parses because `BlockExpr` is an `HxExpr`.
 *
 * `elseifs:Array<HxElseifExpr>` sits between `expr` and `elseExpr`: each clause carries the
 * `#elseif` keyword on its first field's metadata with a single-`HxExpr` body; the position
 * before `elseExpr` is mandatory so the clause loop terminates before the optional `#else`
 * dispatch fires. `@:optional @:kw('#else') var elseExpr:Null<HxExpr>` uses the
 * optional-kw-Ref path: a miss leaves the field `null`; a commit captures the
 * `_beforeKw*` / `_kwLeading_` / `_beforeKwNewline_` / `_bodyOnSameLine_` trivia slots.
 *
 * `@:fmt(padTrailing)` on `expr`, `elseifs` and `elseExpr` closes the boundary gaps the
 * default internal-only sep leaves glued (`expr#end`, `expr#else`); the engine's
 * `prevPadTrailing` tracker drops the next field's `sameLineSeparator` to `_de()` when the
 * pad fires, so no double space opens. One emission point per boundary: `expr` owns `expr →
 * elseifs / #else / #end`; the `elseifs` Star pad owns `last clause → #else / #end` when a
 * clause is present and is transparent when empty (`composePadTrailing`); the `elseExpr` pad
 * fires INSIDE the optional wrapper. Each clause's own `expr` carries NO pad.
 *
 * Source-driven multi-line shape: the `elseExpr`-side `_beforeKwNewline_` slot captures the
 * `expr`→`#else` newline; the trailing boundaries opt into the terminal `<f>NewlineAfter:Bool`
 * slot via `@:fmt(captureSourceNewlineAfter)` so `padTrailingDoc` picks `_dhl()` over `_dt(' ')`.
 * `@:fmt(nestBodyOnSourceNewline)` on `expr` and `elseExpr` (ω-cond-comp-expr-body-nest)
 * wraps the body's leading separator in `Nest(_cols, [hardline, body])` when the source had
 * a newline at the kw/cond → body boundary — the fork convention at expression scope; the
 * inline shape keeps `_dt(' ') + body`. Stmt/decl mirrors do not get the flag — the fork
 * keeps the body at the keyword's indent there. `@:fmt(condExprFitBreak)` on all three
 * fields (ω-cond-expr-fit) marks each flat separator as a knob-gated soft `Line(' ')` — a
 * space while the ctor's `condExprFitGroup` fits its line, a directive-seam break when it
 * does not (`sameLine.conditionalExprFit`, documented on `HxModuleWriteOptions`).
 */
@:peg
typedef HxConditionalExpr = {
	var cond: HxPpCondLit;
	@:fmt(padTrailing, captureSourceNewlineAfter, nestBodyOnSourceNewline, condExprFitBreak) var expr: HxExpr;
	@:trivia @:tryparse @:fmt(padTrailing, condExprFitBreak) var elseifs: Array<HxElseifExpr>;
	@:optional @:kw('#else') @:fmt(padTrailing, captureSourceNewlineAfter, nestBodyOnSourceNewline, condExprFitBreak) var elseExpr: Null<HxExpr>;
};
