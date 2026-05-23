package unit.miniblock;

/**
 * Marker class for the macro-generated Fast-mode parser of `MiniBlock`.
 *
 * Empty body — the `@:build` macro contributes the `parse(source)`
 * entry point and the private recursive-descent helpers.
 */
@:build(anyparse.macro.Build.buildParser(unit.miniblock.MiniBlock))
@:nullSafety(Strict)
class MiniBlockParser {}
