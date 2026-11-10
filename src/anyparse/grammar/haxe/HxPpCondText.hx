package anyparse.grammar.haxe;

/** A run of a condition group's interior that opens nothing: no parenthesis, no quote, no block-comment opener. */
@:re('(?:[^()\'"/]|/(?!\\*))+')
abstract HxPpCondText(String) from String to String {}
