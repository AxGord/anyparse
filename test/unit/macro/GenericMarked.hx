package unit.macro;

import anyparse.grammar.haxe.lit.HxIdentLit;

/**
 * A word after `@`: the Haxe structure of `GenericBare` under another grammar, so an instance shaped
 * for the wrong argument still compiles and parses wrong.
 */
@:peg
typedef GenericMarked = {
	@:lead('@')
	var word: HxIdentLit;
}
