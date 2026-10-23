package anyparse.grammar.mermaid;

/**
 * Marker class for the macro-generated Fast parser of the Mermaid flowchart grammar —
 * `parse(source): MmdFlowchart`, throwing `ParseError` on the first failure.
 *
 * The class body is empty on purpose: every member is contributed by the macro.
 */
@:build(anyparse.macro.Build.buildParser(anyparse.grammar.mermaid.MmdFlowchart))
@:nullSafety(Strict)
class MermaidParser {}
