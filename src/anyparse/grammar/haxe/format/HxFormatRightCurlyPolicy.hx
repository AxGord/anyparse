package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `lineEnds.rightCurly` field
 * accepts. Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.RightCurlyPlacement`:
 *
 * - `"before"` -> `RightCurlyPlacement.Same` (hardline before `}`,
 *   default)
 * - `"both"` -> `RightCurlyPlacement.Same` (equivalent for our
 *   output -- the trailing newline after `}` is contributed by the
 *   surrounding sibling separator, so `Before` and `Both` collapse)
 * - `"after"` -> `RightCurlyPlacement.Inline` (no hardline before
 *   `}`; the trailing newline after `}` is already produced by the
 *   outer context)
 * - `"none"` -> `RightCurlyPlacement.Inline` (degraded -- the
 *   `{ body }` flat shape collapses with `After` because the outer
 *   sibling sep cannot be suppressed from this knob alone)
 *
 * Casing matches fork JSON ("none"/"before"/"after"/"both" -- all
 * lowercase). Sister precedent: `HxFormatLeftCurlyPolicy`.
 */
enum abstract HxFormatRightCurlyPolicy(String) to String {

	final None = 'none';

	final Before = 'before';

	final After = 'after';

	final Both = 'both';

}
