package anyparse.grammar.haxe;

/**
 * The name slot of a function declaration. Besides a plain identifier it accepts a macro-reification
 * `$ident` (`macro class { function $name() … }`), the twin of `HxVarNameLit` for a function name.
 */
@:re('\\$?(?!(?:abstract|break|case|cast|catch|class|continue|default|do|dynamic|else|enum|extends|extern|false|final|for|function|if|implements|import|in|inline|interface|macro|null|operator|overload|override|package|private|public|return|static|switch|this|throw|true|try|typedef|untyped|using|var|while)\\b)[A-Za-z_][A-Za-z0-9_]*')
@:rawString
abstract HxFnNameLit(String) from String to String {}
