package unit.query.format;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.ShapeVocab;
import anyparse.query.format.FlowJson;
import anyparse.query.format.FlowMermaid;
import anyparse.query.format.FlowText;
import anyparse.query.graph.FlowBuilder;
import anyparse.query.graph.FlowGraph;

/**
 * The three outputs of a `FlowGraph` — the text report, the Mermaid flowchart and the JSON document — of one function
 * with a decision, a `throw` and a `return`.
 */
@:nullSafety(Strict)
class FlowOutputTest extends Test {

	private static final SOURCE: String = "class C { static function f(a: Int): Int { if (a > 0) throw 'x'; return a; } }";

	/** The text report counts, then lists the nodes with their line and the edges with their branch. */
	public function testTextReportListsNodesThenEdges(): Void {
		Assert.equals(
			'C.f: 5 node(s), 5 edge(s)\nnodes:\n  n0  start  line 1  start\n  n1  decision  line 1  a > 0\n'
			+ "  n2  throw  line 1  throw 'x'\n  n3  return  line 1  return a\n  n4  end  line 1  end\n"
			+ 'edges:\n  n0 -> n1\n  n1 -> n2  yes\n  n1 -> n3  no\n  n2 -> n4\n  n3 -> n4\n',
			FlowText.write(chart())
		);
	}

	/** Mermaid shapes each node by what it is, labels an edge by its branch, escapes a `>` in a label and draws a `throw` red. */
	@:killer('M-FLOW-MERMAID-SHAPES')
	@:pin('control')
	public function testMermaidShapesAndColoursNodes(): Void {
		Assert.equals(
			'%% graph --flow C.f\nflowchart TB\nn0([start])\nn1{"a #gt; 0"}\nn2([throw \'x\'])\nn3([return a])\nn4([end])\nn0 --> n1\n'
			+ 'n1 -->|yes| n2\nn1 -->|no| n3\nn2 --> n4\nn3 --> n4\nclassDef throw stroke:#d33,stroke-width:2px\nclass n2 throw\n',
			FlowMermaid.write(chart(), 'graph --flow C.f')
		);
	}

	/** JSON carries the name, the nodes with their kind and line, and the edges, a label only where one is drawn. */
	public function testJsonCarriesNodesAndEdges(): Void {
		final json: String = FlowJson.write(chart());
		Assert.isTrue(json.indexOf('"name":"C.f"') >= 0, json);
		Assert.isTrue(json.indexOf('{"id":"n1", "kind":"decision", "label":"a > 0", "line":1}') >= 0, json);
		Assert.isTrue(json.indexOf('{"from":"n1", "to":"n2", "label":"yes"}') >= 0, json);
		Assert.isTrue(json.indexOf('{"from":"n0", "to":"n1"}') >= 0, json);
	}

	private static function chart(): FlowGraph {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		final fn: Null<QueryNode> = find(plugin.parseFile(SOURCE), ShapeVocab.functionLikeKinds(shape));
		final built: Null<FlowGraph> = fn == null ? null : FlowBuilder.build(fn, 'C.f', shape, SOURCE, plugin.lexicalRegions(SOURCE));
		return built ?? new FlowGraph('none');
	}

	private static function find(node: QueryNode, kinds: Array<String>): Null<QueryNode> {
		if (kinds.contains(node.kind)) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = find(c, kinds);
			if (found != null) return found;
		}
		return null;
	}

}
