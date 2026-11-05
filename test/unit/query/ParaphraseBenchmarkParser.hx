package unit.query;

/** Marker class for the macro-generated parser of `ParaphraseBenchmark`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(unit.query.ParaphraseBenchmark))
@:nullSafety(Strict)
class ParaphraseBenchmarkParser {}
