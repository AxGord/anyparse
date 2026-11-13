package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated Fast-mode parser of `HxCondValue`: `parse(source)` reads a whole condition
 * text into its value tree and throws on anything left over, so the one reader of a condition's value is the
 * grammar's own.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.haxe.HxCondValue))
@:nullSafety(Strict)
final class HxCondValueParser {}
