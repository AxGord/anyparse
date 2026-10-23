package anyparse.grammar.mermaid;

/**
 * One flowchart statement. The order is the parse order: a keyword statement is tried before
 * `Chain`, so a node cannot be called `subgraph` or `style`, and `end` is no node id at all.
 */
@:peg
enum MmdStatement {
	FrontMatter(text: MmdFrontMatterLit);
	Comment(text: MmdCommentLit);
	Directive(text: MmdDirectiveLit);

	/** A `;` that separates two statements on one line; written on a line of its own. */
	@:lit(';')
	Semicolon;

	Header(header: MmdHeader);
	AnonymousSubgraph(subgraph: MmdAnonymousSubgraph);

	@:kw('subgraph')
	Subgraph(subgraph: MmdSubgraph);

	@:kw('direction')
	Direction(direction: MmdDirection);

	@:kw('classDef')
	ClassDef(def: MmdClassDef);

	@:kw('class')
	Class(assign: MmdClassAssign);

	@:kw('style')
	Style(style: MmdStyle);

	/** `linkStyle <links> interpolate <curve>` with no style list; tried first, see `MmdCurveLit`. */
	@:kw('linkStyle')
	LinkCurve(curve: MmdLinkCurve);

	@:kw('linkStyle')
	LinkStyle(style: MmdLinkStyle);

	@:kw('click')
	Click(click: MmdClick);

	@:kw('accTitle') @:lead(':')
	AccTitle(text: MmdLineTextLit);

	@:kw('accDescr') @:lead(':')
	AccDescr(text: MmdLineTextLit);

	@:kw('accDescr') @:lead('{') @:trail('}')
	AccDescrBlock(text: MmdBlockTextLit);

	/** Nodes and the links between them: `A[Start] --> B & C -->|yes| D`. */
	Chain(chain: MmdChain);
}
