package unit.minilex;

/**
 * A second grammar, one screen long, whose only purpose is to be LEXED: a word, an `@ … @`
 * string and a parenthesised list, over a format that spells its comments `#` and `<# #>`.
 *
 * Nothing here is Haxe, so `unit.lowering.GeneratedLexicalScanSecondGrammarTest` can state
 * what a Haxe-only pin cannot: the generated pass carries no built-in idea of a comment or a
 * string, only the declarations it was handed.
 */
@:peg
@:schema(unit.minilex.MiniLexFormat)
@:ws
enum MiniLexDoc {

	Word(s: MiniLexAtom);

	Text(s: MiniLexStringLit);

	@:lead('(') @:trail(')')
	List(items: Array<MiniLexDoc>);

}
