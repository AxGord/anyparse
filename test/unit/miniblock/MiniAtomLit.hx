package unit.miniblock;

/**
 * Atom-literal terminal for the `MiniBlock` pilot grammar.
 *
 * Matches an identifier `[a-z][a-z0-9]*`. The block-ended Star pilot
 * needs atoms that visibly differ from `{`/`}` braces so the test
 * fixtures unambiguously distinguish `Atom` and `Block` elements;
 * nothing about the regex matters beyond that. Digits permitted so
 * fixtures can name atoms `inner1`/`inner2` without collision.
 */
@:re('[a-z][a-z0-9]*')
@:rawString
abstract MiniAtomLit(String) from String to String {}
