package anyparse.grammar.haxe;

/**
 * Declaration-scope token-splice conditional whose branches are PARALLEL
 * type-declaration headers, each opening the body, with the members and
 * the closing `}` living AFTER `#end` and shared by every compilation
 * variant:
 *
 * ```haxe
 * #if starling
 * class TooltipSource extends MovieClip implements IStarlingConvertible {
 * #else
 * class TooltipSource extends MovieClip {
 * #end
 *     ... members ...
 * }
 * ```
 *
 * (`pony/flash/ui/TooltipSource.hx:16`; also `pony/flash/ui/Window.hx`,
 * `pony/TypedPool.hx`, `lime/net/HTTPRequest.hx`, and the `abstract`
 * form in `lime/graphics/opengl/GLProgram.hx`, `.../GLShader.hx`,
 * `lime/graphics/OpenGLES3RenderContext.hx` and
 * `lime/graphics/WebGL2RenderContext.hx`.)
 *
 * The Haxe compiler never sees the problem - it evaluates the condition
 * at LEX time and parses one branch. A formatter cannot: `hxq fmt
 * --write` rewrites the file, so a branch that was never parsed would be
 * DELETED from it. BOTH branches have to survive the write.
 *
 * SHAPE - first branch live, alternates raw:
 *
 *  - `head` parses the FIRST branch STRUCTURALLY, and its `@:trail('{')`
 *    consumes the brace that branch opens;
 *  - `alt` captures `#else` / `#elseif` through `#end` byte-verbatim;
 *  - `members` parses the shared member list, and the owning ctor's
 *    `@:trail('}')` closes the body.
 *
 * The first branch's type name, type parameters, heritage and every
 * shared member therefore stay in the tree and queryable; the
 * alternative headers are not. That asymmetry is accepted and intended -
 * the same blindness already holds for `#if` bodies generally.
 *
 * WHY NOT SPLICE THE WHOLE REGION. `HxCondSpliceRaw` swallows from the
 * `#if` to the `#end`; after that the parser meets a stray `}` with no
 * body to close, so the existing splice ctors cannot represent this
 * shape at all.
 *
 * WHY NOT CAPTURE THE WHOLE ENCLOSING DECLARATION RAW. That was the
 * other option, and it was rejected: it would blind the MEMBERS too,
 * which is exactly what the parse is for.
 *
 * WHY NOT EXTEND `HxClassDecl` WITH AN OPTIONAL ALTERNATE SLOT. The
 * region's `#else` sits between the `{` and the first member, so the
 * slot would have to be inserted into `HxClassDecl` between its
 * `heritage` and `members` fields. FIELD POSITION is load-bearing for
 * the writer's trivia slots - shifting `members` would move every class
 * declaration's slot in the corpus. Modelling the alternate as a
 * MEMBER-scope ctor keyed on `#else` fails for a harder reason:
 * `HxConditionalMember.body` is the same `Array<HxMemberDecl>` and must
 * STOP at `#else` so the region's own `elseBody` slot can fire, and a
 * `#else`-led member would make it consume the clause instead.
 *
 * `meta` and `modifiers` are duplicated from `HxTopLevelDecl` rather
 * than reusing it, because `HxTopLevelDecl` requires a complete `HxDecl`
 * and the whole point here is that the declaration is cut in half. The
 * tags inside the region belong to the first branch -
 * `@:forward(id, refs) abstract GLProgram(...)` in `GLProgram.hx`,
 * `@:generic class TypedPool1<...>` in `TypedPool.hx`.
 *
 * Dispatch: `HxDecl.CondSharedBodyDecl` is tried AFTER
 * `HxDecl.Conditional`, mirroring `HxClassMember.CondSpliceMember` after
 * `HxClassMember.Conditional` and `HxStatement.CondSpliceStmt` after
 * `HxStatement.Conditional`, so every balanced `#if` declaration region
 * keeps its structured representation.
 */
@:peg
typedef HxCondSharedBodyDecl = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading) var meta: Array<HxMetadata>;
	@:trivia @:tryparse @:fmt(forceInlineSep) var modifiers: Array<HxModifier>;
	var head: HxDeclHead;
	var alt: HxCondAltRaw;
	@:trail('}') @:trivia @:fmt(padLeading, nestBody, existingBetweenFields, rightCurly) var members: Array<HxMemberDecl>;
}
