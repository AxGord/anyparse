package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <expr> [#else <expr>] #end` preprocessor-
 * guarded expression-position region. Mirror of `HxConditionalDecl` /
 * `HxConditionalStmt` at the expression scope: the enclosing
 * `HxExpr.ConditionalExpr` ctor consumes the `#if` keyword and the
 * trailing `#end`; this typedef covers the content between them — the
 * condition atom, the then-branch single expression, and an optional
 * `#else` clause with its own single expression.
 *
 * Body is a single `HxExpr` (not `Array<HxExpr>` Star) because expr-
 * scope `#if` in real Haxe wraps exactly one expression per branch —
 * `var x = #if cond e1 #else e2 #end;` is the canonical shape, where
 * each branch contributes one value to the parent expression position.
 * The Star pattern used by `HxConditionalDecl` / `HxConditionalStmt`
 * doesn't transpose to expr scope: expressions don't separate with
 * `;` outside `BlockExpr`'s `{…}`, and the natural terminator for the
 * body Pratt loop (`#else` / `#end` token) gives at most one
 * expression before either keyword fires the next field.
 *
 * Multi-statement-body forms like
 * `var x = #if cond expr; #else expr; #end` (with `;` inside the
 * branch before `#else` / `#end`) are out of scope for this slice:
 * single-Ref body parses one expression, stops at the `;`, then the
 * outer `@:trail('#end')` fails because the next token is `;`, not
 * `#end`. Authors who need multiple statements per branch can today
 * wrap them in a block — `var x = #if cond { a; b; result } #else
 * { c } #end;` — because `BlockExpr` is itself an `HxExpr` and
 * matches the body slot through the standard atom dispatch. A bare-
 * `;` body shape would need a separate ctor variant whose body is
 * `Array<HxStatement>`, dispatched via `tryBranch` rollback when the
 * single-Ref form fails. Deferred until a fixture demands it.
 *
 * `#elseif` chained-clause support landed in slice ω-cond-comp-elseif:
 * `elseifs:Array<HxElseifExpr>` Star sits between `expr` and
 * `elseExpr`. Each clause is a `HxElseifExpr` typedef carrying the
 * `#elseif` keyword on its first field's metadata (HxCatchClause
 * precedent), with single-`HxExpr` body matching this typedef's own
 * Ref-vs-Star divergence. Empty Star degrades to `_de()`. Position
 * before `elseExpr` is mandatory so the clause loop fully terminates
 * before the optional `#else` dispatch fires.
 *
 * `@:optional @:kw('#else') var elseExpr:Null<HxExpr>` uses the long-
 * supported optional-kw-Ref path (predates the Star variant from
 * ω-cond-comp-engine). Miss leaves the field `null`; commit captures
 * `_beforeKw{Leading,Trailing}` + `_kwLeading_` + `_beforeKwNewline_`
 * + `_bodyOnSameLine_` trivia slots automatically through the
 * existing optional-kw-Ref engine path (the `TriviaTypeSynth.isOptionalKw`
 * generalisation from ω-cond-comp-engine accepts Ref|Star uniformly).
 *
 * `@:fmt(padTrailing)` on `expr`, `elseifs`, and `elseExpr` (slice
 * ω-pad-trailing-ref-engine) closes the boundary gaps that the
 * default internal-only sep leaves glued. Without the flag,
 * `expr`→outer `#end` would emit `expr#end` (missing space) and
 * `expr`→`#else` would emit `expr#else` for the same reason. The
 * engine's `prevPadTrailing` tracker drops the next field's
 * `sameLineSeparator` to `_de()` at runtime when this pad fires,
 * preventing the double-space `expr  #else` window that a naive
 * pad-only opt-in would open.
 *
 * Pad placement per field (single emission point per boundary):
 *   - `expr` (bare-Ref pad)        — owns `expr → elseifs / #else / #end`.
 *   - `elseifs` (Star pad)         — owns `last_clause_expr → #else / #end`
 *                                    when at least one clause is present;
 *                                    transparent when empty (engine
 *                                    propagates `expr`'s pad through the
 *                                    empty Star via `composePadTrailing`).
 *   - `elseExpr` (optional-Ref pad) — owns `elseExpr → #end`; emitted
 *                                    INSIDE the optional wrapper so the
 *                                    pad fires only when `elseExpr != null`.
 * Each clause's own `expr` carries NO pad — the parent Star's trailing
 * pad alone owns the trailing boundary; mirroring `HxElseifDecl` /
 * `HxElseifStmt` body Stars where the clause-internal Star pad is
 * what the parent Star sep + clause pad would otherwise double up.
 *
 * `@:fmt(padLeading)` (Star-specific) is not used in this slice — the
 * preceding kw / sibling already provides the leading sep into each
 * boundary, so no leading-side gap exists to close.
 *
 * Source-driven multi-line shape preservation
 * (`#if cond\n\te1\n#else\n\te2\n#end`): the `elseExpr`-side
 * `_beforeKwNewline_` slot captures the source's `expr`→`#else`
 * newline through the engine path; the `expr`-side / `elseExpr`-side
 * trailing boundaries (`expr`→`#elseif`/`#else`/`#end` and
 * `elseExpr`→`#end`) opt into the terminal `<f>NewlineAfter:Bool`
 * slot via `@:fmt(captureSourceNewlineAfter)` so `WriterLowering.padTrailingDoc`
 * can pick `_dhl()` over `_dt(' ')` when the source had a newline at
 * the boundary (sub-slice 5 of ω-cond-comp-expr-multiline).
 *
 * `@:fmt(nestBodyOnSourceNewline)` on `expr` and `elseExpr` (slice
 * ω-cond-comp-expr-body-nest) wraps the body's leading separator in
 * `Nest(_cols, [hardline, body])` when the source had a newline at
 * the kw/cond → body boundary, placing the body one indent step deeper
 * than the surrounding `#if`/`#else` line — the fork convention at
 * expression scope (issue_429). Without the flag the body lands at
 * parent indent on break, mismatching fork output. Inline single-line
 * shape (`var x = #if c a #else b #end`) keeps the byte-identical
 * `_dt(' ') + body` layout because the source-newline decision is
 * false (`exprBeforeNewline=false` on `expr`;
 * `elseExprBodyOnSameLine=true` on `elseExpr`, which the writer
 * inverts to `false`). Per-kind dispatch lives in
 * `WriterLowering.lowerStruct`: bare-Ref non-first reads
 * `value.exprBeforeNewline` directly; opt-kw-Ref reads
 * `!value.elseExprBodyOnSameLine`. Stmt/decl scope mirrors don't get
 * the flag — fork keeps body at the keyword's indent there.
 */
@:peg
typedef HxConditionalExpr = {
	var cond:HxPpCondLit;
	@:fmt(padTrailing, captureSourceNewlineAfter, nestBodyOnSourceNewline) var expr:HxExpr;
	@:trivia @:tryparse @:fmt(padTrailing) var elseifs:Array<HxElseifExpr>;
	@:optional @:kw('#else') @:fmt(padTrailing, captureSourceNewlineAfter, nestBodyOnSourceNewline) var elseExpr:Null<HxExpr>;
};
