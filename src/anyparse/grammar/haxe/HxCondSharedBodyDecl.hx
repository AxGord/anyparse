package anyparse.grammar.haxe;

/**
 * Declaration-scope token-splice conditional whose branches are PARALLEL type-declaration
 * headers, each opening the body, with the members and the closing `}` living AFTER `#end`
 * and shared by every compilation variant:
 *
 * ```haxe
 * #if starling
 * class TooltipSource extends MovieClip implements IStarlingConvertible {
 * #else
 * class TooltipSource extends MovieClip {
 * #end
 * }
 * ```
 *
 * The Haxe compiler evaluates the condition at LEX time and parses one branch; a formatter rewrites the file,
 * so BOTH branches have to survive the write.
 *
 * SHAPE — first branch live, alternates raw: `head` parses the FIRST branch STRUCTURALLY (the `@:trail('{')`
 * on each `HxDeclHead` branch consumes the brace that branch opens); `alt` captures `#else` / `#elseif`
 * through `#end` byte-verbatim; `members` parses the shared member list, and its own `@:trail('}')` closes the
 * body — on `members` rather than on the owning ctor so the Star can also carry `@:fmt(rightCurly)`, which
 * puts the closer on its own line at the OUTER indent. The first branch's type name, type parameters, heritage
 * and every shared member therefore stay in the tree and queryable; the alternative headers are not.
 *
 * WHY NOT SPLICE THE WHOLE REGION: `HxCondSpliceRaw` swallows from the `#if` to the `#end`; after that the
 * parser meets a stray `}` with no body to close. WHY NOT CAPTURE THE WHOLE ENCLOSING DECLARATION RAW: it
 * would blind the MEMBERS too, which is exactly what the parse is for. WHY NOT AN OPTIONAL ALTERNATE SLOT ON
 * `HxClassDecl`: it would have to go between `heritage` and `members`, and FIELD POSITION is load-bearing for
 * the writer's trivia slots — shifting `members` would move every class declaration's slot. A MEMBER-scope
 * ctor keyed on `#else` fails harder: `HxConditionalMember.body` is the same `Array<HxMemberDecl>` and must
 * STOP at `#else` so the region's own `elseBody` slot fires.
 *
 * `meta` and `modifiers` are duplicated from `HxTopLevelDecl` rather than reusing it, because `HxTopLevelDecl`
 * requires a complete `HxDecl` and here the declaration is cut in half; the tags inside the region belong to
 * the first branch (`@:forward(id, refs) abstract GLProgram(...)`, `@:generic class TypedPool1<...>`).
 * Dispatch: `HxDecl.CondSharedBodyDecl` is tried AFTER `HxDecl.Conditional`, like the member- and
 * statement-scope splice ctors, so every balanced region keeps its structure.
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
