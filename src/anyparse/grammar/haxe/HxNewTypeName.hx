package anyparse.grammar.haxe;

/**
 * Constructor-target type-name terminal — `HxTypeName` byte-twin with an
 * optional leading `$` for macro type-reification in `new` expressions
 * (`new $tp()`, `new $tp.Sub(args)`).
 *
 * Exact mirror of `HxTypeName` (transparent `String` abstract, `@:re`
 * picked up by the `Re` strategy, `@:rawString` so the matched slice is
 * used verbatim) differing only by the optional `\$?` prefix on the
 * first segment. Used solely as the `type` slot of `HxNewExpr`; every
 * other type-position keeps `HxTypeName` so `$`-prefixed names are not
 * accepted as class names, import paths, or named `HxTypeRef` heads —
 * preserving the documented `HxType.Named` vs `HxType.DollarType`
 * dispatch contract (a `$`-bearing `HxTypeName` on `HxTypeRef.name`
 * would shadow `DollarType`, since `Named` is the first `HxType` branch).
 *
 * The `$` is kept inside the matched slice, so the writer's verbatim
 * raw-String emission of `HxNewExpr.type` round-trips `new $tp()`
 * byte-for-byte with no format-side change. Purely syntactic — no
 * reification semantics, in line with `HxDollarReif` / `HxFieldNameLit`'s
 * "intentionally permissive" philosophy. Dotted continuation
 * (`$tp.Sub.Inner`) is supported by repeating the post-`$?` ident
 * segment after `.`, matching the `HxTypeName` dotted shape.
 *
 * `@:re` argument is double-quoted: a single-quoted metadata string
 * subjects `$` to Haxe interpolation, which would corrupt the pattern.
 *
 * `from String to String` keeps existing call-site literals and the
 * 15 `(ne.type : String)` test pattern-matches compiling without casts.
 *
 * Recursive `new ${expr}()` (DollarBlock-typed) is intentionally out of
 * scope: a regex terminal cannot carry a nested expression, and the
 * skip-parse corpus only exercises the bare `$ident` form
 * (`issue_219_macro_reification_comma`). It is a future slice (a
 * sum-type field) if a non-compounding fixture ever requires it.
 */
@:re("\\$?[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*")
@:rawString
abstract HxNewTypeName(String) from String to String {}
