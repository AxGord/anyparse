package anyparse.grammar.haxe;

/**
 * Terminal for one line's leading whitespace inside a block-comment
 * body. Captures `[ \t]*` verbatim so the writer can compute a common
 * leading-prefix reduce across lines and preserve the relative indent
 * offsets that distinguish nested content from its heading (e.g. a
 * bullet indented one space under a paragraph).
 */
@:re('[ \\t]*')
@:rawString
abstract BlockCommentLineWs(String) from String to String {}
