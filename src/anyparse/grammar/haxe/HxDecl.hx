package anyparse.grammar.haxe;

/**
 * A top-level declaration in a Haxe module.
 *
 * Four forms are recognised:
 *  - `ClassDecl` — `class Name { ... }` wrapping an `HxClassDecl`.
 *  - `TypedefDecl` — `typedef Name = Type;` wrapping an `HxTypedefDecl`.
 *    Carries `@:trail(';')` because the typedef has no closing brace.
 *  - `EnumDecl` — `enum Name { ... }` wrapping an `HxEnumDecl`.
 *  - `InterfaceDecl` — `interface Name { ... }` wrapping an `HxInterfaceDecl`.
 *
 * Each branch's introducer keyword lives inside the enclosed sub-rule's
 * first field via `@:kw`, so the branches here have no `@:kw` — the
 * sub-rule already consumes it. This keeps each sub-rule usable as a
 * stand-alone parser root if needed.
 *
 * `abstract` declarations are deferred — they have unique syntax
 * (`(UnderlyingType)`, `from/to`) requiring new patterns.
 */
@:peg
enum HxDecl {
	ClassDecl(decl:HxClassDecl);

	@:trail(';')
	TypedefDecl(decl:HxTypedefDecl);

	EnumDecl(decl:HxEnumDecl);

	InterfaceDecl(decl:HxInterfaceDecl);
}
