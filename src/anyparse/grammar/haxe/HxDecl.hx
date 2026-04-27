package anyparse.grammar.haxe;

/**
 * A top-level declaration in a Haxe module.
 *
 * Seven forms are recognised:
 *  - `ClassDecl` — `class Name { ... }` wrapping an `HxClassDecl`.
 *  - `TypedefDecl` — `typedef Name = Type[;]` wrapping an `HxTypedefDecl`.
 *    Carries `@:trailOpt(';')` — the trailing semicolon is optional on
 *    parse (real Haxe accepts both `typedef Foo = Int;` and
 *    `typedef Foo = Int`, and the bare `}` form `typedef T = { x:Int }`
 *    is the dominant convention for anon typedefs in the wild). The
 *    writer keeps emitting `;` as canonical output; preserving source
 *    presence is a separate slice.
 *  - `EnumDecl` — `enum Name { ... }` wrapping an `HxEnumDecl`.
 *  - `InterfaceDecl` — `interface Name { ... }` wrapping an `HxInterfaceDecl`.
 *  - `AbstractDecl` — `abstract Name(Type) [from T]* [to T]* { ... }`
 *    wrapping an `HxAbstractDecl`.
 *  - `VarDecl` — `var name [:Type] [= init];` module-level variable
 *    declaration (slice ω-toplevel-var-fn). Reuses `HxVarDecl` from the
 *    class-member / statement grammar. The `@:kw('var')` lives here, the
 *    body has the same shape, and `@:trailOpt(';')` mirrors
 *    `HxStatement.VarStmt`'s relaxation so a `}`-terminated rhs at module
 *    level (rare, but possible) parses without a trailing semicolon.
 *    Top-level `var`/`function` are not part of Haxe's stable surface
 *    syntax, but the AxGord/haxe-formatter corpus contains plain-snippet
 *    fixtures that drop the `class { ... }` wrapper to keep the test
 *    bodies focused — the formatter accepts module-level `var`/`function`
 *    in those snippets, and so do we to unblock the corpus.
 *  - `FnDecl` — `function name(...) [:Ret] { stmts | expr | ; }` module-
 *    level function declaration (slice ω-toplevel-var-fn). Reuses
 *    `HxFnDecl` from the class-member grammar. The `@:kw('function')`
 *    lives here. Body shape (block / no-body) is unchanged from the
 *    inside-class form.
 *
 * Each branch except `VarDecl` and `FnDecl` carries no `@:kw` — the
 * enclosed sub-rule's first field already consumes the introducer
 * keyword (`class`, `typedef`, `enum`, `interface`, `abstract`). The
 * two new top-level binding ctors break this symmetry because their
 * sub-rules (`HxVarDecl`, `HxFnDecl`) intentionally omit the `var` /
 * `function` keyword — the keyword is owned by the calling context
 * (`HxClassMember`, `HxStatement`, now `HxDecl`).
 */
@:peg
enum HxDecl {
	ClassDecl(decl:HxClassDecl);

	@:trailOpt(';')
	TypedefDecl(decl:HxTypedefDecl);

	EnumDecl(decl:HxEnumDecl);

	InterfaceDecl(decl:HxInterfaceDecl);

	AbstractDecl(decl:HxAbstractDecl);

	@:kw('var') @:trailOpt(';')
	VarDecl(decl:HxVarDecl);

	@:kw('function')
	FnDecl(decl:HxFnDecl);
}
