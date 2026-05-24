package unit.miniblockstrict;

/**
 * Atom-literal terminal for the `MiniBlockStrict` pilot grammar.
 *
 * Identical regex to `unit.miniblock.MiniAtomLit` — duplicated to keep
 * the strict pilot self-contained (no cross-package coupling with the
 * permissive-sep pilot it parallels).
 */
@:re('[a-z][a-z0-9]*')
@:rawString
abstract MiniAtomLitStrict(String) from String to String {}
