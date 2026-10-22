package anyparse.grammar.haxe.format;

/**
 * Closed set of values `wrapping.ternaryMultilineBranch` accepts — haxe-formatter's
 * `TernaryMultilineBranchPolicy`, the same key and spellings, so one config means the same to
 * both tools. Mapped by `HaxeFormatConfigLoader` onto `HxModuleWriteOptions.ternaryMultilineBranchInline`.
 *
 * The defaults differ, and the difference is a decision rather than drift: hxq's is `break`
 * (the layout it always wrote), the fork's is `inline`.
 */
enum abstract HxFormatTernaryMultilineBranchPolicy(String) to String {

	final Inline = 'inline';

	final Break = 'break';

}
