package anyparse.grammar.haxe;

/**
 * Type-position carrier in the Haxe grammar.
 *
 * `HxType` is the outer Alt enum that fronts every type-position field
 * (var-decl `:Type`, function-decl return type, abstract underlying
 * type, catch-clause type, etc.).
 *
 * Variants:
 *
 *  - `Named(ref:HxTypeRef)` — the named-and-optionally-parameterised
 *    type reference (`Int`, `Array<Int>`, `Map<String, Int>`,
 *    `haxe.io.Bytes`, `Foo<Bar<Baz>>`).
 *  - `DollarType(name:HxIdentLit)` — a macro-reification escape
 *    (`$ident`) used in type position: `var x:$optionsCT = …`,
 *    `macro : Null<$optionsCT>` inside a `@:build`/macro helper.
 *    The expression-position twin is `HxExpr.DollarIdentExpr`
 *    (`@:lead("$")` + `HxIdentLit`); this is the type-position
 *    mirror on the same enum-Alt path, dispatched by the `$` lead
 *    (no other `HxType` variant begins with `$`, and the
 *    `HxTypeRef` name terminal excludes `$`, so `Named` never
 *    competes). Only the bare `$ident` form appears in type
 *    position in the corpus; the `${expr}` / `$name{expr}`
 *    reification forms stay expression-only.
 *  - `ConditionalType(c:HxConditionalType)` — preprocessor-guarded
 *    type-position region `#if cond T1; [#else T2;] #end`, the RHS of
 *    a conditional typedef (`typedef X = #if (haxe_ver >= 4) A; #else
 *    B; #end`). `@:kw('#if')` + `@:trail('#end')` host ctor, exact
 *    twin of `HxExpr.ConditionalExpr` on the expression Pratt enum;
 *    the body content lives in `HxConditionalType`. Dispatched by the
 *    unique `#if` keyword lead — no other `HxType` atom begins with
 *    `#`, and `#if` is word-boundary checked, so `Named` never
 *    competes regardless of source order.
 *
 *  - `Arrow(left:HxType, right:HxType)` — function-arrow type in the
 *    old (curried) syntax: `Void->Void`, `Int->String->Void`,
 *    `Array<SymbolInformation>->Void`. Declared as an `@:infix('->')`
 *    branch with `Right` associativity at precedence `0` — same Pratt
 *    pattern that powers `HxExpr`. The macro auto-detects the Pratt
 *    branch in `Lowering` and emits a precedence-climbing loop wrapping
 *    the atom dispatcher. Carries `@:fmt(tight)` so the writer emits
 *    `Int->Void` without surrounding spaces, matching haxe-formatter's
 *    output for the old-form arrow. The new (parenthesised) form
 *    `(args) -> ret` lives on the separate `ArrowFn` variant below.
 *
 *  - `Anon(fields:Array<HxAnonMember>)` — anonymous structure type
 *    `{x:Int, y:String}` or `{ var x:Int; var y:String; }`. Bracketed
 *    `HxAnonMember` list reusing the Case 4 sep-peek Star pattern.
 *    `HxAnonMember` wraps `HxAnonField` with a leading metadata Star
 *    (the `HxMemberDecl` to `HxClassMember` relationship at the
 *    anon-struct level) so `{ @:optional x:Int }` parses. The
 *    `@:sepAlt(';')` opt-in makes the separator tolerant in the
 *    non-trivia build: a close-driven loop consumes an OPTIONAL `,`
 *    OR `;` between fields, so `;`-terminated class-notation fields
 *    (`var`/`final`), `;`-separated short fields, classic `,`, mixed,
 *    and an optional trailing separator all parse. Dispatched by the
 *    `{` lead — type-position is
 *    always after `:` (var-decl, function-param, return type,
 *    type-param body), so no Alt-level ambiguity with `HxStatement.
 *    BlockStmt` or `HxExpr.ObjectLit` exists. Nested anon
 *    (`{f:{f:Int}}`) and arrow inside anon (`{cb:Int->Void}`) compose
 *    naturally through the recursive `HxType` value field reached via
 *    `HxAnonMember.field`.
 *
 *  - `ArrowFn(fn:HxArrowFnType)` — new-form arrow function type
 *    `(args) -> ret` (Haxe 4 syntax). Structurally `(`-`,`-`)`
 *    parenthesised list of `HxArrowParam` (positional `Type` or named
 *    `name:Type`), then `->`, then return type. Placed BEFORE `Parens`
 *    in source order so the parser tries the arrow-fn shape first; when
 *    the trailing `->` is absent the branch rolls back and `Parens`
 *    takes over for `(T)` parens-around-type. Examples: `() -> Void`,
 *    `(Int, String) -> Bool`, `(name:String) -> Void`. The single-arg
 *    `(T) -> R` shape ALSO routes through `ArrowFn` — there is no
 *    parser-level disambiguation between "old-form arrow with parens
 *    around a single positional arg" and "new-form arrow with one
 *    positional arg"; the new-form representation is canonical and the
 *    writer emits ` -> ` (around-spaced) per `functionTypeHaxe4Policy`.
 *    Compound `(Int->Bool) -> Void` parses as
 *    `ArrowFn([Positional(Arrow(Int,Bool))], Void)` — semantically
 *    equivalent to the pre-slice `Arrow(Parens(Arrow(Int,Bool)), Void)`
 *    but with around-spaced `->` on the outer arrow.
 *
 *  - `Parens(inner:HxType)` — parenthesised type atom `(T)`. Wraps a
 *    full inner `HxType` between `(` and `)` via Case 3 single-Ref
 *    `@:wrap('(', ')')` — same shape as `HxExpr.ParenExpr`. Used both
 *    for type-param constraints `<S:(pack.sub.Type)=...>` and for
 *    explicit precedence wrapping inside arrows `(Int->Bool)`. Reached
 *    only when `ArrowFn` rolls back (no trailing `->` after `)`).
 *
 * The wrapper is introduced as a foundation so each new variant lands
 * as a small additive slice rather than retrofitting the type-position
 * shape across the whole grammar each time.
 *
 * `HxTypeRef.params` carries `Array<HxType>`, not `Array<HxTypeRef>`,
 * so type parameters can themselves be arrows or anon structs once
 * those branches are added (`Array<Int -> Void>`, `Map<{a:Int}, B>`).
 *
 * Right-associativity ensures `Int->Bool->Void` parses as
 * `Arrow(Int, Arrow(Bool, Void))`, mirroring the curried function-type
 * convention. Inputs with `(...)` followed by `->` route through
 * `ArrowFn` (see the variant doc above) — `(Int->Bool) -> Void` parses
 * as `ArrowFn([Positional(Arrow(Int, Bool))], Void)`. `Parens` is
 * reached only for `(...)` shapes NOT followed by `->`.
 */
@:peg
@:fmt(preWrite(HaxeTypeRewrites.arrowFnOldStyleRewrite))
enum HxType {
	Named(ref:HxTypeRef);

	@:lead("$")
	DollarType(name:HxIdentLit);

	/**
	 * Optional-argument marker in a curried (Haxe-3) function type:
	 * the `?` before a type in `Int->?Int->Void`. Single-Ref
	 * `@:lead('?')` atom branch — identical generic parse / writer /
	 * synth path to `DollarType` (`@:lead("$")`); zero core/writer/synth
	 * ripple, no `HaxeQueryPlugin` change (the plugin's nominal-name
	 * walker recurses `inner` through its generic `case _:` operand
	 * descent, exactly as it does for `Arrow` / `Parens`).
	 *
	 * AST-shape note (deferred precision, not a round-trip defect):
	 * because `inner:HxType` re-enters the full rule, `Int->?Int->Void`
	 * groups as `Arrow(Int, OptionalArg(Arrow(Int, Void)))` rather than
	 * the semantically tidier "optional first arg of the tail". The
	 * writer re-emits structurally (`?` + rendered `inner`) so every
	 * `?`-form round-trips byte-identically regardless of grouping —
	 * the skip-parse / byte-round-trip corpus metric is fully met. A
	 * precise optional-arg model (attaching `?` to a single `Arrow`
	 * operand) is a non-compounding follow-up if a later analysis pass
	 * needs the exact arity.
	 *
	 * The new-form parenthesised arrow `(?x:Int) -> Void` carries its
	 * optionality on `HxArrowParam`, a separate production — this
	 * branch covers only the curried `->`-chained shape.
	 */
	@:lead('?')
	OptionalArg(inner:HxType);

	@:kw('#if') @:trail('#end')
	ConditionalType(c:HxConditionalType);

	@:infix('->', 0, 'Right') @:fmt(tight)
	Arrow(left:HxType, right:HxType);

	@:trivia @:lead('{') @:trail('}') @:sep(',') @:sepAlt(';') @:fmt(anonTypeBracesOpen, anonTypeBracesClose, wrapRules('anonTypeWrap'), leftCurly('anonTypeLeftCurly'), rightCurly('anonTypeRightCurly'), beforeDocCommentEmptyLines, forceMultiInTypedef)
	Anon(fields:Array<HxAnonMember>);

	ArrowFn(fn:HxArrowFnType);

	@:wrap('(', ')')
	Parens(inner:HxType);
}
