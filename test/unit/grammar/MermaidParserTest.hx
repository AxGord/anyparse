package unit.grammar;

import anyparse.grammar.mermaid.MermaidParser;
import anyparse.grammar.mermaid.MermaidWriter;
import anyparse.grammar.mermaid.MmdBackslashBody;
import anyparse.grammar.mermaid.MmdClickAction;
import anyparse.grammar.mermaid.MmdClickExtra;
import anyparse.grammar.mermaid.MmdDirection;
import anyparse.grammar.mermaid.MmdDottedLabel;
import anyparse.grammar.mermaid.MmdEdge;
import anyparse.grammar.mermaid.MmdFlowchart;
import anyparse.grammar.mermaid.MmdHeader;
import anyparse.grammar.mermaid.MmdLabel;
import anyparse.grammar.mermaid.MmdNode;
import anyparse.grammar.mermaid.MmdNodeGroup;
import anyparse.grammar.mermaid.MmdSlashBody;
import anyparse.grammar.mermaid.MmdSolidLabel;
import anyparse.grammar.mermaid.MmdStatement;
import anyparse.grammar.mermaid.MmdSubgraphHead;
import anyparse.grammar.mermaid.MmdThickLabel;
import anyparse.runtime.ParseError;
import haxe.Exception;
import haxe.Json;
import utest.Assert;
import utest.Test;

/**
 * `MermaidParser` / `MermaidWriter` on each flowchart construct: the AST a statement parses to,
 * compared by value against one built by hand, and the canonical text the writer gives back.
 */
@:nullSafety(Strict)
class MermaidParserTest extends Test {

	/** The header keyword with and without a direction, the arrow directions, and a `;` after it. */
	public function testHeaders(): Void {
		same(Header(Flowchart(TD)), parse('flowchart TD').first);
		same(Header(Undirected('graph')), parse('graph').first);
		same(Header(Graph(Right)), parse('graph >').first);
		final withSemicolon: MmdFlowchart = parse('flowchart LR;');
		same(Header(Flowchart(LR)), withSemicolon.first);
		same([Semicolon], withSemicolon.rest);
	}

	/** A header alone on its line takes no direction from the next line, whose first node may be called `v` or `TB`. */
	@:pin('guard')
	public function testAnUndirectedHeaderEndsItsLine(): Void {
		final doc: MmdFlowchart = parse('flowchart\n    v --> w\n');
		same(Header(Undirected('flowchart')), doc.first);
		same([edge(Arrow({ link: '-->' }), 'v', 'w')], doc.rest);
		same(Header(Undirected('graph')), parse('graph\n TB --> X').first);
	}

	/** Every node shape parses to its own ctor, the slanted ones by the closer that ends them. */
	public function testNodeShapes(): Void {
		final t: MmdLabel = Plain('t');
		final cases: Array<{ source: String, node: MmdNode }> = [
			{ source: 'a[t]', node: Rect(Id('a'), t) },
			{ source: 'a(t)', node: Round(Id('a'), t) },
			{ source: 'a([t])', node: Stadium(Id('a'), t) },
			{ source: 'a[[t]]', node: Subroutine(Id('a'), t) },
			{ source: 'a[(t)]', node: Cylinder(Id('a'), t) },
			{ source: 'a((t))', node: Circle(Id('a'), t) },
			{ source: 'a(((t)))', node: DoubleCircle(Id('a'), t) },
			{ source: 'a{t}', node: Diamond(Id('a'), t) },
			{ source: 'a{{t}}', node: Hexagon(Id('a'), t) },
			{ source: 'a>t]', node: Asymmetric(Id('a'), t) },
			{ source: 'a[/t/]', node: Slash(Id('a'), LeanRight(t)) },
			{ source: 'a[/t\\]', node: Slash(Id('a'), Trapezoid(t)) },
			{ source: 'a[\\t\\]', node: Backslash(Id('a'), LeanLeft(t)) },
			{ source: 'a[\\t/]', node: Backslash(Id('a'), InvTrapezoid(t)) },
			{ source: 'a@{ shape: rect }', node: Data(Id('a'), 'shape: rect') },
			{ source: 'a[t]:::hot', node: Classed(Rect(Id('a'), t), 'hot') }
		];
		for (c in cases) same(MmdStatement.Chain({ head: group(c.node), links: [] }), statement(c.source), c.source);
	}

	/** A label is a markdown string, plain text, or markup — whichever its source spells. */
	public function testLabelKinds(): Void {
		same(node(Rect(Id('a'), Markdown('**b**'))), statement('a["`**b**`"]'));
		same(node(Rect(Id('a'), Plain('Map<K, V>'))), statement('a["Map#lt;K, V#gt;"]'));
		same(node(Rect(Id('a'), Markup('x<br>y'))), statement('a[x<br>y]'));
		same(node(Rect(Id('a'), Markup('&lt;b&gt; &hearts;'))), statement('a["#lt;b#gt; #hearts;"]'));
		same(node(Rect(Id('a'), Plain('`x`'))), statement('a[`x`]'));
	}

	/** A chain links node groups left to right; `&` joins nodes into one group. */
	public function testChainsAndGroups(): Void {
		final expected: MmdStatement = MmdStatement.Chain({
			head: { vertex: Id('A'), also: [{ vertex: Id('B') }] },
			links: [
				{ edge: Arrow({ link: '-->' }), target: group(Id('C')) },
				{ edge: Arrow({ link: '-.->', label: Plain('maybe') }), target: { vertex: Id('D'), also: [{ vertex: Id('E') }] } }
			]
		});
		same(expected, statement('A & B --> C -.->|maybe| D & E'));
	}

	/** An inline label belongs to the link family its opener names; an edge id names the edge after it. */
	public function testInlineLabelsAndEdgeIds(): Void {
		same(edge(SolidText({ open: '--', text: MmdSolidLabel.Plain('yes'), close: '-->' })), statement('A -- yes --> B'));
		same(edge(ThickText({ open: '==', text: MmdThickLabel.Plain('a - b'), close: '==>' })), statement('A == a - b ==> B'));
		same(edge(DottedText({ open: '-.', text: MmdDottedLabel.Plain('a = b'), close: '.->' })), statement('A -. a = b .-> B'));
		same(edge(SolidText({ open: '--', text: MmdSolidLabel.Markup('a<br>b'), close: '-->' })), statement('A -- a<br>b --> B'));
		same(edge(Identified({ id: 'e1@', edge: Arrow({ link: '<-->' }) })), statement('A e1@<--> B'));
	}

	/** A subgraph is titled, named (the whole line, spaces included) or anonymous, and its body is statements. */
	public function testSubgraphs(): Void {
		final body: Array<MmdStatement> = [node(Id('x'))];
		same(
			Subgraph({ head: Titled({ name: 'one', title: Plain('One title') }), body: body }),
			statement('subgraph one [One title]\nx\nend')
		);
		same(Subgraph({ head: Named('Some Title'), body: body }), statement('subgraph Some Title\nx\nend'));
		same(Subgraph({ head: Named('"quoted"'), body: body }), statement('subgraph "quoted"\nx\nend'));
		same(AnonymousSubgraph({ keyword: 'subgraph', body: body }), statement('subgraph\nx\nend'));
	}

	/** Class, style and link-style statements keep their lists verbatim. */
	public function testStyling(): Void {
		same(ClassDef({ names: 'a,b', styles: 'fill:#f9f,stroke:#333' }), statement('classDef a,b fill:#f9f,stroke:#333'));
		same(Class({ nodes: 'A,B', className: 'hot' }), statement('class A,B hot'));
		same(Style({ target: 'A', styles: 'stroke-dasharray: 5 5' }), statement('style A stroke-dasharray: 5 5'));
		same(LinkStyle({ links: '0,2', styles: 'stroke:#f00' }), statement('linkStyle 0,2 stroke:#f00'));
		same(
			LinkStyle({ links: 'default', curve: 'basis', styles: 'stroke:#000' }),
			statement('linkStyle default interpolate basis stroke:#000')
		);
		same(LinkCurve({ links: '1', curve: 'cardinal' }), statement('linkStyle 1 interpolate cardinal'));
	}

	/** A click opens a link or calls a function, with its tooltip and window when written. */
	public function testClicks(): Void {
		same(Click({ target: 'A', action: Callback({ callback: 'cb', extras: [Tooltip('"tip"')] }) }), statement('click A cb "tip"'));
		same(Click({ target: 'A', action: Call({ callback: 'cb(1, "x")', extras: [] }) }), statement('click A call cb(1, "x")'));
		same(
			Click({ target: 'A', action: Href({ url: '"https://x"', extras: [Tooltip('"t"'), Window('_blank')] }) }),
			statement('click A href "https://x" "t" _blank')
		);
		same(Click({ target: 'A', action: Link({ url: '"https://x"', extras: [] }) }), statement('click A "https://x"'));
	}

	/** Comments, directives, front matter and accessibility lines are statements of their own. */
	public function testNonGraphStatements(): Void {
		final doc: MmdFlowchart = MermaidParser.parse(
			'---\ntitle: T\n---\n%%{init: {}}%%\nflowchart\n%% note\naccTitle: A title\naccDescr { two\nlines }\n'
		);
		same(FrontMatter('---\ntitle: T\n---'), doc.first);
		same([
			Directive('%%{init: {}}%%'),
			Header(Undirected('flowchart')),
			Comment('%% note'),
			AccTitle('A title'),
			AccDescrBlock('two\nlines ')
		], doc.rest);
	}

	/** `end` closes a subgraph and is no node id; text after the last statement is refused. */
	public function testRejections(): Void {
		rejects('flowchart TD\nend --> B');
		rejects('flowchart TD\nA --> B\n)))');
		rejects('flowchart TD\nsubgraph one\nA');
	}

	/**
	 * The canonical text: one statement per line, a subgraph body indented,
	 * shapes hugging their id, labels re-quoted only where needed.
	 */
	public function testTheWriterIsCanonical(): Void {
		final source: String = 'graph TD\n  A[ "Start" ]-->|"ok"|B{Is it?}\n\n  subgraph s1[ One ]\nB-- "no" -->C\n  end';
		final expected: String = 'graph TD\nA[Start] -->|ok| B{Is it?}\nsubgraph s1[One]\n    B -- no --> C\nend\n';
		Assert.equals(expected, MermaidWriter.write(MermaidParser.parse(source)));
	}

	/** A label that renders as literal text, markup, a backtick or an unnamed code is written back so it renders the same. */
	@:killer('M-MERMAID-PLAIN-LT-RAW', 'M-MERMAID-PLAIN-AMP-RAW', 'M-MERMAID-TICK-UNESCAPED', 'M-MERMAID-CODEPOINT-UNBOUNDED')
	@:pin('control')
	public function testWritingKeepsWhatALabelRenders(): Void {
		for (line in [
			'A["Array#lt;String#gt;"]',
			'B["#lt;b#gt;bold#lt;/b#gt;"]',
			'C["a #amp;quot; b"]',
			'D[`x`]',
			'E["#96;x` y|z"]',
			'F["&#99999999;"] --> G["&#1114112;"] --> H["&#55357;"]',
			'I["a<br>b"] -- "x<i>y" --> J["`**md**`"]',
			'K["50%% done"]'
		]) Assert.equals('flowchart TD\n$line\n', MermaidWriter.write(MermaidParser.parse('flowchart TD\n$line\n')), line);
	}

	/** An AST built by hand with labels the bare form cannot hold writes to text that parses back to it. */
	@:killer('M-MERMAID-ENCODE-DROPPED')
	@:pin('control')
	public function testAnyLabelRoundTripsThroughTheWriter(): Void {
		for (text in [
			'a "b"',
			'x|y',
			'#quot;',
			' pad ',
			'`md`',
			'line\nbreak',
			'[(odd)]',
			'v1.2-rc=3',
			'Map<K, V>',
			'a &amp; b'
		]) {
			final doc: MmdFlowchart = {
				first: Header(Flowchart(TD)),
				rest: [
					MmdStatement.Chain({
						head: group(Rect(Id('A'), Plain(text))),
						links: [
							{ edge: Arrow({ link: '-->', label: Plain(text) }), target: group(Rect(Id('B'), Markdown(text))) },
							{ edge: SolidText({ open: '--', text: MmdSolidLabel.Plain(text), close: '---' }), target: group(Id('C')) },
							{ edge: ThickText({ open: '==', text: MmdThickLabel.Plain(text), close: '==>' }), target: group(Id('D')) },
							{ edge: DottedText({ open: '-.', text: MmdDottedLabel.Plain(text), close: '.->' }), target: group(Id('E')) }
						]
					}),
					node(Rect(Id('M'), Markup('<i>$text</i>'))),
					Subgraph({ head: Titled({ name: 'g', title: Plain(text) }), body: [] })
				]
			};
			same(doc, MermaidParser.parse(MermaidWriter.write(doc)), Json.stringify(text));
		}
	}

	private static function parse(source: String): MmdFlowchart {
		return MermaidParser.parse(source);
	}

	/** The one statement `body` parses to under a `flowchart` header. */
	private static function statement(body: String): MmdStatement {
		final doc: MmdFlowchart = MermaidParser.parse('flowchart\n$body\n');
		Assert.equals(1, doc.rest.length, body);
		return doc.rest[0];
	}

	private static function group(vertex: MmdNode): MmdNodeGroup {
		return { vertex: vertex, also: [] };
	}

	/** A chain of one node and no link. */
	private static function node(vertex: MmdNode): MmdStatement {
		return MmdStatement.Chain({ head: group(vertex), links: [] });
	}

	/** A chain `<from> <edge> <to>`. */
	private static function edge(edge: MmdEdge, from: String = 'A', to: String = 'B'): MmdStatement {
		return MmdStatement.Chain({ head: group(Id(from)), links: [{ edge: edge, target: group(Id(to)) }] });
	}

	private static function same(expected: Any, actual: Any, ?message: String): Void {
		Assert.equals(MermaidAst.dump(expected), MermaidAst.dump(actual), message);
	}

	private static function rejects(source: String): Void {
		final failed: Bool = try {
			MermaidParser.parse(source);
			false;
		} catch (_: ParseError) true catch (_: Exception) true;
		Assert.isTrue(failed, 'refuses ${Json.stringify(source)}');
	}

}
