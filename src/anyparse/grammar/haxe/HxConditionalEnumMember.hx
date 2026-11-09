package anyparse.grammar.haxe;

/**
 * Body of a `#if <cond> <ctors> [#elseif …] [#else <ctors>] #end` region among enum
 * constructors: the enum-scope twin of `HxConditionalMember`. The enclosing
 * `HxEnumCtor.Conditional` consumes `#if` and `#end`; nesting re-enters that ctor through
 * `HxEnumMember`. An empty region never lands here: `HxEnumMember.meta` claims it as a prefix.
 */
@:peg
typedef HxConditionalEnumMember = {
	var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var body: Array<HxEnumMember>;
	@:trivia @:tryparse @:fmt(elemSelfTrailsNewline) var elseifs: Array<HxElseifEnumMember>;
	@:optional @:kw('#else') @:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var elseBody: Null<Array<HxEnumMember>>;
};
