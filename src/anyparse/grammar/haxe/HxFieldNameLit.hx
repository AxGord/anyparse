package anyparse.grammar.haxe;

/**
 * Field-access suffix terminal — a standard Haxe identifier with an
 * optional leading `$` for macro field-reification (`obj.$name`,
 * `$struct.$name`).
 *
 * Exact mirror of `HxIdentLit` (transparent `String` abstract, `@:re`
 * picked up by the `Re` strategy, `@:rawString` so the matched slice is
 * used verbatim) differing only by the optional `\$?` prefix. Used
 * solely as the `field` slot of `HxExpr.FieldAccess`; every other
 * identifier position keeps `HxIdentLit` so `$`-prefixed names are not
 * accepted as variable/type names.
 *
 * The `$` is kept inside the matched slice, so the writer's
 * `'.' + field` method-chain emission and the generic single-Ref
 * postfix path both round-trip `obj.$name` byte-for-byte with no
 * format-side change. Purely syntactic — no reification semantics, in
 * line with `HxDollarReif`'s "intentionally permissive" philosophy.
 *
 * The recursive `obj.${expr}` (DollarBlock) field form is intentionally
 * out of scope: a regex terminal cannot carry a nested expression, and
 * no non-compounding corpus fixture requires it. It is a future slice
 * (a sum-type field) if one ever does.
 *
 * `@:re` argument is double-quoted: a single-quoted metadata string
 * subjects `$` to Haxe interpolation, which would corrupt the pattern.
 *
 * `from String to String` keeps existing call-site literals and the
 * ~20 `FieldAccess(o, f)` test pattern-matches compiling without casts.
 */
@:re("\\$?[A-Za-z_][A-Za-z0-9_]*")
@:rawString
abstract HxFieldNameLit(String) from String to String {}
