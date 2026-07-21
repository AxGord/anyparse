package anyparse.grammar.haxe;

/**
 * Dispatch over the bodyless type-declaration headers a conditional
 * region can hold - the `head` field of `HxCondSharedBodyDecl`.
 *
 * Only the two forms observed in the wild are branches: `class` and
 * `abstract`. Every skip-parse source that motivated the shared-body
 * declaration production splits on one of them
 * (`pony/flash/ui/TooltipSource.hx`, `pony/flash/ui/Window.hx`,
 * `pony/TypedPool.hx`, `lime/net/HTTPRequest.hx` are `class`;
 * `lime/graphics/opengl/GLProgram.hx`, `.../GLShader.hx`,
 * `lime/graphics/OpenGLES3RenderContext.hx`,
 * `lime/graphics/WebGL2RenderContext.hx` are `abstract`). `interface`,
 * `enum` and `enum abstract` get no branch until a live source needs
 * one - each would be a new head typedef duplicating another decl's
 * fields, and speculative ones would only widen the dispatch.
 *
 * SCOPE DISCIPLINE. This enum is referenced ONLY from
 * `HxCondSharedBodyDecl`, mirroring the `HxMemberModifier` (narrow,
 * ordinary position) vs `HxModifier` (broad, conditional-region bodies
 * only) precedent. A bodyless `class Foo` must never be reachable from
 * the ordinary `HxDecl` dispatch, where it would shadow `ClassDecl` and
 * accept a class with no body at all.
 *
 * Branch order is documentation rather than disambiguation: `class` and
 * `abstract` are distinct `@:kw` tokens owned by the payload typedefs,
 * so the branches are disjoint.
 */
@:peg
enum HxDeclHead {

	@:trail('{') @:fmt(spaceBeforeTrail)
	ClassHead(head: HxClassDeclHead);

	@:trail('{') @:fmt(spaceBeforeTrail)
	AbstractHead(head: HxAbstractDeclHead);

}
