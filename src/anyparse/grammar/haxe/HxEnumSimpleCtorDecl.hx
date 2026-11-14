package anyparse.grammar.haxe;

import anyparse.grammar.haxe.lit.HxIdentLit;
import anyparse.grammar.haxe.types.HxType;

/**
 * Grammar type for a parameterless enum constructor: `Name;`, or with a GADT
 * result type `Name:Type;`. The optional `returnType` keeps the plain form
 * byte-identical; the trailing semicolon lives on `HxEnumCtor.SimpleCtor`.
 */
@:peg
typedef HxEnumSimpleCtorDecl = {
	var name: HxIdentLit;
	@:optional
	@:fmt(space('typeHintColon', 'lead'))
	@:lead(':')
	var returnType: Null<HxType>;
};
