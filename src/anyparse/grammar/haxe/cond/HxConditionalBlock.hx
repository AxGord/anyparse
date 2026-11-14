package anyparse.grammar.haxe.cond;

/**
 * Body of a `#if <cond> <blocks> [#elseif ...] [#else <blocks>] #end` preprocessor-guarded region
 * wrapping whole ELEMENTS of a block-structured list: switch `case` / `default` branches, enum
 * constructors, class / interface / abstract member declarations. The host ctor (`HxSwitchCase`,
 * `HxEnumCtor`, `HxClassMember`) consumes `#if` and the trailing `#end`; this typedef covers the
 * content between them. Every instance shares one layout policy: each body Star pads its
 * boundaries, indents under the directive, puts one element per line and shares its sibling
 * scope with the other bodies of the region.
 *
 * Each body is a `@:tryparse` Star that ends at the first token no element starts with, in legal
 * input `#elseif` / `#else` / `#end`; nesting re-enters the host ctor through the element type.
 * A `#if` inside a case body parses first as a statement region and fail-rewinds when the guarded
 * content is `case` / `default` clauses, so the switch-cases Star dispatches the case instance.
 * An empty member or enum region never lands here: the element's meta prefix claims it.
 */
@:peg
typedef HxConditionalBlock<T> = {
	var cond: HxPpCondLit;
	@:trivia
	@:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent, elementPerLine,
		siblingPad('anyparse.format.SiblingShare.padSlot', 'conditionalSiblings'))
	var body: Array<T>;
	@:trivia
	@:tryparse
	@:fmt(elemSelfTrailsNewline)
	var elseifs: Array<HxElseifBlock<T>>;
	@:optional
	@:kw('#else')
	@:trivia
	@:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent, elementPerLine,
		siblingPad('anyparse.format.SiblingShare.padSlot', 'conditionalSiblings'))
	var elseBody: Null<Array<T>>;
};
