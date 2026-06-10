package anyparse.grammar.haxe;

/**
 * Variable declaration body for a class member `var`.
 *
 * Phase 3 slice: name, an optional type annotation prefixed by `:`,
 * and an optional initializer prefixed by `=`. Either, both, or neither
 * may be present — `var x;`, `var x:Int;`, `var x = 1;`, `var x:Int = 1;`
 * all parse. The initializer, when present, is a single `HxExpr` atom
 * (int / bool / null / identifier) — operators, calls, and field access
 * come with the Pratt slice.
 *
 * The `name` field is `HxVarNameLit`, not `HxIdentLit`: the binding-name
 * slot also accepts a macro-reification `$ident` prefix (`var $x = …`,
 * `final $localName = …`). It is a dedicated scoped terminal so the
 * shared `HxIdentLit` (used by `IdentExpr`/`FieldAccess.field`/
 * `DollarIdentExpr.name`) is not widened into `$`-ambiguity. Both are
 * `abstract(String) from/to String`, so the swap is transparent to
 * every `(decl.name : String)` consumer. See `HxVarNameLit`.
 *
 * Modifiers (`public`, `private`, `static`, …) and default values are
 * out of scope for this session.
 *
 * Property accessors are supported via the optional `access` field —
 * the parenthesised `(read, write)` pair (`(get, set)`,
 * `(default, null)`, `(get, never)`, method-name accessors). It sits
 * between `name` and the optional `:Type`; `@:lead('(')` is the
 * optional commit point, the inner shape lives in `HxAccessClause`.
 * `HxVarDecl` is shared by class members, anon-struct fields, and
 * local var statements, so accessors parse in all of those positions —
 * acceptable under the permissive philosophy: valid non-property code
 * never places `(` immediately after a var name.
 *
 * The `var` keyword itself and the trailing `;` live on the enclosing
 * `HxClassMember.VarMember` constructor via `@:kw` / `@:trail` — this
 * typedef only describes the inside.
 *
 * The `init` field is marked both `@:optional` and `Null<HxExpr>`:
 * both axes are required by `ShapeBuilder` so the grammar source
 * documents optionality without forcing a reader to cross-reference
 * the type and the meta list (D23). The `@:lead('=')` is the commit
 * point for the optional — `matchLit` peeks it, and the sub-rule
 * parse only fires when the peek hits (D24).
 *
 * `@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral',
 * 'objectLiteralLeftCurly'))` (slice ω-indent-objectliteral) wraps the
 * writer call for `init` in a runtime gate that — when the bound
 * `HxExpr` ctor is `ObjectLit` AND `opt.indentObjectLiteral` is true
 * (default) AND `opt.objectLiteralLeftCurly` is `Next` (`{` on its own
 * line) — applies a `Nest(_cols, …)` wrap so the value's hardlines
 * pick up one extra indent step. Visible effect under Allman:
 * `var x =\n\t{...}` instead of `var x =\n{...}`, matching haxe-
 * formatter's `indentation.indentObjectLiteral` rule which only fires
 * when `{` lands on its own line. Cuddled `Same` placement is
 * unchanged — the gate is inert because `{` already sits on the parent
 * line.
 *
 * Multi-variable declarations (`var a, b = 1, c = 2;`, typed
 * `var x:T = e1, y:T = e2;`) are supported via the `more` field: a
 * `@:trivia @:tryparse var more:Array<HxVarMore>` Star carrying every
 * binding after the first (each `HxVarMore` is `,` + a full
 * `HxVarDecl`). `var a = 1, b = 2;` parses as
 * `{name: a, init: 1, more: [{decl: {name: b, init: 2}}]}`. The
 * `var`/`final` keyword and trailing `;` stay on the enclosing
 * `VarStmt`/`FinalStmt` ctor, so the list needs no closing delimiter —
 * the `@:tryparse` loop terminates when `HxVarMore`'s `@:lead(',')`
 * misses (the ctor's `@:trailOpt(';')` or a `}` block-end ends the
 * statement). Exact mirror of `HxTypedefDecl.intersections`
 * (`@:trivia @:tryparse Array<HxIntersectionClause>` with an
 * `@:lead(punctuation)` single-field element) — the established
 * open-ended-list-led-by-a-token pattern. For single-binding
 * declarations `more` is the empty array, so the writer emits nothing
 * extra and every existing site is transparent. Like `access`, this is
 * shared by class members and anon-struct fields where a comma list
 * after a single binding is not standard Haxe — accepted under the
 * permissive stance (valid single-binding code never places `,` there).
 *
 * The struct-level `@:fmt(multiVarWrap('multiVarWrap', 'more'))` (slice
 * ω-multivar-wrap) routes the binding list through the `multiVarWrap`
 * `WrapRules` cascade when `more` is non-empty: the head binding plus
 * each `more`-chain binding become head-only item Docs (via a
 * consumed-once `opt._suppressMore` flag that degrades the `more` Star
 * to nothing on the recursive head emit), spliced into one
 * `WrapList.emit('', '', ',', …)`. Drives `var a = …,\n\tb = …,\n\tc = …`
 * one-per-line-after-first / fill-line packing per the cascade. The
 * first arg names the `WriteOptions` knob, the second names the
 * right-recursive list field to walk.
 *
 * A second `@:fmt(indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'))`
 * entry (slice ω-indent-complex-value-expr) stacks on the same field —
 * when the bound `HxExpr` ctor is `IfExpr` AND
 * `opt.indentComplexValueExpressions` is true (non-default), a
 * `Nest(_cols, …)` wrap shifts the if-expression's block bodies one
 * indent step right (`var x = if (cond) {\n\t\t…\n\t};` instead of
 * `var x = if (cond) {\n\t…\n};`). Mirrors haxe-formatter's
 * `indentation.indentComplexValueExpressions` rule. The 2-arg form
 * drops the leftCurly gate — `if` always cuddles its `{`, so a
 * placement check would be inert. Other RHS ctors (calls, binops,
 * literals other than ObjectLit/IfExpr) are unaffected.
 *
 * Slice ω-fieldlevel-var-value-expr-indent extends this `IfExpr` entry on
 * two axes specific to the `indentComplexValueExpressions` knob (see
 * `WriterLowering.indentValueIfCtorWrap`): (1) the ctor match unwraps the
 * transparent prefix-keyword wrappers `untyped` / `inline` / `cast` /
 * `macro`, so `var x = untyped if (…) … else …` (`UntypedExpr(IfExpr(…))`)
 * still indents the inner `if`; (2) when the RHS is a class-member
 * initializer (`opt._inFieldLevelVar`, set at `HxClassMember.VarMember` /
 * `FinalMember` via `@:fmt(propagateFieldLevelVar)`) the indent is forced
 * regardless of the config knob, matching fork's `Indenter.isFieldLevelVar`.
 * Local-var initializers keep the flag false and stay knob-gated.
 *
 * `@:fmt(indentValueIfCtor('Anon', 'indentVarTypeHintAnon',
 * 'anonTypeLeftCurly'))` on the `type` field (slice ω-var-type-hint-
 * anon-indent) extends the same RHS-style indent rule to the type-hint
 * RHS — when the bound `HxType` ctor is `Anon` AND
 * `opt.indentVarTypeHintAnon` is true (default) AND
 * `opt.anonTypeLeftCurly` is `Next` (`{` on its own line) — applies a
 * `Nest(_cols, …)` wrap so the multi-line anon body's hardlines pick up
 * one extra indent step. Visible effect under Allman:
 * `\tvar a:\n\t\t{\n\t\t\tx:Int,…\n\t\t};` instead of
 * `\tvar a:\n\t{\n\t\tx:Int,…\n\t};`, matching the fork's behaviour for
 * multi-line var-type-hint anon types under `lineEnds.leftCurly: "both"`
 * (issue_301 fixture cluster). Single-line anon (`var a:{x:Int}`) stays
 * cuddled under Same — the wrap is inert because no internal hardlines
 * exist. Independent of `init` — both fields can carry their own
 * `indentValueIfCtor` entries simultaneously.
 *
 * Slice 20: a leading `@:trivia @:tryparse var meta:Array<HxMetadata>`
 * Star captures inline metadata between the `var`/`final` keyword and
 * the binding name on a local statement (`var @:name name = 'Foo';` —
 * fork fixture `whitespace/var_meta_data`). Byte-twin of
 * `HxAnonMember.meta` / `HxMemberDecl.meta`: no `@:lead`/`@:trail`/
 * `@:sep`, the try-parse loop attempts an element each iteration and
 * breaks when the next token isn't `@`. Reachable from every consumer
 * (class member, anon struct field, top-level decl, `VarExpr`/
 * `FinalExpr`, `HxVarMore`); on the dominant no-metadata case the Star
 * is empty and every existing site stays byte-identical. At the
 * class-member / anon-struct positions the outer wrapper's metadata
 * (`HxMemberDecl.meta` / `HxAnonMember.meta`) is the canonical slot —
 * the inner Star here is permissive, accepting the unusual
 * `var @:meta x;` placement that would normally be written
 * `@:meta var x;`.
 */
@:peg
@:fmt(multiVarWrap('multiVarWrap', 'more'))
typedef HxVarDecl = {
	@:trivia @:tryparse var meta: Array<HxMetadata>;
	var name: HxVarNameLit;
	@:optional @:fmt(tightLead) @:lead('(') var access: Null<HxAccessClause>;
	@:optional @:fmt(typeHintColon, indentValueIfCtor('Anon', 'indentVarTypeHintAnon', 'anonTypeLeftCurly'))
	@:lead(':') var type: Null<HxType>;
	@:optional
	@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly'),
		indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'), breakAfterLeadIfLhsTypeParam('type'), propagateExprPosition)
	@:lead('=') var init: Null<HxExpr>;
	@:trivia @:tryparse var more: Array<HxVarMore>;
}
