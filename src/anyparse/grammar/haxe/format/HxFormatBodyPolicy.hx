package anyparse.grammar.haxe.format;

/**
 * Closed set of values the haxe-formatter `sameLine.*Body` fields
 * accept. Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.BodyPolicy`:
 *
 * - `"same"` → `BodyPolicy.Same`
 * - `"next"` → `BodyPolicy.Next`
 * - `"fitLine"` → `BodyPolicy.FitLine`
 * - `"keep"` → `BodyPolicy.Keep` — the writer reads the source form and
 *    reproduces it. This line read `BodyPolicy.Same` (degraded) until S159
 *    noticed it: `bodyPolicyToRuntime` has mapped `Keep` to `Keep` for long
 *    enough that `HxLoopBodyIfElseSliceTest` now pins the difference, and a
 *    `keep` body that reproduces a source break is what that pin asserts.
 */
enum abstract HxFormatBodyPolicy(String) to String {

	final Same = 'same';

	final Next = 'next';

	final Keep = 'keep';

	final FitLine = 'fitLine';

}
