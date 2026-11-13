package anyparse.grammar.haxe;

/** A numeric condition operand (`#if 0` comments out a region, `#if 4.2` is one operand). */
@:re('[0-9][0-9.]*')
@:rawString
abstract HxPpCondNumber(String) from String to String {}
