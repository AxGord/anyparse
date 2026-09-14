package anyparse.grammar.haxe;

/**
 * Type-position carrier in the Haxe grammar — the outer Alt enum that fronts every
 * type-position field. `HxTypeRef.params` carries `Array<HxType>`, not `Array<HxTypeRef>`,
 * so type parameters can themselves be arrows or anon structs.
 *
 * `Named(ref:HxTypeRef)` — the named-and-optionally-parameterised type reference (`Int`,
 * `Map<String, Int>`, `haxe.io.Bytes`). `DollarType(name:HxIdentLit)` — a macro-reification
 * escape (`$ident`) in type position, the twin of `HxExpr.DollarIdentExpr`, dispatched by the
 * `$` lead (the `HxTypeRef` name terminal excludes `$`, so `Named` never competes).
 * `ConditionalType(c:HxConditionalType)` — a preprocessor-guarded region `#if cond T1;
 * [#else T2;] #end`, the `@:kw('#if')` + `@:trail('#end')` host twin of
 * `HxExpr.ConditionalExpr`, dispatched by the unique, word-boundary-checked `#if` lead.
 *
 * `Arrow(left:HxType, right:HxType)` — the old (curried) function-arrow type `Int->String->
 * Void`, an `@:infix('->')` branch with `Right` associativity at precedence `0` — the Pratt
 * pattern that powers `HxExpr`; the macro auto-detects the Pratt branch in `Lowering` and
 * emits a precedence-climbing loop around the atom dispatcher, so `Int->Bool->Void` parses
 * as `Arrow(Int, Arrow(Bool, Void))`. Carries `@:fmt(functionTypeHaxe3)` so the writer gates
 * the `->` spacing on `opt.functionTypeHaxe3` (default `None`: `Int->Void`).
 *
 * `Anon(fields:Array<HxAnonMember>)` — anonymous structure type `{x:Int, y:String}` or `{
 * var x:Int; }`, reusing the Case 4 sep-peek Star pattern. `HxAnonMember` wraps `HxAnonField`
 * with a leading metadata Star so `{ @:optional x:Int }` parses. `@:sepAlt(';')` makes the
 * separator tolerant in the non-trivia build: a close-driven loop consumes an OPTIONAL `,`
 * OR `;` between fields, so `;`-terminated class-notation fields, `;`-separated short
 * fields, classic `,`, mixed, and an optional trailing separator all parse. Dispatched by the
 * `{` lead — type position is always after `:`, so no Alt-level ambiguity with
 * `HxStatement.BlockStmt` or `HxExpr.ObjectLit` exists.
 *
 * `ArrowFn(fn:HxArrowFnType)` — the new-form arrow function type `(args) -> ret`, placed
 * BEFORE `Parens` so the parser tries the arrow-fn shape first; when the trailing `->` is
 * absent the branch rolls back and `Parens` takes over. The single-arg `(T) -> R` shape ALSO
 * routes through `ArrowFn` — there is no parser-level disambiguation between "old-form arrow
 * with parens around one positional arg" and "new-form arrow with one positional arg"; the
 * new form is canonical and the writer emits ` -> ` per `functionTypeHaxe4Policy`, so
 * `(Int->Bool) -> Void` parses as `ArrowFn([Positional(Arrow(Int,Bool))], Void)`.
 *
 * `Parens(inner:HxType)` — parenthesised type atom `(T)`, a Case 3 single-Ref `@:wrap('(',
 * ')')` like `HxExpr.ParenExpr`; reached only when `ArrowFn` rolls back.
 */
@:peg
@:fmt(preWrite(HaxeTypeRewrites.arrowFnOldStyleRewrite))
enum HxType {

	Named(ref: HxTypeRef);

	@:lead("$")
	DollarType(name: HxIdentLit);

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
	 * This branch also carries the POSITIONAL optional arg of a new-form
	 * parenthesised arrow: `(?Int) -> Void` parses as
	 * `ArrowFn([Positional(OptionalArg(Named(Int)))], Void)`, because
	 * `HxArrowParam.OptionalNamedParam` needs a `:` after the name and rolls back on a bare type. Same when the optional's type is itself a
	 * function type — `(?Int -> Void) -> Void` is
	 * `Positional(OptionalArg(Arrow(Int, Void)))`, which is what keeps
	 * `HaxeTypeRewrites.arrowFnOldStyleRewrite`'s
	 * `[Positional(Arrow(_, _))]` old-style pattern from firing on it. The NAMED optional
	 * `(?x:Int) -> Void` is the one that lives on `HxArrowParam.OptionalNamedParam`.
	 */
	@:lead('?')
	OptionalArg(inner: HxType);

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
	ConstStringType(v: HxDoubleStringLit);

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
	BracketExprListType(elems: Array<HxExpr>);

	@:kw('#if') @:trail('#end') @:fmt(spaceBeforeTrail)
	ConditionalType(c: HxConditionalType);

	@:infix('->', 0, 'Right') @:fmt(functionTypeHaxe3)
	Arrow(left: HxType, right: HxType);

	/**
	 * `@:fmt(typedefBodyBlanks)` (slice ω-typedef-between-fields) opts this
	 * sep-Star into typedef-scoped blank-line injection. Active only when
	 * the descendant anon body sees `opt._inTypedefBody == true` (set by
	 * `HxTypedefDecl.type`'s `propagateTypedefContext`), so the
	 * `emptyLines.typedefEmptyLines.beginType` / `betweenFields` knobs
	 * insert blank lines after the opening `{` and between adjacent fields
	 * in the `@:sep`-Star force-multi branch — without touching inline
	 * anon-type uses (`var x:{a:Int}`), which never carry the flag.
	 *
	 * `@:fmt(forceMultiInTypedef)` doubles as the typedef-awareness marker
	 * for the source-newline policy: `wrapping.anonType.defaultWrap:
	 * "ignore"` re-flows an INLINE anon type hint by width (fits → one
	 * line, exceeds → one field per line), but the drop is gated off while
	 * `opt._inTypedefBody` holds, so a typedef RHS body keeps its source
	 * line structure. The fork needs no such gate — it classifies the
	 * typedef brace as `BrOpenType.TypedefDecl` and routes it to
	 * `MarkWrapping.typedefWrapping`, which never reads `wrapping.anonType`.
	 */
	@:trivia @:lead('{') @:trail('}') @:sep(',') @:sepAlt(';') @:fmt(anonTypeBracesOpen, anonTypeBracesClose, wrapRules('anonTypeWrap'),
		leftCurly('anonTypeLeftCurly'), rightCurly('anonTypeRightCurly'), beforeDocCommentEmptyLines, forceMultiInTypedef,
		keepCurlyBlanks, typedefBodyBlanks, groupRestProbe, trailingComma('trailingCommaAnonTypes'))
	Anon(fields: Array<HxAnonMember>);

	ArrowFn(fn: HxArrowFnType);

	@:wrap('(', ')')
	Parens(inner: HxType);

}
