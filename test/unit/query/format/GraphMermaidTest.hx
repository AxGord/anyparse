package unit.query.format;

import anyparse.grammar.mermaid.MermaidParser;
import anyparse.grammar.mermaid.MermaidWriter;
import anyparse.grammar.mermaid.MmdFlowchart;
import anyparse.grammar.mermaid.MmdLabel;
import anyparse.grammar.mermaid.MmdStatement;
import anyparse.query.format.GraphMermaid;
import anyparse.query.graph.CodeGraph;
import anyparse.query.graph.MemberGraphBuilder;
import unit.grammar.MermaidAst;
import unit.query.graph.GraphFixture;

/**
 * `GraphMermaid` — a code graph written through the Mermaid grammar's writer: what it writes parses back
 * with `MermaidParser` to the AST it was written from, every label comes back as the plain text it was,
 * and the output of a fixture walk is pinned byte for byte.
 */
@:nullSafety(Strict)
class GraphMermaidTest extends Test {

	/** Labels Mermaid would read as syntax, markup, an entity code or a markdown string, were they written raw. */
	private static final LABELS: Array<String> = [
		'Map<String, Int>',
		'<init>',
		'a|b',
		'[x] (y) {z}',
		'say "hi"',
		'#lt; spelled out',
		'50% done',
		'a;b',
		'end',
		'`tick`',
		'a & b',
		'x --> y'
	];

	/** Each label parses back as `Plain` holding exactly the text it was given, on a vertex and on a subgraph title. */
	@:killer('M-GRAPH-LABEL-MARKUP')
	@:pin('control')
	public function testLabelsComeBackAsPlainText(): Void {
		final graph: CodeGraph = new CodeGraph();
		for (i => label in LABELS) {
			final name: String = 'T${String.fromCharCode('a'.code + i)}';
			final type: String = graph.addNode(Type, name, label, null, false);
			graph.addNode(Member, '$name.m', label, type, false);
		}
		final read: Array<MmdLabel> = [];
		collectLabels(MermaidParser.parse(GraphMermaid.write(graph)), read);
		final expected: Array<MmdLabel> = [for (label in LABELS) for (_ in 0...2) Plain(label)];
		Assert.equals(MermaidAst.dump(expected), MermaidAst.dump(read));
	}

	/** The written text parses to the very AST it was written from, and writing that again changes nothing. */
	public function testTheWriteRoundTrips(): Void {
		final graph: CodeGraph = MemberGraphBuilder.chains(GraphFixture.calls(), ['Alpha.run'], 3, true, null);
		final built: MmdFlowchart = GraphMermaid.flowchart(graph, 'callees Alpha.run --depth 3');
		final text: String = GraphMermaid.write(graph, 'callees Alpha.run --depth 3');
		final parsed: MmdFlowchart = MermaidParser.parse(text);
		Assert.equals(MermaidAst.dump(built), MermaidAst.dump(parsed));
		Assert.equals(text, MermaidWriter.write(parsed));
	}

	/** `callees Alpha.run --depth 3` on the fixture, byte for byte. */
	public function testCalleesGolden(): Void {
		final graph: CodeGraph = MemberGraphBuilder.chains(GraphFixture.calls(), ['Alpha.run'], 3, true, null);
		Assert.equals(GraphFixture.CALLEES_MERMAID, GraphMermaid.write(graph, 'callees Alpha.run --depth 3'));
	}

	/** Kinds and weights label an edge; a call or an import of one site is unlabelled; an external node is classed. */
	public function testEdgeLabelsAndClasses(): Void {
		final graph: CodeGraph = new CodeGraph();
		final a: String = graph.addNode(Member, 'a', 'a', null, false);
		final b: String = graph.addNode(Member, 'b', 'b', null, true);
		graph.addEdge(a, b, Call);
		graph.addEdge(a, b, Ref, 3);
		graph.addEdge(b, a, Import, 2);
		graph.markFocus(a);
		Assert.equals([
			'flowchart LR',
			'm_a(a)',
			'm_b([b])',
			'm_a --> m_b',
			'm_a -.->|ref 3| m_b',
			'm_b -->|2| m_a',
			'classDef focus stroke-width:3px',
			'class m_a focus',
			'classDef external stroke-dasharray:4 3',
			'class m_b external',
			''
		].join('\n'), GraphMermaid.write(graph));
	}

	/** An empty graph is a flowchart with no statement after its header. */
	public function testAnEmptyGraph(): Void {
		Assert.equals('flowchart LR\n', GraphMermaid.write(new CodeGraph()));
	}

	/** Every vertex and subgraph-title label of `doc`, in document order. */
	private static function collectLabels(doc: MmdFlowchart, out: Array<MmdLabel>): Void {
		for (s in [doc.first].concat(doc.rest)) statementLabels(s, out);
	}

	private static function statementLabels(statement: MmdStatement, out: Array<MmdLabel>): Void {
		switch statement {
			case Subgraph(subgraph):
				switch subgraph.head {
					case Titled(head):
						out.push(head.title);
					case Named(_):
				}
				for (s in subgraph.body) statementLabels(s, out);
			case Chain(chain):
				switch chain.head.vertex {
					case Round(_, text), Rect(_, text), Subroutine(_, text), Stadium(_, text): out.push(text);
					case _:
				}
			case _:
		}
	}

}
