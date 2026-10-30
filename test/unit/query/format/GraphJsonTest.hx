package unit.query.format;

import anyparse.query.format.GraphJson;
import anyparse.query.format.json.CodeGraphJson;
import anyparse.query.format.json.CodeGraphJsonParser;
import anyparse.query.graph.CodeGraph;
import haxe.Exception;

/**
 * `GraphJson` — a code graph written through its `@:schema` type and the JSON grammar's writer: the
 * text reads back through the same schema's parser to the graph's own nodes and edges.
 */
@:nullSafety(Strict)
class GraphJsonTest extends Test {

	/** The fixture walk reads back through `CodeGraphJsonParser` node for node and edge for edge. */
	public function testTheDocumentReadsBackThroughItsSchema(): Void {
		final graph: CodeGraph = MemberGraphBuilder.chains(GraphFixture.calls(), ['Alpha.run'], 3, true, null);
		final read: CodeGraphJson = CodeGraphJsonParser.parse(GraphJson.write(graph));
		Assert.equals(
			[
				for (n in graph.nodes()) '${n.id} ${n.level} ${n.name} ${n.label} ${n.parent} ${n.external} ${n.focus}'
			].join('\n'),
			[
				for (n in read.nodes) '${n.id} ${n.level} ${n.name} ${n.label} ${n.parent} ${n.external} ${n.focus}'
			].join('\n')
		);
		Assert.equals(
			[for (e in graph.edges()) '${e.from} ${e.to} ${e.kind} ${e.weight}'].join('\n'),
			[for (e in read.edges) '${e.from} ${e.to} ${e.kind} ${e.weight}'].join('\n')
		);
	}

	/** A small graph, byte for byte: a top-level node carries no `parent` key; a record that fits the line stays on one. */
	public function testGolden(): Void {
		final graph: CodeGraph = new CodeGraph();
		final t: String = graph.addNode(Type, 'p.T', 'T', null, false);
		final m: String = graph.addNode(Member, 'p.T.m', 'm', t, true);
		graph.addEdge(m, m, Call, 2);
		Assert.equals([
			'{',
			'    "nodes":[',
			'        {',
			'            "id":"em_p_dT_dm",',
			'            "level":"member",',
			'            "name":"p.T.m",',
			'            "label":"m",',
			'            "parent":"t_p_dT",',
			'            "external":true,',
			'            "focus":false',
			'        },',
			'        {"id":"t_p_dT", "level":"type", "name":"p.T", "label":"T", "external":false, "focus":false}',
			'    ],',
			'    "edges":[{"from":"em_p_dT_dm", "to":"em_p_dT_dm", "kind":"call", "weight":2}]',
			'}',
			''
		].join('\n'), GraphJson.write(graph));
	}

	/** A record missing a key the schema requires does not read as a graph. */
	public function testTheSchemaRefusesAMissingKey(): Void {
		Assert.raises(() -> CodeGraphJsonParser.parse('{"nodes":[{"id":"m_a"}],"edges":[]}'), Exception);
	}

	/** An edge with a way back carries `mutual: true`; any other edge carries no `mutual` key, and the key reads back. */
	public function testAMutualEdgeIsMarked(): Void {
		final graph: CodeGraph = new CodeGraph();
		final a: String = graph.addNode(Package, 'a', 'a', null, false);
		final b: String = graph.addNode(Package, 'b', 'b', null, false);
		final c: String = graph.addNode(Package, 'c', 'c', null, false);
		graph.addEdge(a, b, Import);
		graph.addEdge(b, a, Import);
		graph.addEdge(b, c, Import);
		final text: String = GraphJson.write(graph);
		Assert.equals(2, text.split('"mutual":true').length - 1);
		Assert.equals(-1, text.indexOf('"mutual":false'));
		Assert.equals('true,true,null', [for (e in CodeGraphJsonParser.parse(text).edges) '${e.mutual}'].join(','));
	}

}
