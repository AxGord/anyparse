package unit.minilex;

/**
 * `@ … @`, escaped with `\`. Declared `@:lexical(StringLit)`, so the generated pass masks it
 * exactly the way `HxDoubleStringLit` is masked in Haxe — from a delimiter Haxe never uses.
 */
@:re('@(?:[^@\\\\]|\\\\.)*@')
@:rawString
@:lexical(StringLit)
abstract MiniLexStringLit(String) from String to String {}
