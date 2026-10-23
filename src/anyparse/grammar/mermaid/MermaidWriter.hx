package anyparse.grammar.mermaid;

/**
 * Marker class for the macro-generated writer of the Mermaid flowchart grammar —
 * `write(value, ?options): String`, the canonical text of an `MmdFlowchart`.
 *
 * The class body is empty on purpose: every member is contributed by the macro.
 */
@:build(anyparse.macro.Build.buildWriter(anyparse.grammar.mermaid.MmdFlowchart, anyparse.grammar.mermaid.MermaidWriteOptions))
@:nullSafety(Strict)
class MermaidWriter {}
