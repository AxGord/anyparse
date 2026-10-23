package anyparse.grammar.mermaid;

/**
 * A plain node, pipe or subgraph-title label — the text a reader sees: quoted, or bare text up to
 * a closing bracket (a `/` or `\` ends it only before a `]`, which closes the slanted shapes). It
 * holds no raw `<` / `>`, no HTML reference and no entity code `MermaidText` cannot resolve; a label
 * that does is markup (`MmdMarkupLit`).
 */
@:re('\"(?!`)(?:[^\"<>&#]|&(?![#A-Za-z0-9_]+;)|#(?![A-Za-z0-9_]+;)|#(?=(?:quot|amp|lt|gt|apos|nbsp|num|grave|(?!0+;|5529[6-9];|55[3-9][0-9]{2};|56[0-9]{3};|57[0-2][0-9]{2};|573[0-3][0-9];|5734[0-3];)[0-9]{1,6});))*\"|(?:[^\\[\\](){}|\"\\n\\r/\\\\<>&#]|[/\\\\](?!\\])|&(?![#A-Za-z0-9_]+;)|#(?![A-Za-z0-9_]+;)|#(?=(?:quot|amp|lt|gt|apos|nbsp|num|grave|(?!0+;|5529[6-9];|55[3-9][0-9]{2};|56[0-9]{3};|57[0-2][0-9]{2};|573[0-3][0-9];|5734[0-3];)[0-9]{1,6});))*(?=[\\])}|/\\\\])')
@:decode('anyparse.grammar.mermaid.MermaidText.decodePlain')
@:encode('anyparse.grammar.mermaid.MermaidText.encodePlain')
abstract MmdTextLit(String) from String to String {}
