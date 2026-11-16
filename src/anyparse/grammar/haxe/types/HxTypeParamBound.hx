package anyparse.grammar.haxe.types;

/**
 * What follows a declare-site type parameter's constraint colon — the one answer to "which types does `T:` bound
 * `T` by" in the grammar: a single type (`T:Foo`, `T:(Foo)`, `T:(A) -> B`) or the Haxe 3 parenthesised list
 * (`T:(A, B)`). The single type is tried first, so a parenthesised type or a function type stays one bound and only
 * a `(`-list no type reads falls to the list. Neither alternative is a query node (`@:queryTransparent`): the
 * constraint projects as its types, as `T:A & B` does.
 */
@:peg
enum HxTypeParamBound {

	@:queryTransparent
	TypeBound(type: HxType);

	@:queryTransparent
	@:trivia
	@:lead('(')
	@:trail(')')
	@:sep(',')
	ParenBounds(types: Array<HxType>);

}
