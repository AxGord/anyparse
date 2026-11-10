package anyparse.grammar.haxe;

/**
 * A parenthesised condition group: its interior is not read as an expression, only balanced, so a quoted string or a
 * block comment inside it opens nothing and a group may span lines.
 */
@:peg
typedef HxPpCondGroup = {
	@:lead('(')
	@:trail(')')
	var items: Array<HxPpCondGroupItem>;
}
