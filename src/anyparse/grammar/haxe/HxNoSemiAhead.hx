package anyparse.grammar.haxe;

/**
 * A zero-width check that the next token is not a `;` (`HxCondSemiAssign.end`): it matches the empty string and
 * consumes nothing, so it writes nothing either.
 */
@:re('(?!;)')
@:rawString
abstract HxNoSemiAhead(String) from String to String {}
