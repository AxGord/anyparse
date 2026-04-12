package anyparse.grammar.haxe;

/**
 * Grammar type for a single enum constructor inside an enum body.
 *
 * Phase 3 skeleton: zero-arg constructors only — `Name;`. The
 * trailing semicolon on the `name` field makes each constructor
 * self-terminating inside the close-peek Star loop of
 * `HxEnumDecl.ctors`.
 *
 * Constructors with parameters (`Rgb(r:Int, g:Int, b:Int)`) are
 * deferred to a future slice.
 */
@:peg
typedef HxEnumCtor = {
	@:trail(';') var name:HxIdentLit;
}
