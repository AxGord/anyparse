package anyparse.grammar.mermaid;

/**
 * Root of the Mermaid flowchart grammar: a document is a list of statements, one per line.
 *
 * The `flowchart` / `graph` header is a statement (`MmdStatement.Header`) because front matter,
 * directives and comments may precede it, and the writer puts a line break before every statement
 * after the first only through the per-element separator of `rest`; so the grammar does not force
 * the header to come first, and a document is whatever its statements say. The first statement is
 * a field of its own for the same reason: it is the one no separator precedes.
 *
 * `MermaidParser` is the Fast parser, `MermaidSpanParser` the span-bearing (Tolerant) one,
 * `MermaidWriter` the canonical writer: one statement per line, a subgraph body indented, labels
 * re-encoded by `MermaidText`; blank lines are not kept, and a `;` is a statement written on a line of its own.
 */
@:peg
@:schema(anyparse.grammar.mermaid.MermaidFormat)
@:ws
typedef MmdFlowchart = {
	var first: MmdStatement;
	@:tryparse @:fmt(sameLine('statementBreak')) var rest: Array<MmdStatement>;
}
