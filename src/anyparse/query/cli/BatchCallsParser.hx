package anyparse.query.cli;

/** The generated parser of `BatchCalls` — what `apq --batch` reads. Throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(anyparse.query.cli.BatchCalls))
@:nullSafety(Strict)
class BatchCallsParser {}
