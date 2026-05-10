package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `lineEnds.emptyCurly` field
 * accepts. Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.EmptyCurly`:
 *
 * - `"same"` → `EmptyCurly.Same` (default — empty bodies stay flat)
 * - `"break"` → `EmptyCurly.Break` (empty bodies break to two lines
 *   with `}` on its own line at the parent's indent)
 *
 * Slice ω-empty-curly-break.
 */
enum abstract HxFormatEmptyCurlyPolicy(String) to String {

	final Same = 'same';

	final Break = 'break';
}
