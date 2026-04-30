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
 *  - `Anon(fields:Array<HxAnonField>)` — anonymous structure type
 *    `{x:Int, y:String}`. Bracketed comma-separated `HxAnonField`
 *    list reusing the same Case 4 sep-peek Star pattern as
 *    `HxObjectLit`. Dispatched by the `{` lead — type-position is
 *    always after `:` (var-decl, function-param, return type,
 *    type-param body), so no Alt-level ambiguity with `HxStatement.
 *    BlockStmt` or `HxExpr.ObjectLit` exists. Nested anon
 *    (`{f:{f:Int}}`) and arrow inside anon (`{cb:Int->Void}`) compose
 *    naturally through the recursive `HxType` value field on
 *    `HxAnonField`.
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

	@:infix('->', 0, 'Right') @:fmt(tight)
	Arrow(left:HxType, right:HxType);

	@:lead('{') @:trail('}') @:sep(',') @:fmt(anonTypeBracesOpen, anonTypeBracesClose)
	Anon(fields:Array<HxAnonField>);

	ArrowFn(fn:HxArrowFnType);

	@:wrap('(', ')')
	Parens(inner:HxType);
}
