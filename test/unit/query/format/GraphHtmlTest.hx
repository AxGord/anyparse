package unit.query.format;

import anyparse.query.format.GraphHtml;
import anyparse.query.format.GraphMermaid;
import anyparse.query.format.json.GraphPageJson;
import anyparse.query.format.json.GraphPageJsonParser;
import anyparse.query.graph.CodeGraph;
import anyparse.query.graph.GraphView;

/**
 * `GraphHtml` — the views of a graph page over the graph fixture, from the level asked down through the packages to
 * the types' members, each reached once; and the page, its data read back and its inlined script unable to close
 * the element holding it.
 */
@:nullSafety(Strict)
class GraphHtmlTest extends Test {

	/**
	 * The first view draws the packages; a package opens into its types,
	 * a type into its members, in the order a reader first reaches them.
	 */
	public function testViewsOpenPackagesThenTypes(): Void {
		final data: GraphPageJson = GraphHtml.data(members(), Package, prune(), 'calls');
		Assert.equals(',p_pkg_da,p_pkg_db,t_pkg_da_dAlpha,t_pkg_db_dBeta,t_pkg_db_dGamma', [for (v in data.views) v.id].join(','));
		Assert.equals(
			'calls|package pkg.a|package pkg.b|type pkg.a.Alpha|type pkg.b.Beta|type pkg.b.Gamma',
			[for (v in data.views) v.title].join('|')
		);
		Assert.equals('-,,,p_pkg_da,p_pkg_db,p_pkg_db', [for (v in data.views) v.up ?? '-'].join(','), 'a view goes up to its holder');
	}

	/** The first view is the graph lifted to the level asked; a type's view holds its members and folds the rest. */
	public function testAViewIsTheGraphOpenedThere(): Void {
		final graph: CodeGraph = members();
		final data: GraphPageJson = GraphHtml.data(graph, Package, prune(), 'calls');
		Assert.equals(GraphMermaid.write(GraphView.filter(GraphView.lift(graph, Package), prune())), data.views[0].mermaid);
		final alpha: String = data.views[3].mermaid;
		Assert.isTrue(alpha.indexOf('m_pkg_da_dAlpha_drun(run)') >= 0, alpha);
		Assert.isTrue(alpha.indexOf('p_pkg_db[pkg.b]') >= 0, 'what lies outside the type stands whole: $alpha');
		Assert.equals(-1, alpha.indexOf('t_pkg_db_dBeta'), alpha);
	}

	/** Started at the type level, the packages stand open in every view and only the types open further. */
	public function testAFinerLevelOpensWhatHoldsIt(): Void {
		final data: GraphPageJson = GraphHtml.data(members(), Type, prune(), 'calls');
		Assert.equals(',t_pkg_da_dAlpha,t_pkg_db_dBeta,t_pkg_db_dGamma', [for (v in data.views) v.id].join(','));
		Assert.equals('-,,,', [for (v in data.views) v.up ?? '-'].join(','), 'a package open from the start has no view to go up to');
	}

	/**
	 * The library is inlined with every `</script` written `<\/script`,
	 * so the data, the library and the page's own script each close once.
	 */
	@:killer('M-GRAPH-HTML-SCRIPT-UNCLOSED')
	@:pin('control')
	public function testThePageInlinesItsScriptsClosedOnce(): Void {
		final page: String = GraphHtml.page(
			GraphHtml.data(members(), Package, prune(), 'a <b> & c'), 'var s = "</script><SCRIPT></Script>";'
		);
		Assert.isTrue(page.indexOf('var s = "<\\/script><SCRIPT><\\/Script>";') >= 0);
		Assert.equals(3, page.toLowerCase().split('</script>').length - 1);
		Assert.isTrue(page.indexOf('<title>a &lt;b&gt; &amp; c</title>') >= 0);
	}

	/** The data the page holds reads back as the views it was written from. */
	public function testTheDataReadsBack(): Void {
		final data: GraphPageJson = GraphHtml.data(members(), Package, prune(), 'a <b> title');
		final page: String = GraphHtml.page(data, '');
		final open: String = 'id="graph-data">';
		final start: Int = page.indexOf(open) + open.length;
		final json: String = page.substring(start, page.indexOf('</script>', start));
		Assert.equals(-1, json.indexOf('<'), 'no markup can start inside the data');
		final back: GraphPageJson = GraphPageJsonParser.parse(json);
		Assert.equals(
			[for (v in data.views) '${v.id} ${v.title} ${v.mermaid}'].join('\n'),
			[for (v in back.views) '${v.id} ${v.title} ${v.mermaid}'].join('\n')
		);
		Assert.equals(data.legend, back.legend);
	}

	/** The member graph of the fixture. */
	private static function members(): CodeGraph {
		return MemberGraphBuilder.whole(GraphFixture.calls(), null);
	}

	/** A filter that prunes nothing. */
	private static function prune(): GraphFilter {
		return {
			minWeight: 1,
			focus: [],
			radius: 0,
			mutualOnly: false,
			external: false
		};
	}

}
