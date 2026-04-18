package anyparse.grammar.haxe;

/**
 * Closed set of values the haxe-formatter `sameLine.*Body` fields
 * accept. Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.BodyPolicy`:
 *
 * - `"same"` → `BodyPolicy.Same`
 * - `"next"` → `BodyPolicy.Next`
 * - `"fitLine"` → `BodyPolicy.FitLine`
 * - `"keep"` → `BodyPolicy.Same` (degraded — recovering the original
 *   source shape requires per-node layout tracking the parser does
 *   not yet preserve; `Same` is the nearest no-surprise fallback).
 */
enum abstract HxFormatBodyPolicy(String) to String {

	final Same = 'same';

	final Next = 'next';

	final Keep = 'keep';

	final FitLine = 'fitLine';
}
