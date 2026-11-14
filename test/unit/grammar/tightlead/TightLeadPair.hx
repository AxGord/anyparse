package unit.grammar.tightlead;

import anyparse.grammar.haxe.lit.HxIdentLit;

/** A pair whose second field's lead is Haxe's key-value separator, which the format declares tight, and no `@:fmt` space knob spaces it. */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
typedef TightLeadPair = {
	var name: HxIdentLit;
	@:lead(':')
	var type: HxIdentLit;
}
