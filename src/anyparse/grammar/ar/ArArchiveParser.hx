package anyparse.grammar.ar;

/**
 * Macro-generated Fast-mode parser for Unix ar archives.
 *
 * The `@:build` metadata invokes the five-pass macro pipeline with
 * `ArArchive` as the grammar root, generating a `parse(source:Bytes)`
 * entry point that returns a typed `ArArchive` value.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.ar.ArArchive))
@:nullSafety(Strict)
class ArArchiveParser {}
