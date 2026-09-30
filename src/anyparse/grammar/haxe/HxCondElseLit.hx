package anyparse.grammar.haxe;

/**
 * The `#else` directive as a REQUIRED terminal (`HxCondSemiRegion.elseKw`): a `@:kw` on the Star field that follows
 * would make the whole field optional, and the region is self-terminating only when an `#else` is present. The word
 * boundary keeps `#elseif` out.
 */
@:re('#else\\b')
@:rawString
abstract HxCondElseLit(String) from String to String {}
