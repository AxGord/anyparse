package unit.macro;

/** Two instances of one generic typedef with different arguments, a field each. */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
typedef GenericPair = {
	var bare: GenericSlot<GenericBare>;
	@:lead(',')
	var marked: GenericSlot<GenericMarked>;
}
