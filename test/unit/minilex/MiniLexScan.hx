package unit.minilex;

/** The lexical pass generated from `MiniLexDoc` — the second grammar's `HaxeLexicalRegions`. */
@:build(anyparse.macro.Build.buildLexicalScan(unit.minilex.MiniLexDoc))
@:nullSafety(Strict)
final class MiniLexScan {}
