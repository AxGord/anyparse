package unit.macro;

import anyparse.grammar.haxe.lit.HxIdentLit;

/** A type followed by `&&` and a word: the `&&` belongs to the wrapper, not to the type. */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
typedef NotFollowedByWrap = {

	var type: NotFollowedByType;

	@:lead('&&')
	var rest: HxIdentLit;

}
