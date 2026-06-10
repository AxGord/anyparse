package anyparse.grammar.haxe;

/**
 * Grammar type for an enum constructor with parameters.
 *
 * Shape: `Name<TypeParams>(param1:Type, param2:Type)` — a name,
 * optional per-constructor declare-site type parameters, then a
 * parenthesised, comma-separated list of `HxParam` entries (reuses
 * the same typedef as function parameters).
 *
 * `typeParams` is the per-constructor analog of `HxEnumDecl.typeParams`
 * / `HxFnDecl.typeParams` — the same `@:optional @:lead('<') …
 * Array<HxTypeParamDecl>` close-peek Star. `@:optional` keeps plain
 * `Bar(...)` constructors byte-identical: an absent Star emits no
 * `<…>`, so existing parsing and round-trip are unchanged.
 *
 * The `@:lead('(') @:trail(')') @:sep(',')` on `params` selects the
 * sep-peek termination mode in `emitStarFieldSteps`: peek close-char
 * for empty list, then sep-separated loop. Zero-param constructors
 * `Ctor()` parse as `params: []`.
 *
 * The trailing semicolon is NOT on this typedef — it lives on the
 * `HxEnumCtor.ParamCtor` enum branch via `@:trail(';')`.
 */
@:peg
typedef HxEnumCtorDecl = {
	var name: HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams')) var params: Array<HxParam>;
};
