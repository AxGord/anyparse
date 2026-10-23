package anyparse.grammar.mermaid;

/** A trailing argument of a `click` statement. */
@:peg
enum MmdClickExtra {
	Tooltip(text: MmdStringLit);
	Window(target: MmdWindowLit);
}
