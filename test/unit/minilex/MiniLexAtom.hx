package unit.minilex;

/** A bare word — the one thing `MiniLexDoc` holds that is neither a string nor a comment. */
@:re('[a-z]+')
@:rawString
abstract MiniLexAtom(String) from String to String {}
