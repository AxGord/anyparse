package anyparse.grammar.haxe;

/**
 * Identifier terminal for the `var`/`final` binding-name slot, allowing
 * one optional leading `$` for a macro-reification name
 * (`var $x = …`, `final $localName = …`).
 *
 * A structural mirror of `HxIdentLit` with the regex widened by a
 * leading `\$?`. It is a separate, scoped terminal rather than a change
 * to `HxIdentLit` itself: `HxIdentLit` is shared by `IdentExpr`,
 * `FieldAccess.field`, and `DollarIdentExpr.name`, where a `$`-tolerant
 * pattern would make the bare `$ident` expression form ambiguous with a
 * plain identifier. The name slot has no competing leading-`$`
 * production, so the widened pattern is unambiguous there.
 *
 * The pattern is double-quoted because `@:re` arguments are parsed as
 * normal Haxe expressions and a single-quoted `\$` would interpolate.
 * `@:rawString` keeps the matched slice (including the `$`) verbatim so
 * the name round-trips unchanged through the writer.
 *
 * The `${expr}` brace-form name is deliberately NOT matched — no source
 * site uses it today (minimal-first). Exit criterion: add a brace
 * production for this slot when a real `var ${e} = …` site appears.
 *
 * `from String to String` keeps `(decl.name : String)` reads and
 * string-built test ASTs compiling transparently — the type swap on
 * `HxVarDecl.name` is structurally invisible to every consumer.
 */
@:re("\\$?[A-Za-z_][A-Za-z0-9_]*")
@:rawString
abstract HxVarNameLit(String) from String to String {}
