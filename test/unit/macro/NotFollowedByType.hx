package unit.macro;

import anyparse.grammar.haxe.lit.HxIdentLit;

/** A type with an `&` that must leave the first `&` of an outer `&&` alone. */
@:peg
@:schema(anyparse.grammar.haxe.HaxeFormat)
@:ws
enum NotFollowedByType {

	Named(name: HxIdentLit);

	@:infix('&', 0)
	@:notFollowedBy('=', '&')
	Both(left: NotFollowedByType, right: NotFollowedByType);

}
