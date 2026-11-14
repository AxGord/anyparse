package anyparse.grammar.haxe.cond;

/**
 * Where the blank around a Haxe preprocessor condition ends in raw text, GENERATED from its declaration
 * `HxPpCondBlank`: `endAt(input, at)` reads the blank starting exactly at `at`, `at` when none. The `#if` terminal
 * `HxPpCondLit` names it by `@:condRegionBlank`, so the blank after a directive keyword and after a condition is the
 * one the grammar declares after a `!`.
 */
@:nullSafety(Strict)
@:build(anyparse.macro.Build.buildExtentScan(anyparse.grammar.haxe.cond.HxPpCondBlank))
final class HxPpCondBlankScan {}
