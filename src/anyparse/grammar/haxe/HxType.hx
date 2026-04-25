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
 *    the atom dispatcher (which sees only `Named` for now). Carries
 *    `@:fmt(tight)` so the writer emits `Int->Void` without surrounding
 *    spaces, matching haxe-formatter's output for the old-form arrow.
 *    The new (parenthesised) form `(Int) -> Int`, `(Int, String) -> Bool`
 *    requires a parenthesised-type atom and stays for a follow-up slice.
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
 * convention. Left-nested arrows like `(Int->Bool)->Void` carry an
 * AST-level `Arrow` on the left whose context-precedence (`leftCtx =
 * prec + 1` for right-assoc) forces the writer to wrap them in parens.
 */
@:peg
enum HxType {
	Named(ref:HxTypeRef);

	@:infix('->', 0, 'Right') @:fmt(tight)
	Arrow(left:HxType, right:HxType);

	@:lead('{') @:trail('}') @:sep(',')
	Anon(fields:Array<HxAnonField>);
}
