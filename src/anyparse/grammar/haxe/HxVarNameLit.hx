package anyparse.grammar.haxe;

/**
 * Identifier terminal for the `var`/`final` binding-name slot, allowing one optional leading
 * `$` for a macro-reification name (`var $x = …`, `final $localName = …`).
 *
 * A structural mirror of `HxIdentLit` with the regex widened by a leading `\$?`. It is a
 * separate, scoped terminal rather than a change to `HxIdentLit`: that one is shared by
 * `IdentExpr`, `FieldAccess.field` and `DollarIdentExpr.name`, where a `$`-tolerant pattern
 * would make the bare `$ident` expression form ambiguous with a plain identifier; the name
 * slot has no competing leading-`$` production.
 *
 * The `(?!(?:var|final)\b)` negative lookahead rejects a bare `var` or `final` keyword in the
 * name slot. It matters in `HxVarMore.decl`, the `,`-led multi-binding continuation: without
 * it `f(var foo, var bar)` (a pattern-position call with two `var <ident>` captures) is
 * greedily consumed as one multi-binding and the stray `bar)` fails the parent's parse; with
 * it the inner `HxVarDecl.name` fails on `var`, the `@:tryparse more` Star rolls back, and the
 * `,` is reclaimed by the enclosing `Call.args` separator. The lookahead applies only without
 * a `$` prefix, and its `\b` keeps `vararg` / `final_count` parsing as normal identifiers.
 *
 * The pattern is double-quoted because `@:re` arguments are parsed as Haxe expressions and a
 * single-quoted `\$` would interpolate. `@:rawString` keeps the matched slice (including the
 * `$`) verbatim so the name round-trips unchanged. The `${expr}` brace-form name is
 * deliberately NOT matched — add a brace production when a real `var ${e} = …` site appears.
 *
 * `from String to String` keeps `(decl.name : String)` reads and string-built test ASTs
 * compiling transparently.
 */
@:re("\\$?(?!(?:var|final)\\b)[A-Za-z_][A-Za-z0-9_]*")
@:rawString
abstract HxVarNameLit(String) from String to String {}
