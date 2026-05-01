package anyparse.grammar.haxe;

/**
 * Grammar type for a single Haxe class declaration — the smaller of
 * the two Phase 3 grammar roots. Kept as a stand-alone root (driven
 * by `HaxeParser`) alongside `HxModule` (driven by
 * `HaxeModuleParser`), which wraps zero or more `HxDecl` branches
 * for multi-declaration files. Having both roots live on the same
 * grammar package validates that the marker-class pattern scales to
 * multiple entry points.
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
 * `typeParams` is the close-peek-Star sibling of `HxTypeRef.params`,
 * gated on `@:optional` so the common no-generics case skips the
 * angle brackets. Element type is `HxTypeParamDecl` — declare-site
 * wrapper carrying `name` and an optional single-bound `constraint`
 * (`<T:Foo>`). Defaults (`<T = Int>`) and multi-bound syntax
 * (`<T:A&B>`) are deferred and extend `HxTypeParamDecl` rather than
 * reshape this field.
 *
 * The members field is a `Star` field wrapped in `{` / `}`
 * with no separator between items — each `HxMemberDecl` is
 * self-terminating via its own `;` or `{}` tail. `Lowering`'s new
 * separator-less Star path drives that loop until the closing brace.
 */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
@:fmt(multilineWhenFieldNonEmpty('members'))
typedef HxClassDecl = {
	@:kw('class') var name:HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose) var typeParams:Null<Array<HxTypeParamDecl>>;
	@:fmt(leftCurly, afterFieldsWithDocComments, existingBetweenFields, beforeDocCommentEmptyLines, interMemberBlankLines('member', 'VarMember', 'FnMember')) @:lead('{') @:trail('}') @:trivia var members:Array<HxMemberDecl>;
}
