package anyparse.grammar.haxe;

/**
 * An identifier-shaped WORD where Haxe takes a reserved one too — the slots that do not declare a name: a property
 * accessor (`(default, null)`, `(get, never)`, `dynamic`), an interpolated `'$this'` / `'$null'`, and the `$name`
 * of a macro reification (`$default` is one token to the lexer). `HxIdentLit`, the declaration-name terminal, refuses
 * every reserved word; this is its unguarded twin, the pattern `HxIdentLit` had before it did.
 *
 * `@:rawString` keeps the matched slice verbatim; `from String to String` keeps string-built ASTs and reads compiling.
 */
@:re('[A-Za-z_][A-Za-z0-9_]*')
@:rawString
abstract HxWordLit(String) from String to String {}
