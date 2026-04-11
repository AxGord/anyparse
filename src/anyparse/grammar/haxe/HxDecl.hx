package anyparse.grammar.haxe;

/**
 * A top-level declaration in a Haxe module.
 *
 * The Phase 3 multi-decl slice recognises a single form: a class
 * declaration wrapping an `HxClassDecl`. Future branches for
 * `typedef`, `enum`, `abstract`, and `interface` decls will each
 * carry their own introducer keyword via `@:kw` on the constructor.
 *
 * The `class` keyword itself lives inside `HxClassDecl.name`'s
 * `@:kw('class')` annotation, so the `ClassDecl` branch here has no
 * `@:kw` / `@:lead` — the enclosed sub-rule already consumes it.
 * This keeps `HxClassDecl` usable as a stand-alone parser root in
 * addition to being a module decl, which matters because the
 * original `HaxeFastParser` (rooted on `HxClassDecl`) still exists
 * alongside the new `HaxeModuleFastParser`.
 */
@:peg
enum HxDecl {
	ClassDecl(decl:HxClassDecl);
}
