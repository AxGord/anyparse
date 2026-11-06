package anyparse.query.format.json;

/** A repeating call of a written lint finding (`Check.RepeatSite`): the function it sits in and what repeats there. */
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
typedef LintRepeatSiteRecord = {
	@:key('function') var member: String;
	var at: String;
};
