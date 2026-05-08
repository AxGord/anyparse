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
 * `#elseif` is intentionally out of scope for this slice (mirrors
 * `HxConditionalDecl` / `HxConditionalStmt` scope decisions). At
 * expression scope `#elseif` is more idiomatic than at decl/stmt
 * scope (`var x = #if a 1 #elseif b 2 #else 3 #end;`) so a follow-up
 * is more likely to surface here first; the chained-clause shape
 * (one `#if` head + Star of `#elseif` clauses + optional `#else`
 * tail) will land uniformly across the cond-comp typedef cluster
 * when added.
 *
 * `@:optional @:kw('#else') var elseExpr:Null<HxExpr>` uses the long-
 * supported optional-kw-Ref path (predates the Star variant from
 * ω-cond-comp-engine). Miss leaves the field `null`; commit captures
 * `_beforeKw{Leading,Trailing}` + `_kwLeading_` + `_beforeKwNewline_`
 * + `_bodyOnSameLine_` trivia slots automatically through the
 * existing optional-kw-Ref engine path (the `TriviaTypeSynth.isOptionalKw`
 * generalisation from ω-cond-comp-engine accepts Ref|Star uniformly).
 *
 * No `@:fmt(padLeading, padTrailing)` — that meta is Star-specific
 * (the writer adds pads around non-empty Stars). Single-Ref body
 * slots default to one inter-token space via the writer's standard
 * lead/trail emission, which matches the canonical inline shape
 * (`#if cond e1 #else e2 #end`). Source-driven multi-line shape
 * preservation (`#if cond\n\te1\n#else\n\te2\n#end`) is a partial
 * follow-up: the `elseExpr`-side `_beforeKwNewline_` slot already
 * captures the source's `expr`→`#else` newline through the engine
 * path, so the `#else`-led branch's leading newline is recoverable
 * at write time; the `expr`-side (cond→expr leading newline,
 * expr→`#end` trailing newline) needs a `@:trivia` capture on `expr`
 * plus writer-time space-vs-hardline switching to fully round-trip.
 */
@:peg
typedef HxConditionalExpr = {
	var cond:HxPpCondLit;
	var expr:HxExpr;
	@:optional @:kw('#else') var elseExpr:Null<HxExpr>;
};
