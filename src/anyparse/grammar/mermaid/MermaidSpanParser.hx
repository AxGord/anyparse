package anyparse.grammar.mermaid;

/**
 * Marker class for the macro-generated span-bearing (Tolerant-mode) parser of the Mermaid
 * flowchart grammar: every ctor of the paired `*S` types in `anyparse.grammar.mermaid.spans.Pairs`
 * carries its source span. The query walker (`MermaidQueryWalker`) reads it.
 *
 * The class body is empty on purpose: every member is contributed by the macro.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.mermaid.MmdFlowchart, { spans: true }))
@:nullSafety(Strict)
class MermaidSpanParser {}
