package anyparse.grammar.haxe.cond;

/**
 * Where a Haxe preprocessor condition ends in raw text, GENERATED from its declaration `HxPpCond`: `endAt(input, at)`
 * reads the condition starting exactly at `at`. The `#if` terminal `HxPpCondLit` names it by `@:scan`, and every
 * scan of a source the parser may never see (the directive reader, the splice predicates) reaches the same reader
 * through that terminal, so one `#if` is one condition everywhere.
 */
@:nullSafety(Strict)
@:build(anyparse.macro.Build.buildExtentScan(anyparse.grammar.haxe.cond.HxPpCond))
final class HxPpCondScan {}
