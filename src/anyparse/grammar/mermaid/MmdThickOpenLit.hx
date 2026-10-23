package anyparse.grammar.mermaid;

/** The opener of a thick link that carries its label inline (`==` of `A== text ==>B`). */
@:re('[xo<]?==(?![=>])')
@:rawString
abstract MmdThickOpenLit(String) from String to String {}
