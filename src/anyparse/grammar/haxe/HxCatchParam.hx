package anyparse.grammar.haxe;

/**
 * Body shape for the `(name [: Type])` slot of a catch clause —
 * the name + optional type-annotation pair shared by all three
 * catch-clause sibling typedefs (`HxCatchClause`,
 * `HxCatchClauseStmtBare`, `HxCatchClauseExpr`).
 *
 * Lifted out of the original per-sibling fields when the bare
 * `catch (name)` form (e.g. `catch (_)`) was added: the closing
 * `)` of the catch parens must always be consumed, but the
 * `:Type` annotation is optional. Lowering's `@:optional @:lead(':')
 * @:trail(')')` combination would skip the trail when the lead
 * misses, so the trail can't sit on the type field directly. The
 * wrapper carries the inner shape; the parent sibling's
 * `@:trail(')')` then fires unconditionally on the wrapper field.
 *
 * Mirror of the `HxParamBody` / `HxLambdaParamBody` pattern (name +
 * optional `:Type`), minus the default-value slot — catch clauses
 * have no default-value form in any Haxe surface syntax.
 *
 * `@:fmt(typeHintColon)` on `type` mirrors `HxParamBody.type` /
 * `HxLambdaParamBody.type` / `HxVarDecl.type`: the colon emission
 * flips between tight (`e:E`) and around (`e : E`) per
 * `HxModuleWriteOptions.typeHintColon`.
 */
@:peg
typedef HxCatchParam = {
	var name:HxIdentLit;
	@:optional @:fmt(typeHintColon) @:lead(':') var type:Null<HxType>;
}
