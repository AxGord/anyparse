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
 *    the atom dispatcher. Carries `@:fmt(functionTypeHaxe3)` so the
 *    writer gates the `->` spacing on `opt.functionTypeHaxe3:
 *    WhitespacePolicy` (haxe-formatter's `whitespace.
 *    functionTypeHaxe3Policy: @:default(None)`); default `None` emits
 *    `Int->Void` without surrounding spaces, `"around"` flips to
 *    spaced `Int -> Void`. The new (parenthesised) form `(args) -> ret`
 *    lives on the separate `ArrowFn` variant below and is gated by the
 *    sibling `functionTypeHaxe4Policy` knob.
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

	/**
	 * Constant string literal in a type-parameter slot —
	 * `hl.Abstract<"hl_tls">`, `flixel.util.FlxSignal<"foo">`. Single-Ref
	 * leaf wrapping the existing `HxDoubleStringLit` terminal; dispatch
	 * is by the terminal's `@:re '"..."'` regex (same path
	 * `HxExpr.DoubleStringExpr` uses, no `@:lead` needed — `"` is not a
	 * legal start for any other `HxType` atom). Writer emits the raw
	 * source slice verbatim via `HxDoubleStringLit`'s `@:rawString`
	 * carrier, so the construct round-trips byte-identically with zero
	 * writer fork. Only the string-literal const form is added — `Int`,
	 * `Float`, identifier consts as type-param values appear in no
	 * current skip-parse fixture and stay deferred to a follow-up slice
	 * if they ever land in the corpus.
	 */
	ConstStringType(v:HxDoubleStringLit);

	/**
	 * Macro-expression bracket list in a type-parameter slot —
	 * `haxe.macro.MacroType<[…]>`. The `[…]` body is a comma-separated
	 * list of expressions (typically build-macro calls like
	 * `cdb.Module.build("data.cdb")`) that `haxe.macro.MacroType<T>`
	 * wires through at compile time to inject a macro-built type.
	 *
	 * Verbatim byte-twin of `HxExpr.ArrayExpr`'s `@:lead('[')
	 * @:trail(']') @:sep(',')` Star-of-HxExpr pattern, applied to a
	 * type-position host. Cross-enum recursion (`HxType` → `HxExpr`)
	 * is the same direction `HxExpr.MacroTypeExpr(t:HxType)` already
	 * relies on. Generic Star writer emits `[elem1, elem2, …]`
	 * byte-identically; no fmt directives wired — the corpus driver
	 * (`whitespace/issue_622_bracket`) uses a single-element body,
	 * multi-element trailing-comma and wrap policies are deferred to
	 * a follow-up if a multi-element fixture ever lands in the corpus.
	 *
	 * Dispatched by the `[` lead — no other `HxType` atom begins with
	 * `[`, so Alt-level ambiguity is impossible. The Star is unbounded
	 * by the `@:sep+@:trail` mechanism, so empty `<[]>` parses as well
	 * (no corpus fixture exercises the empty form; structural
	 * completeness leftover).
	 */
	@:trivia @:lead('[') @:trail(']') @:sep(',')
	BracketExprListType(elems:Array<HxExpr>);

	@:kw('#if') @:trail('#end') @:fmt(spaceBeforeTrail)
	ConditionalType(c:HxConditionalType);

	@:infix('->', 0, 'Right') @:fmt(functionTypeHaxe3)
	Arrow(left:HxType, right:HxType);

	/**
	 * `@:fmt(typedefBodyBlanks)` (slice ω-typedef-between-fields) opts this
	 * sep-Star into typedef-scoped blank-line injection. Active only when
	 * the descendant anon body sees `opt._inTypedefBody == true` (set by
	 * `HxTypedefDecl.type`'s `propagateTypedefContext`), so the
	 * `emptyLines.typedefEmptyLines.beginType` / `betweenFields` knobs
	 * insert blank lines after the opening `{` and between adjacent fields
	 * in the `@:sep`-Star force-multi branch — without touching inline
	 * anon-type uses (`var x:{a:Int}`), which never carry the flag.
	 */
	@:trivia @:lead('{') @:trail('}') @:sep(',') @:sepAlt(';') @:fmt(anonTypeBracesOpen, anonTypeBracesClose, wrapRules('anonTypeWrap'), leftCurly('anonTypeLeftCurly'), rightCurly('anonTypeRightCurly'), beforeDocCommentEmptyLines, forceMultiInTypedef, keepCurlyBlanks, typedefBodyBlanks, groupRestProbe)
	Anon(fields:Array<HxAnonMember>);

	ArrowFn(fn:HxArrowFnType);

	@:wrap('(', ')')
	Parens(inner:HxType);
}
