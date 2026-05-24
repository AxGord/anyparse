package unit.miniblockstrict;

/**
 * Marker class for the macro-generated writer of `MiniBlockStrict`.
 */
@:build(anyparse.macro.Build.buildWriter(
	unit.miniblockstrict.MiniBlockStrict,
	unit.miniblockstrict.MiniBlockStrictWriteOptions
))
@:nullSafety(Strict)
class MiniBlockStrictWriter {}
