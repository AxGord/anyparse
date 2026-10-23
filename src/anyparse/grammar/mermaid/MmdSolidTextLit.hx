package anyparse.grammar.mermaid;

/**
 * The plain label of a `-- text -->` edge: quoted, or bare text up to its closing link with no
 * `--`, no raw `<` / `>`, no HTML reference and no unresolved entity code in it.
 */
@:re('\"(?!`)(?:[^\"<>&#]|&(?![#A-Za-z0-9_]+;)|#(?![A-Za-z0-9_]+;)|#(?=(?:quot|amp|lt|gt|apos|nbsp|num|grave|(?!0+;|5529[6-9];|55[3-9][0-9]{2};|56[0-9]{3};|57[0-2][0-9]{2};|573[0-3][0-9];|5734[0-3];)[0-9]{1,6});))*\"|(?:[^-\\n\\r\"<>&#]|-(?!-)|&(?![#A-Za-z0-9_]+;)|#(?![A-Za-z0-9_]+;)|#(?=(?:quot|amp|lt|gt|apos|nbsp|num|grave|(?!0+;|5529[6-9];|55[3-9][0-9]{2};|56[0-9]{3};|57[0-2][0-9]{2};|573[0-3][0-9];|5734[0-3];)[0-9]{1,6});))+(?=--)')
@:decode('anyparse.grammar.mermaid.MermaidText.decodePlain')
@:encode('anyparse.grammar.mermaid.MermaidText.encodePlainSolid')
abstract MmdSolidTextLit(String) from String to String {}
