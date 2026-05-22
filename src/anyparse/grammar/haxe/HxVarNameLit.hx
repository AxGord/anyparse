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
 * A `(?!(?:var|final)\b)` negative-lookahead rejects a bare `var` or
 * `final` keyword in the name slot. The lookahead matters in
 * `HxVarMore.decl` — the `,`-led multi-binding continuation. Without
 * it, source like `f(var foo, var bar)` (a Haxe pattern-position call
 * with two `var <ident>` captures) is greedily consumed as a single
 * multi-binding `VarExpr(name=foo, more=[{decl: name='var'}])`, and
 * the stray `bar)` then fails the parent's parse. With the lookahead,
 * the inner `HxVarDecl.name` regex fails on `var`, the `@:tryparse
 * more` Star rolls back, and the outer `,` is reclaimed by the
 * enclosing `Call.args` separator so each `var <ident>` parses as its
 * own arg. The lookahead applies only when no `$` prefix is present —
 * a `$var` macro-reification name is still accepted. `(?!…\b)` uses
 * word-boundary semantics so `vararg` / `final_count` continue to
 * parse as normal identifiers (the `\b` requires the next char to be
 * a non-word char before the negative lookahead fires).
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
@:re("\\$?(?!(?:var|final)\\b)[A-Za-z_][A-Za-z0-9_]*")
@:rawString
abstract HxVarNameLit(String) from String to String {}
