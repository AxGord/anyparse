package anyparse.grammar.mermaid;

/**
 * A link as written: solid (`---`, `-->`, `--x`, `--o`, longer `---->`), thick (`===`, `==>`),
 * dotted (`-.-`, `-.->`, `-..->`), any of them with a start head (`<-->`, `x--x`, `o--o`), or the
 * invisible `~~~`. The spelling IS the value: stroke, heads and length are read off it.
 */
@:re('[xo<]?(?:-{2,}[-xo>]|={2,}[=xo>]|-?\\.+-[xo>]?)|~{3,}')
@:rawString
abstract MmdLinkLit(String) from String to String {}
