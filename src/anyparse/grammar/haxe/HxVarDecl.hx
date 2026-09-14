package anyparse.grammar.haxe;

/**
 * Variable declaration body shared by class members, anon-struct fields and local `var` /
 * `final` statements: `[@:meta] name [(access)] [:Type] [#if c = e #end | = init] [, more]*`.
 * The keyword and the trailing `;` live on the enclosing ctor — this is the inside only.
 *
 * `name` is `HxVarNameLit`, not `HxIdentLit`: the binding-name slot also accepts a
 * macro-reification `$ident` prefix without widening the shared `HxIdentLit` into
 * `$`-ambiguity (both are `abstract(String) from/to String`, so the swap is transparent).
 * `access` is the optional parenthesised `(read, write)` accessor pair; `@:lead('(')` is the
 * commit point, the inner shape lives in `HxAccessClause`; it parses in every position this
 * typedef reaches, acceptable since valid non-property code never places `(` after a var
 * name. `init` is `@:optional` AND `Null<HxExpr>` — both axes are required by `ShapeBuilder`
 * (D23); `@:lead('=')` is the commit point (D24). A leading `@:trivia @:tryparse var
 * meta:Array<HxMetadata>` Star captures inline metadata between the keyword and the name
 * (`var @:name name = 'Foo';`), the byte-twin of `HxMemberDecl.meta`; at member positions
 * the outer wrapper's slot is canonical and this Star is permissive.
 *
 * Multi-variable declarations (`var a, b = 1, c = 2;`) go through `more`: a `@:trivia
 * @:tryparse Array<HxVarMore>` Star carrying every binding after the first (each `HxVarMore`
 * is `,` + a full `HxVarDecl`); the loop terminates when the `@:lead(',')` misses. The
 * struct-level `@:fmt(multiVarWrap('multiVarWrap', 'more'))` routes the binding list through
 * the `multiVarWrap` cascade when `more` is non-empty: head plus chain bindings become
 * head-only item Docs (a consumed-once `opt._suppressMore` flag degrades the `more` Star on
 * the recursive head emit) spliced into one `WrapList.emit('', '', ',', …)`.
 *
 * `@:fmt(indentValueIfCtor(...))` entries wrap a field's writer call in a runtime gate that
 * applies a `Nest(_cols, …)` when the bound ctor and the named knobs match: on `init`,
 * `ObjectLit` under `indentObjectLiteral` AND `objectLiteralLeftCurly == Next`, and `IfExpr`
 * under `indentComplexValueExpressions` (the ctor match unwraps the transparent `untyped` /
 * `inline` / `cast` / `macro` wrappers, and the indent is forced regardless of the knob when
 * `opt._inFieldLevelVar` is set by `HxClassMember`'s `propagateFieldLevelVar`); on `type`,
 * `Anon` under `indentVarTypeHintAnon` AND `anonTypeLeftCurly == Next`. Each is inert when
 * `{` sits on the parent line or the value renders flat.
 *
 * `condInit` is the optional `#if <cond> = <expr> #end` slot — a preprocessor-guarded
 * initializer whose `=` lives inside the region (`var current:MovieClip #if flash =
 * flash.Lib.current #end;`); the `#if` rides the field while `#end` rides the
 * `HxVarInitRegion` branch. It sits BETWEEN `type` and `init`, and that position is
 * load-bearing: placed AFTER `init` it shifts the writer's blank-line-after-decl trivia slot.
 */
@:peg
@:fmt(multiVarWrap('multiVarWrap', 'more'))
typedef HxVarDecl = {
	@:trivia @:tryparse var meta: Array<HxMetadata>;
	var name: HxVarNameLit;
	@:optional @:fmt(tightLead) @:lead('(') var access: Null<HxAccessClause>;
	@:optional @:fmt(typeHintColon, indentValueIfCtor('Anon', 'indentVarTypeHintAnon', 'anonTypeLeftCurly'))
	@:lead(':') @:queryTypeSlot var type: Null<HxType>;
	@:optional @:kw('#if') var condInit: Null<HxVarInitRegion>;
	@:optional
	@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly'),
		indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'), breakAfterLeadOnOverflow('type'), propagateExprPosition)
	@:lead('=') var init: Null<HxExpr>;
	@:trivia @:tryparse var more: Array<HxVarMore>;
}
