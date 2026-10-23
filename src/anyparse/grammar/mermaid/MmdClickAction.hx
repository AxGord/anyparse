package anyparse.grammar.mermaid;

/** What a click does: open a link (`href "url"` or a bare `"url"`) or call a function (`call fn()` or a bare `fn`). */
@:peg
enum MmdClickAction {
	@:kw('href')
	Href(link: MmdClickLink);

	@:kw('call')
	Call(call: MmdClickCall);

	Link(link: MmdClickLink);
	Callback(call: MmdClickCall);
}
