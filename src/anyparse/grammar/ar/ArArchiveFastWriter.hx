package anyparse.grammar.ar;

/**
 * Macro-generated Fast-mode writer for Unix ar archives.
 *
 * The `@:build` metadata invokes the writer pipeline with
 * `ArArchive` as the grammar root, generating a `write(value):Bytes`
 * entry point.
 */
@:build(anyparse.macro.Build.buildWriter(anyparse.grammar.ar.ArArchive))
@:nullSafety(Strict)
class ArArchiveFastWriter {}
