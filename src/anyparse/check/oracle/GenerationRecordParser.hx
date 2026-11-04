package anyparse.check.oracle;

/** The generated parser of `GenerationRecord` — the record of a successful generation. Throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(anyparse.check.oracle.GenerationRecord))
@:nullSafety(Strict)
class GenerationRecordParser {}
