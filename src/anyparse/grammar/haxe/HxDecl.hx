package anyparse.grammar.haxe;

/**
 * A top-level declaration in a Haxe module.
 *
 * Five forms are recognised:
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
 *
 * Each branch's introducer keyword lives inside the enclosed sub-rule's
 * first field via `@:kw`, so the branches here have no `@:kw` — the
 * sub-rule already consumes it. This keeps each sub-rule usable as a
 * stand-alone parser root if needed.
 */
@:peg
enum HxDecl {
	ClassDecl(decl:HxClassDecl);

	@:trailOpt(';')
	TypedefDecl(decl:HxTypedefDecl);

	EnumDecl(decl:HxEnumDecl);

	InterfaceDecl(decl:HxInterfaceDecl);

	AbstractDecl(decl:HxAbstractDecl);
}
