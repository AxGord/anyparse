package unit.macro;

import anyparse.grammar.haxe.HxIdentLit;

/** A bare word, the first argument of `GenericSlot` in `GenericPair`. */
@:peg
typedef GenericBare = { var word: HxIdentLit; }
