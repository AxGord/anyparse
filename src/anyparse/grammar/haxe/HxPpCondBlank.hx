package anyparse.grammar.haxe;

/**
 * The blank a condition admits after a `!`, after a directive keyword and after the condition itself: spaces, tabs
 * and line breaks, possibly none. A comment is not part of it.
 */
@:re('[ \\t\\r\\n]*')
abstract HxPpCondBlank(String) from String to String {}
