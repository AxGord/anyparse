package anyparse.grammar.haxe;

/**
 * Expression-position identifier terminal — `HxIdentLit` with a
 * negative-lookahead guard rejecting the reserved words no expression is (the control-flow keywords
 * (`if` / `else` / `for` / `while` / `do` / `switch` / `case` /
 * `default` / `try` / `catch` / `return` / `break` / `continue` /
 * `throw` / `var` / `final`), and the declaration words below).
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
 * Every reserved word but the expression atoms is rejected: the control-flow keywords, and the declaration words no
 * expression starts with (`class`, `dynamic`, `extends`, `private`, `static`, `using`, …), which a lambda-shaped
 * `(dynamic:Int) -> 1` otherwise read as a check-type expression. The atoms legal in expression position (`inline`,
 * `new`, `untyped`, `macro`, `cast`, `this`, `super`, `null`, `abstract`
 * (the value of an abstract inside its own methods, `switch abstract { … }`),
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
@:re('(?!(?:if|else|for|while|do|switch|case|default|try|catch|return|break|continue|throw|var|final|class|dynamic|enum|extends|extern|implements|import|in|interface|operator|overload|override|package|private|public|static|typedef|using)\\b)[A-Za-z_][A-Za-z0-9_]*')
@:rawString
abstract HxExprIdentLit(String) from String to String {}
