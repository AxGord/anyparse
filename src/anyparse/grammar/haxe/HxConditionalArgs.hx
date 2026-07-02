package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <expr-list> [#elseif …] [#else <expr-list>]
 * #end` preprocessor-guarded region wrapping whole ELEMENTS of a
 * comma-separated expression list — array-literal entries, call
 * arguments, `new` arguments. The enclosing `HxExpr.ConditionalArgs`
 * ctor consumes the `#if` keyword and the trailing `#end`; this
 * typedef covers the content between them.
 *
 * Expr-list twin of `HxConditionalParam` (fn params, Slice 18) /
 * `HxConditionalObjectField` (obj literals): one grammar production
 * covers every `Array<HxExpr>` sep-Star because the conditional group
 * is itself an `HxExpr` element. Live dogfood shapes:
 *
 *  - `[a, #if !mobile b, c, #end d]` — guarded run of array elements
 *    with a trailing comma inside the body.
 *  - `g(true #if FEATURE_SHARE_EXTRA, true #end)` — trailing extra
 *    argument; the leading `,` INSIDE the body is the `sepBeforeOpt`
 *    form (incl. glued shapes — where `#if` is glued to the
 *    previous `)` with no space).
 *  - `[#if mobile A, #else B, #end c]` — `#else` alternative with its
 *    own trailing comma.
 *
 * Branch-order note: `HxExpr.ConditionalExpr` (the balanced
 * single-expression form `#if c e1 #else e2 #end`) is tried FIRST and
 * keeps winning every shape it parsed before — this ctor only commits
 * when the body contains list punctuation the balanced form rejects
 * (a `,` before `#elseif`/`#else`/`#end`), so pre-slice fixtures stay
 * byte-identical. The outer list's between-element sep elision around
 * the group (no doubled comma) rides the existing per-element
 * `sepAfter` capture, same as `HxParam.Conditional`.
 *
 * `elseBody` carries `@:sep(',')` directly — the optional-kw-Star
 * engine path gained sep support in Slice D4 (HxConditionalStmt), so
 * the `#else '/tmp', #end` trailing-comma shape parses; the
 * HxConditionalParam-era single-element limitation does not apply.
 */
@:peg
typedef HxConditionalArgs = {
	var cond: HxPpCondLit;
	@:trivia @:sep(',', sepFaithful) @:tryparse @:fmt(padLeading, padTrailing, sepBeforeOpt, conditionalBodyIndent) var body: Array<HxExpr>;
	@:tryparse var elseifs: Array<HxElseifArgs>;
	@:optional @:kw('#else') @:trivia @:sep(',', sepFaithful) @:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent) var elseBody: Null<Array<HxExpr>>;
};
