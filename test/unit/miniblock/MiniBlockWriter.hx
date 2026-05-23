package unit.miniblock;

/**
 * Marker class for the macro-generated writer of `MiniBlock`.
 *
 * Empty body — the `@:build` macro contributes the `write(value)`
 * entry point that round-trips a `MiniBlock` AST back to source.
 */
@:build(anyparse.macro.Build.buildWriter(
	unit.miniblock.MiniBlock,
	unit.miniblock.MiniBlockWriteOptions
))
@:nullSafety(Strict)
class MiniBlockWriter {}
