package anyparse.grammar.haxe;

/**
 * Marker class for the macro-generated Fast-mode parser of
 * `HxModule` — the multi-declaration Haxe module root.
 *
 * Lives alongside the existing `HaxeFastParser` (rooted on
 * `HxClassDecl`). Having two marker classes on the same grammar
 * package validates that the marker-class pattern scales to
 * multiple roots: the macro generates a distinct set of
 * `parseXxx` helpers per marker class, and shared sub-rules (like
 * `parseHxClassDecl`) are regenerated into each marker rather than
 * shared at runtime — an acceptable cost while the grammar is
 * small.
 *
 * The class body is empty on purpose — editing it would just be
 * clobbered on the next compile.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.haxe.HxModule))
@:nullSafety(Strict)
class HaxeModuleFastParser {}
