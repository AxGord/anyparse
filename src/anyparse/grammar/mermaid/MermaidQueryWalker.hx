package anyparse.grammar.mermaid;

/**
 * Marker class for the macro-generated query walker of the Mermaid flowchart grammar — the
 * projection of the span parser's paired AST (`MermaidSpanParser`) onto the engine's `QueryNode`
 * tree. Every kind is the grammar's own ctor name; a struct is transparent. `MermaidProjection`
 * wraps the walk in the document root.
 *
 * The class body is empty on purpose: every member is contributed by the macro.
 */
@:build(anyparse.macro.Build.buildQueryWalker(anyparse.grammar.mermaid.MmdFlowchart, anyparse.grammar.mermaid.MermaidSpanParser))
@:nullSafety(Strict)
class MermaidQueryWalker {}
