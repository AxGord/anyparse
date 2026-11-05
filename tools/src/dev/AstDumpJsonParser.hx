package dev;

/**
 * Marker class for the macro-generated parser of `anyparse.query.format.json.AstDumpJson`,
 * the `hxq ast --json` output; `parse` throws on malformed or wrong-shaped input.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.query.format.json.AstDumpJson))
@:nullSafety(Strict)
class AstDumpJsonParser {}
