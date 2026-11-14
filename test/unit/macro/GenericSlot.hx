package unit.macro;

import anyparse.grammar.haxe.lit.HxIdentLit;

/** A generic `@:peg` typedef: a name, then its `T` after a `:` lead that every instance carries. */
@:peg
typedef GenericSlot<T> = {
	var name: HxIdentLit;
	@:lead(':')
	var value: T;
}
