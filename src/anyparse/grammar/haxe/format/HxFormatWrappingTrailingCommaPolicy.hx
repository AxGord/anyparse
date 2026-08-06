package anyparse.grammar.haxe.format;

/**
 * Closed set of values the anyparse-specific `wrapping.trailingComma` field
 * accepts. No haxe-formatter counterpart exists — this knob is an anyparse
 * extension, so it defaults to `keep` (byte-inert) and never re-baselines
 * at JSON-load entry the way the fork-canonical wrapping knobs do.
 *
 * Distinct from `HxFormatTrailingCommaPolicy` (the fork's
 * `trailingCommas.*Default` yes/no/keep/ignore set, which decides whether
 * to ADD a comma): this one decides whether a trailing comma may SURVIVE in
 * a multiline list, and `remove` OUTRANKS every one of those add-knobs.
 *
 * Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.TrailingCommaPolicy`:
 *
 * - `"keep"`   → `TrailingCommaPolicy.Keep`
 * - `"remove"` → `TrailingCommaPolicy.Remove`
 */
enum abstract HxFormatWrappingTrailingCommaPolicy(String) to String {

	final Keep = 'keep';

	final Remove = 'remove';

}
