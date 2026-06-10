package anyparse.grammar.haxe;

/**
 * Bare object-literal field shape — `name: value`. Was the original
 * `HxObjectField` typedef before Slice 18 promoted `HxObjectField` to a
 * sum-type enum to host the cond-comp wrapper. Carried verbatim from
 * the previous typedef: same `HxObjectKeyLit` name terminal, same
 * `@:lead(':') HxExpr` value, same writer-side `@:fmt(objectFieldColon,
 * indentValueIfCtor, propagateExprPosition)` markers.
 *
 * Wrapped in `HxObjectField.Field(body)` rather than living directly on
 * the enum ctor because Haxe rejects field-level `@:fmt` / `@:lead`
 * metadata on individual enum ctor parameters (`Unexpected @` at parse
 * time, see lang-haxe gotcha "Enum Constructor Parameters Cannot Have
 * Metadata — Use a Typedef Instead"). The typedef indirection keeps the
 * full per-field writer/parser metadata stack working through the
 * `@:peg` macro.
 *
 * Doc on the slices (`@:fmt(objectFieldColon)`, `@:fmt(indentValueIfCtor)`)
 * lives on the original typedef site; refer to `HxObjectField` history
 * for the colon-spacing and nested-objectLit-indent rationales — both
 * apply unchanged to this body shape.
 */
@:peg
typedef HxObjectFieldBody = {
	var name: HxObjectKeyLit;
	@:fmt(objectFieldColon, indentValueIfCtor('ObjectLit', 'indentObjectLiteral', 'objectLiteralLeftCurly'), propagateExprPosition) @:lead(':') var value: HxExpr;
}
