package unit.miniblockstrict;

/**
 * Marker class for the macro-generated Fast-mode parser of
 * `MiniBlockStrict`.
 */
@:build(anyparse.macro.Build.buildParser(unit.miniblockstrict.MiniBlockStrict))
@:nullSafety(Strict)
class MiniBlockStrictParser {}
