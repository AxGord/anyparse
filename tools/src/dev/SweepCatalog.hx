package dev;

/** The trap catalog `trap-fix-sweep` reads. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef SweepCatalog = {

	/** The compiler version the probes' expectations were recorded with; the sweep does not read it. */
	@:optional var haxe: String;
	var traps: Array<SweepTrap>;

};
