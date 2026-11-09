package anyparse.grammar.haxe;

/**
 * One `#elseif <cond> <ctors>` clause of a `HxConditionalEnumMember`, the enum-scope twin of
 * `HxElseifMember`. The keyword sits on the first field so the parent's Star stops at the
 * first token that is not `#elseif`.
 */
@:peg
typedef HxElseifEnumMember = {
	@:kw('#elseif') var cond: HxPpCondLit;
	@:trivia @:tryparse @:fmt(padLeading, padTrailing, conditionalBodyIndent) var body: Array<HxEnumMember>;
};
