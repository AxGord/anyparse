package anyparse.grammar.haxe;

/**
 * Expression-position identifier terminal — `HxIdentLit` with a
 * negative-lookahead guard rejecting control-flow keywords
 * (`if` / `else` / `for` / `while` / `do` / `switch` / `case` /
 * `default` / `try` / `catch` / `return` / `break` / `continue` /
 * `throw` / `var` / `final`).
 *
 * The plain ident regex is permissive: without the guard,
 * `IdentExpr` happily matches a keyword whenever the structured
 * keyword-atom branch fails to complete — e.g. `if (a == b)` with no
 * then-branch parses as `Call(IdentExpr if, …)`. That mis-parse
 * poisons ordered-choice fallbacks: a token-splice conditional whose
 * fragment is a bare if-head (`#if x if (cond) #end stmt;`) is
 * "successfully" consumed by the structured `Conditional` production,
 * so the `CondSpliceStmt` fallback ordered after it is never tried.
 * With the guard the structured path fail-rewinds honestly and the
 * splice production picks the region up.
 *
 * Only CONTROL-FLOW keywords are rejected. Value-ish and
 * modifier-ish keywords legal in expression position (`inline`,
 * `new`, `untyped`, `macro`, `cast`, `this`, `super`, `null`,
 * `true`, `false`) stay matchable — their dedicated atom branches
 * dispatch before `IdentExpr`, and rejecting them here would break
 * shapes those branches do not cover.
 *
 * The lookahead group is followed by `\b` so keyword-PREFIXED
 * identifiers (`iffy`, `variance`, `catchAll`) still match: the word
 * boundary fails mid-ident and the negative lookahead succeeds.
 *
 * `@:rawString` — same decoding as `HxIdentLit`: the matched slice is
 * the value, no unescape pass.
 */
@:re('(?!(?:if|else|for|while|do|switch|case|default|try|catch|return|break|continue|throw|var|final)\\b)[A-Za-z_][A-Za-z0-9_]*')
@:rawString
abstract HxExprIdentLit(String) from String to String {}
