package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter
 * `emptyLines.classEmptyLines.existingBetweenFields` field accepts.
 * Mirrors `formatter.config.KeepEmptyLinesPolicy` in the fork's schema
 * 1:1 so a `hxformat.json` written for upstream haxe-formatter parses
 * without unknown-value errors.
 *
 * Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.KeepEmptyLinesPolicy`:
 *
 * - `"keep"`   → `KeepEmptyLinesPolicy.Keep`
 * - `"remove"` → `KeepEmptyLinesPolicy.Remove`
 */
enum abstract HxFormatKeepEmptyLinesPolicy(String) to String {

	final Keep = 'keep';

	final Remove = 'remove';
}
