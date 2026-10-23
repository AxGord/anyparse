package anyparse.grammar.mermaid;

/**
 * A `-. text .->` label, by kind: a markdown string, plain text (what the reader sees), or markup (the HTML
 * Mermaid renders). Plain is tried before markup, which takes only what plain refuses.
 */
@:peg
enum MmdDottedLabel {
	Markdown(text: MmdMarkdownLit);
	Plain(text: MmdDottedTextLit);
	Markup(html: MmdDottedMarkupLit);
}
