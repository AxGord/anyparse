package anyparse.grammar.haxe;

/**
 * The name slot of a function declaration. Besides a plain identifier it accepts a macro-reification
 * `$ident` (`macro class { function $name() … }`), the twin of `HxVarNameLit` for a function name.
 */
@:re('\\$?[A-Za-z_][A-Za-z0-9_]*')
@:rawString
abstract HxFnNameLit(String) from String to String {}
