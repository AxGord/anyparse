package dev;

/** The trap catalog `trap-fix-sweep` reads. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef SweepCatalog = {
	var traps: Array<SweepTrap>;
};
