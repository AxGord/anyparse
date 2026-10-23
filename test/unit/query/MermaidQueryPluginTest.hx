package unit.query;

import anyparse.grammar.mermaid.MermaidQueryPlugin;
import anyparse.query.Engine;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.query.cli.CliArgs;
import anyparse.runtime.Span;

/**
 * `MermaidQueryPlugin` — the Mermaid flowchart grammar's query projection: statements under a
 * `Document` root, nodes named by id and shapes by label, the selector vocabulary the read ops take,
 * and the canonical writer behind `writeRoundTrip`.
 */
@:nullSafety(Strict)
class MermaidQueryPluginTest extends Test {

	private static final DOCUMENT: String = '\nflowchart TD\n%% note\nA[Start] --> B{Is it?} & C\nsubgraph g [Group]\n    C -.-> D\nend\n';

	private final _plugin: MermaidQueryPlugin = new MermaidQueryPlugin();

	/** The projection is the statement list in source order, each statement's nodes beneath it. */
	public function testTheProjectionIsTheStatementList(): Void {
		final root: QueryNode = _plugin.parseFile(DOCUMENT);
		Assert.equals('Document', root.kind);
		Assert.equals('Header,Comment,Chain,Subgraph', [for (child in root.children) child.kind].join(','));
		Assert.equals(1, root.children[0].span?.from);
	}

	/** A shape is named by its decoded label, a node id by the id, and both are addressable. */
	public function testASelectorPicksAShapeByItsLabel(): Void {
		final diamond: QueryNode = only('Chain > Diamond:Is it?');
		final span: Null<Span> = diamond.span;
		Assert.notNull(span);
		if (span != null) Assert.equals('B{Is it?}', DOCUMENT.substring(span.from, span.to));
		Assert.equals('Id', diamond.children[0].kind);
		Assert.equals('B', diamond.children[0].name);
		Assert.equals('Titled', only('Subgraph > Titled:g').kind);
	}

	/** Every `%%` comment is a line-comment region. */
	public function testTheLexicalRegionsAreTheComments(): Void {
		final regions: Array<LexRegion> = _plugin.lexicalRegions(DOCUMENT);
		Assert.equals('%% note', [for (r in regions) DOCUMENT.substring(r.from, r.to)].join('|'));
	}

	/** A pattern is one statement, and a node id `$name` is a metavariable. */
	public function testAPatternNodeIdIsAMetavariable(): Void {
		final pattern: Pattern = _plugin.parsePattern('$$a --> $$b');
		Assert.equals('Chain', pattern.root.kind);
		Assert.equals('Metavar:a,Arrow:null,Metavar:b', [for (child in pattern.root.children) '${child.kind}:${child.name}'].join(','));
	}

	/** `writeRoundTrip` is the canonical form, not the file's own layout. */
	public function testWriteRoundTripIsTheCanonicalForm(): Void {
		Assert.equals('flowchart TD\nA[Start] --> B\n', _plugin.writeRoundTrip('flowchart TD\n  A["Start"]-->B\n'));
	}

	/** A `.mmd` or `.mermaid` file reaches this plugin whatever `--lang` says. */
	public function testTheExtensionSelectsThePlugin(): Void {
		Assert.equals('mermaid', CliArgs.pickPluginFor('haxe', 'docs/flow.MMD').langName());
		Assert.equals('mermaid', CliArgs.pickPluginFor('haxe', 'a.mermaid').langName());
		Assert.equals('mermaid', CliArgs.pickPlugin(CliArgs.MERMAID_LANG).langName());
		Assert.equals('haxe', CliArgs.pickPluginFor('haxe', 'A.hx').langName());
	}

	/** Every kind the projection emits is one the walker declares. */
	public function testEveryProjectedKindIsDeclared(): Void {
		final declared: Array<String> = _plugin.projectedKinds();
		for (kind in [
			'Header',
			'Comment',
			'Chain',
			'Subgraph',
			'Titled',
			'Rect',
			'Diamond',
			'Arrow',
			'DottedText',
			'Id'
		]) Assert.isTrue(declared.contains(kind), '$kind is declared');
	}

	/** The one node `selector` picks in `DOCUMENT`. */
	private function only(selector: String): QueryNode {
		final hits: Array<QueryNode> = Engine.select(_plugin.parseFile(DOCUMENT), Selector.parse(selector));
		Assert.equals(1, hits.length, selector);
		return hits[0];
	}

}
