package anyparse.grammar.mermaid;

/** A `click` callback: a function name, with its argument list when one is written (`fn(1, "x")`). */
@:re("[A-Za-z_$][\\w$.]*(?:\\([^)\\n]*\\))?")
@:rawString
abstract MmdCallbackLit(String) from String to String {}
