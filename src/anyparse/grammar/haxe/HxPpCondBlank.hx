package anyparse.grammar.haxe;

/** The blank a condition admits after a `!`: spaces, tabs and line breaks, possibly none. */
@:re('[ \\t\\r\\n]*')
abstract HxPpCondBlank(String) from String to String {}
