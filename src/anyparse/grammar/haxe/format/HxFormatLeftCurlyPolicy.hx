package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `lineEnds.leftCurly` field
 * accepts. Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.BracePlacement`:
 *
 * - `"before"` → `BracePlacement.Next`
 * - `"both"` → `BracePlacement.Next` (equivalent for our output — the
 *   trailing newline after `{` is already part of the generated
 *   `blockBody` layout, so `Before` and `Both` collapse)
 * - `"after"` → `BracePlacement.Same` (default)
 * - `"none"` → `BracePlacement.Same` (degraded — the inline `{ ... }`
 *   shape is not represented by the current two-value surface and
 *   would need per-node source-shape tracking the parser does not yet
 *   preserve; `Same` is the nearest no-surprise fallback)
 */
enum abstract HxFormatLeftCurlyPolicy(String) to String {

	final None = 'none';

	final After = 'after';

	final Before = 'before';

	final Both = 'both';
}
