package anyparse.grammar.haxe;

/**
 * An `abstract` declaration's header WITHOUT its body: the `abstract`
 * keyword, the name, optional type parameters, the parenthesised
 * underlying type and the `from` / `to` clauses - every field of
 * `HxAbstractDecl` except `members`, which owns the `{ ... }`.
 *
 * Twin of `HxClassDeclHead`; see that type for why the fields are copied
 * verbatim instead of being factored out of `HxAbstractDecl`, and
 * `HxCondSharedBodyDecl` for the shape that needs a bodyless header.
 *
 * Motivating source - `lime/graphics/opengl/GLProgram.hx:13`:
 *
 * ```haxe
 * #if !lime_webgl
 * @:forward(id, refs) abstract GLProgram(GLObject) from GLObject to GLObject
 * {
 * #else
 * @:forward() abstract GLProgram(js.html.webgl.Program) from js.html.webgl.Program to js.html.webgl.Program
 * {
 * #end
 * ```
 *
 * `enum abstract` needs no separate head type: the `enum` keyword lives
 * on `HxDecl.EnumAbstractDecl`, not on `HxAbstractDecl`, so a future
 * `EnumAbstractHead` branch would reuse this same payload. None is added
 * until a live source needs one.
 */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
typedef HxAbstractDeclHead = {
	@:kw('abstract') var name: HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:optional @:lead('(') @:trail(')') @:fmt(tightLead) var underlyingType: Null<HxType>;
	@:trivia @:tryparse @:fmt(padLeading, lineLengthAwareSeps) var clauses: Array<HxAbstractClause>;
}
