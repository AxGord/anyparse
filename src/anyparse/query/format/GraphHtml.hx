package anyparse.query.format;

import anyparse.grammar.json.JsonFormat;
import anyparse.query.format.json.GraphPageJson;
import anyparse.query.format.json.GraphPageJsonWriter;
import anyparse.query.format.json.GraphPageViewJson;
import anyparse.query.graph.CodeGraph;
import anyparse.query.graph.GraphView;
import haxe.Exception;

/**
 * A `CodeGraph` as one self-contained HTML page a reader opens node by node: the first view draws the graph at the level
 * asked, a click on a node holding others opens a view of what it holds, and a click on an opened frame or on an earlier
 * step of the path goes back. Every view is drawn here through `GraphView` and `GraphMermaid`; the page renders the
 * Mermaid text of the view shown with the library it inlines, so it reads with no network. A plain text template: the
 * page is not a typed tree yet.
 */
@:nullSafety(Strict)
final class GraphHtml {

	/** How many edges, either way, a view of an opened node reaches from what the node holds: the edges touching it. */
	private static inline final OPENED_RADIUS: Int = 1;

	/** The page around its data and its two scripts, with no line of either: the style, the header, the legend's text. */
	private static final HEAD: Array<String> = [
		'<!DOCTYPE html>',
		'<html lang="en">',
		'<head>',
		'<meta charset="utf-8">',
		'<meta name="viewport" content="width=device-width, initial-scale=1">',
		'<style>',
		':root { color-scheme: light; --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --line: #d1d9e0; --accent: #0969da; }',
		':root[data-theme="dark"] {'
			+ ' color-scheme: dark; --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --line: #3d444d; --accent: #4493f8; }',
		'html, body { height: 100%; margin: 0; }',
		'body { display: flex; flex-direction: column; background: var(--bg); color: var(--fg); font: 14px/1.45 system-ui, sans-serif; }',
		'header { display: flex; align-items: center; gap: 12px; padding: 8px 14px; border-bottom: 1px solid var(--line); }',
		'#path { flex: 1; overflow-wrap: anywhere; }',
		'#path a { color: var(--accent); text-decoration: none; }',
		'#path a:hover { text-decoration: underline; }',
		'button { background: none; color: var(--fg); border: 1px solid var(--line); border-radius: 6px; padding: 4px 10px; font: '
			+ 'inherit; cursor: pointer; }',
		'main { flex: 1; display: flex; min-height: 0; }',
		'#view { flex: 1; overflow: auto; padding: 14px; }',
		'aside { width: 280px; flex: none; overflow: auto; padding: 14px; border-left: 1px solid var(--line); color: var(--muted); }',
		'aside h2 { margin: 0 0 8px; font-size: 13px; color: var(--fg); }',
		'aside p { margin: 8px 0; }',
		'#legend-chart svg { max-width: 100%; height: auto; }',
		'.opens { cursor: pointer; }',
		'.closes { cursor: zoom-out; }',
		'.error { color: #d1242f; white-space: pre-wrap; }',
		'</style>'
	];

	private static final BODY: Array<String> = [
		'</head>',
		'<body>',
		'<header><nav id="path"></nav><button id="theme" type="button">Light / dark</button></header>',
		'<main>',
		'<div id="view"></div>',
		'<aside>',
		'<h2>Legend</h2>',
		'<div id="legend-chart"></div>',
		'<p>Click a package or a type to open it; click an opened frame, or an earlier step of the path above, to go back.</p>',
		'<p>A plain arrow is a call or an import, a thick one a construction, a dotted one a reference or a virtual call, a circle-ended '
			+ 'one a member a type holds; a number counts the sites an edge stands for.</p>',
		'<p>Red: the two ends depend on each other. Bold: what the node opened holds. Dashed: outside the scope.</p>',
		'</aside>',
		'</main>'
	];

	/** The page's own script: it renders the view the location names, binds the clicks, and switches the theme. */
	private static final SCRIPT: Array<String> = [
		'(function () {',
		'  "use strict";',
		'  var data = JSON.parse(document.getElementById("graph-data").textContent);',
		'  var views = {};',
		'  data.views.forEach(function (v) { views[v.id] = v; });',
		'  var view = document.getElementById("view");',
		'  var path = document.getElementById("path");',
		'  var legend = document.getElementById("legend-chart");',
		'  var dark = window.matchMedia("(prefers-color-scheme: dark)").matches;',
		'  var serial = 0;',
		'  function configure() {',
		'    document.documentElement.setAttribute("data-theme", dark ? "dark" : "light");',
		'    mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "default", securityLevel: "strict",',
		'      maxTextSize: 100000000, maxEdges: 1000000, flowchart: { useMaxWidth: false } });',
		'  }',
		'  function draw(target, text) {',
		'    serial += 1;',
		'    var name = "graph-svg-" + serial;',
		'    return mermaid.render(name, text).then(function (out) {',
		'      target.className = "";',
		'      target.innerHTML = out.svg;',
		'      var svg = target.querySelector("svg");',
		'      return svg ? { svg: svg, prefix: name + "-" } : null;',
		'    }, function (error) {',
		'      target.className = "error";',
		'      target.textContent = String(error && error.message ? error.message : error);',
		'      return null;',
		'    });',
		'  }',
		'  function shown() {',
		'    var id = decodeURIComponent(location.hash.slice(1));',
		'    return Object.prototype.hasOwnProperty.call(views, id) ? id : "";',
		'  }',
		'  function go(id) {',
		'    location.hash = id;',
		'  }',
		'  function nodeIdOf(element, prefix) {',
		'    var id = element.id.indexOf(prefix) === 0 ? element.id.slice(prefix.length) : element.id;',
		'    var match = /^flowchart-([A-Za-z0-9_]+)-[0-9]+/.exec(id);',
		'    return match ? match[1] : id;',
		'  }',
		'  function showPath(id) {',
		'    path.textContent = "";',
		'    var chain = [];',
		'    for (var step = id; step !== undefined; step = views[step].up) chain.unshift(step);',
		'    chain.forEach(function (step, i) {',
		'      if (i > 0) path.appendChild(document.createTextNode(" / "));',
		'      var link = document.createElement(step === id ? "strong" : "a");',
		'      link.textContent = views[step].title;',
		'      if (step !== id) link.href = "#" + step;',
		'      path.appendChild(link);',
		'    });',
		'  }',
		'  function show() {',
		'    var id = shown();',
		'    document.title = views[id].title;',
		'    showPath(id);',
		'    draw(view, views[id].mermaid).then(function (drawn) {',
		'      if (!drawn) return;',
		'      drawn.svg.querySelectorAll("g.node").forEach(function (node) {',
		'        var target = nodeIdOf(node, drawn.prefix);',
		'        if (target === id || !Object.prototype.hasOwnProperty.call(views, target)) return;',
		'        node.classList.add("opens");',
		'        node.addEventListener("click", function () { go(target); });',
		'      });',
		'      drawn.svg.querySelectorAll("g.cluster").forEach(function (frame) {',
		'        var target = views[nodeIdOf(frame, drawn.prefix)];',
		'        if (!target || target.up === undefined) return;',
		'        frame.classList.add("closes");',
		'        frame.addEventListener("click", function () { go(target.up); });',
		'      });',
		'    });',
		'  }',
		'  function redraw() {',
		'    configure();',
		'    show();',
		'    draw(legend, data.legend);',
		'  }',
		'  document.getElementById("theme").addEventListener("click", function () {',
		'    dark = !dark;',
		'    redraw();',
		'  });',
		'  window.addEventListener("hashchange", show);',
		'  redraw();',
		'})();'
	];

	/**
	 * Every view of `graph` a reader can reach, in the order a reader first reaches them. The first, titled `title`, draws
	 * the graph at `level`; a view of a node holding others opens it and the nodes holding it, and keeps what it holds
	 * with the edges touching that (`GraphView.opening`). Each view is pruned by the weight floor, the mutual pairs and
	 * the scope of `prune`, whose focus and radius the page does not read.
	 */
	public static function data(graph: CodeGraph, level: GraphLevel, prune: GraphFilter, title: String): GraphPageJson {
		// every node holding a node at the level stands open in every view
		final above: Map<String, Bool> = [];
		for (n in graph.nodes()) if (n.level == level) openHolders(graph, n, above);
		final first: CodeGraph = GraphView.filter(GraphView.opened(graph, above), viewFilter(prune, []));
		final views: Array<GraphPageViewJson> = [{ id: '', title: title, mermaid: GraphMermaid.write(first) }];
		final seen: Map<String, Bool> = [];
		final pending: Array<CodeGraph> = [first];
		while (pending.length > 0) {
			final shown: CodeGraph = pending.shift() ?? throw new Exception('graph page: no view pending');
			for (id in openable(shown, graph)) if (!seen.exists(id)) {
				seen[id] = true;
				final n: GraphNode = graph.node(id) ?? throw new Exception('graph page: no node $id');
				final open: Map<String, Bool> = above.copy();
				open[id] = true;
				openHolders(graph, n, open);
				final held: Array<String> = [for (c in graph.held(id)) c.id];
				final drawn: CodeGraph = GraphView.filter(GraphView.opening(graph, id, open), viewFilter(prune, held));
				// a node shows only inside its holder opened, so the holder's view, when it has one, was reached first
				final parent: Null<String> = n.parent;
				views.push({
					id: id,
					title: '${n.level} ${n.name}',
					up: parent != null && seen.exists(parent) ? parent : '',
					mermaid: GraphMermaid.write(drawn)
				});
				pending.push(drawn);
			}
		}
		return { views: views, legend: GraphMermaid.write(legend(), null, TB) };
	}

	/**
	 * The page of `data`, `mermaid` the text of the Mermaid library it inlines. A `</script` in either is written
	 * `<\/script`, which a script reads alike and which cannot close the element holding it.
	 */
	public static function page(data: GraphPageJson, mermaid: String): String {
		final json: String = GraphPageJsonWriter.write(data, JsonFormat.instance.defaultWriteOptions).replace('<', '\\u003c');
		final title: String = data.views.length > 0 ? data.views[0].title : 'graph';
		final lines: Array<String> = HEAD.concat(['<title>${title.htmlEscape(true)}</title>']).concat(BODY);
		lines.push('<script type="application/json" id="graph-data">$json</script>');
		lines.push('<script>${inlined(mermaid)}</script>');
		lines.push('<script>');
		lines.push(SCRIPT.join('\n'));
		lines.push('</script>');
		lines.push('</body>');
		lines.push('</html>');
		return lines.join('\n') + '\n';
	}

	/** The nodes of `shown` a reader can open: each holds nodes in `graph` and none in `shown`. */
	private static function openable(shown: CodeGraph, graph: CodeGraph): Array<String> {
		return [
			for (n in shown.nodes()) if (graph.held(n.id).length > 0 && shown.held(n.id).length == 0) n.id
		];
	}

	/** Mark every node holding `n` open in `open`. */
	private static function openHolders(graph: CodeGraph, n: GraphNode, open: Map<String, Bool>): Void {
		var parent: Null<String> = n.parent;
		while (parent != null) {
			open[parent] = true;
			parent = graph.node(parent)?.parent;
		}
	}

	/** `prune` centred on `focus`, `OPENED_RADIUS` edges around it, or on nothing. */
	private static function viewFilter(prune: GraphFilter, focus: Array<String>): GraphFilter {
		return {
			minWeight: prune.minWeight,
			focus: focus,
			radius: OPENED_RADIUS,
			mutualOnly: prune.mutualOnly,
			external: prune.external
		};
	}

	/** `script` with each `</script`, whatever its case, written `<\/script`. */
	private static function inlined(script: String): String {
		return ~/<\/(script)/gi.map(script, found -> '<\\/${found.matched(1)}');
	}

	/** The legend's chart: a node of each level and outside the scope, and an edge of each look. */
	private static function legend(): CodeGraph {
		final graph: CodeGraph = new CodeGraph();
		final pkg: String = graph.addNode(Package, 'package', 'package', null, false);
		final type: String = graph.addNode(Type, 'type', 'type', null, false);
		final member: String = graph.addNode(Member, 'member', 'member', null, false);
		final held: String = graph.addNode(Member, 'held', 'held by the node opened', null, false);
		final outside: String = graph.addNode(Member, 'outside', 'outside the scope', null, true);
		graph.addEdge(pkg, type, Import);
		graph.addEdge(type, pkg, Import);
		graph.addEdge(type, member, New, 2);
		graph.addEdge(member, held, Ref);
		graph.addEdge(held, outside, Contains);
		graph.markFocus(held);
		return graph;
	}

}
