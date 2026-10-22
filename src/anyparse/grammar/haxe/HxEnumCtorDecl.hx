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
 * `params` is laid out as the function signature it is: a `@:trivia` Star with `HxFnDecl.params`'
 * wrap set, so a `#if` region keeps exactly the separators the source wrote (per-element
 * `sepAfter`) and a comment between parameters rides its element instead of being dropped.
 *
 * `returnType` is the GADT result type (`Errored(e:Error):Status<Error>;`), absent on a
 * plain constructor, which therefore stays byte-identical.
 *
 * The trailing semicolon is NOT on this typedef — it lives on the
 * `HxEnumCtor.ParamCtor` enum branch via `@:trail(';')`.
 */
@:peg
typedef HxEnumCtorDecl = {
	var name: HxIdentLit;
	@:optional @:lead('<') @:trail('>') @:sep(',') @:fmt(typeParamOpen, typeParamClose, wrapRules('typeParameterWrap'), groupRestProbe) var typeParams: Null<Array<HxTypeParamDecl>>;
	@:trivia @:lead('(') @:trail(')') @:sep(',') @:fmt(trailingComma('trailingCommaParams'), wrapRules('functionSignatureWrap'),
		bodyAwareCompactIndent, groupRestProbe, ignoreSourceNewlinesForWrap) var params: Array<HxParam>;
	@:optional @:fmt(typeHintColon) @:lead(':') var returnType: Null<HxType>;
};
