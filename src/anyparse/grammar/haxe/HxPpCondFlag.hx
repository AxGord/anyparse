package anyparse.grammar.haxe;

/**
 * A define name operand, possibly DOTTED (`#if target.unicode`, `#if js.classic`): the dot belongs to the flag, so
 * stopping at it would leave the tail to be read as code. A dot not followed by an identifier start ends the flag.
 */
@:re('[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*')
@:rawString
abstract HxPpCondFlag(String) from String to String {}
