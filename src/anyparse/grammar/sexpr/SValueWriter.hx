package anyparse.grammar.sexpr;

/**
 * Marker class for the macro-generated writer of `SValue`. Sister to
 * `JValueWriter` — same `Build.buildWriter` pipeline, different grammar.
 */
@:build(anyparse.macro.Build.buildWriter(anyparse.grammar.sexpr.SValue, anyparse.grammar.sexpr.SValueWriteOptions))
@:nullSafety(Strict)
class SValueWriter {}
