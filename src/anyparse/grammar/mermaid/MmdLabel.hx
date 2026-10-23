package anyparse.grammar.mermaid;

/**
 * A node, pipe or subgraph-title label, by kind: a markdown string, plain text (what the reader sees), or markup (the HTML
 * Mermaid renders). Plain is tried before markup, which takes only what plain refuses.
 */
@:peg
enum MmdLabel {
	Markdown(text: MmdMarkdownLit);
	Plain(text: MmdTextLit);
	Markup(html: MmdMarkupLit);
}
