package anyparse.grammar.haxe;

/**
 * Root grammar type for the Phase 3 Haxe skeleton — a single class
 * declaration in a file. Multi-declaration modules are out of scope:
 * a file with two top-level classes is not valid input for the current
 * parser.
 *
 * Grammar metadata:
 *  - `@:peg` marks this as a grammar entry point.
 *  - `@:schema(HaxeFormat)` binds the grammar to `HaxeFormat` so the
 *    macro pipeline's `FormatReader` reads its `whitespace` field at
 *    compile time.
 *  - `@:ws` activates cross-cutting whitespace skipping before every
 *    literal and regex match in the generated parser.
 *
 * The first field (`name`) uses `@:kw('class')` — the Kw strategy
 * emits a `class` keyword match with a word boundary, so `classy` is
 * not accepted as `class` followed by `y` (the word-boundary check
 * fails and the parser rejects the input).
 *
 * The second field (`members`) is a `Star` field wrapped in `{` / `}`
 * with no separator between items — each `HxClassMember` is
 * self-terminating via its own `;` or `{}` tail. `Lowering`'s new
 * separator-less Star path drives that loop until the closing brace.
 */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
typedef HxClassDecl = {
	@:kw('class') var name:HxIdentLit;
	@:lead('{') @:trail('}') var members:Array<HxClassMember>;
}
