package anyparse.grammar.haxe;

/**
 * Optional name of a `macro class` reification head — a standard Haxe
 * identifier with an optional leading `$` for macro name-reification
 * (`macro class $name { … }`), or a plain identifier
 * (`macro class Foo { … }`), or absent (`macro class { … }`).
 *
 * Exact mirror of `HxFieldNameLit` (transparent `String` abstract,
 * `@:re` picked up by the `Re` strategy, `@:rawString` so the matched
 * slice is used verbatim) differing only in semantic role. A dedicated
 * terminal — rather than reusing `HxFieldNameLit` — keeps that type's
 * documented "field-access slot only" contract intact (the Slice 4
 * precedent: clone over cross-position reuse for clarity + zero churn).
 * Every other identifier position keeps `HxIdentLit`, so `$`-prefixed
 * names are not accepted as variable / type names.
 *
 * The `$` is kept inside the matched slice, so the generic single-Ref
 * writer path round-trips `macro class $name` byte-for-byte with no
 * format-side change (the Slice 4 `$` rides verbatim pattern). Purely
 * syntactic — no reification semantics, in line with `HxDollarReif`'s
 * "intentionally permissive" philosophy.
 *
 * Presence vs absence of the name is disambiguated one level up by
 * `HxMacroClassHead` (`NamedHead` carrying this terminal, tried before
 * the parameterless `AnonHead`), not by an optional field here — a
 * regex terminal cannot match the empty string.
 *
 * `@:re` argument is double-quoted: a single-quoted metadata string
 * subjects `$` to Haxe interpolation, which would corrupt the pattern.
 *
 * `from String to String` keeps call-site literals and test
 * pattern-matches compiling without casts.
 */
@:re("\\$?[A-Za-z_][A-Za-z0-9_]*")
@:rawString
abstract HxMacroClassName(String) from String to String {}
