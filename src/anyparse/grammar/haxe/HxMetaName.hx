package anyparse.grammar.haxe;

/**
 * Metadata-tag name terminal — `@name` (user metadata) or `@:name`
 * (compiler metadata). The leading `@` is part of the captured
 * string so the writer can emit the value verbatim without
 * threading the prefix as a separate field.
 *
 * Used by `HxMetadata.Meta(name:HxMetaName, args:Null<Array<HxExpr>>)`,
 * the generic structural branch that mirrors Haxe's
 * `MetadataEntry { name:String, params:Null<Array<Expr>> }` shape.
 * Args parse through the standard `HxExpr` pipeline — the same
 * code path that handles call arguments — so format-driven knobs
 * (`anonFuncParens`, `typeHintColon`, `funcParamParens`) apply
 * uniformly to metadata-arg shapes without per-meta grammar.
 *
 * The pattern matches Haxe's metadata tag path: a dot-separated
 * identifier run (`@:flash.property`, `@a.b.c`) behind the optional
 * `:` compiler-meta marker prefix, same shape as `HxTypeName`. Each
 * `.` must be followed by an identifier, so a float literal or a
 * field access belonging to a following expression can never be
 * absorbed into the tag. `from String to String` keeps test
 * call-site literals compiling without explicit casts. `@:rawString`
 * routes the matched slice through `Lowering.lowerTerminal` without
 * the JSON-style unescape loop — meta tag names are not Haxe string
 * literals.
 */
@:re('@:?[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*')
@:rawString
abstract HxMetaName(String) from String to String {}
