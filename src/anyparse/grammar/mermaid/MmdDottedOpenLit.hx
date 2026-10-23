package anyparse.grammar.mermaid;

/** The opener of a dotted link that carries its label inline (`-.` of `A-. text .->B`). */
@:re('[xo<]?-\\.(?![-.])')
@:rawString
abstract MmdDottedOpenLit(String) from String to String {}
