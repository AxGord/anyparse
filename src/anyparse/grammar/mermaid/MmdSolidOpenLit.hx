package anyparse.grammar.mermaid;

/** The opener of a solid link that carries its label inline (`--` of `A-- text -->B`). */
@:re('[xo<]?--(?![->])')
@:rawString
abstract MmdSolidOpenLit(String) from String to String {}
