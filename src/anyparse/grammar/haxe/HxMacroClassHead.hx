package anyparse.grammar.haxe;

/**
 * Head of a `macro class` reification expression: the `class` keyword
 * plus an optional class name.
 *
 * Splitting the head into a two-branch enum is the load-bearing design
 * choice for this slice. The `class` keyword must ALWAYS be consumed,
 * but the name is optional and may carry a leading `$`. A single
 * `@:kw('class') @:optional var name:Null<…>` field cannot express
 * this: `@:optional` + `@:kw` makes the *keyword itself* conditional
 * (the Lowering optional-Ref path rewinds entirely when `matchKw`
 * fails), and `@:kw` + `@:absentOn` is a compile-time fatal in
 * `Lowering`. The enum sidesteps both: each branch carries `@:kw('class')`
 * so the keyword is consumed unconditionally on whichever branch wins.
 *
 * Branch order matters — `NamedHead` is declared first so it is tried
 * first (enum branches are lowered in declaration order with full
 * rollback via `tryBranch`). For `macro class { … }` the `class`
 * keyword matches, the `HxMacroClassName` regex then fails against `{`,
 * the branch rolls back, and `AnonHead` succeeds. For
 * `macro class $name { … }` / `macro class Foo { … }` the name regex
 * matches and `NamedHead` wins. This ParamCtor-then-SimpleCtor
 * same-keyword pair mirrors `HxExpr.UntypedExpr` / `UntypedAtom`
 * (`@:kw('untyped')` ParamCtor then SimpleCtor) exactly.
 *
 * The members block lives one level up on `HxMacroClass` (shared by
 * both branches), so only name presence is disambiguated here.
 */
@:peg
enum HxMacroClassHead {
	@:kw('class')
	NamedHead(name:HxMacroClassName);

	@:kw('class')
	AnonHead;
}
