package unit.macro;

/** A lowercase word. */
@:re('[a-z][a-z0-9]*')
@:rawString
abstract NarrowWhitespaceAtom(String) from String to String {}
