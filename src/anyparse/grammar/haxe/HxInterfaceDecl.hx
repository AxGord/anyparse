package anyparse.grammar.haxe;

/**
 * Grammar type for a Haxe interface declaration.
 *
 * Structurally identical to `HxClassDecl` — a keyword-introduced
 * name followed by a close-peek Star field of members inside braces.
 * Shares `HxMemberDecl` for member declarations, so interfaces
 * accept the same `var`/`function` members with optional modifiers.
 *
 * Semantic differences between interfaces and classes (no function
 * bodies, no `static`, mandatory `public`) are not the parser's
 * responsibility — they belong to a later analysis pass.
 *
 * `extends` is deferred to a future slice.
 */
@:peg
typedef HxInterfaceDecl = {
	@:kw('interface') var name:HxIdentLit;
	@:lead('{') @:trail('}') var members:Array<HxMemberDecl>;
}
